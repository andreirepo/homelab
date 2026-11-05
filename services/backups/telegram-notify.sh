#!/usr/bin/env bash
# Shared Telegram notification helper for Immich backup scripts.
# Usage: source /home/anmu/telegram-notify.sh
#        notify "message text"

_telegram_send() {
  local text="$1"
  local token chat_id
  # shellcheck source=/dev/null
  source /home/anmu/.telegram-backup
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    -d text="${text}" \
    -d parse_mode=Markdown \
    >/dev/null 2>&1
}

notify() {
  _telegram_send "$1"
}
