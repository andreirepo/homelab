#!/usr/bin/env bash
# Nightly Proxmox host-config backup -> Backblaze B2.
# Runs on media-server, pulls config from the PVE host over SSH, uploads via rclone.
set -uo pipefail

PVE_HOST=192.168.18.121
PVE_USER=root
SSH_KEY=/home/anmu/.ssh/id_ed25519_pve
REMOTE=b2-proxmox:homelab-proxmox-host-backup
WORK=/home/anmu/proxmox-backup
LOG=/home/anmu/proxmox-backup.log
KEEP=30

log() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }
if [ -f /home/anmu/telegram-notify.sh ]; then
  source /home/anmu/telegram-notify.sh
else
  notify() { :; }
fi

mkdir -p "$WORK"
DATE=$(date +%Y%m%d-%H%M)
OUT="$WORK/proxmox-host-config-$DATE.tgz"

log "=== backup start ==="

ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "$PVE_USER@$PVE_HOST" 'bash -s' > "$OUT" <<'REMOTE'
set -e
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
M="$D/_manifest"; mkdir -p "$M"
pveversion -v                > "$M/pveversion.txt" 2>&1 || true
pvesm status                 > "$M/storage-status.txt" 2>&1 || true
qm list                      > "$M/qm-list.txt" 2>&1 || true
for id in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
  echo "### VM $id"; qm config "$id"; echo
done                         > "$M/qm-configs.txt" 2>&1 || true
pct list                     > "$M/pct-list.txt" 2>&1 || true
lsblk -f                     > "$M/lsblk.txt" 2>&1 || true
fdisk -l                     > "$M/fdisk.txt" 2>&1 || true
pvs                          > "$M/pvs.txt" 2>&1 || true
vgs                          > "$M/vgs.txt" 2>&1 || true
lvs -a                       > "$M/lvs.txt" 2>&1 || true
ip -4 addr                    > "$M/ip-addr.txt" 2>&1 || true
ip route                     > "$M/ip-route.txt" 2>&1 || true
blkid                        > "$M/blkid.txt" 2>&1 || true
dpkg --get-selections        > "$M/dpkg-selections.txt" 2>&1 || true
apt-mark showmanual          > "$M/apt-manual.txt" 2>&1 || true
proxmox-boot-tool status     > "$M/proxmox-boot-tool-status.txt" 2>&1 || true
efibootmgr -v                > "$M/efibootmgr.txt" 2>&1 || true
ceph status                  > "$M/ceph-status.txt" 2>&1 || true
{ echo "hostname: $(hostname)"; echo "date: $(date)"; echo "uptime: $(uptime)"; } > "$M/host-info.txt"

PATHS="etc/pve etc/network/interfaces etc/hosts etc/hostname etc/resolv.conf \
etc/fstab etc/apt etc/lvm etc/default/grub etc/kernel etc/ssh etc/ceph \
etc/cron.d etc/cron.daily etc/systemd/system root/.ssh var/spool/cron/crontabs"
EXIST=""
for p in $PATHS; do [ -e "/$p" ] && EXIST="$EXIST $p"; done
tar czf - -C "$D" _manifest -C / $EXIST
REMOTE
rc=$?

if [ "$rc" -ne 0 ] || [ ! -s "$OUT" ]; then
  log "archive build/transfer FAILED (rc=$rc)"
  notify fail "Proxmox host config" "Step=collect" "Exit code=$rc"
  exit 1
fi

sha=$(sha256sum "$OUT" | awk '{print $1}')
size=$(du -h "$OUT" | cut -f1)
echo "$sha  proxmox-host-config-$DATE.tgz" > "$OUT.sha256"
log "archive built: $size sha256=$sha"

rclone copyto "$OUT" "$REMOTE/config/proxmox-host-config-$DATE.tgz"      >/dev/null 2>>"$LOG"
rclone copyto "$OUT" "$REMOTE/config/proxmox-host-config-latest.tgz"     >/dev/null 2>>"$LOG"
rclone copyto "$OUT.sha256" "$REMOTE/config/proxmox-host-config-$DATE.tgz.sha256" >/dev/null 2>>"$LOG"
urc=$?

if [ "$urc" -ne 0 ]; then
  log "rclone upload FAILED (rc=$urc)"
  notify fail "Proxmox host config" "Step=upload" "Exit code=$urc"
  exit 1
fi
log "rclone upload OK"

# local rotation
ls -1t "$WORK"/proxmox-host-config-*.tgz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
# remote rotation (keep KEEP dated archives)
rclone lsf "$REMOTE/config/" --files-only 2>/dev/null \
  | grep -E '^proxmox-host-config-[0-9]{8}-[0-9]{4}\.tgz$' | sort \
  | head -n -"$KEEP" | while read -r f; do rclone deletefile "$REMOTE/config/$f" >/dev/null 2>&1; done

log "=== backup end ($size) ==="
notify ok "Proxmox host config" "Archive=$(basename "$OUT")" "Size=$size" \
  "Duration=$(fmt_secs $SECONDS)" "Destination=$(basename "${REMOTE%%/*}")"
