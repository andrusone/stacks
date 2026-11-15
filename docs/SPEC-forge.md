# Forge: where the work lives, and can be rebuilt alone

**Serves:** workbench:OC6, workbench:OC7
**Tier:** homelab
**Status:** proposed 2026-11-15

The forge is the self-hosted Forgejo that holds every repo, runs the pull requests, and with its runner runs `mise run check` on every push (workbench D07). This spec says what must be true so that the place the work lives is small, stands alone, is watched from its first boot, and can be rebuilt from nothing in an afternoon at most. The requirements marked OC7 are the part of the outcome about no outside gate (rate limits, exit to another host, cost); the rest is OC6.

It follows the owner's order: workbench, then monitoring, then the forge, then everything else is built. So the forge and its runner are made by hand once, like the monitor, before the stack machinery exists, and each declares a health file the moment it exists ([SPEC-health.md](SPEC-health.md), HL-FR-06).

## Build or adopt?

Adopt Forgejo; nothing here is written. D07 has the maturity case: a hard fork of Gitea governed by a non-profit, with an LTS line, and every clone holds the full history, so losing the forge loses pull request discussion and CI logs, never a commit. Its Actions are deliberately not GitHub-compatible, which does not matter because CI runs one command. There is no commercial support; Gitea is the drop-in fallback if that ever matters.

## Boundaries

The forge and its runner are two separate units. Each stands alone.

| | The forge | The runner |
|---|---|---|
| **Owns** | the repos, accounts, tokens and pull request history on its one VM and one data folder | nothing worth keeping: it can be recreated and re-registered at any time |
| **Needs, hard** | the Proxmox host (compute and local disk), a network path to its users | the forge, to receive jobs; the internet, to fetch tools |
| **Needs, soft** (keeps working without it) | TrueNAS, only as the place the nightly copy goes; the GitHub mirror target; the monitor, which only watches it | nothing |
| **Never needs** | TrueNAS storage to run, DNS to start, any stack, the monitor, the runner | TrueNAS, the Proxmox API, any secret |
| **Needed by** | every repo's `origin`, every agent, the runner, and the monitor's config pull (which tolerates its absence) | nothing |

The one circle to break on purpose: the forge's own setup script lives in a repo that the forge hosts. A rebuild therefore never takes that script from the forge; it takes it from any clone (FG-FR-02).

## Requirements

**P1** is OC6's check. **P2** is OC7's.

| ID | P | Requirement | Acceptance |
|---|---|---|---|
| FG-FR-01 | P1 | **The forge stands alone.** It is one VM on local Proxmox storage with no other service in it, and it needs nothing from TrueNAS to run. | Block the forge VM's access to TrueNAS: cloning, pushing and opening a pull request still work. |
| FG-FR-02 | P1 | **Rebuild alone, without the forge.** If the forge VM is lost, a new VM, the setup script and the restored data bring it back with nothing else touched. The script and its inputs come from a clone on another machine, never from the forge itself. | Delete the forge VM. Create a new one from the golden image, take the script from a clone on the owner's machine, restore the latest nightly copy. Every repo, pull request and account is present, and the elapsed time is recorded. |
| FG-FR-03 | P1 | **A nightly copy is on TrueNAS, taken without the forge holding NAS credentials.** TrueNAS fetches it. It restores cleanly. | The newest copy on TrueNAS is under 26 hours old. The rebuild in FG-FR-02 restores from it. A search of the forge VM finds no TrueNAS credential. |
| FG-FR-04 | P1 | **The runner is a separate unit.** It is its own VM, registered to the forge, and for each push it runs `mise run check` and reports the result on the branch or pull request. | Push a branch with a passing and a failing check in turn: each shows green and red on the branch within 5 minutes. The runner VM is not the forge VM. |
| FG-FR-05 | P1 | **The runner can reach the forge and the internet, and nothing else.** It holds no secret and cannot reach TrueNAS or the Proxmox API. It runs code from pushed branches, so it is treated as untrusted. | From the runner VM, a connection to TrueNAS and to the Proxmox API fails. A search of the runner finds no token other than its own registration. Delete the runner and register a new one: jobs run again. |
| FG-FR-06 | P1 | **Roles are enforced by the forge** (D07). `main` is protected, and only the architect's token merges to it. A builder token can push `st*` branches and the workbench, and cannot push to a product repo's `main`. An operator token reads product repos and writes the workbench. | With each token: a builder push to `main` is refused and to a `st*` branch succeeds; an operator push to a product repo is refused; an architect merge succeeds. |
| FG-FR-07 | P1 | **Agents switch with one line.** Moving an agent machine to the forge is one change to `FORGE_URL` and a rerun of the machine setup. Nothing in any repo changes. | On the agent machine, change `FORGE_URL`, rerun the setup, start a builder: it claims a story by push, and its evidence lands on the forge. |
| FG-FR-08 | P1 | **All history moves intact,** in D07's order: the workbench, one pilot repo, then the rest. | For each repo, every branch and tag on the forge has the same commit IDs as the old origin before its `origin` is changed. A fresh clone from the forge has the same `main` commit as the old origin. |
| FG-FR-09 | P1 | **Watched from the first boot.** The forge and the runner each have a health file, so the four answers show for both and an alert reaches the phone when either goes down. | Stop the forge's container: the service answer goes down and an alert names `forge` within 10 minutes. The same for the runner. |
| FG-FR-10 | P1 | **No secret in git.** Admin password, runner registration, role tokens and the mirror key live in env files on the machines that use them, never in a repo or in this spec's output. | A scan of every repo and of a sample of the forge's logs finds none. |
| FG-NFR-01 | P1 | **Pinned to the LTS line** (D07). The version is one pinned value, and changing it is the upgrade. | The pin is in one committed place. Changing it and rebuilding gives the new version with the data intact. |
| FG-FR-11 | P2 (OC7) | **No outside gate.** Agents work without hitting a rate limit or a metered service, and find work by git alone. | Block outbound access to github.com. Run 4 agents for an hour, each claiming and completing stories (claim, push branch, pull request, CI result, review, merge). The forge's log shows zero rate-limit responses and zero metered CI minutes, and no list or poll calls for new work. |
| FG-FR-12 | P2 (OC7) | **I can leave any host.** | Clone every repo from the forge and push each to a second host (a throwaway GitHub or Codeberg account). Full history lands intact in under an hour with no conversion. |
| FG-FR-13 | P2 (OC7) | **Only public repos are mirrored out,** to GitHub, for visibility. Nothing is authored there and no Actions run there. | A private repo is absent from the mirror. A repo marked public is present and current within an hour of a push. |
| FG-NFR-02 | P2 (OC7) | **Cheap.** The forge and its off-site copy cost under $10 a month. | The month's bill for the forge and its copy. |

## Homelab scope

**Context:** about a dozen repos, three or four agent roles, one owner, one forge VM and one runner VM.

**Safe shortcuts:** SQLite, not a separate database server; one forge and one runner, no high availability; no email, no single sign-on; the nightly copy, not continuous replication; a Linux runner only, until an outcome ships to Windows (D06); a restore drill instead of a standing standby.

**Never skipped:** `main` is protected and tokens are per role; no secret in git; every clone is a full copy of the history; the runner holds no secret and cannot reach the NAS or Proxmox; the rebuild drill is run, not assumed; the setup script is never fetched from the forge it builds.

**Enterprise habit not to import:** single sign-on and group sync, high availability and a database cluster, audit logging with long retention, and a separate staging forge.

## Decided items

Each is the architect's default; the owner may change any. Two of them correct text already in D07 and OC6, which the owner should accept or reject.

| ID | Question | Decision |
|---|---|---|
| FG-OI-1 | Where does the forge's data live? | On the forge VM's local Proxmox storage. TrueNAS holds the nightly copy only. D07 says "the Forgejo data lives on TrueNAS", which would make the forge run on the NAS; read as the backup location, and the sentence should be amended to say so. |
| FG-OI-2 | How does the nightly copy get to TrueNAS? | TrueNAS fetches it over SSH, read-only, from a dump the forge writes each night to one local folder. The dump is a consistency point, not a backup system, so D07's "the forge never builds its own backup" still holds; TrueNAS decides retention and off-site copies. |
| FG-OI-3 | Database? | SQLite (D07: one container plus a data volume). |
| FG-OI-4 | Does the runner run on the forge VM? | No. It is its own VM: it executes code from pushed branches, so it must hold no secrets and reach no storage, and it must be rebuildable alone. |
| FG-OI-5 | What do jobs run in? | The D06 thin Ubuntu image, as a container on the runner VM, so a job sees the same environment as an agent. |
| FG-OI-6 | Names? | Stack IDs `forge` and `runner`, giving `forge` and `runner` under the home domain by the stack naming rule (SK-FR-04), once that machinery exists. Until then the hostnames are set by hand. |
| FG-OI-7 | Bootstrap, before the stack machinery exists. | The forge and runner VMs are made by hand once from the golden image, with one setup script each. A bootstrap exception, like the monitor's: it ends when the stacks outcome can deploy them. |
| FG-OI-8 | Windows runner? | Not now. It waits until an outcome ships to Windows (D06, D07). |
