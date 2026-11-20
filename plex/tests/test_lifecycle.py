import os

from plexcurator import alerts, config, lifecycle

from .helpers import DAY, GB, NOW, Base, FakePlex, FakeRadarr

TOTAL = 1000 * GB
LOW = 300 * GB  # 30% free: below the 35% trigger


class LC(Base):
    n = 0

    def add(
        self,
        title,
        folder="Movies",
        rating=None,
        watched=0,
        born_days=800,
        wl_days=None,
        size=10,
        rated_days=None,
        peak=0,
        unidentified=0,
        multi=0,
        zone=None,
        rating_key=True,
        tmdb=True,
    ):
        LC.n += 1
        i = LC.n
        if folder == "Curated/Watchlist":
            zone = zone or "watchlist"
        z = zone or ("watched" if folder.startswith("Curated/Watched") else "unmanaged")
        d = os.path.join(self.root, folder, f"{title} (2000)")
        p = self.mkfile(os.path.join(d, f"{title}.mkv"), b"x")
        mid = self.conn.execute(
            """INSERT INTO movie(title,year,rating,rated_at,watched,peak_percent,born_at,watchlisted_at,
            unidentified,multi_version,plex_rating_key,radarr_id,first_seen_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                title,
                2000,
                rating,
                (
                    NOW - rated_days * DAY
                    if rated_days is not None
                    else (NOW - 50 * DAY if rating else None)
                ),
                watched,
                peak,
                NOW - born_days * DAY,
                None if wl_days is None else NOW - wl_days * DAY,
                unidentified,
                multi,
                str(i) if rating_key else None,
                100 + i,
                NOW,
                NOW,
            ),
        ).lastrowid
        if tmdb:
            self.conn.execute(
                "INSERT INTO external_id VALUES (?,?,?)", (mid, "tmdb", str(1000 + i))
            )
        self.conn.execute(
            "INSERT INTO file(movie_id,path,size,mtime,fingerprint,zone,first_seen_at,last_seen_at) "
            "VALUES (?,?,?,?,?,?,?,?)",
            (mid, p, size * GB, 0, f"fp{i}", z, NOW, NOW),
        )
        self.conn.execute(
            "INSERT OR REPLACE INTO meta VALUES ('last_sync_ok', ?)", (str(NOW),)
        )
        self.conn.commit()
        return mid, p

    def plan(self, free=LOW, total=TOTAL):
        return lifecycle.plan(self.conn, self.cfg, free, total, NOW)

    def names(self, free=LOW):
        return [c["title"] for c in self.plan(free)[0]]


class Rules(LC):
    def test_nothing_when_space_is_fine(self):
        self.add("One", rating=2)
        self.assertEqual(self.plan(free=360 * GB), ([], None))
        self.assertEqual(
            self.plan(free=350 * GB), ([], None)
        )  # exactly 35% is not "below"

    def test_order_is_one_two_watchlist_unmanaged_and_dates_not_size_order_within(self):
        self.add("Stale_new", born_days=500, size=90)
        self.add("Stale_old", born_days=900, size=1)
        self.add("Wl_new", folder="Curated/Watchlist", wl_days=400, size=80)
        self.add("Wl_old", folder="Curated/Watchlist", wl_days=700, size=2)
        self.add("Two_new", rating=4, rated_days=5, size=70, born_days=10)
        self.add("Two_old", rating=5, rated_days=90, size=3, born_days=10)
        self.add("One_new", rating=2, rated_days=5, size=60, born_days=10)
        self.add("One_old", rating=3, rated_days=90, size=4, born_days=10)
        sel, alert = self.plan(free=0, total=10_000 * GB)
        self.assertEqual(
            [c["rule"] for c in sel],
            ["one_star"] * 2
            + ["two_star"] * 2
            + ["stale_watchlist"] * 2
            + ["stale_unmanaged"] * 2,
        )
        self.assertEqual(
            [c["title"] for c in sel],
            [
                "One_old",
                "One_new",
                "Two_old",
                "Two_new",
                "Wl_old",
                "Wl_new",
                "Stale_old",
                "Stale_new",
            ],
        )
        self.assertTrue(all(c["reason"] for c in sel))

    def test_three_to_five_stars_are_never_candidates_anywhere(self):
        for r in (6, 7, 8, 9, 10):
            self.add(f"R{r}", rating=r, wl_days=900)  # old, watchlisted, rated high
            self.add(f"RW{r}", folder="Curated/Watchlist", rating=r, wl_days=900)
        self.assertEqual(self.names(), [])

    def test_age_rules_skip_watched_rated_and_progress(self):
        self.add("Watched", watched=1, peak=100)
        self.add("Partial", peak=30)
        self.add(
            "HalfStar", rating=1
        )  # 0.5 star: rated, not a 1-star candidate, not "untouched"
        self.add(
            "Listed", wl_days=900
        )  # watchlisted long ago, untouched: the watchlist rule takes it, not rule 4
        self.add("Plain")
        sel, _ = self.plan()
        self.assertEqual(
            [(c["title"], c["rule"]) for c in sel],
            [("Listed", "stale_watchlist"), ("Plain", "stale_unmanaged")],
        )

    def test_default_stale_days_includes_exact_cutoff(self):
        self.add("AtCutoff", born_days=365)
        self.add("OneDayYoung", born_days=364)
        self.assertEqual(self.names(), ["AtCutoff"])

    def test_young_content_and_legacy_stale_months(self):
        self.add("Young", born_days=300)
        self.add("Old", born_days=400)
        self.assertEqual(self.names(), ["Old"])
        self.cfg["lifecycle"] = config.load(
            overrides={"lifecycle": {"stale_months": 6}}
        )["lifecycle"]
        self.assertEqual(self.names(), ["Old", "Young"])

    def test_unmanaged_folder_stale_days_overrides_the_default(self):
        self.cfg["folders"]["unmanaged"][0]["stale_days"] = 61
        self.add("AtFolderCutoff", born_days=61)
        self.add("OneDayYoung", born_days=60)
        self.assertEqual(self.names(), ["AtFolderCutoff"])

    def test_watchlist_stale_days_overrides_default_independently_of_folder_age(self):
        self.cfg["lifecycle"]["watchlist_stale_days"] = 61
        self.cfg["folders"]["unmanaged"][0]["stale_days"] = 30
        self.add("AtWatchlistCutoff", folder="Curated/Watchlist", wl_days=61)
        self.add("OneDayYoung", folder="Curated/Watchlist", wl_days=60)
        self.assertEqual(self.names(), ["AtWatchlistCutoff"])

    def test_unmanaged_without_lifecycle_flag_is_never_touched(self):
        self.add("InOther", folder="Other", rating=2)
        self.add("InOtherOld", folder="Other")
        self.assertEqual(self.names(), [])

    def test_unidentified_multi_version_zone_other_and_missing_file_are_invariants(
        self,
    ):
        self.add("Home", unidentified=1, tmdb=False)
        self.add("Multi", multi=1, rating=2)
        self.add("Elsewhere", zone="other")
        mid, p = self.add("Gone", rating=2)
        self.conn.execute("UPDATE file SET present=0 WHERE movie_id=?", (mid,))
        self.assertEqual(self.names(), [])

    def test_rules_can_be_turned_off_by_name(self):
        self.add("One", rating=2)
        self.add("Stale")
        self.cfg["lifecycle"]["rules"] = ["two_star", "stale_unmanaged"]
        self.assertEqual(self.names(), ["Stale"])

    def test_age_only_rules_ignore_free_space_and_folder_override_wins(self):
        self.add("Old", born_days=800)
        self.add("Recent", born_days=10)
        self.cfg["lifecycle"]["age_only"] = ["stale_unmanaged"]
        selected, alert = self.plan(free=800 * GB)
        self.assertEqual([c["title"] for c in selected], ["Old"])
        self.assertIsNone(alert)
        self.assertTrue(selected[0]["age_only"])
        self.assertIn("age only: stale_unmanaged, 800 days old", selected[0]["reason"])

        self.cfg["folders"]["unmanaged"][0]["age_only"] = False
        self.assertEqual(self.plan(free=800 * GB), ([], None))

        self.cfg["lifecycle"]["age_only"] = []
        self.cfg["folders"]["unmanaged"][0]["age_only"] = True
        self.assertEqual(self.names(free=800 * GB), ["Old"])

    def test_age_only_candidates_are_capped_with_an_alert(self):
        self.cfg["lifecycle"]["age_only"] = ["stale_unmanaged"]
        for i in range(12):
            self.add(f"Old{i:02d}", born_days=800 + i)
        selected, alert = self.plan(free=800 * GB)
        self.assertEqual(len(selected), 10)
        self.assertTrue(all(c["age_only"] for c in selected))
        self.assertIn("2 eligible candidate(s) remain", alert)
        self.assertIn("Old01", alert)

    def test_stops_when_target_reached_and_caps_per_run(self):
        for i in range(5):
            self.add(f"S{i}", born_days=900 - i, size=20)
        sel, alert = self.plan(free=349 * GB)  # needs 51 GB: three 20 GB movies
        self.assertEqual((len(sel), alert), (3, None))
        self.cfg["advanced"]["max_deletions_per_run"] = 2
        sel, alert = self.plan(free=0, total=10_000 * GB)
        self.assertEqual(len(sel), 2)
        self.assertIn("3 eligible candidate(s) remain", alert)


class Preview(LC):
    def test_preview_groups_by_folder_and_rule_with_age_provenance(self):
        self.cfg["folders"]["unmanaged"][0]["stale_days"] = 61
        self.cfg["folders"]["unmanaged"][1]["lifecycle"] = True
        self.cfg["lifecycle"]["watchlist_stale_days"] = 30
        self.add(
            "Watchlist",
            folder="Curated/Watchlist",
            wl_days=31,
            size=4,
        )
        self.add("Unmanaged", born_days=61, size=6)
        self.add("Default", folder="Other", born_days=400, size=5)
        self.add("OneStar", rating=2, rated_days=60, size=2)

        candidates, groups = lifecycle.preview_candidates(self.conn, self.cfg, NOW)

        self.assertEqual(len(candidates), 4)
        grouped = {(g["folder"], g["rule"]): g for g in groups}
        watchlist = os.path.join(self.root, "Curated", "Watchlist")
        movies = os.path.join(self.root, "Movies")
        other = os.path.join(self.root, "Other")
        self.assertEqual(
            (
                grouped[(watchlist, "stale_watchlist")]["count"],
                grouped[(watchlist, "stale_watchlist")]["size"],
                grouped[(watchlist, "stale_watchlist")]["oldest_age_days"],
            ),
            (1, 4 * GB, 31),
        )
        self.assertEqual(
            (
                grouped[(movies, "stale_unmanaged")]["count"],
                grouped[(movies, "stale_unmanaged")]["size"],
                grouped[(movies, "stale_unmanaged")]["oldest_age_days"],
            ),
            (1, 6 * GB, 61),
        )
        self.assertEqual(
            (
                grouped[(other, "stale_unmanaged")]["count"],
                grouped[(other, "stale_unmanaged")]["size"],
                grouped[(other, "stale_unmanaged")]["oldest_age_days"],
            ),
            (1, 5 * GB, 400),
        )
        by_title = {c["title"]: c for c in candidates}
        self.assertEqual(
            (
                by_title["Unmanaged"]["age_source"],
                by_title["Unmanaged"]["age_threshold"],
                by_title["Unmanaged"]["age_basis"],
            ),
            ("folder", "61 days", "added date"),
        )
        self.assertEqual(
            (
                by_title["Watchlist"]["age_source"],
                by_title["Watchlist"]["age_threshold"],
            ),
            ("rule", "30 days"),
        )
        self.assertEqual(
            (
                by_title["Default"]["age_source"],
                by_title["Default"]["age_threshold"],
            ),
            ("default", "365 days"),
        )
        self.assertEqual(
            (
                by_title["OneStar"]["age_source"],
                by_title["OneStar"]["age_basis"],
                by_title["OneStar"]["age_days"],
            ),
            ("rule", "rating date", 60),
        )


class AlertText(LC):
    def test_exhausted_alert_has_total_free_threshold_needed_and_instruction(self):
        self.add("Loved", rating=10)
        sel, alert = self.plan(
            free=2 * 10**12 * 15 // 100, total=2 * 10**12
        )  # 15% of 2 TB free
        self.assertEqual(sel, [])
        for need in (
            "2.00 TB total",
            "300.0 GB free (15.0%)",
            "35%",
            "40%",
            "500.0 GB needed",
            "exhausted",
            "manual aggressive intervention is required",
        ):
            self.assertIn(need, alert)

    def test_partial_plan_still_short_alerts(self):
        self.add("Small", rating=2, size=10)
        sel, alert = self.plan(free=300 * GB)
        self.assertEqual(len(sel), 1)
        self.assertIn("could free only 10.0 GB", alert)

    def test_all_rules_off_alerts_immediately(self):
        self.add("One", rating=2)
        self.cfg["lifecycle"]["rules"] = []
        sel, alert = self.plan()
        self.assertEqual(sel, [])
        self.assertIn("none enabled", alert)

    def test_publish_writes_logs_exit_code_and_clears(self):
        with self.assertLogs("plexcurator", level="ERROR"):
            rc = alerts.publish(self.cfg, ["storage is low"])
        self.assertEqual(rc, 2)
        self.assertIn("storage is low", open(self.cfg["advanced"]["alert_file"]).read())
        self.assertEqual(alerts.publish(self.cfg, []), 0)
        self.assertFalse(os.path.exists(self.cfg["advanced"]["alert_file"]))

    def test_unidentified_movies_raise_an_alert(self):
        self.add("Home Video", unidentified=1, tmdb=False)
        msgs = alerts.collect(self.conn)
        self.assertEqual(len(msgs), 1)
        self.assertIn("unidentified", msgs[0])
        self.assertIn("Home Video", msgs[0])


class Execute(LC):
    def setUp(self):
        super().setUp()
        self.cfg["mode"] = "reclaim"
        self.usage = lambda: (0, 10_000 * GB)

    def mirror(self):
        """A Plex whose live state equals the DB (nothing changed since the sync)."""
        live = {
            r["plex_rating_key"]: {
                "ratingKey": r["plex_rating_key"],
                "userRating": r["rating"],
            }
            for r in self.conn.execute(
                "SELECT plex_rating_key, rating FROM movie WHERE plex_rating_key IS NOT NULL"
            )
        }
        return FakePlex(live=live)

    def go(self, plex=None, radarr=None, planned=None, **kw):
        planned = (
            planned if planned is not None else self.plan(free=0, total=10_000 * GB)[0]
        )
        return lifecycle.execute(
            self.conn,
            self.cfg,
            planned,
            plex or self.mirror(),
            radarr,
            now=NOW,
            usage_fn=kw.get("usage_fn", self.usage),
            log_fn=lambda *_: None,
        )

    def test_retires_only_selected_keeps_metadata_and_bans_in_radarr(self):
        a = self.add("One", rating=2)
        b = self.add("Stale")
        keep3 = self.add("Keep3", rating=6)
        keepw = self.add("KeepW", watched=1, peak=100)
        self.conn.execute(
            "INSERT INTO source_record VALUES (?, 'ffprobe', ?, '{}')", (a[0], NOW)
        )
        radarr, plex = FakeRadarr(), self.mirror()
        res = self.go(plex, radarr)
        self.assertEqual([s for _, s in res], ["retired", "retired"])
        self.assertFalse(os.path.exists(os.path.dirname(a[1])))
        self.assertFalse(os.path.exists(os.path.dirname(b[1])))
        self.assertTrue(os.path.exists(keep3[1]) and os.path.exists(keepw[1]))
        rid = self.conn.execute(
            "SELECT radarr_id FROM movie WHERE id=?", (a[0],)
        ).fetchone()[0]
        self.assertIn(("delete_excl", rid), radarr.calls)
        self.assertIn(("trash", "1"), plex.calls)
        m = self.conn.execute(
            "SELECT state, retired_at FROM movie WHERE id=?", (a[0],)
        ).fetchone()
        self.assertEqual((m[0], m[1]), ("retired", NOW))
        self.assertEqual(
            self.conn.execute(
                "SELECT COUNT(*) FROM event WHERE kind='retired'"
            ).fetchone()[0],
            2,
        )
        self.assertEqual(
            self.conn.execute("SELECT COUNT(*) FROM source_record").fetchone()[0], 1
        )  # metadata kept
        d = self.conn.execute(
            "SELECT rule, reason, status, radarr_done, files_done FROM deletion WHERE movie_id=?",
            (a[0],),
        ).fetchone()
        self.assertEqual((d[0], d[2], d[3], d[4]), ("one_star", "done", 1, 1))
        self.assertIn("rated 1 star", d[1])

    def test_movie_unknown_to_radarr_is_banned_by_tmdb_id(self):
        self.add("One", rating=2)
        self.conn.execute("UPDATE movie SET radarr_id=NULL")
        radarr = FakeRadarr()
        self.go(radarr=radarr)
        self.assertEqual(radarr.calls, [("add_excl", 1000 + LC.n)])

    def test_requires_reclaim_mode(self):
        self.add("One", rating=2)
        self.cfg["mode"] = "organize"
        with self.assertRaises(RuntimeError):
            self.go()

    def test_stale_sync_or_missing_folder_refuses(self):
        self.add("One", rating=2)
        planned = self.plan(free=0, total=10_000 * GB)[0]
        self.conn.execute(
            "UPDATE meta SET value=? WHERE key='last_sync_ok'", (str(NOW - 5 * DAY),)
        )
        with self.assertRaises(RuntimeError):
            self.go(planned=planned)
        self.conn.execute(
            "UPDATE meta SET value=? WHERE key='last_sync_ok'", (str(NOW),)
        )
        self.cfg["folders"]["unmanaged"][0]["path"] = os.path.join(
            self.root, "NotMounted"
        )
        with self.assertRaises(RuntimeError):
            self.go(planned=planned)

    def test_live_plex_veto(self):
        a = self.add("One", rating=2)
        plex = FakePlex(
            live={str(LC.n): {"ratingKey": str(LC.n), "userRating": 8.0}}
        )  # just rated 4
        res = self.go(plex)
        self.assertTrue(res[0][1].startswith("skipped"))
        self.assertTrue(os.path.exists(a[1]))
        self.assertEqual(
            self.conn.execute("SELECT status FROM deletion").fetchone()[0], "skipped"
        )
        self.assertEqual(
            self.conn.execute("SELECT state FROM movie").fetchone()[0], "present"
        )

    def test_live_veto_when_watched_since_sync_and_when_unknown_to_plex(self):
        self.add("Stale")
        plex = FakePlex(live={str(LC.n): {"ratingKey": str(LC.n), "viewOffset": 5000}})
        self.assertTrue(self.go(plex)[0][1].startswith("skipped"))
        b = self.add("NoKey", rating_key=False)
        planned = [
            c for c in self.plan(free=0, total=10_000 * GB)[0] if c["title"] == "NoKey"
        ]
        self.assertTrue(self.go(planned=planned)[0][1].startswith("skipped"))
        self.assertTrue(os.path.exists(b[1]))

    def test_radarr_failure_prevents_file_deletion(self):
        a = self.add("One", rating=2)
        res = self.go(radarr=FakeRadarr(fail=True))
        self.assertTrue(res[0][1].startswith("failed"))
        self.assertTrue(os.path.exists(a[1]))
        self.assertEqual(
            self.conn.execute("SELECT state FROM movie").fetchone()[0], "present"
        )

    def test_path_outside_known_folders_is_refused(self):
        self.add("One", rating=2)
        planned = self.plan(free=0, total=10_000 * GB)[0]
        planned[0]["path"] = "/etc/passwd"
        res = self.go(planned=planned)
        self.assertTrue(res[0][1].startswith("failed"))

    def test_stops_when_real_free_space_reaches_target(self):
        self.add("A", rating=2, born_days=10)
        self.add("B", rating=2, born_days=10, rated_days=10)
        calls = iter([(0, TOTAL), (500 * GB, TOTAL), (500 * GB, TOTAL)])
        res = self.go(usage_fn=lambda: next(calls))
        self.assertEqual([s for _, s in res], ["retired"])

    def test_age_only_deletion_continues_after_free_space_target(self):
        movie_id, path = self.add("Old", born_days=800)
        self.cfg["lifecycle"]["age_only"] = ["stale_unmanaged"]
        planned = self.plan(free=800 * GB)[0]
        res = self.go(planned=planned, usage_fn=lambda: (800 * GB, TOTAL))
        self.assertEqual([status for _, status in res], ["retired"])
        self.assertFalse(os.path.exists(path))
        reason = self.conn.execute(
            "SELECT reason FROM deletion WHERE movie_id=?", (movie_id,)
        ).fetchone()[0]
        self.assertIn("age only: stale_unmanaged, 800 days old", reason)

    def test_loose_file_deletes_only_its_own_files(self):
        p = self.mkfile("Movies/loose.mkv")
        self.mkfile("Movies/loose.srt")
        other = self.mkfile("Movies/keep.mkv")
        mid = self.conn.execute(
            "INSERT INTO movie(title,rating,rated_at,first_seen_at,updated_at,plex_rating_key) "
            "VALUES ('Loose',2,?,?,?,'9')",
            (NOW, NOW, NOW),
        ).lastrowid
        self.conn.execute(
            "INSERT INTO file(movie_id,path,size,mtime,fingerprint,zone,first_seen_at,last_seen_at) "
            "VALUES (?,?,?,?,?,'unmanaged',?,?)",
            (mid, p, GB, 0, "f", NOW, NOW),
        )
        self.conn.execute(
            "INSERT OR REPLACE INTO meta VALUES ('last_sync_ok', ?)", (str(NOW),)
        )
        self.go()
        self.assertFalse(os.path.exists(p) or os.path.exists(p[:-3] + "srt"))
        self.assertTrue(os.path.exists(other))
