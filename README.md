# MicroCloud maintenance workflow

## Fresh MicroCloud install setup

Before using the scripts in this repository, set up a fresh MicroCloud host with a working LXD environment and a storage pool named `zpool`.

### 1. Install the base tooling

On the MicroCloud host, ensure the following are available:

- `lxc`
- `lxd`
- `bash`
- `jq`
- `python3`
- `curl`

The scripts in this repository assume that:

- the host has an available storage pool named `zpool` (can be changed in deploy-project.sh)
- an uplink physical network named `UPLINK-NAT` already exists (can be changed in deploy-project.sh)
- the `default` project is available for image discovery

### 2. Create the network uplink

Create a physical uplink network for the host that will act as the external-facing network for OVN traffic. The network should be configured as a physical network on the host NIC that will carry your traffic upstream.

In practice, that means:

- pick the host physical interface that should connect to the external network
- create a physical network object named `UPLINK-NAT`
- set the network to use that interface
- configure DNS servers for the uplink
- configure a gateway and the correct IPv4 routes for the upstream network
- reserve the OVN IPv4 address range that the project networks should use for NAT and routing

The important idea is that `UPLINK-NAT` should represent a real physical uplink path, not an isolated bridge or a private virtual network.

A typical configuration pattern looks like this conceptually, using an uplink network of 172.31.232.0/21:

```yaml
access_entitlements:
  - can_edit
  - can_delete
project: default
name: UPLINK-NAT
description: ''
type: physical
config:
  dns.nameservers: 1.1.1.1,9.9.9.9
  ipv4.gateway: 172.31.232.1/21
  ipv4.routes: 172.31.233.0/24,172.31.234.0/24,172.31.235.0/24,172.31.236.0/24, 172.31.237.0/24, 172.31.238.0/24, 172.31.239.0/24, 172.31.232.128/25
  ipv4.ovn.ranges: 172.31.232.2-172.31.232.127
```

Use values that match your site network planning. The exact address block should be chosen to fit the external network that the host is attached to.

### 3. Confirm the storage pool

Create or confirm the storage pool named `zpool` before running the deployment scripts.

This repository expects the root disk for profiles and instances to come from that storage pool.

### 4. Validate the environment

Once the host is ready, verify that:

- `lxc network show UPLINK-NAT` succeeds
- `lxc storage show zpool` succeeds
- `lxc image list --project default` returns images that can be used for instance creation

---

## Script overview

These scripts are intended for a project-based workflow on a MicroCloud host.

- `deploy-project.sh` creates a project, network, and Linux/Windows profiles.
- `create-instance.sh` creates instances inside the selected project using the chosen profile and image set.
- `resize-instance.sh` resizes an existing instance in the selected project.
- `delete-instance.sh` removes a single instance.
- `delete-project.sh` deletes all profiles in a project, removes the network, and destroys the project.
- `backup/backup-instances.sh` exports every instance running on the local cluster member to NFS storage. Intended to run from `microcloud-backup.timer` on every node.
- `backup/restore-instance.sh` restores an instance from a backup written by `backup-instances.sh`.
- `dns/technitium-dns.sh` is a shared helper, sourced (not run directly) by `create-instance.sh`, `delete-instance.sh`, `delete-project.sh`, and `sync-dns-records.sh` to manage DNS records in Technitium.
- `dns/sync-dns-records.sh` audits every instance across the whole cluster and creates or corrects any missing/stale Technitium DNS record.

`.env` stays at the repository root and is shared by every script, including those in `dns/` and `backup/`.

### Command-line usage

All of the scripts now accept command-line arguments and keep the original prompt-driven flow as an interactive fallback when you omit the matching arguments.

#### `deploy-project.sh`

Create a new project, OVN network, and both profiles.

Examples:

```bash
./deploy-project.sh --project-name demo --project-id 42
```

If you omit the options, the script will prompt for them in the original interactive way.

#### `create-instance.sh`

Create a new instance inside an existing project.

Examples:

```bash
./create-instance.sh --project-id 42 --environment d --service-code tstng --profile-type linux --image-alias ubuntu2604 --cpu 1 --ram 2 --disk 20 --description-suffix 'site-a'
```

Supported arguments:

- `--project-id` selects the target project by numeric project ID.
- `--environment` uses `p`, `t`, `q`, or `d`. (Prod, Test, QA, Dev)
- `--service-code` must be exactly five alphanumeric characters.
- `--profile-type` is `linux` or `win`.
- `--cpu`, `--ram`, and `--disk` override the profile defaults.
- `--image-index` selects the image from the numbered filtered list.
- `--image-alias` can be supplied instead of `--image-index` when you know the exact alias.
- `--description-suffix` appends an optional text suffix to the instance description.

If you omit any of these positional choices, the script will prompt for the missing values. The description suffix is the one exception: it's only prompted for when the script is run with *no* arguments at all. As soon as any argument is passed, an omitted `--description-suffix` is treated as empty rather than prompted for, since it's a genuinely optional field and a scripted invocation shouldn't block on stdin for it.

If Technitium is configured in `.env` (see [DNS registration](#dns-registration)), the script also registers `<instance-name>.<zone>` pointing at the instance's forward IP.

#### `resize-instance.sh`

Resize an existing instance in a project.

Examples:

```bash
./resize-instance.sh --project-id 42 --instance-index 1 --cpu 4 --ram 8 --boot-disk 60 --yes
```

Supported arguments:

- `--project-id` selects the project by numeric project ID.
- `--instance-index` selects the instance from the numbered list shown by the script.
- `--cpu`, `--ram`, and `--boot-disk` set the new values.
- `--yes` skips the final confirmation prompt.

If you omit the selection or resource values, the script will prompt for them interactively.

#### `delete-instance.sh`

Delete a single instance safely.

Examples:

```bash
./delete-instance.sh --project-id 42 --instance-name p42-tstng-ct01 --yes
```

Supported arguments:

- `--project-id` selects the source project by numeric project ID.
- `--instance-index` selects the instance from the numbered list.
- `--instance-name` deletes the instance directly by exact LXD instance name.
- `--yes` skips the final confirmation prompt.

If Technitium is configured in `.env`, the script also removes the instance's `<instance-name>.<zone>` record.

#### `delete-project.sh`

Delete all profiles, remove the OVN network, and remove an entire project.

Examples:

```bash
./delete-project.sh --project-id 42
./delete-project.sh --project-id 42 --delete-instances
```

Supported arguments:

- `--project-id` selects the project by numeric project ID.
- `--delete-instances` stops and deletes every instance in the project before the project itself is removed.
- `--yes` skips the confirmation prompt for the instance cleanup. Probably shouldn't use this.

When `--delete-instances` is used and Technitium is configured in `.env`, each deleted instance's DNS record is removed alongside its network forward.

A normal delete run will refuse to proceed if the project still contains instances unless you pass `--delete-instances`.

#### `sync-dns-records.sh`

Audit every instance in every project (across the whole cluster, not just the local node) and create or correct its Technitium A record.

Examples:

```bash
./dns/sync-dns-records.sh --dry-run
./dns/sync-dns-records.sh
```

Supported arguments:

- `--dry-run` reports what would be created or corrected without writing to Technitium.

Instances without a stored forward IP are skipped. Existing records that already match are left alone. Use this to backfill DNS for instances created before this feature existed, or to recover after a Technitium outage caused a `create-instance.sh` registration to fail.

#### `backup-instances.sh`

Export instances to the NFS backup directory, then prune backups older than the retention window. By default it covers the instances on the cluster member the `lxc` client talks to (the local node when run on a host). From outside the cluster, for example the MicroCloud Vault VM (the `microcloud-backup-ui` repository), it can back up every member through the LXD API.

Examples:

```bash
./backup/backup-instances.sh
./backup/backup-instances.sh --retention-days 14
./backup/backup-instances.sh --dry-run
./backup/backup-instances.sh --project p42-testing --instance p42-tstng-ct01 --tag adhoc --description 'before upgrade' --no-prune
./backup/backup-instances.sh --all-members                   # every instance in the cluster
./backup/backup-instances.sh --member mc-node2 --dry-run     # only instances on mc-node2
```

Supported arguments:

- `--retention-days` overrides `BACKUP_RETENTION_DAYS` from `.env` for this run.
- `--all-members` backs up instances on every cluster member, not just the one the client talks to.
- `--member` backs up only instances located on the named member (can't be combined with `--all-members`).
- `--project` limits the run to one project.
- `--instance` limits the run to one instance, which must be within the member scope above. The run fails if it isn't found.
- `--tag` appends a tag to the file name (`<instance>_<timestamp>_<tag>.tar.gz`), e.g. `adhoc` for manual backups.
- `--description` stores a free-text note in the backup's `.json` metadata sidecar.
- `--requested-by` records who asked for the run, in the sidecar and the run record.
- `--no-prune` skips retention pruning for this run (backups and run records).
- `--dry-run` prints what would be backed up and pruned without doing it.

This script takes no interactive input and is meant to run unattended from `microcloud-backup.timer`. See [Backups](#backups) below for setup.

#### `restore-instance.sh`

Restore an instance from a backup written by `backup-instances.sh`.

Examples:

```bash
./backup/restore-instance.sh --project-id 42 --instance-name p42-tstng-ct01
./backup/restore-instance.sh --project-id 42 --instance-name p42-tstng-ct01 --backup-index 1 --new-name p42-tstng-ct02 --yes
```

Supported arguments:

- `--project-id` selects the project the backup belongs to, by numeric project ID.
- `--instance-name` is the original instance name; used to locate its backups.
- `--backup-index` selects a backup from the numbered list (newest first).
- `--backup-file` restores an exact tarball path instead of browsing.
- `--new-name` restores under a different instance name (default: original name).
- `--yes` skips the confirmation prompt.

If you omit the project, instance, or backup selection, the script will prompt for them interactively. The script refuses to overwrite an existing instance with the same name - use `--new-name` or delete the existing instance first. The restored instance is imported stopped; start it manually once you've verified it. If the original instance had a network forward, recreate it with `lxc network forward create` after the restore.

### Deployment flow

1. Run `deploy-project.sh` with `--project-name` and `--project-id`, or let it prompt if you omit them.
2. The script creates:
   - the project
   - the OVN network for the project
   - the Linux profile
   - the Windows profile
3. The Linux profile uses the cloud-init payload from `cloud-init-user-data.yaml`.
4. The Windows profile is created without cloud-init and uses a larger boot disk size.

### Instance creation flow

1. Run `create-instance.sh` with the required argument set, or let it prompt for the missing values.
2. The script selects the project, environment, and service code.
3. It chooses either the Linux or Windows profile.
4. It applies the chosen CPU, RAM, and disk values.
5. It selects an image from the filtered list shown for the chosen profile family.
6. The script creates the instance, allocates a forward IP, and stores the created description text.

### Resize flow

1. Run `resize-instance.sh` and let it prompt interactively.
2. The existing description is preserved as-is.
3. If the new boot disk is larger while the instance is running, the script will stop and restart it automatically.

### Project deletion flow

1. Run `delete-project.sh` with `--project-id`, or let it prompt if you omit it.
2. The script removes every profile in the project first.
3. It then removes the project network.
4. Finally, it deletes the project itself.

---

## DNS registration

`create-instance.sh` and `delete-instance.sh`/`delete-project.sh` can register and remove an A record in [Technitium DNS](https://technitium.com/dns/) for each instance, pointing `<instance-name>.<zone>` (e.g. `p42-tstng-ct01.infnet`) at the instance's forward IP - its external, NAT'd address, not its internal OVN address. This is entirely driven by `technitium-dns.sh`, a small shared helper sourced by all three scripts.

### 1. Create an API token in Technitium

DNS registration is best-effort and non-blocking: if Technitium is unreachable or misconfigured, the affected script prints a warning to stderr and continues rather than failing the deployment or decom.

In the Technitium web console, go to Administration > Sessions > Create Token, and create a token for a user with permission to manage the zone in question. Unlike a login session, a token doesn't expire.

### 2. Configure `.env`

Set these values in `.env` on the host(s) that run `create-instance.sh`, `delete-instance.sh`, and `delete-project.sh`:

```
TECHNITIUM_URL='http://dns.example.infnet:5380'
TECHNITIUM_API_TOKEN='...'
TECHNITIUM_ZONE='infnet'
TECHNITIUM_DNS_TTL='3600'
```

The `infnet` zone must already exist in Technitium; the scripts only add and remove records within it, they don't create the zone itself.

If `TECHNITIUM_URL`, `TECHNITIUM_API_TOKEN`, or `TECHNITIUM_ZONE` is left blank, DNS registration is skipped entirely (with a warning) and the scripts behave exactly as they did before this feature existed.

### Behavior

- `create-instance.sh` registers `<instance-name>.<zone>` -> the instance's forward IP right after the network forward is created.
- `delete-instance.sh` and `delete-project.sh --delete-instances` remove that same record when they delete the instance's network forward.
- Record management uses the instance's LXD name as the DNS hostname; renaming an instance in LXD does not update DNS.
- `sync-dns-records.sh` backfills or corrects records for instances that predate this feature, or whose registration failed at creation time (e.g. Technitium was unreachable). See [`sync-dns-records.sh`](#sync-dns-recordssh) above.

---

## Backups

`backup-instances.sh` and `restore-instance.sh` back instances up to a shared NFS export and restore them from it. Every node in the cluster runs the same script on its own timer; each node only backs up the instances currently located on itself, so the full cluster's instances are covered without any single node having to reach across to the others.

### 1. Export and mount the NFS share

On the NFS server, export a directory that all cluster nodes can reach. On each MicroCloud node (`nfs-common`/`nfs-utils` is already installed by `post-install.sh`), mount that export at the same path used by `NFS_BACKUP_DIR` in `.env`, for example:

```
# /etc/fstab, on every node
nfs-server.example.com:/export/microcloud-backups  /mnt/microcloud-backups  nfs  defaults,_netdev  0  0
```

```bash
mkdir -p /mnt/microcloud-backups
mount /mnt/microcloud-backups
```

`backup-instances.sh` refuses to run if `NFS_BACKUP_DIR` isn't an actual mount point, so it won't silently fill up the local root disk if the NFS mount is down.

### 2. Configure `.env` on every node

Set (or confirm) these values in `.env` on each node - they should match on every node in the cluster:

```
NFS_BACKUP_DIR='/mnt/microcloud-backups'
BACKUP_RETENTION_DAYS='7'
```

### 3. Install the scripts and systemd timer on every node

Deploy this repository (including `.env`) to the same path on every node, e.g. `/opt/microcloud-maintenance`. Then install the timer unit:

```bash
cp backup/systemd/microcloud-backup.service backup/systemd/microcloud-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now microcloud-backup.timer
```

The shipped units assume the repository lives at `/opt/microcloud-maintenance` and that `NFS_BACKUP_DIR` is `/mnt/microcloud-backups`. If either differs on your site, update `ExecStart`/`WorkingDirectory` in `microcloud-backup.service` and `ConditionPathIsMountPoint` to match before copying them in.

By default the timer runs nightly at 02:00 with up to a 20 minute random delay (`RandomizedDelaySec`), so all cluster nodes don't hit the NFS server at the exact same moment. Check a node's recent runs with:

```bash
systemctl status microcloud-backup.timer
journalctl -u microcloud-backup.service
```

### Backup layout and retention

Backups are written as:

```
${NFS_BACKUP_DIR}/<project>/<instance>/<instance>_<timestamp>[_<tag>].tar.gz
${NFS_BACKUP_DIR}/<project>/<instance>/<instance>_<timestamp>[_<tag>].tar.gz.json
```

Exports are written as `<file>.tar.gz.partial` and renamed only once `lxc export` succeeds, so an interrupted export never looks like a restorable backup. A failed export is logged and the run moves on to the next instance. The script then exits non-zero and lists the failures in its run record.

The `.json` sidecar records:

```jsonc
{
  "project": "p42-testing", "instance": "p42-tstng-ct01",
  "member": "mc-node1",          // where the instance was located
  "runner": "microcloud-vault",  // host that ran the backup (BACKUP_RUNNER_NAME or hostname)
  "run_id": "20260926-174851_microcloud-vault_5144",
  "tag": "adhoc", "description": "before upgrade", "requested_by": "admin",
  "created_at": "2026-09-26T17:48:55Z", "size_bytes": 1652555776
}
```

Every run that isn't a dry run also writes a run record to `${NFS_BACKUP_DIR}/.runs/<UTC timestamp>_<runner>_<pid>.json`, whether it succeeds or fails. The record holds the scope, the result, the files written, any per-instance failures, and what was pruned. Because it lives on the shared NFS export, the history covers every node and the Vault VM, which journald can't do. Run records older than `BACKUP_RUN_HISTORY_DAYS` (default `90`) are pruned along with backups.

Tagged (e.g. ad-hoc) backups follow the same retention as scheduled ones.

Each run also deletes files in that instance's directory older than `BACKUP_RETENTION_DAYS` (default `7`). Backups are point-in-time exports of the instance's storage volume via `lxc export --optimized-storage`, taken without stopping the instance first - treat them as crash-consistent, not necessarily transaction-consistent for things like databases.

### Restoring

Run `backup/restore-instance.sh` on any node - it doesn't need to be the node the backup was taken on. See [`restore-instance.sh`](#restore-instancesh) above for usage.

### Optional `.env` settings

| Variable | Default | Purpose |
|----------|---------|---------|
| `BACKUP_RUN_HISTORY_DAYS` | `90` | How long run records in `.runs/` are kept |
| `BACKUP_RUNNER_NAME` | short hostname | Name recorded as `runner` in sidecars and run records |
| `LXD_CONF` (exported) | lxc default | Client config dir, e.g. for the Vault VM's dedicated cluster remote |

### Running backups from the MicroCloud Vault VM

`microcloud-backup-ui` deploys a small VM that holds a trusted `lxc` client certificate and mounts the same NFS export. It calls `backup-instances.sh --all-members` for ad-hoc backups and `restore-instance.sh` for restores. You can keep the per-node `microcloud-backup.timer` (the default), or let the VM run the nightly backup for the whole cluster instead. If you switch to the VM, disable the timer on every node.

---

## Notes

- The Linux profile is intended for cloud-init based image deployment.
- The Windows profile is intended for Windows-capable images and uses a `64GiB` root disk.
- The image picker filters the list based on the chosen profile family so that Linux selections exclude names containing `win`, and Windows selections only show images whose names include `win`.
- The following can be used to set image aliases:
```
lxc image list local: -c LFd
lxc image alias create NAME FINGERPRINT --project default
```
