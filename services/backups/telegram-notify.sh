#!/usr/bin/env bash
# Shared Telegram notifier for every homelab job.
#
# One shape everywhere:
#
#   🖥️ homelab › media-server
#
#   ✅ Proxmox host config
#
#   Archive:   proxmox-host-config-20261105-0415.tgz
#   Size:      264 KB
#   Duration:  14s
#
#   05 Nov 2026 · 04:15
#
# Usage:
#   notify ok   "Proxmox host config" "Archive=$name" "Size=$size" "Duration=$(fmt_secs $SECONDS)"
#   notify fail "Proxmox host config" "Step=upload" "Exit code=$urc"
#
# States: ok (✅) · warn (⚠️) · fail (🚨) · info (ℹ️)
# Values may contain HTML (<code>, <pre>) and are passed verbatim.
set -uo pipefail

TELEGRAM_ENV=/home/anmu/.telegram-backup
HOMELAB_LABEL=${NOTIFY_HOMELAB:-homelab}
HOST_LABEL=${NOTIFY_HOST:-$(hostname -s)}

_state_emoji() {
  case "$1" in
    ok)   printf '✅' ;;
    warn) printf '⚠️' ;;
    fail) printf '🚨' ;;
    *)    printf 'ℹ️' ;;
  esac
}

_key_label() {
  local key=${1%%=*}
  key=${key//_/ }
  printf '%s%s' "$(printf '%s' "${key:0:1}" | tr '[:lower:]' '[:upper:]')" "${key:1}"
}

# 95 -> 1m 35s, 12 -> 12s
fmt_secs() {
  local s=${1:-0}
  if [ "$s" -lt 60 ]; then
    printf '%ds' "$s"
  else
    printf '%dm %02ds' $((s / 60)) $((s % 60))
  fi
}

notify() {
  local state=$1 title=$2
  shift 2 || true

  local text="🖥️ <b>${HOMELAB_LABEL}</b> › ${HOST_LABEL}"$'\n\n'
  text+="$(_state_emoji "$state") <b>${title}</b>"

  if [ "$#" -gt 0 ]; then
    text+=$'\n'
    for pair in "$@"; do
      case "$pair" in
        ?*=*) text+=$'\n'"<b>$(_key_label "$pair"):</b> ${pair#*=}" ;;
        *)    text+=$'\n'"${pair}" ;;
      esac
    done
  fi

  text+=$'\n\n'"<i>$(date '+%d %b %Y · %H:%M')</i>"

  # shellcheck source=/dev/null
  source "$TELEGRAM_ENV"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" \
    >/dev/null 2>&1
}
