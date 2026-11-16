# Runbook: the monitor on a new Ubuntu Server VM

The steps to run the monitor (HL-FR-19) on a fresh VM. On your own computer you need only ssh and scp (both come with OpenSSH) and the git checkout of this repo you already have. Each command says what tool it uses and where it runs.

## 1. Make the VM by hand

- Create a VM running **Ubuntu Server**, with an SSH user that has **sudo**.
- Give it a **fixed address** (a static address or a DHCP reservation). Write the address down: you will need it as `MONITOR_BIND`.
- Install nothing else. The setup script installs the rest.

Connect from your own computer:

```
ssh youruser@192.168.1.50      # ssh, on your own computer (use your VM's address and user)
```

## 2. Get the repo onto the VM and fill in one file

The repo is private, so the VM cannot clone it and holds no key of yours. Your own computer sends the repo as a bundle: one file that holds the whole repo.

On your own computer, in your local stacks checkout:

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
```

```
scp stacks.bundle youruser@192.168.1.50:      # scp, on your own computer: copies the file to the VM's home folder
```

Then, over the ssh session on the VM:

```
git clone stacks.bundle stacks      # git, on the VM: makes the stacks folder from the bundle
```

```
cd stacks      # cd, on the VM
```

```
cp compose/monitor/.env.example compose/monitor/.env      # cp, on the VM
```

Edit the file with `nano` (ships with Ubuntu Server):

```
nano compose/monitor/.env      # nano, on the VM
```

The six values:

| Variable | What it means | Example |
|---|---|---|
| `MONITOR_USER` | The service user that owns the monitor's folders. Leave `monitor` unless you have a reason. | `monitor` |
| `MONITOR_DIR` | The folder where the monitor keeps its state. | `/srv/monitor` |
| `MONITOR_BIND` | The VM's own address, so your browser and phone can reach the monitor. Required. | `192.168.1.50` (use your VM's address) |
| `GATUS_PORT` | The port of the status page. | `8081` |
| `NTFY_PORT` | The port of the alert service. | `8090` |
| `NTFY_TOPIC` | Your phone's topic: a secret word, never committed to git. Required. | the output of the command below |

Make the topic word with a command that ships with Ubuntu:

```
openssl rand -hex 8      # openssl, on the VM; copy the output into NTFY_TOPIC
```

The topic is a secret. Do not put it in git, in a file other than `.env`, or in a message to anyone.

Then run the setup script and the compose command:

```
sudo ./setup.sh      # bash, on the VM: checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, sets restart on boot
```

```
sudo docker compose -f compose/monitor/docker-compose.yml up -d      # docker compose, on the VM
```

If you skipped the copy in step 2, `setup.sh` creates `compose/monitor/.env` and exits with status 1. Fill it in and run `sudo ./setup.sh` again.

**Updating the repo later:** on your own computer, run `git bundle create stacks.bundle main` and the `scp` command again. On the VM, inside the existing `stacks` folder, run `git pull ~/stacks.bundle main` (git, on the VM). Do not delete the `stacks` folder to start over: your `.env` lives in it and git does not track it.

## 3. What you should see

- **The status page:** open `http://<MONITOR_BIND>:<GATUS_PORT>` in a browser (for example `http://192.168.1.50:8081`). Within 2 minutes it lists one target, `starter`, with its answers up: host, service and right answer. (A stack with no declared need has no dependency answer, so the starter shows three.)
- **The alert service:** `http://<MONITOR_BIND>:<NTFY_PORT>` answers in a browser.
- **Running it again:** `sudo ./setup.sh` again ends with the line `changes: 0`, because nothing needed changing.

## 4. Your phone, one line

Install the **ntfy** app on your phone. Add a subscription with the server `http://<MONITOR_BIND>:<NTFY_PORT>` and the topic `<NTFY_TOPIC>`. To send a test message, from the VM over the ssh session:

```
curl -d "hello" http://<MONITOR_BIND>:<NTFY_PORT>/<NTFY_TOPIC>      # curl, on the VM
```

The message should arrive on the phone within seconds.

## 5. What this does not cover

- Beszel (the host's health stays "unknown" for now; the host check is only a network check).
- The timer that pulls new checks from git.
- The outside heartbeat that tells you if the monitor itself goes quiet.
- Rebuilding the monitor alone from scratch.
- Protection against a bad commit: a broken check file is not rejected yet.

**Check that it survives a reboot:**

```
sudo reboot      # sudo and reboot, on the VM
```

Wait about 2 minutes, reconnect with ssh, then check:

```
sudo docker compose -f compose/monitor/docker-compose.yml ps      # docker compose, on the VM: gatus, ntfy and starter should all be "running"
```

```
curl -s http://<MONITOR_BIND>:<NTFY_PORT>/v1/health      # curl, on the VM: should print {"healthy":true}
```

Then open the status page in a browser as in section 3. Both should be back by themselves.

## 6. Friction

If anything in these steps annoyed you or cost you time, tell the architect, or add one line to `outcomes/oc8-four-answers-per-stack.md` in the workbench, under `## Friction`. Nothing else is needed.
