# Plexcurator install and rollout

This is the operator runbook for a Plex server rebuilt from the current `plex` stack. The owner runs every command marked **Owner** on that real host. Do not put Plex tokens, Radarr keys, or their values in shell history, logs, screenshots, issues, or this repository.

The commands and guardrails below reflect the vpcx1 rollout on 2026-10-31. A rebuilt node can produce different counts and paths; treat each preview as node-specific, not as approval to repeat old actions.

## 1. Prepare NAS access and Plex paths

**Owner — changes NAS membership and mounts:** from the network repository checkout, add `plex` to the NAS group and let the script remount configured shares:

```bash
sudo bash stacks/os/ubuntu/mount-nas.sh --add-user plex
sudo systemctl restart plexmediaserver
```

The mount script may prompt for NAS credentials. Enter them only at the prompt. Confirm `plex` is in the `nas` group and that the required shares are mounted before continuing. Restarting Plex is needed for its process to receive the updated supplementary groups.

In Plex, add the managed folder and every configured unmanaged folder to a **movie** library. Linux paths are case-sensitive: use the exact spelling and capitalization shown by the mounted filesystem in both Plex and the config. The template's managed path is `/nas/plex/Curated`; replace the example unmanaged path with the actual movie-library path on this node. Keep the managed folder distinct from every unmanaged folder.

## 2. Create and fill the config

The config lives at `/etc/plexcurator/config.toml`; the build script creates it from `config.example.toml` on a fresh node, then stops with exit code 2 before installing anything. **Owner — expected first-run bootstrap:**

```bash
sudo ./stacks/plex/build-plex-node.sh
sudoedit /etc/plexcurator/config.toml
```

In Plex Web, get the server token using Plex's [official token instructions](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/). In Radarr, find the API key under **Settings → General → Security**. Paste both only into the protected config editor; do not display or copy their values into terminal output.

Fill in the required Plex URL and token, Radarr URL and API key, `[storage].backup_dir`, `[folders].managed`, and each `[[folders.unmanaged]]` path. Set `backup_dir` to a NAS directory that `plex` can write to. Keep `mode = "observe"` and the production storage thresholds (template defaults: 35% and 40%) for the first rollout. The build creates the config as `root:plex` with mode `0640` so the service account can read it.

## 3. Check and build

**Owner — validates the completed config and reports planned changes without installing or probing writes:**

```bash
sudo ./stacks/plex/build-plex-node.sh --check
```

Resolve every config, path, connectivity, or permission problem before proceeding. `--check` deliberately skips the brief NAS write probe.

**Owner — installs and converges the node after the check is clean:**

```bash
sudo ./stacks/plex/build-plex-node.sh
# Only if the build created the Kometa placeholder:
sudoedit /etc/kometa/config.yml
# Rerun after filling the placeholder (otherwise this is an idempotent no-op):
sudo ./stacks/plex/build-plex-node.sh
sudo ./stacks/plex/check-plex.sh --check
```

The first build creates `/etc/kometa/config.yml` from a credential-free
placeholder only if it is absent; the Kometa timer remains disabled. If the
placeholder was created, fill it with the owner's existing Kometa settings
using `sudoedit`, then rerun the full build to enable the timer. Existing
Kometa configuration is never overwritten. Keep its credentials in that
protected file and out of terminal output, shell history, issues, and this
repository.

The build installs dependencies and the package, initializes the database and folder layout, installs the systemd timers, and creates `/usr/local/bin/plexcurator`. That wrapper uses the configured service account (default `plex`), install directory, and config; run it with `sudo`, for example `sudo plexcurator validate`. The nightly curator run is scheduled for 04:15 and the database backup for 04:00. The backup is staged and verified on local disk before the NAS copy.

The same build installs Kometa v2.4.8 from the SHA-256-pinned source archive and installs the release's `requirements.txt` into `/opt/kometa/venv`, owned by `kometa:kometa`. Its requirements manifest is independently hash-pinned, but upstream does not hash every dependency: it includes an `apprise>=` lower bound and an unpinned `serializd-py` Git dependency. This is an accepted reproducibility risk; a rebuild may resolve different dependency versions even with the same Kometa release pin. Do not run `pip install -U`; dependency changes are applied only by an intentional pin update.

If `/etc/kometa/config.yml` is absent, the build installs a placeholder without credentials and leaves `kometa.timer` disabled. Fill the config before the next build enables the timer. Existing config contents are never overwritten; the service uses `--read-only-config`.

## 4. Roll out one mode at a time

All commands in this section are **Owner** actions. Manual wrapper runs execute as `plex`, print their log output to the terminal, and do not write to the systemd journal.

### Observe first

Leave `mode = "observe"` and run:

```bash
sudo plexcurator run
```

Observe collects Plex, Radarr, and filesystem data and creates the managed folder tree; it does not move or delete media. Review the terminal output and health check before changing modes.

### Preview organize before moving anything

Set `mode = "organize"` in `/etc/plexcurator/config.toml`, then preview:

```bash
sudo plexcurator --dry-run run
```

Review every planned source and destination, not only the count. The vpcx1 preview recorded on 2026-10-31 listed **38 planned moves**; this is a historical example, not an expected count for a rebuilt or different node. If the plan is not understood, leave the node in `observe` and investigate. Only after approving that node's preview, run `sudo plexcurator run` to apply the moves and renames.

### Preview reclaim without deleting

Before any real reclaim, take or verify a recent database backup and review the complete candidate list. The following preview ignores the free-space threshold for listing candidates and is read-only:

```bash
sudo plexcurator --dry-run reclaim --all
```

To preview the space-triggered plan as it would run against this volume, read the current `free space:` percentage, then temporarily set `mode = "reclaim"` and choose valid test thresholds just above that percentage (`0 < min_free_pct < reclaim_to_pct < 100`). Run:

```bash
sudo plexcurator --dry-run reclaim
```

The output reports free space, the thresholds, age-only and space-driven candidate counts, and each planned candidate. **Immediately restore the exact production thresholds and the prior mode after the preview. Never run a real `plexcurator reclaim` while test thresholds are configured.** If the volume has too much free space to choose valid thresholds above it, use the read-only `--dry-run reclaim --all` preview instead.

Only switch to `mode = "reclaim"` with the production thresholds when the owner has reviewed and approved the candidates. Reclaim permanently removes files, is capped at 10 movies per run, and may update Radarr exclusions and Plex library state. Age-only rules require a separate first-run alert and explicit `--confirm-age-only`; review that alert before confirming anything.

## 5. Read run results

- Application exit code **0** means success or a warning; **1** means an error; **2** means an alert needs a human. An exit 2 can make `plexcurator.service` appear failed even though the run completed and raised an alert.
- The default alert file is `/var/lib/plexcurator/ALERT`. Read it and the corresponding log whenever an alert is raised; `check-plex.sh` reports the alert-status service failure as a warning.
- A run/reclaim output line such as `free space: 37.5% (… of …); reclaim below 35%, to 40%` records the measured volume and configured thresholds. Confirm the `measure_path` (or default managed volume) is the intended volume.
- Manual `sudo plexcurator ...` output goes to the terminal. Timer-driven output is in the journal:

  ```bash
  sudo journalctl -u plexcurator.service --since today --no-pager
  sudo journalctl -u plexcurator-backup.service --since today --no-pager
  ```

## 6. Rollback and recovery

### Undoing moves

Organize records each successful move in the `event` table as `kind = 'moved'`: `value` is the destination path and the JSON `detail.from` is the original path. Inspect the event history before restoring anything:

```bash
sudo plexcurator query timeline
```

Stop the curator timer while performing a rollback. For each reviewed event, confirm the destination still contains the intended media and the original path is safe to restore to; then move it back manually, preserving any same-stem subtitle or sidecar files. **Owner — example only; replace both placeholders with paths from the event and do not run it literally:**

```bash
sudo systemctl stop plexcurator.timer
sudo mv -- '/path/from/event/value' '/path/from/event/detail.from'
```

Rescan the affected Plex library and reconcile in `observe` mode before re-enabling the timer. Event history is an audit trail, not an automatic undo command. If the file has since moved again or the destination is missing, stop and investigate rather than guessing.

### Restore the database

Backups are named `plexcurator-<time>-schema<N>.db` in the configured `backup_dir`; the backup timer retains the newest 14. A database restore rolls back curator metadata only—it does not put moved/deleted media back or reverse Radarr/Plex changes.

**Owner — recovery procedure:** stop both timers and any running oneshot services; copy the current database and any `-wal`/`-shm` sidecars aside; select a known-good backup compatible with the installed schema; replace the configured `advanced.db_path` database with that backup; remove stale sidecars only after the services are stopped; and restore ownership to the configured service user (default `plex`). Then run `sudo ./stacks/plex/check-plex.sh --check`, inspect the result, and restart the timers:

```bash
DB=/var/lib/plexcurator/plexcurator.db # replace if advanced.db_path differs
BACKUP=/nas/path/to/selected-plexcurator-backup.db # set this to the selected backup's actual path
SAVE="$DB.before-restore.$(date -u +%Y%m%dT%H%M%SZ)"
sudo systemctl stop plexcurator.timer plexcurator-backup.timer
sudo systemctl stop plexcurator.service plexcurator-backup.service
sudo cp -- "$DB" "$SAVE"
for suffix in -wal -shm; do
  if sudo test -e "$DB$suffix"; then sudo cp -- "$DB$suffix" "$SAVE$suffix"; fi
done
sudo cp -- "$BACKUP" "$DB"
sudo rm -f -- "$DB-wal" "$DB-shm"
sudo chown plex:plex "$DB" # use the configured --user if it is not plex
sudo ./stacks/plex/check-plex.sh --check
sudo systemctl start plexcurator.timer plexcurator-backup.timer
```

### Deleted media

Reclaim uses permanent filesystem deletion (`os.remove` or recursive directory removal), then may empty Plex's library trash. Restoring the database cannot recover those files. Recovery requires an independent NAS snapshot or media backup; restore the media first, then reconcile Plex and Radarr. Treat a confirmed delete as irreversible if no such backup exists.
