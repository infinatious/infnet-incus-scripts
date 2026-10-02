# INFNET Incus scripts

Project-based workflow for a standalone (or clustered) [Incus](https://linuxcontainers.org/incus/) host: every project gets its own OVN network and Linux/Windows/Docker profiles, every instance gets a public IPv4 through 1:1 NAT, a Technitium DNS record, and nightly backups to NFS.

This repository replaces `microcloud-maintenance`. It targets Incus from the [Zabbly packages](https://github.com/zabbly/incus), with a local OVN control plane in place of MicroOVN.

- [Host setup](#host-setup)
- [Clustering](#clustering)
- [1:1 NAT](#11-nat)
- [Firewall](#firewall)
- [Authentik SSO](#authentik-sso)
- [Web UI branding](#web-ui-branding)
- [Scripts](#scripts)
- [DNS registration](#dns-registration)
- [Backups](#backups)

---

## Host setup

`host/setup-incus-host.sh` turns a clean Ubuntu 26.04 (or 24.04 / Debian 12-13) host into the environment the scripts expect. It is safe to re-run: each step checks what is already in place.

### 1. Deploy the repository and fill in `.env`

```bash
sudo git clone https://github.com/infinatious/infnet-incus-scripts.git /opt/infnet-incus-scripts
sudo chown -R "$USER": /opt/infnet-incus-scripts
cd /opt/infnet-incus-scripts
cp .env.example .env
```

Edit the **Host bootstrap** and **Authentik OIDC** sections of `.env`:

| Variable | Meaning |
|---|---|
| `INCUS_CHANNEL` | Zabbly channel: `stable` or `lts-7.0` - 1:1 NAT needs Incus 7.3+ or a 7.0 LTS release after 7.0.1 (see [1:1 NAT](#11-nat)) |
| `INCUS_ADMIN_USER` | User added to `incus-admin` so it can run `incus` without sudo |
| `STORAGE_DEVICE` | Disk (or partition) for the `zpool` ZFS pool, as a `/dev/disk/by-id/` path. Leave empty for a loop-file pool |
| `STORAGE_LOOP_SIZE` | With `STORAGE_DEVICE` empty: size of a loop-file ZFS pool (e.g. `700GiB`), for hosts whose only disk holds the OS. Incus creates it under `/var/lib/incus/disks` |
| `OVN_ENCAP_IP` | This host's management IP: OVN Geneve tunnel endpoint and, once clustered, its cluster address |
| `OVN_CENTRAL_ADDRESSES` | Clusters only: comma-separated `OVN_ENCAP_IP`s of the hosts that run the OVN databases (normally three), identical on every member (see [Clustering](#clustering)) |
| `UPLINK_PARENT` | NIC wired to the public network (no IP configured on it) |
| `UPLINK_IPV4_GATEWAY` | Upstream gateway with prefix, e.g. `172.31.232.1/21` |
| `UPLINK_IPV4_OVN_RANGES` | Addresses the OVN routers take for their own uplink ports (one per project network, used for shared outbound NAT) |
| `UPLINK_IPV4_ROUTES` | Public addresses handed out for 1:1 NAT - must not overlap `UPLINK_IPV4_OVN_RANGES` |
| `UPLINK_DNS_NAMESERVERS` | DNS servers handed to instances |
| `NFS_BACKUP_SOURCE` | NFS export mounted at `NFS_BACKUP_DIR` for backups |
| `OIDC_*` | See [Authentik SSO](#authentik-sso); leave `OIDC_CLIENT_ID` empty to skip |

### 2. Run it

```bash
sudo ./host/setup-incus-host.sh
```

If the storage disk still carries an old pool (for example the MicroCloud `local`/`zpool` pool), the script stops and lists the signatures it found. Re-run with `--wipe-storage-device` to erase them - this destroys everything on that disk.

### What it does

These are the exact commands, in order, if you'd rather run them by hand. Values in `<>` come from `.env`.

```bash
# Zabbly repository (verify the key fingerprint is 4EFC 5906 96CB 15B8 7C73 A3AD 82CC 8797 C838 DCFD)
curl -fsSL https://pkgs.zabbly.com/key.asc | gpg --show-keys --fingerprint
sudo mkdir -p /etc/apt/keyrings
sudo curl -fsSL https://pkgs.zabbly.com/key.asc -o /etc/apt/keyrings/zabbly.asc
sudo tee /etc/apt/sources.list.d/zabbly-incus.sources <<EOF
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/<INCUS_CHANNEL>
Suites: $(. /etc/os-release && echo "${VERSION_CODENAME}")
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

# Packages: Incus, its web UI, incus-extra (distrobuilder, incus-migrate), ZFS, and a local OVN
sudo apt-get update
sudo apt-get install -y incus incus-ui-canonical incus-extra zfsutils-linux ovn-central ovn-host \
  nfs-common jq curl python3 python3-yaml

# Local OVN control plane (Incus talks to unix:/run/ovn/ovnnb_db.sock by default)
sudo systemctl enable --now ovn-central ovn-host
sudo ovs-vsctl set open_vswitch . \
  external_ids:ovn-remote=unix:/run/ovn/ovnsb_db.sock \
  external_ids:ovn-encap-type=geneve \
  external_ids:ovn-encap-ip=<OVN_ENCAP_IP>

sudo usermod -aG incus-admin <INCUS_ADMIN_USER>

# Initialize Incus
cat <<EOF | sudo incus admin init --preseed
config:
  core.https_address: '[::]:8443'
networks:
- name: <UPLINK_NETWORK>
  type: physical
  config:
    parent: <UPLINK_PARENT>
    ipv4.gateway: <UPLINK_IPV4_GATEWAY>
    ipv4.ovn.ranges: <UPLINK_IPV4_OVN_RANGES>
    ipv4.routes: <UPLINK_IPV4_ROUTES>
    dns.nameservers: <UPLINK_DNS_NAMESERVERS>
- name: default
  type: ovn
  config:
    network: <UPLINK_NETWORK>
    ipv4.address: <IPV4_SUBNET_PREFIX>.0.1/24
    ipv4.nat: 'true'
    ipv6.address: none
storage_pools:
- name: <STORAGE_POOL>
  driver: zfs
  config:
    source: <STORAGE_DEVICE>
profiles:
- name: default
  devices:
    root: {path: /, pool: <STORAGE_POOL>, type: disk}
    eth0: {name: eth0, network: default, type: nic}
EOF
```

It then mounts the NFS backup export, installs the backup timer (only when the repository lives at `/opt/infnet-incus-scripts`, the path the units use), applies the OIDC settings, and brands the web UI.

The `default` project's OVN network uses `<IPV4_SUBNET_PREFIX>.0.0/24`, so project ID `0` is reserved for it.

### Validate

```bash
incus network show UPLINK --project default
incus storage show zpool
incus image list images: ubuntu/26.04 --format csv -c lt | head   # remote image server reachable
```

Images the scripts can deploy must be in the `default` project (project networks are created with `features.images=false`):

```bash
incus image copy images:ubuntu/26.04/cloud local: --alias ubuntu2604 --vm
incus image list -c lFtd
```

Windows images: `distrobuilder repack-windows` (from `incus-extra`) injects the VirtIO drivers into a Windows ISO, the same job `lxd-imagebuilder repack-windows` did.

### Cluster health report

```bash
host/cluster-health.sh
```

A read-only report (also first under Host Tasks in `start.sh`) that marks each check OK, WARN or FAIL and exits 1 on any FAIL:

- **Members:** status, roles, Incus version (all equal?), placement, number of database voters.
- **OVN databases:** NB/SB leader, and how recently each member answered it, read on the leader.
- **Gateways:** which host carries each project network's uplink traffic, flagged if it isn't an `ovn-chassis` member.
- **Instances:** per member, and a WARN when a redundant set (names differing only in the `-ctNN`/`-vsNN` number) runs entirely on one member. Also any instance in Error state.
- **Resource check:** headroom per member, as bars (green < 70 %, yellow < 85 %, red above), each with absolute figures:
  - **pool used:** WARN at 80 %, FAIL at 90 %.
  - **RAM allocated:** the sum of `limits.memory` of the running instances on the member against host RAM, with what's unallocated. Stopped instances' allocation and instances without a limit are listed separately. WARN at 90 %.
  - **RAM in use:** `MemTotal − MemAvailable`, counting the ZFS ARC above its minimum as free, since ZFS gives it back. WARN at 85 %, FAIL at 95 %.
  - **CPU load:** the 5-minute load average as a % of the member's threads, plus the vCPUs allocated to running instances. WARN at 80 %, FAIL at 100 %.

  The live figures come over ssh. Without it, RAM in use falls back to the Incus API (which counts the ARC as used), and CPU load is skipped.
- **Backups:** newest backup per running instance (WARN after `BACKUP_WARN_HOURS`, default 36; FAIL after `BACKUP_FAIL_HOURS`, default 192), the last run record, and on every member the backup timer, its last result and the NFS mount.
- **Hosts:** pending reboot, UEFI boot logo status, and every NFS mount in `/etc/fstab`.

It uses `sudo` locally (OVN status, the root-only backup folders), and `ssh` plus `sudo` to the other members by cluster address for the per-host checks. Members it can't reach over ssh show as WARN.

### Upgrading Incus

```bash
host/upgrade-incus.sh --check   # installed vs. available, on every member; changes nothing
host/upgrade-incus.sh           # rolling upgrade of every member, this host last
```

Both are also in the `start.sh` menu. Run them as your normal user on any member: the script uses `sudo` locally and `ssh -t` + `sudo` on the other members (by their cluster address), so every member needs this repository at the same path and SSH access from the host you run it on. On a standalone server it only upgrades that host.

- Upgrades only the `incus*` packages each member already has installed, the other members first and this host last. Instances keep running: restarting the Incus daemon doesn't stop containers or VMs. An upgraded member waits for the others before serving the cluster API again, so all members are done in one run. If one fails, fix it and re-run; members that are already current are skipped.
- **UI branding** is re-applied by its APT hook.
- **UEFI boot logo:** if the new package ships the same VM firmware, the logo's APT hook puts it back. If it ships new firmware, the hook keeps Zabbly's (stock logo), and the script then rebuilds the logo once on this host (~10 minutes, log in `/tmp/infnet-uefi-build.*.log`), copies it to every member that had the logo, and applies it there. Members that never had the logo are left alone.
- Running VMs keep their old QEMU and firmware until they are restarted.

Zabbly's `daily` channel isn't an upgrade path from `stable`: its versions (`1:0~…`) sort below the stable ones, so apt never offers them.

---

## Clustering

A standalone host built by `setup-incus-host.sh` can grow into a cluster without touching its instances.

Two databases have to survive a host failure, and with three members both do:

- **Incus** (dqlite) is replicated to up to three members automatically and needs a majority, 2 of 3, to keep the API working.
- **OVN** (northbound and southbound) runs as an OVN RAFT cluster on the hosts in `OVN_CENTRAL_ADDRESSES`, also needing 2 of 3. Every client (each host's `ovn-controller` and `ovn-northd`, and Incus) is given all members' addresses and fails over by itself. `ovn-northd` runs on every member and holds a lock, so one is active at a time.

Plan the three OVN members before starting and put the same `OVN_CENTRAL_ADDRESSES` in every host's `.env`, including the first host. Further hosts can join as chassis-only members (leave them out of the list). A two-member cluster has no failure tolerance at all, for either database.

### 1. Convert the existing host (once)

```bash
sudo host/cluster-enable.sh --add-member <new-host-short-name>
```

- Converts this host's standalone OVN databases into a one-member OVN RAFT cluster (contents kept; the standalone files are copied to `/var/lib/ovn/standalone-backup`), serving clients on `OVN_ENCAP_IP` (northbound tcp/6641, southbound tcp/6642, RAFT tcp/6643-6644). It's done by `ovn-ctl` from the cluster options the script writes to `/etc/default/ovn-central`.
- Points this host's OVN chassis, `ovn-northd` and Incus (`network.ovn.northbound_connection`) at every address in `OVN_CENTRAL_ADDRESSES`. Members that don't exist yet are skipped until they come up.
- Sets `cluster.https_address=<OVN_ENCAP_IP>:8443` (clustering can't use the `[::]` wildcard) and runs `incus cluster enable`.
- Prints a single-use join token per `--add-member`. Later tokens: `incus cluster add <name>` on any member.

### 2. Join each new host

On the new host: clone the repository to `/opt/infnet-incus-scripts`, create its `.env` (its own `STORAGE_DEVICE` or `STORAGE_LOOP_SIZE`, `UPLINK_PARENT`, `OVN_ENCAP_IP`, plus the shared `OVN_CENTRAL_ADDRESSES`), then:

```bash
sudo host/cluster-join.sh --token <token> [--wipe-storage-device]
```

It installs the same packages as `setup-incus-host.sh`, checks it can reach the cluster and an existing OVN database member, joins the OVN RAFT cluster through that member if its own `OVN_ENCAP_IP` is in `OVN_CENTRAL_ADDRESSES` (otherwise it doesn't run the OVN databases at all), points its OVN chassis at every OVN member, and joins with its own `zpool` disk and uplink NIC (`member_config`). Networks, projects, profiles and OIDC come from the cluster. It also sets up the NFS mount, backup timer and UI branding. The host must be clean: it refuses to join if Incus is already initialized there.

Join the remaining OVN members promptly: while only two of three have joined, OVN needs both of them up.

### Changing the OVN members later

Edit `OVN_CENTRAL_ADDRESSES` in every member's `.env`, then re-run `cluster-enable.sh` on the first host and `cluster-join.sh` (no token) on the others; on an existing member it skips the join. That re-points every client. Removing a database member from the RAFT cluster itself is a manual `ovn-appctl -t /var/run/ovn/ovn{nb,sb}_db.ctl cluster/kick` on a remaining member.

### Checking OVN health

```bash
sudo ovn-appctl -t /var/run/ovn/ovnnb_db.ctl cluster/status OVN_Northbound   # Role, Leader, Servers
sudo ovn-appctl -t /var/run/ovn/ovnsb_db.ctl cluster/status OVN_Southbound
```

### Requirements and caveats

- **Network:** members reach each other on tcp/8443 (Incus), tcp/6641-6644 (OVN clients and RAFT) and udp/6081 (Geneve). Each member's `UPLINK_PARENT` must be on the same public L2 network. On VLAN 29, new hosts also need the same UniFi rules as the first (NFS, Authentik).
- **What a host failure takes down:** with three members, only the instances on the failed host. The other members' instances, networking (including gateways, which OVN moves to a surviving host), 1:1 NAT and the API keep working.
- **No new public IPs while a member is down:** Incus refuses to create or delete network forwards unless every member is online (`peer node ... is down`), so `create-instance.sh --public-ip` fails cleanly (it removes the half-made instance) until the host is back. Instances without a public IP can still be created. If a host is gone for good, `incus cluster remove --force <member>` lifts this.
- **Storage stays per-host ZFS:** each instance lives on one member; `incus move <instance> --target <member>` copies it (no live migration), and an instance goes down with its host. Shared storage (Ceph) is what buys failover.
- **Placement:** `create-instance.sh` lets Incus pick the member (the least loaded) unless `--target <member>` is given.
- **Backups:** on a cluster, `backup-instances.sh` only backs up the instances on the member it runs on, so the timer installed on every member covers them all (or run one `--all-members` job instead).

Tested end to end on three lab VMs:
- An existing instance and its 1:1 NAT kept working through `cluster-enable.sh`, and the OVN contents carried over into the new RAFT cluster.
- After both `cluster-join.sh` runs, instances on each member had working 1:1 NAT (inbound, and outbound from their own public IP), and traffic between members worked.
- The first host was then force-stopped while it was the leader of the Incus database and both OVN databases, and hosted the active gateway of every network. Within 20 seconds:
  - both of the others had elected new leaders and moved the gateways;
  - instances on the surviving hosts kept inbound, 1:1 NAT outbound and shared-router NAT outbound;
  - the API answered, and instances without a public IP could still be created.
- When restarted, the host rejoined everything by itself and its instance came back working.

---

## 1:1 NAT

Every instance gets one public IPv4 that maps to it in both directions. Incus builds this from two halves:

| Direction | Mechanism | Command the scripts run |
|---|---|---|
| Inbound | A **network forward** on the project's OVN network, listening on the public IP, with the instance as default target (every port and protocol); its description is the instance name, so forward listings show which machine owns each public IP | `incus network forward create <network> <public-ip> target_address=<internal-ip> --description <instance> --project <project>` |
| Outbound | **`ipv4.address.external`** on the instance NIC, which adds a per-NIC SNAT rule so its traffic leaves from that same public IP instead of the network's shared address | `incus config device override <instance> eth0 ipv4.address=<internal-ip> ipv4.address.external=<public-ip> --project <project>` |

Constraints the scripts enforce:

- **Incus 7.3+ (or a 7.0 LTS release after 7.0.1).** Earlier versions implement a default-target forward as a portless OVN load balancer that collides with the NIC's SNAT rule: it drops the SYN-ACK of every connection the instance opens itself, so outbound TCP hangs while ping and inbound traffic still work. Fixed upstream in commit `42053c457d` ("Fix NAT for network forward default targets"), which uses a plain `dnat` rule instead. Verified on inf-93148 with Incus 7.0.1. `create-instance.sh` refuses older versions.
- **The forward must exist first.** Incus rejects `ipv4.address.external` unless the address is already a network forward on the NIC's network (it is validated against the forward table), so the NIC setting can't replace the forward - both are needed.
- **Public IPs come from the uplink's `ipv4.routes`.** Forward listen addresses must fall inside those routes. `ipv4.ovn.ranges` doesn't qualify: it is reserved for the OVN routers' own uplink addresses. `create-instance.sh` refuses to run if the uplink has no `ipv4.routes`.
- **Incus has no `--allocate` for forwards** (that was an LXD feature), so `lib/public-ip.sh` picks addresses itself: a random address in `ipv4.routes` that isn't the gateway, the uplink subnet's network/broadcast address, or already used by any forward, load balancer or OVN router on that uplink in any project.
- **The server needs the `network_ovn_external_nic_address` API extension**, which every version new enough for the fix above has. `create-instance.sh` checks for it.
- **`eth0` comes from the profile**, so the NIC settings are applied with `incus config device override`, which copies the profile device onto the instance. `config device set` only works once the instance has its own copy.
- **The internal address is pinned** (`ipv4.address`) to the address OVN handed out at boot, so the forward target stays valid across restarts. The NIC is re-plugged once at creation to apply it.

The public IP is also recorded in the instance's `user.public_ipv4` config key, which `delete-instance.sh`, `delete-project.sh` and `sync-dns-records.sh` read.

On a physical uplink, OVN answers ARP for the forward addresses itself (`ovn.ingress_mode=l2proxy`, the default), so the routes can be a slice of the uplink's own subnet without any upstream routing changes.

---

## Firewall

1:1 NAT forwards **every** port to the instance, so the forward decides nothing about what's reachable - a firewall does. `create-instance.sh` gives each instance its own **network ACL**, named after the instance and attached to its `eth0`:

| Direction | Default |
|---|---|
| Inbound | Rejected, except **ICMP** (ping, for every instance) and **SSH (tcp/22)** for Linux profiles or **RDP (tcp/3389)** for Windows profiles |
| Outbound | Allowed |

OVN ACLs are stateful (replies to the instance's own connections get back in), and Incus automatically allows DHCP, DNS and ping to the network's router, so addressing and name resolution keep working. Instances without a public IP get the same ACL.

The ACL only filters traffic that reaches an instance **through the project router**, i.e. from outside its network (public IP, other projects, INFNET). Traffic between instances on the **same** project network isn't blocked by the default inbound reject, *as long as the sender has an ACL too*: its egress `allow` and OVN's stateful ACLs let the connection through. Every instance made by these scripts has one. An instance created by hand without an ACL **is** filtered by the destination's ACL (connection refused). Verified on us-west 2026-10-01.

### Routing a remote subnet through a gateway instance

An instance can act as a router for another subnet, e.g. a WireGuard site-to-site gateway. Set the subnet as a route on its NIC, and the project router forwards that subnet to it:

```bash
incus config device set <gateway> eth0 ipv4.routes=<remote-subnet> --project <project>
```

That also lets the gateway send traffic with the remote subnet's source addresses (OVN port security accepts them). The gateway instance needs IP forwarding on, and an ACL rule allowing its **own** project subnet (all TCP/UDP), which forwarded traffic and its replies need. Instances behind it need no rules for traffic from the remote side. Containers using WireGuard also need `linux.kernel_modules=wireguard`.

**Opening more ports** for one machine means adding an ingress rule to its ACL:

- Web UI: *Networks > ACLs* in the instance's project, open the ACL with the instance's name, add an **ingress** rule (action `allow`, protocol, destination port).
- CLI: `incus network acl rule add <instance> ingress action=allow protocol=tcp destination_port=443 description=HTTPS --project <project>`

Don't add ports on the *Forwards* screen: the forward already sends everything, and the ACL is what filters it.

`delete-instance.sh` and `delete-project.sh` delete the ACL with the instance. `restore-instance.sh` recreates a missing ACL with only its default rules (ICMP, plus RDP if the backup's `image.os` is Windows or SSH otherwise), so extra ports have to be re-added after a restore.

The NIC keys the scripts set are `security.acls=<instance>`, `security.acls.default.ingress.action=reject` and `security.acls.default.egress.action=allow` (both defaults are `reject` in Incus, which would also block outbound traffic).

---

### Managing an instance's firewall

```bash
./firewall-manager.sh                                                       # interactive
./firewall-manager.sh --project-id 23 --instance pd23-mcrft-ct01 --list
./firewall-manager.sh --project-id 23 --instance pd23-mcrft-ct01 --add tcp:25001 --description Minecraft
./firewall-manager.sh --project-id 23 --instance pd23-mcrft-ct01 --add tcp:8443 --source infnet --description Crafty
./firewall-manager.sh --project-id 23 --instance pd23-mcrft-ct01 --remove 6
```

It edits the instance's own ACL. `--add` takes `tcp`, `udp`, `both` (one rule each), `icmp4` or `icmp6`, with ports as a number, range or list (`tcp:8000-8100`, `udp:53,123`). `--source` limits a rule to CIDRs, and `infnet` means `10.100.0.0/16`. `--remove N` uses the numbers `--list` shows. Changes apply immediately. The interactive menu asks before removing the SSH/RDP rule, and the script warns if the ACL isn't attached to the instance's NIC.

## Authentik SSO

Incus accepts Authentik logins for both the web UI and the CLI.

### What Incus requires of the provider

Taken from the Incus source (`internal/server/auth/oidc`):

- **Public client, PKCE.** Incus has no client-secret setting; the web UI login uses the authorization code flow with PKCE and an empty secret.
- **Device code flow** for the CLI (`incus remote add ... --auth-type=oidc`).
- **Redirect URI:** `https://<the host name the browser used>/oidc/callback`.
- **Signed JWT access tokens.** Incus verifies the *access token* (issuer, signature against the provider's JWKS, expiry, and audience if `oidc.audience` is set). The username is its `email` claim, falling back to `sub`.
- **Tokens live in cookies** (`oidc_access`, `oidc_refresh`, `oidc_id`), each limited to ~4 KB by browsers.
- **Every authenticated user gets full admin.** OpenFGA is the only authorization method Incus supports alongside OIDC, and without it any user who can log in controls the server. **Restrict who can log in on the Authentik side.**

### Authentik provider and application

Create a new OAuth2/OpenID provider and application (e.g. slug `incus-us-west`); the old `lxd-us-west` app is confidential and can't be reused as-is.

| Setting | Value |
|---|---|
| Client type | **Public** |
| Redirect URIs | Strict: `https://us-west.infinatio.us/oidc/callback` (add `https://inf-93148.phxaz.infinatio.us:8443/oidc/callback` if you also use the direct address) |
| Signing key | Any RSA certificate, e.g. `authentik Self-signed Certificate` (required, so tokens are RS256-signed and verifiable via JWKS) |
| Scopes | `openid`, `email`, `offline_access`, and a **profile mapping without groups** (reuse `LXD OAuth Mapping: profile (no groups)`) - the default `profile` mapping includes every group and pushes the token cookies past 4 KB, the same failure LXD hit |
| Include claims in id_token | On |
| Subject mode | Based on the user's email (makes `sub` match the username Incus shows) |
| Access token validity | e.g. `minutes=10`; refresh token e.g. `days=30` |

Then:

- **Application > Policy / Group / User Bindings:** bind the admin group only, so nobody else can obtain a token.
- **Device code flow** (for the CLI): create a flow with designation *Stage Configuration* and authentication *Require authentication*, then select it under **System > Brands > (your brand) > Default code flow**. Authentik only offers the device flow on brands that have one configured, so without it `incus remote add --auth-type=oidc` fails.
- Copy the **Client ID**.

### Incus server settings

```bash
incus config set oidc.issuer="https://auth.infinatio.us/application/o/incus-us-west/"
incus config set oidc.client.id="<AUTHENTIK_CLIENT_ID>"
incus config set oidc.scopes="openid,offline_access,email,profile"
incus config set oidc.audience="<AUTHENTIK_CLIENT_ID>"   # optional: reject tokens minted for other apps
```

(Incus uses `oidc.*` keys; there are no `openid.*` keys.) `setup-incus-host.sh` runs these from the `OIDC_*` values in `.env`, after checking that the issuer's discovery document is reachable from the host - on VLAN 29 that needs the firewall rule to NPM.

### Logging in

- **Web UI:** `https://us-west.infinatio.us/ui/` > *Login with SSO*.
- **CLI:** `incus remote add us-west https://us-west.infinatio.us --auth-type=oidc`, then open the printed URL and confirm the device code.

---

## Web UI branding

The web UI is the `incus-ui-canonical` package: static files in **`/opt/incus/ui/`**, served by `incusd` because Zabbly's `incusd` wrapper exports `INCUS_UI=/opt/incus/ui/`. Nothing about its appearance is configurable, but the files are plain assets on disk, so `branding/apply-ui-branding.sh` edits them:

| Change | How |
|---|---|
| Font: Special Gothic | Copies `branding/assets/fonts/special-gothic.ttf` and `branding.css` into `/opt/incus/ui/assets/infnet/` and links the stylesheet from `index.html`. The stylesheet redefines the UI's `Ubuntu variable` font family to point at Special Gothic, so every text face changes without touching the hashed JS/CSS bundles. `Ubuntu Mono` is left alone for the terminal and code editors. |
| Logo | Replaces `/opt/incus/ui/assets/img/incus-logo.svg` (the path is hardcoded in the UI bundle) with `branding/assets/logo.svg`, the white "Infinatious Cloud" wordmark. The stylesheet hides the UI's own "Incus UI" label, inverts the wordmark to black on the light theme, and crops it to the square badge when the sidebar is collapsed. |
| Favicon | Replaces `/opt/incus/ui/assets/img/favicon-32x32.png` with `branding/assets/favicon-32x32.png`. |
| Page titles | `<title>` in `index.html`, and the `<page> \| Incus UI` tab-title literal in the main JS bundle, become `Infinatious Cloud`. If a future release changes that literal the script warns and leaves titles alone. |

### Applying it

```bash
sudo /opt/infnet-incus-scripts/branding/apply-ui-branding.sh --install-hook
```

Reload the UI with a hard refresh. `setup-incus-host.sh` already runs this.

**Asset URLs are versioned.** The stylesheet, logo and favicon are linked with `?v=<hash of the assets>`, so a CDN in front of the UI can't keep serving old branding: us-west sits behind Cloudflare, which kept the old logo well past its `max-age`. `index.html` isn't cached, so a change shows up on the next page load.

**Package upgrades restore the stock files.** `--install-hook` adds `/etc/apt/apt.conf.d/99-infnet-incus-ui-branding`, which re-runs the script after every `dpkg` run, so an `apt upgrade` is rebranded automatically. The script is idempotent.

### Changing the assets

Replace the files in `branding/assets/` and re-run the script:

- `logo.svg` - shown 30 px tall (max 184 px wide); keep a `viewBox` so it scales instead of cropping. White artwork is expected (it is inverted on the light theme), with a square badge at the left for the collapsed sidebar.
- `favicon-32x32.png` - optional; e.g. `magick -background none -density 72 logo.svg -resize 32x32 favicon-32x32.png`.
- `fonts/special-gothic.ttf` - Special Gothic variable font (weights 400-700, widths 75-125%).
- `branding.css` - logo sizing and theme handling.

To undo: `sudo rm /etc/apt/apt.conf.d/99-infnet-incus-ui-branding && sudo apt-get install --reinstall incus-ui-canonical`.

### UEFI boot logo

VMs show the Infinatious Cloud logo (`branding/assets/uefi-logo.bmp`, 576x192 24-bit BMP) while their firmware boots. The logo is compiled into the OVMF firmware, so `branding/uefi-logo.sh` rebuilds it:

```bash
./branding/uefi-logo.sh build         # ~5-10 min, in a throwaway container
sudo ./branding/uefi-logo.sh apply    # installs it; VMs use it from their next boot
./branding/uefi-logo.sh status
sudo ./branding/uefi-logo.sh revert   # back to the stock firmware
```

`build` compiles OVMF exactly as Zabbly does for the incus package (same edk2 tag, patches and build flags, read from their `daily` build workflow), with only `MdeModulePkg/Logo/Logo.bmp` swapped. Only `/opt/incus/share/qemu/OVMF_CODE.4MB.fd` is replaced; each VM's variable store (Secure Boot keys, boot entries) is untouched. The build output (`branding/assets/uefi/`) isn't committed.

`apply` saves the stock firmware under `/var/lib/infnet-uefi-logo/` and installs an APT hook (`/etc/apt/apt.conf.d/99-infnet-uefi-logo`). After an incus upgrade reinstalls the stock firmware, the hook puts the logo build back only if the package firmware is the same build that was branded; when incus ships **new** firmware it keeps it (stock logo) and warns to run `build` and `apply` again, so VMs never end up on older firmware.

---

## Scripts

`./start.sh` is a main menu for everything below, under an INFNET banner with the Incus version, cluster members and projects. Pick a numbered category, then a task; each task runs its script without arguments (so it prompts for what it needs) and returns to that category. `b)` goes back, `e)` exits, and `NO_COLOR=1` turns the colors off.

| Category | Tasks |
|---|---|
| 1) Project Manager | deploy a project; delete an empty project; delete a project with all its instances (`--delete-instances`); add missing profiles to one project or to all projects; update profile payloads in all projects |
| 2) Host Tasks | cluster health report; check for Incus upgrades; rolling upgrade of all members (see [Upgrading Incus](#upgrading-incus)); re-run host setup (`sudo`, never wipes the disk from the menu); re-apply web UI branding (`sudo`); UEFI boot logo status |
| 3) Instance Manager | create, resize, delete an instance; manage an instance's firewall (open/close ports) |
| 4) Backup Manager | back up now, dry run, restore an instance |
| 5) Misc | sync DNS records (and dry run), manage images and aliases |

`deploy-project.sh --all-projects --add-missing-profiles` (or `--update-payloads`) runs the profile action on every project these scripts manage, i.e. those described `Project ID: N`.

- `deploy-project.sh` creates a project, its OVN network, and Linux/Windows/Docker profiles.
- `create-instance.sh` creates an instance from the chosen profile and image, and maps a public IP to it with 1:1 NAT. `--empty` makes a stopped VM with no image (NIC, ACL, NAT and DNS all set) to receive an imported disk; `--target` picks the member.
- `resize-instance.sh` changes CPU, RAM and root disk size.
- `delete-instance.sh` deletes an instance and releases its public IP and DNS record.
- `delete-project.sh` deletes a project's profiles, network and the project itself (and optionally its instances).
- `manage-images.sh` lists the `default` project's images (the ones every project launches from), imports new ones from the `images:` server, adds/renames/removes aliases, and deletes images.
- `backup/backup-instances.sh` exports instances to NFS. Runs nightly from `infnet-incus-backup.timer`.
- `backup/restore-instance.sh` restores an instance, including its 1:1 NAT.
- `dns/sync-dns-records.sh` creates or corrects the Technitium records of every instance and project.
- `lib/public-ip.sh` and `dns/technitium-dns.sh` are shared helpers, sourced by the scripts above.
- `host/setup-incus-host.sh` builds the host ([Host setup](#host-setup)); `host/cluster-enable.sh` and `host/cluster-join.sh` grow it into a cluster ([Clustering](#clustering)); `host/common.sh` holds their shared steps; `branding/apply-ui-branding.sh` brands the UI.

`.env` stays at the repository root and is shared by every script. All scripts accept command-line arguments and fall back to interactive prompts for anything omitted.

#### `deploy-project.sh`

```bash
./deploy-project.sh --project-name demo --project-id 42
```

Creates the project (description `Project ID: 42`, which the other scripts use to find it), an OVN network `demo` on `<IPV4_SUBNET_PREFIX>.42.1/24` behind `UPLINK_NETWORK`, and the profiles `demo-linux` (1 CPU, 2 GiB, 20 GiB, cloud-init from `cloud-init-user-data.yaml`) `demo-win` (2 CPU, 4 GiB, 64 GiB, cloudbase-init from `cloudbase-init-user-data.yaml`) and `demo-linux-docker` (see [Docker profile](#docker-profile)). It warns if the uplink has no `ipv4.routes`, since instances in the project couldn't get public IPs.

New Linux instances take their timezone from the profile's cloud-init. Set `INSTANCE_TIMEZONE` in each site's `.env` (us-west `America/Phoenix`, us-east `America/Detroit`). Without it, the zone in `cloud-init-user-data.yaml` applies. After changing it, run `./deploy-project.sh --all-projects --update-payloads`; that only affects instances created afterwards.

Projects created before a profile was added (e.g. the Docker one) get it with:

```bash
./deploy-project.sh --project-name demo --add-missing-profiles
```

It creates whichever of the three standard profiles the project lacks and leaves the existing ones untouched.

Profiles keep a copy of the cloud-init payload from when they were created. After editing `cloud-init-user-data.yaml` or `cloudbase-init-user-data.yaml`, push the new payload into a project's existing profiles (instances created afterwards get it; CPU, memory and disk settings stay as they are):

```bash
./deploy-project.sh --project-name demo --update-payloads
```

##### Docker profile

`demo-linux-docker` is for running Docker inside a system container rather than a full VM: the same 1 CPU, 2 GiB, 20 GiB defaults as `demo-linux`, plus `security.nesting=true` (so dockerd can create its own namespaces, cgroups and overlay mounts while the container stays unprivileged), and the Linux cloud-init payload plus Docker Engine and the Compose plugin from Docker's own repos (`get.docker.com` on Debian/Ubuntu/Fedora, the RHEL repo on AlmaLinux/Rocky) with every user in the `docker` group. The payload is generated from `cloud-init-user-data.yaml` when the profile is created, so users and keys stay defined in one place; re-create the profile after editing that file. `create-instance.sh --profile-type docker` offers container images only and opens SSH like any Linux instance; published container ports still need an ingress rule on the instance's ACL (see [Firewall](#firewall)).

#### `create-instance.sh`

```bash
./create-instance.sh --project-id 42 --environment d --service-code tstng --profile-type linux --image-alias ubuntu2604 --cpu 1 --ram 2 --disk 20 --description-suffix 'site-a'
./create-instance.sh --project-id 42 --environment p --service-code dnsag --profile-type linux --image-alias ubuntu2604 --public-ip 172.31.232.140
```

- `--project-id` selects the target project by numeric project ID.
- `--environment` uses `p`, `t`, `q`, or `d` (Prod, Test, QA, Dev).
- `--service-code` must be exactly five alphanumeric characters.
- `--profile-type` is `linux`, `win` or `docker`.
- `--cpu`, `--ram`, and `--disk` override the profile defaults.
- `--image-index` selects the image from the numbered filtered list; `--image-alias` selects it by exact alias.
- `--public-ip IP` gives the instance that 1:1 NAT address, `--public-ip random` a random free one from the uplink's `ipv4.routes`, and `--no-public-ip` none at all (it then only reaches out through its project's shared NAT address, and gets no DNS record). With none of these the script asks whether to assign a public IP and which one (blank = random); when it isn't run from a terminal it picks a random one. The address is checked before the instance is created.
- `--description-suffix` appends text to the instance description. It is only prompted for when the script is run with no arguments at all.

The instance is named `<env prefix><project id>-<service code>-<ct|vs><nn>` (e.g. `pd20-dnsag-ct01`). Before the instance first starts, the script creates its [firewall ACL](#firewall) (ICMP plus SSH or RDP inbound only) and, with a public IP, pins the NIC to a free internal address and creates the [1:1 NAT](#11-nat) - all while it is stopped, because changing the NIC of a running VM re-plugs it and a booting guest (Windows especially) fails with `Duplicate device ID`. VM images marked `requirements.cdrom_agent` also get the `agent:config` disk they need. If the first start fails, the instance, forward and ACL are removed again. It then registers `<instance-name>.<zone>` in Technitium (if configured and it has a public IP) and sets the description to the public IP (empty if it has none), plus the optional suffix.

The internal address is read from the guest (needs the `incus-agent` in VMs) or, failing that, from the address OVN assigned to the NIC - so VMs without the agent, such as a fresh Windows install, still work.

- `--empty` creates a VM with no image and leaves it stopped, with the NIC, ACL, 1:1 NAT and DNS done as usual. It's the target for an imported disk (see [Importing a VM disk](#importing-a-vm-disk-eg-from-proxmox)).
- `--target <member>` puts the instance on that cluster member instead of letting Incus choose.

#### Importing a VM disk (e.g. from Proxmox)

Done for the RDS servers (inf-10029 → `pd24-rdsts-vs01`, 2026-10-01). The disk moves with ZFS, so only a final incremental sync happens during downtime.

1. **Target VM:** `./create-instance.sh --project-id <ID> --environment p --service-code <code> --profile-type win --cpu <n> --ram <GiB> --disk <same size as the source> --public-ip random --empty --target <member>`
2. **Disk bus:** a Windows guest whose disk was SATA/IDE in Proxmox may lack the VirtIO SCSI driver, so attach the disk as NVMe (Windows has the driver in-box): `incus config device set <vm> root io.bus=nvme --project <P>`. The NIC stays virtio-net; Proxmox VMs with a `virtio` NIC already have its driver.
3. **Stage while the source runs:** snapshot the source zvol and stream it into a holding dataset on the target member. The Proxmox host can't reach the members directly, so relay through the workstation:
   `ssh root@<pve> 'zfs snapshot zpool/vm-<id>-disk-0@incus1; zfs send -c zpool/vm-<id>-disk-0@incus1' | ssh <member> 'sudo zfs recv -u zpool/import/vm-<id>-disk-0'`
4. **Cutover:**
   - Shut the source down from inside Windows. It may ignore Proxmox's ACPI shutdown when users are signed in. Also run `qm set <id> --onboot 0`.
   - Run a second snapshot `@incus2` and `zfs send -i @incus1 …` the same way (seconds).
5. **Write the disk.** Incus keeps a stopped VM's zvol at `volmode=none` (no `/dev/zvol` node), so expose it for the copy only:
   ```bash
   v=zpool/virtual-machines/<project>_<vm>.block
   sudo zfs set volmode=dev $v && sudo udevadm settle
   sudo dd if=/dev/zvol/zpool/import/vm-<id>-disk-0 of=/dev/zvol/$v bs=4M conv=sparse,fsync
   sudo zfs set volmode=none $v
   ```
6. **Start:** `incus start <vm> --project <P>`.
   - UEFI Windows boots via its fallback `\EFI\Boot\bootx64.efi` with Incus' Secure Boot keys.
   - The new NIC is a new adapter on DHCP, which gets the pinned internal address. Any old static IP stays on the hidden old adapter.
7. **Rollback:** stop the Incus VM and `qm start <id>`. Remove the staging dataset and the `@incus*` snapshots only after the move is confirmed.

Domain-joined Windows keeps its machine account. It needs outbound access from its public IP to the DCs, and DNS that resolves the AD domain (here the uplink's Technitium servers forward the AD zone to the DCs). Windows registers its internal 10.x address in AD DNS, so turn off "Register this connection's addresses in DNS" on the NIC and point the users' name at the public IP.

#### `resize-instance.sh`

```bash
./resize-instance.sh --project-id 42 --instance-index 1 --cpu 4 --ram 8 --boot-disk 60 --yes
```

Growing the root disk of a running instance stops and restarts it (after confirmation). Shrinking is refused.

#### `delete-instance.sh`

```bash
./delete-instance.sh --project-id 42 --instance-name p42-tstng-ct01 --yes
```

`--instance-index` selects from the numbered list instead of `--instance-name`. The instance gets a minute to shut down cleanly before it is force-stopped (a Windows VM that is still booting ignores the shutdown request). After the instance is deleted, its network forward (the inbound half of the NAT), its firewall ACL and its DNS record are removed.

#### `delete-project.sh`

```bash
./delete-project.sh --project-id 42
./delete-project.sh --project-id 42 --delete-instances
```

Refuses to run while the project has instances unless `--delete-instances` is given, which deletes each one as `delete-instance.sh` does. `--yes` skips that confirmation.

#### DNS names

All records go into the one Technitium zone (`TECHNITIUM_ZONE`, default `infnet`), shared by both sites:

| Name | Points at | Written by |
|---|---|---|
| `<instance>.infnet` | the instance's public IP (only instances that have one) | `create-instance.sh` (removed by `delete-instance.sh` / `delete-project.sh`) |
| `<instance>.<project>.infnet` | the instance's **internal** address (`10.x.x.y`); every instance, public IP or not | `create-instance.sh` once the address is known (removed by the same delete scripts) |
| `<project>.infnet` | the project network's gateway, `<IPV4_SUBNET_PREFIX>.<id>.1` | `deploy-project.sh` (removed by `delete-project.sh`) |

Instance names are unique across sites. Project names aren't (both sites have `infra-dns` and `infra-edge`), so each site only adds or removes its own gateway address in `<project>.infnet`, which then lists both. `deploy-project.sh` also sets the OVN network's `dns.domain` to `<project>.infnet`, so new instances' OVN-internal names are `<instance>.<project>.infnet`. Existing instances keep their old internal name (`<instance>.incus`) until restarted.

Instances can only resolve these names if their DNS server knows the `infnet` zone: the uplink's `dns.nameservers` must point at a Technitium server that hosts it (or a secondary/forwarder of it).

#### `sync-dns-records.sh`

```bash
./dns/sync-dns-records.sh --dry-run
./dns/sync-dns-records.sh
```

Audits every instance in every project and creates or corrects its Technitium A record so it points at the instance's public IP. Instances without a public IP are skipped.

#### `backup-instances.sh`

```bash
./backup/backup-instances.sh
./backup/backup-instances.sh --dry-run
./backup/backup-instances.sh --project infra-dns --instance pd20-dnsag-ct01 --tag adhoc --description 'before upgrade' --no-prune
```

- `--retention-days`, `--weekly-weeks`, `--retention-months` override the [retention tiers](#backup-layout-and-retention) for this run.
- `--project` / `--instance` narrow the run; the run fails if the named instance isn't found.
- `--tag` appends a tag to the file name (`<instance>_<timestamp>_<tag>.tar.gz`).
- `--description` and `--requested-by` are recorded in the metadata sidecar and run record.
- `--no-prune` skips retention pruning; `--dry-run` only reports.
- On a **cluster**, only instances on the member the client talks to are backed up by default; `--all-members` covers every member and `--member NAME` one specific member. On a **standalone** server every instance is backed up and `--member` is rejected.

#### `restore-instance.sh`

```bash
./backup/restore-instance.sh --project-id 42 --instance-name p42-tstng-ct01
./backup/restore-instance.sh --project-id 42 --instance-name p42-tstng-ct01 --backup-index 1 --yes
```

- `--backup-index` picks from the numbered list (newest first); `--backup-file` restores an exact tarball.
- `--new-name` restores under a different name.

The restored instance is imported stopped. If the backup had a public IP, the network forward for it is recreated first (Incus won't import a NIC whose `ipv4.address.external` has no forward) and removed again if the import fails. Because the NAT identity travels with the instance, the restore is refused while another instance still owns that public IP: delete the original first, or restore the copy by hand and give it a new address with `incus config device set <copy> eth0 ipv4.address= ipv4.address.external=`.

---

## Zabbix monitoring

Zabbix monitors the **instances**, both containers and VMs (not the Incus hosts). Instances are registered automatically, the same way as DNS.

**Each site has its own Zabbix server**, so monitoring traffic stays inside the site and doesn't depend on the link between the sites:

| Site | Server | `.env` `ZABBIX_URL` |
|---|---|---|
| us-west | `pd25-zabbx-ct01` (infra-monitoring, ID 25) | `https://137.152.231.61` |
| us-east | `pd26-zabbx-ct01` (infra-monitoring, ID 26) | `https://137.152.235.56` |

Each site's `.env` holds its own server's `ZABBIX_*` values, written by `zabbix-configure.sh` on that site.

| When | What happens in Zabbix |
|---|---|
| `create-instance.sh` | Host `<instance>` in group `Incus/<project>`, tagged `site`, `project`, `env`, `type` and `managed-by: infnet-incus-scripts`.<br>**ICMP Ping**, plus a **TCP check per port** the instance's ACL opens to the Zabbix server (trigger after 3 failures).<br>Linux instances also get **Linux by Zabbix agent active**. Their profile's cloud-init installs `zabbix-agent2`. |
| `firewall-manager.sh` add/remove | The TCP checks follow the ACL |
| `delete-instance.sh`, `delete-project.sh --delete-instances` | Host removed |
| `monitoring/sync-zabbix-hosts.sh` (also `start.sh` → Misc) | Registers or updates every instance of this site, removes managed hosts whose instance is gone (`--no-prune` keeps them) |

- **Server-side checks** (ping, TCP) run from the Zabbix server against the instance's **public IP**. Other projects' internal addresses aren't reachable, so instances without a public IP only get their agent.
  - Instances in the server's own project (`ZABBIX_PROJECT`) are checked on their internal IP, because of hairpin NAT.
  - A port only counts if its ACL rule allows anywhere or a range containing `ZABBIX_SERVER_IP`. Single ports only, no ranges.
  - To monitor an INFNET-only port, also allow it from `ZABBIX_SERVER_IP/32`.
  - To leave an open port **unchecked**, set the host macro `{$INFNET.SKIP.PORTS}` (e.g. `443` or `443,8080`) on its Zabbix host. The next sync or firewall change removes the check and won't recreate it.
- **Agents run active-only.** `monitoring/zabbix-agent-install.sh` sets `Server=` (nothing listens) and `ServerActive=<public IP>;<internal IP>`. The agent tries the second address when the first fails, which happens inside the server's own project.
  - Instances need no inbound rule.
  - The Zabbix server's ACL allows tcp/10051 from INFNET and both sites' public ranges.
- **Windows:** imported or Windows VMs get ICMP and port checks only. Install the agent by hand and link a Windows template; the scripts never unlink templates.
- **Alerts (Discord): only actual issues.** They go through the built-in Discord media type on the `Admin` user and the default "Report problems to Zabbix administrators" action, configured by `zabbix-configure.sh`:
  - Only severity **Average and up**: host unreachable, agent gone, a TCP port down. Warning-level problems (latency, "host restarted", swap) stay in the web UI.
  - Only problems **still open after 5 minutes**.
  - Port checks depend on the host's "Unavailable by ICMP ping" trigger: a host that's down raises one alert, not one per port.
  - A recovery message only for problems that were announced.
  - Nothing during maintenance windows.
- **Containers** get the host macro `{$LOAD_AVG_PER_CPU.MAX.WARN}=1000`. They see the *host's* load average divided by their own CPU count, so the template's load trigger only produced false alarms. CPU utilisation is per-container and still alerts.

### Setting it up

```bash
# 1. Server: an Ubuntu 26.04 container in the monitoring project, then Zabbix 7.4 + PostgreSQL + nginx (own TLS, self-signed)
./create-instance.sh --project-id 25 --environment p --service-code zabbx --profile-type linux --image-alias ubuntu2604 --cpu 4 --ram 8 --disk 100 --public-ip random
./monitoring/install-zabbix-server.sh --project-id 25 --instance pd25-zabbx-ct01 [--title 'INFNET Zabbix (WLSOH)']
./firewall-manager.sh --project-id 25 --instance pd25-zabbx-ct01 --add tcp:443,80 --source infnet --description "Zabbix web (INFNET)"
./firewall-manager.sh --project-id 25 --instance pd25-zabbx-ct01 --add tcp:10051 --source 10.100.0.0/16,137.152.224.0/21,137.152.232.0/21 --description "Zabbix agents"
# 2. Discord, API user/token, frontend URL; writes ZABBIX_* into this host's .env (copy them to the other members)
DISCORD_WEBHOOK='https://discord.com/api/webhooks/…' ./monitoring/zabbix-configure.sh --project-id 25 --instance pd25-zabbx-ct01 --site us-west
# 3. Agent in new Linux instances, existing instances, Zabbix hosts
./deploy-project.sh --all-projects --update-payloads
./monitoring/install-zabbix-agent.sh --project-id 20 --instance pd20-dnsag-ct01   # per existing Linux instance
./monitoring/sync-zabbix-hosts.sh
```

| `.env` | Meaning |
|---|---|
| `ZABBIX_URL` | `https://<server public IP>` (API; self-signed certificate unless `ZABBIX_CA_FILE` is set) |
| `ZABBIX_API_TOKEN` | Token of the `svc-infnet-incus` API user |
| `ZABBIX_SITE` | `us-west` / `us-east`: tags hosts, and sync only ever touches this site's hosts |
| `ZABBIX_SERVER_IP` | Server public IP, used to decide which ACL ports it can reach |
| `ZABBIX_SERVER_ACTIVE` | Agents' `ServerActive` (public;internal) |
| `ZABBIX_PROJECT` | Project the server lives in |

Without `ZABBIX_*` in `.env` everything Zabbix-related is skipped with a warning.

- **Secrets** stay root-only in the server container under `/root/zabbix/`: `admin-password` (web user `Admin`), `db-password`, `api-token`.
- **Discord gotcha:** Zabbix's Discord script calls `/api/v10/…`, which the legacy `discordapp.com` host rejects ("Invalid API version"). `zabbix-configure.sh` rewrites the webhook to `discord.com`.
- **Frontend URL gotcha:** webhook media types also need the global macro `{$ZABBIX.URL}` set to the frontend URL. `zabbix-configure.sh` sets it.

## Reverse proxy (NPM)

`proxy/npm-proxy-host.sh` (also `start.sh` → Misc) manages proxy hosts on Nginx Proxy Manager (`pd19-ngxpm-ct01` in `infra-edge`), along with their internal DNS:

```bash
./proxy/npm-proxy-host.sh --list
./proxy/npm-proxy-host.sh --add --domain app.infinatio.us --forward http://inf-10020.phxaz.infinatio.us:3000 [--websockets] [--max-body 10G]
./proxy/npm-proxy-host.sh --remove --domain app.infinatio.us
```

- **`--add`:**
  - **Certificate:** reuses an existing one for the name, or requests one from Let's Encrypt through the **Cloudflare DNS challenge** (about a minute). It uses the same Cloudflare token as the existing certificates, read from NPM, so there's no second copy in `.env`.
  - **Proxy host:** SSL forced and HTTP/2, like the existing hosts. `--websockets` and `--max-body` (as `client_max_body_size`) are optional.
  - **DNS:** the name gets an A record → `NPM_DNS_TARGET` in the Technitium zone that contains it. For `infinatio.us` that's a **forwarder zone** (forwarder `this-server`, in the cluster catalog): only the names added there answer internally, and every other name resolves exactly as it does publicly from Cloudflare. `--create-zone` makes such a zone for a new domain.
  - Edits always go to the zone's primary node; a secondary copy relays them.
  - It also adds a local **HTTPS (SVCB) record** without ECH. Otherwise the zone forwards Cloudflare's public one, whose ECH key makes browsers connect to NPM with the cover name `cloudflare-ech.com`, and NPM rejects that (`SSL_ERROR_UNRECOGNIZED_NAME_ALERT`). Any name overridden by hand in a forwarder zone needs the same record.
  - At the end it requests the site through NPM. A 502/504 usually means the backend firewall doesn't allow NPM's address (`137.152.231.105`) yet.
- **`--remove`** deletes the proxy host, its certificate (unless another host uses it, or `--keep-cert`) and the DNS record.
- **`--no-dns`** skips Technitium.
- **Public DNS (Cloudflare) is never changed.**

| `.env` | Meaning |
|---|---|
| `NPM_URL` | NPM admin API, e.g. `http://137.152.231.105:81` |
| `NPM_EMAIL`, `NPM_PASSWORD` | An NPM user for the scripts (NPM → Users, role Administrator) |
| `NPM_DNS_TARGET` | Address the proxy hosts get in internal DNS (NPM's public IP) |
| `NPM_INSTANCE`, `NPM_PROJECT` | Incus instance running NPM, to read its Cloudflare credentials file if the API doesn't return them |

## DNS registration

`create-instance.sh`, `delete-instance.sh` and `delete-project.sh` register and remove an A record in [Technitium DNS](https://technitium.com/dns/) for each instance, pointing `<instance-name>.<zone>` (e.g. `p42-tstng-ct01.infnet`) at the instance's public 1:1 NAT address, not its internal OVN address. This is driven by `dns/technitium-dns.sh`, a small shared helper.

DNS registration is best-effort and non-blocking: if Technitium is unreachable or misconfigured, the script prints a warning and continues.

### 1. Create an API token in Technitium

In the Technitium web console, go to Administration > Sessions > Create Token, and create a token for a user with permission to manage the zone in question. Unlike a login session, a token doesn't expire.

### 2. Configure `.env`

```
TECHNITIUM_URL='http://dns.example.infnet:5380'
TECHNITIUM_API_TOKEN='...'
TECHNITIUM_ZONE='infnet'
TECHNITIUM_DNS_TTL='3600'
```

The zone must already exist in Technitium. If `TECHNITIUM_URL`, `TECHNITIUM_API_TOKEN`, or `TECHNITIUM_ZONE` is blank, DNS registration is skipped with a warning.

### Behavior

- Records use the instance name as the hostname; renaming an instance does not update DNS.
- `sync-dns-records.sh` backfills or corrects records, e.g. after a Technitium outage made a registration fail.

---

## Backups

`backup-instances.sh` and `restore-instance.sh` back instances up to an NFS export and restore them from it.

### 1. Mount the NFS share

Set `NFS_BACKUP_SOURCE` and `NFS_BACKUP_DIR` in `.env` and `setup-incus-host.sh` adds the `/etc/fstab` entry and mounts it. By hand:

```
# /etc/fstab
nfs-server.example.com:/export/incus-backups  /mnt/incus-backups  nfs  defaults,_netdev  0  0
```

`backup-instances.sh` refuses to run if `NFS_BACKUP_DIR` isn't a mount point, so it won't silently fill the local root disk when the NFS mount is down.

### 2. Configure `.env`

```
NFS_BACKUP_DIR='/mnt/incus-backups'
BACKUP_RETENTION_DAYS='7'
BACKUP_WEEKLY_RETENTION_WEEKS='3'
BACKUP_RETENTION_MONTHS='6'
```

On a cluster these should match on every member.

### 3. Install the timer

`setup-incus-host.sh` does this when the repository lives at `/opt/infnet-incus-scripts`. By hand:

```bash
sudo cp backup/systemd/infnet-incus-backup.service backup/systemd/infnet-incus-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now infnet-incus-backup.timer
```

The units assume `/opt/infnet-incus-scripts` and `NFS_BACKUP_DIR=/mnt/incus-backups`; edit `ExecStart`, `WorkingDirectory` and `ConditionPathIsMountPoint` if yours differ. The timer runs nightly at 02:00 with up to 20 minutes of random delay. Check runs with:

```bash
systemctl status infnet-incus-backup.timer
journalctl -u infnet-incus-backup.service
```

### Backup layout and retention

Backups are written as:

```
${NFS_BACKUP_DIR}/<project>/<instance>/<instance>_<timestamp>[_<tag>].tar.gz
${NFS_BACKUP_DIR}/<project>/<instance>/<instance>_<timestamp>[_<tag>].tar.gz.json
```

Exports are written as `<file>.tar.gz.partial` and renamed only once `incus export` succeeds, so an interrupted export never looks like a restorable backup. A failed export is logged and the run moves on to the next instance. The script then exits non-zero and lists the failures in its run record.

The `.json` sidecar records:

```jsonc
{
  "project": "infra-dns", "instance": "pd20-dnsag-ct01",
  "member": "inf-93148",         // where the instance was located
  "runner": "inf-93148",         // host that ran the backup (BACKUP_RUNNER_NAME or hostname)
  "run_id": "20260926-174851_inf-93148_5144",
  "tag": "adhoc", "description": "before upgrade", "requested_by": "admin",
  "created_at": "2026-09-26T17:48:55Z", "size_bytes": 1652555776
}
```

Every run that isn't a dry run also writes a run record to `${NFS_BACKUP_DIR}/.runs/<UTC timestamp>_<runner>_<pid>.json`, whether it succeeds or fails. The record holds the scope, the result, the files written, any per-instance failures, and what was pruned. Run records older than `BACKUP_RUN_HISTORY_DAYS` (default `90`) are pruned along with backups.

Tagged (e.g. ad-hoc) backups follow the same retention as scheduled ones. Each run prunes that instance's directory on a tiered (grandfather-father-son) schedule:

| Tier | Setting (default) | Behavior |
|---|---|---|
| Daily | `BACKUP_RETENTION_DAYS` (`7`) | Every backup younger than this many days is kept. |
| Weekly | `BACKUP_WEEKLY_RETENTION_WEEKS` (`3`) | For this many weeks after the daily tier, only the newest backup in each 7-day bucket survives. |
| Monthly | `BACKUP_RETENTION_MONTHS` (`6`) | Beyond the daily+weekly window, only the newest backup in each ~30-day bucket survives, up to this many months of *total* age from today. Anything older is deleted outright. |

With the defaults, a backup's total lifespan looks like:

```
0-7d    every backup kept               (daily)
8-28d   newest per 7-day bucket kept    (weekly, 3 buckets)
29-180d newest per ~30-day bucket kept  (monthly, ~5 buckets)
>180d   deleted
```

Bucket boundaries are rolling day-counts from the moment each run starts, not calendar weeks/months, and are computed per instance.

Containers are exported with `--optimized-storage` (a ZFS stream); VMs use a plain export, because LXD's optimized export miscounted VM snapshots and Incus shares that storage code. Backups are taken without stopping the instance - treat them as crash-consistent, not necessarily transaction-consistent for databases.

### Optional `.env` settings

| Variable | Default | Purpose |
|----------|---------|---------|
| `BACKUP_RUN_HISTORY_DAYS` | `90` | How long run records in `.runs/` are kept |
| `BACKUP_RUNNER_NAME` | short hostname | Name recorded as `runner` in sidecars and run records |
| `INCUS_CONF` (exported) | incus default | Client config directory, e.g. for a remote backup runner |

The [MicroCloud Vault](https://github.com/infinatious/microcloud-backup-manager) VM drove these scripts through the LXD API with `lxc`; it needs the same conversion before it can run them against Incus.

---

## Notes

- Images and aliases: `./manage-images.sh` (or `incus image alias create NAME FINGERPRINT --project default`).
- The Windows Server 2025 image (`win2025`) was built with [antifob/incus-windows](https://github.com/antifob/incus-windows). Like other images that can't load the incus-agent over a shared filesystem, it's marked `requirements.cdrom_agent`, so `create-instance.sh` adds the `agent:config` disk device those VMs need before starting them.
- The image picker filters by profile family: Linux lists images whose aliases don't contain `win`, Windows lists only those that do, and Docker lists the Linux container images.
