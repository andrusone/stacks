# plexcurator (the `plex` stack)

Curates a Plex movie library and collects data for two later uses: predicting taste, and deciding what to keep. It watches what
you watch and rate, files watched/rated/watchlisted movies into one managed folder (by video class, audio class and stars) with
tags in the file name, records everything permanently in SQLite, and, only if you switch it on, frees space when the NAS fills.
Design and decisions: [docs/DESIGN.md](docs/DESIGN.md). History of the requirements: [docs/GAP-ANALYSIS.md](docs/GAP-ANALYSIS.md).
Operator steps: [install and rollout runbook](docs/INSTALL-ROLLOUT.md).

## Install (Ubuntu 24.04+ / Python 3.12+, run on the Plex server)

```
sudo ./build-plex-node.sh            # first run: writes /etc/plexcurator/config.toml and stops (exit 2)
sudoedit /etc/plexcurator/config.toml
sudo ./build-plex-node.sh --check # dry run: validates config and prints what would change; skips write probes
sudo ./build-plex-node.sh            # installs deps, package, Kometa, DB, timers (Kometa 06:00, run 04:15, backup 04:00), folder tree, marker
sudo ./build-plex-node.sh --selftest # first post-install check: temporary write, backup, and nightly dry-run probes
sudo ./check-plex.sh --check         # read-only host and database health check
sudo plexcurator validate             # installed wrapper runs the CLI as the service user
```

The `kometa` phase installs the source archive and requirements file pinned in
`pins.env`, placing the application in `/opt/kometa/app` and its virtual
environment in `/opt/kometa/venv` owned by `kometa:kometa`. It creates `/etc/kometa/config.yml` from
`config.kometa.example.yml` only when the file is absent; existing config
contents are never overwritten. Replace the placeholder before the builder
enables the daily timer. The config remains `root:kometa` mode `0640` and the
service runs with `--read-only-config`. Upstream does not provide hashes for
every Python dependency, so the builder verifies the bundled requirements file
and installs its exact release-supplied contents rather than maintaining a
divergent lock file.

The backup service reads `/etc/kometa/config.yml` and
`/etc/kometa/collections/` using only its own `kometa` supplementary group. The
read-only health check verifies the Kometa user, timer, recent service result,
and config ownership/permissions only when the Plex stack marker declares
`kometa`; it never reads or prints the Kometa config contents.

The `plex` account must be able to write to the managed folder and `backup_dir`. `backup_dir` must resolve to a mounted SMB share for the final archive copy; the backup fails rather than writing to an unmounted local mount point. On the NAS mounts that means being in the `nas` group: `sudo bash stacks/os/ubuntu/mount-nas.sh --add-user plex`, then restart `plexmediaserver`. `--check` reports write access as unverified without probing; the next real build run performs a brief hidden write probe.

`build-plex-node.sh --selftest` does not run converge phases. It probes configured write paths with temporary files, validates read-only Plex/Radarr connectivity, verifies the Plex-only backup and nightly dry-run against a temporary database copy and temporary alert/backup paths, and removes its temporary files. It explicitly skips Kometa so it never reads the host's Kometa config during this isolated check. It intentionally does not send a live Plex `emptyTrash` request; that request contract is tested with a stub.

The install state phase repairs ownership of an existing database and its SQLite `-wal`/`-shm` sidecars to the configured service user. `sudo plexcurator validate` and `sudo plexcurator init-layout --dry-run` do not create or open the database.

Then add the managed folder (default `/nas/plex/Curated`) and every unmanaged folder to your Plex movie library. The validator warns
if they are missing. Everything starts in `mode = "observe"`: it collects data and creates empty folders, nothing else.
A normal rollout: `observe` for a while, then `sudo plexcurator --dry-run run` in `organize` and `reclaim` to read the plan, then switch the mode.

## Read and change scope

Sync reads and probes every movie in the selected Plex movie libraries. By default, `[plex].libraries = "configured"` selects
libraries whose Plex-mapped locations overlap the managed folder or any unmanaged folder; this is a library-level choice, so a
selected library with a broader root is read in full. Set `[plex].libraries = "all"` or a list of exact Plex movie library titles
to replace that default selection. The account watchlist, configured Plex logs, and Radarr data are read separately.
Library and watchlist responses are processed a page at a time; Radarr requests omit local cover images,
which plexcurator does not use, to reduce transient response memory.

Library selection does not grant filesystem access: files outside the configured folders are never moved, renamed, or deleted.
Moves are limited to the managed folder and moves out of configured unmanaged folders; deletion from an unmanaged folder also
requires `lifecycle = true`. After a move or deletion, Plex refreshes only the selected movie libraries. Plex ratings/state and
Radarr paths/exclusions are updated only as part of those configured-folder operations.

## Use

```
sudo plexcurator validate
sudo plexcurator --selftest validate          # one unchanged Radarr update request
sudo plexcurator radarr-check                 # check paths for movies plexcurator moved
sudo plexcurator radarr-check --fix           # repair drift only in organize/reclaim mode
sudo plexcurator --dry-run run                # preview anything, in any mode
sudo plexcurator reclaim --preview            # read-only candidates, even when space is fine
sudo plexcurator --dry-run reclaim --all      # full candidate list
python3 -m unittest discover -s tests -t .    # tests (run as root to include the build-script tests)
```

The reclaim preview groups candidates by source folder and rule, then shows size, age, and age-policy source. It ignores free-space thresholds only for listing; it never deletes or changes the database. The default listing is capped; use `--all` for every candidate and summary group.

Exit codes: 0 ok or a warning, 1 error, 2 an alert that needs a human (details in the log and in `/var/lib/plexcurator/ALERT`).
Because exit 2 is the alert status, systemd can show `plexcurator.service` as failed while the run itself completed
and raised an alert. `check-plex.sh` reports that specific status as `WARN ... alert raised (exit 2)`, not as a
generic service failure; inspect the alert file and logs for the condition.
Unidentified movies are warnings by default (`alert_unidentified = "warn"`); set it to `"fail"` to keep the prior
exit-2 behavior. Reclaim shortfalls still exit 2.

`check-plex.sh` records one drift-log result and checks Plex on TCP 32400, all documented `/nas` shares
as readable by `plex`, plus the plexcurator service user's `nas` group membership and group-writable
NAS mount modes. If write access is missing, the check reports the likely cause and
`mount-nas.sh --add-user NAME` fix. It checks the documented Remote Access and LAN Network settings,
and the local appdata filesystem. Appdata must have at least 10% and 1 GiB free. It also checks the plexcurator timers are active,
the latest oneshot service runs succeeded, the database opens read-only with a clean integrity check
and the installed schema version, and the newest recovery bundle is under 36 hours old on an SMB mount.
The daily 04:00 bundle contains a verified plexcurator SQLite snapshot, `Preferences.xml`, Plex plug-in preferences,
and the newest dated Plex-generated library database snapshot (never the live library database). If Plex has no dated
library snapshot, the run succeeds with a warning recorded in its receipt. The `plexcurator` database is checked with
`PRAGMA integrity_check`; Plex's snapshot may use Plex-only FTS tokenizers, so the bundle verifier checks its staged
size and SHA-256 and runs a read-only query against an ordinary table instead. The bundle is built and verified on
local disk first; the NAS mount is accessed only for the final copy. The receipt at
`/var/lib/backup-receipts/receipts.jsonl` records the archive size and SHA-256, which the health check verifies along
with the UTC timestamp of the last good backup.

The same daily backup service creates a separate Kometa artifact containing
only `config.yml` and the collections tree. It encrypts the archive with the
shared backup recipient public-key helper before writing to the NAS, then
writes a checksum sidecar, manifest, and `kometa` recovery-group receipt. The
backup fails closed if encryption cannot run. Thirteen encrypted Kometa
artifacts are retained; the CIFS mount may not enforce the local 0600 modes.
See the [Kometa restore section](../../docs/runbooks/backup-plex.md#restore-kometa).

`plexcurator validate` remains read-only. The explicit `--selftest` option sends one unchanged movie DTO through the
current Radarr update-by-id endpoint, without a rescan; it requires at least one existing Radarr movie. This catches an
API rejection before a nightly run. Owner UAT for card #248 confirmed that the update-by-id call is accepted on Radarr
6.4; the rescan behavior remains unverified. `radarr-check` is read-only unless `--fix` is supplied, and repair is
limited to `organize` or `reclaim` mode. The nightly run checks pre-existing moved-movie drift after organize, repairs
it in those modes, and records the finding in the summary and ALERT.

## Configuration

`config.example.toml` is the whole file. Required values are marked `...`. Anything not listed here is a default in code.

| Key | What it does |
|---|---|
| `mode` | `observe` collects data only; `organize` also moves/renames watched, rated and watchlisted movies; `reclaim` also deletes to free space |
| `watched_pct` | a movie is watched once its peak play percent reaches this (50); it never un-watches |
| `alert_unidentified` | `warn` (default) writes an ALERT warning but exits 0; `fail` writes an error alert and exits 2 |
| `[plex] url, token` | your Plex server and token (library, ratings, watch state, watchlist) |
| `[plex] path_map` | optional; only if Plex sees different paths than this host |
| `[plex] libraries` | `configured` reads libraries whose mapped locations overlap configured folders (default); `all` or a list of exact titles overrides it |
| `[radarr] url, api_key` | Radarr: ids by path, path updates after moves, bans on delete |
| `[radarr] path_map` | optional; only if Radarr sees different paths than this host |
| `[storage] min_free_pct` | start reclaiming when free space drops below this (35) |
| `[storage] reclaim_to_pct` | keep going until this much is free (40) |
| `[storage] backup_dir` | nightly recovery-bundle destination, a writable NAS path (required) |
| `[storage] measure_path` | optional; volume whose free space is measured (default: the managed folder) |
| `[folders] managed` | the one folder plexcurator owns: `Watchlist/` and `Watched/<video>/<audio>/<0-5>/` |
| `[[folders.unmanaged]] path` | an existing Plex movie folder; data is collected, only watched/rated/watchlisted movies are moved out |
| `[[folders.unmanaged]] lifecycle` | `true` lets the `stale_unmanaged` rule (and the rating rules) delete from this folder |
| `[[folders.unmanaged]] stale_days` | optional age override for `stale_unmanaged` in that folder; requires `lifecycle = true` (for example `61`) |
| `[[folders.unmanaged]] age_only` | optional `true` to let `stale_unmanaged` delete from this folder even when free space is high; overrides the rule setting |
| `[video] <name> = { min_width }` | video classes (also folder names); widest match wins; the lowest has `min_width = 0`; optional `min_height` |
| `[audio] <name> = { min_channels }` | audio classes by the best stream's channel count; the lowest has `min_channels = 0` |
| `[hdr.<type>] label, tag` | optional: how an HDR type is shown and tagged in file names (types `dv`, `hdr10plus`, `hdr10`, `hlg`, `sdr`; defaults below; empty tag = no tag) |
| `[lifecycle] stale_days` | default age for stale rules, in days (365) |
| `[lifecycle] watchlist_stale_days` | watchlist age in days; defaults to `stale_days` |
| `[lifecycle] age_only` | optional stale rules to run regardless of free space; defaults to `[]` (off) |
| `[lifecycle] stale_months` | deprecated compatibility alias for `stale_days` (`months x 30.44`); `validate` warns, and it cannot be set with `stale_days` |
| `[lifecycle] rules` | rules in order: `one_star`, `two_star`, `stale_watchlist`, `stale_unmanaged`; delete a name to turn it off |

Adding a class (say `8k`): add the line to `[video]`, run `plexcurator reclassify` (no re-probe), and the next run creates its folders
and re-files affected movies (in `organize`/`reclaim` mode).

**HDR types.** Every probed file gets one canonical type, by fixed priority Dolby Vision > HDR10+ > HDR10 > HLG > SDR, stored in `hdr`
(`dv`, `hdr10plus`, `hdr10`, `hlg`, `sdr`; NULL = not probed), plus separate flag columns `dolby_vision`, `hdr10plus`, `hdr10`, `hlg`,
`dv_profile` and `dv_fallback` (`hdr10`, `hlg`, `sdr` or empty = the base layer a non-Dolby player sees), on `file` / `v_movie` and
`video_stream` / `v_video`. Detection reads ffprobe's colour transfer and Dolby Vision record and mediainfo's `HDR_Format*` fields. ffprobe
rarely lists HDR10+ at stream level, so HDR10+ needs `mediainfo` installed (the build script installs it). The file-name tag is
`DV`, `HDR10+`, `HDR10`, `HLG`, none for SDR, e.g. `[4khd 7ch HDR10+]`; change one with `[hdr.dv] tag = "DoVi"` (no spaces or brackets, unique).
The name is always derived from the stored type, so a changed tag renames curated files on the next `organize` run, once, and a second run
changes nothing. Queries: `by_hdr`, `hdr_by_video_class`, `dolby_vision_profiles`, `hdr_stars`.

Fixed in code, not configurable: movies rated 3-5 stars are never deleted; the age rules skip anything watched, rated or in progress;
a movie with no TMDB/IMDb id is flagged `unidentified` (with an alert) and never moved, renamed or deleted.
Age-only reclaim is opt-in. The first real run with age-only candidates alerts with the candidate list and deletes nothing;
review it, then run `plexcurator reclaim --confirm-age-only` once. Later runs apply that age-only policy automatically.
At most 10 movies are deleted per run; if more candidates remain, the run raises an alert and continues in a later run.

## Queries

`python3 -m plexcurator query list` shows the examples (resolution, audio and HDR mix, where content sits, codec mix, rating vs
resolution, abandoned movies, taste by decade, days from born to watched, problem movies, event timeline, retirement audit,
unidentified movies). Any field of the stored ffprobe/mediainfo/Plex JSON can be aggregated with `json_extract` over `source_record`.

## Versions and upgrades

`python3 -m plexcurator --version` prints the app version and the database schema version it expects (`APP_VERSION`, `SCHEMA_VERSION`
in `plexcurator/version.py`). The database records its schema in `PRAGMA user_version` and in the `schema_migration(version, applied_at,
app_version)` table. At every start: database older than the app, it is backed up to `storage.backup_dir` first, then numbered steps
(`db.MIGRATIONS`, one place) are applied in order; equal, it just runs; newer than the app knows, it refuses with an error and
touches nothing. Backups are named `plexcurator-<time>-schema<N>.db`, so a restore always says which schema it holds (the number is
also in the file's own `user_version`). Today the schema is version 2 (HDR type columns, backfilled from the stored raw JSON without re-probing); to change it, add step N+1 and bump `SCHEMA_VERSION`.
