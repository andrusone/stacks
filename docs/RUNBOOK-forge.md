# Runbook: the forge and the runner on two new Ubuntu Server VMs

The steps to build the forge (FG-FR-15) and then the runner on two fresh VMs made from the golden image. On your own computer you need git, ssh and scp, and the git checkout of this repo you already have. Each command says what tool it uses and where it runs.

## 0. What you supply, that no agent can

- **Two VMs**, each cloned by you from the golden image, named with `hostbook next-name --phys v --env p --intent c --os x` before the clone and added with `hostbook add <name> <address>` (the `hostbook` console does the same), and set up as [RUNBOOK-monitor.md](RUNBOOK-monitor.md) section 1 says. The image's steps are in [REF-golden-image.md](REF-golden-image.md); this runbook does not repeat them. Write the addresses down: the forge's is `FORGE_BIND`, the runner's is the one you ssh to.
- **A second disk for the forge VM**, 20 GB to start, on TrueNAS iSCSI storage. You add it in Proxmox, format it and mount it at `/data` (section 3). Forgejo keeps its data on this disk, not on the NAS share.
- **The forge admin's email address**, which the setup script asks you for in section 4. The admin password the script generates for you; you do not make one.
- **The runner's one-time registration token**, made on the forge's page once the forge is up (section 5).
- **The TrueNAS and Proxmox API addresses** (`TRUENAS_ADDR` and `PROXMOX_ADDR`). The runner blocks outbound traffic to them; you do not need to open anything.

No secret is ever written to git or to a story. The secrets go in the `.env` files on the VMs, and nowhere else.

## 1. Make the two VMs

Clone each VM from the golden image, name and address it with `hostbook`, and set it up as section 0 says (the steps are in [RUNBOOK-monitor.md](RUNBOOK-monitor.md) section 1).

Then, in the Proxmox web page, add the second disk to the forge VM only: the forge VM, **Hardware**, **Add**, **Hard Disk**, 20 GB, on the TrueNAS iSCSI storage. Start the forge VM. The runner VM gets no second disk.

Go on to section 2.

## 2. Get the repo onto the forge VM and connect

The forge VM clones the repo from the NAS share, so it needs no bundle, no `scp` and no key of yours. The share's clone must be on branch `main` (a CIFS share has no executable bit, so run from the VM's own clone, never from the share), as [RUNBOOK-host.md](RUNBOOK-host.md) section 1 and [RUNBOOK-monitor.md](RUNBOOK-monitor.md) section 2 say.

### 2a. Connect to the forge VM (on your own computer)

```
ssh youruser@192.168.1.60      # ssh, on your own computer: opens a session on the forge VM; use its address and user
```

From here, every command runs in that ssh session, on the forge VM.

### 2b. Clone the repo from the share (on the forge VM)

```
git clone -b main /nas/projects/andrusone/stacks ~/stacks      # git, on the forge VM: makes the stacks folder from the share's main branch
```

```
cd ~/stacks      # cd, on the forge VM
```

The forge's backup folder, `/nas/cloud-backup/services/forge/backup`, is made by `host/nas-layout.sh`, run once as [RUNBOOK-monitor.md](RUNBOOK-monitor.md) section 2 says. Do not make it by hand.

## 3. Forge VM: format and mount the data disk

The second disk must be a separate filesystem mounted at `/data`. The setup script stops before any change if it is not, so do this step first. Nothing here is run by a script: you run each command.

```
lsblk      # lsblk, on the forge VM: lists the disks; the new disk is the 20G one with no partitions and no MOUNTPOINT (usually sdb; use the name you see)
```

**Warning:** the next command erases the disk it is given. Use the name you saw in the `lsblk` output, and only the new 20G disk.

```
sudo mkfs.ext4 -L forge-data /dev/sdb      # mkfs.ext4, on the forge VM: formats the NEW disk (replace sdb with the name from lsblk)
```

```
sudo mkdir -p /data      # mkdir, on the forge VM: the mount point
```

```
sudo blkid /dev/sdb      # blkid, on the forge VM: prints the disk's UUID; copy the value inside the quotes after UUID=
```

Add one line at the end of `/etc/fstab`, with the UUID you copied in place of `<uuid>`:

```
sudo nano /etc/fstab      # nano, on the forge VM: opens the fstab file; add the line below at the end, save and exit
```

This line goes into `/etc/fstab` on the forge VM (the file content, not a command; `nofail` so a missing disk does not stop the boot):

```
UUID=<uuid>  /data  ext4  defaults,nofail  0  2
```

```
sudo mount /data      # mount, on the forge VM: mounts the disk at /data using the line you just added
```

```
findmnt /data      # findmnt, on the forge VM: the SOURCE column is the disk and the FSTYPE column is ext4; if nothing prints, the disk is not mounted: go back to the mount step
```

## 4. Forge VM: answer the setup's questions, set it up, start it

### 4a. The values

There is no file to copy or edit. The setup script (section 4b) asks for each value below, one question at a time. Each question shows its default: press Enter to accept it. Your answers go to `compose/forge-vm/.env`, which git does not track.

| Variable | What it means | Default | Secret? |
|---|---|---|---|
| `FORGE_USER` | The service user that owns the forge's folders. | `forge` | no |
| `FORGE_UID` | The user id of `FORGE_USER`. The setup script creates the user with this id. | `1100` | no |
| `FORGE_GID` | The group id of `FORGE_USER`. | `1100` | no |
| `FORGE_BIND` | The forge VM's own address, so your browser and the runner can reach the forge. | the VM's address on its network (for example `192.168.1.60`) | no |
| `FORGE_PORT` | The port of the forge's web page. | `3000` | no |
| `FORGE_HOST` | The forge's name on your network (letters, digits, dots and hyphens; no spaces). Nothing resolves it by itself: until the name points at the forge VM, other machines cannot open the URL. | `forge.core.andrusonline.com` | no |
| `FORGE_URL` | The address the forge's page answers at, with the port: what you type in a browser and what the runner connects to. | `http://` + `FORGE_HOST` + `:` + `FORGE_PORT` + `/` | no |
| `FORGE_DATA` | The folder on the data disk where the forge keeps all its data. | `/data/forgejo` | no |
| `FORGE_ADMIN_USER` | The forge's admin login. You will log in as this user. | `forge-admin` | no |
| `FORGE_ADMIN_EMAIL` | The admin's email address, as the forge asks for it. Use any address you control. | none: you type it (for example `admin@example.com`) | no |
| `FORGE_ADMIN_PASSWORD` | The admin's password. The script generates it and does not print it. | generated | **yes** |

**Set `FORGE_URL` to the forge's name, not its address (owner, 2026-11-21).** Type `http://forge.core.andrusonline.com:3000/` at the `FORGE_URL` question instead of accepting the default. Every repo cloned to the forge keeps that URL in its remote, so changing it later means editing every clone. Add the name first with `hostbook` (the host, and an alias `forge`) so it resolves from your computer and the runner.

The script never prints the password. To read it, once the setup has run, use this command; it prints the value, so do not paste the output into a message:

```
grep '^FORGE_ADMIN_PASSWORD=' compose/forge-vm/.env      # grep, on the forge VM: prints the generated admin password from the .env file
```

The password and the `.env` file are secrets. Do not put them in git, in a file other than `.env`, or in a message to anyone.

### 4b. The setup script

Run the setup script as your normal user; it calls `sudo` itself. It asks for the values in section 4a first, then checks the VM and the data disk, installs Docker and the repo's tools with mise, creates the service user and the data folder under `/data`, and sets restart on boot. If `/data` is not a mounted separate disk it stops before any change and names the fix: go back to section 3.

```
./compose/forge-vm/setup.sh      # bash, on the forge VM, as your normal user: asks for the values (Enter accepts each default), then checks the VM and the data disk, installs Docker and the repo's tools with mise, creates the service user and the data folder, sets restart on boot
```

If it stops and names a value (for example `FORGE_ADMIN_EMAIL has no default here`), it has not changed the VM: run the same script again and answer that question. (Answers already given are kept in `.env`.) `./compose/forge-vm/setup.sh --yes` takes every default without asking; it still stops, naming `FORGE_ADMIN_EMAIL`, because that value has no default.

Run it once more to see that nothing is left to change:

```
./compose/forge-vm/setup.sh      # bash, on the forge VM, as your normal user: a second run; its last line must say changes: 0
```

### 4c. Start the forge

The setup script's last lines print the forge URL marked "once started", then ask `Start the forge now? [Y/n]`. Press Enter (or type `y`) to start it there. Answer `n`, or run `./compose/forge-vm/setup.sh --yes`, and it starts nothing; to start it later, run this command:

```
sudo docker compose -f compose/forge-vm/docker-compose.yml up -d      # docker compose, on the forge VM: starts the forge (the same command the setup script offers)
```

**What you should see:** open `FORGE_URL` in a browser (for example `http://192.168.1.60:3000`) once the forge is started. The forge's page answers. Log in as `FORGE_ADMIN_USER` with `FORGE_ADMIN_PASSWORD`. The setup script's last line is `changes: <n>`; a run that had nothing left to change, and did not start the forge, ends with `changes: 0`. The first run also checks that `health/forge.toml` is in git; if not, it prints the `go run ./cmd/health new forge <address> --commit` command: run it on your own machine, push, rerun, then open the monitor page and confirm the forge shows (its three answers, `forge: host` and the rest).

### 4d. Updating the repo later

In the ssh session on the forge VM, the share's clone must be on `main` and up to date first, as [RUNBOOK-host.md](RUNBOOK-host.md) section 1 says. Then update the checkout from the share:

```
cd ~/stacks      # cd, on the forge VM
```

```
git pull      # git, on the forge VM: brings the new commits from the share into the stacks folder
```

Do not delete the `stacks` folder to start over: your `.env` lives in it and git does not track it.

## 5. Runner VM: make the token

Make the registration token on the forge's page, logged in as the admin: **Settings**, then **Actions**, then **Runners**, then **create new runner**. Copy the token it shows; the runner VM's setup script asks for it in section 6.

## 6. Runner VM: send the repo, fill in one file, set it up, start it

The runner VM mounts nothing and has no second disk. Steps 6a and 6b run on your own computer, in your local stacks checkout. The runner keeps the bundle because it cannot reach the NAS share (FG-FR-05), so it cannot clone from there.

### 6a. Pack the repo and copy it (on your own computer)

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.70:      # scp, on your own computer: copies the file to the runner VM's home folder; use the runner VM's address and user
```

### 6b. Connect to the runner VM (on your own computer)

```
ssh youruser@192.168.1.70      # ssh, on your own computer: opens a session on the runner VM; use its address and user
```

From here, every command runs in that ssh session, on the runner VM.

```
git clone -b main stacks.bundle stacks      # git, on the runner VM: makes the stacks folder from the bundle's main branch (a bundle of main has no HEAD, so name the branch)
```

```
cd stacks      # cd, on the runner VM
```

There is no file to edit by hand: the setup script in the next step asks for each value in the table below. Enter accepts the default shown; a variable set in the environment for that run skips its question. The answers are written to `compose/runner-vm/.env` (mode 600), and the token is never printed.

The variables:

| Variable | What it means | Example | Secret? |
|---|---|---|---|
| `RUNNER_USER` | The service user that owns the runner's folders. Leave `runner` unless you have a reason. | `runner` | no |
| `RUNNER_UID` | The user id of `RUNNER_USER`. | `1001` | no |
| `RUNNER_GID` | The group id of `RUNNER_USER`. | `1001` | no |
| `DOCKER_GID` | The group id of the `docker` group on this VM. Leave it empty: the setup script fills it in the first time it runs. | (empty) | no |
| `RUNNER_DATA` | The folder on the VM where the runner keeps its state. | `/srv/runner` | no |
| `RUNNER_NAME` | The name the runner shows on the forge's page. | `runner-vm` (the VM's host name, the default) | no |
| `FORGE_URL` | The forge's address, the same value as in the forge VM's `.env`, no trailing slash. No default: you type it. | `http://192.168.1.60:3000` | no |
| `RUNNER_REGISTRATION_TOKEN` | The one-time token from section 5. The runner uses it to register. Typed hidden, or the path of a file whose first line is the token. No default. | the token from the forge's page | **yes** |
| `TRUENAS_ADDR` | TrueNAS's address. The runner must not reach it; the setup script blocks it. No default: you type it. | `192.168.1.20` | no |
| `PROXMOX_ADDR` | The Proxmox API's address. The runner must not reach it; the setup script blocks it. No default: you type it. | `192.168.1.10` | no |

The token is a secret. The script never prints it. If you leave it empty, the script asks for it again on its next run, so keep it until the runner has registered.

Run the setup script as your normal user; it calls `sudo` itself. It asks for the values above first, then checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, blocks outbound traffic to `TRUENAS_ADDR` and `PROXMOX_ADDR`, sets restart on boot, and fills in `DOCKER_GID` in `.env`:

```
./compose/runner-vm/setup.sh      # bash, on the runner VM, as your normal user: asks for the values, then checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, blocks outbound traffic to TRUENAS_ADDR and PROXMOX_ADDR, sets restart on boot, fills in DOCKER_GID
```

If a value is missing and there is no terminal to answer at, the script stops before it changes anything and names the value. Run it again with the value set in the environment, or in a terminal.

Run it once more to see that nothing is left to change:

```
./compose/runner-vm/setup.sh      # bash, on the runner VM, as your normal user: a second run; its last line must say changes: 0 (changes: 1 if you said yes to starting the runner in it)
```

The setup script's last lines name the runner and ask `Start the runner now? [Y/n]`. Press Enter (or type `y`) to start it there. Answer `n`, or run `./compose/runner-vm/setup.sh --yes`, and it starts nothing; to start it later, run this command:

```
sudo docker compose -f compose/runner-vm/docker-compose.yml up -d      # docker compose, on the runner VM: starts the runner (the same command the setup script offers)
```

**What you should see:** once the runner is started, on the forge's page, under **Settings**, **Actions**, **Runners**, the runner named `RUNNER_NAME` shows as online. The first run also checks that `health/runner.toml` is in git; if not, it prints the `go run ./cmd/health new runner <address> --commit` command: run it on your own machine, push, rerun, then open the monitor page and confirm the runner shows (its four answers, `runner: host` and the rest).

## 7. Test: a green check and a red one

This runs on the forge VM, in a new ssh session to the forge VM (or the one from section 2), so the test repo is made where the forge is. You need only git.

1. **Make the test repo on the forge.** In the browser, logged in as the admin, click **New repository**, name it `check-test`, and create it with the default settings.

2. **Make the folder and the first commit, which passes:**

```
mkdir ~/check-test      # mkdir, on the forge VM: the folder for the test repo
```

```
cd ~/check-test      # cd, on the forge VM
```

```
git init -b main      # git, on the forge VM: makes an empty repo on branch main
```

```
printf '[tasks.check]\nrun = "true"\n' > mise.toml      # printf, on the forge VM: the check task that passes
```

```
mkdir -p .forgejo/workflows      # mkdir, on the forge VM
```

```
printf '%s\n' 'on: push' 'jobs:' '  check:' '    runs-on: mise' '    steps:' '      - name: fetch the pushed commit from the forge' '        run: |' '          git init -q .' '          git fetch -q --depth 1 "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY.git" "$GITHUB_SHA"' '          git checkout -q FETCH_HEAD' '      - name: mise run check' '        run: |' '          mise trust -q' '          mise run check' > .forgejo/workflows/check.yml      # printf, on the forge VM: the workflow file that runs mise run check
```

```
git add -A      # git, on the forge VM
```

```
git -c user.name=owner -c user.email=owner@localhost commit -m "check: passes"      # git, on the forge VM
```

```
git remote add origin http://192.168.1.60:3000/forge-admin/check-test.git      # git, on the forge VM: your FORGE_URL, then your FORGE_ADMIN_USER and check-test
```

```
git push -u origin main      # git, on the forge VM: git asks for the admin user and password; type them, they are not stored
```

3. **Read the green status.** Within 5 minutes, the repo's commit list on the forge shows a green tick beside the commit `check: passes`.

4. **Make the second commit, which fails:**

```
printf '[tasks.check]\nrun = "false"\n' > mise.toml      # printf, on the forge VM: the check task that fails
```

```
git add -A      # git, on the forge VM
```

```
git -c user.name=owner -c user.email=owner@localhost commit -m "check: fails"      # git, on the forge VM
```

```
git push      # git, on the forge VM
```

5. **Read the red status.** Within 5 minutes, the commit `check: fails` shows a red cross.

If a job fails in seconds with no step log, it is a workflow or action error (a YAML mistake, or `uses:` of an action the runner cannot fetch), which the forge does not name. This test's workflow has no `uses:`, so check the YAML of `.forgejo/workflows/check.yml` first.

6. **Check the runner cannot reach TrueNAS or Proxmox.** Open a second ssh session to the runner VM (`ssh youruser@192.168.1.70`) and run these two commands there (`nc` ships with Ubuntu). Each one must fail: nothing connects, and `nc` returns to the prompt after about 3 seconds with nothing printed.

```
nc -zw3 192.168.1.20 443      # nc, on the runner VM: TRUENAS_ADDR, port 443; must not connect
```

```
nc -zw3 192.168.1.10 8006      # nc, on the runner VM: PROXMOX_ADDR, the Proxmox API's port 8006; must not connect
```

If either one connects, the block is missing: tell the architect; do not go on.

## 8. Reboot check, for each VM

On the forge VM, then on the runner VM, one at a time:

```
sudo reboot      # systemd, on the VM
```

Wait about 2 minutes, then reconnect with ssh and go to the stacks folder:

```
cd stacks      # cd, on the VM: a new ssh login starts in your home folder
```

On the forge VM only, check that the data disk came back before the forge does:

```
findmnt /data      # findmnt, on the forge VM: must print the data disk with FSTYPE ext4
```

Check the forge (on the forge VM; the forge should be "running"):

```
sudo docker compose -f compose/forge-vm/docker-compose.yml ps      # docker compose, on the forge VM
```

Check the runner (on the runner VM; the runner should be "running"):

```
sudo docker compose -f compose/runner-vm/docker-compose.yml ps      # docker compose, on the runner VM
```

Then open `FORGE_URL` in a browser: the forge's page should be back by itself, and after the runner VM's reboot the runner should show online on the forge's page again. Nothing is started by hand.

## 9. Reconnect: the forge VM is lost, the data is fine

Use this when the forge VM is gone but the data disk is safe (FG-FR-02). Nothing else is touched: no backup is needed, and the NAS is not involved.

1. **Stop the lost VM and take the data disk off it** (Proxmox web page: the lost forge VM, **Hardware**, the 20 GB hard disk, **Remove**). Choose to keep the disk: do not delete it.
2. **Make a new forge VM** from the golden image (section 1), then attach the same disk to it (Proxmox: the new forge VM, **Hardware**, **Add**, **Hard Disk**, use the existing 20 GB disk). Start it.
3. **Mount the disk**, on the new forge VM in its ssh session. The disk keeps its UUID, so the `/etc/fstab` line from section 3 works unchanged; add it again on the new VM:

```
sudo blkid      # blkid, on the new forge VM: find the UUID of the 20 GB disk, the same one as before
```

```
sudo nano /etc/fstab      # nano, on the new forge VM: add the same line (with nofail) as in section 3 at the end, save and exit
```

```
sudo mount /data      # mount, on the new forge VM: mounts the disk at /data
```

```
findmnt /data      # findmnt, on the new forge VM: must print the disk with FSTYPE ext4; if not, do not go on
```

4. **Get the repo and the env file.** Clone the repo from the share again as in section 2b (the forge VM's old copy is gone and must not be used; the share's clone must be on `main`). Run the setup script again and answer its questions from the table in section 4a; the values already in `compose/forge-vm/.env` are the defaults, so Enter keeps them. `FORGE_UID` and `FORGE_GID` must be the same as before, because the files on the disk belong to those ids. `FORGE_ADMIN_PASSWORD` is used only if the admin user does not exist yet, so keep the stored value (Enter accepts it).
5. **Set up and start**, as in section 4b and 4c, each command in its own block, on the new forge VM:

```
cd stacks      # cd, on the new forge VM
```

```
./compose/forge-vm/setup.sh      # bash, on the new forge VM, as the normal user (it calls sudo itself)
```

```
sudo docker compose -f compose/forge-vm/docker-compose.yml up -d      # docker compose, on the new forge VM
```

**What you should see:** `FORGE_URL` shows the forge with every repo, pull request and account as they were. Log in as `FORGE_ADMIN_USER`. Record how long it took.

The runner needs nothing: it re-registers only if you delete it and make a new token (section 5).

## 10. What this does not cover

- Role tokens and a protected `main` branch.
- The backup and the restore. Both scripts exist and are run by hand, not on a schedule. They are the MVP 1 scripts: they call plain `docker`, so they run with `sudo`, and they read `FORGE_DATA` and `FORGE_BACKUP` from the command line, not from `.env`. `FORGE_BACKUP` must lie outside the data folder. The backup copy goes to a folder on the NAS share that the golden image already mounts at `/nas/cloud-backup`, in `services/forge/backup`; that copy is the SMB copy, not the live data.

  Make a backup while the forge is running (on the forge VM, from the stacks folder):

  ```
  cd stacks      # cd, on the forge VM
  ```

  ```
  sudo FORGE_DATA=/data/forgejo FORGE_BACKUP=/nas/cloud-backup/services/forge/backup bash compose/forge/backup.sh      # bash, on the forge VM: writes one copy to the backup folder and keeps the newest seven
  ```

  Restoring is not yet a path for the forge VM. The restore script starts its own local forge on `127.0.0.1:3000`, so the steps are: stop the forge VM, move the old data aside so the folder is empty, restore, stop the local forge, fix the owner of the restored files, and start the forge VM on the restored data.

  ```
  sudo docker compose -f compose/forge-vm/docker-compose.yml down      # docker compose, on the forge VM: stops the forge; the data stays
  ```

  ```
  sudo mv /data/forgejo /data/forgejo.old      # mv, on the forge VM: moves the old data aside on the data disk
  ```

  ```
  sudo mkdir /data/forgejo      # mkdir, on the forge VM: an empty data folder for the restore
  ```

  ```
  sudo FORGE_DATA=/data/forgejo FORGE_BACKUP=/nas/cloud-backup/services/forge/backup bash compose/forge/restore.sh      # bash, on the forge VM: unpacks the newest copy into the data folder and starts a local forge on 127.0.0.1:3000
  ```

  ```
  sudo bash compose/forge/down.sh      # bash, on the forge VM: stops that local forge; the data stays
  ```

  ```
  sudo chown -R <FORGE_UID>:<FORGE_GID> /data/forgejo      # chown, on the forge VM: the restore wrote the files as root; the forge runs as FORGE_UID and FORGE_GID, so give them to it; put the two numbers from your .env in place of the placeholders
  ```

  ```
  sudo docker compose -f compose/forge-vm/docker-compose.yml up -d      # docker compose, on the forge VM: starts the forge VM on the restored data
  ```

  Check the forge's page after the last step before you trust it. Then delete the old copy on the data disk yourself, once the restore is checked:

  ```
  sudo rm -rf /data/forgejo.old      # rm, on the forge VM: deletes the old data to free the disk; run it only after the restored forge works
  ```

  The restore has not been run on a VM yet, and its scripts run as root under `sudo`, so the files they write are owned by root until the `chown` above.

- SOPS-encrypted secrets.
- Health files.
- Moving real repos and their history to the forge.

## 11. Friction

If anything in these steps annoyed you or cost you time, tell the architect, or add one line to `outcomes/oc6-forge-rebuildable.md` in the workbench, under `## Friction`. Nothing else is needed.
