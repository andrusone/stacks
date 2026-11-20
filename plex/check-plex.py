#!/usr/bin/env python3
"""Read-only health checks for the Plex host and its embedded plexcurator database."""

import argparse
import grp
import hashlib
import importlib.util
import json
import os
import re
import shlex
import shutil
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import pwd
from datetime import datetime, timezone
from pathlib import PurePosixPath
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit

from plexcurator import backup as curator_backup
from plexcurator import config as curator_config

LOCAL_FILESYSTEMS = {"ext2", "ext3", "ext4", "xfs", "btrfs"}
SMB_FILESYSTEMS = {"cifs", "smb3"}
BACKUP_MAX_AGE = 36 * 60 * 60
NAS_GROUP = "nas"
EXPECTED_BACKUP_TABLES = {
    "movie",
    "external_id",
    "source_record",
    "file",
    "format",
    "video_stream",
    "audio_stream",
    "subtitle_stream",
    "event",
    "watchlist",
    "issue",
    "deletion",
    "meta",
    "schema_migration",
}
APPDATA_MIN_FREE_BYTES = 1 << 30
APPDATA_MIN_FREE_PERCENT = 10
EXPECTED_LAN_NETWORKS = "10.10.0.0/16"
DEFAULT_APPDATA = (
    "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
)
DEFAULT_ALERT_FILE = "/var/lib/plexcurator/ALERT"
DEFAULT_RECEIPTS_LOG = "/var/lib/backup-receipts/receipts.jsonl"
DEFAULT_MARKER = os.environ.get(
    "ANDRUSONE_MARKER_PATH",
    os.path.join(
        os.environ.get("ANDRUSONE_ETC", "/etc"), "andrusone", "stacks", "plex"
    ),
)
DEFAULT_SHARES = (
    "/nas/plex",
    "/nas/home",
    "/nas/media",
    "/nas/projects",
    "/nas/cloud-backup",
    "/nas/local-backup",
)


def report(results, name, ok, detail="", warning=False):
    results.append((name, ok))
    status = "WARN" if warning else "PASS" if ok else "FAIL"
    print(f"{status}  {name}" + (f": {detail}" if detail else ""))


def report_warning(results, name, detail=""):
    results.append((name, None))
    print(f"WARN  {name}" + (f": {detail}" if detail else ""))


def run_command(*args):
    return subprocess.run(args, capture_output=True, text=True, timeout=10, check=False)


def mount_info(path):
    try:
        result = run_command("findmnt", "-n", "-o", "SOURCE,FSTYPE", "-T", str(path))
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)
    if result.returncode != 0:
        return (
            None,
            result.stderr.strip() or "findmnt could not identify the filesystem",
        )
    fields = result.stdout.strip().split(maxsplit=1)
    if len(fields) != 2:
        return None, "findmnt returned no source and filesystem type"
    return (fields[0], fields[1]), ""


def local_disk(path):
    info, error = mount_info(path)
    if info is None:
        return False, error
    source, fstype = info
    ok = source.startswith("/dev/") and fstype in LOCAL_FILESYSTEMS
    return ok, f"{source} ({fstype})"


def read_directory_as_user(path, service_user):
    reader = (
        "import os, sys\n"
        "try:\n"
        " with os.scandir(sys.argv[1]) as entries:\n"
        "  next(entries, None)\n"
        "except OSError as error:\n"
        " print(error, file=sys.stderr); raise SystemExit(1)\n"
    )
    try:
        result = run_command(
            "runuser",
            "-u",
            service_user,
            "--",
            "python3",
            "-c",
            reader,
            str(path),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, str(error)
    if result.returncode != 0:
        return False, result.stderr.strip() or "cannot read directory as service user"
    return True, ""


def backup_nas(path, service_user=None):
    if service_user:
        readable, error = read_directory_as_user(path, service_user)
        if not readable:
            return False, error
    info, error = mount_info(path)
    if info is None:
        return False, error
    source, fstype = info
    ok = fstype in SMB_FILESYSTEMS and source.startswith("//")
    return ok, f"{source} ({fstype})"


def _newest_backup(path, now=None):
    directory = Path(path)
    try:
        backups = [
            p
            for p in directory.glob("plexcurator-*.tar.gz")
            if p.is_file() and not p.is_symlink()
        ]
    except OSError as error:
        return None, None, f"cannot read backup directory: {error}"
    if not backups:
        return None, None, "no plexcurator recovery bundle found"
    try:
        newest = max(backups, key=lambda p: p.stat().st_mtime)
        modified = newest.stat().st_mtime
        age = (time.time() if now is None else now) - modified
    except OSError as error:
        return None, None, f"cannot stat newest backup: {error}"
    if age < 0 or age >= BACKUP_MAX_AGE:
        return newest, modified, f"newest backup is {age / 3600:.1f} hours old"
    return newest, modified, ""


def _validate_bundle(path, expected_tables, local_dir):
    try:
        with tempfile.TemporaryDirectory(
            prefix="plex-backup-check-", dir=local_dir
        ) as temp_dir:
            with tarfile.open(path, "r:gz") as archive:
                members = {}
                for member in archive.getmembers():
                    name = PurePosixPath(member.name)
                    if (
                        name.is_absolute()
                        or ".." in name.parts
                        or not member.isfile()
                        or member.name in members
                    ):
                        return False, "backup bundle contains an unsafe member"
                    members[member.name] = member
                database = members.get("plexcurator.db")
                if database is None:
                    return False, "backup bundle is missing the plexcurator database"
                if "plex-config/Preferences.xml" not in members:
                    return False, "backup bundle is missing Plex Preferences.xml"
                library_databases = [
                    member
                    for name, member in members.items()
                    if re.fullmatch(
                        r"plex-config/Plug-in Support/Databases/"
                        r"com\.plexapp\.plugins\.library\.db-\d{4}-\d{2}-\d{2}",
                        name,
                    )
                ]
                if len(library_databases) > 1:
                    return (
                        False,
                        "backup bundle contains multiple Plex library database snapshots",
                    )
                stream = archive.extractfile(database)
                if stream is None:
                    return False, "backup bundle database cannot be read"
                local_copy = Path(temp_dir) / "plexcurator.db"
                with local_copy.open("wb") as target:
                    shutil.copyfileobj(stream, target)
                library_copy = None
                library_member = None
                if library_databases:
                    library_member = library_databases[0]
                    stream = archive.extractfile(library_member)
                    if stream is None:
                        return (
                            False,
                            f"{library_member.name}: Plex library database snapshot cannot be read",
                        )
                    library_copy = Path(temp_dir) / "plex-library.db"
                    with library_copy.open("wb") as target:
                        shutil.copyfileobj(stream, target)
            if local_copy.stat().st_size == 0:
                return False, "newest backup database is empty"
            try:
                uri = local_copy.resolve().as_uri() + "?mode=ro"
                connection = sqlite3.connect(uri, uri=True, timeout=5)
            except (OSError, sqlite3.Error, ValueError) as error:
                return (
                    False,
                    f"newest backup database cannot be opened read-only: {error}",
                )
            try:
                integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
                tables = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type='table'"
                    ).fetchall()
                }
            except sqlite3.Error as error:
                return False, f"newest backup database cannot be checked: {error}"
            finally:
                connection.close()
            if library_copy:
                try:
                    curator_backup.verify_plex_library_snapshot(
                        library_copy, expected_size=library_member.size
                    )
                except (OSError, sqlite3.Error, RuntimeError, ValueError) as error:
                    return (
                        False,
                        f"{library_member.name}: size, page metadata, or read-only "
                        f"query check failed: {error}",
                    )
    except (OSError, tarfile.TarError) as error:
        return False, f"cannot read newest backup bundle: {error}"
    if integrity != "ok":
        return False, f"newest backup database integrity_check is {integrity}"
    missing = sorted(expected_tables - tables)
    if missing:
        return (
            False,
            f"newest backup database is missing expected tables: {', '.join(missing)}",
        )
    return True, ""


def latest_backup_info(path, now=None, local_dir=None):
    newest, modified, error = _newest_backup(path, now)
    if error:
        return False, error, newest
    age = (time.time() if now is None else now) - modified
    if age < 0 or age >= BACKUP_MAX_AGE:
        return False, f"newest backup is {age / 3600:.1f} hours old", newest
    valid, detail = _validate_bundle(newest, EXPECTED_BACKUP_TABLES, local_dir)
    if not valid:
        return False, detail, newest
    last_good_backup = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(modified))
    return (
        True,
        f"last good backup at {last_good_backup}; recovery bundle opens read-only and "
        f"contains all {len(EXPECTED_BACKUP_TABLES)} expected tables; "
        f"{age / 3600:.1f} hours old",
        newest,
    )


def latest_backup(path, now=None, local_dir=None):
    ok, detail, _ = latest_backup_info(path, now, local_dir)
    return ok, detail


def _file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as artifact:
        for chunk in iter(lambda: artifact.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def latest_backup_receipt(path, artifact_path, host=None):
    receipt_file = Path(path)
    try:
        lines = receipt_file.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        return False, f"cannot read backup receipt log: {error}", False
    short_host = (host or socket.gethostname()).split(".", 1)[0]
    matches = []
    try:
        for index, line in enumerate(lines):
            if not line.strip():
                continue
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("receipt line is not a JSON object")
            if (
                record.get("type") == "backup"
                and record.get("host") == short_host
                and record.get("stack") == "plex"
                and record.get("archive_class") == "local"
            ):
                ts = record.get("ts")
                if not isinstance(ts, str):
                    raise ValueError("receipt timestamp is not a string")
                timestamp = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if timestamp.utcoffset() is None:
                    raise ValueError("receipt timestamp has no timezone")
                timestamp = timestamp.astimezone(timezone.utc)
                matches.append((timestamp, index, record))
    except (
        AttributeError,
        json.JSONDecodeError,
        KeyError,
        TypeError,
        ValueError,
    ) as error:
        return False, f"backup receipt log contains an invalid record: {error}", False
    if not matches:
        return False, "no Plex local-backup receipt found for this host", False
    _, _, latest = max(matches, key=lambda item: (item[0], item[1]))
    if latest.get("result") != "ok":
        return False, "latest Plex local-backup receipt reports failure", False
    if artifact_path is None:
        return False, "no recovery bundle is available for the latest receipt", False
    recorded_path = latest.get("artifact_path")
    if not isinstance(recorded_path, str) or os.path.abspath(
        recorded_path
    ) != os.path.abspath(os.fspath(artifact_path)):
        return (
            False,
            "latest Plex local-backup receipt does not match the newest bundle",
            False,
        )
    try:
        size = os.path.getsize(artifact_path)
        digest = _file_sha256(artifact_path)
    except OSError as error:
        return False, f"cannot verify backup receipt artifact: {error}", False
    if latest.get("bytes") != size or latest.get("sha256") != digest:
        return (
            False,
            "latest Plex local-backup receipt size or SHA-256 does not match",
            False,
        )
    warning = latest.get("warning", "")
    if not isinstance(warning, str):
        return False, "latest Plex local-backup receipt warning is invalid", False
    detail = "latest Plex local-backup receipt matches the newest bundle"
    if warning:
        detail += f"; warning: {warning}"
    return True, detail, bool(warning)


def appdata_space(path, statvfs=os.statvfs):
    try:
        stats = statvfs(path)
    except OSError as error:
        return False, f"cannot read appdata filesystem space: {error}"
    total = stats.f_blocks * stats.f_frsize
    free = stats.f_bavail * stats.f_frsize
    percent = 100 * free / total if total else 0
    ok = free >= APPDATA_MIN_FREE_BYTES and percent >= APPDATA_MIN_FREE_PERCENT
    detail = f"{free / (1 << 30):.1f} GiB free ({percent:.1f}%)"
    return ok, detail


def installed_schema(install_dir):
    version_path = Path(install_dir) / "plexcurator" / "version.py"
    spec = importlib.util.spec_from_file_location(
        "_plexcurator_installed_version", version_path
    )
    if spec is None or spec.loader is None:
        raise ImportError("installed version.py could not be loaded")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    schema = getattr(module, "SCHEMA_VERSION", None)
    if not isinstance(schema, int) or schema < 1:
        raise ValueError("installed SCHEMA_VERSION is invalid")
    return schema


def database_checks(path, expected_schema, results):
    db_path = Path(path)
    try:
        uri = db_path.resolve().as_uri() + "?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=5)
    except (OSError, sqlite3.Error, ValueError) as error:
        report(results, "database opens read-only", False, str(error))
        report(
            results,
            "database integrity_check is ok",
            False,
            "database could not be opened",
        )
        report(
            results,
            "database schema version matches installed code",
            False,
            "database could not be opened",
        )
        return
    try:
        try:
            connection.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchall()
        except sqlite3.Error as error:
            report(results, "database opens read-only", False, str(error))
            report(
                results,
                "database integrity_check is ok",
                False,
                "database could not be read",
            )
            report(
                results,
                "database schema version matches installed code",
                False,
                "database could not be read",
            )
            return
        report(results, "database opens read-only", True)
        try:
            integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
            report(
                results,
                "database integrity_check is ok",
                integrity == "ok",
                str(integrity),
            )
        except sqlite3.Error as error:
            report(results, "database integrity_check is ok", False, str(error))
        try:
            version = connection.execute("PRAGMA user_version").fetchone()[0]
            ok = expected_schema is not None and version == expected_schema
            detail = (
                f"database {version}, code {expected_schema}"
                if expected_schema is not None
                else f"database {version}, code unavailable"
            )
            report(
                results, "database schema version matches installed code", ok, detail
            )
        except sqlite3.Error as error:
            report(
                results,
                "database schema version matches installed code",
                False,
                str(error),
            )
    finally:
        connection.close()


def check_preferences(appdata, results):
    path = Path(appdata) / "Preferences.xml"
    try:
        attributes = ET.parse(path).getroot().attrib
    except (OSError, ET.ParseError) as error:
        report(results, "Plex Preferences.xml is readable", False, str(error))
        report(
            results,
            "Plex Remote Access is disabled",
            False,
            "preferences could not be read",
        )
        report(
            results,
            "Plex LAN Networks match documented range",
            False,
            "preferences could not be read",
        )
        return
    report(results, "Plex Preferences.xml is readable", True)
    remote_access = attributes.get("PublishServerOnPlexOnlineKey")
    report(
        results,
        "Plex Remote Access is disabled",
        remote_access == "0",
        f"PublishServerOnPlexOnlineKey={remote_access!r}",
    )
    networks = attributes.get("LanNetworksBandwidth")
    report(
        results,
        "Plex LAN Networks match documented range",
        networks == EXPECTED_LAN_NETWORKS,
        f"LanNetworksBandwidth={networks!r}",
    )


def service_active(unit, results):
    try:
        result = run_command("systemctl", "is-active", "--quiet", unit)
    except (OSError, subprocess.TimeoutExpired) as error:
        report(results, f"{unit} active", False, str(error))
        return
    report(results, f"{unit} active", result.returncode == 0)


def oneshot_succeeded(unit, results):
    properties = {}
    for prop in ("Result", "ExecMainStatus", "ExecMainExitTimestamp"):
        try:
            result = run_command(
                "systemctl", "show", f"--property={prop}", "--value", unit
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            report(results, f"{unit} last run succeeded", False, str(error))
            return
        if result.returncode != 0:
            report(
                results,
                f"{unit} last run succeeded",
                False,
                result.stderr.strip() or "systemctl show failed",
            )
            return
        properties[prop] = result.stdout.strip()
    ok = (
        properties["Result"] == "success"
        and properties["ExecMainStatus"] == "0"
        and properties["ExecMainExitTimestamp"] not in ("", "n/a", "-")
    )
    if (
        unit == "plexcurator.service"
        and properties["Result"] == "exit-code"
        and properties["ExecMainStatus"] == "2"
    ):
        report(
            results,
            f"{unit} last run succeeded",
            True,
            "alert raised (exit 2)",
            warning=True,
        )
        return
    report(
        results,
        f"{unit} last run succeeded",
        ok,
        f"Result={properties['Result']}, ExecMainStatus={properties['ExecMainStatus']}",
    )


def alert_file_status(path, policy, results):
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        report(results, "plexcurator alert file is clear", True)
        return
    except (OSError, UnicodeError) as error:
        report(results, "plexcurator alert file is readable", False, str(error))
        return
    if not any(line.strip() for line in lines):
        report(results, "plexcurator alert file is clear", True)
    elif policy == "warn" and all("[WARN:unidentified] " in line for line in lines):
        report_warning(
            results,
            "plexcurator has unidentified movies",
            "configured as a warning; details are in the alert file",
        )
    else:
        report(
            results,
            "plexcurator alert file is clear",
            False,
            "an error or unclassified alert is present",
        )


def timer_active(unit, results):
    service_active(unit, results)
    try:
        result = run_command("systemctl", "is-enabled", "--quiet", unit)
    except (OSError, subprocess.TimeoutExpired) as error:
        report(results, f"{unit} enabled", False, str(error))
        return
    report(results, f"{unit} enabled", result.returncode == 0)


def kometa_declared(marker_path, results):
    try:
        lines = Path(marker_path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return False
    except (OSError, UnicodeError) as error:
        report(results, "Plex stack marker is readable", False, str(error))
        return False

    values = []
    try:
        for line in lines:
            if line.startswith("COMPONENTS="):
                assignments = shlex.split(line, comments=True)
                if len(assignments) != 1 or "=" not in assignments[0]:
                    raise ValueError("invalid COMPONENTS marker entry")
                values.append(assignments[0].split("=", 1)[1])
    except ValueError as error:
        report(results, "Plex stack component marker is valid", False, str(error))
        return False
    if len(values) > 1:
        report(
            results,
            "Plex stack component marker is valid",
            False,
            "duplicate COMPONENTS entries",
        )
        return False
    return bool(values and "kometa" in values[0].split(","))


def check_kometa_user(results):
    try:
        pwd.getpwnam("kometa")
    except KeyError:
        report(results, "Kometa service user exists", False, "user kometa is missing")
    else:
        report(results, "Kometa service user exists", True)


def check_kometa_config(path, results):
    try:
        if os.path.islink(path):
            raise OSError("config path is a symlink")
        info = os.stat(path, follow_symlinks=False)
        group = grp.getgrnam("kometa")
    except (KeyError, OSError) as error:
        report(results, "Kometa config permissions are safe", False, str(error))
        return
    mode = stat.S_IMODE(info.st_mode)
    ok = (
        stat.S_ISREG(info.st_mode)
        and info.st_uid == 0
        and info.st_gid == group.gr_gid
        and not mode & stat.S_IROTH
    )
    report(
        results,
        "Kometa config permissions are safe",
        ok,
        (
            ""
            if ok
            else "config must be a regular root:kometa file without world-read permission"
        ),
    )


def kometa_service_recently_succeeded(unit, results, now=None):
    properties = {}
    for prop in ("Result", "ExecMainStatus", "ExecMainExitTimestamp"):
        try:
            result = run_command(
                "systemctl", "show", f"--property={prop}", "--value", unit
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            report(
                results, "Kometa service succeeded within 48 hours", False, str(error)
            )
            return
        if result.returncode != 0:
            report(
                results,
                "Kometa service succeeded within 48 hours",
                False,
                result.stderr.strip() or "systemctl show failed",
            )
            return
        properties[prop] = result.stdout.strip()

    ok = properties["Result"] == "success" and properties["ExecMainStatus"] == "0"
    timestamp = properties["ExecMainExitTimestamp"]
    try:
        fields = timestamp.split()
        zone = ""
        if len(fields) >= 3 and re.fullmatch(r"\d{4}-\d{2}-\d{2}", fields[-3]):
            date_time = fields[-3:-1]
            zone = fields[-1]
        elif len(fields) >= 2 and re.fullmatch(r"\d{4}-\d{2}-\d{2}", fields[-2]):
            date_time = fields[-2:]
        else:
            raise ValueError("systemd returned no service completion timestamp")
        completed_at = datetime.strptime(" ".join(date_time), "%Y-%m-%d %H:%M:%S")
        if zone in ("UTC", "GMT"):
            completed_at = completed_at.replace(tzinfo=timezone.utc)
        else:
            completed_at = completed_at.astimezone()
        age_seconds = (time.time() if now is None else now) - completed_at.timestamp()
        ok = ok and 0 <= age_seconds < 48 * 60 * 60
    except (OverflowError, ValueError):
        age_seconds = None
        ok = False
    detail = (
        f"last run was {age_seconds / 3600:.1f} hours ago"
        if age_seconds is not None
        else "completion timestamp is unavailable or invalid"
    )
    if properties["Result"] != "success" or properties["ExecMainStatus"] != "0":
        detail = (
            f"Result={properties['Result']}, "
            f"ExecMainStatus={properties['ExecMainStatus']}"
        )
    report(results, "Kometa service succeeded within 48 hours", ok, detail)


def configured_service_user(results):
    try:
        result = run_command(
            "systemctl",
            "show",
            "--property=User",
            "--value",
            "plexcurator.service",
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        report(results, "plexcurator service user is configured", False, str(error))
        return None
    user = result.stdout.strip()
    ok = result.returncode == 0 and bool(user)
    report(
        results,
        "plexcurator service user is configured",
        ok,
        user if ok else result.stderr.strip() or "systemd returned no service user",
    )
    return user if ok else None


def nas_write_access(path, service_user):
    try:
        groups = run_command("id", "-nG", service_user)
        group = run_command("getent", "group", NAS_GROUP)
        options = run_command("findmnt", "-n", "-o", "OPTIONS", "-T", str(path))
    except (OSError, subprocess.TimeoutExpired) as error:
        return False, f"cannot check NAS group or mount modes: {error}"
    if groups.returncode != 0:
        return False, f"cannot read groups for service user {service_user}"
    if group.returncode != 0:
        return False, f"cannot determine the {NAS_GROUP} group ID"
    if options.returncode != 0:
        return False, "cannot read NAS mount modes"

    group_fields = group.stdout.strip().split(":")
    if len(group_fields) < 3 or not group_fields[2].isdigit():
        return False, f"cannot determine the {NAS_GROUP} group ID"
    nas_gid = group_fields[2]
    mount_options = dict(
        field.split("=", 1)
        for field in options.stdout.strip().split(",")
        if "=" in field
    )
    mount_gid = mount_options.get("gid", "")
    directory_mode = mount_options.get("dir_mode", "0755")
    try:
        mode = int(directory_mode, 8)
    except ValueError:
        mode = 0

    causes = []
    if NAS_GROUP not in groups.stdout.split():
        causes.append(f"{service_user} is not in group {NAS_GROUP}")
    if mount_gid not in (NAS_GROUP, nas_gid):
        causes.append(f"mount gid is {mount_gid or 'unset'}, not {NAS_GROUP}")
    if (mode & 0o030) != 0o030:
        causes.append(
            f"mount dir_mode={directory_mode} does not grant group write and search"
        )
    details = f"mount gid={mount_gid or 'unset'}, dir_mode={directory_mode}"
    if causes:
        repair = f"mount-nas.sh --add-user {shlex.quote(service_user)}"
        return (
            False,
            f"likely cause: {'; '.join(causes)}; check NAS mount modes "
            f"(mount gid={mount_gid or 'unset'}, dir_mode={directory_mode}; "
            f"expected gid={NAS_GROUP} and group-writable dir_mode such as 0775). "
            f"Fix group membership with: {repair}",
        )
    return True, f"service user is in {NAS_GROUP}; {details} grants group write"


def plex_port_answers(url, results):
    if not isinstance(url, str):
        report(
            results,
            "Plex TCP port 32400 answers",
            False,
            "Plex URL is missing or invalid in config",
        )
        return
    try:
        parsed = urlsplit(url)
        port = parsed.port
        ok = bool(parsed.hostname) and port == 32400
    except ValueError:
        parsed = None
        ok = False
    if not ok:
        report(
            results,
            "Plex TCP port 32400 answers",
            False,
            "configured Plex URL must identify port 32400",
        )
        return
    try:
        with socket.create_connection((parsed.hostname, port), timeout=3):
            pass
    except OSError as error:
        report(results, "Plex TCP port 32400 answers", False, str(error))
        return
    report(results, "Plex TCP port 32400 answers", True)


def check_share(path, service_user, results):
    label = (
        f"NAS share {path} is mounted and readable by "
        f"{service_user or 'plexcurator service user'}"
    )
    if service_user is None:
        report(results, label, False, "service user could not be determined")
        report(
            results,
            f"NAS share {path} is writable by plexcurator service user",
            False,
            "service user could not be determined",
        )
        return
    readable, read_error = read_directory_as_user(path, service_user)
    if not readable:
        report(
            results,
            label,
            False,
            read_error,
        )
        report(
            results,
            f"NAS share {path} is writable by plexcurator service user",
            False,
            read_error,
        )
        return
    info, error = mount_info(path)
    mounted = (
        info is not None and info[1] in SMB_FILESYSTEMS and info[0].startswith("//")
    )
    ok = mounted
    detail = error or (f"{info[0]} ({info[1]})" if info else "not mounted")
    if info is not None and info[1] == "autofs":
        detail = f"{info[0]} (autofs did not resolve to SMB after service-user read)"
    report(results, label, ok, detail)
    write_check = f"NAS share {path} is writable by plexcurator service user"
    if not mounted:
        report(results, write_check, False, "NAS share is not mounted")
    else:
        writable, write_detail = nas_write_access(path, service_user)
        report(results, write_check, writable, write_detail)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True)
    parser.add_argument("--install-dir", required=True)
    parser.add_argument("--appdata", default=DEFAULT_APPDATA)
    parser.add_argument(
        "--backup-receipts",
        default=os.environ.get("BACKUP_RECEIPTS_LOG", DEFAULT_RECEIPTS_LOG),
    )
    parser.add_argument("--marker", default=DEFAULT_MARKER)
    parser.add_argument("--kometa-config", default="/etc/kometa/config.yml")
    parser.add_argument("--share", action="append", default=[])
    args = parser.parse_args(argv)
    results = []
    shares = args.share or list(DEFAULT_SHARES)

    try:
        config = curator_config.load(args.config)
    except (
        OSError,
        tomllib.TOMLDecodeError,
        TypeError,
        KeyError,
        AttributeError,
    ) as error:
        config = None
        report(results, "plexcurator config is readable", False, str(error))
    else:
        report(results, "plexcurator config is readable", True)

    def configured_string(section, key):
        section_value = config.get(section) if config is not None else None
        value = section_value.get(key) if isinstance(section_value, dict) else None
        return value if isinstance(value, str) and value.strip() else None

    plex_url = configured_string("plex", "url")
    db_path = configured_string("advanced", "db_path")
    backup_dir = configured_string("storage", "backup_dir")
    settings_valid = all((plex_url, db_path, backup_dir))
    report(
        results,
        "required Plex health-check config values are valid",
        settings_valid,
        (
            ""
            if settings_valid
            else "plex.url, advanced.db_path, and storage.backup_dir must be non-empty strings"
        ),
    )
    alert_policy = config.get("alert_unidentified") if config is not None else None
    if alert_policy is None and config is not None:
        alert_policy = "warn"
    policy_valid = alert_policy in ("warn", "fail")
    report(
        results,
        "unidentified-movie alert policy is valid",
        policy_valid,
        str(alert_policy) if policy_valid else "must be 'warn' or 'fail'",
    )
    if config is not None:
        advanced = config.get("advanced")
        alert_file = (
            advanced.get("alert_file", DEFAULT_ALERT_FILE)
            if isinstance(advanced, dict)
            else DEFAULT_ALERT_FILE
        )
        if isinstance(alert_file, str) and alert_file.strip():
            alert_file_status(alert_file, alert_policy, results)
        else:
            report(
                results,
                "plexcurator alert file path is valid",
                False,
                "advanced.alert_file must be a non-empty string",
            )
    plex_port_answers(plex_url, results)
    service_active("plexmediaserver", results)
    check_preferences(args.appdata, results)
    service_user = configured_service_user(results)

    for share in shares:
        check_share(share, service_user, results)

    appdata_ok, appdata_detail = local_disk(args.appdata)
    report(results, "Plex appdata is on a local disk", appdata_ok, appdata_detail)
    space_ok, space_detail = appdata_space(args.appdata)
    report(
        results, "Plex appdata has at least 10% and 1 GiB free", space_ok, space_detail
    )

    if db_path:
        db_local, db_detail = local_disk(db_path)
        report(results, "plexcurator database is on a local disk", db_local, db_detail)
    else:
        report(
            results,
            "plexcurator database is on a local disk",
            False,
            "advanced.db_path is missing or invalid",
        )

    expected_schema = None
    try:
        expected_schema = installed_schema(args.install_dir)
    except (ImportError, OSError, ValueError, SyntaxError) as error:
        report(
            results,
            "installed plexcurator schema version is available",
            False,
            str(error),
        )
    else:
        report(
            results,
            "installed plexcurator schema version is available",
            True,
            str(expected_schema),
        )

    if db_path:
        database_checks(db_path, expected_schema, results)
    else:
        report(
            results,
            "database opens read-only",
            False,
            "advanced.db_path is missing or invalid",
        )
        report(
            results,
            "database integrity_check is ok",
            False,
            "advanced.db_path is missing or invalid",
        )
        report(
            results,
            "database schema version matches installed code",
            False,
            "advanced.db_path is missing or invalid",
        )

    if backup_dir:
        on_nas, nas_detail = backup_nas(backup_dir, service_user)
        report(
            results,
            "plexcurator backup directory is mounted on the NAS",
            on_nas,
            nas_detail,
        )
        local_dir = Path(db_path).resolve().parent if db_path else None
        recent, recent_detail, newest = latest_backup_info(
            backup_dir, local_dir=local_dir
        )
        report(
            results,
            "newest Plex recovery bundle is younger than 36 hours",
            recent,
            recent_detail,
        )
        receipt_ok, receipt_detail, receipt_warning = latest_backup_receipt(
            args.backup_receipts, newest
        )
        report(
            results,
            "latest Plex local-backup receipt matches the newest bundle",
            receipt_ok,
            receipt_detail,
            warning=receipt_warning,
        )
    else:
        report(
            results,
            "plexcurator backup directory is mounted on the NAS",
            False,
            "storage.backup_dir is missing or invalid",
        )
        report(
            results,
            "newest Plex recovery bundle is younger than 36 hours",
            False,
            "storage.backup_dir is missing or invalid",
        )
        report(
            results,
            "latest Plex local-backup receipt matches the newest bundle",
            False,
            "storage.backup_dir is missing or invalid",
        )

    oneshot_succeeded("plexcurator.service", results)
    oneshot_succeeded("plexcurator-backup.service", results)
    timer_active("plexcurator.timer", results)
    timer_active("plexcurator-backup.timer", results)
    if kometa_declared(args.marker, results):
        check_kometa_user(results)
        timer_active("kometa.timer", results)
        kometa_service_recently_succeeded("kometa.service", results)
        check_kometa_config(args.kometa_config, results)
    return 1 if any(ok is False for _, ok in results) else 0


if __name__ == "__main__":
    sys.exit(main())
