# devices: the network and storage devices, watched by the monitor

**Serves:** workbench:OC15
**Tier:** homelab
**Status:** proposed 2026-11-21

The monitor (OC8, `SPEC-health.md`) answers the four questions for the physical devices the stacks sit on, with its existing Gatus checks and nothing new written but one generator option. Only the rung needed now is written (D12). The devices come from the zone file, not from a list the owner gives: the ER8411 gateway and firewall (`ppno1`, 10.10.8.1), the TL-SG3428X-M2 switch (`ppno2`, 10.10.8.2), the OC200 Omada controller (`ppno3`, 10.10.8.3), TrueNAS (`ppsx1`, 10.10.8.20) and Proxmox #1 (`ppcx1`, 10.10.8.21). Access points are managed through the controller and are a later rung (they need its API and a read-only account the owner makes, working rule 17).

## Boundaries

| | Device health files |
|---|---|
| **Owns** | one file per device in `health/`, and the generator's `insecure` option |
| **Needs, hard** | the monitor (OC8) running, the device's address (an address, never a name: the monitor needs no DNS) |
| **Never needs** | a token, an agent on the device, or any code that probes a device |
| **Needed by** | nothing; the monitor page and the phone show them |

## Requirements

| ID | P | Requirement | Acceptance |
|---|---|---|---|
| DEV-FR-01 | P1 | **A health file may say its right-answer request skips certificate checks.** Devices serve self-signed certificates. A health file may carry `insecure = true`; the generated Gatus endpoint for its right answer then has `client: insecure: true`, and no other endpoint does. The key is optional, accepts only `true` or `false`, and a file without it generates what it generated before. | MVP 1: `go test ./...` has a case where `insecure = true` produces the client block on the right-answer endpoint only, a case without the key whose output is unchanged, and a bad value is rejected naming the line; `mise run check` passes. |
| DEV-FR-02 | P1 | **Each device has its four answers.** `health/ppno1.toml`, `ppno2.toml`, `ppno3.toml`, `ppsx1.toml` and `ppcx1.toml` each name the device by its address, its management service port (443, or 8006 for Proxmox), a right-answer request that returns what a healthy device returns (an HTTPS request to the management page and its status), `insecure = true`, and `needs = []`. A comment names the device and what its address is in the zone. | MVP 1: `mise run check` accepts all five and the generated config holds a host, service and right-answer endpoint for each. Which status a real device returns is the owner's first run (friction), not guessed to a certainty here. |
| DEV-FR-03 | P2 | **One real fault reaches the phone.** | Written at MVP 2 from friction. |
