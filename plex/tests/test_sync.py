import os

from plexcurator import sync

from .helpers import DAY, NOW, Base, FakePlex, FakeRadarr, fake_probe, plex_item


class SyncBase(Base):
    def put(self, rel, data=b"movie-bytes"):
        return self.mkfile(rel, data)

    def run_sync(self, plex, now=NOW, radarr=None, **kw):
        kw.setdefault("probe_fn", fake_probe())
        return sync.sync(self.conn, self.cfg, plex, radarr, now=now, **kw)

    def events(self, kind=None):
        q = (
            "SELECT kind, value, ts FROM event"
            + (" WHERE kind=?" if kind else "")
            + " ORDER BY id"
        )
        return [tuple(r) for r in self.conn.execute(q, (kind,) if kind else ())]

    def movie(self):
        return self.conn.execute("SELECT * FROM v_movie").fetchone()


class SectionPlex(FakePlex):
    def __init__(self, sections, items):
        super().__init__()
        self._sections, self._items = sections, items

    def sections(self):
        return self._sections

    def movie_sections(self, only=()):
        return [
            section
            for section in self.sections()
            if section["type"] == "movie"
            and (not only or section["title"] in only or section["key"] in only)
        ]

    def movies(self, key):
        self.calls.append(("movies", key))
        return self._items.get(key, [])


class LibraryScope(SyncBase):
    def sections(self):
        return [
            {
                "key": "1",
                "title": "Movies",
                "type": "movie",
                "Location": [{"path": "/remote/Movies"}],
            },
            {
                "key": "2",
                "title": "Curated",
                "type": "movie",
                "Location": [{"path": "/remote/Curated/Watched"}],
            },
            {
                "key": "3",
                "title": "Legacy",
                "type": "movie",
                "Location": [{"path": "/remote/Legacy"}],
            },
            {
                "key": "4",
                "title": "Shows",
                "type": "show",
                "Location": [{"path": "/remote/Movies"}],
            },
        ]

    def test_default_probes_only_libraries_overlapping_configured_folders(self):
        self.cfg["plex"]["libraries"] = "configured"
        self.cfg["plex"]["path_map"] = {"/remote": self.root}
        movies_path = self.put("Movies/A/a.mkv", b"a")
        curated_path = self.put("Curated/Watched/B/b.mkv", b"b")
        legacy_path = self.put("Legacy/C/c.mkv", b"c")
        sections = self.sections()
        plex = SectionPlex(
            sections,
            {
                "1": [plex_item(1, "A", movies_path, tmdb=1)],
                "2": [plex_item(2, "B", curated_path, tmdb=2)],
                "3": [plex_item(3, "C", legacy_path, tmdb=3)],
            },
        )
        probed = []
        probe = fake_probe()

        def record_probe(path):
            probed.append(path)
            return probe(path)

        stats = self.run_sync(plex, probe_fn=record_probe)
        self.assertEqual(
            [key for name, key in plex.calls if name == "movies"], ["1", "2"]
        )
        self.assertEqual(set(probed), {movies_path, curated_path})
        self.assertEqual(stats["new"], 2)
        self.assertEqual(
            {row[0] for row in self.conn.execute("SELECT title FROM movie")},
            {"A", "B"},
        )

    def test_explicit_library_title_list_selects_only_those_libraries(self):
        self.cfg["plex"]["libraries"] = ["Legacy"]
        path = self.put("Legacy/C/c.mkv")
        plex = SectionPlex(self.sections(), {"3": [plex_item(3, "C", path, tmdb=3)]})
        probed = []
        probe = fake_probe()

        def record_probe(file_path):
            probed.append(file_path)
            return probe(file_path)

        self.run_sync(plex, probe_fn=record_probe)
        self.assertEqual([key for name, key in plex.calls if name == "movies"], ["3"])
        self.assertEqual(probed, [path])

    def test_unknown_explicit_library_title_is_an_error(self):
        self.cfg["plex"]["libraries"] = ["Missing"]
        with self.assertRaisesRegex(ValueError, "not found"):
            self.run_sync(SectionPlex(self.sections(), {}))

    def test_sync_uses_streaming_plex_client_when_available(self):
        path = self.put("Movies/Streamed/streamed.mkv")
        item = plex_item(1, "Streamed", path, tmdb=1)

        class StreamingPlex(SectionPlex):
            def iter_movies(self, key):
                yield from self._items.get(key, [])

            def movies(self, key):
                raise AssertionError("sync should stream Plex pages")

        plex = StreamingPlex(self.sections(), {"1": [item]})
        self.cfg["plex"]["libraries"] = ["Movies"]
        self.cfg["plex"]["path_map"] = {"/remote": self.root}
        stats = self.run_sync(plex)
        self.assertEqual(stats["new"], 1)
        self.assertEqual(self.movie()["title"], "Streamed")


class IdentityAndCollect(SyncBase):
    def test_new_movie_born_ids_sources_probe(self):
        p = self.put("Movies/Alien (1979)/alien.mkv")
        self.run_sync(
            FakePlex(
                [
                    plex_item(
                        10,
                        "Alien",
                        p,
                        tmdb=348,
                        imdb="tt0078748",
                        year=1979,
                        added=NOW - 400 * DAY,
                    )
                ]
            )
        )
        m = self.movie()
        self.assertEqual(
            (
                m["tmdb"],
                m["imdb"],
                m["state"],
                m["zone"],
                m["video_class"],
                m["audio_class"],
            ),
            ("348", "tt0078748", "present", "unmanaged", "1080hd", "5ch"),
        )
        self.assertEqual(self.events("born"), [("born", None, NOW - 400 * DAY)])
        srcs = {r[0] for r in self.conn.execute("SELECT source FROM source_record")}
        self.assertEqual(srcs, {"plex", "ffprobe"})
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM audio_stream").fetchone()[0], 1
        )

    def test_resync_is_idempotent(self):
        p = self.put("Movies/A/a.mkv")
        plex = FakePlex([plex_item(1, "A", p, tmdb=1)])
        self.run_sync(plex)
        n = self.conn.execute("SELECT COUNT(*) FROM event").fetchone()[0]
        self.run_sync(plex, now=NOW + DAY)
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM event").fetchone()[0], n
        )
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM movie").fetchone()[0], 1
        )

    def test_identity_survives_new_path_new_rating_key_and_restores_state(self):
        p1 = self.put("Movies/Alien (1979)/alien.mkv", b"a" * 5000)
        plex = FakePlex([plex_item(10, "Alien", p1, tmdb=348, rating=10, views=1)])
        self.run_sync(plex)
        mid = self.movie()["id"]
        p2 = os.path.join(
            self.root, "Curated", "Watched", "1080hd", "5ch", "5", "Alien", "alien.mkv"
        )
        os.makedirs(os.path.dirname(p2))
        os.rename(p1, p2)
        plex.items = [
            plex_item(77, "Alien", p2, tmdb=348)
        ]  # Plex made a new item: rating/watch lost
        self.run_sync(plex, now=NOW + DAY)
        m = self.movie()
        self.assertEqual(
            (m["id"], m["plex_rating_key"], m["zone"], m["stars"]),
            (mid, "77", "watched", 5),
        )
        self.assertIn(("rate", "77", 10), plex.calls)
        self.assertIn(("scrobble", "77"), plex.calls)
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM movie").fetchone()[0], 1
        )
        self.assertEqual(
            self.events("rated"), [("rated", "5", NOW)]
        )  # restoring is not a new rating

    def test_fingerprint_matches_when_ids_are_missing_later(self):
        p = self.put("Movies/X/x.mkv", b"z" * 4000)
        self.run_sync(FakePlex([plex_item(1, "X", p, tmdb=5)]))
        self.run_sync(
            FakePlex([plex_item(2, "X", p)]), now=NOW + DAY
        )  # Plex lost its match
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM movie").fetchone()[0], 1
        )
        self.assertEqual(self.movie()["unidentified"], 0)

    def test_id_from_filename_tag_and_from_radarr_path(self):
        a = self.put("Movies/Tagged {tmdb-99}/Tagged {tmdb-99}.mkv", b"1")
        b = self.put("Movies/FromRadarr/r.mkv", b"2")
        radarr = FakeRadarr(
            [
                {
                    "id": 7,
                    "tmdbId": 123,
                    "path": os.path.join(self.root, "Movies", "FromRadarr"),
                }
            ]
        )
        self.run_sync(
            FakePlex([plex_item(1, "Tagged", a), plex_item(2, "R", b)]), radarr=radarr
        )
        got = {r[0]: r[1] for r in self.conn.execute("SELECT title, tmdb FROM v_movie")}
        self.assertEqual(got, {"Tagged": "99", "R": "123"})
        self.assertEqual(
            self.conn.execute("SELECT radarr_id FROM movie WHERE title='R'").fetchone()[
                0
            ],
            7,
        )

    def test_unidentified_is_tracked_once_and_flagged(self):
        p = self.put("Other/Home Movies/christmas.mkv")
        plex = FakePlex([plex_item(5, "Christmas 1999", p)])
        st = self.run_sync(plex)
        self.run_sync(plex, now=NOW + DAY)
        self.assertEqual(st["unidentified"], 1)
        self.assertEqual(
            self.conn.execute(
                "SELECT COUNT(*) FROM movie WHERE unidentified=1"
            ).fetchone()[0],
            1,
        )
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM external_id").fetchone()[0], 0
        )

    def test_empty_plex_is_refused_not_treated_as_mass_disappearance(self):
        p = self.put("Movies/A/a.mkv")
        self.run_sync(FakePlex([plex_item(1, "A", p, tmdb=1)]))
        with self.assertRaises(RuntimeError):
            self.run_sync(FakePlex([]), now=NOW + DAY)

    def test_missing_from_plex_is_not_an_event_or_state_change(self):
        a, b = self.put("Movies/A/a.mkv", b"1"), self.put("Movies/B/b.mkv", b"2")
        self.run_sync(
            FakePlex([plex_item(1, "A", a, tmdb=1), plex_item(2, "B", b, tmdb=2)])
        )
        before = self.conn.execute("SELECT COUNT(*) FROM event").fetchone()[0]
        with self.assertLogs("plexcurator", level="WARNING") as cm:
            self.run_sync(FakePlex([plex_item(1, "A", a, tmdb=1)]), now=NOW + DAY)
        self.assertTrue(any("no longer listed" in m for m in cm.output))
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM event").fetchone()[0], before
        )
        self.assertEqual(
            self.conn.execute(
                "SELECT COUNT(*) FROM movie WHERE state='present'"
            ).fetchone()[0],
            2,
        )

    def test_retired_movie_found_again_gets_reborn(self):
        p = self.put("Movies/A/a.mkv")
        plex = FakePlex([plex_item(1, "A", p, tmdb=1)])
        self.run_sync(plex)
        self.conn.execute("UPDATE movie SET state='retired', retired_at=?", (NOW,))
        self.conn.execute(
            "INSERT INTO event(movie_id,ts,kind,life) VALUES (1,?, 'retired', 0)",
            (NOW,),
        )
        self.run_sync(plex, now=NOW + DAY)
        m = self.movie()
        self.assertEqual((m["state"], m["life"]), ("present", 1))
        self.assertEqual([e[0] for e in self.events()][-1], "reborn")

    def test_two_versions_flagged_multi_version(self):
        p = self.put("Movies/A/a.mkv")
        q = self.put("Movies/A/a-4k.mkv", b"other")
        it = plex_item(1, "A", p, tmdb=1)
        it["Media"].append({"Part": [{"file": q}]})
        with self.assertLogs("plexcurator", level="WARNING"):
            self.run_sync(FakePlex([it]))
        self.assertEqual(self.movie()["multi_version"], 1)


class WatchSemantics(SyncBase):
    def setUp(self):
        super().setUp()
        self.p = self.put("Movies/A/a.mkv")

    def go(self, now, **kw):
        self.run_sync(FakePlex([plex_item(1, "A", self.p, tmdb=1, **kw)]), now=now)

    def test_partial_play_over_threshold_counts_and_peak_never_drops(self):
        self.go(NOW, offset=4_200_000, last_viewed=NOW - 5)  # 60%
        m = self.movie()
        self.assertEqual(
            (m["peak_percent"], m["watched"], m["first_watched_at"]), (60.0, 1, NOW - 5)
        )
        self.assertEqual(self.events("watched"), [("watched", "60.0", NOW - 5)])
        self.go(NOW + DAY, offset=1_400_000)  # restarted and stopped at 20%
        self.assertEqual(self.movie()["peak_percent"], 60.0)
        self.assertEqual(len(self.events("watched")), 1)

    def test_under_threshold_is_recorded_but_not_watched(self):
        self.go(NOW, offset=2_100_000)  # 30%
        m = self.movie()
        self.assertEqual((m["peak_percent"], m["watched"]), (30.0, 0))
        self.assertEqual(len(self.events("watched")), 1)

    def test_threshold_is_configurable(self):
        self.cfg["watched_pct"] = 25
        self.go(NOW, offset=2_100_000)
        self.assertEqual(self.movie()["watched"], 1)

    def test_finished_play_is_100_and_each_new_play_is_an_event(self):
        self.go(NOW, views=1, last_viewed=NOW - 10)
        self.assertEqual(self.events("watched"), [("watched", "100", NOW - 10)])
        self.go(NOW + DAY, views=1)  # nothing new
        self.assertEqual(len(self.events("watched")), 1)
        self.go(NOW + 2 * DAY, views=2, last_viewed=NOW + 2 * DAY - 1)
        self.assertEqual(len(self.events("watched")), 2)

    def test_threshold_crossing_then_finish(self):
        self.go(NOW, offset=1_000_000)  # 14%
        self.go(NOW + DAY, offset=4_000_000)  # 57%
        self.go(NOW + 2 * DAY, views=1)  # finished, offset cleared
        m = self.movie()
        self.assertEqual((m["peak_percent"], m["watched"]), (100.0, 1))
        self.assertEqual(
            [e[1] for e in self.events("watched")], ["14.3", "57.1", "100"]
        )

    def test_ratings_are_whole_stars_rounded_down_with_dates(self):
        self.go(NOW, rating=9.0, last_rated=NOW - 50)
        self.assertEqual(self.events("rated"), [("rated", "4", NOW - 50)])
        self.go(NOW + DAY, rating=8.0)  # same whole stars? 8 -> 4: no event
        self.assertEqual(len(self.events("rated")), 1)
        self.go(NOW + 2 * DAY, rating=1.0)  # half star = 0
        self.assertEqual([e[1] for e in self.events("rated")], ["4", "0"])
        self.assertEqual(self.movie()["stars"], 0)

    def test_cleared_rating_is_recorded_as_zero(self):
        self.go(NOW, rating=10.0)
        self.go(NOW + DAY)
        self.assertEqual([e[1] for e in self.events("rated")], ["5", "0"])
