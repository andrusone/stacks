# Runbook: one core node (CORE-FR-10)

The owner's steps to bring up one core node (DNS, time and the zone) on a VM, in order. Each step says where it runs. The setup script does the rest and says what it changed.

## 1. Make the VM from the golden image

Make the VM from the golden image as [REF-golden-image.md](REF-golden-image.md) describes. Give it a fixed address on the LAN (the one you will put in `CORE_BIND`). Nothing else on the VM is set by hand.

## 2. Get the repo onto the VM

Follow step 1 of [RUNBOOK-host.md](RUNBOOK-host.md): the stacks repo comes over as a bundle, and you clone it into a `stacks` folder in your home. The VM holds no key of yours.

## 3. Run the setup

On the VM, in the `stacks` folder:

```
./compose/core-vm/setup.sh     # bash, on the VM: asks for the node's values once, then runs each stage
```

It asks for these, with a default (Enter accepts):

| Value | What it is | Default |
|---|---|---|
| `CORE_BIND` | this VM's address | the default-route address |
| `CORE_LAN` | the LAN as a CIDR (DNS and NTP are open to it) | this address's /24 |
| `CORE_ADMIN` | the address or CIDR allowed to SSH in | the machine you are logging in from |
| `CORE_ZONE_URL` | the zone repository: by address, never a name, for example `http://192.168.1.20/zone.git`; or a folder path such as `/nas/projects/andrusone/zone`; or a `file://` URL of that folder | none: you give it |
| `CORE_ROLE` | `primary` or `secondary` | `primary` |
| `CORE_PEER` | the other node's address; leave empty until it exists | empty |
| ports (not asked) | DNS on 53 and NTP on 123 open to `CORE_LAN`; BIND on 5300 open to `CORE_PEER` only | fixed |

`CORE_ZONE_URL` is the `zone` repository's address on the owner's Git host until the forge exists. The setup refuses a name there, because the zone must load before DNS does.

When the `zone` repository is cloned on the NAS share, use the path form (`/nas/projects/andrusone/zone`) or its `file://` URL. It needs no key and no DNS, and the setup checks that the folder exists. A missing folder is refused.

The answers go to `compose/core-vm/.env` (git ignores it). A rerun reuses that file and asks nothing.

The setup then runs, each stage checking first:

1. preflight: apt, systemd, Docker and mise. A missing one stops here with a plain message, and nothing is written.
2. `host.sh`: chrony serves `CORE_LAN` only, ufw is default-deny with DNS and NTP open to `CORE_LAN` and SSH to `CORE_ADMIN`, and Docker's published ports obey the same rule. With `CORE_PEER` set, BIND's port 5300 (tcp and udp) is open to that peer and to no one else.
3. the zone-sync service and timer: copied into `/etc/systemd/system`, and `/etc/core/zone-sync.env` written; the timer is enabled and started (every 5 minutes).
4. a first zone sync, through the service, when BIND has no copy of the zone yet.
5. `mise run core-up` with the node's address, LAN, role and peer, and its ports: DNS on 53 (Unbound answers the LAN), NTP on 123, and BIND on 5300, the port the peer reaches.

It ends with `changes: n`. Run it again and it ends with `changes: 0`.

To see the steps without changing anything, run `./compose/core-vm/setup.sh --dry-run`. It asks nothing and writes nothing; values come from the environment or the defaults.

## 4. Prove it from another machine on the LAN

From another machine on `CORE_LAN` (not the VM):

```
mise run core-lan-prove -- <CORE_BIND>     # mise, in a stacks checkout: a DNS answer for the fixture host, a DNSSEC failure, a time query, and the closed ports probed
```

`CORE_PROVE_HOST` names the host it looks up (default `nas.core.andrusonline.com`); set it to any name in your zone.

Run it from a LAN client, not from the VM: the point is that a client on the LAN gets the answers and a client off it does not.

## If it stops

- `systemd is not running`: the VM needs systemd. A container, a WSL shell or a shell without systemd cannot be a core node.
- `CORE_ZONE_URL ... not valid`: give an `http://` or `https://` URL with an address, not a name; or an absolute path to a folder that exists; or a `file://` URL of one.
- `zone-sync: no copy yet`: the Git host at `CORE_ZONE_URL` must be reachable from the VM. Read the log with `journalctl -u zone-sync.service`, fix the address or the network, and run the setup again.
