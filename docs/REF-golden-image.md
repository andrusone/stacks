# REF: what the golden image gives every VM, and how the owner's scripts are written

Reference, not a spec. Written 2026-11-16 from the owner's own scripts in the `network` repo (`stacks/os/ubuntu/image/README.md`, `post-install-baseline-all.sh`, `post-clone-server.sh`, `zero-free-space.sh`, and `stacks/os/ubuntu/mount-nas.sh`). Read it before writing any stack's `setup.sh`, compose file or runbook.

## How a VM is made (always by the owner, by hand)

The owner clones a Proxmox VM from the Ubuntu Server golden image, connects, and runs `post-clone-server.sh` (hostname, static IP, grow the disk, scheduled zero-fill, validate). The VM then runs a stack's `setup.sh`. **No outcome creates, clones or addresses a VM.** A stack's scripts start from a VM that already has everything below.

## What is already on the VM before any stack's setup.sh

- Patched Ubuntu Server; unattended security updates (never auto-reboot); weekly `fstrim`; journald and logrotate limits; QEMU guest agent.
- Packages: `qemu-guest-agent curl wget ca-certificates gnupg lsb-release unattended-upgrades cifs-utils openssh-server ufw git`.
- SSH enabled. `ufw` has an allow rule for the SSH port(s) but is **inactive** unless the owner ran the baseline with `ENABLE_UFW=1`. A stack that publishes a port must work with ufw off and with ufw on (add its own allow rule).
- **TrueNAS shares are already mounted over SMB (cifs) under `/nas/<share>`**, by `mount-nas.sh`: systemd automount, credentials in `/etc/samba/credentials.truenas` (root-only), files owned by the person who ran the baseline, group `nas`, file mode 0664, directory mode 0775. The shares are discovered from the NAS. A service gets write access by its account being in group `nas`.
- The shell and prompt (`bootstrap-shell.sh`) and a stack marker for the `os` stack.

## What is NOT on the VM

Docker, the compose plugin, mise, Go. A stack's `setup.sh` installs them (mise for tools mise can install; Docker's own apt repository for the engine and compose plugin).

## Consequences for every stack's scripts

1. **Never create a network mount.** Do not add NFS or SMB lines to `/etc/fstab`, do not install `nfs-common`. Persistent data lives in a directory under an existing `/nas/<share>`. Preflight: if that path is not a mounted share, stop before any change and print the line that fixes it (`mount-nas.sh`).
2. **Start from the image, not from "a plain Ubuntu".** Do not repeat what the baseline already did (ssh, ufw rules for ssh, unattended upgrades, cifs-utils, git).
3. **Follow the owner's script conventions:** bash with `set -euo pipefail` and a `SCRIPT_VERSION`; run as the normal user, never as root, and call `sudo` itself (refuse a bare root login); idempotent, changing a file or service only when it differs; a read-only `--check` mode that prints `PASS`, `FAIL` or `WARN` per item and exits 1 on any `FAIL`; values taken from environment variables so prompts can be skipped; `--only <stage>` to rerun one part; a clear last line saying what changed.
4. **ufw may be active.** Open exactly the ports the stack publishes, and say so.

## Settled by the owner (2026-11-16, item 30): Forgejo's data

Forgejo keeps SQLite on a local block disk, a second disk on the forge VM (iSCSI-backed on TrueNAS, so an ordinary disk to the VM) mounted at `/data`, not on SMB; no Postgres. The backup copy goes to a `/nas/<share>` path.
