"""Alerts: warning/error log lines + an alert file (present only while something needs a human)."""

import logging
import os
import time

log = logging.getLogger("plexcurator")


def collect(conn):
    """Standing conditions that need a human, from the database."""
    msgs = []
    rows = conn.execute(
        """SELECT m.title, f.path FROM movie m LEFT JOIN file f ON f.movie_id = m.id
                           WHERE m.unidentified = 1 AND m.state = 'present' ORDER BY m.id"""
    ).fetchall()
    if rows:
        sample = "; ".join(
            f"{r['title'] or '?'} ({r['path'] or 'no file'})" for r in rows[:5]
        )
        msgs.append(
            f"{len(rows)} movie(s) are unidentified (no TMDB/IMDb id) and will never be moved, renamed or deleted "
            f"until you fix the match in Plex or add a {{tmdb-N}} tag to the file name: {sample}"
            + (" ..." if len(rows) > 5 else "")
        )
    return msgs


def publish(cfg, errors=(), warnings=()):
    """Write alerts and return 2 only when at least one error alert is present."""
    path = cfg["advanced"]["alert_file"]
    warnings = list(warnings)
    errors = list(errors)
    for m in warnings:
        log.warning("ALERT: %s", m)
    for m in errors:
        log.error("ALERT: %s", m)
    try:
        if warnings or errors:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as fh:
                for level, messages in (
                    ("WARN:unidentified", warnings),
                    ("ERROR", errors),
                ):
                    for message in messages:
                        fh.write(f"{time.strftime('%F %T')} [{level}] {message}\n")
        elif os.path.exists(path):
            os.remove(path)
    except OSError as e:
        log.error("could not update alert file %s: %s", path, e)
        return 2 if errors else 1
    return 2 if errors else 0
