"""build-plex-node.sh against a temp tree. Needs root (the script refuses otherwise) and bash; skipped elsewhere.
Only the phases that touch temp paths are exercised; apt, systemd and runuser-as-plex are NOT run here.
"""

import hashlib
import grp
import os
import pwd
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

SCRIPT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "build-plex-node.sh"
)


def script_version():
    with open(SCRIPT) as fh:
        for line in fh:
            if line.startswith("SCRIPT_VERSION="):
                return line.split('"')[1]
    raise AssertionError("no SCRIPT_VERSION in the build script")


class BackupUnitTemplates(unittest.TestCase):
    def test_backup_timer_and_service_do_not_hold_the_mount_during_staging(self):
        deploy = os.path.join(os.path.dirname(SCRIPT), "deploy")
        with open(os.path.join(deploy, "plexcurator-backup.timer")) as stream:
            timer = stream.read()
        with open(os.path.join(deploy, "plexcurator-backup.service")) as stream:
            service = stream.read()
        self.assertIn("OnCalendar=*-*-* 04:00:00", timer)
        self.assertNotIn("RequiresMountsFor=", service)
        self.assertIn("PLEX_APPDATA_DIR=@APPDATA@", service)
        self.assertIn("BACKUP_RECEIPT_HELPER=@RECEIPT_HELPER@", service)
        self.assertIn("BACKUP_ENCRYPTION_HELPER=@ENCRYPTION_HELPER@", service)
        self.assertIn("SupplementaryGroups=kometa", service)
        self.assertIn("BACKUP_RECEIPTS_LOG=@RECEIPTS_LOG@", service)


@unittest.skipUnless(
    shutil.which("bash") and hasattr(os, "geteuid") and os.geteuid() == 0,
    "needs root and bash",
)
class BuildScript(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        r = self.tmp.name
        for d in ("Movies", "Curated"):
            os.makedirs(os.path.join(r, d))
        self.cfg = os.path.join(r, "etc", "config.toml")
        self.marker = os.path.join(r, "etc", "andrusone", "stacks", "plex")
        self.inst = os.path.join(r, "opt")
        self.wrapper = os.path.join(r, "bin", "plexcurator")
        os.makedirs(os.path.dirname(self.cfg))

    def tearDown(self):
        self.tmp.cleanup()

    def write_cfg(self):
        r = self.tmp.name
        with open(self.cfg, "w") as fh:
            fh.write(
                f"""[plex]
token = "t"
[radarr]
url = "http://r"
api_key = "k"
[storage]
backup_dir = "{r}/bk"
[folders]
managed = "{r}/Curated"
[[folders.unmanaged]]
path = "{r}/Movies"
[advanced]
db_path = "{r}/state/plexcurator.db"
"""
            )

    def write_legacy_marker(self):
        os.makedirs(os.path.dirname(self.marker), exist_ok=True)
        with open(self.marker, "w") as fh:
            fh.write(
                """STACK=plex
COMPONENT=plexcurator
SCRIPT=build-plex-node.sh
SCRIPT_VERSION=1.0.0
INSTALLED_AT=2024-01-02T03:04:05Z
"""
            )

    def kometa_fixture(self, version="2.4.8"):
        root = os.path.join(self.tmp.name, "kometa-test-root")
        os.makedirs(root, exist_ok=True)
        source = os.path.join(self.tmp.name, f"Kometa-{version}")
        os.makedirs(source, exist_ok=True)
        with open(os.path.join(source, "pyproject.toml"), "w") as stream:
            stream.write(
                f'[project]\nname = "kometa-fixture"\nversion = "{version}"\nrequires-python = ">=3.12"\n'
            )
        requirements = os.path.join(source, "requirements.txt")
        with open(requirements, "w") as stream:
            stream.write("")
        with open(os.path.join(source, "kometa.py"), "w") as stream:
            stream.write("# offline Kometa fixture\n")

        archive = os.path.join(self.tmp.name, f"kometa-{version}.tar.gz")
        with tarfile.open(archive, "w:gz") as stream:
            stream.add(source, arcname=f"Kometa-{version}")
        with open(archive, "rb") as stream:
            archive_sha256 = hashlib.sha256(stream.read()).hexdigest()
        with open(requirements, "rb") as stream:
            requirements_sha256 = hashlib.sha256(stream.read()).hexdigest()

        fake_bin = os.path.join(self.tmp.name, "kometa-fake-bin")
        os.makedirs(fake_bin, exist_ok=True)
        curl = os.path.join(fake_bin, "curl")
        if not os.path.exists(curl):
            with open(curl, "w") as stream:
                stream.write(
                    "#!/bin/sh\n"
                    "set -eu\n"
                    'output=""\n'
                    'while [ "$#" -gt 0 ]; do\n'
                    '  if [ "$1" = "--output" ]; then output=$2; shift 2; else shift; fi\n'
                    "done\n"
                    'printf "%s\\n" "$KOMETA_TEST_ARCHIVE" >>"$KOMETA_CURL_LOG"\n'
                    'cp "$KOMETA_TEST_ARCHIVE" "$output"\n'
                )
            os.chmod(curl, 0o755)
        systemctl = os.path.join(fake_bin, "systemctl")
        if not os.path.exists(systemctl):
            with open(systemctl, "w") as stream:
                stream.write(
                    "#!/bin/sh\n" 'printf "%s\\n" "$*" >>"$SYSTEMCTL_LOG"\n' "exit 0\n"
                )
            os.chmod(systemctl, 0o755)

        env = {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "KOMETA_TEST_ROOT": root,
            "KOMETA_TEST_VERSION": version,
            "KOMETA_TEST_SHA256": archive_sha256,
            "KOMETA_TEST_REQUIREMENTS_SHA256": requirements_sha256,
            "KOMETA_TEST_ARCHIVE": archive,
            "KOMETA_CURL_LOG": os.path.join(self.tmp.name, "kometa-curl.log"),
            "SYSTEMCTL_LOG": os.path.join(self.tmp.name, "systemctl.log"),
        }
        return env, root

    def sh(self, *args, user="root", extra_env=None):
        env = dict(
            os.environ,
            DRIFT_LOG=os.path.join(self.tmp.name, "drift.jsonl"),
            BACKUP_RECEIPTS_LOG=os.path.join(
                self.tmp.name, "backup-receipts", "receipts.jsonl"
            ),
            PLEX_APPDATA_DIR=os.path.join(self.tmp.name, "plex-appdata"),
        )
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            [
                "bash",
                SCRIPT,
                "--config",
                self.cfg,
                "--install-dir",
                self.inst,
                "--wrapper",
                self.wrapper,
                "--user",
                user,
                "--marker",
                self.marker,
                *args,
            ],
            capture_output=True,
            text=True,
            env=env,
        )

    def install_for_selftest(self, user="root"):
        self.write_cfg()
        if user != "root":
            service_user = pwd.getpwnam(user)
            service_group = grp.getgrnam(user)
            os.chmod(self.tmp.name, 0o711)
            for path in (
                os.path.join(self.tmp.name, "Curated"),
                os.path.join(self.tmp.name, "Movies"),
                os.path.join(self.tmp.name, "bk"),
            ):
                os.makedirs(path, exist_ok=True)
                os.chown(path, service_user.pw_uid, service_group.gr_gid)
                os.chmod(path, 0o750)
        result = self.sh("--only", "install,state", user=user)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def selftest_python_stub(self, fake_bin):
        os.makedirs(fake_bin, exist_ok=True)
        python = os.path.join(fake_bin, "python3")
        with open(python, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                'if [ "$1" = "-m" ] && [ "$2" = "plexcurator" ]; then\n'
                '  case " $* " in\n'
                '    *" validate --skip-tools "*)\n'
                '      if [ "${SELFTEST_PLEX_DOWN:-0}" = "1" ]; then\n'
                '        echo "ERROR Plex unreachable or token rejected: fixture" >&2\n'
                "        exit 1\n"
                "      fi\n"
                '      echo "config OK"\n'
                "      exit 0 ;;\n"
                '    *" --dry-run run "*) echo "dry-run fixture"; exit 0 ;;\n'
                "  esac\n"
                "fi\n"
                f'exec "{sys.executable}" "$@"\n'
            )
        os.chmod(python, 0o755)
        findmnt = os.path.join(fake_bin, "findmnt")
        with open(findmnt, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                'case " $* " in\n'
                '  *" -o FSTYPE "*) printf "cifs\\n" ;;\n'
                '  *" -o SOURCE,FSTYPE "*) printf "//fixture/backup cifs\\n" ;;\n'
                '  *" -o OPTIONS "*) printf "rw,relatime\\n" ;;\n'
                '  *) printf "//fixture/backup cifs\\n" ;;\n'
                "esac\n"
            )
        os.chmod(findmnt, 0o755)

    def test_missing_config_check_creates_nothing_then_real_run_writes_template_and_stops(
        self,
    ):
        r = self.sh("--check")
        self.assertEqual(r.returncode, 2, r.stdout + r.stderr)
        self.assertFalse(os.path.exists(self.cfg))
        r = self.sh()
        self.assertEqual(r.returncode, 2)
        self.assertTrue(os.path.exists(self.cfg))
        self.assertIn('mode = "observe"', open(self.cfg).read())
        self.assertIn("Fill in every value", r.stdout)

    def test_kometa_check_install_and_pin_update_are_isolated_and_preserve_config(self):
        self.write_cfg()
        env, root = self.kometa_fixture()
        check = self.sh("--check", "--only", "kometa", extra_env=env)
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        self.assertIn("WOULD: install pinned Kometa v2.4.8", check.stdout)
        self.assertFalse(os.path.exists(os.path.join(root, "opt", "kometa")))
        self.assertFalse(os.path.exists(env["KOMETA_CURL_LOG"]))

        plan = self.sh("--print-plan", extra_env=env)
        self.assertEqual(plan.returncode, 0, plan.stdout + plan.stderr)
        self.assertIn("kometa", plan.stdout)
        self.assertFalse(os.path.exists(os.path.join(root, "opt", "kometa")))

        installed = self.sh("--only", "kometa", extra_env=env)
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        app = os.path.join(root, "opt", "kometa", "app")
        venv = os.path.join(root, "opt", "kometa", "venv")
        config = os.path.join(root, "etc", "kometa", "config.yml")
        with open(os.path.join(app, "pyproject.toml")) as stream:
            self.assertIn('version = "2.4.8"', stream.read())
        self.assertTrue(os.path.isfile(os.path.join(venv, "bin", "python")))
        self.assertIn("REPLACE_WITH_PLEX_TOKEN", open(config).read())
        self.assertEqual(os.stat(config).st_mode & 0o777, 0o640)
        original_config = open(config, "rb").read()
        self.assertEqual(len(open(env["KOMETA_CURL_LOG"]).read().splitlines()), 1)
        units = self.sh("--only", "units", extra_env=env)
        self.assertEqual(units.returncode, 0, units.stdout + units.stderr)
        self.assertIn("disable --now kometa.timer", open(env["SYSTEMCTL_LOG"]).read())

        def snapshot(path):
            entries = []
            for directory, subdirs, files in os.walk(path):
                for name in sorted(subdirs + files):
                    target = os.path.join(directory, name)
                    info = os.lstat(target)
                    entries.append(
                        (
                            os.path.relpath(target, path),
                            info.st_mode,
                            info.st_size,
                            info.st_mtime_ns,
                        )
                    )
            return entries

        before_check = snapshot(os.path.join(root, "opt", "kometa"))
        adopted = self.sh("--check", "--only", "kometa", extra_env=env)
        self.assertEqual(adopted.returncode, 0, adopted.stdout + adopted.stderr)
        self.assertIn("RESULT (--check): 0 change(s) would be made", adopted.stdout)
        self.assertEqual(snapshot(os.path.join(root, "opt", "kometa")), before_check)
        self.assertEqual(len(open(env["KOMETA_CURL_LOG"]).read().splitlines()), 1)
        adopted_run = self.sh("--only", "kometa", extra_env=env)
        self.assertEqual(
            adopted_run.returncode, 0, adopted_run.stdout + adopted_run.stderr
        )
        self.assertIn("RESULT: 0 change(s) made", adopted_run.stdout)
        self.assertEqual(len(open(env["KOMETA_CURL_LOG"]).read().splitlines()), 1)

        update_env, update_root = self.kometa_fixture("2.4.9")
        self.assertEqual(update_root, root)
        updated = self.sh("--only", "kometa", extra_env=update_env)
        self.assertEqual(updated.returncode, 0, updated.stdout + updated.stderr)
        with open(os.path.join(app, "pyproject.toml")) as stream:
            self.assertIn('version = "2.4.9"', stream.read())
        self.assertEqual(open(config, "rb").read(), original_config)
        self.assertEqual(sorted(os.listdir(os.path.dirname(app))), ["app", "venv"])
        self.assertEqual(len(open(env["KOMETA_CURL_LOG"]).read().splitlines()), 2)

    def test_kometa_unit_uses_read_only_config_and_enables_utc_timer(self):
        self.write_cfg()
        env, root = self.kometa_fixture()
        config = os.path.join(root, "etc", "kometa", "config.yml")
        os.makedirs(os.path.dirname(config), exist_ok=True)
        with open(config, "w") as stream:
            stream.write(
                "plex:\n  url: http://127.0.0.1:32400\n  token: fixture\nlibraries: {}\n"
            )

        result = self.sh("--only", "units", extra_env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        unit_dir = os.path.join(root, "etc", "systemd", "system")
        with open(os.path.join(unit_dir, "kometa.service")) as stream:
            service = stream.read()
        with open(os.path.join(unit_dir, "kometa.timer")) as stream:
            timer = stream.read()
        self.assertIn("User=kometa", service)
        self.assertIn("Group=kometa", service)
        self.assertIn("--read-only-config --run", service)
        self.assertIn(
            os.path.join(root, "opt", "kometa", "venv", "bin", "python"), service
        )
        self.assertIn("OnCalendar=*-*-* 06:00:00 UTC", timer)
        self.assertIn("RandomizedDelaySec=5min", timer)
        self.assertIn("Persistent=true", timer)
        self.assertIn("restart kometa.timer", open(env["SYSTEMCTL_LOG"]).read())

    def test_template_config_is_rejected_before_any_change(self):
        self.sh()  # creates the template
        r = self.sh("--only", "prereqs")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("config invalid", r.stdout)
        self.assertFalse(os.path.exists(self.marker))

    def test_check_skips_write_probe_but_real_run_keeps_it(self):
        self.write_cfg()
        fake_bin = os.path.join(self.tmp.name, "bin")
        os.makedirs(fake_bin)
        python = os.path.join(fake_bin, "python3")
        with open(python, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                'if [ "$1" = "-m" ] && [ "$2" = "plexcurator" ] && [ "$3" = "validate" ]; then\n'
                '  echo "config OK"\n'
                "  exit 0\n"
                "fi\n"
                f'exec "{sys.executable}" "$@"\n'
            )
        os.chmod(python, 0o755)
        runuser = os.path.join(fake_bin, "runuser")
        with open(runuser, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                'printf "%s\\n" "$*" >>"$RUNUSER_LOG"\n'
                'case "$*" in *".plexcurator-write-probe."*) exit 1 ;; esac\n'
                "exit 0\n"
            )
        os.chmod(runuser, 0o755)
        runuser_log = os.path.join(self.tmp.name, "runuser.log")
        env = {
            "PATH": f"{fake_bin}:{os.environ['PATH']}",
            "RUNUSER_LOG": runuser_log,
        }

        checked = self.sh(
            "--check", "--only", "prereqs", user="www-data", extra_env=env
        )
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        self.assertIn(
            "not verified during --check (write probe skipped)", checked.stdout
        )
        self.assertNotIn("cannot write", checked.stdout)
        self.assertNotIn(".plexcurator-write-probe.", open(runuser_log).read())

        open(runuser_log, "w").close()
        real = self.sh("--only", "prereqs", user="www-data", extra_env=env)
        self.assertEqual(real.returncode, 0, real.stdout + real.stderr)
        self.assertIn("WARN: www-data cannot write", real.stdout)
        self.assertIn(".plexcurator-write-probe.", open(runuser_log).read())

    def test_converges_and_second_run_changes_nothing(self):
        self.write_cfg()
        self.write_legacy_marker()  # INSTALLED_AT must survive the migration and every re-run
        phases = ("--only", "install,state,layout,marker")
        r = self.sh("--check", *phases)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("would be made", r.stdout)
        self.assertFalse(os.path.exists(self.inst))  # --check changed nothing
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "state")))
        r = self.sh(*phases)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.path.isdir(os.path.join(self.inst, "plexcurator")))
        self.assertTrue(os.path.isfile(os.path.join(self.inst, "backup-receipt.sh")))
        self.assertTrue(os.path.isfile(os.path.join(self.inst, "backup-encrypt.sh")))
        self.assertTrue(os.path.isfile(self.wrapper))
        receipt_log = os.path.join(self.tmp.name, "backup-receipts", "receipts.jsonl")
        self.assertTrue(os.path.isfile(receipt_log))
        self.assertEqual(os.stat(receipt_log).st_mode & 0o777, 0o660)
        self.assertEqual(os.stat(self.wrapper).st_mode & 0o777, 0o755)
        wrapper_text = open(self.wrapper).read()
        self.assertIn("runuser -u root -- env", wrapper_text)
        self.assertIn(f"PYTHONPATH={self.inst}", wrapper_text)
        self.assertIn(f"PLEXCURATOR_CONFIG={self.cfg}", wrapper_text)
        self.assertTrue(
            os.path.exists(os.path.join(self.tmp.name, "state", "plexcurator.db"))
        )
        self.assertTrue(
            os.path.isdir(
                os.path.join(self.tmp.name, "Curated", "Watched", "1080hd", "5ch", "3")
            )
        )
        self.assertTrue(
            os.path.isdir(os.path.join(self.tmp.name, "Curated", "Watchlist"))
        )
        text = open(self.marker).read()
        for line in (
            "MARKER_SCHEMA=1",
            "STACK=plex",
            'COMPONENTS="plex,plexcurator,kometa"',
            'SCRIPT="build-plex-node.sh"',
            f'SCRIPT_VERSION="{script_version()}"',
            'SERVICE_USER="root"',
            'INSTALLED_AT="2024-01-02T03:04:05Z"',
        ):
            self.assertIn(line, text)
        r = self.sh(*phases)
        self.assertIn("RESULT: 0 change(s) made", r.stdout)
        self.assertEqual(open(self.marker).read(), text)  # INSTALLED_AT is kept
        self.assertEqual(open(self.wrapper).read(), wrapper_text)

    def test_wrapper_runs_as_configured_user_and_forwards_cli_arguments(self):
        self.write_cfg()
        user = "www-data"
        result = self.sh("--only", "install", user=user)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        fake_bin = os.path.join(self.tmp.name, "fake-bin")
        os.makedirs(fake_bin)
        runuser = os.path.join(fake_bin, "runuser")
        with open(runuser, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                'printf "%s\\n" "$@" >"$RUNUSER_ARGS"\n'
                'if [ "$1" != "-u" ] || [ "$2" != "www-data" ] || [ "$3" != "--" ]; then exit 90; fi\n'
                "shift 3\n"
                'exec "$@"\n'
            )
        os.chmod(runuser, 0o755)
        python = os.path.join(fake_bin, "python3")
        with open(python, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                'printf "%s\\n%s\\n" "$PLEXCURATOR_CONFIG" "$PYTHONPATH" >"$WRAPPER_CONTEXT"\n'
                'printf "%s\\n" "$@" >"$WRAPPER_ARGS"\n'
            )
        os.chmod(python, 0o755)

        runuser_args = os.path.join(self.tmp.name, "runuser-args")
        wrapper_context = os.path.join(self.tmp.name, "wrapper-context")
        wrapper_args = os.path.join(self.tmp.name, "wrapper-args")
        env = dict(
            os.environ,
            PATH=f"{fake_bin}:{os.environ['PATH']}",
            RUNUSER_ARGS=runuser_args,
            WRAPPER_CONTEXT=wrapper_context,
            WRAPPER_ARGS=wrapper_args,
        )
        invoked = subprocess.run(
            [self.wrapper, "--dry-run", "reclaim", "--all"],
            capture_output=True,
            text=True,
            env=env,
        )

        self.assertEqual(invoked.returncode, 0, invoked.stdout + invoked.stderr)
        self.assertEqual(open(runuser_args).read().splitlines()[:3], ["-u", user, "--"])
        self.assertEqual(
            open(wrapper_context).read().splitlines(), [self.cfg, self.inst]
        )
        self.assertEqual(
            open(wrapper_args).read().splitlines(),
            ["-m", "plexcurator", "--dry-run", "reclaim", "--all"],
        )

    def test_validate_and_layout_dry_run_do_not_create_database(self):
        self.write_cfg()
        state = os.path.join(self.tmp.name, "state")
        env = dict(
            os.environ,
            PYTHONPATH=os.path.dirname(os.path.dirname(SCRIPT)),
            PLEXCURATOR_CONFIG=self.cfg,
        )
        for args in (
            ("validate", "--offline", "--skip-tools"),
            ("init-layout", "--dry-run"),
        ):
            result = subprocess.run(
                ["python3", "-m", "plexcurator", "--config", self.cfg, *args],
                capture_output=True,
                text=True,
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(os.path.exists(state))

    def test_state_repairs_root_owned_database_and_sidecars(self):
        self.write_cfg()
        db = os.path.join(self.tmp.name, "state", "plexcurator.db")
        os.makedirs(os.path.dirname(db))
        paths = (db, f"{db}-wal", f"{db}-shm")
        for path in paths:
            with open(path, "wb"):
                pass

        service_user = pwd.getpwnam("www-data")
        service_group = grp.getgrnam("www-data")
        check = self.sh("--check", "--only", "state", user="www-data")
        self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        for path in paths:
            self.assertEqual(os.stat(path).st_uid, 0)
            self.assertIn(
                f"repair ownership of {path} to www-data:www-data", check.stdout
            )

        result = self.sh("--only", "state", user="www-data")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for path in paths:
            self.assertEqual(os.stat(path).st_uid, service_user.pw_uid)
            self.assertEqual(os.stat(path).st_gid, service_group.gr_gid)
            self.assertIn(
                f"repair ownership of {path} to www-data:www-data", result.stdout
            )

    def test_state_initializes_database_as_service_user(self):
        self.write_cfg()
        os.chmod(self.tmp.name, 0o711)
        service_user = pwd.getpwnam("www-data")
        service_group = grp.getgrnam("www-data")
        for path in (
            os.path.join(self.tmp.name, "Curated"),
            os.path.join(self.tmp.name, "bk"),
        ):
            os.makedirs(path, exist_ok=True)
            os.chown(path, service_user.pw_uid, service_group.gr_gid)
            os.chmod(path, 0o750)

        result = self.sh("--only", "install,state", user="www-data")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        db = os.path.join(self.tmp.name, "state", "plexcurator.db")
        self.assertTrue(os.path.isfile(db))
        self.assertEqual(os.stat(db).st_uid, service_user.pw_uid)
        self.assertEqual(os.stat(db).st_gid, service_group.gr_gid)

    def test_nas_write_failure_reports_group_and_mount_mode_fix(self):
        self.write_cfg()
        os.chmod(self.tmp.name, 0o711)
        os.chmod(os.path.join(self.tmp.name, "Curated"), 0o555)
        fake_bin = os.path.join(self.tmp.name, "bin")
        os.makedirs(fake_bin)
        findmnt = os.path.join(fake_bin, "findmnt")
        with open(findmnt, "w") as fh:
            fh.write("#!/bin/sh\nprintf 'cifs\\n'\n")
        os.chmod(findmnt, 0o755)
        python = os.path.join(fake_bin, "python3")
        with open(python, "w") as fh:
            fh.write(
                "#!/bin/sh\n"
                'if [ "$1" = "-m" ] && [ "$2" = "plexcurator" ] && [ "$3" = "validate" ]; then\n'
                '  echo "config OK"\n'
                "  exit 0\n"
                "fi\n"
                f'exec "{sys.executable}" "$@"\n'
            )
        os.chmod(python, 0o755)

        result = self.sh(
            "--only",
            "prereqs",
            user="www-data",
            extra_env={"PATH": f"{fake_bin}:{os.environ['PATH']}"},
        )

        self.assertIn("www-data cannot write", result.stdout)
        self.assertIn("group nas", result.stdout)
        self.assertIn("dir_mode=0775", result.stdout)
        self.assertIn("mount-nas.sh --add-user www-data", result.stdout)

    def test_selftest_uses_a_temporary_database_copy_without_converging(self):
        appdata = os.path.join(self.tmp.name, "plex-appdata")
        os.makedirs(appdata)
        with open(os.path.join(appdata, "Preferences.xml"), "w") as stream:
            stream.write("<Preferences />\n")
        self.install_for_selftest()
        fake_bin = os.path.join(self.tmp.name, "selftest-bin")
        self.selftest_python_stub(fake_bin)
        db = os.path.join(self.tmp.name, "state", "plexcurator.db")
        with open(db, "rb") as stream:
            before = stream.read()

        result = self.sh(
            "--selftest",
            extra_env={"PATH": f"{fake_bin}:{os.environ['PATH']}"},
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(
            "PASS  backup and integrity verification on temporary database copy",
            result.stdout,
        )
        self.assertIn(
            "PASS  nightly job dry-run on temporary database copy", result.stdout
        )
        self.assertIn("live emptyTrash intentionally not exercised", result.stdout)
        self.assertEqual(open(db, "rb").read(), before)
        self.assertFalse(os.path.exists(self.marker))

    def test_selftest_names_plex_and_state_failures_with_repairs(self):
        appdata = os.path.join(self.tmp.name, "plex-appdata")
        os.makedirs(appdata)
        with open(os.path.join(appdata, "Preferences.xml"), "w") as stream:
            stream.write("<Preferences />\n")
        self.install_for_selftest("www-data")
        selftest_dir = os.path.join(self.tmp.name, "Curated")
        os.chmod(selftest_dir, 0o555)
        db = os.path.join(self.tmp.name, "state", "plexcurator.db")
        os.chown(db, 0, 0)
        os.chmod(db, 0o644)
        fake_bin = os.path.join(self.tmp.name, "selftest-bin")
        self.selftest_python_stub(fake_bin)

        result = self.sh(
            "--selftest",
            user="www-data",
            extra_env={
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "SELFTEST_PLEX_DOWN": "1",
            },
        )

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Plex unreachable or token rejected", result.stdout)
        self.assertIn("mount-nas.sh --add-user www-data", result.stdout)
        self.assertIn(
            f"--only state --config {self.cfg} --user www-data", result.stdout
        )

    def test_marker_only_migrates_legacy_marker_without_converging(self):
        self.write_cfg()
        self.write_legacy_marker()
        before = open(self.marker).read()
        r = self.sh("--check", "--only", "marker")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("would be made", r.stdout)
        self.assertEqual(open(self.marker).read(), before)
        self.assertFalse(os.path.exists(self.inst))
        r = self.sh("--only", "marker")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('COMPONENTS="plex,plexcurator,kometa"', open(self.marker).read())
        self.assertIn('INSTALLED_AT="2024-01-02T03:04:05Z"', open(self.marker).read())
        self.assertFalse(os.path.exists(self.inst))

    def test_layout_never_removes_anything(self):
        self.write_cfg()
        os.makedirs(os.path.join(self.tmp.name, "Curated", "Watched", "keepme"))
        open(
            os.path.join(self.tmp.name, "Curated", "Watched", "keepme", "f.mkv"), "w"
        ).close()
        self.sh("--only", "install,state,layout")
        self.assertTrue(
            os.path.exists(
                os.path.join(self.tmp.name, "Curated", "Watched", "keepme", "f.mkv")
            )
        )

    def test_drift_record_written_by_verify_only_runs_and_print_plan(self):
        r = subprocess.run(
            ["bash", SCRIPT, "--print-plan"], capture_output=True, text=True
        )
        self.assertEqual(r.returncode, 0)
        self.assertEqual(
            r.stdout.strip(),
            "phases: prereqs packages install kometa state units layout marker verify",
        )
