#!/usr/bin/env bash
set -u

CONF_DIR=/home/anmu/apps/immich
DATA_ROOT=/mnt/backup/Pictures/immich-backup
DB_DIR="$DATA_ROOT/db"
LOG=/home/anmu/immich-backup.log
REMOTE=b2:dev-server-immich-backup
KEEP_DAYS=14
SYNC_ATTEMPTS=3
SYNC_WAIT=120

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
# shellcheck source=/dev/null
source /home/anmu/telegram-notify.sh

START_TIME=$(date '+%F %T')
BACKUP_STATUS="✅"
DB_STATUS=""
DB_SIZE=""
SYNC_STATUS=""
ERROR_MSG=""

log "=== backup start ==="
mkdir -p "$DB_DIR"

set -a
# shellcheck source=/dev/null
source <(grep -vE '^(UID|GID)=' "$CONF_DIR/.env")
set +a

# 1. PostgreSQL dump (custom format, restorable with pg_restore)
DUMP="$DB_DIR/immich_$(date +%Y%m%d).dump"
if docker exec -e PGPASSWORD="$DB_PASSWORD" immich_postgres pg_dump -U "$DB_USERNAME" -Fc "$DB_DATABASE_NAME" > "$DUMP" 2>>"$LOG"; then
  DB_SIZE=$(du -h "$DUMP" 2>/dev/null | cut -f1)
  DB_STATUS="OK ($DB_SIZE)"
  log "pg_dump OK -> $DUMP ($DB_SIZE)"
else
  DB_STATUS="FAILED"
  BACKUP_STATUS="❌"
  log "pg_dump FAILED"
  rm -f "$DUMP"
fi

# 2. Prune dumps older than KEEP_DAYS
find "$DB_DIR" -name 'immich_*.dump' -mtime +"$KEEP_DAYS" -delete 2>/dev/null
log "pruned dumps older than $KEEP_DAYS days"

# 3. Sync data dir to Backblaze B2 (incremental)
#    Exclude thumbs/ and encoded-video/ (regenerable cache)
sync_rc=1
for attempt in $(seq 1 "$SYNC_ATTEMPTS"); do
  rclone sync "$DATA_ROOT" "$REMOTE" --fast-list --transfers 4 --stats 5m --log-file "$LOG" --log-level INFO --exclude "thumbs/**" --exclude "encoded-video/**"
  sync_rc=$?
  if [ "$sync_rc" -eq 0 ]; then
    break
  fi
  log "rclone sync attempt $attempt/$SYNC_ATTEMPTS failed (rc=$sync_rc)"
  if [ "$attempt" -lt "$SYNC_ATTEMPTS" ]; then
    sleep "$SYNC_WAIT"
  fi
done

if [ "$sync_rc" -eq 0 ]; then
  SYNC_STATUS="OK"
  log "rclone sync OK"
else
  SYNC_STATUS="FAILED"
  BACKUP_STATUS="❌"
  ERROR_MSG=$(grep -E "ERROR|FATAL" "$LOG" | tail -1 || echo "Unknown error")
  log "rclone sync FAILED (rc=$sync_rc)"
fi

# Get B2 totals
B2_INFO=$(rclone size "$REMOTE" --fast-list 2>/dev/null | grep "Total" | head -1 | sed 's/Total //')
B2_OBJECTS=$(echo "$B2_INFO" | grep -oP '\d[\d.]*k?' | head -1)
B2_SIZE=$(echo "$B2_INFO" | grep -oP '[\d.]+\s*[KMGT]?iB' | head -1)

log "=== backup end ==="

# Send Telegram notification
MSG="${BACKUP_STATUS} *Immich Backup — ${START_TIME}*

*DB dump:* ${DB_STATUS}
*Sync:* ${SYNC_STATUS}
*B2 total:* ${B2_OBJECTS} files (${B2_SIZE})"

if [ -n "$ERROR_MSG" ]; then
  MSG="${MSG}

*Error:* ${ERROR_MSG}"
fi

notify "$MSG"
