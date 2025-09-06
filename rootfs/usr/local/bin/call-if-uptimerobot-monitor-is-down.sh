#!/bin/bash

DRY_RUN=${DRY_RUN:-false}
UR_API_ENDPOINT=https://api.uptimerobot.com/v3/monitors
UR_API_KEYS=${UR_API_KEYS}
SEMAPHORE_TTL=${SEMAPHORE_TTL:-300}
SEMAPHORE_DIR=${SEMAPHORE_DIR:-/tmp}

SKIPPED_MONITORS=(
    "https://yclas.com"
    "https://www.domestika.org"
)

FAILING_MONITORS=()
CALLED_MONITORS=()

for UR_API_KEY in $(echo ${UR_API_KEYS} | tr ',' ' '); do
  MONITORS=$(curl -s -XGET ${UR_API_ENDPOINT} -H "Accept: application/json" -H "Authorization: Bearer ${UR_API_KEY}")
  FAILING_MONITORS+=( $(echo ${MONITORS} | jq -r ".data | .[] | select(.status != \"UP\") | .url") )
done

SHOULD_CALL=false
for monitor in ${FAILING_MONITORS[@]}; do
  if [[ " ${SKIPPED_MONITORS[*]} " =~ " ${monitor} " ]]; then
    continue
  fi

  MONITOR_SEMAPHORE_FILE=${SEMAPHORE_DIR}/$(echo ${monitor} | base64).called
  TTL=$(echo $(cat ${MONITOR_SEMAPHORE_FILE} 2>/dev/null | grep "^ttl=" | awk -F= '{print $2}') + ${SEMAPHORE_TTL} | bc 2>/dev/null)
  TTL=${TTL:-0}
  if [ $(date +%s) -ge ${TTL} ]; then
    rm -f ${MONITOR_SEMAPHORE_FILE}
  else
    continue
  fi

  SHOULD_CALL=true
  echo "url=${monitor}" > ${MONITOR_SEMAPHORE_FILE}
  echo "ttl=$(date +%s)" >> ${MONITOR_SEMAPHORE_FILE}
  CALLED_MONITORS+=( ${monitor} )
done

if [ a"${SHOULD_CALL}" == a"true" ]; then
  echo "Calling for monitors down: "
  echo "${CALLED_MONITORS[@]}" | tr ' ' '\n'
  if [ a"${DRY_RUN}" == a"false" ]; then
    python3 /usr/local/bin/call.py
  fi
fi