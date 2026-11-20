import contextlib
import io
import os
import sqlite3
import tempfile
import unittest
from unittest import mock

from plexcurator import backup, cli, db
from plexcurator.version import APP_VERSION, SCHEMA_VERSION

STEP_NEXT = "ALTER TABLE movie ADD COLUMN note TEXT; CREATE INDEX movie_note ON movie(note);"  # a made-up next step


def schema_of(path):
    c = sqlite3.connect(path)
    rows = sorted(
        (t, n, " ".join((s or "").split()))
        for t, n, s in c.execute(
            "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'"
        )
    )
    c.close()
    return rows


class Versioning(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.p = lambda n: os.path.join(self.tmp.name, n)
        self.bk = self.p("bk")

    def tearDown(self):
        self.tmp.cleanup()

    def v_next(self):
        n = SCHEMA_VERSION + 1
        return mock.patch.multiple(
            db, MIGRATIONS={**db.MIGRATIONS, n: STEP_NEXT}, SCHEMA_VERSION=n
        )

    def test_steps_are_numbered_from_1_to_schema_version(self):
        self.assertEqual(sorted(db.MIGRATIONS), list(range(1, SCHEMA_VERSION + 1)))

    def test_fresh_database_is_stamped(self):
        c = db.connect(self.p("a.db"), now=1000)
        self.assertEqual(c.execute("PRAGMA user_version").fetchone()[0], SCHEMA_VERSION)
        self.assertEqual(
            tuple(
                c.execute(
                    "SELECT version, applied_at, app_version FROM schema_migration"
                ).fetchone()
            ),
            (1, 1000, APP_VERSION),
        )
        self.assertEqual(
            [
                r[0]
                for r in c.execute("SELECT version FROM schema_migration ORDER BY 1")
            ],
            list(range(1, SCHEMA_VERSION + 1)),
        )
        c.close()
        self.assertFalse(
            os.path.exists(self.bk)
        )  # nothing to back up on a new database

    def test_reopening_at_same_version_changes_nothing(self):
        db.connect(self.p("a.db")).close()
        before = schema_of(self.p("a.db"))
        c = db.connect(self.p("a.db"))
        self.assertEqual(
            c.execute("SELECT COUNT(*) FROM schema_migration").fetchone()[0],
            SCHEMA_VERSION,
        )
        c.close()
        self.assertEqual(schema_of(self.p("a.db")), before)

    def test_read_only_connection_never_creates_or_writes(self):
        path = self.p("a.db")
        db.connect(path).close()
        before = schema_of(path)
        conn = db.connect_read_only(path)
        self.assertEqual(conn.execute("PRAGMA query_only").fetchone()[0], 1)
        with self.assertRaises(sqlite3.OperationalError):
            conn.execute(
                "INSERT INTO movie(title, first_seen_at, updated_at) VALUES ('Nope', 1, 1)"
            )
        conn.close()
        self.assertEqual(schema_of(path), before)

        missing = self.p("not-created/db.sqlite")
        with self.assertRaises(db.SchemaError):
            db.connect_read_only(missing)
        self.assertFalse(os.path.exists(os.path.dirname(missing)))

    def test_migrating_from_current_equals_building_from_scratch_and_backs_up_first(
        self,
    ):
        db.connect(self.p("old.db")).close()  # a database at the current version
        c0 = db.connect(self.p("old.db"))
        c0.execute(
            "INSERT INTO movie(title, first_seen_at, updated_at) VALUES ('Keep', 1, 1)"
        )
        c0.commit()
        c0.close()
        with self.v_next():
            db.connect(self.p("scratch.db")).close()
            c = db.connect(self.p("old.db"), backup_dir=self.bk, now=2000)
            self.assertEqual(
                c.execute("PRAGMA user_version").fetchone()[0], SCHEMA_VERSION + 1
            )
            self.assertEqual(
                [
                    r[0]
                    for r in c.execute(
                        "SELECT version FROM schema_migration ORDER BY 1"
                    )
                ],
                list(range(1, SCHEMA_VERSION + 2)),
            )
            self.assertEqual(
                c.execute("SELECT title FROM movie").fetchone()[0], "Keep"
            )  # data survives
            c.close()
        self.assertEqual(schema_of(self.p("old.db")), schema_of(self.p("scratch.db")))
        (b,) = os.listdir(self.bk)
        self.assertIn(
            f"-schema{SCHEMA_VERSION}.db", b
        )  # the backup is the OLD version, named so
        self.assertEqual(
            sqlite3.connect(os.path.join(self.bk, b))
            .execute("PRAGMA user_version")
            .fetchone()[0],
            SCHEMA_VERSION,
        )

    def test_newer_database_is_refused_and_left_alone(self):
        db.connect(self.p("a.db")).close()
        c = sqlite3.connect(self.p("a.db"))
        c.execute("PRAGMA user_version = 99")
        c.close()
        before = schema_of(self.p("a.db"))
        with self.assertRaises(db.SchemaError) as cm:
            db.connect(self.p("a.db"), backup_dir=self.bk)
        self.assertIn("version 99", str(cm.exception))
        self.assertEqual(schema_of(self.p("a.db")), before)
        self.assertFalse(os.path.exists(self.bk))

    def test_pending_migration_without_backup_dir_is_refused(self):
        db.connect(self.p("a.db")).close()
        with self.v_next(), self.assertRaises(db.SchemaError):
            db.connect(self.p("a.db"))
        self.assertEqual(
            sqlite3.connect(self.p("a.db"))
            .execute("PRAGMA user_version")
            .fetchone()[0],
            SCHEMA_VERSION,
        )

    def test_unversioned_database_with_tables_is_not_guessed_at(self):
        c = sqlite3.connect(self.p("a.db"))
        c.execute("CREATE TABLE movie (id INTEGER)")
        c.commit()
        c.close()
        with self.assertRaises(db.SchemaError):
            db.connect(self.p("a.db"), backup_dir=self.bk)

    def test_backup_filename_records_schema_version(self):
        db.connect(self.p("a.db")).close()
        dest = backup.backup(self.p("a.db"), self.bk, 5, now=3000)
        self.assertRegex(
            os.path.basename(dest),
            rf"^plexcurator-\d{{8}}-\d{{6}}-schema{SCHEMA_VERSION}\.db$",
        )

    def test_backup_directory_is_created_after_local_copy_is_verified(self):
        db_path = self.p("a.db")
        db.connect(db_path).close()
        real_makedirs = os.makedirs
        directory_created = []

        def verify_before_create(path, *args, **kwargs):
            if path == self.bk:
                staged = [
                    os.path.join(self.tmp.name, name)
                    for name in os.listdir(self.tmp.name)
                    if name.startswith(".backup-") and name.endswith(".db")
                ]
                self.assertEqual(len(staged), 1)
                connection = sqlite3.connect(staged[0])
                self.assertEqual(
                    connection.execute("PRAGMA integrity_check").fetchone()[0], "ok"
                )
                connection.close()
                directory_created.append(True)
            return real_makedirs(path, *args, **kwargs)

        with mock.patch.object(backup.os, "makedirs", side_effect=verify_before_create):
            dest = backup.backup(db_path, self.bk, 5, now=3000)

        self.assertTrue(directory_created)
        self.assertTrue(os.path.isfile(dest))

    def test_version_flag_prints_app_and_schema(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as cm:
            cli.main(["--version"])
        self.assertEqual(cm.exception.code, 0)
        self.assertEqual(
            out.getvalue().strip(),
            f"plexcurator {APP_VERSION} (database schema {SCHEMA_VERSION})",
        )

    def test_cli_refuses_newer_database_with_a_clear_message(self):
        cfgp = self.p("c.toml")
        with open(cfgp, "w") as fh:
            fh.write(
                f"""[plex]
token = "t"
[radarr]
url = "http://r"
api_key = "k"
[storage]
backup_dir = "{self.bk}"
[folders]
managed = "{self.tmp.name}/Curated"
[advanced]
db_path = "{self.p("t.db")}"
"""
            )
        db.connect(self.p("t.db")).close()
        c = sqlite3.connect(self.p("t.db"))
        c.execute("PRAGMA user_version = 99")
        c.close()
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = cli.main(["-c", cfgp, "init-db"])
        self.assertEqual(rc, 1)
        self.assertIn("refusing to run", err.getvalue())
