# Runbook order: the four VMs, in the order to build them

Build the VMs in this order. Each section says what the VM needs first and which runbook holds the steps. This page copies no steps: if a step changes in a runbook, that runbook is right.

Start every VM from the golden image ([REF-golden-image.md](REF-golden-image.md)).

## 0. Name and address each VM first

Before any VM's first clone, name it and give it its fixed address with `hostbook` (see [RUNBOOK-monitor.md](RUNBOOK-monitor.md) section 1). Write the address down: the monitor and the DNS node need it.

## 1. Once, from any VM with the share mounted: `host/nas-layout.sh`

Clone the repo first ([RUNBOOK-host.md](RUNBOOK-host.md) step 1), then run `./host/nas-layout.sh` once from the clone. It makes the NAS folders the forge and the monitor back up to, so they must exist before those VMs run their backups. It needs the TrueNAS share mounted, which the golden image does.

**The NAS clone must be current.** The VMs clone the repo from `/nas/projects/andrusone/stacks`, so that clone must be on `main` and up to date before any VM's first clone. Until the owner schedules a refresh, run it by hand on the Linux machine that holds the share: `git -C /nas/projects/andrusone/stacks pull --ff-only` (git, on that machine). The monitor then pulls from GitHub itself once its deploy key is in ([RUNBOOK-monitor.md](RUNBOOK-monitor.md) section 2).

On the monitor page: no VM comes up in this step, so nothing new shows.

## 2. The monitor

It needs nothing, not even DNS. Its steps, including the six values in `compose/monitor/.env`, are in [RUNBOOK-monitor.md](RUNBOOK-monitor.md). Its state backup runs nightly once the NAS folder exists ([RUNBOOK-monitor.md](RUNBOOK-monitor.md) section 4c).

On the monitor page: open `http://<MONITOR_BIND>:<GATUS_PORT>`. Within 2 minutes it lists the `starter` target with host, service and right answer up. Each later stack shows here once it has a health file.

## 3. The DNS node

It needs the zone, by one of two routes:

- the zone by NAS path, or
- for a `git@` zone URL, the node's read-only deploy key for `andrusone/zone` ([RUNBOOK-core.md](RUNBOOK-core.md) section 3b).

Set its own resolver first ([RUNBOOK-core.md](RUNBOOK-core.md) section 3), then run its setup and prove it from a LAN client (section 5). The cutover in section 6 of that runbook is the owner's own step, and it is not part of building the node.

On the monitor page: the `core` stack's four answers from `health/core.toml`. Its right answer is a real DNS lookup of a known host against the node's own address.

## 4. The forge

Its URL is its name, `forge.core.andrusonline.com`, so the DNS node from step 3 comes first. If the forge must come up before DNS, use its address instead and edit every clone later. The name is added with `hostbook` (host and alias `forge`) before the first clone.

It needs its data disk, formatted and mounted at `/data` by you ([RUNBOOK-forge.md](RUNBOOK-forge.md) section 3), and the repo sent to it as a bundle ([RUNBOOK-forge.md](RUNBOOK-forge.md) section 2). Set `FORGE_URL` to its name at the setup's question ([RUNBOOK-forge.md](RUNBOOK-forge.md) section 4a).

On the monitor page: no health file yet. `health/forge.toml` is not in the repo; the forge's first setup run writes it ([RUNBOOK-forge.md](RUNBOOK-forge.md) section 4c).

## 5. The runner

It needs the forge from step 4 up, and a one-time runner registration token that you make on the forge's page ([RUNBOOK-forge.md](RUNBOOK-forge.md) section 5). The runner cannot reach the NAS, so it gets its repo as a bundle ([RUNBOOK-forge.md](RUNBOOK-forge.md) section 6).

On the monitor page: no health file yet. `health/runner.toml` is not in the repo; the runner's first setup run writes it ([RUNBOOK-forge.md](RUNBOOK-forge.md) section 6).

## 6. The repository move

Not built yet. Moving the repos to the forge with their full history is OC6's third rung (FG-FR-08). It needs the forge and the runner from steps 4 and 5 running. There is no runbook for it yet, so there is no step to follow here.

On the monitor page: nothing new; no VM comes up in this step.
