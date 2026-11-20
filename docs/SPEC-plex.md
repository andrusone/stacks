# plex: Plex, Kometa and plexcurator in Docker, rebuilt from nothing

**Serves:** workbench:OC14
**Tier:** homelab
**Status:** proposed 2026-11-20

Plex Media Server and Kometa move to containers; plexcurator is packaged, not rewritten: its code moves into this repo unchanged and only its configuration paths change. Only the rung needed now is written (D12). `network` is read, not edited. The old stack is `network/stacks/plex`.

## Boundaries

| | plex VM |
|---|---|
| **Owns** | Plex's application data (library database, watch history, ratings, collections), Kometa's config, plexcurator's database and its backups |
| **Needs, hard** | the NAS for media and for the backup share, the internet for Plex's account |
| **Needs, soft** | DNS (Plex starts without it), Radarr on the downloader VM (plexcurator reads it, read-only), the monitor (only watches it) |
| **Never needs** | core DNS to start, Mullvad, any other stack |
| **Needed by** | nothing else; the monitor watches it |

## Requirements

| ID | P | Requirement | Acceptance |
|---|---|---|---|
| PLEX-FR-01 | P1 | **plexcurator moves unchanged.** The `plexcurator/` package, `check-plex.py`, `check-plex.sh`, `config.example.toml`, `deploy/` and `tests/` live in `plex/`, and the `os/common/backup/` and `os/common/drift/` helpers they call live at the same relative place (`os/common/` at the repo root) of this repo, byte for byte as in `network/stacks/plex` (a change needs a reason written in the story). | MVP 1: `diff -r` of each against `network/stacks/plex/` shows no difference; `mise run plex-prove` runs the unchanged unit tests (`python3 -m unittest discover -s tests -t .` in `plex/`) and they pass, with no network call. |
| PLEX-FR-02 | P1 | **Plex and Kometa are one compose file with pinned images.** `compose/plex/docker-compose.yml` runs Plex Media Server and Kometa from images pinned by tag and digest in `compose/plex/.env.example`; Plex's data, Kometa's config and the media path are bind mounts named in the same file; Kometa's version matches `pins.env` (2.4.8). No hardware transcoding device. | MVP 1: `docker compose --env-file compose/plex/.env.example -f compose/plex/docker-compose.yml config` exits 0 and prints both services with the pinned images; a search finds no unpinned `:latest`. |
| PLEX-FR-03 | P1 | **Declared to the monitor.** `health/plex.toml` gives the four answers, the right answer being Plex's identity endpoint (`/identity`) replying. | MVP 1: `mise run check` accepts the file and the generated config has its endpoints. |
| PLEX-FR-04 | P2 | **Plays on a real client**, with the library, watched states and ratings of the old server, proved on a VM. | Written at MVP 2. |
| PLEX-FR-05 | P2 | **Rebuild alone and the service backup**, with a drill. | Written at MVP 3. |

## Homelab scope

Safe shortcut: MVP 1 proves the moved code's own tests and that the compose file is well formed; no Plex runs and no library is read. Never skipped: a play on a real client with the old server's watch history, ratings and collections before the old VM is replaced (MVP 2).
