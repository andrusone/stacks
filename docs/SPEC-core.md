# Core: DNS and time for the LAN, rebuilt from nothing

**Serves:** workbench:OC12
**Tier:** homelab
**Status:** proposed 2026-11-19

Two identical core nodes answer DNS and serve time for the LAN. This spec is the redesign of `network/stacks/core`; `network` is read for the zone and the old settings and is not edited. Only the rung needed now is written (D12); later rungs are written from friction.

## Boundaries

| | Core node |
|---|---|
| **Owns** | its resolver and zone-server config, its chrony config, its firewall rules, and a git copy of the zone file |
| **Needs, hard** | the zone file in git (the `zone` repository, written by OC9's tool; a local copy once cloned), an upstream resolver and an upstream time source on the internet |
| **Needs, soft** | the monitor (only watches it), TrueNAS (only holds its service backup, a later rung) |
| **Never needs** | HAProxy, a floating address, a dashboard, the monitor or any other stack to start |
| **Needed by** | every LAN client for DNS and time; the monitor's checks resolve by address, so the monitor never needs core DNS |

No circle: core needs nothing that needs core.

## Requirements

| ID | P | Requirement | Acceptance |
|---|---|---|---|
| CORE-FR-01 | P1 | **The internal zone is served from a git copy.** An authoritative server (BIND, recursion off) in a container serves the zone file as it is in git, and refuses to start on a zone that fails `named-checkzone`. | MVP 1: `mise run core-prove` starts the stack on one Docker machine with the zone fixture; `dig @127.0.0.1 -p <port> <known host>` returns its address; a zone with a syntax error makes `core-up` stop with the checker's message. |
| CORE-FR-02 | P1 | **Recursive DNS for the LAN.** A validating resolver (Unbound) in a container answers recursive queries, sends the internal zone to the authoritative server, and returns SERVFAIL for a name that fails DNSSEC. | MVP 1: through the resolver's port, the known internal host returns its address, `example.com` resolves, and `dnssec-failed.org` returns SERVFAIL. |
| CORE-FR-03 | P1 | **Time for the LAN.** chrony in a container serves NTP to clients and follows upstream sources. | MVP 1: a throwaway client container runs `chronyd -Q 'server <core> iburst'` against it and reports a measured offset. |
| CORE-FR-04 | P1 | **Declared to the monitor.** `health/core.toml` gives the four answers; its right answer is a real DNS lookup of the known host against the node's own address. | MVP 1: `mise run check` accepts the file and the generated Gatus config holds a DNS check for it. |
| CORE-FR-05 | P2 | **Host-level time and firewall on a real VM**, ufw allowing only the LAN and admin addresses, proved from a LAN client (Docker publishes around ufw). | MVP 2: `compose/core-vm/host.sh` (run as root on a VM) installs chrony and ufw, makes chrony serve the LAN and nobody else, sets ufw default-deny with DNS (53 tcp/udp) and NTP (123/udp) open to `CORE_LAN` and SSH open to `CORE_ADMIN`, and adds the same rules to Docker's `DOCKER-USER` chain so a published port is filtered too; a second run changes nothing and ends `changes: 0`; `--dry-run` prints the commands. A test with stubbed `ufw`, `iptables` and `systemctl` checks the commands. |
| CORE-FR-06 | P2 | **Rebuild alone and service backup** with the forge's reconnect, restore and drill expectations. | Written at MVP 3 or later. |
| CORE-FR-07 | P2 | **The zone comes from the `zone` repository, by IP, and survives its loss.** `compose/core-vm/zone-sync.sh` clones `CORE_ZONE_URL` (an address, never a name; read-only) into `CORE_ZONE_DIR` on first run and pulls on later runs with `git pull --ff-only`; a systemd timer (`zone-sync.timer`, every 5 minutes) runs it. After a pull the zone is checked with `named-checkzone`; only a zone that passes is copied to the folder BIND reads, so a bad commit or an unreachable origin leaves the last good copy serving. A node with a local copy and no reachable origin starts and serves. | MVP 2: a test with a local bare repository as origin shows the first run clones, a pushed change reaches BIND's folder on the next run, a pushed bad zone does not, and a run with the origin removed exits 0 and leaves the copy. |
| CORE-FR-08 | P2 | **One node is secondary to the other.** With `CORE_ROLE=primary` BIND allows zone transfer and sends NOTIFY only to `CORE_PEER`; with `CORE_ROLE=secondary` it transfers the zone from `CORE_PEER` and keeps it on local disk, so a rebuilt primary can load the zone from the secondary with the forge down (an operator step in the runbook, not automatic). | MVP 2: a test brings up two BIND containers on one machine, the secondary answers the fixture host after transfer, and a transfer request from any other address is refused. |
| CORE-FR-09 | P2 | **The proof needs nothing on the host.** `core-prove` runs `dig` from a throwaway container (the BIND image already in the stack), so a machine with only Docker and mise passes it. | MVP 2: `core-prove` passes on a machine where `command -v dig` finds nothing. |
| CORE-FR-10 | P2 | **One setup command per VM, and a proof from a LAN client.** `compose/core-vm/setup.sh` (at most 300 lines, split by stage) asks for the VM's values once (`CORE_BIND`, `CORE_LAN`, `CORE_ADMIN`, `CORE_ZONE_URL`, `CORE_ROLE`, `CORE_PEER`), writes `.env`, runs `host.sh`, installs the zone-sync timer, starts the stack and ends `changes: n` (`changes: 0` on a rerun). `mise run core-lan-prove -- <core-ip>` run from any LAN client does the DNS lookup, a DNSSEC failure, a time query, and probes the ports that must stay closed. | MVP 2: `setup.sh --dry-run` on a clean Ubuntu lists every step and writes nothing; `core-lan-prove` has a test with stubbed `dig`, `chronyc` and `nc`. The VM run itself is the owner's weekend deployment and is logged as friction. |

## Homelab scope

Safe shortcuts: MVP 1 runs on one Docker machine with high ports and a zone fixture, and chrony is a container because nothing here sets a clock. Never skipped: DNSSEC validation, recursion limited to the LAN on a real VM (MVP 2), and the zone gate before the server starts.
