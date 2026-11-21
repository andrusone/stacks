# Runbook: one core node (CORE-FR-10)

The owner's steps to bring up one core node (DNS, time and the zone) on a VM, in order. Each step says where it runs. The setup script does the rest and says what it changed.

## 1. Make the VM from the golden image

Make the VM from the golden image as [REF-golden-image.md](REF-golden-image.md) describes. Name it and give it its fixed address on the LAN (the one you will put in `CORE_BIND`) with `hostbook`, as the zone repository's README describes, not with `post-clone-server.sh`. Nothing else on the VM is set by hand.

## 2. Get the repo onto the VM

The VM clones the stacks repo from the NAS share, as step 1 of [RUNBOOK-host.md](RUNBOOK-host.md) does: `git clone -b main /nas/projects/andrusone/stacks ~/stacks`. No bundle, no `scp`, and no key of yours on the VM.

## 3. Before the setup: a public resolver on the VM

The setup needs names (apt, Docker and mise fetch from the internet), and the LAN resolvers may be down while you build the node. So set the VM's own DNS to a public resolver such as `1.1.1.1` first, by hand, in netplan. Find the interface with `ip -o route show default` (the name after `dev`). Then, in the file under `/etc/netplan/` that holds it, add under that interface:

```
nameservers:
  addresses: [1.1.1.1]
```

The entry looks like this, with your interface's name in place of `<interface>`; keep the indentation:

```
network:
  ethernets:
    <interface>:
      nameservers:
        addresses: [1.1.1.1]
```

Then run `sudo netplan apply` on the VM.

The setup does not change the VM's resolver. Reading `compose/core-vm/setup.sh`, `host.sh` and `setup-stages.sh`, its stages are preflight, `host.sh` (chrony, ufw and Docker's ports), the zone-sync units, a first zone sync and `core-up`. None of them writes netplan or `resolv.conf`. So after the setup the VM keeps the resolver you gave it, and you set it again by hand if you want it to ask its own DNS.

## 4. Run the setup

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

## 5. Prove the node before changing DHCP

From another machine on `CORE_LAN` (not the VM), in a stacks checkout, with `dig` and `nc` installed:

```
mise run core-lan-prove -- <CORE_BIND>     # mise, on the client: one ok or FAIL line per check; exit 0 only if every check is ok
```

Read the lines this way:

- `ok dns: nas.core.andrusonline.com via <CORE_BIND> is ...`: the node answers a name in the zone. `CORE_PROVE_HOST` names another host, default `nas.core.andrusonline.com`.
- `ok dns: example.com via <CORE_BIND> is ...`: the node also resolves a name outside the zone.
- `ok dnssec: dnssec-failed.org ... is SERVFAIL`: the node validates DNSSEC and refuses a broken signature.
- `ok time: offset ...s`: the node answers time on 123. The client needs `ntpdate` for this; without it the line reads `skip time`, which is not a failure.
- `ok closed: <CORE_BIND>:<port> refuses`, five lines (5300, 5353, 12300, 22222, 8080): the ports that must stay closed to the LAN.

A `FAIL` line names the check. Fix it on the node and run the proof again. Run it from a LAN client, not from the VM: the point is that a client on the LAN gets the answers and a client off it does not.

Prove each new node this way before you change anything on the network.

## 6. Cutover (the owner's steps)

The two current nodes are the household DNS: `vpnx1` (`10.10.20.21`, `ns1`) and `vpnx2` (`10.10.20.24`, `ns2`). Omada hands clients their resolvers by DHCP. Do the steps in this order:

1. Build the new nodes at new addresses: steps 1 to 4 on each, named and addressed with `hostbook`.
2. Prove each one with step 5. Do not go on until both pass.
3. Change the DHCP DNS servers in Omada to the new nodes' addresses.
4. In the zone (`hostbook` makes the change and raises the serial), point the records that name the old nodes at the new addresses: `ns1` and `ns2`, and the `dns`, `ntp` and `chrony` records, which also list the old nodes.
5. Retire `vpnx1` and `vpnx2` once clients use the new nodes. A pushed zone reaches the DNS nodes within 10 minutes.

The zone has records the new stack does not provide. Keep or drop each one yourself; the story does not delete them:

- `home` (`10.10.20.26`): the Homepage VIP, held by keepalived on `vpnx1` (primary) or `vpnx2` (backup) according to the zone file.
- `homepage`: the alias for `home`.

Find them in the `zone` repository's `db.core.andrusonline.com`, under "VIRTUAL / NETWORK SERVICE ALIASES".

## If it stops

- `systemd is not running`: the VM needs systemd. A container, a WSL shell or a shell without systemd cannot be a core node.
- `CORE_ZONE_URL ... not valid`: give an `http://` or `https://` URL with an address, not a name; or an absolute path to a folder that exists; or a `file://` URL of one.
- `zone-sync: no copy yet`: the Git host at `CORE_ZONE_URL` must be reachable from the VM. Read the log with `journalctl -u zone-sync.service`, fix the address or the network, and run the setup again.
