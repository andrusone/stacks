# Runbook: the forge and the runner on two new Ubuntu Server VMs

The steps to build the forge (FG-FR-15) and then the runner on two fresh VMs made from the golden image. On your own computer you need git, ssh and scp, and the git checkout of this repo you already have. Each command says what tool it uses and where it runs.

## 0. What you supply, that no agent can

- **Two VMs**, each cloned by you from the golden image and finished with the image's own `post-clone-server.sh`. The image's steps are in [REF-golden-image.md](REF-golden-image.md); this runbook does not repeat them. Write the addresses down: the forge's is `FORGE_BIND`, the runner's is the one you ssh to.
- **A second disk for the forge VM**, 20 GB to start, on TrueNAS iSCSI storage. You add it in Proxmox, format it and mount it at `/data` (section 3). Forgejo keeps its data on this disk, not on the NAS share.
- **The admin password for the forge**, which you make yourself in section 4.
- **The runner's one-time registration token**, made on the forge's page once the forge is up (section 5).
- **The TrueNAS and Proxmox API addresses** (`TRUENAS_ADDR` and `PROXMOX_ADDR`). The runner blocks outbound traffic to them; you do not need to open anything.

No secret is ever written to git or to a story. The secrets go in the `.env` files on the VMs, and nowhere else.

## 1. Make the two VMs

Clone each VM from the golden image and finish it with `post-clone-server.sh`, as section 0 says.

Then, in the Proxmox web page, add the second disk to the forge VM only: the forge VM, **Hardware**, **Add**, **Hard Disk**, 20 GB, on the TrueNAS iSCSI storage. Start the forge VM. The runner VM gets no second disk.

Go on to section 2.

## 2. Send the repo to the forge VM and connect

Steps 2a and 2b run on your own computer, in your local stacks checkout. Step 2c opens the ssh session on the forge VM, and every command after it runs there.

### 2a. Pack the repo (on your own computer)

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

### 2b. Copy the bundle to the forge VM (on your own computer)

```
scp stacks.bundle youruser@192.168.1.60:      # scp, on your own computer: copies the file to the VM's home folder; use the forge VM's address and user
```

The repo is private, so the VM cannot clone it and holds no key of yours; the bundle is how it gets the repo.

### 2c. Connect to the forge VM (on your own computer)

```
ssh youruser@192.168.1.60      # ssh, on your own computer: opens a session on the forge VM; use its address and user
```

From here, every command runs in that ssh session, on the forge VM.

```
git clone stacks.bundle stacks      # git, on the forge VM: makes the stacks folder from the bundle
```

```
cd stacks      # cd, on the forge VM
```

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

## 4. Forge VM: fill in one file, set it up, start it

### 4a. The env file

```
cp compose/forge-vm/.env.example compose/forge-vm/.env      # cp, on the forge VM
```

```
nano compose/forge-vm/.env      # nano, on the forge VM: fill in the values from the table below, save and exit
```

The variables:

| Variable | What it means | Example | Secret? |
|---|---|---|---|
| `FORGE_USER` | The service user that owns the forge's folders. Leave `forge` unless you have a reason. | `forge` | no |
| `FORGE_UID` | The user id of `FORGE_USER`. The setup script creates the user with this id. | `1100` | no |
| `FORGE_GID` | The group id of `FORGE_USER`. | `1100` | no |
| `FORGE_BIND` | The forge VM's own address, so your browser and the runner can reach the forge. | `192.168.1.60` | no |
| `FORGE_PORT` | The port of the forge's web page. | `3000` | no |
| `FORGE_URL` | The address the forge's page answers at, with the port: what you type in a browser and what the runner connects to. | `http://192.168.1.60:3000` | no |
| `FORGE_DATA` | The folder on the data disk where the forge keeps all its data. Leave `/data/forgejo` unless you have a reason. | `/data/forgejo` | no |
| `FORGE_ADMIN_USER` | The forge's admin login. You will log in as this user. | `forge-admin` | no |
| `FORGE_ADMIN_EMAIL` | The admin's email address, as the forge asks for it. Use any address you control. | `admin@example.com` | no |
| `FORGE_ADMIN_PASSWORD` | The admin's password. A random string, made in the next block, kept in this file only. | the output of the command below | **yes** |

Make the admin password with a command that ships with Ubuntu, then paste the output into `FORGE_ADMIN_PASSWORD`:

```
openssl rand -hex 24      # openssl, on the forge VM: copy the output into FORGE_ADMIN_PASSWORD
```

The password and the `.env` file are secrets. Do not put them in git, in a file other than `.env`, or in a message to anyone.

### 4b. The setup script

Run the setup script as your normal user; it calls `sudo` itself. It checks the VM and the data disk, installs Docker and the repo's tools with mise, creates the service user and the data folder under `/data`, and sets restart on boot. If `/data` is not a mounted separate disk it stops before any change and names the fix: go back to section 3.

```
./compose/forge-vm/setup.sh      # bash, on the forge VM, as your normal user: checks the VM and the data disk, installs Docker and the repo's tools with mise, creates the service user and the data folder, sets restart on boot
```

If the script says it created `compose/forge-vm/.env` and exits with status 1, you skipped the copy in 4a: fill in the file, then run the same script again:

```
./compose/forge-vm/setup.sh      # bash, on the forge VM, as your normal user: the same script, run again after filling in .env
```

Run it once more to see that nothing is left to change:

```
./compose/forge-vm/setup.sh      # bash, on the forge VM, as your normal user: a second run; its last line must say changes: 0
```

### 4c. Start the forge

```
sudo docker compose -f compose/forge-vm/docker-compose.yml up -d      # docker compose, on the forge VM: starts the forge
```

**What you should see:** open `FORGE_URL` in a browser (for example `http://192.168.1.60:3000`). The forge's page answers. Log in as `FORGE_ADMIN_USER` with `FORGE_ADMIN_PASSWORD`. The setup script's last line is `changes: <n>`; a run that had nothing left to change ends with `changes: 0`.

### 4d. Updating the repo later

On your own computer, in your local stacks checkout, make a new bundle and copy it to the forge VM:

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.60:      # scp, on your own computer: copies the file to the VM's home folder
```

In the ssh session on the forge VM, update the checkout from the new bundle:

```
cd stacks      # cd, on the forge VM
```

```
git pull ~/stacks.bundle main      # git, on the forge VM: brings the new commits into the stacks folder
```

Do not delete the `stacks` folder to start over: your `.env` lives in it and git does not track it.

## 5. Runner VM: make the token

Make the registration token on the forge's page, logged in as the admin: **Settings**, then **Actions**, then **Runners**, then **create new runner**. Copy the token it shows; you will paste it into the runner VM's `.env` in section 6.

## 6. Runner VM: send the repo, fill in one file, set it up, start it

The runner VM mounts nothing and has no second disk. Steps 6a and 6b run on your own computer, in your local stacks checkout.

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
git clone stacks.bundle stacks      # git, on the runner VM: makes the stacks folder from the bundle
```

```
cd stacks      # cd, on the runner VM
```

```
cp compose/runner-vm/.env.example compose/runner-vm/.env      # cp, on the runner VM
```

```
nano compose/runner-vm/.env      # nano, on the runner VM: fill in the values from the table below, save and exit
```

The variables:

| Variable | What it means | Example | Secret? |
|---|---|---|---|
| `RUNNER_USER` | The service user that owns the runner's folders. Leave `runner` unless you have a reason. | `runner` | no |
| `RUNNER_UID` | The user id of `RUNNER_USER`. | `1001` | no |
| `RUNNER_GID` | The group id of `RUNNER_USER`. | `1001` | no |
| `DOCKER_GID` | The group id of the `docker` group on this VM. Leave it empty: the setup script fills it in the first time it runs. | (empty) | no |
| `RUNNER_DATA` | The folder on the VM where the runner keeps its state. | `/srv/runner` | no |
| `RUNNER_NAME` | The name the runner shows on the forge's page. | `runner-vm` | no |
| `FORGE_URL` | The forge's address, the same value as in the forge VM's `.env`. | `http://192.168.1.60:3000` | no |
| `RUNNER_REGISTRATION_TOKEN` | The one-time token from section 5. The runner uses it once to register. | the token from the forge's page | **yes** |
| `TRUENAS_ADDR` | TrueNAS's address. The runner must not reach it; the setup script blocks it. | `192.168.1.20` | no |
| `PROXMOX_ADDR` | The Proxmox API's address. The runner must not reach it; the setup script blocks it. | `192.168.1.10` | no |

The token is a secret. Paste it into this file only.

Run the setup script as your normal user; it calls `sudo` itself. It checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, blocks outbound traffic to `TRUENAS_ADDR` and `PROXMOX_ADDR`, sets restart on boot, and fills in `DOCKER_GID` in `.env`:

```
./compose/runner-vm/setup.sh      # bash, on the runner VM, as your normal user: checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, blocks outbound traffic to TRUENAS_ADDR and PROXMOX_ADDR, sets restart on boot, fills in DOCKER_GID
```

If the script says it created `compose/runner-vm/.env` and exits with status 1, you skipped the copy above: fill in the file, then run the same script again:

```
./compose/runner-vm/setup.sh      # bash, on the runner VM, as your normal user: the same script, run again after filling in .env
```

Run it once more to see that nothing is left to change:

```
./compose/runner-vm/setup.sh      # bash, on the runner VM, as your normal user: a second run; its last line must say changes: 0
```

Start the runner:

```
sudo docker compose -f compose/runner-vm/docker-compose.yml up -d      # docker compose, on the runner VM: starts the runner
```

**What you should see:** on the forge's page, under **Settings**, **Actions**, **Runners**, the runner named `RUNNER_NAME` shows as online.

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

4. **Get the repo and the env file.** Send the repo as in section 2 (the bundle is made on your own computer; the forge's own copy is gone and must not be used). Fill in `compose/forge-vm/.env` again from the table in section 4a. `FORGE_UID` and `FORGE_GID` must be the same as before, because the files on the disk belong to those ids. `FORGE_ADMIN_PASSWORD` is used only if the admin user does not exist yet, so the same value is fine if you kept it, or a new one if you did not.
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
- The backup and the restore. Both scripts exist and are run by hand, not on a schedule. They are the MVP 1 scripts: they call plain `docker`, so they run with `sudo`, and they read `FORGE_DATA` and `FORGE_BACKUP` from the command line, not from `.env`. `FORGE_BACKUP` must lie outside the data folder. The backup copy goes to a folder on the NAS share that the golden image already mounts at `/nas/<share>`; that copy is the SMB copy, not the live data.

  Make a backup while the forge is running (on the forge VM, from the stacks folder):

  ```
  cd stacks      # cd, on the forge VM
  ```

  ```
  sudo FORGE_DATA=/data/forgejo FORGE_BACKUP=/nas/<share>/forge-backup bash compose/forge/backup.sh      # bash, on the forge VM: writes one copy to the backup folder and keeps the newest seven
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
  sudo FORGE_DATA=/data/forgejo FORGE_BACKUP=/nas/<share>/forge-backup bash compose/forge/restore.sh      # bash, on the forge VM: unpacks the newest copy into the data folder and starts a local forge on 127.0.0.1:3000
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
