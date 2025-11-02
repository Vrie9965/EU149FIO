#!/bin/bash
# File: EOFIO12/scripts/recover_logs.sh
# Recovers missing episode logs from Facebook page posts

: "${FRMENV_FBTOKEN:=${TOK_FB:-}}"
if [[ -z "$FRMENV_FBTOKEN" ]]; then
  echo "ERROR: FRMENV_FBTOKEN is empty!"
  exit 1
fi

. "$(dirname "$0")/../config.conf"
LOG_FILE="$(dirname "$0")/../fb/log.txt"
RECOVERED_FILE="$(dirname "$0")/../fb/recovered_log.txt"

# Episodes to recover
episodes_to_recover=("01" "02")

# Clear recovered file
> "$RECOVERED_FILE"

echo "Starting recovery process..."
echo "Fetching posts from Facebook page..."

# Fetch all posts from the page
page_id="194597373745170"
url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${page_id}/posts?fields=id,message,created_time&limit=100&access_token=${FRMENV_FBTOKEN}"

all_posts=""
page_count=0

while [[ -n "$url" ]]; do
  page_count=$((page_count + 1))
  echo "Fetching page $page_count of posts..."
  
  response=$(curl -s "$url")
  
  # Extract posts data
  posts=$(echo "$response" | jq -r '.data[]? | @json')
  
  if [[ -z "$posts" ]]; then
    echo "No more posts found."
    break
  fi
  
  all_posts="${all_posts}${posts}"$'\n'
  
  # Get next page URL
  url=$(echo "$response" | jq -r '.paging.next // empty')
  
  # Rate limiting
  sleep 1
done

echo "Total pages fetched: $page_count"
echo "Processing posts to find episode frames..."

# Process posts to find episode frames
recovered_count=0

for episode in "${episodes_to_recover[@]}"; do
  echo ""
  echo "=== Recovering Episode $episode ==="
  
  # Filter posts that mention this episode
  episode_posts=$(echo "$all_posts" | while IFS= read -r post; do
    if [[ -n "$post" ]]; then
      message=$(echo "$post" | jq -r '.message // empty')
      post_id=$(echo "$post" | jq -r '.id // empty')
      
      if echo "$message" | grep -q "Episode $episode"; then
        echo "$post_id|$message"
      fi
    fi
  done | sort)
  
  if [[ -z "$episode_posts" ]]; then
    echo "No posts found for Episode $episode"
    continue
  fi
  
  # Parse and write to recovered log
  echo "$episode_posts" | while IFS='|' read -r post_id message; do
    if [[ -n "$post_id" ]]; then
      # Extract frame number from message
      frame_num=$(echo "$message" | grep -oE "Frame:? ?[0-9]+" | grep -oE "[0-9]+" | head -1)
      
      if [[ -z "$frame_num" ]]; then
        frame_num="?"
      fi
      
      # Construct Facebook URL
      fb_url="https://facebook.com/${post_id}"
      
      # Write in same format as original log
      log_entry="[√] Frame: ${frame_num}, Episode ${episode} ${fb_url}"
      echo "$log_entry" >> "$RECOVERED_FILE"
      echo "$log_entry"
      
      recovered_count=$((recovered_count + 1))
    fi
  done
done

echo ""
echo "=========================================="
echo "Recovery complete!"
echo "Total frames recovered: $recovered_count"
echo "Recovered log saved to: $RECOVERED_FILE"
echo ""
echo "You can now manually merge recovered_log.txt with log.txt"
