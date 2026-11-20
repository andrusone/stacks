import json
import os
from unittest import mock

from plexcurator import collect, config, db, discover, hdr, naming, probe, validate

from .helpers import NOW, Base, fake_probe
from .test_layout import LayoutBase


def dovi(profile, compat):
    return {
        "side_data_type": "DOVI configuration record",
        "dv_version_major": 1,
        "dv_version_minor": 0,
        "dv_profile": profile,
        "dv_level": 6,
        "rpu_present_flag": 1,
        "el_present_flag": int(profile == 7),
        "bl_present_flag": 1,
        "dv_bl_signal_compatibility_id": compat,
    }


HDR10PLUS = {"side_data_type": "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)"}
MASTERING = {"side_data_type": "Mastering display metadata"}
PQ, HLG = "smpte2084", "arib-std-b67"


def stream(transfer=None, primaries=None, side=()):
    s = {
        "index": 0,
        "codec_type": "video",
        "codec_name": "hevc",
        "width": 3840,
        "height": 2160,
        "pix_fmt": "yuv420p10le",
        "avg_frame_rate": "24000/1001",
    }
    if transfer:
        s.update(
            color_transfer=transfer,
            color_primaries=primaries or "bt2020",
            color_space="bt2020nc",
        )
    if side:
        s["side_data_list"] = list(side)
    return s


def mi(**video):
    return {"media": {"track": [{"@type": "General"}, {"@type": "Video", **video}]}}


# (name, ffprobe stream, mediainfo, canonical, (dv, hdr10plus, hdr10, hlg), dv_profile, dv_fallback)
CASES = [
    ("sdr", stream("bt709", "bt709"), None, "sdr", (0, 0, 0, 0), None, None),
    ("sdr, no colour info", stream(), None, "sdr", (0, 0, 0, 0), None, None),
    ("hdr10", stream(PQ, side=[MASTERING]), None, "hdr10", (0, 0, 1, 0), None, None),
    (
        "hdr10+ from ffprobe side data",
        stream(PQ, side=[MASTERING, HDR10PLUS]),
        None,
        "hdr10plus",
        (0, 1, 1, 0),
        None,
        None,
    ),
    (
        "hdr10+ from mediainfo",
        stream(PQ),
        mi(
            HDR_Format="SMPTE ST 2086 / SMPTE ST 2094 App 4",
            HDR_Format_Compatibility="HDR10 / HDR10+ Profile B",
        ),
        "hdr10plus",
        (0, 1, 1, 0),
        None,
        None,
    ),
    (
        "hdr10 from mediainfo agrees",
        stream(PQ),
        mi(HDR_Format="SMPTE ST 2086", HDR_Format_Compatibility="HDR10"),
        "hdr10",
        (0, 0, 1, 0),
        None,
        None,
    ),
    ("hlg", stream(HLG), None, "hlg", (0, 0, 0, 1), None, None),
    (
        "dolby vision 8.1 with hdr10 fallback",
        stream(PQ, side=[dovi(8, 1)]),
        None,
        "dv",
        (1, 0, 1, 0),
        8,
        "hdr10",
    ),
    (
        "dolby vision 7 (dual layer, hdr10 base)",
        stream(PQ, side=[dovi(7, 6)]),
        None,
        "dv",
        (1, 0, 1, 0),
        7,
        "hdr10",
    ),
    (
        "dolby vision 5, no fallback",
        stream(PQ, side=[dovi(5, 0)]),
        None,
        "dv",
        (1, 0, 0, 0),
        5,
        None,
    ),
    (
        "dolby vision 8.2 sdr base",
        stream("bt709", "bt709", [dovi(8, 2)]),
        None,
        "dv",
        (1, 0, 0, 0),
        8,
        "sdr",
    ),
    (
        "dolby vision 8.4 hlg base",
        stream(HLG, side=[dovi(8, 4)]),
        None,
        "dv",
        (1, 0, 0, 1),
        8,
        "hlg",
    ),
    (
        "dolby vision + hdr10+ is still dv",
        stream(PQ, side=[dovi(8, 1), HDR10PLUS]),
        None,
        "dv",
        (1, 1, 1, 0),
        8,
        "hdr10",
    ),
    (
        "dolby vision from mediainfo only",
        stream(),
        mi(
            HDR_Format="Dolby Vision",
            HDR_Format_Profile="dvhe.08",
            HDR_Format_Level="06",
            HDR_Format_Compatibility="HDR10",
        ),
        "dv",
        (1, 0, 1, 0),
        8,
        "hdr10",
    ),
    (
        "dolby vision 5 from mediainfo",
        stream(),
        mi(HDR_Format="Dolby Vision", HDR_Format_Profile="dvhe.05"),
        "dv",
        (1, 0, 0, 0),
        5,
        None,
    ),
]


class Detect(Base):
    def test_every_type_from_ffprobe_and_mediainfo_samples(self):
        for name, s, m, want, flags, prof, fb in CASES:
            with self.subTest(name):
                f = hdr.detect(s, m)
                self.assertEqual(hdr.canonical(f), want)
                self.assertEqual((f["dv"], f["hdr10plus"], f["hdr10"], f["hlg"]), flags)
                self.assertEqual((f["dv_profile"], f["dv_fallback"]), (prof, fb))

    def test_priority_is_dv_then_hdr10plus_then_hdr10_then_hlg(self):
        self.assertEqual(hdr.PRIORITY, ("dv", "hdr10plus", "hdr10", "hlg"))
        every = dict(dv=1, hdr10plus=1, hdr10=1, hlg=1)
        self.assertEqual(hdr.canonical(every), "dv")
        self.assertEqual(hdr.canonical({**every, "dv": 0}), "hdr10plus")
        self.assertEqual(hdr.canonical({**every, "dv": 0, "hdr10plus": 0}), "hdr10")
        self.assertEqual(hdr.canonical({"hlg": 1}), "hlg")
        self.assertEqual(hdr.canonical({}), "sdr")

    def test_normalize_puts_flags_on_stream_rows_and_best_stream_on_the_summary(self):
        n = probe.normalize({"streams": [stream(PQ, side=[dovi(8, 1)])], "format": {}})
        v = n["video"][0]
        self.assertEqual(
            (
                v["hdr"],
                v["dolby_vision"],
                v["hdr10"],
                v["hdr10plus"],
                v["hlg"],
                v["dv_profile"],
                v["dv_fallback"],
            ),
            ("dv", 1, 1, 0, 0, 8, "hdr10"),
        )
        self.assertEqual(
            {k: n["summary"][k] for k in probe.HDR_FIELDS},
            {k: v[k] for k in probe.HDR_FIELDS},
        )
        self.assertIsNone(
            probe.normalize({"streams": [], "format": {}})["summary"]["hdr"]
        )  # no video: unknown, not sdr

    def test_store_probe_writes_queryable_columns_and_uses_mediainfo(self):
        m = self.conn.execute(
            "INSERT INTO movie(title,first_seen_at,updated_at) VALUES ('X',?,?)",
            (NOW, NOW),
        ).lastrowid
        fid = self.conn.execute(
            "INSERT INTO file(movie_id,path,size,mtime,fingerprint,first_seen_at,last_seen_at) "
            "VALUES (?,?,?,?,?,?,?)",
            (m, "/x.mkv", 1, 0, "fp", NOW, NOW),
        ).lastrowid
        pj, mj = fake_probe(
            3840,
            2160,
            6,
            PQ,
            side_data=[MASTERING],
            mediainfo=mi(
                HDR_Format="SMPTE ST 2094 App 4",
                HDR_Format_Compatibility="HDR10+ Profile B",
            ),
        )("/x")
        collect.store_probe(self.conn, self.cfg, m, fid, pj, mj, NOW)
        r = self.conn.execute(
            "SELECT hdr, dolby_vision, hdr10plus, hdr10, hlg FROM v_movie"
        ).fetchone()
        self.assertEqual(tuple(r), ("hdr10plus", 0, 1, 1, 0))
        self.assertEqual(
            self.conn.execute("SELECT hdr FROM v_video").fetchone()[0], "hdr10plus"
        )
        collect.store_probe(
            self.conn, self.cfg, m, fid, pj, None, NOW + 1
        )  # without mediainfo: plain HDR10
        self.assertEqual(
            self.conn.execute("SELECT hdr FROM v_movie").fetchone()[0], "hdr10"
        )


class Tags(Base):
    TAGS = {
        "dv": "DV",
        "hdr10plus": "HDR10+",
        "hdr10": "HDR10",
        "hlg": "HLG",
        "sdr": "",
        None: "",
    }

    def row(self, key):
        return {
            "tmdb": "1",
            "imdb": None,
            "title": "Heat",
            "year": 1995,
            "video_class": "4khd",
            "audio_class": "7ch",
            "hdr": key,
            "path": "/x/h.mkv",
        }

    def test_default_tags_in_filenames(self):
        for key, tag in self.TAGS.items():
            want = "Heat (1995) {tmdb-1} [4khd 7ch" + (" " + tag if tag else "") + "]"
            self.assertEqual(naming.curated_stem(self.row(key), self.cfg), want)
        r = dict(self.row("dv"), video_class="1080hd", audio_class="5ch")
        self.assertEqual(
            naming.curated_stem(r, self.cfg), "Heat (1995) {tmdb-1} [1080hd 5ch DV]"
        )

    def test_tag_round_trips_through_parse_for_every_type(self):
        for key in self.cfg["hdr"]:
            stem = naming.curated_stem(self.row(key), self.cfg)
            self.assertEqual(
                naming.parse_tech(stem, self.cfg), ("4khd", "7ch", key), stem
            )
        self.assertIsNone(naming.parse_tech("Heat (1995) {tmdb-1}", self.cfg))
        self.assertEqual(
            naming.parse_tech("Heat [4khd 7ch NOPE]", self.cfg), ("4khd", "7ch", None)
        )

    def test_tags_and_labels_are_config_data(self):
        cfg = config.load(overrides={"hdr": {"dv": {"tag": "DoVi"}}})
        self.assertEqual(
            naming.curated_stem(self.row("dv"), cfg),
            "Heat (1995) {tmdb-1} [4khd 7ch DoVi]",
        )
        self.assertEqual(
            hdr.label("dv", cfg), "Dolby Vision"
        )  # untouched keys keep their defaults
        self.assertEqual(hdr.tag("hdr10", cfg), "HDR10")
        self.assertEqual(naming.parse_tech("Heat [4khd 7ch DoVi]", cfg)[2], "dv")

    def test_validate_rejects_unusable_or_duplicate_tags(self):
        cfg = config.load(
            overrides={
                "hdr": {
                    "dv": {"tag": "Dolby Vision"},
                    "hlg": {"tag": "HDR10"},
                    "wide": {"tag": "W"},
                }
            }
        )
        errs = []
        validate._check_hdr(cfg, errs)
        joined = "\n".join(errs)
        for need in ("hdr.dv", "already used", "unknown type 'wide'"):
            self.assertIn(need, joined)
        errs = []
        validate._check_hdr(config.load(), errs)
        self.assertEqual(errs, [])

    def test_title_parsing_ignores_the_tech_bracket(self):
        self.assertEqual(
            discover.title_year("/x/Heat (1995) {tmdb-1} [4khd 7ch HDR10+].mkv"),
            ("Heat", 1995),
        )


class Renames(LayoutBase):
    def test_new_file_gets_dv_tag_and_next_runs_change_nothing(self):
        self.add(
            "Movies/Heat (1995)/heat.mkv",
            title="Heat",
            tmdb=1,
            year=1995,
            views=1,
            probe=fake_probe(3840, 2160, 6, PQ, side_data=[dovi(8, 1)]),
        )
        self.go()
        self.assertTrue(
            os.path.basename(self.path()).startswith(
                "Heat (1995) {tmdb-1} [4khd 5ch DV]"
            )
        )
        self.assertEqual(self.plan(), [])  # no flip-flop
        self.resync(now=NOW + 99)
        self.assertEqual(self.plan(), [])

    def test_curated_file_whose_hdr_changes_is_renamed_in_place_on_next_run(self):
        self.add(
            "Movies/Heat (1995)/heat.mkv",
            title="Heat",
            tmdb=1,
            year=1995,
            views=1,
            extra=("heat.en.srt",),
            probe=fake_probe(3840, 2160, 6, PQ),
        )
        self.go()
        old = self.path()
        self.assertIn("[4khd 5ch HDR10]", old)
        self._probe = fake_probe(
            3840, 2160, 6, PQ, side_data=[HDR10PLUS]
        )  # the file is replaced by an HDR10+ release
        self.conn.execute(
            "UPDATE file SET hdr='hdr10plus'"
        )  # ... and re-probed (moves re-probe too)
        plan = self.plan()
        self.assertEqual(len(plan), 1)
        self.assertEqual(
            os.path.dirname(plan[0]["dst_folder"]),
            os.path.dirname(os.path.dirname(old)),
        )  # same star folder
        self.go()
        new = self.path()
        stem = "Heat (1995) {tmdb-1} [4khd 5ch HDR10+]"
        self.assertEqual(os.path.basename(new), stem + ".mkv")
        self.assertEqual(
            sorted(os.listdir(os.path.dirname(new))),
            sorted([stem + ".mkv", stem + ".en.srt"]),
        )
        self.assertFalse(os.path.exists(os.path.dirname(old)))
        self.assertEqual(self.plan(), [])
        self._probe = fake_probe(3840, 2160, 6)  # losing the tag works too
        self.conn.execute("UPDATE file SET hdr='sdr'")
        self.go()
        self.assertEqual(
            os.path.basename(self.path()), "Heat (1995) {tmdb-1} [4khd 5ch].mkv"
        )
        self.assertEqual(self.plan(), [])

    def test_changing_a_configured_tag_renames_curated_files(self):
        self.add(
            "Movies/Heat (1995)/heat.mkv",
            title="Heat",
            tmdb=1,
            year=1995,
            views=1,
            probe=fake_probe(3840, 2160, 6, PQ, side_data=[dovi(8, 1)]),
        )
        self.go()
        self.cfg["hdr"]["dv"]["tag"] = "DoVi"
        self.assertEqual(len(self.plan()), 1)
        self.go()
        self.assertIn("[4khd 5ch DoVi]", self.path())


class MigrationBackfill(Base):
    """A schema-1 database holding raw ffprobe/mediainfo JSON gets the HDR columns without any re-probe."""

    def test_backfill_from_raw_json(self):
        path = os.path.join(self.root, "v1.db")
        with mock.patch.multiple(db, MIGRATIONS={1: db.SCHEMA}, SCHEMA_VERSION=1):
            c = db.connect(path)
        samples = [
            ("Plain", stream("bt709", "bt709"), None),
            ("Ten", stream(PQ), None),
            ("Plus", stream(PQ), mi(HDR_Format_Compatibility="HDR10+ Profile B")),
            ("Vision", stream(PQ, side=[dovi(8, 1)]), None),
            ("Gone", None, None),
        ]
        for i, (title, s, m) in enumerate(samples, 1):
            c.execute(
                "INSERT INTO movie(id,title,first_seen_at,updated_at) VALUES (?,?,?,?)",
                (i, title, NOW, NOW),
            )
            c.execute(
                "INSERT INTO file(id,movie_id,path,size,mtime,fingerprint,first_seen_at,last_seen_at,hdr) "
                "VALUES (?,?,?,1,0,?,?,?,?)",
                (
                    i,
                    i,
                    f"/{title}.mkv",
                    f"fp{i}",
                    NOW,
                    NOW,
                    "HDR10" if title == "Gone" else None,
                ),
            )
            if s is None:
                continue
            c.execute(
                "INSERT INTO video_stream(file_id, idx, codec_name) VALUES (?,0,'hevc')",
                (i,),
            )
            c.execute(
                "INSERT INTO source_record VALUES (?,?,?,?)",
                (i, "ffprobe", NOW, json.dumps({"streams": [s], "format": {}})),
            )
            if m:
                c.execute(
                    "INSERT INTO source_record VALUES (?,?,?,?)",
                    (i, "mediainfo", NOW, json.dumps(m)),
                )
        c.commit()
        self.assertEqual(c.execute("PRAGMA user_version").fetchone()[0], 1)
        c.close()
        bk = os.path.join(self.root, "bk")
        c = db.connect(path, backup_dir=bk)
        self.assertEqual(
            c.execute("PRAGMA user_version").fetchone()[0], db.SCHEMA_VERSION
        )
        got = {
            r[0]: tuple(r[1:])
            for r in c.execute(
                "SELECT title, hdr, dolby_vision, hdr10plus, hdr10, dv_profile, dv_fallback FROM v_movie"
            )
        }
        self.assertEqual(
            got,
            {
                "Plain": ("sdr", 0, 0, 0, None, None),
                "Ten": ("hdr10", 0, 0, 1, None, None),
                "Plus": ("hdr10plus", 0, 1, 1, None, None),
                "Vision": ("dv", 1, 0, 1, 8, "hdr10"),
                "Gone": ("hdr10", None, None, None, None, None),
            },
        )  # no stored JSON: old value, mapped
        self.assertEqual(
            {
                r[0]: r[1]
                for r in c.execute(
                    "SELECT m.title, v.hdr FROM v_video v JOIN movie m ON m.id=v.movie_id"
                )
            },
            {"Plain": "sdr", "Ten": "hdr10", "Plus": "hdr10plus", "Vision": "dv"},
        )
        (b,) = os.listdir(bk)
        self.assertIn("-schema1.db", b)


class Queries(Base):
    def test_hdr_aggregate_queries_run(self):
        import contextlib
        import io
        from plexcurator import cli

        self.conn.execute(
            "INSERT INTO movie(title,first_seen_at,updated_at) VALUES ('X',?,?)",
            (NOW, NOW),
        )
        self.conn.execute(
            "INSERT INTO file(movie_id,path,size,mtime,fingerprint,first_seen_at,last_seen_at,"
            "video_class,hdr,dolby_vision,dv_profile,dv_fallback) VALUES (1,'/x',5000000000,0,'f',?,?,"
            "'4khd','dv',1,8,'hdr10')",
            (NOW, NOW),
        )
        for q, want in (
            ("by_hdr", "dv	1	5.0"),
            ("hdr_by_video_class", "4khd	dv	1"),
            ("dolby_vision_profiles", "8	hdr10	1"),
            ("hdr_stars", "0	dv	1"),
        ):
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                cli.run_query(self.conn, q)
            self.assertIn(want, out.getvalue(), q)
