#!/usr/bin/env bash
# Weekly backup of the homeserver to an external HDD.
#
# Uses rsync snapshots with hardlinks: every snapshot looks like a full copy,
# but unchanged files are stored only once. When there are more than KEEP
# snapshots, the oldest ones are deleted.
#
# Run as root, e.g. every Sunday at 03:00 (sudo crontab -e):
#   0 3 * * 0 /path/to/self-hosted-server/backup.sh >> /var/log/homeserver-backup.log 2>&1
#
# Restore: snapshots are plain directories, copy files back with
#   rsync -aHAX /mnt/backup/snapshots/<date>/<source>/ /original/path/

set -euo pipefail

# =============================== CONFIG ======================================

# Backup disk
BACKUP_UUID="CHANGE_ME"              # UUID of the backup HDD, see: lsblk -f
MOUNT_POINT="/mnt/backup"            # where the HDD gets mounted
UNMOUNT_AFTER=true                   # unmount after the backup (protects it from accidents)

# What to back up
REPO_DIR="CHANGE_ME"                 # this repo on the server, e.g. /home/user/self-hosted-server
NEXTCLOUD_DATA="/mnt/nextcloud-data" # Nextcloud data directory
SOURCES=(                            # all directories to back up
  "$REPO_DIR"                        #   compose files + all service data/config
  "$NEXTCLOUD_DATA"
)

# Rotation
KEEP=4                               # number of snapshots to keep

# Consistency
STOP_CONTAINERS=true                 # stop the stack during backup so databases are consistent

# =============================================================================

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERROR: $*"; exit 1; }

# ---- Sanity checks ----------------------------------------------------------
[[ $EUID -eq 0 ]] || die "must run as root"
[[ "$BACKUP_UUID" != "CHANGE_ME" && "$REPO_DIR" != "CHANGE_ME" ]] \
  || die "fill in the placeholders in the CONFIG section"
for src in "${SOURCES[@]}"; do
  [[ -d "$src" ]] || die "source $src does not exist"
done
[[ "$KEEP" -ge 1 ]] || die "KEEP must be at least 1"

# Only one backup at a time
exec 9>/run/homeserver-backup.lock
flock -n 9 || die "another backup is already running"

# ---- Mount ------------------------------------------------------------------
MOUNTED_BY_US=false
if ! mountpoint -q "$MOUNT_POINT"; then
  mkdir -p "$MOUNT_POINT"
  mount "UUID=$BACKUP_UUID" "$MOUNT_POINT" || die "could not mount backup disk"
  MOUNTED_BY_US=true
fi
SNAP_DIR="$MOUNT_POINT/snapshots"
mkdir -p "$SNAP_DIR"

# ---- Always restart containers and unmount, even on failure -----------------
STOPPED=false
cleanup() {
  if $STOPPED; then
    log "Starting containers."
    docker compose --project-directory "$REPO_DIR" start \
      || log "WARNING: failed to start containers!"
  fi
  if $MOUNTED_BY_US && $UNMOUNT_AFTER; then
    sync
    umount "$MOUNT_POINT" || log "WARNING: failed to unmount $MOUNT_POINT"
  fi
}
trap cleanup EXIT

if $STOP_CONTAINERS; then
  log "Stopping containers."
  STOPPED=true
  docker compose --project-directory "$REPO_DIR" stop
fi

# ---- Snapshot ---------------------------------------------------------------
NAME="$(date +%Y-%m-%d_%H%M)"
PARTIAL="$SNAP_DIR/.partial"
rm -rf "$PARTIAL"   # leftover from an aborted run
mkdir -p "$PARTIAL"

for src in "${SOURCES[@]}"; do
  sub="$(basename "$src")"
  link=()
  [[ -d "$SNAP_DIR/latest/$sub" ]] && link=(--link-dest="$SNAP_DIR/latest/$sub")
  log "Backing up $src"
  rsync -aHAX --numeric-ids --delete "${link[@]}" "$src/" "$PARTIAL/$sub/"
done

# Only a complete snapshot gets a real name
mv "$PARTIAL" "$SNAP_DIR/$NAME"
ln -sfn "$NAME" "$SNAP_DIR/latest"
log "Snapshot $NAME complete."

# ---- Rotation (delete oldest first) -----------------------------------------
mapfile -t snaps < <(find "$SNAP_DIR" -mindepth 1 -maxdepth 1 -type d \
  -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9]' | sort)
while (( ${#snaps[@]} > KEEP )); do
  log "Deleting old snapshot $(basename "${snaps[0]}")"
  rm -rf "${snaps[0]}"
  snaps=("${snaps[@]:1}")
done

log "Disk usage: $(df -h --output=used,avail "$MOUNT_POINT" | tail -1)"
log "Backup finished."
