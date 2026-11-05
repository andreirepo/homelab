#!/usr/bin/env bash
set -u

DATA_ROOT=/mnt/backup/Pictures/immich-backup
REMOTE=b2:dev-server-immich-backup
LOG=/home/anmu/immich-check.log

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
# shellcheck source=/dev/null
source /home/anmu/telegram-notify.sh

CHECK_TIME=$(date '+%F %T')
CHECK_STATUS=""
ERROR_MSG=""

log "=== check start ==="

if pgrep -f 'rclone sync' >/dev/null; then
  log "rclone sync in progress, skipping"
  log "=== check end ==="
  notify warn "Immich integrity check" "Status=skipped" "Reason=rclone sync in progress"
  exit 0
fi

if rclone check "$DATA_ROOT" "$REMOTE" --fast-list --exclude "thumbs/**" --exclude "encoded-video/**" >>"$LOG" 2>&1; then
  CHECK_STATUS="OK"
  log "rclone check OK: source and destination identical"
else
  CHECK_STATUS="FAILED"
  ERROR_MSG=$(grep -E "ERROR|differ" "$LOG" | tail -1 || echo "See log for details")
  log "rclone check FAILED: differences found (see above)"
fi

log "=== check end ==="

# Send Telegram notification
if [ "$CHECK_STATUS" = "FAILED" ]; then
  notify fail "Immich integrity check" \
    "Status=$CHECK_STATUS" "Detail=$ERROR_MSG" "Log=$(basename "$LOG")" \
    "Duration=$(fmt_secs "$SECONDS")"
else
  notify ok "Immich integrity check" \
    "Status=$CHECK_STATUS" "Compared=source vs B2 (thumbs and encoded video excluded)" \
    "Duration=$(fmt_secs "$SECONDS")"
fi
