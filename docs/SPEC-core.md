# Core: DNS and time for the LAN, rebuilt from nothing

**Serves:** workbench:OC12
**Tier:** homelab
**Status:** proposed 2026-11-19

Two identical core nodes answer DNS and serve time for the LAN. This spec is the redesign of `network/stacks/core`; `network` is read for the zone and the old settings and is not edited. Only the rung needed now is written (D12); later rungs are written from friction.

## Boundaries

| | Core node |
|---|---|
| **Owns** | its resolver and zone-server config, its chrony config, its firewall rules, and a git copy of the zone file |
| **Needs, hard** | the zone file in git (`network`, written by OC9's tool), an upstream resolver and an upstream time source on the internet |
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
| CORE-FR-05 | P2 | **Host-level time and firewall on a real VM**, ufw allowing only the LAN and admin addresses, proved from a LAN client (Docker publishes around ufw). | Written at MVP 2 from friction. |
| CORE-FR-06 | P2 | **Rebuild alone and service backup** with the forge's reconnect, restore and drill expectations. | Written at MVP 3 or later. |

## Homelab scope

Safe shortcuts: MVP 1 runs on one Docker machine with high ports and a zone fixture, and chrony is a container because nothing here sets a clock. Never skipped: DNSSEC validation, recursion limited to the LAN on a real VM (MVP 2), and the zone gate before the server starts.
