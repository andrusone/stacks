import os

from plexcurator import alerts, discover, sync, watchlist

from .helpers import DAY, NOW, Base, FakePlex, FakeRadarr, fake_probe, plex_item


def wl(tmdb=None, imdb=None):
    it = {"type": "movie", "title": "W", "Guid": []}
    if tmdb:
        it["Guid"].append({"id": f"tmdb://{tmdb}"})
    if imdb:
        it["Guid"].append({"id": f"imdb://{imdb}"})
    return it


class Watchlist(Base):
    def own(self, tmdb=1):
        p = self.mkfile(f"Movies/M{tmdb}/m.mkv", bytes([tmdb]) * 50)
        sync.sync(
            self.conn,
            self.cfg,
            FakePlex([plex_item(tmdb, f"M{tmdb}", p, tmdb=tmdb)]),
            now=NOW,
            probe_fn=fake_probe(),
        )

    def events(self):
        return [
            tuple(r)
            for r in self.conn.execute(
                "SELECT kind, ts, detail FROM event WHERE kind='watchlisted'"
            )
        ]

    def test_owned_movie_gets_first_watchlist_date_once(self):
        self.own(1)
        plex = FakePlex(watchlist=[wl(tmdb=1)])
        st = watchlist.sync_watchlist(self.conn, plex, now=NOW + DAY)
        watchlist.sync_watchlist(self.conn, plex, now=NOW + 2 * DAY)
        self.assertEqual(st["linked"], 1)
        self.assertEqual(self.events(), [("watchlisted", NOW + DAY, None)])
        self.assertEqual(
            self.conn.execute("SELECT watchlisted_at FROM movie").fetchone()[0],
            NOW + DAY,
        )

    def test_watchlist_sync_uses_streaming_client_when_available(self):
        self.own(1)

        class StreamingPlex(FakePlex):
            def iter_watchlist(self):
                yield wl(tmdb=1)

            def watchlist(self):
                raise AssertionError("watchlist sync should use the iterator")

        stats = watchlist.sync_watchlist(self.conn, StreamingPlex(), now=NOW + DAY)
        self.assertEqual(stats["linked"], 1)

    def test_unowned_item_is_remembered_and_dated_when_the_movie_arrives(self):
        plex = FakePlex(watchlist=[wl(tmdb=7)])
        watchlist.sync_watchlist(self.conn, plex, now=NOW)
        self.assertEqual(self.events(), [])
        self.own(7)
        watchlist.sync_watchlist(self.conn, plex, now=NOW + 30 * DAY)
        self.assertEqual(
            self.events(), [("watchlisted", NOW, None)]
        )  # date it was first listed, not arrival

    def test_removed_then_readded_is_a_second_event_but_first_date_stays(self):
        self.own(1)
        watchlist.sync_watchlist(self.conn, FakePlex(watchlist=[wl(tmdb=1)]), now=NOW)
        watchlist.sync_watchlist(
            self.conn, FakePlex(watchlist=[wl(tmdb=99)]), now=NOW + DAY
        )
        self.assertEqual(
            self.conn.execute(
                "SELECT present FROM watchlist WHERE value='1'"
            ).fetchone()[0],
            0,
        )
        watchlist.sync_watchlist(
            self.conn, FakePlex(watchlist=[wl(tmdb=1)]), now=NOW + 2 * DAY
        )
        self.assertEqual(len(self.events()), 2)
        self.assertEqual(
            self.conn.execute("SELECT watchlisted_at FROM movie").fetchone()[0], NOW
        )

    def test_empty_answer_does_not_clear_and_errors_do_not_raise(self):
        self.own(1)
        watchlist.sync_watchlist(self.conn, FakePlex(watchlist=[wl(tmdb=1)]), now=NOW)
        watchlist.sync_watchlist(self.conn, FakePlex(watchlist=[]), now=NOW + DAY)
        self.assertEqual(
            self.conn.execute("SELECT present FROM watchlist").fetchone()[0], 1
        )

        class Boom(FakePlex):
            def watchlist(self):
                raise OSError("plex.tv down")

        with self.assertLogs("plexcurator", level="WARNING"):
            st = watchlist.sync_watchlist(self.conn, Boom(), now=NOW)
        self.assertIn("plex.tv down", st["error"])

    def test_items_without_ids_are_skipped_and_imdb_ids_match(self):
        self.own(3)
        self.conn.execute("INSERT INTO external_id VALUES (1,'imdb','tt333')")
        st = watchlist.sync_watchlist(
            self.conn, FakePlex(watchlist=[wl(), wl(imdb="tt333")]), now=NOW
        )
        self.assertEqual((st["unmatched"], st["linked"]), (1, 1))


class Discover(Base):
    def run_d(self, radarr=None, **kw):
        return discover.discover(
            self.conn, self.cfg, radarr, now=NOW, probe_fn=fake_probe(), **kw
        )

    def count(self, table):
        return self.conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]

    def test_tagged_file_not_in_plex_is_collected_in_unmanaged_and_managed_trees(self):
        self.mkfile("Movies/Heat (1995) {tmdb-949}/Heat (1995) {tmdb-949}.mkv", b"h")
        self.mkfile("Curated/Watchlist/Ronin (1998) {imdb-tt0122690}/r.mp4", b"r")
        self.mkfile("Movies/Heat (1995) {tmdb-949}/readme.txt", b"no")
        self.mkfile("Movies/.hidden/skip.mkv", b"s")
        st = self.run_d()
        self.assertEqual((st["new"], st["unidentified"], st["probed"]), (2, 0, 2))
        rows = {
            r["title"]: (r["tmdb"], r["imdb"], r["zone"])
            for r in self.conn.execute("SELECT * FROM v_movie")
        }
        self.assertEqual(
            rows,
            {
                "Heat": ("949", None, "unmanaged"),
                "Ronin": (None, "tt0122690", "watchlist"),
            },
        )
        self.assertEqual(
            self.conn.execute("SELECT year FROM movie WHERE title='Heat'").fetchone()[
                0
            ],
            1995,
        )
        self.assertEqual(self.count("event"), 2)
        self.assertEqual(self.count("source_record"), 2)

    def test_second_run_adds_nothing(self):
        self.mkfile("Movies/A {tmdb-1}/a.mkv", b"a")
        self.run_d()
        n = self.count("event")
        st = self.run_d()
        self.assertEqual(
            (st["new"], self.count("movie"), self.count("event")), (0, 1, n)
        )

    def test_radarr_path_identifies_untagged_file(self):
        p = self.mkfile("Movies/Untagged (2001)/u.mkv", b"u")
        radarr = FakeRadarr([{"id": 3, "tmdbId": 555, "path": os.path.dirname(p)}])
        self.run_d(radarr)
        m = self.conn.execute("SELECT * FROM v_movie").fetchone()
        self.assertEqual((m["tmdb"], m["radarr_id"], m["unidentified"]), ("555", 3, 0))

    def test_unidentified_file_is_flagged_and_alerts(self):
        self.mkfile("Other/Home Videos/christmas.mp4", b"c")
        st = self.run_d()
        self.assertEqual(st["unidentified"], 1)
        self.assertEqual(
            self.conn.execute("SELECT unidentified FROM movie").fetchone()[0], 1
        )
        self.assertEqual(len(alerts.collect(self.conn)), 1)

    def test_walk_then_plex_attaches_to_same_movie(self):
        p = self.mkfile("Movies/Z/z.mkv", b"zzzz")
        self.run_d()  # walk first: unidentified
        self.assertEqual(
            self.conn.execute("SELECT unidentified FROM movie").fetchone()[0], 1
        )
        sync.sync(
            self.conn,
            self.cfg,
            FakePlex([plex_item(4, "Z", p, tmdb=42)]),
            now=NOW + DAY,
            probe_fn=fake_probe(),
        )
        self.assertEqual(self.count("movie"), 1)
        self.assertEqual(
            self.conn.execute("SELECT unidentified FROM movie").fetchone()[0], 0
        )
        self.assertEqual(
            self.conn.execute("SELECT value FROM external_id").fetchone()[0], "42"
        )

    def test_identical_copy_is_ignored_with_a_warning(self):
        self.mkfile("Movies/A {tmdb-1}/a.mkv", b"same-bytes")
        self.run_d()
        self.mkfile("Movies/Copy/a-copy.mkv", b"same-bytes")
        with self.assertLogs("plexcurator", level="WARNING") as cm:
            st = self.run_d()
        self.assertEqual(st["duplicates"], 1)
        self.assertTrue(any("identical copy" in m for m in cm.output))
        self.assertEqual(self.count("movie"), 1)

    def test_file_gone_from_disk_is_flagged_not_retired(self):
        p = self.mkfile("Movies/A {tmdb-1}/a.mkv", b"a")
        self.run_d()
        os.remove(p)
        with self.assertLogs("plexcurator", level="WARNING"):
            st = self.run_d()
        self.assertEqual(st["missing"], 1)
        self.assertEqual(self.conn.execute("SELECT present FROM file").fetchone()[0], 0)
        self.assertEqual(
            self.conn.execute("SELECT state FROM movie").fetchone()[0], "present"
        )
        self.assertEqual(self.count("event"), 1)  # only 'born': no disappearance event

    def test_title_and_year_parsing(self):
        self.assertEqual(
            discover.title_year("/x/The.Matrix.1999.1080p.BluRay.mkv"),
            ("The Matrix", 1999),
        )
        self.assertEqual(
            discover.title_year("/x/Alien (1979) {tmdb-348} [1080hd 5ch].mkv"),
            ("Alien", 1979),
        )
        self.assertEqual(discover.title_year("/x/christmas.mp4"), ("christmas", None))
