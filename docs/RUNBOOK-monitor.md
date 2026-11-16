# Runbook: the monitor on a new Ubuntu Server VM

The steps to run the monitor (HL-FR-19) on a fresh VM. Nothing else is needed on your own computer except ssh. Each command says what tool it uses and where it runs.

## 1. Make the VM by hand

- Create a VM running **Ubuntu Server**, with an SSH user that has **sudo**.
- Give it a **fixed address** (a static address or a DHCP reservation). Write the address down: you will need it as `MONITOR_BIND`.
- Install nothing else. The setup script installs the rest.

Connect from your own computer:

```
ssh youruser@192.168.1.50      # ssh, on your own computer (use your VM's address and user)
```

## 2. Clone the repo and fill in one file

Everything below runs on the VM, over that ssh session.

```
git clone git@github.com:andrusone/stacks.git      # git, on the VM
cd stacks
cp compose/monitor/.env.example compose/monitor/.env   # cp, on the VM
```

The VM needs read access to the repo. Use your own key for that (add it to your GitHub account, or use a deploy key); this runbook does not create keys.

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
sudo docker compose -f compose/monitor/docker-compose.yml up -d      # docker compose, on the VM
```

If you skipped the copy in step 2, `setup.sh` creates `compose/monitor/.env` and exits with status 1. Fill it in and run `sudo ./setup.sh` again.

## 3. What you should see

- **The status page:** open `http://<MONITOR_BIND>:<GATUS_PORT>` in a browser (for example `http://192.168.1.50:8081`). Within 2 minutes it lists one target, `starter`, with its answers up: host, service and right answer. (A stack with no declared need has no dependency answer, so the starter shows three.)
- **The alert service:** `http://<MONITOR_BIND>:<NTFY_PORT>` answers in a browser.
- **Running it again:** `sudo ./setup.sh` again ends with the line `changes: 0`, because nothing needed changing.

## 4. Your phone, one line

Install the **ntfy** app on your phone. Add a subscription with the server `http://<MONITOR_BIND>:<NTFY_PORT>` and the topic `<NTFY_TOPIC>`. To send a test message from any computer on your network with curl:

```
curl -d "hello" http://<MONITOR_BIND>:<NTFY_PORT>/<NTFY_TOPIC>      # curl, on any computer on your network
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
sudo reboot      # systemd, on the VM
```

Wait about 2 minutes, reconnect with ssh, then check:

```
sudo docker compose -f compose/monitor/docker-compose.yml ps      # docker compose, on the VM: gatus, ntfy and starter should all be "running"
curl -s http://<MONITOR_BIND>:<NTFY_PORT>/v1/health      # curl, on the VM: should print {"healthy":true}
```

Then open the status page in a browser as in section 3. Both should be back by themselves.

## 6. Friction

If anything in these steps annoyed you or cost you time, tell the architect, or add one line to `outcomes/oc8-four-answers-per-stack.md` in the workbench, under `## Friction`. Nothing else is needed.
