# plexcurator design

Three goals: (1) behavioural movie lifecycle management, (2) permanent taste data, (3) permanent quality data for future
curation. Stdlib-only Python 3.11+ (sqlite3, urllib, tomllib) plus `ffprobe` and `mediainfo`; runs on the Plex server as
the `plex` user. The requirement-by-requirement history is in [GAP-ANALYSIS.md](GAP-ANALYSIS.md) (R1-R20 and the owner's decisions).

## Safety model (read first)

* **One switch:** `mode = "observe" | "organize" | "reclaim"` in the config. `observe` (the default) only collects data and
  creates empty folders. `organize` also moves/renames. Only `reclaim` can delete. `plexcurator --dry-run <cmd>` previews any mode.
* **Code invariants, not configurable:** movies rated 3-5 stars are never candidates; `unidentified` (no TMDB/IMDb id),
  multi-version and file-less movies are never moved, renamed or deleted; files outside the configured folders are never touched;
  unmanaged folders are only deleted from when `lifecycle = true`; nothing is ever moved *into* an unmanaged folder.
* **Library scope:** by default, sync reads movie libraries whose mapped locations overlap a configured folder; `plex.libraries = "all"`
  or a list of exact titles overrides that selection. A selected library is read in full, but only configured folders may be changed.
  Plex scans after moves/deletes are limited to the same selected libraries.
* **Before deleting:** the last successful sync must be younger than 26 h and every configured folder must exist; Plex is asked
  live about each movie (a rating or watch since the sync vetoes it); Radarr is banned *before* the files are deleted (a Radarr
  failure stops that movie); real free space is re-measured after each deletion and the run stops at the target; at most 25 per run.
* Tests (`python3 -m unittest discover -s tests -t .`) cover all of this against temp trees and fake clients. Nothing here has run
  against a real Plex, Radarr or NAS.

## Identity

`movie.id` (internal) is the key of everything. `external_id(movie_id, provider, value)` ties it to an authoritative source
(tmdb, imdb; unique per provider+value). Ids come from, in order: Plex guids; a `{tmdb-123}` / `{imdb-tt…}` tag in the file or
folder name; Radarr's tmdbId for the file's path. No paid APIs. A movie with none is **`unidentified`**: tracked and
fingerprinted, never moved/renamed/deleted, and `alerts.collect` raises an alert until a human fixes the match. The
`alert_unidentified` setting controls whether it warns or fails the nightly unit.
The file fingerprint (sha256 of size + head/middle/tail 1 MiB) only answers "same file?", e.g. an unidentified file that Plex
later matches attaches to the same movie. Ephemeral values (Plex ratingKey, Radarr id, paths) are plain columns overwritten each sync.
A retired movie that turns up again gets a `reborn` event and a new `life` on the same id.

## Schema (db.py)

| table | purpose |
|---|---|
| `movie` | the one definition: title/year, `state` (present/retired), `unidentified`, `multi_version`, `life`, born/retired/first-watchlisted dates, `rating` (Plex 0-10), `rated_at`, `peak_percent`, `watched` (latched), `first_watched_at`, ephemeral Plex/Radarr ids |
| `external_id` | tmdb/imdb ids |
| `source_record` | **one current raw record per movie+source** (`plex`, `ffprobe`, `mediainfo`, future ones): `raw_json` + `fetched_at` |
| `file`, `format`, `video_stream`, `audio_stream`, `subtitle_stream` | the movie's single current file and normalized rows transformed from the ffprobe JSON; `file` also holds `zone`, `video_class`, `audio_class` and the HDR columns (below) |
| `event` | append-only: `born, watchlisted, watched(value=%), rated(value=0-5), moved, retired, reborn`, internal `selected` |
| `watchlist` | Plex watchlist membership by id (the movie may not be on the NAS yet) |
| `issue` | WARN/ERROR lines from the Plex logs, attributed to a movie by file name or `/library/metadata/<key>` |
| `deletion` | reclaim audit: rule, human reason, size, per-step flags, status |
| views | `v_movie` (movie + file + stars + ids), `v_video`, `v_audio`; examples in `plexcurator/queries.sql` (`plexcurator query list`) |

Any ffprobe/mediainfo/Plex field is aggregatable: normalized columns, or `json_extract(raw_json, '$.path')` over `source_record`.
**Events:** one `born` per movie and one `retired` per life are enforced by partial unique indexes; `watchlisted`, `watched`, `rated`, `moved` repeat.
A movie that disappears from Plex or disk without curator action is a WARN line in the run log (and `file.present = 0` when the
disk walk sees the file gone), not an event.

## Watch percentage (the curator owns it)

Percent = peak of Plex `viewOffset / duration`; a `watched` event (value = percent) is written whenever the peak rises by 1 point,
and a new completed play (viewCount increased, or an already-watched library on first sync) is a `watched` event with 100.
`watched` latches when the peak reaches `watched_pct` (default 50) and never reverts. **Limit:** Plex keeps a resume offset only for
unfinished plays and clears it at about 90% (then increments viewCount). A daily poll therefore catches "stopped at 60%" and
finished plays, but can miss a play that crossed 50% and was restarted and stopped lower before the next poll, a manual
"mark unplayed", and exact times (day resolution). Recommendation, not built: a daily poll is enough to start; add a 5-10 minute
`/status/sessions` poller only if misses show up.

## Folders

```
<unmanaged>/…                      any number, each a Plex movie folder; data collected; only moved OUT of
<managed>/Watchlist/<stem>/<stem>.<ext>                        flat
<managed>/Watched/<video>/<audio>/<0-5>/<stem>/<stem>.<ext>    why it is kept is the path
stem = Title (Year) {tmdb-123} [1080hd 5ch HDR10]     last word = HDR tag, absent for SDR
```
`<managed>` must also be a Plex movie folder (the validator warns if not). The tree for every configured class and 0..5 is created on
every run (and never deleted), so adding a class creates its folders. Stars are whole stars, half stars round **down**, none = 0.

* A movie goes to `Watched/…` when it is watched (`watched_pct`) **or** rated 1+ stars; it goes to `Watchlist/` when it is on a Plex
  watchlist and still in an unmanaged folder. Once in `Watched` it never leaves (rating changes and class changes re-file it inside).
* A move relocates the movie's own folder (when it holds exactly one video file) and renames files sharing the old file's stem; a loose
  file gets a new folder with its same-stem siblings. It is a rename on one filesystem and copy+delete across filesystems. A collision
  fails safely. Afterwards: DB path/zone, a `moved` event (from, reason, classes, stars), ffprobe/mediainfo re-collected, Radarr told,
  Plex scanned. Plex recreates the item; the next sync restores the rating and watched state into Plex from the DB.
* **Radarr after curation:** keep tracking, **unmonitor**, set the new path, `RescanMovie`. Not deleting the entry stops lists
  re-adding it; unmonitoring stops upgrades fetching a second copy. Retiring deletes the entry with an import exclusion.
  Radarr's own "rename movies" setting should stay off. The update-by-id `PUT` and `RescanMovie` command remain
  **UNVERIFIED**; card #248 must settle which call works on Radarr 6.4. `plexcurator --selftest validate` probes the
  existing update-by-id call with an unchanged movie DTO but does not verify the live instance.
* Classes are config tables: video by `min_width` (+ optional `min_height`), audio by `min_channels`; the widest match wins; the
  lowest must be 0. `plexcurator reclassify` re-derives classes from stored width/height/channels without re-probing.

## Lifecycle (lifecycle.py)

Starts when free space (of `storage.measure_path`, default the managed folder) is below `min_free_pct` (35) and continues to
`reclaim_to_pct` (40). Rules in config order, each only while more space is needed, **oldest date first**:
`one_star` (by rating date), `two_star`, `stale_watchlist` (first watchlist date older than `watchlist_stale_days`, unwatched and unrated),
`stale_unmanaged` (unmanaged folder with `lifecycle = true`, born older than that folder's `stale_days` or the global `stale_days` default, unwatched, unrated, not watchlisted).
The stale rules can be opted into age-only reclaim per rule with `[lifecycle] age_only = ["stale_unmanaged"]` or per unmanaged
folder with `age_only = true`; a folder setting overrides the rule setting. Age-only candidates run even when free space is high
and are planned before space-driven candidates. The default is off. Before the first deletion for a changed age-only policy, a real
run raises an alert listing the candidates and stops; `plexcurator reclaim --confirm-age-only` confirms that exact list and enables
the policy for later runs. Age-only audit reasons, events, and journal lines include the rule and age. The limit is 10 deletions per
run; if more eligible candidates remain, an alert reports them for a later run.
The global default is 365 days; `watchlist_stale_days` defaults to it. `stale_months` remains a deprecated alias at 30.44 days per month,
but cannot be set with `stale_days`. The reclaim preview reports the effective day threshold and whether it came from the folder,
the rule, or the default.
Retiring = remove from Radarr with an import exclusion (or ban the tmdb id if Radarr no longer has it), delete the folder/files,
Plex scan + empty trash, `retired` event, state `retired`; metadata and events stay forever.
`reclaim --preview` lists all eligible candidates regardless of current free space, grouped by source folder and rule, with size,
oldest age, and the age-policy source. It is read-only; the default output is capped and `--dry-run reclaim --all` shows the full
list. The final line says whether a normal run would enter reclaim now based on free space and the current absence of age-only rules.
If every enabled rule is exhausted and space is still short, the alert states total storage, free, threshold, space needed, what the
rules could free, that all rules are exhausted, and that manual aggressive intervention is required.

## Alerts

Alerts are written to `/var/lib/plexcurator/ALERT` while something needs a human. Reclaim shortfalls are errors and exit 2.
Unidentified movies follow `alert_unidentified`: `warn` (the default) logs a warning, writes a `[WARN]` alert, and exits 0;
`fail` logs an error, writes an `[ERROR]` alert, and exits 2. Warning entries are tagged
`[WARN:unidentified]` so health checks do not downgrade unrelated alert types. No Gatus/Homepage hook.

## Data sources

Plex API (library, ratings with `lastRatedAt`, offsets, watchlist via plex.tv discover), Plex logs, ffprobe, mediainfo, Radarr API v3
(tmdbId by path, path updates, exclusions), and a filesystem walk of unmanaged + managed folders as a safety net (`discover`): it
finds files Plex has not listed, identifies them as above, collects their data, flags identical copies and files gone from disk.

## Install (build-plex-node.sh)

Follows `stacks/core/build-core-node.sh`: root, `SCRIPT_VERSION`, `--check` (dry run), `--only/--skip` phases, `--print-plan`,
check-then-change steps through `do_change`, a fresh host creates the config from `config.example.toml` and stops (exit 2),
`verify` PASS/FAIL checks recorded with `drift_record` in `/var/lib/drift-log/drift.jsonl`. Phases: prereqs (config validates
including Plex/Radarr reachability and service user can read the config; a real run verifies folder write access with a brief
hidden probe, while `--check` reports it as unverified without writing), packages (`ffmpeg mediainfo python3`), install (to
`/opt/plexcurator`, tree-hash gated, plus `/usr/local/bin/plexcurator` for the configured service user), state (DB dir + `init-db`), units (nightly run 04:15; DB backup 04:00, staged locally before the NAS copy), layout (managed tree,
every run), marker, verify. It never deletes or moves media.
**Host marker:** `/etc/andrusone/stacks/plex` (key=value: STACK, COMPONENT, SCRIPT, SCRIPT_VERSION, INSTALLED_AT, INSTALL_DIR,
CONFIG, SERVICE_USER, UNITS), stable across runs so a converged host reports 0 changes. It is the only drift-related scope.

## HDR types (hdr.py)

`hdr.detect(ffprobe_stream, mediainfo)` returns separate facts: `dv`, `hdr10plus`, `hdr10`, `hlg`, `dv_profile`, `dv_fallback`. Rules:
PQ transfer (`smpte2084`) = HDR10, `arib-std-b67` = HLG; a `DOVI` side-data record = Dolby Vision, where `dv_bl_signal_compatibility_id`
1 or 6 means an HDR10 base layer, 4 HLG, 2 SDR, 0 (profile 5) none, and that base layer decides `hdr10`/`hlg` (so profile 5 is not HDR10 even
if a tool reports PQ); SMPTE 2094-40 side data or mediainfo's HDR10+ fields = HDR10+ (which implies HDR10). Either source can add a format.
`hdr.canonical()` collapses the flags by fixed priority DV > HDR10+ > HDR10 > HLG, else `sdr`, and that key is stored in `file.hdr` and
`video_stream.hdr`. The key is independent of config; **labels and filename tags are data** (`[hdr.<type>]`, defaults in
`config.DEFAULTS`), applied only when a name is built (`hdr.tag`) or parsed (`naming.parse_tech`, the inverse, so tags must be unique).
Because the name is a pure function of stored state, a probe that keeps returning the same type never flip-flops a rename; a different
type or a changed tag yields exactly one rename in place on the next `organize` run. Caveat: if `mediainfo` is unavailable on one run and
present on another, HDR10+ can toggle with HDR10 on a re-probe (re-probes only happen when size or mtime change, or after a move); keep it installed.
Schema step 2 adds the columns, maps the old labels (`DV`, `HDR10`, `HLG`) to the new keys and recomputes everything from the stored
`source_record` JSON, one transaction, no re-probe; a file without stored JSON keeps only the mapped old value.

## Versioning

`version.APP_VERSION` and `version.SCHEMA_VERSION` are explicit constants. The schema above is migration step 1 in `db.MIGRATIONS` (step 2 = HDR types, a function with a backfill; steps are SQL or a function(conn)); the database carries
`PRAGMA user_version` plus `schema_migration`. Older database: backup (existing routine) then ordered steps; equal: proceed; newer: refuse, never guess;
an unversioned database that already has tables is refused too. `tests/test_versioning.py` builds from scratch and via migrations and compares schemas; `tests/test_hdr.py` covers the v1 -> v2 backfill.

## Backup

`plexcurator backup` (own timer) uses SQLite's online backup API into `storage.backup_dir` (a NAS path), runs
`PRAGMA integrity_check` on the `plexcurator` database, and keeps the newest 14. The separately copied Plex
library snapshot may use Plex-only FTS tokenizers, so it is checked by staged size, SHA-256, SQLite page metadata,
and a read-only query against an ordinary table instead of `integrity_check`. File names carry the schema version:
`plexcurator-<time>-schema<N>.db`.

## Decisions made while implementing (all reversible; please review)

1. A movie qualifies for `Watched/` when watched **or** rated 1+ stars (R6: rating moves it from any folder).
2. "Rated" for the age rules means any Plex rating above 0, including a half star; any watch progress also counts as touched.
3. `stale_unmanaged` skips watchlisted movies; `stale_watchlist` also skips watched and rated ones.
4. A month is 30.44 days.
5. A rating cleared in Plex is recorded as `rated 0`; if the Plex item was recreated (new ratingKey) the rating is restored instead.
6. `born` for discovered-by-walk files uses the file's mtime (capped at now); for Plex movies, Plex `addedAt`.
7. Movies with several files in Plex (`multi_version`) are anomalies: collected, never curated or deleted.
8. `reclaim` evaluates the plan and raises the "rules exhausted" alert in every mode (it is advice, not an action).
9. The folder tree is created on every run, also in `observe`.
10. `run` no longer backs up; the backup timer does.
11. Config at `/etc/plexcurator/config.toml`; marker at `/etc/andrusone/stacks/plex`.

## Not verified on a real host

Plex watchlist endpoint and its guid format; Plex `lastRatedAt`; Radarr `RescanMovie`, `POST /exclusions` field names and
`DELETE …addImportExclusion`; Plex log line format; ffprobe/mediainfo output on real files; apt, systemd, `runuser` and drift-log
steps of `build-plex-node.sh` (only its config-bootstrap, install, state, layout and marker phases ran, in a temp tree).
