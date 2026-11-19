# qbt: qBittorrent and the Servarr apps behind Mullvad, rebuilt from nothing

**Serves:** workbench:OC13
**Tier:** homelab
**Status:** proposed 2026-11-19

The downloader VM keeps what works today: Mullvad's own daemon owns the tunnel, `mullvad-health.sh` rolls over to the next relay, and `summarize-mullvad-health.py` is the owner's measure of reliability. This spec moves those scripts into this repo unchanged and adds only what is missing. Only the rung needed now is written (D12). `network` is read, not edited.

## Boundaries

| | qbt VM |
|---|---|
| **Owns** | qBittorrent, Radarr, Sonarr and Prowlarr config and state, the relay list, the health journal, its encrypted per-app archives |
| **Needs, hard** | the Mullvad account and daemon, the internet, the NAS for media and backups |
| **Needs, soft** | DNS (the apps start without it), the monitor (only watches it) |
| **Never needs** | core DNS to start, any other stack |
| **Needed by** | nothing else; the monitor watches it |

## Requirements

| ID | P | Requirement | Acceptance |
|---|---|---|---|
| QBT-FR-01 | P1 | **The owner's Mullvad scripts move unchanged.** `mullvad-health.sh`, `mullvad-relays.sh` and `summarize-mullvad-health.py` live in `qbt/ops/` of this repo, byte for byte as in `network` (a change needs a reason written in the story). | MVP 1: `diff` of each file against `network/stacks/qbt/ops/` shows no difference; `bash -n`, `shellcheck` and `python3 -m py_compile` pass on them. |
| QBT-FR-02 | P1 | **Rollover works, proved without a real tunnel.** With a stub `mullvad` command and a stub for the health URL that make the current relay fail, one run of `mullvad-health.sh` sets the next relay in its list and connects. | MVP 1: `mise run qbt-prove` runs the script against the stubs, prints `ok rollover <from> -> <to>` and `ok healthy no change`, and leaves nothing behind. |
| QBT-FR-03 | P1 | **Declared to the monitor.** `health/qbt.toml` gives the four answers, the right answer being the qBittorrent WebUI replying. | MVP 1: `mise run check` accepts the file and the generated config has its endpoints. |
| QBT-FR-04 | P2 | **No leak**, the apps sending nothing outside the tunnel while it is down or rolling over, proved on a VM. | Written at MVP 2. |
| QBT-FR-05 | P2 | **Rebuild alone and the per-app backup** with a drill, keeping today's encrypted archives and retention. | Written at MVP 3. |

## Homelab scope

Safe shortcut: MVP 1 proves the rollover logic against stubs; nothing real is connected. Never skipped: the no-leak proof on a real VM (MVP 2) and the baseline from `summarize-mullvad-health.py` before the old VM is replaced.
