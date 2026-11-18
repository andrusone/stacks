# Runbook: a hand-made VM becomes a Docker host

The steps to turn a VM (or a WSL shell, or a container) into a Docker host with one script (SK-FR-09). A VM comes from the golden image: see [REF-golden-image.md](REF-golden-image.md). Each command says what tool it uses and where it runs.

## 1. Get the repo onto the host

The repo is private, so the host cannot clone it and holds no key of yours. Your own computer sends it as a bundle: one file that holds the whole repo.

On your own computer, in your local stacks checkout:

```
git bundle create stacks.bundle main      # git, on your own computer: packs the main branch into one file
scp stacks.bundle youruser@192.168.1.50:~/  # scp, on your own computer: copies the file to the host's home folder (use your host's address and user)
```

Then, over your session on the host:

```
git clone -b main stacks.bundle stacks   # git, on the host: makes the stacks folder from the bundle's main branch
cd stacks                                # cd, on the host
```

## 2. Prepare the host

```
cd ~/stacks   # cd, on the host: a new login starts in your home folder, not in stacks
./host/prepare.sh      # bash, on the host, as your normal user (never root): installs Docker's engine and compose plugin from Docker's own apt repository, adds you to the docker group, enables Docker at boot where systemd runs; calls sudo itself for each change
```

The script stops, changing nothing, if you run it as root, if the system is not Ubuntu, if sudo, curl or gpg is missing, or if Docker's key does not have Docker's published fingerprint.

You see one `[step]` or `[change]` line per item, then a last line `changes: n`. The first run has `[change]` lines and `changes:` above 0. Run it again: the rerun ends `changes: 0`. A rerun is safe at any time.

## 3. Log out and in

The docker group applies only at a new login, so log out of the host and log in again (tools: `exit`, then `ssh` from your own computer). Or, in the same shell only, run `newgrp docker` (tool: `newgrp`), which opens a shell that has the group.

## 4. Run the smoke test

```
cd ~/stacks   # cd, on the host: a new login starts in your home folder, not in stacks
./host/smoke.sh      # bash, on the host: starts one throwaway busybox container until docker compose ps reports it healthy (tool: docker compose), prints the verdict, then removes it with docker compose down -v; it uses sudo only while you are not yet in the docker group
```

The last line is `smoke: healthy`, with exit 0. If it says `smoke: not healthy`, the line after it shows the container's state; look at `docker ps -a` (tool: docker). The first run pulls `busybox:1.36`, so the host needs network access.

## What the script does not do

- It starts no stack. Each stack's own `setup.sh` or compose file does that.
- The other `setup.sh` scripts still install Docker themselves (`setup.sh`, `compose/forge-vm/setup.sh`, `compose/runner-vm/setup.sh`). They install it only when it is missing, so running one after this script is fine.

## If it fails

Add one line to the workbench's `owner-log.md` (tool: any editor): `f OC2 <step> <what you saw>`, for example `f OC2 prepare.sh stopped at the fingerprint check`. Then commit and push it, so the architect reads it.
