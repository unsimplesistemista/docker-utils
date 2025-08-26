#/bin/bash

set -e

BACKUP_HOST=${BACKUP_HOST}
export DOCKER_HOST=${DOCKER_HOST:-tcp://${BACKUP_HOST}:2375}

MYSQL_USER=${MYSQL_USER:-root}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_HOST=${MYSQL_HOST}
MYSQL_PORT=${MYSQL_PORT:-3306}
MYSQL_DATADIR=${MYSQL_DATADIR:-/var/lib/mysql}
MYSQL_DATABASE_EXCLUDE=${MYSQL_DATABASE_EXCLUDE}

BACKUP_TMP_FOLDER=${BACKUP_TMP_FOLDER:-/backup}
BACKUP_ID=${BACKUP_ID}
BACKUP_SECRET=${BACKUP_SECRET}

S5_CMD_IMAGE=${S5_CMD_IMAGE:-peakcom/s5cmd:v2.3.0}
S3_BUCKET=${S3_BUCKET}
S3_PREFIX=${S3_PREFIX}
S3_REGION=${S3_REGION}
S3_ENDPOINT_URL=${S3_ENDPOINT_URL:-https://s3.${S3_REGION}.amazonaws.com}

TODAY=$(date +%Y%m%d-%H%M%S)

BACKUP_TMP_PATH=${BACKUP_TMP_FOLDER}/${BACKUP_ID}-${TODAY}
BACKUP_TMP_FILE=${BACKUP_TMP_FOLDER}/${BACKUP_ID}-${TODAY}.tar.gz
PRESERVE_BACKUP_FILE=${PRESERVE_BACKUP_FILE:-false}
BACKUP_S3_PATH=${S3_PREFIX}/${BACKUP_ID}/${SSH_HOST}/

if [ "a${BACKUP_HOST}" == "a" ]; then
  echo "ERROR: Missing BACKUP_HOST variable, exiting ..."
  exit 1
fi

if [ "a${MYSQL_PASSWORD}" == "a" ]; then
  echo "ERROR: Missing MYSQL_PASSWORD variable, exiting ..."
  exit 1
fi

if [ "a${BACKUP_ID}" == "a" ]; then
  echo "ERROR: Missing BACKUP_ID variable, exiting ..."
  exit 1
fi

if [ "a${MYSQL_DATABASE_EXCLUDE}" != "a" ]; then
  XTRABACKUP_BACKUP_EXTRA_FLAGS="--databases-exclude=\"${MYSQL_DATABASE_EXCLUDE}\" ${XTRABACKUP_BACKUP_EXTRA_FLAGS}"
fi

xtrabackup --backup --target-dir ${BACKUP_TMP_PATH} --rsync \
  --user=${MYSQL_USER} --password=${MYSQL_PASSWORD} \
  --host=${MYSQL_HOST} --port=${MYSQL_PORT} \
  ${XTRABACKUP_BACKUP_EXTRA_FLAGS}

xtrabackup --prepare --target-dir ${BACKUP_TMP_PATH}

# Create a tar.gz of the backup
if [ "a${BACKUP_SECRET}" == "a" ]; then
  echo "Compressing backup file ${BACKUP_TMP_FILE} ..."
  tar -zvcf ${BACKUP_TMP_FILE} -C ${BACKUP_TMP_PATH} .
  if [ ! -e ${BACKUP_TMP_FILE} ]; then
    echo "ERROR: could not create backup file ${BACKUP_TMP_FILE}, exiting ..."
    exit 1
  fi
else
  # Decrypt using openssl enc -d -aes-256-cbc -md md5 -k password -in archive.tar.gz.encrypt | tar -x
  echo "Compressing and encrypting backup file ${BACKUP_TMP_FILE}.encrypt ..."
  tar -zvcf - -C ${BACKUP_TMP_PATH} . | openssl enc -e -aes256 -pbkdf2 -pass pass:${BACKUP_SECRET} -out ${BACKUP_TMP_FILE}.encrypt
  if [ ! -e ${BACKUP_TMP_FILE}.encrypt ]; then
    echo "ERROR: could not create backup file ${BACKUP_TMP_FILE}.encrypt, exiting ..."
    exit 1
  fi
fi

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
echo "Deleting backup folder ${BACKUP_TMP_PATH} ..."
rm -rf ${BACKUP_TMP_PATH}
if [ a"${PRESERVE_BACKUP_FILE}" != a"true" ]; then
  echo "Deleting backup file ${BACKUP_TMP_FILE} ..."
  rm -rf ${BACKUP_TMP_FILE}*
fi
