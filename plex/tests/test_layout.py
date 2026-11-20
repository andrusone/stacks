import os

from plexcurator import collect, layout, naming, sync

from .helpers import DAY, NOW, Base, FakePlex, FakeRadarr, fake_probe, plex_item


class LayoutBase(Base):
    def add(
        self, rel, title="Alien", tmdb=348, year=1979, extra=(), probe=None, **item
    ):
        p = self.mkfile(rel, b"d" * 100)
        for e in extra:
            self.mkfile(os.path.join(os.path.dirname(rel), e), b"s")
        self.plex = FakePlex([plex_item(1, title, p, tmdb=tmdb, year=year, **item)])
        self._probe = probe
        self.resync(probe=probe)
        return p

    def resync(self, now=NOW, probe=None, radarr=None):
        sync.sync(
            self.conn,
            self.cfg,
            self.plex,
            radarr,
            now=now,
            probe_fn=probe or fake_probe(),
        )

    def plan(self):
        return layout.plan_moves(self.conn, self.cfg)

    def go(self, **kw):
        return layout.apply_moves(
            self.conn,
            self.cfg,
            self.plan(),
            execute=True,
            probe_fn=getattr(self, "_probe", None) or fake_probe(),
            **kw,
        )

    def path(self):
        return self.conn.execute("SELECT path FROM file").fetchone()[0]

    def watched_dir(self, *parts):
        return os.path.join(self.root, "Curated", "Watched", *parts)


class Moves(LayoutBase):
    def test_move_refreshes_only_selected_movie_libraries(self):
        self.add("Movies/A/a.mkv", views=1)
        self.cfg["plex"]["libraries"] = ["Movies"]
        sections = [
            {"key": "1", "title": "Movies", "type": "movie", "Location": []},
            {"key": "2", "title": "Legacy", "type": "movie", "Location": []},
        ]

        class PlexWithSections(FakePlex):
            def sections(self):
                return sections

        self.plex = PlexWithSections(self.plex.items)
        self.go(plex=self.plex)
        self.assertEqual(
            [call for call in self.plex.calls if call[0] == "scan"], [("scan", "1")]
        )

    def test_watched_movie_is_moved_renamed_with_siblings_and_recorded(self):
        old = self.add(
            "Movies/Alien (1979)/alien.1080p.mkv",
            extra=("alien.1080p.en.srt", "poster.jpg"),
            views=1,
        )
        radarr = FakeRadarr([{"id": 4, "tmdbId": 348, "path": os.path.dirname(old)}])
        self.resync(radarr=radarr)
        plex = self.plex
        plan = self.plan()
        self.assertEqual(len(plan), 1)
        layout.apply_moves(
            self.conn, self.cfg, plan, execute=False
        )  # dry run changes nothing
        self.assertTrue(os.path.exists(old))
        res = layout.apply_moves(
            self.conn,
            self.cfg,
            plan,
            execute=True,
            radarr=radarr,
            plex=plex,
            probe_fn=fake_probe(),
        )
        self.assertEqual([s for _, s in res], ["moved"])
        stem = "Alien (1979) {tmdb-348} [1080hd 5ch]"
        folder = self.watched_dir("1080hd", "5ch", "0", stem)
        self.assertEqual(
            sorted(os.listdir(folder)),
            sorted([stem + ".mkv", stem + ".en.srt", "poster.jpg"]),
        )
        self.assertFalse(os.path.exists(os.path.dirname(old)))  # moved, not copied
        self.assertEqual(self.path(), os.path.join(folder, stem + ".mkv"))
        ev = self.conn.execute(
            "SELECT value, detail FROM event WHERE kind='moved'"
        ).fetchall()
        self.assertEqual(len(ev), 1)
        self.assertIn('"reason": "watched"', ev[0][1])
        self.assertEqual(radarr.calls, [("track_at", 4, folder)])
        self.assertIn(("scan", "1"), plex.calls)
        self.assertEqual(
            self.conn.execute("SELECT zone FROM file").fetchone()[0], "watched"
        )
        self.assertEqual(self.plan(), [])  # idempotent

    def test_rated_unwatched_movie_moves_by_stars_and_rerates_move_between_folders(
        self,
    ):
        self.add("Movies/A/a.mkv", rating=6.0)
        self.go()
        self.assertIn(os.sep + "3" + os.sep, self.path())
        self.plex.items[0]["userRating"] = 10.0
        self.resync(now=NOW + DAY)
        self.assertEqual(len(self.plan()), 1)
        self.go()
        self.assertIn(os.sep + "5" + os.sep, self.path())
        self.assertEqual(
            self.conn.execute(
                "SELECT COUNT(*) FROM event WHERE kind='moved'"
            ).fetchone()[0],
            2,
        )
        self.assertEqual(os.listdir(self.watched_dir("1080hd", "5ch", "3")), [])

    def test_half_star_rating_is_folder_zero_and_never_returns_to_unmanaged(self):
        self.add("Movies/A/a.mkv", views=1, rating=1.0)
        self.go()
        self.assertIn(os.sep + "0" + os.sep, self.path())
        self.plex.items[0]["viewOffset"] = 1
        self.resync(now=NOW + DAY)
        self.assertEqual(self.plan(), [])

    def test_watchlisted_goes_to_flat_watchlist_then_to_watched_when_watched(self):
        self.add("Movies/A/a.mkv")
        self.conn.execute(
            "INSERT INTO watchlist VALUES ('tmdb','348',?,?,1)", (NOW, NOW)
        )
        self.go()
        stem = "Alien (1979) {tmdb-348} [1080hd 5ch]"
        self.assertEqual(
            self.path(),
            os.path.join(self.root, "Curated", "Watchlist", stem, stem + ".mkv"),
        )
        self.plex.items[0]["viewCount"] = 1
        self.resync(now=NOW + DAY)
        self.go()
        self.assertEqual(
            self.conn.execute("SELECT zone FROM file").fetchone()[0], "watched"
        )
        self.assertFalse(
            os.path.exists(os.path.join(self.root, "Curated", "Watchlist", stem))
        )

    def test_untouched_cases(self):
        self.add(
            "Movies/Plain/p.mkv", title="Plain", tmdb=1
        )  # unwatched, unrated, not listed
        self.assertEqual(self.plan(), [])
        self.conn.execute("UPDATE movie SET watched=1")
        self.conn.execute("UPDATE movie SET unidentified=1")
        self.assertEqual(self.plan(), [])
        self.conn.execute("UPDATE movie SET unidentified=0, multi_version=1")
        self.assertEqual(self.plan(), [])
        self.conn.execute("UPDATE movie SET multi_version=0")
        self.conn.execute("UPDATE file SET zone='other'")
        self.assertEqual(self.plan(), [])

    def test_loose_file_in_unmanaged_root_gets_its_own_folder(self):
        old = self.add("Movies/loose.mkv", views=1, extra=("loose.srt",))
        self.go()
        stem = "Alien (1979) {tmdb-348} [1080hd 5ch]"
        self.assertEqual(
            sorted(os.listdir(os.path.dirname(self.path()))),
            sorted([stem + ".mkv", stem + ".srt"]),
        )
        self.assertFalse(os.path.exists(old))
        self.assertTrue(
            os.path.isdir(os.path.join(self.root, "Movies"))
        )  # the unmanaged root itself stays

    def test_folder_with_two_videos_is_treated_as_loose(self):
        self.mkfile("Movies/Pack/other.mkv", b"o")
        old = self.add("Movies/Pack/a.mkv", views=1)
        self.go()
        self.assertTrue(
            os.path.exists(os.path.join(self.root, "Movies", "Pack", "other.mkv"))
        )
        self.assertFalse(os.path.exists(old))

    def test_destination_collision_fails_safely(self):
        old = self.add("Movies/A/a.mkv", views=1)
        stem = "Alien (1979) {tmdb-348} [1080hd 5ch]"
        os.makedirs(self.watched_dir("1080hd", "5ch", "0", stem))
        res = self.go()
        self.assertTrue(res[0][1].startswith("failed"))
        self.assertTrue(os.path.exists(old))
        self.assertEqual(
            self.conn.execute(
                "SELECT COUNT(*) FROM event WHERE kind='moved'"
            ).fetchone()[0],
            0,
        )

    def test_reclassify_after_config_edit_renames_in_place(self):
        self.add("Movies/A/a.mkv", views=1)
        self.go()
        self.cfg["audio"] = {
            "surround": {"min_channels": 5},
            "2ch": {"min_channels": 0},
        }
        collect.reclassify(self.conn, self.cfg)
        plan = self.plan()
        self.assertEqual(len(plan), 1)
        self.go()
        self.assertIn(os.path.join("1080hd", "surround", "0"), self.path())

    def test_radarr_path_is_translated_for_container_mounts(self):
        self.add("Movies/A/a.mkv", views=1)
        self.cfg["radarr"]["path_map"] = {"/media": self.root}
        radarr = FakeRadarr([{"id": 9, "tmdbId": 348, "path": "/media/Movies/A"}])
        self.resync(radarr=radarr)
        self.go(radarr=radarr)
        stem = "Alien (1979) {tmdb-348} [1080hd 5ch]"
        self.assertEqual(
            radarr.calls,
            [("track_at", 9, f"/media/Curated/Watched/1080hd/5ch/0/{stem}")],
        )


class TreeAndNames(Base):
    def test_tree_is_created_from_class_tables_and_never_deletes(self):
        todo = layout.ensure_tree(self.cfg, create=False)
        self.assertFalse(
            os.path.exists(os.path.join(self.root, "Curated", "Watchlist"))
        )
        self.assertEqual(len(todo), 2 + 4 * 3 * 6)  # Watchlist, Watched + 72 leaf dirs
        layout.ensure_tree(self.cfg)
        self.assertTrue(
            os.path.isdir(
                os.path.join(self.root, "Curated", "Watched", "4khd", "7ch", "0")
            )
        )
        self.assertTrue(
            os.path.isdir(
                os.path.join(self.root, "Curated", "Watched", "sd", "2ch", "5")
            )
        )
        self.assertEqual(layout.ensure_tree(self.cfg), [])
        self.cfg["video"] = {"8k": {"min_width": 6000}, **self.cfg["video"]}
        self.assertEqual(
            len(layout.ensure_tree(self.cfg)), 3 * 6
        )  # new class -> new folders only

    def row(self, **kw):
        base = {
            "tmdb": "348",
            "imdb": "tt1",
            "title": "Alien: The / Cut?",
            "year": 1979,
            "video_class": "4khd",
            "audio_class": "7ch",
            "hdr": "hdr10",
            "path": "/x/a.MKV",
        }
        return {**base, **kw}

    def test_names(self):
        c = self.cfg
        self.assertEqual(
            naming.curated_stem(self.row(), c),
            "Alien The Cut (1979) {tmdb-348} [4khd 7ch HDR10]",
        )
        self.assertEqual(
            naming.curated_file(self.row(), c),
            "Alien The Cut (1979) {tmdb-348} [4khd 7ch HDR10].MKV",
        )
        self.assertEqual(
            naming.curated_stem(self.row(tmdb=None, hdr=None, year=None), c),
            "Alien The Cut {imdb-tt1} [4khd 7ch]",
        )
        self.assertEqual(
            naming.curated_stem(self.row(hdr="sdr"), c),
            "Alien The Cut (1979) {tmdb-348} [4khd 7ch]",
        )
        self.assertIsNone(naming.curated_stem(self.row(tmdb=None, imdb=None), c))
        self.assertIsNone(naming.curated_stem(self.row(video_class=None), c))
