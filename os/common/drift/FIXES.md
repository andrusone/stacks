# Fleet-check fixes: what each one does and why it is classed as it is

`fleet-check --apply safe|all` (PowerShell: `-Apply safe|all`) applies the fixes below, in order, then runs every
check again. Each VM works out its own list from what its checks found (`suggest_fixes` in
`fleet-check-remote.sh`); a fix that is not needed is not suggested.

## The rule

| Class | Meaning | Applied by |
|---|---|---|
| **safe** | Less than a 50% chance of breaking the service the VM is for. Changing management automation (the drift log, `~/.andrusone`, timers, MOTD) is not a break. | `--apply safe`, `--apply all` |
| **unsafe** | More than a 50% chance of breaking that service (DNS no longer resolving, the VIP split between two nodes, being locked out). | `--apply all` only |
| **manual** | Needs a person, a decision, or something outside the VM. Never applied; always listed under "still to do". | never |

A fix is judged by what it does to the service *as it runs*, not by whether it is intrusive. Where one script can do
both safe and unsafe things (`build-core-node.sh`), the class is that of the worst step it plans on that machine.
Fixes run from the copy of `stacks/` shipped with the run, so what is applied is exactly the version that was checked.
Nothing here reboots a VM or removes a package. Enabling an inactive firewall is unsafe and is offered only by fix 99.

## Safe

| # | Fix | Suggested when | Why it is safe |
|---|---|---|---|
| 10 | `git -C <checkout> pull --ff-only` (sudo on the core nodes' root-owned clone) | a fix is suggested and the host's checkout is not on the commit fleet-check ran from | Fast-forward only: it fails harmlessly on local changes and restarts nothing. Replacing a zone file from git is the same kind of change. |
| 20 | `git-access.sh --role R` | the `git-access` check found drift | Copies the script and `drift-log.sh` to `~/.andrusone`, repairs alias and ssh config in the user's home. No terminal, so it skips installs and prompts. Touches no service. |
| 30 | `apt-get update && apt-get -y --with-new-pkgs upgrade` | packages are upgradable | Does what `unattended-upgrades` does every day: never removes a package, never reboots (`NEEDRESTART_MODE=l` only lists restarts). A daemon being upgraded restarts for a second; that is a blip, not a break. |
| 40 | `post-install-baseline-all.sh` with `SKIP_SMB=1` | a baseline check failed that has no smaller fix | Converges apt periodic settings, journald limits, logrotate (validated before it is kept) and timers. It runs `full-upgrade`, which could remove a package; rare. |
| 35 | `rm -f <dir>/NAME.list` | a repository is configured both as `NAME.list` and `NAME.sources` | The `.sources` file (same URI, same key) stays; the duplicate only makes apt warn on every update. |
| 41 | `apt-get install -y <package>` | a baseline or validate check says a package is missing | Adds a package. |
| 42 | `systemctl enable --now ssh` | ssh is running but not enabled at boot | Only adds boot-time enablement. |
| 43 | `ufw allow N/tcp comment SSH` | no ufw rule for the sshd port | Adds an allow rule; it does not enable ufw. |
| 44 | `systemctl enable --now qemu-guest-agent` | the agent's virtio device is present but the service is not active | Installs boot-time enablement and starts the guest helper. |
| 50 | `mount-nas.sh --yes --no-remount` | the NAS credentials, fstab block or automounts differ | Writes the credentials file, mount points and the managed fstab block with the stored credentials. Shares listed by an installed service's `RequiresMountsFor` have no idle-unmount timeout; other shares use 600 seconds, so the old 60-second default no longer stops a quiet service. **Live mounts are left alone**, so Plex, qBittorrent and Docker keep their open files; changed options (including the `nas` group and the 0664/0775 modes) apply at the next remount or reboot. (Without `--no-remount`, `mount-nas.sh` lazily unmounts and remounts every share, which would be unsafe on a host using `/nas`.) |
| 60 | `bootstrap-shell.sh` | the shell doctor is missing, failing, or predates the drift log | User-level tooling (zsh, Starship, fzf, rc blocks). The login shell is already zsh. Touches no service. |
| 61, 62 | `dev-python/bootstrap-python-dev.sh`, `bootstrap-wails-dev.sh` | a dev doctor is failing or predates the drift log | Installs toolchains under `/usr/local` and the user's home, plus apt packages. These are dev boxes with no service to break. Takes minutes. |
| 70 | `post-clone-<kind>.sh --only polish` | editor, MOTD, NTP config or locale differ | Sets the default editor, locale, MOTD scripts and chrony's server list (restarting chrony). If the core nodes' NTP were down the clock would free-run, which breaks nothing. |
| 75 | `post-clone-<kind>.sh --only zero` | the daily zero-free-space job is not installed, or its unit is the broken one (see below) | Installs the script and a timer; nothing runs until the next scheduled time (03:30 plus up to 45 minutes). The job leaves 1 GiB free and runs at idle I/O priority. |
| 76 | `systemctl reset-failed zero-free-space.service` | after 75, when that unit was failed | Clears a failed state whose cause (below) has just been removed. |
| 80 | `build-core-node.sh` (when its plan has no unsafe step) | a core node's `--check` plans changes or `verify` fails | Helper scripts, peer firewall allows, and service configs that pass their own validation gates (`named-checkconf`, `haproxy -c`, `systemd-analyze verify`). Starting keepalived on a node that already has the shared secret makes it a BACKUP; the VIP only fronts the Dashboard, never DNS. |
| 85 | `build-<stack>-node.sh --only marker` | a built stack's marker is missing or behind its manifest's converge script | Writes only the stack metadata marker through that stack's own marker phase; it does not converge or restart services. Offered only for `KIND=built` manifests. |
| 86 | `build-vitals-node.sh --binary /var/cache/vitals/vitals-linux-amd64 --restart` | the Vitals check fails or its marker is missing, and the pinned binary and enrolled token are already staged | Installs only the checksum-verified observer, enables or restarts only `vitals-agent.service`, refreshes its shipped read-only stack copy, and writes its marker. It changes no monitored service. |
| 90 | `systemctl mask --now motd-news.timer`, then `systemctl mask --now motd-news.service` + `reset-failed` | `motd-news.service` or its timer is failed | The image deliberately makes its script non-executable, so the unit can only fail. Masking the timer first prevents it from triggering a service while that service is being masked. |

## Unsafe

| # | Fix | Suggested when | Why it is unsafe |
|---|---|---|---|
| 80 | `build-core-node.sh` | its plan includes `generate VRRP auth secret`, `ufw default ...`, `ufw enable` or `regenerate SSH host keys` | A VRRP secret generated on one node cannot match the peer's, so both nodes claim the VIP. ufw's default-deny or new SSH host keys can lock you out of the node. More likely than not to break something. |
| 99 | `ENABLE_UFW=1 post-install-baseline-all.sh --only firewall` | ufw is inactive | Enables default-deny incoming, which can block services. The firewall-only baseline path first stages and verifies allow rules for every effective sshd port, then sets the default and enables ufw. Only `--apply all` runs it. |

No other fix is currently unsafe: anything that was is either made safe by how it is run (50, 85) or is manual.

## Manual (never applied)

| # | Item | Suggested when | Why it needs you |
|---|---|---|---|
| 10 | `git clone` the network repo | the host has no checkout | Where to put it is your call. |
| 21 | `git config --global user.name/email` | git identity is not set | It cannot choose your identity. |
| 87 | Stage the pinned Vitals binary and install an enrolled host token | the Vitals stack is missing or unhealthy and safe convergence prerequisites are absent | The binary is a local owner-supplied artifact and the token is host-specific. Neither is downloaded or created by fleet-check. |
| 91 | Read `journalctl -b -p err` | error-priority journal entries since boot | They stay until the next reboot; a person decides if they matter. |
| 92, 93 | `systemctl status`/`journalctl -u X`, then `reset-failed X` | a failed unit other than `motd-news` | Clearing a failed state hides the failure until the next run; someone has to say why it failed. (`zero-free-space.service` is failed on six VMs and no fix is automatic.) |
| 94 | Enable the QEMU guest agent in Proxmox, then restart the VM | the agent's virtio serial channel is missing inside the VM | The setting is on the hypervisor. |
| 95 | `dpkg --configure -a && apt-get -f install` | dpkg or apt report a problem | `-f install` can remove packages. |
| 96 | `investigate: <text>` | the validate stage reports something no rule covers | So nothing is silently ignored. |
| 97 | `systemctl reboot` | `/var/run/reboot-required` exists | A reboot is a certain outage; pick the time. |
| 98 | Check the storage under the VM | the kernel logged disk I/O errors this boot | Not fixable from inside the VM (seen on `vpcx2`: ATA timeouts and swap read/write errors). |

## Not offered at all

Rebooting, removing packages, trusting a new host key, `gh auth login`, registering a key with GitHub,
changing a hostname or IP. Each is either an outage by definition or needs a person.
The `monitor` stack also has no fleet-applied fix: its local pinned binary, enrolled host tokens, Gatus endpoints and
restricted hub firewall require an owner-run converge.

## After applying

The recheck runs every check again and its records go in the drift log marked `"phase":"recheck"`, so drift before and
after a fix can be compared. "Still to do" is computed from the recheck, not from the first pass.

## Things the first real apply run taught us

- **`zero-free-space.service` could never succeed, on any VM.** The unit wrapped the script in
  `flock -n /run/zero-free-space.lock`, and the script then takes `flock -n` on the same file itself, so it always exited
  "another run is already active" and the unit showed as failed every night. The unit also used `ConditionPathIsExecutable=`,
  which does not exist (the directive is `ConditionFileIsExecutable=`), so systemd logged "Unknown key" on every reload.
  `post-clone-server.sh` and `post-clone-desktop.sh` 1.1.0 write a corrected unit; fixes 75 and 76 apply it to a VM whose
  unit still has the old text. **The job has therefore never run**: after the fix, its first run is the next 03:30 (plus up
  to 45 minutes), where it writes zeros until 1 GiB is free on each local filesystem.
- **A busy apt is not a fault.** On the desktop VMs PackageKit or unattended-upgrades often hold apt's lock for minutes;
  `dpkg --audit` and `apt-get check` then fail with "permission denied" or "could not get lock" although nothing is broken.
  While the lock is held the tool reports "apt/dpkg is busy" (manual, with the holder's pid) and does not suggest a dpkg
  repair. Fixes that need apt wait up to two minutes, then end as **deferred** (not failed) and stay under "still to do".
- **A pull is only suggested when the host is behind.** The controller sends the commit it ran from; a host on that commit
  needs no pull. The dev VMs hold no GitHub key (by design), so a pull there fails with "permission denied (publickey)"; the
  fixes do not depend on it because they run from the copy shipped with the run.
- **Go's telemetry counter** (`~/.config/go/telemetry`) changes whenever the dev doctor runs `go version`; the change
  witness ignores it.

## Round two (second run on vdcx3)

- **The change witness is a report, not a failure.** It lists files that changed under the managed paths while a pass
  ran, but on a desktop with VS Code open it caught the editor's own state files and made a clean recheck look broken
  ("4 failed, then 8"). It is now a warning in the record (`warned`, with the file list), and VS Code state and CUPS are
  ignored. The tripwire still caught the one real write we found (a `git status` refreshing an index).
- **Updating the host's own checkout is a courtesy.** Every fix runs from the copy shipped with the run, so a failed `git pull`
  (the dev VMs hold no key GitHub accepts) is reported as *skipped*, not as a failed fix.
- **Masking `motd-news` can no longer "fail" after it worked.** `reset-failed` on a unit that masking has just unloaded
  errors; that is ignored.
- **The bootstrap no longer leaves a repository configured twice.** `bootstrap-common.sh` 1.2.0 removes a vendor's legacy
  `NAME.list` when it writes `NAME.sources` for the same repository. Running the dev bootstrap on a VM that already had
  `github-cli.list` had made apt warn "configured multiple times" on every update.
- The summary says when a recheck did not pass but **nothing left can be automated**, so "NOT PASSED" with only manual items
  reads as "your turn", not as a failed run.

## Round three (first run on a server VM, vdcx1)

vdcx1 went from 9 failed checks to 3 with every fix applied cleanly (ssh enabled at boot, the ufw SSH rule, 46 package
upgrades including Docker, the NAS block, the shell tooling, polish, the zero job). What the three leftovers taught us:

- **`motd-news.service` came back during the run.** Polish makes the script non-executable but left the unit enabled, so
  an upgrade starting it made systemd "degraded" again. The baseline and both clone scripts mask
  `motd-news.timer` before `motd-news.service`, so the timer cannot trigger a service while it is being masked.
- **A fix can bring up a problem only the recheck sees**, so the runner applies a **second round** when something fixable is
  left (that has not already failed, and that this mode would run). Never more than two rounds; a fix that failed in
  round one is not repeated; only the last recheck is reported and logged.
- **Upgrades no longer restart services under you.** Ubuntu's `needrestart` restarts services after every apt run; on
  vdcx1 that included `systemd-networkd` and `systemd-resolved`. While fixes run, a drop-in
  (`/etc/needrestart/conf.d/90-fleet-check.conf`, `$nrconf{restart} = 'l'`) makes it only list them, and it is removed
  afterwards. Anything left running old libraries is reported as manual fix 89 (`sudo needrestart -r i`, or reboot).
- **A pull that was skipped is not suggested again** in the same run, so it does not sit under "still to do".
