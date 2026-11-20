"""Consistent SQLite backup (online backup API), verified, rotated.

SQLite is never opened on the backup directory: that is normally an SMB share, and SQLite's locking and
journal files are not reliable there (a backup came out as an empty file that still passed
integrity_check). The copy is made on local disk next to the database, checked there, then copied to the
share as a plain file, compared byte for byte, and only then given its final name.
"""

import hashlib
import json
import os
import re
import shutil
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import date, datetime, timezone
from pathlib import Path

DEFAULT_PLEX_APPDATA = (
    "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
)
DEFAULT_KOMETA_CONFIG = "/etc/kometa/config.yml"
DEFAULT_KOMETA_COLLECTIONS = "/etc/kometa/collections"


def _tables(conn):
    return conn.execute(
        "SELECT count(*) FROM sqlite_master WHERE type='table'"
    ).fetchone()[0]


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def verify_plex_library_snapshot(path, expected_size=None, expected_sha256=None):
    size = os.path.getsize(path)
    if expected_size is not None and size != expected_size:
        raise RuntimeError(f"size mismatch: got {size} bytes, expected {expected_size}")
    if expected_sha256 is not None and _sha256(path) != expected_sha256:
        raise RuntimeError("SHA-256 mismatch")

    uri = Path(path).resolve().as_uri() + "?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=5)
    try:
        page_size = connection.execute("PRAGMA page_size").fetchone()[0]
        page_count = connection.execute("PRAGMA page_count").fetchone()[0]
        required_size = page_size * page_count
        if page_size <= 0 or page_count <= 0 or size < required_size:
            raise RuntimeError(
                f"truncated or invalid SQLite page metadata: "
                f"{size} bytes for {page_count} pages of {page_size} bytes"
            )
        table = connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' AND sql IS NOT NULL "
            "AND upper(sql) NOT LIKE 'CREATE VIRTUAL TABLE%' "
            "ORDER BY name LIMIT 1"
        ).fetchone()
        if table is None:
            raise RuntimeError("no ordinary SQLite table is available for a read check")
        name = table[0].replace('"', '""')
        connection.execute(f'SELECT 1 FROM "{name}" LIMIT 1').fetchone()
    finally:
        connection.close()


def _create_database_snapshot(db_path, staged):
    src = sqlite3.connect(db_path)
    try:
        schema = src.execute("PRAGMA user_version").fetchone()[0]
        want_tables = _tables(src)
        dst = sqlite3.connect(staged)
        try:
            src.backup(dst)
            ok = dst.execute("PRAGMA integrity_check").fetchone()[0]
            got_tables = _tables(dst)
            got_schema = dst.execute("PRAGMA user_version").fetchone()[0]
        finally:
            dst.close()
    finally:
        src.close()
    if ok != "ok":
        raise RuntimeError(f"backup failed integrity check: {ok}")
    if got_tables != want_tables or got_schema != schema or want_tables == 0:
        raise RuntimeError(
            f"backup is incomplete: {got_tables} of {want_tables} tables, schema {got_schema} (want {schema})"
        )
    return schema, want_tables


def _copy_verified(staged, destination, backup_dir, mode=None):
    part = destination + ".part"
    try:
        os.makedirs(backup_dir, exist_ok=True)
        with open(staged, "rb") as fin, open(part, "wb") as fout:
            shutil.copyfileobj(fin, fout, 1 << 20)
            fout.flush()
            os.fsync(fout.fileno())
        if mode is not None:
            os.chmod(part, mode)
        if os.path.getsize(part) != os.path.getsize(staged) or _sha256(part) != _sha256(
            staged
        ):
            raise RuntimeError(
                f"copy to {backup_dir} does not match the original; not kept"
            )
        os.replace(part, destination)
        if mode is not None:
            os.chmod(destination, mode)
    finally:
        try:
            os.remove(part)
        except FileNotFoundError:
            pass


def _require_nas_mount(backup_dir):
    try:
        result = subprocess.run(
            ["findmnt", "-n", "-o", "SOURCE,FSTYPE", "-T", backup_dir],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(
            f"cannot verify backup destination mount: {error}"
        ) from error
    fields = result.stdout.strip().split(maxsplit=1)
    if result.returncode != 0 or len(fields) != 2:
        detail = result.stderr.strip() or "findmnt returned no mount information"
        raise RuntimeError(f"cannot verify backup destination mount: {detail}")
    source, filesystem = fields
    if filesystem not in ("cifs", "smb3") or not source.startswith("//"):
        raise RuntimeError(
            f"backup destination is not a mounted SMB share: {source} ({filesystem})"
        )


def _prepare_nas_backup_dir(backup_dir):
    mount_target = backup_dir
    while not os.path.exists(mount_target):
        parent = os.path.dirname(mount_target)
        if parent == mount_target:
            raise RuntimeError("backup destination has no existing parent directory")
        mount_target = parent
    _require_nas_mount(mount_target)
    os.makedirs(backup_dir, exist_ok=True)
    _require_nas_mount(backup_dir)


def _rotate(backup_dir, pattern, keep):
    old = sorted(
        f
        for f in os.listdir(backup_dir)
        if f.startswith(pattern[0]) and f.endswith(pattern[1])
    )[:-keep]
    for name in old:
        os.remove(os.path.join(backup_dir, name))


def backup(db_path, backup_dir, keep=14, now=None):
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now or time.time()))
    fd, staged = tempfile.mkstemp(
        prefix=".backup-", suffix=".db", dir=os.path.dirname(os.path.abspath(db_path))
    )
    os.close(fd)
    try:
        schema, _ = _create_database_snapshot(db_path, staged)
        dest = os.path.join(backup_dir, f"plexcurator-{stamp}-schema{schema}.db")
        _copy_verified(staged, dest, backup_dir)
    finally:
        try:
            os.remove(staged)
        except FileNotFoundError:
            pass
    _rotate(backup_dir, ("plexcurator-", ".db"), keep)
    return dest


def _copy_stable_file(source, staged, description):
    if os.path.islink(source) or not os.path.isfile(source):
        raise RuntimeError(f"{description} is not a regular file")
    before = os.stat(source, follow_symlinks=False)
    shutil.copyfile(source, staged)
    after = os.stat(source, follow_symlinks=False)
    source_sha256 = _sha256(source)
    staged_sha256 = _sha256(staged)
    if (
        before.st_size != after.st_size
        or before.st_mtime_ns != after.st_mtime_ns
        or source_sha256 != staged_sha256
    ):
        raise RuntimeError(f"{description} changed while staging")
    return before.st_size, source_sha256


def _config_files(config_dir, stage_dir):
    root = os.path.abspath(config_dir)
    preferences = os.path.join(root, "Preferences.xml")
    if not os.path.isfile(preferences) or os.path.islink(preferences):
        raise RuntimeError("Plex Preferences.xml is unavailable")
    copies = []
    library_signatures = {}
    staged_preferences = os.path.join(stage_dir, "Preferences.xml")
    _copy_stable_file(preferences, staged_preferences, "Plex Preferences.xml")
    copies.append((staged_preferences, "plex-config/Preferences.xml"))

    plugin_preferences = os.path.join(root, "Plug-in Support", "Preferences")
    if os.path.lexists(plugin_preferences):
        if os.path.islink(plugin_preferences) or not os.path.isdir(plugin_preferences):
            raise RuntimeError("Plex plug-in preferences path is not a directory")
        for current, dirs, names in os.walk(plugin_preferences, followlinks=False):
            dirs.sort()
            names.sort()
            for name in dirs:
                path = os.path.join(current, name)
                if os.path.islink(path):
                    raise RuntimeError("Plex plug-in preferences contain a symlink")
            for name in names:
                path = os.path.join(current, name)
                if os.path.islink(path) or not os.path.isfile(path):
                    raise RuntimeError(
                        "Plex plug-in preferences contain a non-regular file"
                    )
                relative = os.path.relpath(path, plugin_preferences)
                staged = os.path.join(stage_dir, "plugin-preferences", relative)
                os.makedirs(os.path.dirname(staged), exist_ok=True)
                _copy_stable_file(path, staged, "Plex plug-in preference")
                copies.append(
                    (
                        staged,
                        os.path.join(
                            "plex-config", "Plug-in Support", "Preferences", relative
                        ),
                    )
                )
    warning = ""
    database_dir = os.path.join(root, "Plug-in Support", "Databases")
    if os.path.lexists(database_dir) and (
        os.path.islink(database_dir) or not os.path.isdir(database_dir)
    ):
        raise RuntimeError("Plex database backup path is not a directory")
    try:
        entries = list(os.scandir(database_dir))
    except FileNotFoundError:
        entries = []
    dated_backups = []
    for entry in entries:
        match = re.fullmatch(
            r"com\.plexapp\.plugins\.library\.db-(\d{4}-\d{2}-\d{2})",
            entry.name,
        )
        if not match:
            continue
        date.fromisoformat(match.group(1))
        if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
            raise RuntimeError(
                "Plex dated library database backup is not a regular file"
            )
        dated_backups.append((match.group(1), entry.path))
    if dated_backups:
        _, source = max(dated_backups)
        name = os.path.basename(source)
        staged = os.path.join(stage_dir, "plex-library-database", name)
        os.makedirs(os.path.dirname(staged), exist_ok=True)
        signature = _copy_stable_file(
            source, staged, "Plex dated library database backup"
        )
        archive_name = os.path.join("plex-config", "Plug-in Support", "Databases", name)
        copies.append(
            (
                staged,
                archive_name,
            )
        )
        library_signatures[archive_name] = signature
    else:
        warning = "No Plex-generated dated library database backup was available."
    return copies, warning, library_signatures


def _verify_bundle(path, expected_tables, expected_library_signatures):
    with tarfile.open(path, "r:gz") as archive:
        members = {}
        for member in archive.getmembers():
            if (
                member.name.startswith("/")
                or ".." in member.name.split("/")
                or not member.isfile()
                or member.name in members
            ):
                raise RuntimeError("backup bundle contains an unsafe member")
            members[member.name] = member
        database = members.get("plexcurator.db")
        if database is None or not database.isfile():
            raise RuntimeError("backup bundle is missing the plexcurator database")
        if "plex-config/Preferences.xml" not in members:
            raise RuntimeError("backup bundle is missing Plex Preferences.xml")
        stream = archive.extractfile(database)
        if stream is None:
            raise RuntimeError("backup bundle database cannot be read")
        with tempfile.NamedTemporaryFile(
            prefix="plex-backup-verify-", suffix=".db"
        ) as local:
            shutil.copyfileobj(stream, local)
            local.flush()
            connection = sqlite3.connect(local.name)
            try:
                ok = connection.execute("PRAGMA integrity_check").fetchone()[0]
                got_tables = _tables(connection)
            finally:
                connection.close()
        if ok != "ok" or got_tables != expected_tables:
            raise RuntimeError("backup bundle database failed verification")
        for name, member in members.items():
            if not name.startswith(
                "plex-config/Plug-in Support/Databases/"
                "com.plexapp.plugins.library.db-"
            ):
                continue
            signature = expected_library_signatures.get(name)
            if signature is None:
                raise RuntimeError(
                    f"Plex library database snapshot {name} has no staged signature"
                )
            expected_size, expected_sha256 = signature
            stream = archive.extractfile(member)
            if stream is None:
                raise RuntimeError(
                    f"Plex library database snapshot {name} cannot be read"
                )
            try:
                with (
                    stream,
                    tempfile.NamedTemporaryFile(
                        prefix="plex-library-check-", suffix=".db"
                    ) as local,
                ):
                    shutil.copyfileobj(stream, local)
                    local.flush()
                    verify_plex_library_snapshot(
                        local.name,
                        expected_size=expected_size,
                        expected_sha256=expected_sha256,
                    )
            except (OSError, sqlite3.Error, RuntimeError, ValueError) as error:
                raise RuntimeError(
                    f"Plex library database snapshot {name} failed size, SHA-256, "
                    f"or read-only query check: {error}"
                ) from error


def _receipt_helper_path():
    configured = os.environ.get("BACKUP_RECEIPT_HELPER")
    if configured:
        return configured
    source_tree_helper = os.path.join(
        os.path.dirname(__file__),
        "..",
        "..",
        "os",
        "common",
        "backup",
        "backup-receipt.sh",
    )
    return os.path.abspath(source_tree_helper)


def _record_receipt(
    result,
    artifact_path,
    started,
    warning="",
    recovery_group="plex",
    encrypted=None,
):
    if shutil.which("python3") is None:
        print(
            "plexcurator: WARN: python3 is unavailable; backup receipt was not written",
            file=sys.stderr,
        )
        return
    helper = _receipt_helper_path()
    if not os.path.isfile(helper):
        print(
            "plexcurator: WARN: backup receipt helper is unavailable; receipt was not written",
            file=sys.stderr,
        )
        return
    try:
        host = socket.gethostname().split(".", 1)[0]
        has_artifact = bool(artifact_path)
        artifact_bytes = os.path.getsize(artifact_path) if has_artifact else 0
        digest = _sha256(artifact_path) if has_artifact else ""
    except OSError as error:
        print(
            f"plexcurator: WARN: backup receipt metadata unavailable: {error}",
            file=sys.stderr,
        )
        return
    command = [
        "bash",
        "-c",
        'source "$1"; shift; backup_receipt_record "$@"',
        "backup-receipt",
        helper,
        "--type",
        "backup",
        "--host",
        host,
        "--stack",
        "plex",
        "--archive-class",
        "local",
        "--recovery-group",
        recovery_group,
        "--artifact-path",
        artifact_path,
        "--bytes",
        str(artifact_bytes),
        "--sha256",
        digest,
        "--result",
        result,
        "--duration-seconds",
        str(max(0, int(time.monotonic() - started))),
    ]
    if warning:
        command.extend(("--warning", warning))
    if encrypted is not None:
        command.extend(("--encrypted", "true" if encrypted else "false"))
    try:
        completed = subprocess.run(command, check=False)
    except OSError as error:
        print(
            f"plexcurator: WARN: backup receipt helper could not run: {error}",
            file=sys.stderr,
        )
        return
    if completed.returncode != 0:
        print(
            f"plexcurator: WARN: backup receipt helper exited with status {completed.returncode}",
            file=sys.stderr,
        )


def _encryption_helper_path():
    configured = os.environ.get("BACKUP_ENCRYPTION_HELPER")
    if configured:
        return configured
    source_tree_helper = os.path.join(
        os.path.dirname(__file__),
        "..",
        "..",
        "os",
        "common",
        "backup",
        "backup-encrypt.sh",
    )
    return os.path.abspath(source_tree_helper)


def _encrypt_archive(source, destination):
    helper = _encryption_helper_path()
    if not os.path.isfile(helper) or os.path.islink(helper):
        raise RuntimeError("Kometa backup encryption helper is unavailable")
    try:
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; shift; backup_encrypt_archive "$@"',
                "backup-encrypt",
                helper,
                source,
                destination,
            ],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError("Kometa archive encryption could not complete") from error
    if result.returncode != 0:
        raise RuntimeError("Kometa archive encryption failed")
    if not os.path.isfile(destination) or os.path.islink(destination):
        raise RuntimeError("Kometa archive encryption produced no regular file")
    if os.path.getsize(destination) == 0:
        raise RuntimeError("Kometa archive encryption produced an empty file")


def _kometa_files(config_path, collections_dir, stage_dir):
    if os.path.islink(config_path) or not os.path.isfile(config_path):
        raise RuntimeError("Kometa config is not a regular file")
    if os.path.islink(collections_dir) or not os.path.isdir(collections_dir):
        raise RuntimeError("Kometa collections path is not a directory")

    staged_config = os.path.join(stage_dir, "config.yml")
    _copy_stable_file(config_path, staged_config, "Kometa config")
    os.chmod(staged_config, 0o600)
    copies = [(staged_config, "kometa/config.yml")]
    staged_collections = os.path.join(stage_dir, "collections")
    os.mkdir(staged_collections, 0o700)

    for current, dirs, names in os.walk(collections_dir, followlinks=False):
        dirs.sort()
        names.sort()
        relative_dir = os.path.relpath(current, collections_dir)
        if relative_dir != ".":
            if any(os.path.islink(os.path.join(current, name)) for name in dirs):
                raise RuntimeError("Kometa collections contain a symlink")
            staged_dir = os.path.join(staged_collections, relative_dir)
            os.makedirs(staged_dir, mode=0o700, exist_ok=True)
        for name in dirs:
            path = os.path.join(current, name)
            if os.path.islink(path):
                raise RuntimeError("Kometa collections contain a symlink")
        for name in names:
            source = os.path.join(current, name)
            if os.path.islink(source) or not os.path.isfile(source):
                raise RuntimeError("Kometa collections contain a non-regular file")
            relative = os.path.relpath(source, collections_dir)
            staged = os.path.join(staged_collections, relative)
            os.makedirs(os.path.dirname(staged), mode=0o700, exist_ok=True)
            _copy_stable_file(source, staged, "Kometa collection")
            os.chmod(staged, 0o600)
            copies.append((staged, os.path.join("kometa", "collections", relative)))
    return copies, staged_collections


def _verify_kometa_bundle(path, expected_files):
    with tarfile.open(path, "r:gz") as archive:
        names = set()
        files = set()
        for member in archive.getmembers():
            path_parts = member.name.split("/")
            if (
                member.name.startswith("/")
                or ".." in path_parts
                or member.issym()
                or member.islnk()
                or not (member.isfile() or member.isdir())
                or member.name in names
            ):
                raise RuntimeError("Kometa backup contains an unsafe archive member")
            names.add(member.name)
            if member.isfile():
                files.add(member.name)
        if files != set(expected_files) or "kometa/config.yml" not in files:
            raise RuntimeError("Kometa backup is missing expected files")


def _rotate_kometa(backup_dir, keep=13):
    pattern = re.compile(r"kometa-\d{8}-\d{6}\.tar\.gz\.gpg")
    archives = []
    for name in os.listdir(backup_dir):
        if not pattern.fullmatch(name):
            continue
        path = os.path.join(backup_dir, name)
        if os.path.islink(path) or not os.path.isfile(path):
            raise RuntimeError("Kometa backup contains a non-regular artifact")
        archives.append(path)
    for archive in sorted(archives)[:-keep]:
        for path in (archive, archive + ".sha256", archive + ".manifest.json"):
            if os.path.lexists(path):
                if os.path.islink(path) or not os.path.isfile(path):
                    raise RuntimeError("Kometa backup sidecar is not a regular file")
                os.remove(path)


def backup_kometa_with_config(
    config_path,
    collections_dir,
    backup_dir,
    staging_dir,
    keep=13,
    now=None,
):
    started = time.monotonic()
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now or time.time()))
    destination = os.path.join(backup_dir, f"kometa-{stamp}.tar.gz.gpg")
    installed = []
    try:
        with tempfile.TemporaryDirectory(
            prefix=".kometa-backup-", dir=staging_dir
        ) as stage_dir:
            copies, staged_collections = _kometa_files(
                config_path, collections_dir, stage_dir
            )
            staged_bundle = os.path.join(stage_dir, "kometa.tar.gz")
            with tarfile.open(staged_bundle, "w:gz") as archive:
                archive.add(copies[0][0], arcname="kometa/config.yml", recursive=False)
                archive.add(
                    staged_collections,
                    arcname="kometa/collections",
                    recursive=False,
                )
                for source, name in copies[1:]:
                    archive.add(source, arcname=name, recursive=False)
            os.chmod(staged_bundle, 0o600)
            _verify_kometa_bundle(staged_bundle, [name for _, name in copies])

            staged_encrypted = os.path.join(stage_dir, "kometa.tar.gz.gpg")
            _encrypt_archive(staged_bundle, staged_encrypted)
            os.chmod(staged_encrypted, 0o600)
            size = os.path.getsize(staged_encrypted)
            digest = _sha256(staged_encrypted)
            archive_name = os.path.basename(destination)
            kometa_dir = os.path.dirname(os.path.abspath(config_path))
            manifest = {
                "schema_version": 1,
                "captured_at": datetime.fromtimestamp(
                    now or time.time(), timezone.utc
                ).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "host": socket.gethostname().split(".", 1)[0],
                "stack": "plex",
                "recovery_group": "kometa",
                "archive_class": "local",
                "archive": archive_name,
                "bytes": size,
                "sha256": digest,
                "encrypted": True,
                "source_paths": [
                    os.path.abspath(config_path),
                    os.path.abspath(collections_dir),
                ],
                "excluded_paths": [
                    os.path.join(kometa_dir, "config.cache"),
                    os.path.join(kometa_dir, "logs"),
                    "/opt/kometa/app",
                    "/opt/kometa/venv",
                ],
            }
            staged_sha = os.path.join(stage_dir, "kometa.sha256")
            with open(staged_sha, "wb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(f"{digest}  {archive_name}\n".encode())
            staged_manifest = os.path.join(stage_dir, "kometa.manifest.json")
            with open(staged_manifest, "wb") as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(
                    (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
                )

            _prepare_nas_backup_dir(backup_dir)
            targets = (
                destination,
                destination + ".sha256",
                destination + ".manifest.json",
            )
            if any(os.path.lexists(path) for path in targets):
                raise RuntimeError("Kometa backup destination already exists")
            for source, target in zip(
                (staged_encrypted, staged_sha, staged_manifest), targets
            ):
                installed.append(target)
                _copy_verified(source, target, backup_dir, mode=0o600)
        _rotate_kometa(backup_dir, keep)
    except (
        OSError,
        RuntimeError,
        subprocess.SubprocessError,
        tarfile.TarError,
        ValueError,
    ):
        for path in installed:
            if os.path.isfile(path) and not os.path.islink(path):
                os.remove(path)
        artifact = destination if os.path.isfile(destination) else ""
        _record_receipt(
            "failed",
            artifact,
            started,
            recovery_group="kometa",
            encrypted=True,
        )
        raise
    _record_receipt(
        "ok",
        destination,
        started,
        recovery_group="kometa",
        encrypted=True,
    )
    return destination


def backup_with_config(db_path, config_dir, backup_dir, keep=14, now=None):
    started = time.monotonic()
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(now or time.time()))
    destination = ""
    warning = ""
    try:
        local_parent = os.path.dirname(os.path.abspath(db_path))
        with tempfile.TemporaryDirectory(
            prefix=".plex-backup-", dir=local_parent
        ) as stage_dir:
            staged_db = os.path.join(stage_dir, "plexcurator.db")
            schema, tables = _create_database_snapshot(db_path, staged_db)
            config_files, warning, library_signatures = _config_files(
                config_dir, stage_dir
            )
            staged_bundle = os.path.join(stage_dir, "backup.tar.gz")
            with tarfile.open(staged_bundle, "w:gz") as archive:
                archive.add(staged_db, arcname="plexcurator.db", recursive=False)
                for source, name in config_files:
                    archive.add(source, arcname=name, recursive=False)
            _verify_bundle(staged_bundle, tables, library_signatures)
            destination = os.path.join(
                backup_dir, f"plexcurator-{stamp}-schema{schema}.tar.gz"
            )
            _prepare_nas_backup_dir(backup_dir)
            _copy_verified(staged_bundle, destination, backup_dir)
        _rotate(backup_dir, ("plexcurator-", ".tar.gz"), keep)
    except (OSError, sqlite3.Error, RuntimeError, tarfile.TarError, ValueError):
        artifact = destination if destination and os.path.isfile(destination) else ""
        _record_receipt("failed", artifact, started, warning)
        raise
    if warning:
        print(f"plexcurator: WARN: {warning}", file=sys.stderr)
    _record_receipt("ok", destination, started, warning)
    return destination
