import contextlib
import hashlib
import importlib.util
import io
import json
import os
import sqlite3
import socket
import subprocess
import tarfile
import tempfile
import time
from datetime import datetime, timezone
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from .helpers import add_missing_plex_fts_tokenizer

CHECKER = Path(__file__).resolve().parents[1] / "check-plex.py"
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
SPEC = importlib.util.spec_from_file_location("plex_healthcheck", CHECKER)
healthcheck = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(healthcheck)


class PlexHealthcheck(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.appdata = self.root / "appdata"
        self.appdata.mkdir()
        self.receipts = self.root / "receipts.jsonl"
        self.marker = self.root / "plex.marker"
        self.marker.write_text('COMPONENTS="plex,plexcurator,kometa"\n')
        self.kometa_config = self.root / "kometa-config.yml"
        self.kometa_config.write_text("token: SECRET_FIXTURE_DO_NOT_PRINT\n")
        self.kometa_mode = 0o640
        self.kometa_uid = 0
        self.kometa_gid = 1234
        self.kometa_user_missing = False
        self.kometa_exit_timestamp = (
            datetime.now().astimezone().strftime("%a %Y-%m-%d %H:%M:%S %Z")
        )
        self.backup_dir = self.root / "nas-backups"
        self.backup_dir.mkdir()
        self.share = self.root / "nas-share"
        self.share.mkdir()
        self.install = self.root / "install"
        (self.install / "plexcurator").mkdir(parents=True)
        (self.install / "plexcurator" / "version.py").write_text("SCHEMA_VERSION = 2\n")
        self.db_path = self.root / "plexcurator.db"
        self.alert_file = self.root / "ALERT"
        connection = sqlite3.connect(self.db_path)
        connection.execute("PRAGMA user_version = 2")
        connection.close()
        self.backup = self.backup_dir / "plexcurator-20261028-041500-schema2.tar.gz"
        self.config = self.root / "config.toml"
        self.config.write_text(
            f"""alert_unidentified = "warn"\n"""
            f"""[plex]\nurl = "http://127.0.0.1:32400"\n"""
            f"""[storage]\nbackup_dir = "{self.backup_dir}"\n"""
            f"""[advanced]\ndb_path = "{self.db_path}"\nalert_file = "{self.alert_file}"\n"""
        )
        self.write_preferences()
        plugin_preferences = self.appdata / "Plug-in Support" / "Preferences"
        plugin_preferences.mkdir(parents=True)
        (plugin_preferences / "fixture.json").write_text('{"fixture": true}\n')
        database_dir = self.appdata / "Plug-in Support" / "Databases"
        database_dir.mkdir()
        plex_database = sqlite3.connect(
            database_dir / "com.plexapp.plugins.library.db-2026-10-28"
        )
        plex_database.execute("CREATE TABLE library_fixture (id INTEGER)")
        plex_database.commit()
        plex_database.close()
        self.write_backup()
        self.write_receipt()
        self.inactive = set()
        self.failed_services = set()
        self.alerted_services = set()
        self.unenabled = set()
        self.unreadable = set()
        self.service_groups = {"plex", "nas"}
        self.nas_mount_options = "uid=1000,gid=nas,file_mode=0664,dir_mode=0775"
        self.autofs_resolutions = {}
        self.mounts = {
            str(self.db_path): ("/dev/root", "ext4"),
            str(self.appdata): ("/dev/root", "ext4"),
            str(self.backup_dir): ("//10.10.20.20/cloud-backup", "cifs"),
            str(self.share): ("//10.10.20.20/plex", "cifs"),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def write_preferences(self, remote="0", networks="10.10.0.0/16"):
        path = self.appdata / "Preferences.xml"
        path.write_text(
            f'<Preferences PublishServerOnPlexOnlineKey="{remote}" '
            f'LanNetworksBandwidth="{networks}" />\n'
        )

    def write_backup(self, tables=EXPECTED_BACKUP_TABLES):
        self.backup.unlink(missing_ok=True)
        database = self.root / "plexcurator-fixture.db"
        database.unlink(missing_ok=True)
        connection = sqlite3.connect(database)
        for table in sorted(tables):
            connection.execute(f'CREATE TABLE "{table}" (id INTEGER)')
        connection.close()
        with tarfile.open(self.backup, "w:gz") as archive:
            archive.add(database, arcname="plexcurator.db")
            archive.add(
                self.appdata / "Preferences.xml",
                arcname="plex-config/Preferences.xml",
            )
            archive.add(
                self.appdata / "Plug-in Support" / "Preferences" / "fixture.json",
                arcname="plex-config/Plug-in Support/Preferences/fixture.json",
            )
            archive.add(
                self.appdata
                / "Plug-in Support"
                / "Databases"
                / "com.plexapp.plugins.library.db-2026-10-28",
                arcname=(
                    "plex-config/Plug-in Support/Databases/"
                    "com.plexapp.plugins.library.db-2026-10-28"
                ),
            )

    def write_receipt(self, result="ok", warning=None):
        digest = hashlib.sha256(self.backup.read_bytes()).hexdigest()
        receipt = {
            "ts": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "type": "backup",
            "host": socket.gethostname().split(".", 1)[0],
            "stack": "plex",
            "archive_class": "local",
            "recovery_group": "plex",
            "artifact_path": str(self.backup),
            "bytes": self.backup.stat().st_size,
            "sha256": digest,
            "result": result,
            "duration_seconds": 1,
        }
        if warning:
            receipt["warning"] = warning
        self.receipts.write_text(json.dumps(receipt) + "\n")

    def stub_command(self, *args):
        if args[0] == "findmnt":
            target = args[-1]
            if "OPTIONS" in args:
                return subprocess.CompletedProcess(
                    args, 0, f"{self.nas_mount_options}\n", ""
                )
            source, fstype = self.mounts.get(target, ("/dev/root", "ext4"))
            return subprocess.CompletedProcess(args, 0, f"{source} {fstype}\n", "")
        if args[:2] == ("systemctl", "show"):
            prop = args[2].split("=", 1)[1]
            unit = args[-1]
            alerted = unit in self.alerted_services
            failed = unit in self.failed_services
            value = {
                "User": "plex",
                "Result": "exit-code" if failed or alerted else "success",
                "ExecMainStatus": str(2 if alerted else 1 if failed else 0),
                "ExecMainExitTimestamp": (
                    self.kometa_exit_timestamp
                    if unit == "kometa.service"
                    else "2026-10-28 04:15:00 UTC"
                ),
            }[prop]
            return subprocess.CompletedProcess(args, 0, f"{value}\n", "")
        if args[0] == "id":
            return subprocess.CompletedProcess(
                args, 0, f"{' '.join(sorted(self.service_groups))}\n", ""
            )
        if args[:2] == ("getent", "group"):
            return subprocess.CompletedProcess(args, 0, "nas:x:1001:\n", "")
        if args[0] == "runuser":
            path = args[-1]
            status = 1 if path in self.unreadable else 0
            if status == 0 and path in self.autofs_resolutions:
                self.mounts[path] = self.autofs_resolutions[path]
            return subprocess.CompletedProcess(
                args, status, "", "permission denied" if status else ""
            )
        if args[0] == "systemctl":
            unit = args[-1]
            if args[1] == "is-active":
                status = 1 if unit in self.inactive else 0
                return subprocess.CompletedProcess(args, status, "", "")
            if args[1] == "is-enabled":
                status = 1 if unit in self.unenabled else 0
                return subprocess.CompletedProcess(args, status, "", "")
            prop = args[2].split("=", 1)[1]
            value = {
                "Result": "exit-code" if unit in self.failed_services else "success",
                "ExecMainStatus": "1" if unit in self.failed_services else "0",
                "ExecMainExitTimestamp": "2026-10-28 04:15:00 UTC",
            }[prop]
            return subprocess.CompletedProcess(args, 0, f"{value}\n", "")
        raise AssertionError(f"unexpected command: {args}")

    def run_checks(self, appdata_space=(True, "fixture free space"), socket_error=None):
        output = io.StringIO()
        real_stat = os.stat

        def fake_stat(path, **kwargs):
            if os.fspath(path) == str(self.kometa_config):
                return SimpleNamespace(
                    st_mode=healthcheck.stat.S_IFREG | self.kometa_mode,
                    st_uid=self.kometa_uid,
                    st_gid=self.kometa_gid,
                )
            return real_stat(path, **kwargs)

        def fake_kometa_user(name):
            if self.kometa_user_missing:
                raise KeyError(name)
            return SimpleNamespace(pw_name=name)

        argv = [
            "--config",
            str(self.config),
            "--install-dir",
            str(self.install),
            "--appdata",
            str(self.appdata),
            "--share",
            str(self.share),
            "--backup-receipts",
            str(self.receipts),
            "--marker",
            str(self.marker),
            "--kometa-config",
            str(self.kometa_config),
        ]
        socket_patch = (
            mock.patch.object(
                healthcheck.socket,
                "create_connection",
                side_effect=OSError("connection refused"),
            )
            if socket_error
            else mock.patch.object(
                healthcheck.socket,
                "create_connection",
                return_value=contextlib.nullcontext(),
            )
        )
        with (
            mock.patch.object(
                healthcheck, "run_command", side_effect=self.stub_command
            ),
            mock.patch.object(
                healthcheck.pwd,
                "getpwnam",
                side_effect=fake_kometa_user,
            ),
            mock.patch.object(
                healthcheck.grp,
                "getgrnam",
                return_value=SimpleNamespace(gr_gid=1234),
            ),
            mock.patch.object(
                healthcheck.os,
                "stat",
                side_effect=fake_stat,
            ),
            socket_patch,
            mock.patch.object(healthcheck, "appdata_space", return_value=appdata_space),
            contextlib.redirect_stdout(output),
        ):
            status = healthcheck.main(argv)
        return status, output.getvalue()

    def test_all_health_checks_pass_using_stubs_and_temporary_state(self):
        status, output = self.run_checks()
        self.assertEqual(status, 0, output)
        for check in (
            "Plex TCP port 32400 answers",
            "plexmediaserver active",
            "NAS share",
            "NAS share",
            "Plex Remote Access is disabled",
            "Plex LAN Networks match documented range",
            "Plex appdata is on a local disk",
            "plexcurator database is on a local disk",
            "database opens read-only",
            "database integrity_check is ok",
            "database schema version matches installed code",
            "newest Plex recovery bundle is younger than 36 hours",
            "latest Plex local-backup receipt matches the newest bundle",
            "plexcurator.service last run succeeded",
            "unidentified-movie alert policy is valid",
            "plexcurator alert file is clear",
            "plexcurator.timer active",
            "Kometa service user exists",
            "kometa.timer active",
            "kometa.timer enabled",
            "Kometa service succeeded within 48 hours",
            "Kometa config permissions are safe",
        ):
            self.assertIn(f"PASS  {check}", output)
        self.assertIn(
            f"PASS  NAS share {self.share} is writable by plexcurator service user",
            output,
        )
        self.assertRegex(
            output,
            r"last good backup at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC",
        )
        self.assertNotIn("SECRET_FIXTURE_DO_NOT_PRINT", output)

    def test_host_without_kometa_component_skips_kometa_checks(self):
        self.marker.write_text('COMPONENTS="plex,plexcurator"\n')

        status, output = self.run_checks()

        self.assertEqual(status, 0, output)
        self.assertNotIn("Kometa", output)
        self.assertNotIn("kometa.timer", output)

    def test_kometa_component_checks_fail_for_missing_or_unsafe_state(self):
        self.kometa_user_missing = True
        self.inactive.add("kometa.timer")
        self.unenabled.add("kometa.timer")
        self.failed_services.add("kometa.service")
        self.kometa_mode = 0o644

        status, output = self.run_checks()

        self.assertEqual(status, 1)
        self.assertIn("FAIL  Kometa service user exists", output)
        self.assertIn("FAIL  kometa.timer active", output)
        self.assertIn("FAIL  kometa.timer enabled", output)
        self.assertIn("FAIL  Kometa service succeeded within 48 hours", output)
        self.assertIn("FAIL  Kometa config permissions are safe", output)

    def test_kometa_service_must_have_succeeded_within_48_hours(self):
        self.kometa_exit_timestamp = (
            datetime.fromtimestamp(time.time() - 49 * 60 * 60)
            .astimezone()
            .strftime("%a %Y-%m-%d %H:%M:%S %Z")
        )

        status, output = self.run_checks()

        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  Kometa service succeeded within 48 hours: last run was",
            output,
        )

    def test_application_defaults_are_used_when_advanced_section_is_absent(self):
        self.config.write_text(f'[storage]\nbackup_dir = "{self.backup_dir}"\n')
        with mock.patch.dict(
            healthcheck.curator_config.DEFAULTS["advanced"],
            {"db_path": str(self.db_path)},
        ):
            status, output = self.run_checks()
        self.assertEqual(status, 0, output)
        for check in (
            "required Plex health-check config values are valid",
            "plexcurator database is on a local disk",
            "installed plexcurator schema version is available",
            "database opens read-only",
            "database integrity_check is ok",
            "database schema version matches installed code",
        ):
            self.assertIn(f"PASS  {check}", output)
        self.assertNotIn("advanced.db_path is missing or invalid", output)

    def test_autofs_share_is_triggered_before_cifs_mount_check(self):
        self.mounts[str(self.share)] = ("systemd-1", "autofs")
        self.autofs_resolutions[str(self.share)] = ("//10.10.20.20/plex", "cifs")
        status, output = self.run_checks()
        self.assertEqual(status, 0, output)
        self.assertIn(
            f"PASS  NAS share {self.share} is mounted and readable by plex: "
            "//10.10.20.20/plex (cifs)",
            output,
        )

    def test_autofs_backup_directory_is_triggered_before_nas_check(self):
        self.mounts[str(self.backup_dir)] = ("systemd-1", "autofs")
        self.autofs_resolutions[str(self.backup_dir)] = (
            "//10.10.20.20/cloud-backup",
            "cifs",
        )
        status, output = self.run_checks()
        self.assertEqual(status, 0, output)
        self.assertIn(
            "PASS  plexcurator backup directory is mounted on the NAS: "
            "//10.10.20.20/cloud-backup (cifs)",
            output,
        )

    def test_untriggerable_autofs_share_reports_read_error(self):
        self.mounts[str(self.share)] = ("systemd-1", "autofs")
        self.unreadable.add(str(self.share))
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn(
            f"FAIL  NAS share {self.share} is mounted and readable by plex: "
            "permission denied",
            output,
        )

    def test_service_exit_two_is_reported_as_alert_warning(self):
        self.alerted_services.add("plexcurator.service")
        status, output = self.run_checks()
        self.assertEqual(status, 0, output)
        self.assertIn(
            "WARN  plexcurator.service last run succeeded: alert raised (exit 2)",
            output,
        )

    def test_host_drift_is_reported_as_failed_checks(self):
        self.inactive.add("plexmediaserver")
        self.inactive.add("plexcurator-backup.timer")
        self.failed_services.update(
            ("plexcurator.service", "plexcurator-backup.service")
        )
        self.unenabled.add("plexcurator-backup.timer")
        self.unreadable.add(str(self.share))
        self.mounts[str(self.db_path)] = ("//10.10.20.20/db", "cifs")
        self.mounts[str(self.appdata)] = ("//10.10.20.20/appdata", "cifs")
        self.mounts[str(self.backup_dir)] = ("/dev/root", "ext4")
        self.backup.touch()
        old = time.time() - (37 * 60 * 60)
        os.utime(self.backup, (old, old))
        self.write_preferences(remote="1", networks="10.10.20.0/24")
        status, output = self.run_checks(
            appdata_space=(False, "0.5 GiB free (2.0%)"), socket_error=True
        )
        self.assertEqual(status, 1)
        for check in (
            "Plex TCP port 32400 answers",
            "plexmediaserver active",
            "NAS share",
            "Plex Remote Access is disabled",
            "Plex LAN Networks match documented range",
            "Plex appdata is on a local disk",
            "Plex appdata has at least 10% and 1 GiB free",
            "plexcurator database is on a local disk",
            "newest Plex recovery bundle is younger than 36 hours",
            "plexcurator.service last run succeeded",
            "plexcurator-backup.service last run succeeded",
            "plexcurator-backup.timer active",
            "plexcurator-backup.timer enabled",
        ):
            self.assertIn(f"FAIL  {check}", output)

    def test_corrupt_database_fails_read_only_database_checks(self):
        self.db_path.write_bytes(b"not a sqlite database")
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn("FAIL  database opens read-only", output)
        self.assertIn("FAIL  database integrity_check is ok", output)

    def test_unidentified_alert_is_a_warning_under_warn_policy(self):
        self.alert_file.write_text(
            "2026-10-31 23:00:00 [WARN:unidentified] one movie is unidentified\n"
        )
        status, output = self.run_checks()
        self.assertEqual(status, 0, output)
        self.assertIn("WARN  plexcurator has unidentified movies", output)

    def test_unidentified_alert_fails_under_fail_policy(self):
        self.alert_file.write_text(
            "2026-10-31 23:00:00 [WARN:unidentified] one movie is unidentified\n"
        )
        self.config.write_text(
            self.config.read_text().replace(
                'alert_unidentified = "warn"', 'alert_unidentified = "fail"'
            )
        )
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn("FAIL  plexcurator alert file is clear", output)

    def test_error_alert_still_fails_under_warn_policy(self):
        self.alert_file.write_text("2026-10-31 23:00:00 [ERROR] reclaim shortfall\n")
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn("FAIL  plexcurator alert file is clear", output)

    def test_empty_backup_fails_health_check(self):
        self.backup.write_bytes(b"")
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  newest Plex recovery bundle is younger than 36 hours: cannot read newest backup bundle",
            output,
        )

    def test_backup_older_than_36_hours_fails_health_check(self):
        old = time.time() - (37 * 60 * 60)
        os.utime(self.backup, (old, old))
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  newest Plex recovery bundle is younger than 36 hours: newest backup is 37.0 hours old",
            output,
        )

    def test_backup_must_open_and_contain_expected_tables(self):
        self.write_backup(EXPECTED_BACKUP_TABLES - {"deletion"})
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  newest Plex recovery bundle is younger than 36 hours: newest backup database is missing expected tables: deletion",
            output,
        )

    def test_unopenable_backup_fails_health_check(self):
        self.backup.write_bytes(b"not a sqlite database")
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  newest Plex recovery bundle is younger than 36 hours: cannot read newest backup bundle",
            output,
        )

    def test_backup_is_copied_locally_before_opening_sqlite(self):
        real_connect = sqlite3.connect
        opened_paths = []

        def capture_connect(database, *args, **kwargs):
            opened_paths.append(Path(database.removesuffix("?mode=ro")))
            return real_connect(database, *args, **kwargs)

        with mock.patch.object(
            healthcheck.sqlite3, "connect", side_effect=capture_connect
        ):
            ok, detail = healthcheck.latest_backup(self.backup_dir, local_dir=self.root)
        self.assertTrue(ok, detail)
        self.assertEqual(len(opened_paths), 2)
        self.assertTrue(all(path.parent != self.backup_dir for path in opened_paths))
        self.assertIn("contains all 14 expected tables", detail)

    def test_missing_plex_fts_tokenizer_does_not_fail_backup_health_checks(self):
        database_path = (
            self.appdata
            / "Plug-in Support"
            / "Databases"
            / "com.plexapp.plugins.library.db-2026-10-28"
        )
        add_missing_plex_fts_tokenizer(database_path)
        self.write_backup()
        self.write_receipt()

        status, output = self.run_checks()

        self.assertEqual(status, 0, output)
        for check in (
            "newest Plex recovery bundle is younger than 36 hours",
            "latest Plex local-backup receipt matches the newest bundle",
            "plexcurator.service last run succeeded",
        ):
            self.assertIn(f"PASS  {check}", output)

    def test_truncated_plex_library_snapshot_fails_backup_health_check(self):
        database_path = (
            self.appdata
            / "Plug-in Support"
            / "Databases"
            / "com.plexapp.plugins.library.db-2026-10-28"
        )
        with database_path.open("r+b") as stream:
            stream.truncate(database_path.stat().st_size - 1)
        self.write_backup()
        self.write_receipt()

        ok, detail = healthcheck.latest_backup(self.backup_dir, local_dir=self.root)

        self.assertFalse(ok)
        self.assertIn(database_path.name, detail)
        self.assertIn("truncated", detail)

    def test_missing_backup_receipt_fails_health_check(self):
        self.receipts.unlink()

        status, output = self.run_checks()

        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  latest Plex local-backup receipt matches the newest bundle: "
            "cannot read backup receipt log",
            output,
        )

    def test_failed_backup_receipt_fails_health_check(self):
        self.write_receipt(result="failed")

        status, output = self.run_checks()

        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  latest Plex local-backup receipt matches the newest bundle: "
            "latest Plex local-backup receipt reports failure",
            output,
        )

    def test_receipt_warning_is_reported_without_failing_health_check(self):
        self.write_receipt(
            warning="No Plex-generated dated library database backup was available."
        )

        status, output = self.run_checks()

        self.assertEqual(status, 0, output)
        self.assertIn(
            "WARN  latest Plex local-backup receipt matches the newest bundle:",
            output,
        )
        self.assertIn("No Plex-generated dated library database backup", output)

    def test_missing_nas_group_membership_reports_cause_and_fix(self):
        self.service_groups = {"plex"}
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn("plex is not in group nas", output)
        self.assertIn("mount-nas.sh --add-user plex", output)
        self.assertIn("dir_mode=0775", output)

    def test_non_group_writable_nas_mount_modes_fail(self):
        self.nas_mount_options = "uid=1000,gid=nas,file_mode=0664,dir_mode=0755"
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn("dir_mode=0755 does not grant group write", output)

    def test_database_schema_must_match_installed_code(self):
        connection = sqlite3.connect(self.db_path)
        connection.execute("PRAGMA user_version = 1")
        connection.close()
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn("FAIL  database schema version matches installed code", output)

    def test_invalid_config_values_report_failures_without_traceback(self):
        self.config.write_text(
            "[plex]\nurl = 32400\n"
            "[storage]\nbackup_dir = []\n"
            "[advanced]\ndb_path = false\n"
        )
        status, output = self.run_checks()
        self.assertEqual(status, 1)
        self.assertIn(
            "FAIL  required Plex health-check config values are valid", output
        )
        self.assertIn("FAIL  Plex TCP port 32400 answers", output)
        self.assertIn("FAIL  database opens read-only", output)
        self.assertNotIn("Traceback", output)

    def test_free_space_floor_requires_both_percentage_and_one_gibibyte(self):
        enough = SimpleNamespace(f_blocks=100, f_bavail=20, f_frsize=1 << 30)
        low_percent = SimpleNamespace(f_blocks=100, f_bavail=9, f_frsize=1 << 30)
        low_bytes = SimpleNamespace(f_blocks=100, f_bavail=0, f_frsize=1 << 30)
        self.assertTrue(healthcheck.appdata_space(self.appdata, lambda _: enough)[0])
        self.assertFalse(
            healthcheck.appdata_space(self.appdata, lambda _: low_percent)[0]
        )
        self.assertFalse(
            healthcheck.appdata_space(self.appdata, lambda _: low_bytes)[0]
        )

    def test_check_wrapper_help_is_non_mutating(self):
        wrapper = CHECKER.with_name("check-plex.sh")
        result = subprocess.run(
            ["bash", str(wrapper), "--help"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Usage: check-plex.sh", result.stdout)

    def test_check_wrapper_records_warning_without_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake_bin = Path(tmp) / "bin"
            fake_bin.mkdir()
            fake_python = fake_bin / "python3"
            fake_python.write_text(
                "#!/bin/sh\n" "printf 'PASS  fixture\\nWARN  fixture alert\\n'\n"
            )
            fake_python.chmod(0o755)
            drift_log = Path(tmp) / "drift.jsonl"
            env = dict(
                os.environ,
                PATH=f"{fake_bin}:{os.environ['PATH']}",
                DRIFT_LOG=str(drift_log),
            )
            result = subprocess.run(
                [
                    "bash",
                    str(CHECKER.with_name("check-plex.sh")),
                    "--config",
                    str(self.config),
                ],
                capture_output=True,
                text=True,
                env=env,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            record = json.loads(drift_log.read_text().splitlines()[-1])
            self.assertEqual(record["failed"], 0)
            self.assertEqual(record["warned"], 1)
