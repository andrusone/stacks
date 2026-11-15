# Health: four answers for every stack, and a phone that tells me

**Serves:** workbench:OC8
**Tier:** homelab
**Status:** proposed 2026-11-15

Every stack answers four questions: is its host online and healthy, are its dependencies online and healthy, is the service online and healthy, and is it giving the right answer. This spec says how a stack declares them, where the answers are shown, and who is told when one turns bad. It supersedes the combined dashboard, the drift reporting and the tiered catalog of the `network` repo, which the owner judged too complex and dropped (2026-11-15).

It builds on SK-FR-02 and SK-FR-05 of [SPEC-stacks.md](SPEC-stacks.md): the health check a stack must have is the one defined here. It is deliberately small: four answers, one page, one phone, and a watcher that is itself watched.

## Build or adopt?

The `network` repo already runs two of the right tools, so this spec adopts them and builds almost nothing.

| Need | Adopt | Why | Gap to know about |
|---|---|---|---|
| Is it up, does it answer correctly, alert and recover | Gatus: checks written as one YAML file, a built-in status page, history, many alert targets. Already on both core nodes | the config is text in git, so it can be generated from the stack map | no parent and child suppression: it cannot silence dependents when a dependency fails (HL-FR-08) |
| Host health: processor, memory, disk, containers | Beszel: a small hub and one tiny agent per VM, threshold alerts. Already on the core nodes | the agent goes into the base template, so every VM has it from birth | one hub per core node, enrolled by hand today |
| Alert delivery to the phone | ntfy: already how the core nodes alert | nothing new to run | the topic name is a secret (HL-NFR-02) |
| Is the watcher alive | a free outside heartbeat service (for example Healthchecks.io), pinged by the monitor | the only check that survives the whole house being down | an outside service, so nothing private goes in its messages |

Considered and not chosen: Uptime Kuma (settings live in a database and a UI, not in git, which fights "a stack from a commit"); Prometheus with Alertmanager and Grafana (the usual answer, and far more machinery than four questions need); Zabbix (closest to SCOM in spirit, and just as heavy); Checkmk Raw (the nearest free thing to SCOM, with discovery; the fallback if the adopted tools prove too hand-built). The one program we write is the generator that turns the stack map into Gatus and Beszel configuration.

## Abandoned, not migrated

The owner has dropped the combined dashboard, drift reporting, the tiered service catalog, the capacity header, and the custom health agent and hub (Vitals). Nothing in this spec carries them forward, maintains them, removes them or edits the `network` repo that holds them. They are simply not part of what is built from here on. While they still run on a host they may raise their own alerts; that is not this spec's concern.

The core DNS nodes keep running Gatus and Beszel, and the Proxmox host and the NAS keep their current health collectors until the owner decides (HL-OI-6).

## Requirements

All requirements are **P1**, needed for the check of the outcome. The stack map's `health` entry (HL-FR-06) is the contract.

| ID | P | Requirement | Acceptance |
|---|---|---|---|
| HL-FR-01 | P1 | **Four answers per stack.** One page shows, for every stack, four answers, each up or down with when it last changed: the host, its dependencies, the service, and the right answer. | With `smoke` and `smoke-b` deployed, the page lists both with four answers each, all up. Breaking one thing (HL-FR-02 to 05) turns only the answer that thing belongs to, and the answers that truly depend on it. |
| HL-FR-02 | P1 | **Host online and healthy.** The host answer is down when the machine does not answer on the network, or its disk, memory or processor stays over its limit. The limits are defaults the owner can edit: disk over 85 percent, memory over 90 percent, processor over 90 percent for 10 minutes. | Stop the VM, then fill its disk past the limit, one at a time: each turns the host answer down within 10 minutes and says which reason. |
| HL-FR-03 | P1 | **Dependencies online and healthy.** A stack declares what it needs (another stack, the core DNS, the file server). Its dependency answer is down when any of them is down, and names which. | Stop `smoke`: `smoke-b`'s dependency answer goes down within 5 minutes and names `smoke`. |
| HL-FR-04 | P1 | **Service online and healthy.** The service answer is down when its real address and port do not accept a connection, or when its containers do not report healthy. | With the VM running, stop `smoke`'s container: the service answer goes down within 5 minutes and the host answer stays up. |
| HL-FR-05 | P1 | **Right answer.** A stack declares one request and what a correct reply contains (a status, a piece of text, or a field). The answer is down when the reply is wrong, even though connecting works. | Make `smoke` accept connections but return a wrong reply: only the right-answer answer goes down, within 5 minutes. |
| HL-FR-06 | P1 | **Declared with the stack** (contract: a `health` entry in the stack map). The entry names the dependencies and the request and correct reply. Adding a stack adds its four answers, removing it removes them, with no separate monitoring step. A stack with no `health` entry is rejected before anything changes (SK-FR-02). | Add `smoke`: its four answers appear within the ten minutes of SK-FR-08. Delete the entry: they disappear. An entry without `health` fails the map check. |
| HL-FR-07 | P1 | **A bad answer reaches the phone.** An answer that stays down sends one alert naming the stack, which of the four, and since when, then one recovery notice. A fault left in place sends no more than one reminder an hour. | Break each of the four in turn: one alert each within 10 minutes naming the stack and the answer. Undo each: one recovery within 10 minutes. Leave one fault for two hours: at most two reminders. |
| HL-FR-08 | P1 | **Cause first, no storm.** A dependency that other stacks share alerts once, from its own stack, not once per stack that uses it. When a host dies, the alert for the host comes before the alerts for the answers that depend on it. | Stop `smoke`: `smoke-b`'s dependency answer is down on the page but sends no alert of its own. Stop `smoke`'s VM: the first alert names the host. |
| HL-FR-09 | P1 | **The watcher is watched.** If monitoring stops, the owner hears within 15 minutes, by a path that does not go through the machines being monitored. | Stop the monitor: a message arrives within 15 minutes. Start it: a recovery arrives. |
| HL-FR-10 | P1 | **Unknown is never up.** A check that cannot run, hangs, or has gone silent shows as unknown or down, never as up. | Stop only the host-metrics agent on a VM: the host answer shows unknown within 10 minutes, never up. A probe that hangs counts as a failure. |
| HL-NFR-01 | P1 | **No monitoring software of our own.** Only maintained, existing tools are configured. The only code written for this is the generator from the stack map. | A search of the stacks repo finds no monitoring agent or hub source, and the generator is one program. |
| HL-NFR-02 | P1 | **Secrets stay out.** The phone topic and any token are never in git, in alert text, or on the status page. | A scan of the repos and a sample of alerts find none. |

## Homelab scope

**Context:** about a dozen VMs in one house, read by two people, alerts to one phone.

**Safe shortcuts:** a single page, with Gatus's short history and no long-term metrics store or error budgets; checks run every minute; one phone and one topic per core node; a dying host may send several alerts as long as the first names the cause; no on-call, no escalation, no maintenance calendar.

**Never skipped:** a check that hangs counts as a failure; a silent source is unknown, never up (HL-FR-10); no secret in config, alert or page (HL-NFR-02); the watcher is watched from outside (HL-FR-09).

**Enterprise habit not to import:** service-level objectives and reporting, a configuration database for the catalog, per-service ownership and escalation, and keeping every reading for audit.

## Decided items

The owner decided HL-OI-1 on 2026-11-15. The others are defaults the owner may change.

| ID | Question | Decision |
|---|---|---|
| HL-OI-1 | Keep or retire the custom health agent and hub (Vitals)? | **Retired (owner, 2026-11-15).** It was too complex, and Gatus plus Beszel cover the four questions. What is given up: the listener-against-firewall-rule check, the per-name DNS check, and drift, none of which is one of the four questions. Nothing here migrates or removes it, and the `network` repo is not touched. |
| HL-OI-2 | Where do the checks run? | On the two core nodes, where Gatus and Beszel already run, as two independent copies. Checks use addresses, not names, so a DNS failure cannot blind them. The outside heartbeat covers the case where both nodes are down. No new VM. |
| HL-OI-3 | How is the phone told? | ntfy, one topic per node, as the core nodes already do. The outside heartbeat service emails when pings stop. |
| HL-OI-4 | How is host health collected? | A Beszel agent in the base template, so a new VM has it from its first boot. Everything else is checked from outside by Gatus. |
| HL-OI-5 | What about stacks that exist today and are installed natively? | They get the same four answers when they join the stack map. OC8's check covers new stacks only. |
| HL-OI-6 | The Proxmox host and the NAS? | Left as they are for now: not part of OC8. The owner decides later whether they join the same four answers. |
