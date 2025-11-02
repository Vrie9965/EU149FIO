#!/bin/bash
# File: EOFIO12/scripts/reshare_random.sh

: "${FRMENV_FBTOKEN:=${TOK_FB:-}}"

if [[ -z "$FRMENV_FBTOKEN" ]]; then
  echo "1 FRMENV_FBTOKEN is empty!"
  exit 1
fi

. "$(dirname "$0")/../config.conf"

LOG_FILE="$(dirname "$0")/../fb/log.txt"

episodes=$(awk '{for(i=1;i<=NF;i++) if ($i=="Episode") print $(i+1)}' "$LOG_FILE" | sort -u)

random_episode=$(echo "$episodes" | shuf -n 1)
random_line=$(grep "Episode ${random_episode}" "$LOG_FILE" | shuf -n 1)

frame_info=$(echo "$random_line" | awk -F 'https' '{print $1}' | sed 's/\[√\] *//')
frame_url=$(echo "$random_line" | awk '{print $NF}')

message="Random frame. ${frame_info}"

# debug
echo "DEBUG: Posting to page URL: ${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/194597373745170/feed?access_token=${FRMENV_FBTOKEN}"
echo "DEBUG: Picked episode ${random_episode}"

response=$(
  curl -s -w "\n%{http_code}" -X POST \
    -F "message=${message}" \
    -F "link=${frame_url}" \
    "${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/194597373745170/feed?access_token=${FRMENV_FBTOKEN}"
)

body=$(echo "$response" | head -n 1)
status=$(echo "$response" | tail -n 1)

if [[ "$status" != "200" ]]; then
  echo "Failed to share $frame_url"
  echo "Facebook response: $body"
  exit 1
fi

echo "Shared: $frame_info $frame_url"
