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

page_id="194597373745170"
all_posts_file=$(mktemp)
total_posts=0

# Method 1: Try to get photos from albums (most likely to work)
echo "=========================================="
echo "METHOD 1: Fetching photos from albums..."
echo "=========================================="

url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${page_id}/albums?fields=id,name&access_token=${FRMENV_FBTOKEN}"
albums_response=$(curl -s "$url")

error_msg=$(echo "$albums_response" | jq -r '.error.message // empty' 2>/dev/null)
if [[ -n "$error_msg" ]]; then
  echo "Method 1 failed: $error_msg"
else
  albums=$(echo "$albums_response" | jq -r '.data[]? | .id' 2>/dev/null)
  if [[ -n "$albums" ]]; then
    echo "Found albums, fetching photos..."
    while IFS= read -r album_id; do
      echo "  Checking album: $album_id"
      photo_url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${album_id}/photos?fields=id,name,created_time&limit=100&access_token=${FRMENV_FBTOKEN}"
      
      page_count=0
      while [[ -n "$photo_url" ]]; do
        page_count=$((page_count + 1))
        photos_response=$(curl -s "$photo_url")
        
        photos=$(echo "$photos_response" | jq -r '.data[]? | @json' 2>/dev/null)
        if [[ -n "$photos" ]]; then
          photos_count=$(echo "$photos" | wc -l)
          total_posts=$((total_posts + photos_count))
          echo "    Page $page_count: Found $photos_count photos"
          echo "$photos" >> "$all_posts_file"
        fi
        
        photo_url=$(echo "$photos_response" | jq -r '.paging.next // empty' 2>/dev/null)
        sleep 0.5
      done
    done <<< "$albums"
  fi
fi

echo "Method 1 total: $total_posts posts"
echo ""

# Method 2: Try photos endpoint directly
echo "=========================================="
echo "METHOD 2: Fetching photos directly..."
echo "=========================================="

url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${page_id}/photos/uploaded?fields=id,name,created_time&limit=100&access_token=${FRMENV_FBTOKEN}"
page_count=0
method2_count=0

while [[ -n "$url" ]]; do
  page_count=$((page_count + 1))
  echo "Fetching page $page_count..."
  
  response=$(curl -s "$url")
  error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  
  if [[ -n "$error_msg" ]]; then
    echo "Method 2 failed: $error_msg"
    break
  fi
  
  photos=$(echo "$response" | jq -r '.data[]? | @json' 2>/dev/null)
  if [[ -z "$photos" ]]; then
    break
  fi
  
  photos_count=$(echo "$photos" | wc -l)
  method2_count=$((method2_count + photos_count))
  total_posts=$((total_posts + photos_count))
  echo "  Found $photos_count photos"
  echo "$photos" >> "$all_posts_file"
  
  url=$(echo "$response" | jq -r '.paging.next // empty' 2>/dev/null)
  sleep 0.5
done

echo "Method 2 total: $method2_count posts"
echo ""

# Method 3: Try feed endpoint
echo "=========================================="
echo "METHOD 3: Fetching from feed..."
echo "=========================================="

url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${page_id}/feed?fields=id,message,created_time&limit=100&access_token=${FRMENV_FBTOKEN}"
page_count=0
method3_count=0

while [[ -n "$url" ]] && [[ $page_count -lt 5 ]]; do
  page_count=$((page_count + 1))
  echo "Fetching page $page_count..."
  
  response=$(curl -s "$url")
  error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  
  if [[ -n "$error_msg" ]]; then
    echo "Method 3 failed: $error_msg"
    break
  fi
  
  posts=$(echo "$response" | jq -r '.data[]? | @json' 2>/dev/null)
  if [[ -z "$posts" ]]; then
    break
  fi
  
  posts_count=$(echo "$posts" | wc -l)
  method3_count=$((method3_count + posts_count))
  total_posts=$((total_posts + posts_count))
  echo "  Found $posts_count posts"
  echo "$posts" >> "$all_posts_file"
  
  url=$(echo "$response" | jq -r '.paging.next // empty' 2>/dev/null)
  sleep 0.5
done

echo "Method 3 total: $method3_count posts"
echo ""

# Method 4: Try specific photo IDs from the album set
echo "=========================================="
echo "METHOD 4: Trying specific album photos..."
echo "=========================================="

album_set="122102861978200694"
url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${album_set}/photos?fields=id,name,created_time&limit=100&access_token=${FRMENV_FBTOKEN}"
page_count=0
method4_count=0

while [[ -n "$url" ]] && [[ $page_count -lt 10 ]]; do
  page_count=$((page_count + 1))
  echo "Fetching page $page_count from album set..."
  
  response=$(curl -s "$url")
  error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  
  if [[ -n "$error_msg" ]]; then
    echo "Method 4 failed: $error_msg"
    break
  fi
  
  photos=$(echo "$response" | jq -r '.data[]? | @json' 2>/dev/null)
  if [[ -z "$photos" ]]; then
    break
  fi
  
  photos_count=$(echo "$photos" | wc -l)
  method4_count=$((method4_count + photos_count))
  total_posts=$((total_posts + photos_count))
  echo "  Found $photos_count photos"
  echo "$photos" >> "$all_posts_file"
  
  url=$(echo "$response" | jq -r '.paging.next // empty' 2>/dev/null)
  sleep 0.5
done

echo "Method 4 total: $method4_count posts"
echo ""

echo "=========================================="
echo "TOTAL POSTS COLLECTED: $total_posts"
echo "=========================================="
echo ""

if [[ $total_posts -eq 0 ]]; then
  echo "WARNING: No posts were retrieved using any method."
  echo "This likely means the token needs different permissions."
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
  
  while IFS= read -r post; do
    if [[ -n "$post" ]]; then
      message=$(echo "$post" | jq -r '.name // .message // empty' 2>/dev/null)
      post_id=$(echo "$post" | jq -r '.id // empty' 2>/dev/null)
      
      # Look for pattern like "Episode 01" or "Episode 02"
      if echo "$message" | grep -qiE "Episode[[:space:]]*${episode}"; then
        # Extract frame number
        frame_num=$(echo "$message" | grep -oiE "Frame[[:space:]]*[0-9]+" | grep -oE "[0-9]+" | head -1)
        
        if [[ -z "$frame_num" ]]; then
          frame_num="?"
        fi
        
        # Construct Facebook URL
        fb_url="https://facebook.com/${post_id}"
        
        # Write in same format as original log
        log_entry="[√] Frame: ${frame_num}, Episode ${episode} ${fb_url}"
        echo "$log_entry" >> "$RECOVERED_FILE"
        echo "  Found: Frame $frame_num - $post_id"
        
        recovered_count=$((recovered_count + 1))
      fi
    fi
  done < "$all_posts_file"
  
  echo ""
done

# Cleanup
rm -f "$all_posts_file"

echo "=========================================="
echo "Recovery complete!"
echo "Total frames recovered: $recovered_count"
echo "Recovered log saved to: $RECOVERED_FILE"
echo ""

if [[ $recovered_count -eq 0 ]]; then
  echo "WARNING: No frames were recovered."
  echo "Posts were found but none matched Episode 01 or 02 pattern."
  echo "Empty recovered_log.txt created."
else
  echo "Success! You can now manually merge recovered_log.txt with log.txt"
fi
