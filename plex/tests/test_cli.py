import contextlib
import io
import json
import os
import sqlite3
import subprocess
import tarfile
import tempfile
import time
import urllib.error
from unittest import mock

from plexcurator import cli, config, db, identity, lifecycle, sync

from .helpers import (
    DAY,
    GB,
    NOW,
    Base,
    FakePlex,
    FakeRadarr,
    add_missing_plex_fts_tokenizer,
    fake_probe,
    plex_item,
)


class CliBase(Base):
    def setUp(self):
        super().setUp()
        self.conn.close()
        self.toml = os.path.join(self.root, "c.toml")
        self.appdata = os.path.join(self.root, "plex-appdata")
        self.receipts = os.path.join(self.root, "receipts.jsonl")
        self.kometa_dir = os.path.join(self.root, "kometa")
        self.kometa_config = os.path.join(self.kometa_dir, "config.yml")
        self.kometa_collections = os.path.join(self.kometa_dir, "collections")
        self.recipient_key = os.path.join(self.root, "fixture-public-key.asc")
        self.fake_bin = os.path.join(self.root, "fake-bin")
        self.encryption_helper = os.path.abspath(
            os.path.join(
                os.path.dirname(__file__),
                "..",
                "..",
                "os",
                "common",
                "backup",
                "backup-encrypt.sh",
            )
        )
        self.receipt_helper = os.path.abspath(
            os.path.join(
                os.path.dirname(__file__),
                "..",
                "..",
                "os",
                "common",
                "backup",
                "backup-receipt.sh",
            )
        )
        os.makedirs(os.path.join(self.appdata, "Plug-in Support", "Preferences"))
        with open(os.path.join(self.appdata, "Preferences.xml"), "w") as stream:
            stream.write("<Preferences />\n")
        with open(
            os.path.join(
                self.appdata,
                "Plug-in Support",
                "Preferences",
                "fixture.json",
            ),
            "w",
        ) as stream:
            stream.write('{"fixture": true}\n')
        os.makedirs(os.path.join(self.kometa_collections, "fixture"))
        with open(self.kometa_config, "w", encoding="utf-8") as stream:
            stream.write("plex:\n  token: FIXTURE_NOT_A_REAL_SECRET\n")
        with open(
            os.path.join(self.kometa_collections, "fixture", "collection.yml"),
            "w",
            encoding="utf-8",
        ) as stream:
            stream.write("collections: {}\n")
        os.makedirs(os.path.join(self.kometa_dir, "logs"))
        with open(os.path.join(self.kometa_dir, "logs", "fixture.log"), "w") as stream:
            stream.write("must not be backed up\n")
        with open(
            os.path.join(self.kometa_dir, "config.cache"), "w", encoding="utf-8"
        ) as stream:
            stream.write("must not be backed up\n")
        os.makedirs(self.fake_bin)
        fake_gpg = os.path.join(self.fake_bin, "gpg")
        with open(fake_gpg, "w", encoding="utf-8") as stream:
            stream.write(
                "#!/bin/sh\n"
                '[ "${FAKE_GPG_FAIL:-0}" = 1 ] && exit 1\n'
                "output=\n"
                'while [ "$#" -gt 0 ]; do\n'
                '  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi\n'
                "done\n"
                '[ -n "$output" ] || exit 2\n'
                'printf "FAKE-OPENPGP-CIPHERTEXT\\n" >"$output"\n'
            )
        os.chmod(fake_gpg, 0o755)
        with open(self.recipient_key, "w", encoding="ascii") as stream:
            stream.write(
                "-----BEGIN PGP PUBLIC KEY BLOCK-----\n"
                "FAKE FIXTURE KEY ONLY\n"
                "-----END PGP PUBLIC KEY BLOCK-----\n"
            )
        database_dir = os.path.join(self.appdata, "Plug-in Support", "Databases")
        os.makedirs(database_dir)
        plex_database = sqlite3.connect(
            os.path.join(database_dir, "com.plexapp.plugins.library.db-2026-10-28")
        )
        plex_database.execute("CREATE TABLE library_fixture (id INTEGER)")
        plex_database.commit()
        plex_database.close()
        live_database = sqlite3.connect(
            os.path.join(database_dir, "com.plexapp.plugins.library.db")
        )
        live_database.execute("CREATE TABLE live_fixture (id INTEGER)")
        live_database.commit()
        live_database.close()
        self.write_cfg("observe")

    def write_cfg(self, mode, extra="", root_extra="", storage_extra=""):
        with open(self.toml, "w") as fh:
            fh.write(
                f"""mode = "{mode}"
{root_extra}
[plex]
token = "t"
libraries = "all"
[radarr]
url = "http://r"
api_key = "k"
[storage]
{storage_extra}
backup_dir = "{self.root}/bk"
[folders]
managed = "{self.root}/Curated"
[[folders.unmanaged]]
path = "{self.root}/Movies"
lifecycle = true
[advanced]
db_path = "{self.root}/t.db"
alert_file = "{self.root}/ALERT"
max_sync_age_hours = 100000
{extra}"""
            )
        self.conn = db.connect(os.path.join(self.root, "t.db"))

    def main(self, *args, plex=None, radarr=None, free=(500 * GB, 1000 * GB)):
        out = io.StringIO()
        plex = plex or FakePlex()
        with (
            mock.patch.object(
                cli, "_clients", lambda cfg: (plex, radarr or FakeRadarr())
            ),
            mock.patch.object(cli, "_probe_fn", lambda cfg: fake_probe()),
            mock.patch("plexcurator.sync._default_probe", lambda cfg: fake_probe()),
            mock.patch.object(lifecycle, "usage", lambda p: free),
            mock.patch.object(cli.B, "_require_nas_mount"),
            mock.patch.dict(
                os.environ,
                {
                    "PLEX_APPDATA_DIR": self.appdata,
                    "BACKUP_RECEIPT_HELPER": self.receipt_helper,
                    "BACKUP_RECEIPTS_LOG": self.receipts,
                    "BACKUP_ENCRYPTION_HELPER": self.encryption_helper,
                    "BACKUP_GPG_RECIPIENT_FILE": self.recipient_key,
                    "KOMETA_CONFIG_PATH": self.kometa_config,
                    "KOMETA_COLLECTIONS_PATH": self.kometa_collections,
                    "PATH": self.fake_bin + os.pathsep + os.environ.get("PATH", ""),
                },
            ),
            contextlib.redirect_stdout(out),
        ):
            rc = cli.main(["-c", self.toml, *args])
        self.out = out.getvalue()
        return rc


class Modes(CliBase):
    def library(self):
        self.old = self.mkfile("Movies/Seen {tmdb-1}/seen.mkv", b"s")
        self.stale = self.mkfile("Movies/Stale {tmdb-2}/stale.mkv", b"t")
        return FakePlex(
            [
                plex_item(1, "Seen", self.old, tmdb=1, views=1, added=NOW - 10 * DAY),
                plex_item(2, "Stale", self.stale, tmdb=2, added=NOW - 900 * DAY),
            ]
        )

    def test_radarr_update_failure_is_reported_in_summary_and_alert_without_retry(self):
        self.write_cfg("organize")
        old = self.mkfile("Movies/Alien (1979)/alien.mkv", b"movie")
        previous_move = int(time.time()) - 60
        movie_id = identity.create_movie(
            self.conn, "Alien", 1979, {"tmdb": "348"}, previous_move
        )
        sync.upsert_file(
            self.conn,
            config.load(self.toml),
            movie_id,
            old,
            os.stat(old),
            "fixture-alien",
            previous_move,
        )
        db.add_event(self.conn, movie_id, previous_move, "moved", value=old)
        self.conn.commit()
        plex = FakePlex([plex_item(1, "Alien", old, tmdb=348, year=1979, views=1)])
        radarr = FakeRadarr(
            [{"id": 42, "tmdbId": 348, "path": os.path.dirname(old)}],
            track_error=urllib.error.HTTPError(
                "http://r/api/v3/movie/42", 405, "Method Not Allowed", {}, None
            ),
        )

        with self.assertLogs("plexcurator", level="ERROR"):
            rc = self.main("run", plex=plex, radarr=radarr)

        self.assertEqual(rc, 2)
        self.assertFalse(os.path.exists(old))
        target = self.conn.execute("SELECT path FROM file").fetchone()[0]
        self.assertTrue(os.path.exists(target))
        target_folder = os.path.dirname(target)
        self.assertIn("Radarr update failures: 1", self.out)
        self.assertIn("Alien", self.out)
        self.assertIn(target_folder, self.out)
        self.assertIn("HTTP 405", self.out)
        self.assertIn("no retry attempted", self.out)
        with open(os.path.join(self.root, "ALERT")) as fh:
            alert = fh.read()
        self.assertIn("Alien", alert)
        self.assertIn(target_folder, alert)
        self.assertIn("HTTP 405", alert)
        self.assertEqual(len(radarr.calls), 1)

    def test_radarr_write_selftest_is_explicit_and_reports_success(self):
        with (
            mock.patch.object(cli.V, "report", return_value=0),
            mock.patch.object(cli.clients.Radarr, "selftest") as selftest,
        ):
            rc = self.main("--selftest", "validate")

        self.assertEqual(rc, 0)
        selftest.assert_called_once()
        self.assertIn("Radarr write selftest passed", self.out)

    def test_radarr_write_selftest_reports_rejection_and_preserves_http_status(self):
        error = urllib.error.HTTPError(
            "http://r/api/v3/movie/42", 405, "Method Not Allowed", {}, None
        )
        with (
            mock.patch.object(cli.V, "report", return_value=0),
            mock.patch.object(cli.clients.Radarr, "selftest", side_effect=error),
        ):
            rc = self.main("--selftest", "validate")

        self.assertEqual(rc, 1)
        self.assertIn("Radarr write selftest failed: HTTP 405", self.out)

    def test_radarr_write_selftest_does_not_run_when_validation_fails(self):
        with (
            mock.patch.object(cli.V, "report", return_value=1),
            mock.patch.object(cli.clients.Radarr, "selftest") as selftest,
        ):
            rc = self.main("--selftest", "validate")

        self.assertEqual(rc, 1)
        selftest.assert_not_called()

    def test_observe_collects_creates_tree_and_changes_nothing_else(self):
        plex = self.library()
        self.assertEqual(self.main("run", plex=plex), 0)
        self.assertTrue(
            os.path.isdir(
                os.path.join(self.root, "Curated", "Watched", "4khd", "7ch", "0")
            )
        )
        self.assertTrue(os.path.exists(self.old))
        self.assertIn("1 move(s) (not applied: mode is observe)", self.out)
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM movie").fetchone()[0], 2
        )

    def test_organize_moves_but_never_deletes_even_when_space_is_low(self):
        self.write_cfg("organize")
        plex = self.library()
        rc = self.main("run", plex=plex, free=(100 * GB, 1000 * GB))
        self.assertFalse(os.path.exists(self.old))
        self.assertTrue(os.path.exists(self.stale))
        self.assertIn("not deleted: mode is organize", self.out)
        self.assertEqual(
            rc, 2
        )  # the 1-byte fixture files cannot free 5% of 1 TB: "rules exhausted" is right

    def test_reclaim_deletes_only_what_rules_allow_and_stops_at_target(self):
        self.write_cfg("reclaim")
        plex = self.library()
        plex.live = {"2": {"ratingKey": "2"}}
        self.main("run", plex=plex, free=(300 * GB, 1000 * GB))
        self.assertFalse(os.path.exists(self.stale))
        self.assertEqual(
            self.conn.execute("SELECT state FROM movie WHERE title='Stale'").fetchone()[
                0
            ],
            "retired",
        )
        self.assertEqual(
            self.conn.execute("SELECT state FROM movie WHERE title='Seen'").fetchone()[
                0
            ],
            "present",
        )
        self.assertIn(("trash", "1"), plex.calls)

    def test_age_only_first_run_requires_confirmation_then_deletes(self):
        self.write_cfg(
            "reclaim",
            extra='[lifecycle]\nage_only = ["stale_unmanaged"]\n',
        )
        age_at = int(time.time()) - 900 * DAY
        path = self.mkfile("Movies/Age Only (2000)/Age Only.mkv", b"age-only")
        plex = FakePlex([plex_item(7, "Age Only", path, tmdb=7, added=age_at)])

        with self.assertLogs("plexcurator", level="ERROR"):
            rc = self.main("run", plex=plex, free=(800 * GB, 1000 * GB))
        self.assertEqual(rc, 2)
        self.assertTrue(os.path.exists(path))
        alert = open(os.path.join(self.root, "ALERT")).read()
        self.assertIn("Age Only", alert)
        self.assertIn("stale_unmanaged", alert)
        self.assertIn("900 days old", alert)
        self.assertIn("Candidate list SHA-256", alert)

        self.assertEqual(
            self.main(
                "reclaim",
                "--confirm-age-only",
                plex=plex,
                free=(800 * GB, 1000 * GB),
            ),
            0,
        )
        self.assertFalse(os.path.exists(path))
        reason = self.conn.execute(
            "SELECT reason FROM deletion WHERE movie_id="
            "(SELECT id FROM movie WHERE title='Age Only')"
        ).fetchone()[0]
        self.assertIn("age only: stale_unmanaged, 900 days old", reason)

    def test_age_only_dry_run_shows_separate_sizes_and_does_not_confirm(self):
        self.write_cfg("observe")
        path = self.mkfile("Movies/Age Only (2000)/Age Only.mkv", b"age-only")
        plex = FakePlex([plex_item(8, "Age Only", path, tmdb=8, added=NOW - 900 * DAY)])
        self.assertEqual(self.main("run", plex=plex), 0)
        self.write_cfg(
            "reclaim",
            extra='[lifecycle]\nage_only = ["stale_unmanaged"]\n',
        )
        self.assertEqual(
            self.main(
                "--dry-run",
                "reclaim",
                plex=plex,
                free=(800 * GB, 1000 * GB),
            ),
            0,
        )
        self.assertIn("age only: 1 candidate(s)", self.out)
        self.assertIn("space-driven: 0 candidate(s)", self.out)
        self.assertIn("age only", self.out)
        self.assertIsNone(
            self.conn.execute(
                "SELECT value FROM meta WHERE key='age_only_confirmed_policy'"
            ).fetchone()
        )

    def test_dry_run_changes_nothing_in_any_mode(self):
        self.write_cfg("reclaim")
        plex = self.library()
        self.main("--dry-run", "run", plex=plex, free=(100 * GB, 1000 * GB))
        self.assertTrue(os.path.exists(self.old) and os.path.exists(self.stale))
        self.assertFalse(
            os.path.exists(os.path.join(self.root, "Curated", "Watchlist"))
        )
        self.assertIn("dry run", self.out)

    def test_reclaim_preview_lists_all_candidates_without_mutating(self):
        self.write_cfg("reclaim")
        items = []
        for index in range(55):
            title = f"Old {index:02d}"
            path = self.mkfile(f"Movies/{title}/{title}.mkv", f"movie-{index}".encode())
            items.append(
                plex_item(
                    index + 1,
                    title,
                    path,
                    tmdb=index + 1,
                    added=NOW - 900 * DAY,
                )
            )
        plex = FakePlex(items)
        self.assertEqual(self.main("run", plex=plex, free=(500 * GB, 1000 * GB)), 0)
        before_files = sorted(
            os.path.relpath(os.path.join(root, name), self.root)
            for root, _, names in os.walk(os.path.join(self.root, "Movies"))
            for name in names
        )
        before_movies = [
            tuple(row)
            for row in self.conn.execute(
                "SELECT title, state, updated_at FROM movie ORDER BY title"
            )
        ]

        with (
            mock.patch.object(
                lifecycle,
                "execute",
                side_effect=AssertionError("preview must not delete"),
            ),
            mock.patch.object(
                cli.db, "connect", side_effect=AssertionError("preview must not write")
            ),
        ):
            self.assertEqual(
                self.main("reclaim", "--preview", free=(500 * GB, 1000 * GB)), 0
            )
            self.assertLess(len(self.out.splitlines()), 100)
            self.assertIn("candidate summary: 55 eligible candidate(s)", self.out)
            self.assertIn("Old 00", self.out)
            self.assertIn("since added date", self.out)
            self.assertIn("threshold=365 days (source=default)", self.out)
            self.assertIn("source=default", self.out)
            self.assertIn("10 candidate(s) omitted", self.out)
            self.assertIn("real run would not act now", self.out)

            self.assertEqual(
                self.main("reclaim", "--preview", free=(300 * GB, 1000 * GB)), 0
            )
            self.assertIn("real run would act now", self.out)

            self.assertEqual(
                self.main("--dry-run", "reclaim", "--all", free=(500 * GB, 1000 * GB)),
                0,
            )
            self.assertIn("Old 54", self.out)
            self.assertNotIn("candidate(s) omitted", self.out)

        after_files = sorted(
            os.path.relpath(os.path.join(root, name), self.root)
            for root, _, names in os.walk(os.path.join(self.root, "Movies"))
            for name in names
        )
        after_movies = [
            tuple(row)
            for row in self.conn.execute(
                "SELECT title, state, updated_at FROM movie ORDER BY title"
            )
        ]
        self.assertEqual(after_files, before_files)
        self.assertEqual(after_movies, before_movies)
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM deletion").fetchone()[0], 0
        )

    def test_exhausted_rules_exit_2_with_alert_file(self):
        self.write_cfg(
            "reclaim",
            storage_extra="min_free_pct = 50\nreclaim_to_pct = 60\n",
        )
        p = self.mkfile("Movies/Loved {tmdb-3}/l.mkv")
        plex = FakePlex([plex_item(3, "Loved", p, tmdb=3, rating=10.0, views=1)])
        with self.assertLogs("plexcurator", level="ERROR"):
            rc = self.main("run", plex=plex, free=(100 * GB, 1000 * GB))
        self.assertEqual(rc, 2)
        text = open(os.path.join(self.root, "ALERT")).read()
        self.assertIn("manual aggressive intervention is required", text)
        self.assertIn("threshold 50% free (reclaim to 60%)", text)
        self.assertIn("reclaim below 50%, to 60%", self.out)
        self.assertTrue(
            os.path.exists(
                os.path.join(self.root, "Curated", "Watched", "1080hd", "5ch", "5")
            )
        )
        rc = self.main(
            "run", plex=plex, free=(500 * GB, 1000 * GB)
        )  # space recovered: alert clears
        self.assertEqual(rc, 0)
        self.assertFalse(os.path.exists(os.path.join(self.root, "ALERT")))

    def test_unidentified_movie_warns_by_default_without_failing(self):
        self.write_cfg("reclaim")
        p = self.mkfile("Movies/Home/christmas.mkv")
        plex = FakePlex([plex_item(9, "Christmas", p, views=1)])
        with self.assertLogs("plexcurator", level="WARNING") as logged:
            rc = self.main("run", plex=plex, free=(500 * GB, 1000 * GB))
        self.assertEqual(rc, 0)
        self.assertIn("ALERT:", logged.output[0])
        self.assertIn("unidentified", logged.output[0])
        with open(os.path.join(self.root, "ALERT")) as fh:
            alert = fh.read()
        self.assertIn("[WARN:unidentified]", alert)
        self.assertTrue(os.path.exists(p))

    def test_unidentified_movie_can_be_configured_to_fail(self):
        self.write_cfg("reclaim", root_extra='alert_unidentified = "fail"')
        p = self.mkfile("Movies/Home/christmas.mkv")
        plex = FakePlex([plex_item(9, "Christmas", p, views=1)])
        with self.assertLogs("plexcurator", level="ERROR"):
            rc = self.main("run", plex=plex, free=(500 * GB, 1000 * GB))
        self.assertEqual(rc, 2)
        with open(os.path.join(self.root, "ALERT")) as fh:
            self.assertIn("[ERROR]", fh.read())
        self.assertTrue(os.path.exists(p))

    def test_failure_to_write_warning_alert_is_a_real_error(self):
        self.write_cfg("reclaim")
        p = self.mkfile("Movies/Home/christmas.mkv")
        plex = FakePlex([plex_item(9, "Christmas", p, views=1)])
        alert_dir = os.path.join(self.root, "alert-directory")
        os.mkdir(alert_dir)
        with open(self.toml) as fh:
            config_text = fh.read()
        with open(self.toml, "w") as fh:
            fh.write(
                config_text.replace(
                    f'alert_file = "{self.root}/ALERT"',
                    f'alert_file = "{alert_dir}"',
                )
            )
        with self.assertLogs("plexcurator", level="ERROR"):
            rc = self.main("run", plex=plex, free=(500 * GB, 1000 * GB))
        self.assertEqual(rc, 1)

    def test_invalid_config_stops_before_touching_anything(self):
        self.write_cfg("yolo")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = self.main("run")
        self.assertEqual(rc, 1)
        self.assertIn("mode must be", err.getvalue())

    def test_queries_all_run(self):
        self.main("run", plex=self.library())
        self.main("query", "list")
        for name in self.out.split():
            self.assertEqual(self.main("query", name), 0, name)

    def test_backup_command(self):
        self.main("run", plex=self.library())
        self.assertEqual(self.main("backup"), 0)
        self.assertIn("backup:", self.out)
        self.assertEqual(len(os.listdir(os.path.join(self.root, "bk"))), 4)
        with open(self.receipts, encoding="utf-8") as stream:
            receipts = [json.loads(line) for line in stream]
        self.assertEqual(
            {receipt["recovery_group"] for receipt in receipts},
            {
                "plex",
                "kometa",
            },
        )
        plex_receipt = next(
            receipt for receipt in receipts if receipt["recovery_group"] == "plex"
        )
        self.assertEqual(plex_receipt["stack"], "plex")
        self.assertEqual(plex_receipt["archive_class"], "local")
        self.assertEqual(plex_receipt["result"], "ok")
        self.assertEqual(
            plex_receipt["bytes"], os.path.getsize(plex_receipt["artifact_path"])
        )

    def test_backup_can_skip_kometa_for_isolated_plex_selftests(self):
        self.assertEqual(self.main("--skip-kometa-backup", "backup"), 0)

        self.assertEqual(len(os.listdir(os.path.join(self.root, "bk"))), 1)
        with open(self.receipts, encoding="utf-8") as stream:
            receipts = [json.loads(line) for line in stream]
        self.assertEqual([receipt["recovery_group"] for receipt in receipts], ["plex"])

    def test_backup_accepts_plex_snapshot_with_unavailable_fts_tokenizer(self):
        database_path = os.path.join(
            self.appdata,
            "Plug-in Support",
            "Databases",
            "com.plexapp.plugins.library.db-2026-10-28",
        )
        add_missing_plex_fts_tokenizer(database_path)
        connection = sqlite3.connect(database_path)
        try:
            with self.assertRaisesRegex(
                sqlite3.OperationalError, "no such tokenizer: collating"
            ):
                connection.execute("PRAGMA integrity_check").fetchone()
        finally:
            connection.close()

        self.assertEqual(self.main("--skip-kometa-backup", "backup"), 0, self.out)
        self.assertIn("backup:", self.out)

    def test_backup_rejects_corrupt_or_truncated_plex_library_snapshot(self):
        original_copy = cli.B._copy_stable_file
        snapshot_name = "com.plexapp.plugins.library.db-2026-10-28"

        for corruption in ("truncate", "alter"):
            with self.subTest(corruption=corruption):
                if os.path.exists(self.receipts):
                    os.remove(self.receipts)

                def copy_then_corrupt(source, staged, description):
                    signature = original_copy(source, staged, description)
                    if description == "Plex dated library database backup":
                        if corruption == "truncate":
                            os.truncate(staged, signature[0] - 1)
                        else:
                            with open(staged, "r+b") as stream:
                                original_byte = stream.read(1)
                                stream.seek(0)
                                stream.write(bytes([original_byte[0] ^ 1]))
                    return signature

                with (
                    mock.patch.object(
                        cli.B, "_copy_stable_file", side_effect=copy_then_corrupt
                    ),
                    self.assertRaisesRegex(
                        RuntimeError,
                        "Plex library database snapshot .*failed size, SHA-256, "
                        "or read-only query check",
                    ) as error,
                ):
                    self.main("--skip-kometa-backup", "backup")

                self.assertIn(snapshot_name, str(error.exception))
                expected_check = (
                    "size mismatch" if corruption == "truncate" else "SHA-256 mismatch"
                )
                self.assertIn(expected_check, str(error.exception))
                with open(self.receipts, encoding="utf-8") as stream:
                    receipt = json.loads(stream.readline())
                self.assertEqual(receipt["result"], "failed")

    def test_backup_has_the_data_and_leaves_no_partials(self):
        self.main("run", plex=self.library())
        self.assertEqual(self.main("backup"), 0)
        bk = os.path.join(self.root, "bk")
        name = next(name for name in os.listdir(bk) if name.startswith("plexcurator-"))
        self.assertTrue(name.endswith(".tar.gz"), name)
        path = os.path.join(bk, name)
        self.assertGreater(os.path.getsize(path), 0)
        with tarfile.open(path, "r:gz") as archive:
            members = set(archive.getnames())
            self.assertIn("plexcurator.db", members)
            self.assertIn("plex-config/Preferences.xml", members)
            self.assertIn(
                "plex-config/Plug-in Support/Preferences/fixture.json", members
            )
            self.assertIn(
                "plex-config/Plug-in Support/Databases/"
                "com.plexapp.plugins.library.db-2026-10-28",
                members,
            )
            self.assertNotIn(
                "plex-config/Plug-in Support/Databases/com.plexapp.plugins.library.db",
                members,
            )
            self.assertFalse(
                any(
                    part in name
                    for name in members
                    for part in ("Cache/", "Logs/", "Metadata/", "Media/")
                )
            )
            with tempfile.NamedTemporaryFile(suffix=".db") as local:
                local.write(archive.extractfile("plexcurator.db").read())
                local.flush()
                connection = sqlite3.connect(local.name)
                self.assertGreater(
                    connection.execute("select count(*) from movie").fetchone()[0],
                    0,
                )
                connection.close()
        live = os.path.dirname(os.path.join(self.root, "t.db"))
        self.assertEqual([f for f in os.listdir(live) if f.startswith(".backup-")], [])

    def test_kometa_backup_is_encrypted_manifested_and_limited_to_config(self):
        original_encrypt = cli.B._encrypt_archive
        bundled = []

        def inspect_then_encrypt(source, destination):
            with tarfile.open(source, "r:gz") as archive:
                bundled.extend(archive.getnames())
            original_encrypt(source, destination)

        with mock.patch.object(
            cli.B, "_encrypt_archive", side_effect=inspect_then_encrypt
        ):
            self.assertEqual(self.main("backup"), 0)

        self.assertEqual(
            set(bundled),
            {
                "kometa/config.yml",
                "kometa/collections",
                "kometa/collections/fixture/collection.yml",
            },
        )
        backup_dir = os.path.join(self.root, "bk")
        archive_name = next(
            name for name in os.listdir(backup_dir) if name.endswith(".tar.gz.gpg")
        )
        artifact = os.path.join(backup_dir, archive_name)
        with open(artifact, "rb") as stream:
            encrypted_content = stream.read()
        self.assertEqual(encrypted_content, b"FAKE-OPENPGP-CIPHERTEXT\n")
        self.assertNotIn(b"FIXTURE_NOT_A_REAL_SECRET", encrypted_content)
        manifest_path = artifact + ".manifest.json"
        with open(manifest_path, encoding="utf-8") as stream:
            manifest = json.load(stream)
        self.assertTrue(manifest["encrypted"])
        self.assertEqual(manifest["recovery_group"], "kometa")
        self.assertEqual(manifest["archive_class"], "local")
        self.assertEqual(manifest["archive"], archive_name)
        self.assertIn(os.path.join(self.kometa_dir, "logs"), manifest["excluded_paths"])
        self.assertIn(
            os.path.join(self.kometa_dir, "config.cache"), manifest["excluded_paths"]
        )
        self.assertIn("/opt/kometa/app", manifest["excluded_paths"])
        self.assertIn("/opt/kometa/venv", manifest["excluded_paths"])
        for path in (artifact, artifact + ".sha256", manifest_path):
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        with open(artifact + ".sha256", encoding="ascii") as stream:
            digest, filename = stream.read().split()
        self.assertEqual(filename, archive_name)
        self.assertEqual(cli.B._sha256(artifact), digest)
        with open(self.receipts, encoding="utf-8") as stream:
            receipts = [json.loads(line) for line in stream]
        kometa_receipt = next(
            receipt for receipt in receipts if receipt["recovery_group"] == "kometa"
        )
        self.assertTrue(kometa_receipt["encrypted"])
        self.assertEqual(kometa_receipt["result"], "ok")
        self.assertEqual(kometa_receipt["artifact_path"], artifact)

    def test_kometa_encryption_failure_leaves_no_plaintext_artifact(self):
        with (
            mock.patch.dict(os.environ, {"FAKE_GPG_FAIL": "1"}),
            self.assertRaisesRegex(RuntimeError, "encryption failed"),
        ):
            self.main("backup")

        backup_dir = os.path.join(self.root, "bk")
        self.assertFalse(
            any(name.startswith("kometa-") for name in os.listdir(backup_dir))
        )
        with open(self.receipts, encoding="utf-8") as stream:
            receipts = [json.loads(line) for line in stream]
        failed = next(
            receipt for receipt in receipts if receipt["recovery_group"] == "kometa"
        )
        self.assertEqual(failed["result"], "failed")
        self.assertTrue(failed["encrypted"])

    def test_kometa_backup_fails_closed_without_recipient_key(self):
        os.remove(self.recipient_key)

        with self.assertRaisesRegex(RuntimeError, "encryption failed"):
            self.main("backup")

        backup_dir = os.path.join(self.root, "bk")
        self.assertFalse(
            any(name.startswith("kometa-") for name in os.listdir(backup_dir))
        )
        with open(self.receipts, encoding="utf-8") as stream:
            receipts = [json.loads(line) for line in stream]
        failed = next(
            receipt for receipt in receipts if receipt["recovery_group"] == "kometa"
        )
        self.assertEqual(failed["result"], "failed")

    def test_kometa_backup_retains_thirteen_complete_artifacts(self):
        backup_dir = os.path.join(self.root, "kometa-retention")
        os.mkdir(backup_dir)
        for day in range(1, 15):
            name = f"kometa-202601{day:02d}-000000.tar.gz.gpg"
            for suffix in ("", ".sha256", ".manifest.json"):
                with open(os.path.join(backup_dir, name + suffix), "w") as stream:
                    stream.write("fixture\n")

        cli.B._rotate_kometa(backup_dir)

        self.assertFalse(
            os.path.exists(
                os.path.join(backup_dir, "kometa-20260101-000000.tar.gz.gpg")
            )
        )
        remaining = [
            name for name in os.listdir(backup_dir) if name.endswith(".tar.gz.gpg")
        ]
        self.assertEqual(len(remaining), 13)

    def test_backup_without_plex_dated_database_records_nonfatal_warning(self):
        os.remove(
            os.path.join(
                self.appdata,
                "Plug-in Support",
                "Databases",
                "com.plexapp.plugins.library.db-2026-10-28",
            )
        )

        self.assertEqual(self.main("backup"), 0)

        with open(self.receipts, encoding="utf-8") as stream:
            receipts = [json.loads(line) for line in stream]
        receipt = next(row for row in receipts if row["recovery_group"] == "plex")
        self.assertEqual(receipt["result"], "ok")
        self.assertIn(
            "No Plex-generated dated library database backup", receipt["warning"]
        )

    def test_backup_failure_writes_failed_receipt(self):
        os.remove(os.path.join(self.appdata, "Preferences.xml"))

        with self.assertRaises(RuntimeError):
            self.main("backup")

        with open(self.receipts, encoding="utf-8") as stream:
            [receipt] = [json.loads(line) for line in stream]
        self.assertEqual(receipt["result"], "failed")

    def test_backup_succeeds_when_python_receipt_writer_is_unavailable(self):
        error = io.StringIO()
        with (
            mock.patch.object(cli.B.shutil, "which", return_value=None),
            contextlib.redirect_stderr(error),
        ):
            result = self.main("backup")

        self.assertEqual(result, 0)
        self.assertIn("backup:", self.out)
        self.assertIn("python3 is unavailable", error.getvalue())
        self.assertFalse(os.path.exists(self.receipts))

    def test_backup_copy_rejects_a_non_smb_destination(self):
        result = subprocess.CompletedProcess(
            ["findmnt"], 0, stdout="/dev/root ext4\n", stderr=""
        )
        with mock.patch.object(cli.B.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "not a mounted SMB share"):
                cli.B._require_nas_mount(os.path.join(self.root, "bk"))

    def test_backup_does_not_create_local_mountpoint_when_share_is_unavailable(self):
        destination = os.path.join(self.root, "missing-share", "plex")
        with mock.patch.object(
            cli.B,
            "_require_nas_mount",
            side_effect=RuntimeError("destination is not mounted"),
        ):
            with self.assertRaisesRegex(RuntimeError, "not mounted"):
                cli.B._prepare_nas_backup_dir(destination)

        self.assertFalse(os.path.exists(destination))


class RadarrPathChecks(CliBase):
    def add_moved_movie(self, path, title="Fixture", tmdb="348", radarr_id=42):
        path = self.mkfile(path, b"fixture movie")
        now = int(time.time()) - 60
        movie_id = identity.create_movie(
            self.conn, title, 2000, {"tmdb": str(tmdb)}, now
        )
        self.conn.execute(
            "UPDATE movie SET radarr_id=? WHERE id=?", (radarr_id, movie_id)
        )
        sync.upsert_file(
            self.conn,
            config.load(self.toml),
            movie_id,
            path,
            os.stat(path),
            f"fixture-{tmdb}",
            now,
        )
        db.add_event(self.conn, movie_id, now, "moved", value=path)
        self.conn.commit()
        return path

    def test_radarr_check_accepts_matching_moved_movie_path(self):
        path = self.add_moved_movie("Curated/Watched/Fixture/movie.mkv")
        radarr = FakeRadarr([{"id": 42, "tmdbId": 348, "path": os.path.dirname(path)}])

        self.assertEqual(self.main("radarr-check", radarr=radarr), 0)
        self.assertIn("1 moved movie(s) checked, 0 drift(s)", self.out)
        self.assertEqual(radarr.calls, [])

    def test_radarr_check_reports_drift_without_mutating_radarr(self):
        self.add_moved_movie("Curated/Watched/Fixture/movie.mkv")
        radarr = FakeRadarr([{"id": 42, "tmdbId": 348, "path": "/old/Fixture"}])

        self.assertEqual(self.main("radarr-check", radarr=radarr), 2)
        self.assertIn("ALERT: Radarr path drift", self.out)
        self.assertEqual(radarr.calls, [])
        self.assertEqual(radarr.movie_list[0]["path"], "/old/Fixture")

    def test_radarr_check_repairs_with_mapped_radarr_path_in_organize_mode(self):
        self.write_cfg(
            "organize",
            extra=f'[radarr.path_map]\n"/remote" = "{self.root}/Curated"\n',
        )
        self.add_moved_movie("Curated/Watched/Fixture/movie.mkv")
        radarr = FakeRadarr([{"id": 42, "tmdbId": 348, "path": "/remote/old"}])

        self.assertEqual(self.main("radarr-check", "--fix", radarr=radarr), 0)
        expected = "/remote/Watched/Fixture"
        self.assertEqual(radarr.calls, [("track_at", 42, expected)])
        self.assertEqual(radarr.movie_list[0]["path"], expected)
        self.assertIn("1 repaired", self.out)

    def test_radarr_check_rejects_repair_in_observe_mode(self):
        self.add_moved_movie("Curated/Watched/Fixture/movie.mkv")
        radarr = FakeRadarr([{"id": 42, "tmdbId": 348, "path": "/old/Fixture"}])

        self.assertEqual(self.main("radarr-check", "--fix", radarr=radarr), 1)
        self.assertIn("requires organize or reclaim mode", self.out)
        self.assertEqual(radarr.calls, [])
        self.assertEqual(radarr.movie_list[0]["path"], "/old/Fixture")

    def test_radarr_check_surfaces_radarr_unreachable(self):
        self.add_moved_movie("Curated/Watched/Fixture/movie.mkv")

        self.assertEqual(self.main("radarr-check", radarr=FakeRadarr(fail=True)), 2)
        self.assertIn("Radarr path check failed: radarr down", self.out)

    def test_radarr_check_reports_repair_failure(self):
        self.write_cfg("organize")
        self.add_moved_movie("Curated/Watched/Fixture/movie.mkv")
        radarr = FakeRadarr(
            [{"id": 42, "tmdbId": 348, "path": "/old/Fixture"}],
            track_error=OSError("write denied"),
        )

        self.assertEqual(self.main("radarr-check", "--fix", radarr=radarr), 2)
        self.assertIn("repair failed: write denied", self.out)
        self.assertEqual(len(radarr.calls), 1)

    def test_nightly_run_checks_old_radarr_drift_after_organize(self):
        self.write_cfg("organize")
        filename = "Fixture (2000) {tmdb-348} [1080hd 5ch]"
        path = self.add_moved_movie(
            f"Curated/Watched/1080hd/5ch/0/{filename}/{filename}.mkv"
        )
        plex = FakePlex([plex_item(1, "Fixture", path, tmdb=348, year=2000)])
        radarr = FakeRadarr([{"id": 42, "tmdbId": 348, "path": "/old/Fixture"}])

        self.assertEqual(self.main("run", plex=plex, radarr=radarr), 2)
        self.assertEqual(radarr.calls, [("track_at", 42, os.path.dirname(path))])
        self.assertIn("Radarr path check:", self.out)
        self.assertIn("ALERT: Radarr path drift", self.out)
        with open(os.path.join(self.root, "ALERT"), encoding="utf-8") as stream:
            self.assertIn("Radarr path drift", stream.read())

    def test_nightly_dry_run_reports_drift_without_repairing(self):
        self.write_cfg("organize")
        filename = "Fixture (2000) {tmdb-348} [1080hd 5ch]"
        path = self.add_moved_movie(
            f"Curated/Watched/1080hd/5ch/0/{filename}/{filename}.mkv"
        )
        plex = FakePlex([plex_item(1, "Fixture", path, tmdb=348, year=2000)])
        radarr = FakeRadarr([{"id": 42, "tmdbId": 348, "path": "/old/Fixture"}])

        self.assertEqual(self.main("--dry-run", "run", plex=plex, radarr=radarr), 2)
        self.assertEqual(radarr.calls, [])
        self.assertEqual(radarr.movie_list[0]["path"], "/old/Fixture")
        self.assertIn("ALERT: Radarr path drift", self.out)
