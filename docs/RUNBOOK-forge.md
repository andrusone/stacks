# Runbook: the forge and the runner on two new Ubuntu Server VMs

The steps to build the forge (FG-FR-15) and then the runner on two fresh VMs made from the golden image. On your own computer you need git, ssh and scp, and the git checkout of this repo you already have. Each command says what tool it uses and where it runs.

## 0. What you supply, that no agent can

- **Two VMs**, each cloned by you from the golden image and finished with the image's own `post-clone-server.sh`. The image's steps are in [REF-golden-image.md](REF-golden-image.md); this runbook does not repeat them. Write the addresses down: the forge's is `FORGE_BIND`, the runner's is the one you ssh to.
- **The TrueNAS share for the forge's data**, already mounted on the forge VM under `/nas/<share>` by the image's `mount-nas.sh`. The forge VM only: the runner mounts nothing. Step 2 checks it.
- **The admin password for the forge**, which you make yourself in step 2.
- **The runner's one-time registration token**, made on the forge's page once the forge is up (step 3).
- **The TrueNAS and Proxmox API addresses** (`TRUENAS_ADDR` and `PROXMOX_ADDR`). The runner blocks outbound traffic to them; you do not need to open anything.

No secret is ever written to git or to a story. The secrets go in the `.env` files on the VMs, and nowhere else.

## 1. Make the two VMs

Clone each VM from the golden image and finish it with `post-clone-server.sh`, as section 0 says. Then go on to step 2.

## 2. Forge VM: get the repo onto the VM, fill in one file, start the forge

### 2a. Send the repo to the forge VM

On your own computer, in your local stacks checkout (git and scp):

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.60:      # scp, on your own computer: copies the file to the VM's home folder
```

The repo is private, so the VM cannot clone it and holds no key of yours; the bundle is how it gets the repo.

Connect to the forge VM from your own computer:

```
ssh youruser@192.168.1.60      # ssh, on your own computer (use the forge VM's address and user)
```

Then, over that ssh session on the forge VM:

```
git clone stacks.bundle stacks      # git, on the forge VM: makes the stacks folder from the bundle
```

```
cd stacks      # cd, on the forge VM
```

```
cp compose/forge-vm/.env.example compose/forge-vm/.env      # cp, on the forge VM
```

Edit the file with `nano` (ships with Ubuntu Server):

```
nano compose/forge-vm/.env      # nano, on the forge VM
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
| `FORGE_DATA` | The folder under the TrueNAS share on the VM (`/nas/<share>`); the forge keeps all its data there. | `/nas/<share>/forge-data` | no |
| `FORGE_ADMIN_USER` | The forge's admin login. You will log in as this user. | `forge-admin` | no |
| `FORGE_ADMIN_EMAIL` | The admin's email address, as the forge asks for it. Use any address you control. | `admin@example.com` | no |
| `FORGE_ADMIN_PASSWORD` | The admin's password. A random string, made in the next block, kept in this file only. | the output of the command below | **yes** |

Make the admin password with a command that ships with Ubuntu, then paste the output into `FORGE_ADMIN_PASSWORD`:

```
openssl rand -hex 24      # openssl, on the forge VM: copy the output into FORGE_ADMIN_PASSWORD
```

The password and the `.env` file are secrets. Do not put them in git, in a file other than `.env`, or in a message to anyone.

Check that the share is mounted, and make the data folder under it. Use the path you wrote in `FORGE_DATA`, with your share's name in place of `<share>`:

```
findmnt /nas/<share>      # findmnt, on the forge VM: the FSTYPE column must say cifs
```

If it prints nothing, the share is not mounted: stop, and tell the architect. Do not go on.

```
sudo mkdir -p /nas/<share>/forge-data      # mkdir, on the forge VM: the data folder, under the share
```

Run the setup script as your normal user; it calls `sudo` itself. It checks the VM and the share, installs Docker and the repo's tools with mise, creates the service user and folders, and sets restart on boot:

```
./compose/forge-vm/setup.sh      # bash, on the forge VM, as your normal user: checks the VM and the share, installs Docker and the repo's tools with mise, creates the service user and folders, sets restart on boot
```

If the script says it created `compose/forge-vm/.env` and exits with status 1, you skipped the copy above: fill in the file, then run the same script again.

Start the forge:

```
sudo docker compose -f compose/forge-vm/docker-compose.yml up -d      # docker compose, on the forge VM
```

**What you should see:** open `FORGE_URL` in a browser (for example `http://192.168.1.60:3000`). The forge's page answers. Log in as `FORGE_ADMIN_USER` with `FORGE_ADMIN_PASSWORD`. The setup script's last line is `changes: <n>`; a run that had nothing left to change ends with `changes: 0`.

### 2b. Updating the repo later

On your own computer, in your local stacks checkout, make a new bundle and copy it to the forge VM:

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.60:      # scp, on your own computer: copies the file to the VM's home folder
```

On the forge VM, in its ssh session, update the checkout from the new bundle:

```
cd stacks      # cd, on the forge VM
```

```
git pull ~/stacks.bundle main      # git, on the forge VM: brings the new commits into the stacks folder
```

Do not delete the `stacks` folder to start over: your `.env` lives in it and git does not track it.

## 3. Runner VM: make the token

Make the registration token on the forge's page, logged in as the admin: **Settings**, then **Actions**, then **Runners**, then **create new runner**. Copy the token it shows; you will paste it into the runner VM's `.env` in step 4.

## 4. Runner VM: get the repo onto the VM, fill in one file

On your own computer, in your local stacks checkout, make a bundle and copy it to the runner VM (the same two commands as in step 2a, with the runner VM's address):

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.70:      # scp, on your own computer: copies the file to the VM's home folder
```

Connect to the runner VM from your own computer:

```
ssh youruser@192.168.1.70      # ssh, on your own computer (use the runner VM's address and user)
```

Then, over that ssh session on the runner VM:

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
nano compose/runner-vm/.env      # nano, on the runner VM
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
| `RUNNER_REGISTRATION_TOKEN` | The one-time token from step 3. The runner uses it once to register. | the token from the forge's page | **yes** |
| `TRUENAS_ADDR` | TrueNAS's address. The runner must not reach it; the setup script blocks it. | `192.168.1.20` | no |
| `PROXMOX_ADDR` | The Proxmox API's address. The runner must not reach it; the setup script blocks it. | `192.168.1.10` | no |

The token is a secret. Paste it into this file only.

## 5. Runner VM: run the setup script and start the runner

Run the setup script as your normal user; it calls `sudo` itself. It checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, blocks outbound traffic to `TRUENAS_ADDR` and `PROXMOX_ADDR`, sets restart on boot, and fills in `DOCKER_GID` in `.env`:

```
./compose/runner-vm/setup.sh      # bash, on the runner VM, as your normal user: checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, blocks outbound traffic to TRUENAS_ADDR and PROXMOX_ADDR, sets restart on boot, fills in DOCKER_GID
```

If the script says it created `compose/runner-vm/.env` and exits with status 1, you skipped the copy in step 4: fill in the file, then run the same script again.

Start the runner:

```
sudo docker compose -f compose/runner-vm/docker-compose.yml up -d      # docker compose, on the runner VM
```

**What you should see:** on the forge's page, under **Settings**, **Actions**, **Runners**, the runner named `RUNNER_NAME` shows as online. The setup script's last line is `changes: <n>`.

## 6. Test: a green check and a red one

This runs on the forge VM, over its ssh session, so the test repo is made where the forge is. You need only git.

1. **Make the test repo on the forge.** In the browser, logged in as the admin, click **New repository**, name it `check-test`, and create it with the default settings.

2. **Make the folder and the first commit, which passes** (on the forge VM):

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

6. **Check the runner cannot reach TrueNAS or Proxmox.** Run these two commands from the runner VM, over its ssh session (`nc` ships with Ubuntu). Each one must fail: nothing connects, and `nc` returns to the prompt after about 3 seconds with nothing printed.

```
nc -zw3 192.168.1.20 443      # nc, on the runner VM: TRUENAS_ADDR, port 443; must not connect
```

```
nc -zw3 192.168.1.10 8006      # nc, on the runner VM: PROXMOX_ADDR, the Proxmox API's port 8006; must not connect
```

If either one connects, the block is missing: tell the architect; do not go on.

## 7. Reboot check, for each VM

On the forge VM, then on the runner VM, one at a time:

```
sudo reboot      # systemd, on the VM
```

Wait about 2 minutes, then reconnect with ssh and go to the stacks folder:

```
cd stacks      # cd, on the VM: a new ssh login starts in your home folder
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

## 8. What this does not cover

- Role tokens and a protected `main` branch.
- The backup and the restore. Both scripts exist and are run by hand, not on a schedule. They are the MVP 1 scripts: they call plain `docker`, so they run with `sudo`, and they read `FORGE_DATA` and `FORGE_BACKUP` from the command line, not from `.env`. `FORGE_BACKUP` must lie outside the data folder.

  Make a backup while the forge is running (on the forge VM, from the stacks folder):

  ```
  cd stacks      # cd, on the forge VM
  ```

  ```
  sudo FORGE_DATA=/nas/<share>/forge-data FORGE_BACKUP=/nas/<share>/forge-backup bash compose/forge/backup.sh      # bash, on the forge VM: writes one copy to the backup folder and keeps the newest seven
  ```

  Restoring is not yet a path for the forge VM. The restore script starts its own local forge on `127.0.0.1:3000`, so the steps are: stop the forge VM, move the old data aside so the folder is empty, restore, stop the local forge, and start the forge VM on the restored data.

  ```
  sudo docker compose -f compose/forge-vm/docker-compose.yml down      # docker compose, on the forge VM: stops the forge; the data stays
  ```

  ```
  sudo mv /nas/<share>/forge-data /nas/<share>/forge-data.old      # mv, on the forge VM: moves the old data aside; delete the .old folder yourself once the restore is checked
  ```

  ```
  sudo mkdir /nas/<share>/forge-data      # mkdir, on the forge VM: an empty data folder for the restore
  ```

  ```
  sudo FORGE_DATA=/nas/<share>/forge-data FORGE_BACKUP=/nas/<share>/forge-backup bash compose/forge/restore.sh      # bash, on the forge VM: unpacks the newest copy into the data folder and starts a local forge on 127.0.0.1:3000
  ```

  ```
  sudo bash compose/forge/down.sh      # bash, on the forge VM: stops that local forge; the data stays
  ```

  ```
  sudo docker compose -f compose/forge-vm/docker-compose.yml up -d      # docker compose, on the forge VM: starts the forge VM on the restored data
  ```

  The restore has not been run on a VM yet, and its scripts run as root under `sudo`, so the files they write are owned by root. Check the forge's page after the last step before you trust it.

- SOPS-encrypted secrets.
- Health files.
- Moving real repos and their history to the forge.

## 9. Friction

If anything in these steps annoyed you or cost you time, tell the architect, or add one line to `outcomes/oc6-forge-rebuildable.md` in the workbench, under `## Friction`. Nothing else is needed.
