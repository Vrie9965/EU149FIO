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

# Always create/clear recovered file
> "$RECOVERED_FILE"

echo "Starting recovery process..."
echo "Configuration check:"
echo "  API Origin: ${FRMENV_API_ORIGIN}"
echo "  API Version: ${FRMENV_FBAPI_VER}"
echo "  Token present: $([ -n "$FRMENV_FBTOKEN" ] && echo 'YES' || echo 'NO')"
echo ""

# Fetch all posts from the page using feed endpoint
page_id="194597373745170"
url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${page_id}/feed?fields=id,message,created_time&limit=100&access_token=${FRMENV_FBTOKEN}"

echo "Fetching posts from Facebook page..."
echo "Initial URL: ${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${page_id}/feed"
echo ""

all_posts_file=$(mktemp)
page_count=0
total_posts=0

while [[ -n "$url" ]]; do
  page_count=$((page_count + 1))
  echo "Fetching page $page_count of posts..."
  
  response=$(curl -s "$url")
  
  # Check for API errors
  error_message=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "$error_message" ]]; then
    echo "ERROR: Facebook API returned an error:"
    echo "$error_message"
    echo "Full response:"
    echo "$response"
    rm -f "$all_posts_file"
    exit 1
  fi
  
  # Extract posts data
  posts=$(echo "$response" | jq -r '.data[]? | @json' 2>/dev/null)
  
  if [[ -z "$posts" ]]; then
    echo "No more posts found on this page."
    break
  fi
  
  # Count posts on this page
  posts_count=$(echo "$posts" | wc -l)
  total_posts=$((total_posts + posts_count))
  echo "  Found $posts_count posts on this page (total so far: $total_posts)"
  
  # Save posts to temp file
  echo "$posts" >> "$all_posts_file"
  
  # Get next page URL
  url=$(echo "$response" | jq -r '.paging.next // empty' 2>/dev/null)
  
  # Rate limiting
  sleep 1
done

echo ""
echo "=========================================="
echo "Total pages fetched: $page_count"
echo "Total posts retrieved: $total_posts"
echo "=========================================="
echo ""

if [[ $total_posts -eq 0 ]]; then
  echo "WARNING: No posts were retrieved from the Facebook page."
  echo "This could mean:"
  echo "  1. The access token doesn't have permission to read posts"
  echo "  2. The page ID is incorrect"
  echo "  3. There are no posts on the page"
  echo ""
  echo "Empty recovered_log.txt created."
  rm -f "$all_posts_file"
  exit 0
fi

echo "Processing posts to find episode frames..."
echo ""

# Process posts to find episode frames
recovered_count=0

for episode in "${episodes_to_recover[@]}"; do
  echo "=== Recovering Episode $episode ==="
  
  # Filter posts that mention this episode (looking for "Episode 01" or "Episode 02" pattern)
  while IFS= read -r post; do
    if [[ -n "$post" ]]; then
      message=$(echo "$post" | jq -r '.message // empty' 2>/dev/null)
      post_id=$(echo "$post" | jq -r '.id // empty' 2>/dev/null)
      
      # Look for pattern like "Episode 01" or "Episode 02"
      if echo "$message" | grep -qiE "Episode[[:space:]]*${episode}"; then
        # Extract frame number from message (looking for "Frame X" pattern)
        frame_num=$(echo "$message" | grep -oiE "Frame[[:space:]]*[0-9]+" | grep -oE "[0-9]+" | head -1)
        
        if [[ -z "$frame_num" ]]; then
          frame_num="?"
        fi
        
        # Construct Facebook URL
        fb_url="https://facebook.com/${post_id}"
        
        # Write in same format as original log
        log_entry="[√] Frame: ${frame_num}, Episode ${episode} ${fb_url}"
        echo "$log_entry" >> "$RECOVERED_FILE"
        echo "  Found: Frame $frame_num"
        
        recovered_count=$((recovered_count + 1))
      fi
    fi
  done < "$all_posts_file"
  
  echo ""
done

# Cleanup temp file
rm -f "$all_posts_file"

echo "=========================================="
echo "Recovery complete!"
echo "Total frames recovered: $recovered_count"
echo "Recovered log saved to: $RECOVERED_FILE"
echo ""

if [[ $recovered_count -eq 0 ]]; then
  echo "WARNING: No frames were recovered."
  echo "Check if posts contain 'Episode 01' or 'Episode 02' text."
  echo "Empty recovered_log.txt created."
else
  echo "Success! You can now manually merge recovered_log.txt with log.txt"
fi
