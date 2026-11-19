#!/usr/bin/env python3

import argparse
import json
import re
import statistics
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone, timedelta

SCRIPT_VERSION = "1.0.0"


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------


@dataclass
class Event:
    timestamp: datetime
    message: str


@dataclass
class Incident:
    reason: str
    detected_at: datetime
    previous_healthy: datetime | None
    recovered_at: datetime | None = None

    def upper_bound_downtime(self, end_time):
        """
        Upper-bound downtime assumes the outage began immediately after
        the previous successful health check.

        If there is no previous healthy check, use the detection time.
        If the incident is unresolved, measure through end_time.
        """
        start = self.previous_healthy or self.detected_at
        end = self.recovered_at or end_time
        return end - start


# ---------------------------------------------------------------------------
# Log normalization
# ---------------------------------------------------------------------------

DATE_PREFIX = re.compile(r"^\d{4}-\d{2}-\d{2} " r"\d{2}:\d{2}:\d{2}\s+")

LEVEL_PREFIX = re.compile(r"^(INFO|WARN|ERROR)\s+")


def normalize_message(message: str) -> str:
    """
    Normalize old and new script output so duplicate stdout/logger
    messages compare cleanly.
    """
    message = message.strip()
    message = DATE_PREFIX.sub("", message)
    return message


def message_body(message: str) -> str:
    """
    Remove INFO/WARN/ERROR prefix from the revised logging format.
    """
    return LEVEL_PREFIX.sub("", normalize_message(message))


# ---------------------------------------------------------------------------
# Journal access
# ---------------------------------------------------------------------------


def read_journal(since=None, until=None):
    #
    # Include:
    #   - stdout/stderr from mullvad-health.service
    #   - manual executions recorded using logger -t mullvad-health
    #
    cmd = [
        "journalctl",
        "--no-pager",
        "-o",
        "json",
    ]

    if since:
        cmd.extend(["--since", since])

    if until:
        cmd.extend(["--until", until])

    cmd.extend(
        [
            "_SYSTEMD_UNIT=mullvad-health.service",
            "+",
            "SYSLOG_IDENTIFIER=mullvad-health",
        ]
    )

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(
            f"ERROR: journalctl failed:\n{result.stderr.strip()}",
            file=sys.stderr,
        )
        sys.exit(1)

    events = []

    for line in result.stdout.splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue

        message = record.get("MESSAGE")
        timestamp_raw = record.get("__REALTIME_TIMESTAMP")

        if not message or not timestamp_raw:
            continue

        try:
            timestamp = datetime.fromtimestamp(
                int(timestamp_raw) / 1_000_000,
                tz=timezone.utc,
            ).astimezone()
        except (ValueError, TypeError):
            continue

        events.append(
            Event(
                timestamp=timestamp,
                message=normalize_message(str(message)),
            )
        )

    events.sort(key=lambda e: e.timestamp)

    return deduplicate(events)


def deduplicate(events):
    """
    Old script versions logged the same event once through stdout and once
    through logger. Collapse matching messages occurring within two seconds.
    """
    result = []

    for event in events:
        body = message_body(event.message)

        duplicate = False

        for previous in reversed(result[-3:]):
            delta = abs((event.timestamp - previous.timestamp).total_seconds())

            if delta > 2:
                break

            if body == message_body(previous.message):
                duplicate = True
                break

        if not duplicate:
            result.append(event)

    return result


# ---------------------------------------------------------------------------
# Event classification
# ---------------------------------------------------------------------------


def is_health_start(body):
    return body.startswith("HEALTH: starting Mullvad health check") or body.startswith(
        "Starting Mullvad health check"
    )


def is_healthy(body):
    return (
        body.startswith("HEALTH: connection healthy")
        or body.startswith("Connection healthy")
        or body.startswith("CONNECT: healthy after")
        or body.startswith("Mullvad connected and healthy")
    )


def failure_reason(body):
    #
    # New logging format
    #
    if body.startswith("HEALTH: Mullvad reports disconnected"):
        return "Mullvad reported disconnected"

    if (
        body.startswith("HEALTH: Mullvad reports connected")
        and "tunnel health failed" in body
    ):
        return "Tunnel/Internet health check failed while connected"

    if body.startswith("HEALTH: unable to query Mullvad status"):
        return "Unable to query Mullvad status"

    #
    # Old logging format
    #
    if body.startswith("Mullvad is disconnected"):
        return "Mullvad reported disconnected"

    if (
        body.startswith("FAILOVER: Mullvad reports connected")
        and "Internet health check failed" in body
    ):
        return "Tunnel/Internet health check failed while connected"

    return None


# ---------------------------------------------------------------------------
# Incident reconstruction
# ---------------------------------------------------------------------------


def build_incidents(events):
    incidents = []

    last_healthy = None
    current_incident = None

    health_starts = []

    for event in events:
        body = message_body(event.message)

        if is_health_start(body):
            health_starts.append(event.timestamp)
            continue

        reason = failure_reason(body)

        if reason:
            #
            # Only the initial health failure opens an incident.
            #
            # Subsequent reconnect/failover messages belong to the same
            # incident and must not inflate the failure count.
            #
            if current_incident is None:
                current_incident = Incident(
                    reason=reason,
                    detected_at=event.timestamp,
                    previous_healthy=last_healthy,
                )

                incidents.append(current_incident)

            continue

        if is_healthy(body):
            if current_incident is not None:
                current_incident.recovered_at = event.timestamp
                current_incident = None

            last_healthy = event.timestamp

    return incidents, health_starts


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------


def format_duration(delta):
    seconds = max(0, int(delta.total_seconds()))

    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes, seconds = divmod(seconds, 60)

    parts = []

    if days:
        parts.append(f"{days}d")

    if hours or days:
        parts.append(f"{hours}h")

    if minutes or hours or days:
        parts.append(f"{minutes}m")

    parts.append(f"{seconds}s")

    return " ".join(parts)


def format_timestamp(value):
    return value.strftime("%Y-%m-%d %H:%M:%S %Z")


def timer_is_active():
    result = subprocess.run(
        [
            "systemctl",
            "is-active",
            "--quiet",
            "mullvad-health.timer",
        ]
    )

    return result.returncode == 0


def median_check_interval(health_starts):
    if len(health_starts) < 2:
        return None

    intervals = []

    for previous, current in zip(
        health_starts,
        health_starts[1:],
    ):
        seconds = (current - previous).total_seconds()

        #
        # Ignore large gaps caused by reboot, disabled timers, etc.
        #
        if 0 < seconds < 3600:
            intervals.append(seconds)

    if not intervals:
        return None

    return statistics.median(intervals)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


def summarize(events, incidents, health_starts, details=False):
    if not events:
        print("No Mullvad health log entries found.")
        return

    #
    # Prefer the first actual health check rather than a systemd
    # service-management message.
    #
    start_time = health_starts[0] if health_starts else events[0].timestamp

    active = timer_is_active()

    if active:
        end_time = datetime.now().astimezone()
    else:
        end_time = events[-1].timestamp

    runtime = end_time - start_time
    runtime_seconds = max(0, runtime.total_seconds())

    counts = Counter(incident.reason for incident in incidents)

    unresolved = [incident for incident in incidents if incident.recovered_at is None]

    #
    # Downtime is intentionally an upper-bound estimate.
    #
    # Each incident begins at the previous successful health check and
    # ends at the first subsequent healthy state.
    #
    downtime_seconds = sum(
        incident.upper_bound_downtime(end_time).total_seconds()
        for incident in incidents
    )

    #
    # Protect against pathological/incomplete logs.
    #
    downtime_seconds = max(
        0,
        min(downtime_seconds, runtime_seconds),
    )

    if runtime_seconds > 0:
        uptime_seconds = runtime_seconds - downtime_seconds

        reliability = (uptime_seconds / runtime_seconds) * 100.0
    else:
        uptime_seconds = 0
        reliability = 0.0

    print()
    print("Mullvad Health Summary")
    print("======================")
    print(
        f"Start time:             "
        f"{format_timestamp(start_time)} "
        f"(earliest retained health check)"
    )
    print(f"Total monitored time:   " f"{format_duration(runtime)}")
    print(f"Timer active:           " f"{'yes' if active else 'no'}")
    print(f"Health checks observed: " f"{len(health_starts)}")

    cadence = median_check_interval(health_starts)

    if cadence:
        print(
            f"Median check interval:  " f"{format_duration(timedelta(seconds=cadence))}"
        )

    print()
    print("Failures")
    print("--------")

    if not incidents:
        print("Total failures:         0")
    else:
        for reason, count in counts.most_common():
            print(f"{count:>4}  {reason}")

        print(f"\nTotal failures:         {len(incidents)}")

    if unresolved:
        print(f"Unresolved failures:    {len(unresolved)}")

    print()
    print("Reliability")
    print("-----------")
    print(
        f"Estimated downtime:     "
        f"{format_duration(timedelta(seconds=downtime_seconds))}"
    )
    print(
        f"Estimated uptime:       "
        f"{format_duration(timedelta(seconds=uptime_seconds))}"
    )
    print(f"Reliability:            " f"{reliability:.5f}%")

    print()
    print(
        "Downtime uses the upper-bound estimate: each outage is "
        "assumed to begin immediately after the previous successful "
        "health check and end at the first subsequent healthy result."
    )

    if details and incidents:
        print()
        print("Incidents")
        print("---------")

        for number, incident in enumerate(incidents, start=1):
            start = incident.previous_healthy or incident.detected_at

            end = incident.recovered_at or end_time

            downtime = end - start

            print()
            print(f"Incident {number}")
            print(f"  Reason:             {incident.reason}")

            if incident.previous_healthy:
                print(
                    f"  Last known healthy: "
                    f"{format_timestamp(incident.previous_healthy)}"
                )
            else:
                print(
                    f"  Failure detected:   "
                    f"{format_timestamp(incident.detected_at)}"
                )

            print(
                f"  Recovered:          "
                f"{format_timestamp(incident.recovered_at) if incident.recovered_at else 'UNRESOLVED'}"
            )

            print(f"  Est. downtime:      " f"{format_duration(downtime)}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Summarize Mullvad health-monitor failures, "
            "estimated downtime, and reliability."
        )
    )

    parser.add_argument(
        "--since",
        help='journalctl time expression, e.g. "7 days ago"',
    )

    parser.add_argument(
        "--until",
        help='journalctl time expression, e.g. "2026-09-24 00:00:00"',
    )

    parser.add_argument(
        "--details",
        action="store_true",
        help="show every reconstructed incident",
    )

    args = parser.parse_args()

    events = read_journal(
        since=args.since,
        until=args.until,
    )

    incidents, health_starts = build_incidents(events)

    summarize(
        events,
        incidents,
        health_starts,
        details=args.details,
    )


if __name__ == "__main__":
    main()
