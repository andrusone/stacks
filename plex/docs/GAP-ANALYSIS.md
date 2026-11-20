# plexcurator fit/gap analysis (R1-R20)

**Status 2026-10-28: all of R1-R20 are implemented** (see DESIGN.md for the result and the implementation decisions). The table below is the analysis as written, i.e. the state of the code *before* the redesign; "Decisions" at the end are the owner's answers. Evidence is `file:function` in this repo (the copy in `network/stacks/media/plexcurator`
was identical when I looked at its layout; I did not diff it). Status: FIT / PARTIAL / GAP / CONFLICT (the code does the
opposite of, or cannot coexist with, the requirement).

Summary: the **collection** side (Plex sync, ffprobe capture, event timeline, backup, alert plumbing, threshold trigger,
deletion mechanics, retire-in-Radarr) largely fits. The **model** needs rework: external-ID identity, one-source-record-per-source,
the born/retired event model, policy as data, an unmanaged/curated folder model, watchlists, renaming, and a much simpler config.

## Fit/gap table

| Req | Status | Evidence (current code) | Change that closes it |
|---|---|---|---|
| **R1** array of unmanaged folders | GAP | `config.py` has one `library.root` + one `library.inbox`; `layout.own_folder` hard-codes `root`, `inbox`, `watched` as the "roots" | `folders.unmanaged = [..]`; classify any path by prefix (unmanaged / curated-watched / curated-unwatched / other) in one `layout.classify(path)` |
| **R2** one curated folder, watched + unwatched parts | GAP | `layout.target_dir` only knows `Watched/`; no unwatched curated area | `folders.curated` with fixed children `watched/` and `unwatched/`; unwatched part is used by R9 (layout of that part: see Q7) |
| **R3** watched = Plex-watched, >=50% configurable | CONFLICT | `layout.plan_moves` and `lifecycle._rows` use `play_count>0` (Plex viewCount, which Plex sets at 90%). `config.py` has `watched_percent = 90.0` but **nothing reads it** (dead key). `sync._percent` already computes viewOffset/duration | One `is_watched(movie)` = `percent_complete >= watched_pct` (default 50) **or** viewCount>0; single config key `watched_pct`. Supersedes the earlier "viewCount > 0" answer, see Q4 |
| **R4** watched/video/audio/rating(0-5 whole) | PARTIAL | `layout.target_dir` builds `Watched/<res>/<audio>/<Nstar\|unrated>`; hierarchy order matches. Names differ (`SD,720HD,1080HD,4k`, `unrated,1star..5star`); halves bucketed by `db.stars` (ceil) | Rename classes to `sd,720hd,1080hd,4khd` (from policy data, R11); rating folders `0..5` (0 = unrated/none/0); decide half-star mapping (Q5) |
| **R5** on watch MOVE (not copy), by video/audio/rating, metadata + date | PARTIAL | Move: `layout.apply_moves` (`shutil.move`, same-share rename = true move) but only runs when `organize --execute` / `automation.organize_execute`, default off; trigger is `play_count>0` (R3). Watch date: `sync` writes `watched` event (ts = lastViewedAt) and `watch` rows. `apply_moves` records `moved` with new path only (no from-path/class/rating detail); `sync` records the from-path only if the path changed between syncs | R3 predicate; `moved` event carries from/to + video/audio/rating at time of move; default the move step on once policy is trusted (R19 mode switch); collect metadata at move time (R6) |
| **R6** on rating, move from unmanaged OR managed; recollect metadata; single movie definition, dated move/rating records, single version of probe data | PARTIAL | Re-move on rating change works for watched movies (`plan_moves` recomputes target each run). **Rated-but-unwatched** movies are never planned (`play_count>0` filter). Rating events: `sync` emits `rated` only when value differs from DB; a cleared rating is deliberately kept, not recorded. Probe only when a new fingerprint appears (`sync`, `need_probe`), never "recollected" on move. One `movie` row + many `event` rows is already the shape wanted. `file` keeps one row per physical file ever seen, so a re-encode yields two probe versions | Include rated movies (any folder) in the move plan; re-probe/refresh on move; keep exactly one current probe per source (see R13 `source` table); record `cleared` as a rating event with 0 |
| **R7** movie ID primary key, nothing ephemeral | PARTIAL | `db.movie.id` is an internal autoincrement; `tmdb_id` is `UNIQUE` but **nullable**; unmatched movies fall back to fingerprint identity (`sync._resolve`). Ephemeral ids (ratingKey, radarr_id) are plain columns, good | Make the authoritative external id the key (or a NOT NULL unique column every FK uses); movies without one go to a quarantine list and are never moved/deleted (see R14, Q1-Q2) |
| **R8** rename curated content with tags: title, movie ID, year, video, audio, HDR | GAP | No rename anywhere. `layout.folder_name` only names loose files; folders keep their Radarr names | `layout.curated_name(movie, file)` → e.g. `Title (Year) {imdb-tt0000000} [1080hd 5ch HDR]/Title (Year) {imdb-…} [1080hd 5ch HDR].mkv`; Plex understands `{imdb-…}`/`{tmdb-…}` in names. Radarr must be told (`set_path` exists; file rename needs a rescan/rename call); see Q8 |
| **R9** any Plex watchlist → move unmanaged → managed, collect, rename | GAP | No watchlist code. `clients.Plex` has no watchlist call | New `Plex.watchlist()` (plex.tv discover API, account token), `watchlisted` event (first/last date), plan move to `curated/unwatched/`, metadata + rename like R5. Plex watchlist is per account and cloud-side, see Q6 |
| **R10** configurable storage threshold % | FIT | `config.py` `lifecycle.trigger_free_pct=35`, `target_free_pct=40`; `lifecycle.plan` | Rename to two top-level keys (`min_free_pct`, `reclaim_to_pct`) for R19 |
| **R11** classes and criteria are data, not code | GAP | `probe.res_class`, `probe.audio_class` hard-code thresholds; `layout.RES/AUDIO/STARS` hard-code folder names; `db` views/queries embed names | `policy.toml` (or a table in the main config): ordered list `video = [{name="4khd", min_width=3000, min_height=2000}, …]`, `audio = [{name="7ch", min_channels=7}, …]`, loaded once; `file.res_class/audio_class` derived from stored raw columns by a `reclassify` step so adding `8k` is a data edit + one re-run (no re-probe) |
| **R12** daily batch finds new content wherever it sits (managed or unmanaged) and collects data | PARTIAL | Daily timer exists (`deploy/plexcurator.timer`, 04:15). Discovery is **Plex-driven only** (`sync.sync` iterates `plex.movies`); a file not in a Plex library is invisible. Files in an unmanaged folder that is not a Plex folder are never seen | Add a filesystem walk of `unmanaged[] + curated`; reconcile with Plex/Radarr (Radarr's movie list gives tmdb id + path for files Plex has not scanned). Files with no resolvable id are reported, not touched |
| **R13a** one record per movie | FIT | `db.movie` | none (key change under R7) |
| **R13b** one source record per metadata source (ffprobe, mediainfo, plex, future) | GAP | Sources are columns: `file.probe_json`, `file.mediainfo_json`, `movie.plex_raw`; the derived columns are on `file` | `source(movie_id, source, fetched_at, json)` with a unique `(movie_id, source)`; derived/queryable columns and the `v_stream/v_format` views read from it (ffprobe is per file; the movie's current file is its one version) |
| **R13c** dated events born, watchlisted, watched (with %), rated, retired | PARTIAL | `event.kind` today: `added, removed, reappeared, watched, progress, rated, moved, selected, deleted` (`sync._event`, `lifecycle.execute`). `watched` stores the play count, not a %; `progress` fires on every >=1-point change; no `watchlisted`; `added`≈born, `deleted`≈retired but there is no uniqueness | Kinds: `born, watchlisted, watched, rated, moved, retired` (+ internal `selected`). `watched.value` = percent. Partial unique indexes `ON event(movie_id) WHERE kind='born'` / `'retired'` |
| **R13d** only one born and one retired per movie | CONFLICT | `sync` emits `removed`/`reappeared` for a movie leaving/re-entering Plex (state flips back and forth); nothing prevents two `added` | `state` derived from born/retired only; "left Plex without us retiring it" is a reported anomaly, not an event (Q9) |
| **R13e** database searchable | FIT | `v_movie`, `v_stream`, `v_format`, `queries.sql`, `cli.run_query` | Update views/queries for renamed columns |
| **R14** every movie ID ties to an authoritative external source | PARTIAL | `movie.tmdb_id`, `imdb_id` columns; filled from Plex Guid (`sync._tmdb`), only when Plex matched it | NOT NULL external id; quarantine unmatched; optional verification via Radarr lookup (`/movie/lookup`) |
| **R15** no deletion unless free space < threshold | FIT | `lifecycle.plan` returns `[]` when free% >= trigger; `cli.do_reclaim` returns before `execute`; `test_no_action_when_enough_free`, `test_defaults_are_35_40` | none |
| **R16.1** one-star, ordered by rating date oldest first | PARTIAL | `lifecycle.candidates` rule `a_one_star`, but sorted **largest first** (`-total_size`); `movie.rated_at` is set at the time the sync *noticed* the change, not Plex's rating date | Sort by rating date; prefer Plex `lastRatedAt` if the API returns it, else the first `rated` event date (Q10) |
| **R16.2** two-star, same | PARTIAL | `b_two_star`, same issues | same |
| **R16.3** watchlisted, FIRST watchlist date > 12 months, oldest first | GAP | no watchlist data | `watchlisted` events (R9); rule reads `MIN(ts)`; 12 months from policy data |
| **R16.4** unmanaged, born > 12 months, regardless of folder, oldest born first | CONFLICT | `d_stale_unwatched`: unrated + never watched + no history + `added_at` older than **730 days**, sorted **largest first**; there is no unmanaged/managed notion | Predicate = location is unmanaged ∧ born > 12 months ∧ protected-set excluded (below); order by born date. "Regardless of folder" reads as any of the `unmanaged[]` folders (Q11) |
| **R16.5** exhausted + short → alert with total (GB/TB), free, threshold %, space needed, "all rules exhausted, manual aggressive intervention required" | PARTIAL | `lifecycle.shortfall` + `cli.set_alert` (ERROR log, `alert_file`, exit code 2) work and are tested (`test_alert_when_nothing_eligible`), but the text has only free%, trigger%, projected%, target% | Rewrite the message with the required fields; keep log/file/exit-code delivery |
| **R16 order, "next rule only if more space is needed"** | FIT | `lifecycle.plan` walks `candidates` in rule order and stops at target; `test_order_and_protection`, `test_stops_at_target` | none |
| **R16 criteria as data** | GAP | rules are hard-coded in `lifecycle.candidates` | Rules table in policy data: `{name, match, order_by, min_age_months}` with a fixed vocabulary of matchers (`rating==1`, `watchlisted`, `unmanaged`) |
| **R16 3-5 star watched never in any rule** | FIT | `lifecycle.candidates` skips `stars >= protect_min_stars` first; tests `ThreeStar`, `FiveUnwatched` | Keep as code-level invariant, not a config key (it is one today: `protect_min_stars`) |
| **R17** retire = remove from Plex, delete from disk, Radarr delete + import exclusion, keep metadata/events | FIT (small gaps) | `lifecycle.execute`: Radarr `delete_with_exclusion` (+ `add_exclusion` fallback), file/folder delete, Plex `scan` + `empty_trash` (removal via trash, not `DELETE /library/metadata`), movie `state='deleted'`, rows/events/probe kept. mdblist removal also runs (`clients.MdbList`), which R17 does not list | Emit one `retired` event (R13); decide whether mdblist stays (Q12) |
| **R18** host marker under /etc/andrusone, written by setup.sh | GAP | `setup.sh` writes `/etc/plexcurator/config.toml` and units only | setup.sh writes `/etc/andrusone/stacks/<name>` (format/name: Q13); `--check` verifies it exists |
| **R19** update READMEs, explain config; SIMPLE config, COMPLEX processing | CONFLICT | `config.example.toml` has ~35 keys incl. micro-settings: `backup_keep`, `alert_file`, `max_deletions_per_run`, `max_sync_age_hours`, `protect_min_stars`, `unwatched_min_age_days`, `watched_percent`, `probe.ffprobe/mediainfo`, `plex.sections/path_map/log_dir`, `mdblist.remove_url`, `layout.rating_folders`, two `automation.*` gates plus `lifecycle.enabled` (three overlapping safety switches) | Main config only holds what the owner must decide: connections (Plex, Radarr), `folders.unmanaged[]`, `folders.curated`, `backup_dir`, `min_free_pct`/`reclaim_to_pct`, `watched_pct`, one `mode` (`observe` → `organize` → `reclaim`). Everything else defaults in code or in `policy.toml` (classes, rules, name template). README gets a "config in one page" section |
| **R20** curated stack of folders detected and created by code | PARTIAL | `layout.layout_dirs` + `cli init-layout --create` + `setup.sh --create-layout` create all dirs, but only when asked, and from hard-coded tuples; `apply_moves` also `makedirs` for what it uses | Derive the tree from policy data (R11), create/verify it in every `run` (idempotent, never deletes); `setup.sh` no longer needs a flag |

## Design conflicts with the current code

1. **Folder model.** Current: `Movies` inbox + `Watched/…`. Required: `unmanaged[]` + curated (`watched`, `unwatched`). Touches `config`, `layout`, `validate`, `setup.sh`, tests.
2. **Rating folders.** Current: on by default, named `unrated,1star..5star`, half stars rounded up. Required: always on, `0..5` whole stars, unrated = none or 0. (The earlier "default off" is already reversed in code; naming and half-star rule are what change.)
3. **Identity.** Current: internal integer key, nullable TMDB, fingerprint fallback. Required: authoritative external ID is the key and is never null. The fingerprint becomes a cache/sanity check for "same file", not an identity.
4. **Event model.** Current: nine kinds, `removed/reappeared` flip-flop, `progress` noise, `watched` = count. Required: one born, one retired, many watchlisted/watched(%)/rated, plus moves.
5. **Deletion.** Current: size-ordered, 730-day unrated-unwatched rule, no watchlist. Required: date-ordered (rating date / watchlist date / born date), 12-month thresholds, new watchlist rule, richer alert. Mechanics (gates, live-Plex veto, preflight, Radarr-before-files order, audit) stay.
6. **Thresholds.** 35/40 is already in code and docs; the old 60/55 text is gone. No conflict, only renaming.
7. **Single user vs household.** Current: single Plex account (shared login confirmed by the owner). "Any watchlist" still works with one account's watchlist; it only conflicts if the household has separate Plex accounts (Q6).
8. **Watched definition.** viewCount>0 (owner's earlier answer) vs `>=50%` now. The code has the percent but no use of it.
9. **Metadata shape.** Columns on `file` and `movie` vs one `source` record per source.
10. **Config surface.** ~35 keys and three overlapping safety switches vs "simple".
11. **Discovery.** Plex-driven vs "wherever it sits".
12. **Scope creep.** mdblist code, config keys and validator rules exist; the new requirements do not mention mdblist at all.
13. **Stack conventions** (observed in `network/stacks/README.md`, not yet applied): scripts carry `SCRIPT_VERSION`, stacks list a "Drift detection" column, check scripts append to `/var/lib/drift-log/drift.jsonl`, and the stack must not depend on its own location. `setup.sh` does none of this. R18 says the marker is the only drift scope, so appending to the drift log would be extra (Q14).

## Proposed ordering

Each step ships with fixture tests; nothing destructive is enabled until step 6's tests pass, and `mode` stays `observe` until the owner flips it.

0. **Decisions** (below) and read `network/stacks/media` + `downloads` conventions (is the arr/Plex side Docker? paths, users).
1. **Schema v2**: external-ID key, `source` table, event kinds with born/retired uniqueness, views/queries. No deployed DB, so no migration.
2. **Policy as data + simple config**: `policy.toml` (video/audio classes, rating folders, deletion rules, name template), collapsed main config, one `mode`, validator rewritten for it.
3. **Watch/rating semantics**: `is_watched` (R3), watched % events, rating-cleared events, rating date.
4. **Classify + organize**: unmanaged/curated model, move on watch **and** rating from any folder, create folder tree (R20), re-collect metadata on move.
5. **Rename (R8)** with Radarr/Plex handling (riskiest side effect; separate step so it can be reviewed alone).
6. **Lifecycle rework**: date-ordered rules from policy data, watchlist rule stubbed until step 7, new alert text.
7. **Watchlist ingestion** (R9) + watchlist rule live.
8. **Discovery walk** (R12).
9. **setup.sh**: host marker (R18), layout creation without a flag, stack conventions; **README + config explanation** (R19).

## Decisions (owner, 2026-10-28; supersede the questions that were here)

Nothing below is implemented yet. The owner reviews `config.example.toml` first.

| Topic | Decision | Closes |
|---|---|---|
| Watched | plexcurator owns the percentage: peak of viewOffset/duration (and whatever else Plex exposes), stored as dated `watched` events with value = percent. Plex's integer viewCount is a fallback only when no percent is known (counts as 100). `watched_pct` default 50. Once moved out of unmanaged it never moves back | R3, R5, R13c |
| Identity | internal `movie.id` is the primary key; `external_id(movie_id, provider, value)` holds tmdb, imdb, ... (unique per provider+value). TMDB is the key provider, taken from Plex guids / Radarr. No paid APIs; direct TMDB only with a free key and only if needed. No id = `unidentified`: never moved, renamed or deleted, and an alert asks for human action | R7, R14 |
| Events | `born, watchlisted, watched(%), rated, moved, retired` (+ internal `selected`). `removed/reappeared` dropped: a movie missing from Plex/disk without curator action is an anomaly line in the run log. A retired movie found again gets a `reborn` event and a new life on the same id; no further effort | R13c, R13d |
| Folders | unmanaged folders: anywhere, each a Plex movie library folder, collect data only, except moving watched/rated/watchlisted movies out. One managed root owned by the curator (also a Plex library folder): `Watchlist/` (flat) and `Watched/<video>/<audio>/<0-5>/`. Ratings are whole stars 0..5, half stars round **down**, none = 0 | R1, R2, R4, R20 |
| Classes | config tables, matched on `min_width` (optional `min_height`) for video and `min_channels` for audio; adding 8k = config edit + `reclassify` (no re-probe) | R11 |
| Lifecycle | per unmanaged folder `lifecycle = true/false`, one `stale_months = 12`, four rules in fixed order (`one_star, two_star, stale_watchlist, stale_unmanaged`), each can be removed by name; dates (rating date, first watchlist date, born date) order everything, not size. Code invariants: 3-5 stars never deletable; age rules skip anything watched or rated; watchlisted 3-5 star excluded; `unidentified` never touched | R16, R15 |
| Storage | relational: `movie`, `external_id`, `source_record(movie_id, source, fetched_at, raw_json)` (one per source: ffprobe, mediainfo, plex, future), normalized `file, format, video_stream, audio_stream, subtitle_stream` derived from the raw JSON, `event`. One current version per source per movie. Aggregate views kept | R13b |
| mdblist | dropped entirely (code, config, validator) | Q12 |
| Discovery | filesystem walk of unmanaged + managed folders as a safety net beside the Plex-driven sync; identify by Plex guid, Radarr's tmdbId for the path, or a `{tmdb-123}` tag in the curated name; else `unidentified` + alert | R12 |
| Rename | yes: template with title, year, id tag, video class, audio class, HDR (default `Title (Year) {tmdb-123} [1080hd 5ch HDR]`, in code). Radarr handling: see below | R8 |
| Alerts | log + alert file + exit code 2 | R16.5 |
| Host marker / script | `/etc/andrusone/stacks/plex` (stack "plex", separate from downloads so the server could become Jellyfin). `setup.sh` becomes `build-plex-node.sh` following `stacks/core/build-core-node.sh` (`SCRIPT_VERSION`, `--check` = dry run that changes nothing, `--print-plan`, `--only/--skip` phases, idempotent check-then-change steps via one `do_change`, env/config file created from an example and the script stops, drift record to `/var/lib/drift-log/drift.jsonl` through the optional `os/common/drift/drift-log.sh`). Folder tree is created in every run | R18, R20 |

### Recommendations I was asked to make

**Radarr after curation.** Keep tracking, unmonitor, tell Radarr the new path, rescan; do not delete the entry.
Reason: if the entry is removed without an exclusion, any list (Kometa/mdblist in other stacks) re-adds the movie and
Radarr downloads it again; if it stays monitored, a quality upgrade can fetch a second copy into the old path or
fight the rename. So on every move/rename: `PUT /movie/{id}` with the new `path` and `monitored=false`, then command
`RescanMovie` so Radarr finds the renamed file; Radarr's own "rename movies" setting should stay off. Retiring is
unchanged: delete the entry with `addImportExclusion=true` (and the file via us). Field/command names are from memory of
Radarr v3 and are unverified until tested against the real instance.

**How often to poll for watch percent.** Plex keeps a resume offset only for unfinished plays and clears it at about 90%
(then increments viewCount). Consequences for a once-a-day poll: a movie stopped at 60% still shows 60% the next morning, so the
50% threshold is caught; a finished movie shows viewCount up and no offset, which we record as 100. What a daily poll can miss:
a play that crossed 50% but was then restarted and stopped lower before the next poll (offset overwritten), a manual
"mark unplayed", and exact times (events are accurate to the day). Recommendation: **daily is enough to start**; add a
small `/status/sessions` poller every 5-10 minutes only if you see misses or want exact watch times. It would only append
`watched` events when the peak rises, so it can be added later without changing the model. (Tautulli records per-play percent
if you ever want a second source.)

**`reborn` vs one-born-one-retired.** `born` and `retired` stay unique per movie (partial unique indexes) for the first life.
A retired movie found again sets state back to present and adds one `reborn` event; if it is retired again the second
retirement is a `retired` event with the `reborn` count in `detail`. The uniqueness rule therefore holds for ordinary
movies and is only relaxed by the explicit `reborn` event.

## Remaining open questions

1. **Which volume's free space counts?** Unmanaged folders "can be anywhere". If they are on different filesystems, one `min_free_pct` is ambiguous. I added an optional `measure_path` (default: the managed root) for this; confirm that one volume (e.g. the NAS share) is the case.
2. **Radarr/Plex path mapping.** If Radarr or Plex run in containers they see different paths from this host. I added two optional commented `path_map` keys for that; delete them if everything shares `/nas/plex`.
3. **Several versions of one movie in Plex** (a 1080p and a 4K copy): the model assumes one current file per movie. Proposed: treat as an anomaly line in the run log and curate nothing for that movie until you resolve it.
4. **Single switch and dry-run.** `mode` replaces `lifecycle.enabled` + `automation.*` + `--execute`. That removes the second "arming" step: setting `mode = "reclaim"` is itself the arming. I kept a CLI `--dry-run` for any mode. Is that enough, given reclaim is the destructive one?
5. **Is the id tag `{tmdb-…}`** (follows the TMDB-key decision) or `{imdb-…}` in names? Plex reads both.
6. **Radarr recommendation above:** approve (keep tracking, unmonitored, path updated, rescan)?
7. **Polling:** daily only, or add the 5-10 minute session poller now?
