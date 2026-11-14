# Stacks: from a commit to a running service

**Serves:** workbench:OC2
**Tier:** homelab
**Status:** accepted 2026-11-14

A stack is one service on its own VM. This spec covers adding one: an entry in the stack map, a commit, one apply, and the service is up on its own IP and name. Rebuilding with data intact (OC3), secret rotation (OC4), base updates (OC5) and the forge (OC6) get their own specs.

It carries forward from the `network` repo's standards: stack IDs follow `std-stacks` §3 (2–12 lowercase letters, digits or single hyphens, named for the role, never reused); the zone file stays the single source for names (`std-naming`); and no secret is ever in git.

## Requirements

| ID | Requirement | Acceptance |
|---|---|---|
| SK-FR-01 | **One entry defines a stack** (contract). A stack is declared by one entry in the stack map: its ID, what it runs, its size, and its Proxmox pool (`sensitive` or `dev`, workbench D10). Everything else has a default. | An entry for `smoke` with only those fields deploys into its pool. A stack's token can't touch the other pool or the core DNS nodes. |
| SK-FR-02 | **The map is checked before anything changes.** `mise run check` rejects, without touching Proxmox: an invalid or reused ID, a duplicate IP, a missing required field, and a stack with no health check. | One fixture per fault, each named in the output; a valid map passes. |
| SK-FR-03 | **Its own IP, stable across rebuilds.** Each stack gets an address no other stack has, and keeps it when its VM is rebuilt. | Apply, destroy that VM, apply again: same IP. |
| SK-FR-04 | **Its own name.** `<id>.home.qeke.net` resolves to the stack's IP from the LAN, without a hand edit to the zone. | `dig smoke.home.qeke.net` from a LAN client returns smoke's IP. |
| SK-FR-05 | **Healthy means healthy.** A stack counts as up only when its containers report healthy. | `smoke` with a broken health check never reports up. |
| SK-FR-06 | **Secrets arrive without hand-copying.** A secret a stack needs reaches it at deploy, and git holds it only encrypted. | `smoke` has one secret; the container reads it; a scan of the repo finds no plaintext. |
| SK-FR-07 | **One command after the commit** (contract: `tofu apply`). No Proxmox UI, no SSH, no manual step. | `smoke` is deployed with nobody touching Proxmox or the VM. |
| SK-FR-08 | **Ten minutes.** From the start of the apply to the stack resolving and healthy. | Timed on `smoke`. |
| SK-NFR-01 | **A new stack touches only itself.** The plan for one new entry adds that stack and its name, and changes nothing else. | `tofu plan` for `smoke` shows only additions for `smoke`. |

## Homelab scope

- **Shortcuts:** one Proxmox host; no high availability; one environment (no staging copy of each stack); an apply run by the owner, not a pipeline; no change approval.
- **Never skipped:** a plan before every apply; no plaintext secret in git or in OpenTofu state; a zone change is validated before DNS reloads, so a bad entry can't take down household DNS; the core DNS nodes (vpnx1, vpnx2) are not managed from this repo.
- **Enterprise habit not to import:** a module per stack, a registry of modules, separate state per team.

## Decided items

All six were accepted as leaned on 2026-11-14. SK-OI-6's details are in workbench D10.

| ID | Question | Decision |
|---|---|---|
| SK-OI-1 | How does a stack's name get into the zone without a hand edit? The `network` repo's CoreDNS serves a hand-kept file zone. | CoreDNS serves a second zone file generated from the stack map, validated before reload. |
| SK-OI-2 | Where does OpenTofu state live? OC4 scans it for plaintext secrets. | On TrueNAS, with secrets kept out of it by design (SK-FR-06). |
| SK-OI-3 | Which network zone and address range do stacks get (`adr-networks`)? | A server zone with a reserved block for stacks. |
| SK-OI-4 | VM hostname vs stack name. `std-naming` names hosts (`vpcx<n>`), and a stack is a service. | Hostname per `std-naming`; the DNS service name is the stack ID. |
| SK-OI-5 | The base template. OC2 needs one to clone; OC5 owns keeping it current. | A first template built once, as the **enabler** for the first value story; OC5 takes over later. |
| SK-OI-6 | The secret mechanism (SK-FR-06) is OC4's territory. | SOPS with age keys, decided in a workbench D10 before SK-FR-06's story is `ready`. |
