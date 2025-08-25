#/bin/bash -e

SSH_HOST_SOURCE=${SSH_HOST_SOURCE}
SSH_USER_SOURCE=${SSH_USER_SOURCE:-root}
SSH_PORT_SOURCE=${SSH_PORT_SOURCE:-22}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
export DOCKER_HOST_SOURCE=${DOCKER_HOST_SOURCE:-tcp://${SSH_HOST_SOURCE}:2375}

SSH_HOST_DEST=${SSH_HOST_DEST}
SSH_USER_DEST=${SSH_USER_DEST:-root}
SSH_PORT_DEST=${SSH_PORT_DEST:-22}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
export DOCKER_HOST_DEST=${DOCKER_HOST_DEST:-tcp://${SSH_HOST_DEST}:2375}

DRY_RUN=${DRY_RUN:-false}
BACKUP_TMP_FOLDER=${BACKUP_TMP_FOLDER}:-/backup}
BACKUP_ID=${BACKUP_ID}
BACKUP_SECRET=${BACKUP_SECRET}

S5_CMD_IMAGE=${S5_CMD_IMAGE:-peakcom/s5cmd:v2.3.0}
S3_BUCKET=${S3_BUCKET}
S3_PREFIX=${S3_PREFIX}
S3_REGION=${S3_REGION}
S3_ENDPOINT_URL=${S3_ENDPOINT_URL:-https://s3.${S3_REGION}.amazonaws.com}

LVM_VG=${LVM_VG}
LVM_LV=${LVM_LV}
LVM_SNAPSHOT_SIZE=${LVM_SNAPSHOT_SIZE:-"-L50G"}

TODAY=$(date +%Y%m%d-%H%M%S)

LVM_DEVICE=/dev/${LVM_VG}/${LVM_LV}
SNAP_LVM_DEVICE=/dev/${LVM_VG}/${LVM_LV}-${BACKUP_ID}-snap
SNAP_MOUNTPOINT=/mnt/${LVM_LV}-${BACKUP_ID}-snap
BACKUP_TMP_FILE=/${BACKUP_TMP_FOLDER}/${BACKUP_ID}-${TODAY}.tar.gz
BACKUP_S3_PATH=${S3_PREFIX}/${BACKUP_ID}/${SSH_HOST}/
BACKUP_PATH_SOURCE=${SNAP_MOUNTPOINT}
BACKUP_PATH_DEST=${BACKUP_PATH_DEST:-/backup/${BACKUP_ID}/${SSH_HOST_SOURCE}}

if [ "a${SSH_HOST_SOURCE}" == "a" ]; then
  echo "ERROR: Missing SSH_HOST_SOURCE variable, exiting ..."
  exit 1
fi

if [ "a${SSH_HOST_DEST}" == "a" ]; then
  echo "ERROR: Missing SSH_HOST_DEST variable, exiting ..."
  exit 1
fi

if [ a"${DRY_RUN}" == a"true" ]; then
  RSYNC_EXTRA_FLAGS="${RSYNC_EXTRA_FLAGS}n"
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
ssh ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE} ${SSH_OPTS} -p ${SSH_PORT_SOURCE} "lvcreate ${LVM_SNAPSHOT_SIZE} -s -n ${BACKUP_ID}-snap ${LVM_DEVICE}"
# Mount snapshot
echo "Mounting snapshot ${SNAP_LVM_DEVICE} on ${SNAP_MOUNTPOINT} ..."
ssh ${SSH_USER_SOURCE}@${SSH_HOST_SOURCE} ${SSH_OPTS} -p ${SSH_PORT_SOURCE} "if [ ! -e ${SNAP_MOUNTPOINT} ]; then mkdir -p ${SNAP_MOUNTPOINT}; fi; mount -o ro ${SNAP_LVM_DEVICE} ${SNAP_MOUNTPOINT}"

exit 0 

# Rsync backup to destination server
ssh ${SSH_USER_DEST}@${SSH_HOST_DEST} ${SSH_OPTS} -p ${SSH_PORT_DEST} "if [ ! -e ${BACKUP_PATH_DEST} ]; then mkdir -p ${BACKUP_PATH_DEST}; fi"
rsync -${RSYNC_EXTRA_FLAGS}avz --delete-before -e "ssh ${SSH_OPTS} -p ${SSH_PORT_DEST}" ${BACKUP_PATH_SOURCE}/ ${SSH_USER_DEST}@${SSH_HOST_DEST}:${BACKUP_PATH_DEST}/

# Upload the backup to S3
if [ a"${AWS_ACCESS_KEY_ID}" != "a" -a "a${AWS_SECRET_ACCESS_KEY}" != "a" -a "a${S3_BUCKET}" != "a" ]; then
  echo "Uploading backup to S3 server ${S3_ENDPOINT_URL} and bucket s3://${S3_BUCKET}/${BACKUP_S3_PATH} ..."
  docker run --rm -a stdout -a stderr -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e S3_ENDPOINT_URL -v ${BACKUP_TMP_FOLDER}:${BACKUP_TMP_FOLDER}:ro ${S5_CMD_IMAGE} cp --storage-class=STANDARD_IA ${BACKUP_TMP_FILE}* s3://${S3_BUCKET}/${BACKUP_S3_PATH}/
  backup-warden --hourly=240 --daily=30  --weekly=12 --monthly=12 --yearly=2 -s s3 -b ${S3_BUCKET} -p ${BACKUP_S3_PATH} --delete
fi

# Upload the backup to a secondary S3
if [ a"${SECONDARY_AWS_ACCESS_KEY_ID}" != "a" -a "a${SECONDARY_AWS_SECRET_ACCESS_KEY}" != "a" -a "a${S3_BUCKET}" != "a" -a "a${SECONDARY_S3_ENDPOINT_URL}" != "a" ]; then
  echo "Uploading backup to S3 server ${SECONDARY_S3_ENDPOINT_URL} and bucket s3://${S3_BUCKET}/${BACKUP_S3_PATH} ..."
  docker run --rm -a stdout -a stderr -e AWS_ACCESS_KEY_ID=${SECONDARY_AWS_ACCESS_KEY_ID} -e AWS_SECRET_ACCESS_KEY=${SECONDARY_AWS_SECRET_ACCESS_KEY} -e S3_ENDPOINT_URL=${SECONDARY_S3_ENDPOINT_URL} -v ${BACKUP_TMP_FOLDER}:${BACKUP_TMP_FOLDER}:ro ${S5_CMD_IMAGE} cp ${BACKUP_TMP_FILE}* s3://${S3_BUCKET}/${BACKUP_S3_PATH}
  AWS_ACCESS_KEY_ID=${SECONDARY_AWS_ACCESS_KEY_ID} AWS_SECRET_ACCESS_KEY=${SECONDARY_AWS_SECRET_ACCESS_KEY} S3_ENDPOINT_URL=${SECONDARY_S3_ENDPOINT_URL} backup-warden --hourly=240 --daily=30  --weekly=12 --monthly=12 --yearly=2 -s s3 -b ${S3_BUCKET} -p ${BACKUP_S3_PATH} --delete
fi

# Delete backup file
echo "Deleting backup file ${BACKUP_TMP_FILE} ..."
ssh ${SSH_USER}@${SSH_HOST} ${SSH_OPTS} -p ${SSH_PORT} "rm ${BACKUP_TMP_FILE}*"

cleanup_lvm
