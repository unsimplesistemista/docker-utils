#/bin/bash

set -e 

DRY_RUN=${DRY_RUN:-false}

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
SSH_HOST_SOURCE=${SSH_HOST_SOURCE}
SSH_USER_SOURCE=${SSH_USER_SOURCE:-root}
SSH_PORT_SOURCE=${SSH_PORT_SOURCE:-22}
export DOCKER_HOST_SOURCE=${DOCKER_HOST_SOURCE:-tcp://${SSH_HOST_SOURCE}:2375}

SSH_HOST_DEST=${SSH_HOST_DEST}
SSH_USER_DEST=${SSH_USER_DEST:-root}
SSH_PORT_DEST=${SSH_PORT_DEST:-22}

BACKUP_ID=${BACKUP_ID:-lvm-sync}
LVM_VG=${LVM_VG}
LVM_LV=${LVM_LV}
LVM_SNAPSHOT_SIZE=${LVM_SNAPSHOT_SIZE:-"-L50G"}

TODAY=$(date +%Y%m%d-%H%M%S)

LVM_DEVICE=/dev/${LVM_VG}/${LVM_LV}
SNAP_LVM_DEVICE=/dev/${LVM_VG}/${LVM_LV}-${BACKUP_ID}-snap
SNAP_MOUNTPOINT=/mnt/${LVM_LV}-${BACKUP_ID}-snap
BACKUP_PATH_SOURCE=${SNAP_MOUNTPOINT}
BACKUP_PATH_DEST=${BACKUP_PATH_DEST:-/backup/${BACKUP_ID}/${SSH_HOST_SOURCE}/${LVM_VG}/${LVM_LV}}

if [ a"${DRY_RUN}" == a"true" ]; then
  RSYNC_EXTRA_FLAGS="${RSYNC_EXTRA_FLAGS}n"
fi

if [ "a${SSH_HOST_SOURCE}" == "a" ]; then
  echo "ERROR: Missing SSH_HOST_SOURCE variable, exiting ..."
  exit 1
fi

if [ "a${SSH_HOST_DEST}" == "a" ]; then
  echo "ERROR: Missing SSH_HOST_DEST variable, exiting ..."
  exit 1
fi

if [ "a${BACKUP_ID}" == "a" ]; then
  echo "ERROR: Missing BACKUP_ID variable, exiting ..."
  exit 1
fi

function cleanup_lvm {
  # Delete snapshot if exists
  ssh ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE} ${SSH_OPTS} -p ${SSH_PORT_SOURCE} "if mount | grep -q ${SNAP_MOUNTPOINT}; then echo "Unmounting previous snapshot ${SNAP_MOUNTPOINT} ..."; umount ${SNAP_LVM_DEVICE}; fi"
  ssh ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE} ${SSH_OPTS} -p ${SSH_PORT_SOURCE} "if [ -e ${SNAP_LVM_DEVICE} ]; then echo "Deleting previous snapshot ${SNAP_LVM_DEVICE} ..."; lvremove -f ${SNAP_LVM_DEVICE}; fi"
}

cleanup_lvm
# Ensure old snapshot does not exist already
if ssh ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE} ${SSH_OPTS} -p ${SSH_PORT_SOURCE} "if [ -e ${SNAP_LVM_DEVICE} ]; then exit 0; else exit 1; fi"; then
  echo "ERROR: snapshot ${SNAP_LVM_DEVICE} still exists and I could not delete it. Exiting ..."
  exit 1
fi

# Create snapshot
echo "Creating snapshot ${SNAP_LVM_DEVICE} ..."
ssh ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE} ${SSH_OPTS} -p ${SSH_PORT_SOURCE} "lvcreate ${LVM_SNAPSHOT_SIZE} -s -n ${LVM_LV}-${BACKUP_ID}-snap ${LVM_DEVICE}"
# Mount snapshot
echo "Mounting snapshot ${SNAP_LVM_DEVICE} on ${SNAP_MOUNTPOINT} ..."
ssh ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE} ${SSH_OPTS} -p ${SSH_PORT_SOURCE} "if [ ! -e ${SNAP_MOUNTPOINT} ]; then mkdir -p ${SNAP_MOUNTPOINT}; fi; mount -o ro ${SNAP_LVM_DEVICE} ${SNAP_MOUNTPOINT}"

# Rsync backup to destination server
ssh ${SSH_USER_DEST}@${SSH_HOST_DEST} ${SSH_OPTS} -p ${SSH_PORT_DEST} "if [ ! -e ${BACKUP_PATH_DEST} ]; then mkdir -p ${BACKUP_PATH_DEST}; fi"
ssh ${SSH_USER_DEST}@${SSH_HOST_DEST} ${SSH_OPTS} -p ${SSH_PORT_DEST} "rsync -${RSYNC_EXTRA_FLAGS}avz --delete-before -e "ssh ${SSH_OPTS} -p ${SSH_PORT_SOURCE}" ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE}:${BACKUP_PATH_SOURCE}/ ${BACKUP_PATH_DEST}/"

cleanup_lvm
