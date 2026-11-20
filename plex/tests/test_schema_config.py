import os
import sqlite3

from plexcurator import classes, collect, config, db, validate

from .helpers import NOW, Base, FakePlex, FakeRadarr, fake_probe


class Locs(FakePlex):
    def __init__(self, paths):
        super().__init__()
        self.paths = paths

    def sections(self):
        return [
            {
                "key": "1",
                "title": "M",
                "type": "movie",
                "Location": [{"path": p} for p in self.paths],
            }
        ]


class SchemaTests(Base):
    def new_movie(self):
        return self.conn.execute(
            "INSERT INTO movie(title,first_seen_at,updated_at) VALUES ('X',?,?)",
            (NOW, NOW),
        ).lastrowid

    def test_born_and_retired_are_unique_per_life(self):
        m = self.new_movie()
        db.add_event(self.conn, m, NOW, "born")
        with self.assertRaises(sqlite3.IntegrityError):
            db.add_event(self.conn, m, NOW + 1, "born")
        db.add_event(self.conn, m, NOW + 2, "retired")
        with self.assertRaises(sqlite3.IntegrityError):
            db.add_event(self.conn, m, NOW + 3, "retired")
        db.add_event(self.conn, m, NOW + 4, "reborn", life=1)
        db.add_event(
            self.conn, m, NOW + 5, "retired", life=1
        )  # second life may retire once
        db.add_event(self.conn, m, NOW + 6, "watched", 60)
        db.add_event(
            self.conn, m, NOW + 7, "watched", 100
        )  # watched/rated/watchlisted are repeatable

    def test_event_kinds_are_restricted(self):
        m = self.new_movie()
        with self.assertRaises(sqlite3.IntegrityError):
            db.add_event(self.conn, m, NOW, "removed")

    def test_external_id_is_unique_per_provider(self):
        a, b = self.new_movie(), self.new_movie()
        self.conn.execute("INSERT INTO external_id VALUES (?,?,?)", (a, "tmdb", "1"))
        with self.assertRaises(sqlite3.IntegrityError):
            self.conn.execute(
                "INSERT INTO external_id VALUES (?,?,?)", (b, "tmdb", "1")
            )

    def test_stars_round_down(self):
        self.assertEqual(
            [db.stars(x) for x in (None, 0, 1, 2, 3, 4, 5, 9, 10)],
            [0, 0, 0, 1, 1, 2, 2, 4, 5],
        )

    def test_store_probe_fills_normalized_tables_and_replaces(self):
        m = self.new_movie()
        fid = self.conn.execute(
            "INSERT INTO file(movie_id,path,size,mtime,fingerprint,first_seen_at,last_seen_at) "
            "VALUES (?,?,?,?,?,?,?)",
            (m, "/x.mkv", 1, 0, "fp", NOW, NOW),
        ).lastrowid
        pj, _ = fake_probe(3840, 1600, 8, "smpte2084")("/x.mkv")
        collect.store_probe(self.conn, self.cfg, m, fid, pj, {"media": {}}, NOW)
        f = self.conn.execute("SELECT * FROM file").fetchone()
        self.assertEqual(
            (f["video_class"], f["audio_class"], f["hdr"], f["channels"]),
            ("4khd", "7ch", "hdr10", 8),
        )
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM audio_stream").fetchone()[0], 1
        )
        self.assertEqual(
            self.conn.execute("SELECT language FROM subtitle_stream").fetchone()[0],
            "eng",
        )
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM source_record").fetchone()[0], 2
        )
        pj2, _ = fake_probe(1920, 800, 2)(
            "/x.mkv"
        )  # re-collect: still one record per source
        collect.store_probe(self.conn, self.cfg, m, fid, pj2, None, NOW + 5)
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM video_stream").fetchone()[0], 1
        )
        self.assertEqual(
            self.conn.execute(
                "SELECT COUNT(*) FROM source_record WHERE source='ffprobe'"
            ).fetchone()[0],
            1,
        )
        self.assertEqual(
            self.conn.execute("SELECT video_class FROM v_movie").fetchone()[0], "1080hd"
        )
        r = self.conn.execute(
            "SELECT codec_name, SUM(channels) c FROM v_audio GROUP BY 1"
        ).fetchone()
        self.assertEqual(tuple(r), ("ac3", 2))


class ClassTests(Base):
    def test_default_classes_use_width_so_scope_films_classify_right(self):
        c = self.cfg
        cases = [
            ((3840, 2160), "4khd"),
            ((3840, 1600), "4khd"),
            ((1920, 1080), "1080hd"),
            ((1920, 800), "1080hd"),
            ((1280, 720), "720hd"),
            ((1280, 536), "720hd"),
            ((720, 480), "sd"),
        ]
        for (w, h), want in cases:
            self.assertEqual(classes.classify_video(w, h, c), want, (w, h))
        self.assertEqual(
            [classes.classify_audio(n, c) for n in (1, 2, 6, 7, 8)],
            ["2ch", "2ch", "5ch", "7ch", "7ch"],
        )
        self.assertIsNone(classes.classify_video(None, None, c))

    def test_adding_8k_is_config_plus_reclassify_without_reprobe(self):
        m = self.conn.execute(
            "INSERT INTO movie(title,first_seen_at,updated_at) VALUES ('X',?,?)",
            (NOW, NOW),
        ).lastrowid
        fid = self.conn.execute(
            "INSERT INTO file(movie_id,path,size,mtime,fingerprint,first_seen_at,last_seen_at) "
            "VALUES (?,?,?,?,?,?,?)",
            (m, "/x.mkv", 1, 0, "fp", NOW, NOW),
        ).lastrowid
        collect.store_probe(
            self.conn, self.cfg, m, fid, fake_probe(7680, 4320, 6)("/")[0], None, NOW
        )
        self.assertEqual(
            self.conn.execute("SELECT video_class FROM file").fetchone()[0], "4khd"
        )
        cfg = config.load(
            overrides={
                "video": {
                    "8k": {"min_width": 6000},
                    "4khd": {"min_width": 3000},
                    "1080hd": {"min_width": 1700},
                    "720hd": {"min_width": 1200},
                    "sd": {"min_width": 0},
                }
            }
        )
        self.assertEqual(collect.reclassify(self.conn, cfg), 1)
        self.assertEqual(
            self.conn.execute("SELECT video_class FROM file").fetchone()[0], "8k"
        )
        self.assertEqual(collect.reclassify(self.conn, cfg), 0)

    def test_min_height_is_optional_extra_condition(self):
        cfg = config.load(
            overrides={
                "video": {
                    "big": {"min_width": 1000, "min_height": 900},
                    "sd": {"min_width": 0},
                }
            }
        )
        self.assertEqual(classes.classify_video(1920, 800, cfg), "sd")
        self.assertEqual(classes.classify_video(1920, 1080, cfg), "big")


class ConfigAndValidate(Base):
    def good(self):
        cfg = config.load(
            overrides={
                "plex": {"token": "t"},
                "radarr": {"url": "http://r", "api_key": "k"},
            }
        )
        cfg["folders"], cfg["storage"] = self.cfg["folders"], self.cfg["storage"]
        cfg["advanced"] = self.cfg["advanced"]
        return cfg

    def v(self, cfg, **kw):
        kw.setdefault("tools", False)
        return validate.validate(cfg, **kw)

    def test_defaults_match_decisions(self):
        c = config.load()
        self.assertEqual((c["mode"], c["watched_pct"]), ("observe", 50))
        self.assertEqual(c["plex"]["libraries"], "configured")
        self.assertEqual(
            (c["storage"]["min_free_pct"], c["storage"]["reclaim_to_pct"]), (35, 40)
        )
        self.assertEqual(
            (c["lifecycle"]["stale_days"], c["lifecycle"]["rules"]),
            (365, ["one_star", "two_star", "stale_watchlist", "stale_unmanaged"]),
        )
        self.assertEqual(c["lifecycle"]["age_only"], [])
        self.assertEqual(c["advanced"]["max_deletions_per_run"], 10)
        self.assertEqual(c["alert_unidentified"], "warn")

    def test_example_file_parses_and_only_lacks_secrets(self):
        path = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), "config.example.toml"
        )
        cfg = config.load(path)
        errs, _ = validate.validate(cfg, online=False, tools=False)
        joined = "\n".join(errs)
        for need in ("[plex] token", "[radarr] api_key", "backup_dir"):
            self.assertIn(need, joined)
        self.assertEqual(cfg["mode"], "observe")
        self.assertEqual(list(cfg["video"]), ["4khd", "1080hd", "720hd", "sd"])

    def test_good_offline(self):
        self.assertEqual(self.v(self.good(), online=False)[0], [])

    def test_legacy_stale_months_is_loaded_and_warned(self):
        path = os.path.join(self.root, "legacy.toml")
        with open(path, "w") as fh:
            fh.write("[lifecycle]\nstale_months = 6\n")
        legacy = config.load(path)
        self.assertNotIn("stale_days", legacy["lifecycle"])
        self.assertEqual(legacy["lifecycle"]["stale_months"], 6)

        cfg = self.good()
        cfg["lifecycle"] = legacy["lifecycle"]
        errors, warnings = self.v(cfg, online=False)
        self.assertEqual(errors, [])
        self.assertTrue(
            any("stale_months is deprecated" in warning for warning in warnings)
        )

    def test_both_stale_age_keys_are_rejected_by_name(self):
        cfg = self.good()
        cfg["lifecycle"]["stale_months"] = 12
        errors, _ = self.v(cfg, online=False)
        self.assertTrue(
            any(
                "stale_days and stale_months cannot both be set" in error
                for error in errors
            )
        )

    def test_stale_day_values_and_folder_lifecycle_are_validated(self):
        for value in (0, 1.5, "61", True):
            cfg = self.good()
            cfg["lifecycle"]["stale_days"] = value
            errors, _ = self.v(cfg, online=False)
            self.assertTrue(
                any(
                    "[lifecycle] stale_days must be an integer" in error
                    for error in errors
                ),
                value,
            )

        cfg = self.good()
        cfg["lifecycle"]["watchlist_stale_days"] = 0
        cfg["lifecycle"]["age_only"] = ["stale_unmanaged"]
        cfg["folders"]["unmanaged"][0]["stale_days"] = 61
        cfg["folders"]["unmanaged"][0]["lifecycle"] = False
        cfg["folders"]["unmanaged"][0]["age_only"] = True
        errors, _ = self.v(cfg, online=False)
        self.assertTrue(
            any("watchlist_stale_days must be an integer" in error for error in errors)
        )
        self.assertTrue(
            any("stale_days requires lifecycle = true" in error for error in errors)
        )
        self.assertTrue(
            any("age_only requires lifecycle = true" in error for error in errors)
        )

    def test_config_preserves_per_folder_stale_days(self):
        folder = {
            **self.cfg["folders"]["unmanaged"][0],
            "stale_days": 61,
        }
        cfg = config.load(
            overrides={
                "folders": {
                    "managed": self.cfg["folders"]["managed"],
                    "unmanaged": [folder],
                }
            }
        )
        self.assertEqual(cfg["folders"]["unmanaged"][0]["stale_days"], 61)

    def test_age_only_configuration_is_validated_and_normalized(self):
        cfg = self.good()
        cfg["lifecycle"]["age_only"] = ["stale_unmanaged", "stale_watchlist"]
        cfg["folders"]["unmanaged"][0]["age_only"] = False
        normalized = config.normalize(cfg)
        self.assertFalse(normalized["folders"]["unmanaged"][0]["age_only"])
        self.assertEqual(self.v(normalized, online=False)[0], [])

        normalized["lifecycle"]["age_only"] = ["one_star"]
        normalized["folders"]["unmanaged"][0]["age_only"] = "yes"
        joined = "\n".join(self.v(normalized, online=False)[0])
        self.assertIn("is not age-based", joined)
        self.assertIn("age_only must be true or false", joined)

    def test_bad_values(self):
        c = self.good()
        c["mode"] = "yolo"
        c["alert_unidentified"] = "ignore"
        c["plex"]["libraries"] = ["Movies", ""]
        c["storage"]["reclaim_to_pct"] = 30
        c["lifecycle"]["rules"] = ["one_star", "nonsense"]
        c["video"] = {"4khd": {"min_width": 3000}}
        c["audio"] = {"bad name": {"min_channels": 0}}
        joined = "\n".join(self.v(c, online=False)[0])
        for need in (
            "mode must",
            "alert_unidentified must",
            "reclaim_to_pct",
            "unknown rule",
            "lowest class",
            "folder name",
            "libraries list",
        ):
            self.assertIn(need, joined)

    def test_unmanaged_must_exist_and_not_overlap_managed(self):
        c = self.good()
        c["folders"]["unmanaged"].append(
            {"path": os.path.join(self.root, "Curated", "sub"), "lifecycle": False}
        )
        c["folders"]["unmanaged"].append(
            {"path": os.path.join(self.root, "missing"), "lifecycle": False}
        )
        joined = "\n".join(self.v(c, online=False)[0])
        self.assertIn("overlaps the managed", joined)
        self.assertIn("does not exist", joined)

    def test_plex_library_folder_warnings_and_radarr_down(self):
        c = self.good()
        errs, warns = self.v(
            c, plex=Locs([os.path.join(self.root, "Movies")]), radarr=FakeRadarr()
        )
        self.assertEqual(errs, [])
        self.assertTrue(any("Curated" in w for w in warns))
        self.assertTrue(any("Other" in w for w in warns))
        self.assertFalse(any("Movies" in w and "Other" not in w for w in warns))
        errs, _ = self.v(c, plex=Locs([]), radarr=FakeRadarr(fail=True))
        self.assertTrue(any("Radarr unreachable" in e for e in errs))
