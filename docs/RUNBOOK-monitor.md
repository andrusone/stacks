# Runbook: the monitor on a new VM

The steps to run the monitor (HL-FR-19) on a fresh VM. On your own computer you need only ssh (it comes with OpenSSH). Each command says what tool it uses and where it runs.

## 1. Make the VM from the golden image

Clone a new VM from the golden image. The image already has ssh, git, ufw and cifs-utils, so you install none of them, and it mounts the TrueNAS shares itself. See [REF-golden-image.md](REF-golden-image.md) for what the image gives every VM.

Connect from your own computer:

```
ssh youruser@192.168.1.50      # ssh, on your own computer (use your VM's address and user)
```

Then name and address the VM:

- Name it and add it to the zone with `hostbook`: run `hostbook` with no arguments (the console asks four questions and offers to add the host), or `hostbook add <name> <address>` if you already have both. See `machine:docs/SPEC-hostbook.md`.
- Set its hostname and static address on the VM with `machine --profile server --stage-clone`. It asks for the host name, the static IPv4 address with its CIDR, the gateway and the DNS server, writes the new network file to a staging path and prints it with its diff. It applies nothing until you type `apply`. The machine repo documents this route (`machine:docs/SPEC-machine.md`, MC-FR-14) and no by-hand netplan route, so none is given here.
- Write down the **fixed address** you gave the VM: you will need it as `MONITOR_BIND`.

## 2. Get the repo onto the VM and answer setup's questions

The VM clones the repo from the NAS share, so it needs no bundle, no `scp` and no key of yours. The share's clone must be on branch `main` (a CIFS share has no executable bit, so run from the VM's own clone, never from the share).

Over the ssh session on the VM:

```
git clone -b main /nas/projects/andrusone/stacks ~/stacks      # git, on the VM: makes the stacks folder from the share's main branch
```

```
cd ~/stacks      # cd, on the VM
```

Then make the NAS folders for the stacks, once. This also makes the monitor's backup folder on the share:

```
./host/nas-layout.sh      # bash, on the VM, as your normal user: makes the folders for forge, monitor and core on the share and prints one [step] or [change] line per item, then changes: n (a rerun ends changes: 0)
```

There is no file to copy or edit. `setup.sh` asks for the six values below, each with a default: press Enter to accept it. It writes your answers to `compose/monitor/.env`.

The six values:

| Variable | What it means | Default |
|---|---|---|
| `MONITOR_USER` | The service user that owns the monitor's folders. | `monitor` |
| `MONITOR_DIR` | The folder where the monitor keeps its state. | `/srv/monitor` |
| `MONITOR_BIND` | The VM's own address, so your browser and phone can reach the monitor. | the VM's address on its network (for example `192.168.1.50`) |
| `GATUS_PORT` | The port of the status page. | `8081` |
| `NTFY_PORT` | The port of the alert service. | `8090` |
| `NTFY_TOPIC` | Your phone's topic: a secret word, never committed to git. | a generated word (the script never prints it; section 4 shows how to read it) |

The topic is a secret. Do not put it in git, in a file other than `.env`, or in a message to anyone.

Then run the setup script:

```
./setup.sh      # bash, on the VM, as your normal user (not sudo): asks for the six values (Enter accepts each default), then calls sudo itself for each step that needs it; checks the VM, installs Docker and the repo's tools with mise, creates the service user and folders, sets restart on boot
```

To skip the questions, give a value as an environment variable of the same name, or run `./setup.sh --yes` to take every default.

If `ufw` is active on the VM, `setup.sh` opens the two ports, `GATUS_PORT` and `NTFY_PORT`, and prints that it did. If `ufw` is not active, it changes nothing.

The last lines show the two addresses marked "once started". Then `setup.sh` asks `Start the monitor now? [Y/n]`: press Enter (yes) and it runs the compose command below for you, and says whether it worked. If the monitor is already running, it says so and asks nothing. Answer `n`, or use `--yes`, and it starts nothing; the command to run by hand is:

```
sudo docker compose -f compose/monitor/docker-compose.yml up -d      # docker compose, on the VM (only if you did not start it from setup.sh)
```

**Updating the repo later:** the share's clone must be on `main` and up to date first. On the VM, inside the existing `stacks` folder, run `git pull` (git, on the VM). Do not delete the `stacks` folder to start over: your `.env` lives in it and git does not track it.

**Pulling from GitHub, once:** the clone above points at the NAS share, so the timer that picks up new health files would read a share that goes stale. Give the monitor its own read-only key and point it at GitHub:

```
git-access --role prod --deploy-repo andrusone/stacks      # git-access, on the VM: makes this VM's deploy key and prints the public key
```

Add the printed public key as a read-only deploy key on `andrusone/stacks` on GitHub (Settings, Deploy keys). That is the one step by hand: no script of ours registers a key. Then rerun the setup script:

```
./setup.sh      # bash, on the VM, as your normal user: with the key in place, sets origin to git@github.com:andrusone/stacks.git and says so
```

If the key is missing, setup leaves origin alone and says `run git-access --role prod --deploy-repo andrusone/stacks, then rerun`. Check that the VM can reach GitHub:

```
git -C ~/stacks ls-remote origin      # git, on the VM: lists the refs of andrusone/stacks; an error means the deploy key is not registered yet
```

## 3. What you should see

- **The status page:** open `http://<MONITOR_BIND>:<GATUS_PORT>` in a browser (for example `http://192.168.1.50:8081`). Within 2 minutes it lists one target, `starter`, with its answers up: host, service and right answer. (A stack with no declared need has no dependency answer, so the starter shows three.)
- **The alert service:** `http://<MONITOR_BIND>:<NTFY_PORT>` answers in a browser.
- **Running it again:** `./setup.sh` again ends with the line `changes: 0`, because nothing needed changing. When the monitor is already running, setup says `monitor already running` and asks nothing about starting, so `--yes` is not needed for `changes: 0`.

## 4. Your phone, one line

Install the **ntfy** app on your phone. Add a subscription with the server `http://<MONITOR_BIND>:<NTFY_PORT>` and the topic `<NTFY_TOPIC>`. To read the topic, over the ssh session on the VM: `grep '^NTFY_TOPIC=' compose/monitor/.env` (grep, on the VM). To send a test message, from the VM over the ssh session:

```
curl -d "hello" http://<MONITOR_BIND>:<NTFY_PORT>/<NTFY_TOPIC>      # curl, on the VM
```

The message should arrive on the phone within seconds.

## 4b. The outside heartbeat (silence alert)

The monitor pings an outside service every 5 minutes while its own Gatus answers. If the monitor goes quiet, the outside service alerts you. Setup prints `heartbeat: on` or `heartbeat: off (set HEARTBEAT_URL)`.

1. Make a free dead-man's-switch check at an outside service (any one that alerts on silence) with a **15 minute grace**.
2. Put its URL in `compose/monitor/.env` as `HEARTBEAT_URL=<the URL>` (over the ssh session on the VM, not in git).
3. Prove it: `sudo systemctl stop docker` on the VM. A message arrives within 15 minutes. Then `sudo systemctl start docker`.

## 5. What this does not cover

- Beszel (the host's health stays "unknown" for now; the host check is only a network check).
- The timer that pulls new checks from git.
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
