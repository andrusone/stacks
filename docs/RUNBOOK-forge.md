# Runbook: the forge and the runner on two new Ubuntu Server VMs

The steps to build the forge (FG-FR-15) and then the runner on two fresh VMs. On your own computer you need only ssh and scp (both come with OpenSSH) and the git checkout of this repo you already have. Each command says what tool it uses and where it runs.

## 0. What you supply, that no agent can

- **Two VMs**, each running **Ubuntu Server**, each with an SSH user that has **sudo**, each with a **fixed address** (a static address or a DHCP reservation). Install nothing else; the setup scripts install the rest. Write the addresses down: the forge's is `FORGE_BIND`, the runner's is the one you ssh to.
- **An NFS export on TrueNAS** for the forge's data. The forge VM mounts it and writes to it. The export's own permissions are TrueNAS's: give write access to the user id and group id you put in `FORGE_UID` and `FORGE_GID` (the forge VM's own user; the setup script creates it with those ids). Write down the export path (`TRUENAS_EXPORT`) and TrueNAS's address (`TRUENAS_ADDR`).
- **The runner's one-time registration token**, made on the forge's page once the forge is up (step 3 below).
- **The Proxmox API address** (`PROXMOX_ADDR`). The runner blocks outbound traffic to it; you do not need to open anything.

No secret is ever written to git or to a story. The secrets go in the `.env` files on the VMs, and nowhere else.

## 1. Make the two VMs by hand

Create each VM as described in section 0. Connect to the forge VM from your own computer:

```
ssh youruser@192.168.1.60      # ssh, on your own computer (use the forge VM's address and user)
```

## 2. Forge VM: get the repo onto the VM and fill in one file

The repo is private, so the VM cannot clone it and holds no key of yours. Your own computer sends the repo as a bundle: one file that holds the whole repo.

On your own computer, in your local stacks checkout:

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.60:      # scp, on your own computer: copies the file to the VM's home folder
```

Then, over the ssh session on the forge VM:

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
| `FORGE_UID` | The user id of `FORGE_USER`. Also the user id TrueNAS must let write to the export. | `1000` | no |
| `FORGE_GID` | The group id of `FORGE_USER`. Also the group id TrueNAS must let write to the export. | `1000` | no |
| `FORGE_BIND` | The forge VM's own address, so your browser and the runner can reach the forge. | `192.168.1.60` | no |
| `FORGE_PORT` | The port of the forge's web page. | `3000` | no |
| `FORGE_URL` | The address the forge's page answers at, with the port: what you type in a browser and what the runner connects to. | `http://192.168.1.60:3000` | no |
| `FORGE_DOMAIN` | The name the forge uses for itself in its links. Use the same address as `FORGE_BIND`. | `192.168.1.60` | no |
| `FORGE_DATA` | The folder on the VM where the TrueNAS share is mounted; the forge keeps all its data there. | `/mnt/forge-data` | no |
| `TRUENAS_ADDR` | TrueNAS's address. The forge mounts the share from it. | `192.168.1.20` | no |
| `TRUENAS_EXPORT` | The NFS export path on TrueNAS for the forge's data. | `/mnt/tank/forge` | no |
| `FORGE_ADMIN_USER` | The forge's admin login. You will log in as this user. | `forge-admin` | no |
| `FORGE_ADMIN_EMAIL` | The admin's email address, as the forge asks for it. Use any address you control. | `admin@example.com` | no |
| `FORGE_ADMIN_PASSWORD` | The admin's password. Make one with `openssl rand -hex 24` and keep it in this file only. | the output of `openssl rand -hex 24` | **yes** |

Make the admin password with a command that ships with Ubuntu, then paste the output into `FORGE_ADMIN_PASSWORD`:

```
openssl rand -hex 24      # openssl, on the forge VM; copy the output into FORGE_ADMIN_PASSWORD
```

The password and the `.env` file are secrets. Do not put them in git, in a file other than `.env`, or in a message to anyone.

Then run the setup script. It mounts the TrueNAS share, installs Docker and the repo's tools with mise, creates the service user and folders, and sets restart on boot:

```
sudo ./compose/forge-vm/setup.sh      # bash, on the forge VM: checks the VM, mounts the share, installs Docker and the repo's tools with mise, creates the service user and folders, sets restart on boot
```

If you skipped the copy in step 2, `setup.sh` creates `compose/forge-vm/.env` and exits with status 1. Fill it in and run `sudo ./compose/forge-vm/setup.sh` again.

Start the forge:

```
sudo docker compose -f compose/forge-vm/docker-compose.yml up -d      # docker compose, on the forge VM
```

**Updating the repo later:** on your own computer, run `git bundle create stacks.bundle main` and the `scp` command again. On the forge VM, inside the existing `stacks` folder, run `git pull ~/stacks.bundle main` (git, on the forge VM). Do not delete the `stacks` folder to start over: your `.env` lives in it and git does not track it.

**What you should see:** open `FORGE_URL` in a browser (for example `http://192.168.1.60:3000`). The forge's page answers. Log in as `FORGE_ADMIN_USER` with `FORGE_ADMIN_PASSWORD`. Running `sudo ./compose/forge-vm/setup.sh` again ends with the line `changes: 0`, because nothing needed changing.

## 3. Runner VM: make the token, fill in one file

Make the registration token on the forge's page, logged in as the admin: **Settings**, then **Actions**, then **Runners**, then **create new runner**. Copy the token it shows; you will paste it into the runner VM's `.env` in step 4.

Connect to the runner VM from your own computer:

```
ssh youruser@192.168.1.70      # ssh, on your own computer (use the runner VM's address and user)
```

## 4. Runner VM: get the repo onto the VM

As in step 2, on your own computer, in your local stacks checkout:

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.70:      # scp, on your own computer: copies the file to the VM's home folder
```

Then, over the ssh session on the runner VM:

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
| `DOCKER_GID` | The group id of the `docker` group on this VM, so the runner can use Docker. Leave the example for now; step 5 tells you how to get the real number. | `999` | no |
| `RUNNER_DATA` | The folder on the VM where the runner keeps its state. | `/srv/runner` | no |
| `RUNNER_NAME` | The name the runner shows on the forge's page. | `runner-vm` | no |
| `FORGE_URL` | The forge's address, the same value as in the forge VM's `.env`. | `http://192.168.1.60:3000` | no |
| `RUNNER_REGISTRATION_TOKEN` | The one-time token from step 3. The runner uses it once to register. | the token from the forge's page | **yes** |
| `TRUENAS_ADDR` | TrueNAS's address. The runner must not reach it; the setup script blocks it. | `192.168.1.20` | no |
| `PROXMOX_ADDR` | The Proxmox API's address. The runner must not reach it; the setup script blocks it. | `192.168.1.10` | no |

The token is a secret. Paste it into this file only.

## 5. Runner VM: run the setup script and start the runner

```
sudo ./compose/runner-vm/setup.sh      # bash, on the runner VM: checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, blocks outbound traffic to TRUENAS_ADDR and PROXMOX_ADDR, sets restart on boot
```

The setup script installs Docker, so the `docker` group exists after it. Print its id with `getent group docker` (`getent`, on the runner VM; it ships with Ubuntu). If it differs from the `DOCKER_GID` you left in step 4, write the number into the file with `nano compose/runner-vm/.env` and run `sudo ./compose/runner-vm/setup.sh` again.

Start the runner:

```
sudo docker compose -f compose/runner-vm/docker-compose.yml up -d      # docker compose, on the runner VM
```

**What you should see:** on the forge's page, under **Settings**, **Actions**, **Runners**, the runner named `RUNNER_NAME` shows as online. A rerun of `sudo ./compose/runner-vm/setup.sh` ends with `changes: 0`.

## 6. Test: a green check and a red one

This runs on the forge VM, over its ssh session, so the test repo is made where the forge is. You need only git.

1. **Make the test repo on the forge.** In the browser, logged in as the admin, click **New repository**, name it `check-test`, and create it with the default settings.

2. **Make the folder and the first commit, which passes** (`mkdir`, `printf` and `git`, on the forge VM):

```
mkdir ~/check-test && cd ~/check-test      # mkdir and cd, on the forge VM
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

6. **Check the runner cannot reach TrueNAS or Proxmox.** Run these from the runner VM over its ssh session (`nc` ships with Ubuntu). Each should fail: no connection, and `nc` exits with status 1 after about 3 seconds.

```
nc -zw3 192.168.1.20 443; echo "exit $?"      # nc, on the runner VM: TRUENAS_ADDR, port 443; must not connect
```

```
nc -zw3 192.168.1.10 8006; echo "exit $?"      # nc, on the runner VM: PROXMOX_ADDR, the Proxmox API's port 8006; must not connect
```

If either one connects, the block is missing: tell the architect; do not go on.

## 7. Reboot check, for each VM

On the forge VM, then on the runner VM, one at a time:

```
sudo reboot      # systemd, on the VM
```

Wait about 2 minutes, reconnect with ssh, then check:

```
sudo docker compose -f compose/forge-vm/docker-compose.yml ps      # docker compose, on the forge VM: forge should be "running"
```

```
sudo docker compose -f compose/runner-vm/docker-compose.yml ps      # docker compose, on the runner VM: runner should be "running"
```

Then open `FORGE_URL` in a browser: the forge's page should be back by itself, and after the runner VM's reboot the runner should show online on the forge's page again. Nothing is started by hand.

## 8. What this does not cover

- Role tokens and a protected `main` branch.
- The nightly backup to the real share. The backup and restore scripts exist and are run by hand, from the stacks checkout on the forge VM: `bash compose/forge/backup.sh` writes a copy to the backup folder, and `bash compose/forge/restore.sh` restores the newest copy into an empty data folder (stop the forge first with `sudo docker compose -f compose/forge-vm/docker-compose.yml down`).
- SOPS-encrypted secrets.
- Health files.
- Moving real repos and their history to the forge.

## 9. Friction

If anything in these steps annoyed you or cost you time, tell the architect, or add one line to `outcomes/oc6-forge-rebuildable.md` in the workbench, under `## Friction`. Nothing else is needed.
