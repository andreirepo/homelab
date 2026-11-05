#!/usr/bin/env bash
# Nightly dev-server config backup -> Backblaze B2, encrypted with age.
#
# Runs on media-server: pulls the configuration over SSH, encrypts it locally,
# uploads it. The age private key lives on the workstation, never here, so this
# host can write backups but cannot read them.
#
# What it takes: compose files, .env files, service configs, cron, systemd
# units, Docker inventory and two small databases. What it leaves out: photos,
# node_modules, build output, git clones, logs and time-series tables.
#
# Restore: see docs/restore.md in andreirepo/homelab.
set -uo pipefail

HOST=192.168.18.242
SSH_USER=anre
SSH_KEY=/home/anmu/.ssh/id_ed25519_devserver
REMOTE=b2-proxmox:homelab-proxmox-host-backup/dev-server-config
WORK=/home/anmu/dev-server-backup
LOG=/home/anmu/dev-server-backup.log
KEEP=30
AGE_RECIPIENT=age1wq64xnfmuscjy943yqza4weq7gc7mp96nsum84xwh8hcysqh7pfslg37rj

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
if [ -f /home/anmu/telegram-notify.sh ]; then
  source /home/anmu/telegram-notify.sh
else
  notify() { :; }
fi

mkdir -p "$WORK"
DATE=$(date +%Y%m%d-%H%M)
RAW="$WORK/dev-server-config-$DATE.tar.gz"
OUT="$RAW.age"

log "=== backup start ==="

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$SSH_USER@$HOST" 'bash -s' > "$RAW" <<'REMOTE'
set -e
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
M="$D/_manifest"; mkdir -p "$M" "$D/dumps"

{ echo "hostname: $(hostname)"; echo "date: $(date)"; uname -a; } > "$M/host-info.txt"
docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.Status}}'   > "$M/docker-ps.txt" 2>&1 || true
docker volume ls --format '{{.Name}}'                        > "$M/docker-volumes.txt" 2>&1 || true
docker network ls --format '{{.Name}}'                       > "$M/docker-networks.txt" 2>&1 || true
dpkg --get-selections                                        > "$M/dpkg-selections.txt" 2>&1 || true
crontab -l                                                   > "$M/crontab-anre.txt" 2>&1 || true
ip -4 addr                                                   > "$M/ip-addr.txt" 2>&1 || true

# Normalised compose files: env vars resolved, so a restore does not depend on
# remembering which .env supplied which value.
for project in /home/anre/apps/*/ /home/anre/docker-telegram-monitor/; do
  name=$(basename "$project")
  ( cd "$project" && docker compose config 2>/dev/null ) > "$M/compose-$name.yaml" || true
done

# Small databases worth their bytes. Time-series tables are left out on purpose.
docker exec umami-db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  > "$D/dumps/umami.sql" 2> "$M/umami-dump.err" || rm -f "$D/dumps/umami.sql"
docker exec todo-db sh -c 'mongodump -u "$MONGO_INITDB_ROOT_USERNAME" \
  -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin \
  --archive --gzip --db todos' \
  > "$D/dumps/todo-app.gz" 2> "$M/todo-dump.err" || rm -f "$D/dumps/todo-app.gz"

tar czf - -C "$D" _manifest dumps -C / \
  --exclude='*/node_modules' \
  --exclude='*/dist' \
  --exclude='*/.git' \
  --exclude='*.log' \
  --exclude='*/log/*' \
  --exclude='home/anre/apps/pihole/etc-pihole/pihole-FTL.db*' \
  --exclude='home/anre/apps/pihole/etc-pihole/gravity_old.db' \
  --exclude='home/anre/apps/speedtest-tracker/config/database.sqlite' \
  --exclude='home/anre/apps/beszel/beszel_data*' \
  --exclude='home/anre/apps/github' \
  --exclude='home/anre/apps/umami/umami-data' \
  --exclude='home/anre/apps/beszel/beszel_socket' \
  home/anre/apps \
  home/anre/docker-telegram-monitor \
  srv/ha-backups \
  etc/cron.d etc/cron.daily etc/systemd/system etc/hosts etc/hostname \
REMOTE
rc=$?

if [ "$rc" -ne 0 ] || [ ! -s "$RAW" ]; then
  log "collection FAILED (rc=$rc)"
  notify fail "dev-server config" "Step=collect" "Exit code=$rc"
  exit 1
fi
size=$(du -h "$RAW" | cut -f1)
files=$(tar tzf "$RAW" 2>/dev/null | wc -l)

age -r "$AGE_RECIPIENT" -o "$OUT" "$RAW" 2>>"$LOG"
enc_rc=$?
if [ "$enc_rc" -ne 0 ]; then
  log "encryption FAILED (rc=$enc_rc)"
  notify fail "dev-server config" "Step=encrypt" "Exit code=$enc_rc"
  exit 1
fi
rm -f "$RAW"

sha=$(sha256sum "$OUT" | awk '{print $1}')
echo "$sha  $(basename "$OUT")" > "$OUT.sha256"
log "archive built: $size sha256=$sha"

rclone copyto "$OUT"          "$REMOTE/$(basename "$OUT")"        >/dev/null 2>>"$LOG"
rclone copyto "$OUT"          "$REMOTE/dev-server-config-latest.tar.gz.age" >/dev/null 2>>"$LOG"
rclone copyto "$OUT.sha256"   "$REMOTE/$(basename "$OUT").sha256" >/dev/null 2>>"$LOG"
urc=$?
if [ "$urc" -ne 0 ]; then
  log "rclone upload FAILED (rc=$urc)"
  notify fail "dev-server config" "Step=upload" "Exit code=$urc"
  exit 1
fi
log "rclone upload OK"

# local rotation
ls -1t "$WORK"/dev-server-config-*.tar.gz.age 2>/dev/null \
  | tail -n +$((KEEP + 1)) | xargs -r rm -f
# remote rotation: keep the KEEP most recent dated archives
rclone lsf "$REMOTE/" --files-only 2>/dev/null \
  | grep -E '^dev-server-config-[0-9]{8}-[0-9]{4}\.tar\.gz\.age$' | sort \
  | head -n -"$KEEP" \
  | while read -r f; do rclone deletefile "$REMOTE/$f" >/dev/null 2>&1; done

log "=== backup end ($size) ==="
notify ok "dev-server config" "Archive=$(basename "$OUT")" "Size=$size" \
  "Files=$files" "Duration=$(fmt_secs $SECONDS)" "Destination=$(basename "${REMOTE%%/*}")"
