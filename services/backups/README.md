# Backups

Three nightly jobs on `media-server`, all pushing to Backblaze B2 and all
reporting to Telegram. They cover the things that take days to rebuild, which
is configuration, not disk images.

| Script | Cron | What it takes | Destination | Retention |
|---|---|---|---|---|
| `immich-backup.sh` | 03:30 | Immich library (rclone sync) + nightly `pg_dump -Fc` | `b2:dev-server-immich-backup` | dumps 14 days, library mirrored |
| `proxmox-backup.sh` | 04:15 | Proxmox **host** config: `/etc/pve` (VM and CT definitions), network, LVM, boot, ssh, cron, dpkg selections, hardware manifest | `b2-proxmox:homelab-proxmox-host-backup/config` | 30 |
| `dev-server-config.sh` | 04:30 | dev VM **guest** config: compose files, `.env`, pihole/glance/speedtest/beszel config, cron, systemd units, Docker inventory, umami and todo-app dumps, Home Assistant snapshots | `b2-proxmox:homelab-proxmox-host-backup/dev-server-config` | 30 |

`telegram-notify.sh` is the shared notifier. It reads the bot token from
`/home/anmu/.telegram-backup`, which is **not** in this repository.

## What this deliberately does not back up

- **VM and CT disk images.** The Proxmox archive stores the definitions, so a
  host is rebuilt from config in minutes. Images would be 160 GB, most of it
  Immich photos that are already offsite.
- **Time-series data**: `pihole-FTL.db` (query log, 296 MB), speedtest history,
  beszel metrics. Nice to keep, not worth the bytes.
- **Derived files**: `node_modules`, `dist`, git clones, logs, Immich
  thumbnails and encoded video (regenerable from the originals).

## Encryption

`dev-server-config.sh` encrypts its archive with [age](https://age-encryption.org)
because it contains `.env` files with live secrets (JWT, Mongo, Telegram).

```
recipient (public key, in the script):  age1wq64xnfmuscjy943yqza4weq7gc7mp96nsum84xwh8hcysqh7pfslg37rj
identity (private key):                 ~/.config/age/keys.txt on the workstation, mode 600
```

`media-server` holds only the public key, so it can write backups but cannot
read them. Losing that private key loses the archives; keep a copy somewhere
safe outside this repository.

## Restore

Config archive, from the workstation:

```bash
ssh media-server 'rclone copyto \
  b2-proxmox:homelab-proxmox-host-backup/dev-server-config/dev-server-config-latest.tar.gz.age \
  /tmp/restore.tar.gz.age'

scp media-server:/tmp/restore.tar.gz.age .
age -d -i ~/.config/age/keys.txt -o restore.tar.gz restore.tar.gz.age
tar xzf restore.tar.gz
```

Inside:

```
_manifest/                 one line of truth per thing
  compose-<service>.yaml   `docker compose config` output: env resolved
  docker-ps.txt            what was running, which image, which tag
  docker-volumes.txt       volumes worth recreating
  crontab-anre.txt         the dev VM's cron
  dpkg-selections.txt      packages to reinstall
dumps/umami.sql            pg_dump, plain SQL
dumps/todo-app.gz          mongorestore --archive --gzip
home/anre/apps/<service>/  the original compose file and its .env
srv/ha-backups/            Home Assistant snapshots
```

A service comes back with `docker compose up -d` in its directory. The
normalised copy in `_manifest/` is there for the case where an `.env` is gone
and you need to see what the values actually were.

Proxmox host: extract `etc/pve` over a fresh install and `qm`/`pct` come back,
or copy the individual `qemu-server/*.conf`.

## Home Assistant

Native snapshots go to a Samba share on the dev VM, which the nightly job then
picks up:

```
share:    //192.168.18.242/ha-backups
user:     anre
password: Keychain, service homelab-smb-ha, account dev-server
```

In Home Assistant: **Settings → System → Storage → Add network storage** (SMB),
then **Settings → System → Backups → schedule a weekly snapshot** to it.

## Checking that it works

A backup nobody restores is a rumour. Once a month:

```bash
ssh media-server 'rclone lsf b2-proxmox:homelab-proxmox-host-backup/dev-server-config/ \
  | grep latest; rclone lsf b2-proxmox:homelab-proxmox-host-backup/config/ | tail -3'
```

then run the restore above and diff one compose file against the live one. The
three jobs also send a Telegram message on success and failure, so silence for
a day means the cron stopped.
