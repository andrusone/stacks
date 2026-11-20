# drift

How the homelab measures drift, and fixes it. Every setup script in `stacks/` can say whether its machine still matches what
the script would set up. This folder collects those answers in one log, runs the checks on every Linux VM from your workstation,
and, when you ask, applies the fixes that are safe.

By default it only looks: nothing persistent on a VM changes unless you pass `--apply` or `--push-agent`.

## What is here

| File | What it is |
|---|---|
| `drift-log.sh` | The drift log library. Scripts source it and call `drift_record` to append one JSON line per checking run, optionally tagged with `--stack ID`. It also writes bounded run summaries and the latest run detail. |
| `fleet-check.sh` | The controller, for Linux and WSL. |
| `fleet-check.ps1` | The same controller for a Windows workstation (PowerShell 5.1 or 7). Same options, same log. |
| `fleet-check-remote.sh` | The half that runs **on** a VM. Shipped there by the controller; you do not run it yourself. |
| [`FIXES.md`](FIXES.md) | Every fix, when it is suggested, whether it is **safe**, **unsafe** or **manual**, and why. Read it before using `--apply`. |

## What it automates

1. **Which VMs.** It reads the DNS zone file (`stacks/core/dns/bind/db.core.andrusonline.com`) for every A record named
   `v<env><intent>x<n>`: the Linux VMs. Physical, network and Windows machines are ignored.
2. **Ship and run.** Over ssh it sends a copy of this checkout's `stacks/` to a temp directory on each VM, runs the checks there,
   and removes the directory. Results are therefore measured against *your checkout*: `git pull` first.
3. **Discover stacks.** It reads `/etc/andrusone/stacks/*` and loads each corresponding `stacks/<id>/stack.env`.
   It runs the manifest's `CHECK` and `VERIFY`, compares marker versions with the checkout, and reports missing, unlisted,
   or behind stacks. A VM with no markers and no expected stacks is reported as `os only`.
4. **Check.** It also runs the existing read-only modes: `build-core-node.sh --check` and `--only verify --check` (core
   nodes), the `post-clone-*.sh --only validate` stage, the doctors (`shell-doctor`, `python-doctor`, `dev-doctor`),
   `post-install-baseline-all.sh --check`, `mount-nas.sh --check`, and `git-access.sh --check` when you give a role.
   Manifest-listed stacks also run their `CHECK` and `VERIFY`; Vitals checks its active agent, config, token mode, and
   fresh hub receipt.
5. **Log.** Records come back and are appended to **your local** drift log, marked `"via":"fleet-check@<your machine>"`.
   Each host also gets one summary line (last 60 retained) and a replaced `last-run.jsonl` detail under
   `hosts/<host>/`.
6. **Plan.** Each VM works out the commands that would fix what failed, in order, each classed `safe`, `unsafe` or `manual`.
   Vitals safe convergence is offered only when its checksum-pinned binary and enrolled token are already staged.
   An inactive UFW is a failure; enabling it is offered only as an unsafe fix and verifies the sshd allow rules before
   setting default-deny incoming and enabling the firewall.
7. **Apply (optional).** With `--apply safe|all` it runs those fixes, runs every check again, logs the recheck
   (`"phase":"recheck"`), and reports per machine what was applied, whether the recheck passed and what still needs you.
   A stale marker on a built stack can be adopted through its `--only marker` phase; this does not converge the service.

## VM agent

`vitals agent --once --only drift` runs `fleet-check-remote.sh` from the VM's shipped
`/opt/andrusone/stacks/` copy, so its drift result uses the same checks as a fleet run. It always sets
`FLEET_APPLY=none`, runs niced, allows at most one run at a time, and stops the check after 10 minutes.
The root agent runs privileged checks directly, without requiring `sudo`. Individual scripts have a
nine-minute timeout and a five-second kill grace within that overall limit.
Warnings remain visible without counting as failures; stack-behind, stack-missing, and stack-unlisted
findings each count as one failure.

## How to use it

```powershell
# from Windows, in the network repo
.\stacks\os\common\drift\fleet-check.ps1 -List                              # which VMs it found
.\stacks\os\common\drift\fleet-check.ps1                                    # check every VM, change nothing
.\stacks\os\common\drift\fleet-check.ps1 -Only vpnx1,vpnx2 -GitRole prod -AskSudo
.\stacks\os\common\drift\fleet-check.ps1 -Only vdcx3 -AskSudo -Apply safe   # check, fix the safe things, recheck
```

```bash
# from Linux or WSL
stacks/os/common/drift/fleet-check.sh --list
stacks/os/common/drift/fleet-check.sh --only vpnx1,vpnx2 --git-role prod --ask-sudo
stacks/os/common/drift/fleet-check.sh --only vdcx3 --ask-sudo --apply safe
```

| Option (bash / PowerShell) | Meaning |
|---|---|
| `--only a,b` / `-Only a,b`, `--skip` / `-Skip` | VM short names (`vpnx1`, `vdcx2`, ...) |
| `--list` / `-List` | Print the VMs from the zone file and stop |
| `--git-role ROLE` / `-GitRole ROLE` | `personal`, `prod` or `ai`: also run `git-access.sh --check` with that role. The role is per machine, so it is off unless you say. The core nodes use `prod`. |
| `--ask-sudo` / `-AskSudo` | Ask for the sudo password once, for VMs where `dave` has no passwordless sudo. See below. |
| `--apply safe\|all` / `-Apply safe\|all` | Apply fixes, then recheck. `safe` runs the safe ones; `all` adds the unsafe ones. Manual fixes are never applied. |
| `--push-agent` / `-PushAgent` | Deploy the pinned Vitals binary, agent unit and committed stacks, then run normal checks; cannot be combined with apply. |
| `--binary PATH` / `-Binary PATH` | Controller-local pinned Linux AMD64 binary for push (or `VITALS_BINARY`); no target download or compiler. |
| `--user`, `--domain`, `--zone`, `--key`, `--log` / `-User`, `-Domain`, `-Zone`, `-Key`, `-Log` | ssh user (default `dave`), DNS domain, zone file, ssh key (default `~/.ssh/id_ed25519_github`), log file |
| `-UseZoneIp` (PowerShell) | Connect to the zone file's address instead of the name, for a machine that cannot resolve `core.andrusonline.com` |

Exit code: 0 = every VM reached and nothing failed (after the recheck, when applying); 1 = a VM was unreachable or a check failed;
2 = bad usage.

**Start with one VM and `safe`.** Do the dev VMs first, the service VMs next and the core nodes last.

### Deliver the agent

Owner: build the pinned asset using `tools/vitals/build-release.sh /tmp/vitals-linux-amd64` on a Linux build
controller, and enrol/install each host's token separately. These commands **write to the selected real host**;
agents must not run them against real hosts:

```bash
stacks/os/common/drift/fleet-check.sh --only vdcx1 --push-agent --binary /tmp/vitals-linux-amd64
```

```powershell
.\stacks\os\common\drift\fleet-check.ps1 -Only vdcx1 -PushAgent -Binary C:\cache\vitals-linux-amd64
```

Both controllers check the committed SHA256 pin before SSH; Linux also verifies the local binary's version.
Windows cannot execute a Linux asset, so the target verifies its version before installation. The payload uses
`git archive HEAD stacks`: uncommitted/untracked scripts are not deployed and no git, deploy key, compiler or
token reaches the target. A failed archive extraction or staged stacks copy does not replace the installed tree.
The installed tree is root-owned with no group/other write access; the hash is written to root-owned
`/opt/andrusone/VERSION` only after convergence succeeds. Repeat delivery is idempotent. An existing active Vitals
hub is restarted only if its shared binary was replaced. First delivery skips the immediate receipt gate but
ordinary subsequent fleet checks still report missing/late reports and cause a nonzero fleet exit.

For the first schema-1.1 rollout, deliver to `vpnx1,vpnx2` first so both running hubs accept the additive fields,
then deliver to the remaining VMs. Later rollouts should also update both hubs' baseline with the same commit.

The hub compares the reported commit with its own delivered VERSION, not with a live git remote. `vitals: stacks
copy behind` means a mismatching delivery (the VM missed an update), **not chronological age**. Update the hubs'
delivered baseline as part of each fleet rollout; the VMs never fetch `main`.

### What it needs

- ssh to each VM with this machine's git-access key (`~/.ssh/id_ed25519_github`). On Windows, `git-access.ps1 -Only vms` checks
  and installs that access for every VM; on Linux the key must already be in each VM's `authorized_keys`. A host key that is
  not in `known_hosts` is never trusted: an unknown or changed key counts as unreachable.
- sudo on the VM for the checks that read root-only state. `--ask-sudo` supplies the password without storing it: it lives in
  this script's memory, goes to each VM as the first line of the ssh input (never in a command line or an environment variable),
  and on the VM sits in an unnamed temp file held open by the run. Nothing is installed and no sudoers rule changes. A wrong
  password is tried once per VM, then the root-only checks are skipped.
- Python 3 on the Linux/WSL controller to validate the remote summary record before saving it. The PowerShell controller
  validates the same record with `ConvertFrom-Json`.
- Windows only: `ssh.exe` and `tar.exe` (both ship with Windows), and LF line endings in the checkout (the repo's
  `.gitattributes` does this; the script refuses to run if it finds CRLF).

### What the fixes are

[`FIXES.md`](FIXES.md) is the authority. In short: a fix is **safe** if it has less than a 50% chance of breaking the service the
VM is for (package upgrades, enabling ssh, rewriting the NAS block without remounting), **unsafe** if more (a core-node converge
that would generate a VRRP secret and split the VIP), and **manual** if it needs a person (a Proxmox setting, a reboot,
enabling ufw). Fixes run from the copy shipped with the run, never reboot a VM, and a failed fix is not repeated. While apt is
held by PackageKit or unattended-upgrades, fixes that need it wait up to two minutes and are then **deferred**, not failed.

## The drift log

One JSON line per run of anything that checked something, appended and never rotated:

```json
{"ts":"2026-10-25T14:03:11Z","host":"vpnx1","script":"build-core-node.sh","version":"1.1.1","mode":"check","passed":36,"failed":0,"warned":0,"fixed":0,"failures":[],"user":"root","via":"fleet-check@ppww-dave"}
```

| Field | Meaning |
|---|---|
| `passed`, `failed`, `warned` | Checks that held, that did not, and non-blocking findings |
| `fixed` | Things the run repaired (a `build-core-node.sh` run: changes made; `git-access.sh`: items that had drifted) |
| `mode` | `run`, `check`, `doctor`, `validate`, `plan` (steps a real run would take), `fleet-check` |
| `failures` | Names of the failed checks, first 20 |
| `stack` | Optional stack id supplied with `--stack ID` |
| `via` | Present on records the fleet check collected; absent on a host's own runs |
| `phase` | `recheck` on the pass after `--apply` |

It lives in `/var/lib/drift-log/drift.jsonl` on a host (under `/var/lib`, not `/var/log`, so logrotate never touches it) and in
`~/.local/state/drift-log/drift.jsonl` on your workstation. `DRIFT_LOG=path` overrides both. Example, failures per VM:

```bash
jq -r 'select(.failed > 0) | [.ts,.host,.script,(.failures|join("; "))] | @tsv' ~/.local/state/drift-log/drift.jsonl
```

`drift_run_summary HOST JSON_LINE` appends one controller summary to `hosts/HOST/summary.jsonl`, retaining the last 60
lines by count. `drift_run_detail HOST FILE` atomically replaces `hosts/HOST/last-run.jsonl` with the supplied run detail
file. Both operations take the same per-host lock and place history beside the configured `DRIFT_LOG`.

The summary contains the host verdict (`ok`, `drift`, or `down`), failed/warned/check counts, the marker versions, stacks
behind, scripts with failures, and the run mode (`check` or `apply`). An unreachable VM gets a `down` summary and a synthetic
last-run detail record instead of disappearing from the history.

## Making a script part of this

1. Give it a read-only check and have it call `drift_record SCRIPT VERSION PASSED FAILED --mode check --failures "a|b"` (source
   `drift-log.sh`; it never fails the caller).
2. Add it to `run_checks` in `fleet-check-remote.sh`.
3. For each failure it can report, add a rule to `suggest_fixes` in `fleet-check-remote.sh` (a fix, with a class) or let it fall
   through to the "no fix for this" manual item. Record the reasoning in `FIXES.md`.
4. Add a case to `tests/scripts/test-fleet-apply.sh`.

## Tests

```bash
bash tests/scripts/check-script-versions.sh     # every script has a version and parses; the log writes a good line
bash tests/scripts/test-fleet-apply.sh          # plan, classes, apply, recheck, deferral, both controllers; stubs only
```

The second one uses stub scripts and a fake `sudo`, `systemctl` and `apt-get`, so it touches nothing real. It takes several minutes on
Windows (process spawning), so give it 15.
