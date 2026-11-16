# Health: four answers for every stack, and a phone that tells me

**Serves:** workbench:OC8
**Tier:** homelab
**Status:** proposed 2026-11-15

Every stack answers four questions: is its host online and healthy, are its dependencies online and healthy, is the service online and healthy, and is it giving the right answer. This spec says how a stack declares them, where the answers are shown, and who is told when one turns bad. It supersedes the combined dashboard, the drift reporting and the tiered catalog of the `network` repo, which the owner judged too complex and dropped (2026-11-15).

**The monitor comes first.** It is up, watched and able to alert before any stack is deployed, including DNS and the forge. A stack is added to something already watching, never the other way round. So this spec does not need the stack map: a stack declares its checks in a small file of its own in git (HL-FR-06), and the stack map of [SPEC-stacks.md](SPEC-stacks.md) later points at that file.

It is deliberately small: four answers, one page, one phone, and a watcher that is itself watched.

## Build or adopt?

The `network` repo already runs two of the right tools, so this spec adopts them and builds almost nothing.

| Need | Adopt | Why | Gap to know about |
|---|---|---|---|
| Is it up, does it answer correctly, alert and recover | Gatus: checks written as one YAML file, a built-in status page, history, many alert targets. Already run on the core nodes today; this spec moves them into a stack of their own (HL-OI-2) | the config is text in git, so it can be generated from the health files | no parent and child suppression: it cannot silence dependents when a dependency fails (HL-FR-08) |
| Host health: processor, memory, disk | Beszel: a small hub and one tiny agent per VM, threshold alerts. Already run on the core nodes today | one small agent per VM, nothing to query | one hub, enrolled by hand |
| Alert delivery to the phone | ntfy: already how the core nodes alert | nothing new to run | the topic name is a secret (HL-NFR-02) |
| Is the watcher alive | a free outside heartbeat service (for example Healthchecks.io), pinged by the monitor | the only check that survives the whole house being down | an outside service, so nothing private goes in its messages |

Considered and not chosen: Uptime Kuma (settings live in a database and a UI, not in git); Prometheus with Alertmanager and Grafana (the usual answer, and far more machinery than four questions need); Zabbix (closest to SCOM in spirit, and just as heavy); Checkmk Raw (the nearest free thing to SCOM, with discovery; the fallback if the adopted tools prove too hand-built). The one program we write is the generator that turns the health files into Gatus and Beszel configuration.

## Abandoned, not migrated

The owner has dropped the combined dashboard, drift reporting, the tiered service catalog, the capacity header, and the custom health agent and hub (Vitals). Nothing in this spec carries them forward, maintains them, removes them or edits the `network` repo that holds them. While they still run on a host they may raise their own alerts; that is not this spec's concern. The new checks alert on their own topic so the two can be told apart.

The Proxmox host and the NAS keep their current health collectors until the owner decides (HL-OI-6).

## Requirements

All requirements are **P1**, needed for the check of the outcome (HL-FR-15 to HL-FR-18 are the one-way dependency rules the owner asked for on 2026-11-15), except HL-FR-12, which applies once a deploy command exists. The health file of a stack (HL-FR-06) is the contract.

| ID | P | Requirement | Acceptance |
|---|---|---|---|
| HL-FR-01 | P1 | **Four answers per stack.** One page shows, for every stack, four answers, each up or down with when it last changed: the host, its dependencies, the service, and the right answer. | With two test targets `probe-a` and `probe-b` declared, the page lists both with four answers each, all up. Breaking one thing (HL-FR-02 to 05) turns only the answer that thing belongs to, and the answers that truly depend on it. |
| HL-FR-02 | P1 | **Host online and healthy.** The host answer is down when the machine does not answer on the network, or its disk, memory or processor stays over its limit. The limits are defaults the owner can edit: disk over 85 percent, memory over 90 percent, processor over 90 percent for 10 minutes. A host with no metrics agent shows online with health unknown (HL-FR-10). | Stop the VM, then fill its disk past the limit, one at a time: each turns the host answer down within 10 minutes and says which reason. |
| HL-FR-03 | P1 | **Dependencies online and healthy.** A stack declares what it needs (another stack, the core DNS, the file server). Its dependency answer is down when any of them is down, and names which. | Stop `probe-a`: `probe-b`'s dependency answer goes down within 5 minutes and names `probe-a`. |
| HL-FR-04 | P1 | **Service online and healthy.** The service answer is down when its real address and port do not accept a connection, or when its containers do not report healthy. | With the VM running, stop `probe-a`'s container: the service answer goes down within 5 minutes and the host answer stays up. |
| HL-FR-05 | P1 | **Right answer.** A stack declares one request and what a correct reply contains (a status, a piece of text, or a field). The answer is down when the reply is wrong, even though connecting works. | Make `probe-a` accept connections but return a wrong reply: only the right-answer answer goes down, within 5 minutes. |
| HL-FR-06 | P1 | **Declared in git, one file per stack** (contract: a file named for the stack ID in the `health` folder of the stacks repo). It names the host, the dependencies, and the request and correct reply. Adding a file adds the four answers and removing it removes them. A file missing any part fails `mise run check` before anything changes. | Add a file for a test target: its four answers appear within the ten minutes of HL-FR-13. Delete it: they disappear. A file without a dependency list or a correct reply fails the check. |
| HL-FR-07 | P1 | **A bad answer reaches the phone.** An answer that stays down sends one alert naming the stack, which of the four, and since when, then one recovery notice. A fault left in place sends no more than one reminder an hour. | Break each of the four in turn: one alert each within 10 minutes naming the stack and the answer. Undo each: one recovery within 10 minutes. Leave one fault for two hours: at most two reminders. |
| HL-FR-08 | P1 | **Cause first, no storm.** A dependency that other stacks share alerts once, from its own stack, not once per stack that uses it. When a host dies, the alert for the host comes before the alerts for the answers that depend on it. | Stop `probe-a`: `probe-b`'s dependency answer is down on the page but sends no alert of its own. Stop `probe-a`'s VM: the first alert names the host. |
| HL-FR-09 | P1 | **The watcher is watched.** If monitoring stops, the owner hears within 15 minutes, by a path that does not go through the machines being monitored. | Stop the monitor: a message arrives within 15 minutes. Start it: a recovery arrives. |
| HL-FR-10 | P1 | **Unknown is never up.** A check that cannot run, hangs, or has gone silent shows as unknown or down, never as up. | Stop only the host-metrics agent on a VM: the host health shows unknown within 10 minutes, never up. A probe that hangs counts as a failure. |
| HL-FR-11 | P1 | **The monitor stands first and alone.** The monitor is a stack of its own: one VM with no other service in it, needing no other stack and no DNS to run; its storage is a declared need like any service's. It is up, with its alert path proven, before any other stack is declared. | With no other stack declared: the page loads and a test message reaches the phone. Then block the VM's access to the core DNS addresses and stop every other stack: the page still loads, checks still run, and a test message still reaches the phone. |
| HL-FR-12 | P2 | **No stack goes up unmonitored.** The deploy command refuses to deploy a stack unless the monitor is up and the stack has its health file. | With the monitor stopped, a deploy of a test stack is refused with a message naming the monitor. With it running and the file present, the deploy proceeds. |
| HL-FR-13 | P1 | **Config reaches the monitor from git.** A change to a health file changes the running checks within 10 minutes, with nobody logging in to a host. A bad file never blinds the monitor: it keeps its last good checks and an alert says the new file was rejected. | Push a new file: its answers appear within 10 minutes. Push its removal: they go. Push a broken file: the old checks keep running and an alert names the file. |
| HL-FR-14 | P1 | **Rebuild alone.** If the monitor VM is lost, a new VM, the setup script and the restored hub key bring it back with nothing else touched. The checks return from git by themselves. | Delete the monitor VM. Create a new one from the golden image, run the script, restore the hub key: within 30 minutes the page shows every declared stack and the outside heartbeat is green. No other stack, host or file was changed. |
| HL-FR-15 | P1 | **No circular dependencies.** The dependencies the health files declare form no cycle, and the monitor appears in none of them. | Two health files that name each other fail `mise run check`, naming both. A health file that lists the monitor as a dependency fails it. |
| HL-FR-16 | P1 | **Every dependency is one-way, declared and typed.** Each entry in a health file's dependency list names one thing (another stack, a host, the NAS, DNS), says whether it is **hard** (the service is down without it) or **soft** (it keeps working, reduced), and gives one line of reason. A hard dependency that is down makes the dependency answer down and names it; a soft one that is down makes it degraded and names it. A health file with an entry missing its type or reason fails `mise run check`. | Declare `probe-b` with a hard need on `probe-a` and a soft need on `probe-c`. Stop `probe-a`: the dependency answer goes down and names `probe-a`. Restart it and stop `probe-c`: the answer is degraded and names `probe-c`. An entry without a type fails the check. |
| HL-FR-17 | P1 | **A service runs with only what it declares.** The declared needs are the complete list. Everything not declared can be stopped without the service noticing. | For a test stack, stop every other stack and block every address it did not declare, except the monitor's own checks: its four answers stay up. A stack that fails this has an undeclared dependency, and the fix is to declare it (or remove the use), not to hide it. |
| HL-FR-18 | P1 | **The map of who needs whom is generated, never written.** One page and one text file, built from the health files, list for every service what it needs (hard and soft) and, derived from everyone else's lists, what needs it. "Needed by" is never hand-written anywhere. | Add `probe-b` needing `probe-a`: both files show `probe-b` under `probe-a`'s "needed by" within 10 minutes, with no other edit. Removing the health file removes it from both. |
| HL-FR-19 | P1 | **First build on a real Linux VM.** On a plain Ubuntu Server VM the owner made by hand (SSH, a user with sudo, nothing else), `sudo ./setup.sh` in the stacks checkout brings the monitor up. It checks what is there, has mise install every tool in the repo's mise tool list, and does itself only what mise cannot: the Docker engine and compose plugin, the service user, the folders, and restart on boot. It reads every value that varies from one env file, `compose/monitor/.env`, kept out of git (HL-NFR-02) and copied from `compose/monitor/.env.example`, one comment per value. The monitor is then started and restarted by `docker compose -f compose/monitor/docker-compose.yml up -d` alone, with Gatus's page and ntfy bound to the address in the env file. A starter health file for a throwaway target, in the same compose file, makes the page show its answers on the first start. **MVP 1** is HL-FR-01 to 07 on a local machine. **MVP 2** is this requirement. Not in MVP 2: Beszel (the host answer stays a network check with health unknown, HL-FR-10; Beszel needs a hub key enrolled by hand and an agent on every VM, so it is a later rung, written from friction), the pull timer (HL-FR-13), the outside heartbeat (HL-FR-09), rebuild alone (HL-FR-14), bad-commit protection and the one-way rules (HL-FR-15 to 17). The phone is one runbook line: install the ntfy app and subscribe to the topic URL. | **MVP 2:** On a fresh Ubuntu Server VM, `sudo ./setup.sh` after filling `compose/monitor/.env` ends with exit 0; a second run reports `changes: 0`; `docker compose -f compose/monitor/docker-compose.yml up -d` then shows Gatus's page, reached by browser at the bind address, listing the starter target with its answers up (host, service and right answer; the dependency answer exists only for a stack whose file declares a need, so the starter, which declares none, shows three); ntfy answers on its port; after a reboot both come back by themselves. A scan of the repo finds no topic value. |
| HL-NFR-01 | P1 | **No monitoring software of our own.** Only maintained, existing tools are configured. The only code written for this is the generator from the health files. | A search of the stacks repo finds no monitoring agent or hub source, and the generator is one program. |
| HL-NFR-02 | P1 | **Secrets stay out.** The phone topic and any token are never in git, in alert text, or on the status page. | A scan of the repos and a sample of alerts find none. |

## Boundaries

What the monitor owns, what it needs and what it never needs. A stack that breaks any of these lines breaks the rebuild-alone promise (HL-FR-14).

| | |
|---|---|
| **Owns** | its one VM and the small data on it: the hub key and the short history. Its checks are not owned data: they are generated from git. Its alert topic. |
| **Needs, hard** | the Proxmox host (compute and local disk) and a network path to what it watches. |
| **Needs, soft** (it keeps working without them) | the git remote to pull new checks (it keeps its last good checks, HL-FR-13); the phone alert service and the outside heartbeat (an alert path down is itself visible through the other). |
| **Never needs** | the core DNS (checks use addresses), the forge to run, any stack it watches. |
| **Needed by** | nothing, except one deliberate case: the deploy command refuses to deploy a stack while the monitor is down (HL-FR-12). |

## Homelab scope

**Context:** about a dozen VMs in one house, read by two people, alerts to one phone; the monitor is one small VM.

**Safe shortcuts:** a single page, with Gatus's short history and no long-term metrics store or error budgets; checks run every minute; one phone and one topic; a dying host may send several alerts as long as the first names the cause; no on-call, no escalation, no maintenance calendar.

**Never skipped:** a check that hangs counts as a failure; a silent source is unknown, never up (HL-FR-10); no secret in config, alert or page (HL-NFR-02); the watcher is watched from outside (HL-FR-09); a bad commit never blinds the monitor (HL-FR-13).

**Enterprise habit not to import:** service-level objectives and reporting, a configuration database for the catalog, per-service ownership and escalation, and keeping every reading for audit.

## Decided items

The owner decided HL-OI-1 and the order (monitor first) on 2026-11-15. The others are defaults the owner may change.

| ID | Question | Decision |
|---|---|---|
| HL-OI-1 | Keep or retire the custom health agent and hub (Vitals)? | **Retired (owner, 2026-11-15).** It was too complex, and Gatus plus Beszel cover the four questions. What is given up: the listener-against-firewall-rule check, the per-name DNS check, and drift, none of which is one of the four questions. Nothing here migrates or removes it, and the `network` repo is not touched. |
| HL-OI-2 | Where does the monitor run? | As a stack of its own, by the standard pattern: one VM, Docker, one compose file, its storage declared as a need, with Gatus and the Beszel hub in it. One VM, not two: a second copy would only add something to keep in step. The outside heartbeat is the second line: if the monitor or its whole host goes down, the owner hears within 15 minutes (HL-FR-09), and rebuilding takes minutes (HL-FR-14). Checks use addresses, not names, so a DNS failure cannot blind it. The core DNS nodes stop being the monitor host; they are not touched here and keep their old Gatus and Beszel until the owner removes them. Because the monitor must exist before the stack machinery does, the VM is made by hand once from the golden image, a bootstrap exception that ends when the stacks outcome can deploy it. A second copy can be added later if the owner wants one. |
| HL-OI-3 | How is the phone told? | ntfy, one topic, separate from the old alerts. The outside heartbeat service emails when pings stop. |
| HL-OI-4 | How does a new VM get a metrics agent? | By whatever creates the VM: the base template once it exists (a template story of the stacks outcome). Until a VM has one, its host answer is online with health unknown, never up (HL-FR-02, HL-FR-10). Nothing here waits for the template. |
| HL-OI-5 | How do config changes reach the monitor? | The monitor pulls the stacks repo on a timer and regenerates its checks (HL-FR-13). No push, no SSH, no deploy step. |
| HL-OI-6 | The Proxmox host and the NAS? | Left as they are for now: not part of OC8. The owner decides later whether they join the same four answers. |
| HL-OI-7 | What about stacks that exist today and are installed natively? | They get the same four answers when someone writes a health file for them. OC8's check covers the two test targets only. |
| HL-OI-8 | The first real stacks, DNS and the forge? | Each declares a health file like any other, so it is watched from its first boot: for DNS the right answer is resolving a known name to its address by asking the stack's own address; for the forge, its web reply and a successful git listing. They are checked in those stacks' own outcomes, not here. |
