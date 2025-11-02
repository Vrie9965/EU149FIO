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

# Episodes to recover with their album IDs
declare -A episode_albums
episode_albums["01"]="122102865896200694"
episode_albums["02"]="122119297598200694"

# Always create recovered file and write header
cat > "$RECOVERED_FILE" << EOF
# Recovery Log - $(date)
# Attempting to recover Episode 01 and 02

EOF

echo "Starting recovery process..."
echo "Configuration check:"
echo "  API Origin: ${FRMENV_API_ORIGIN}"
echo "  API Version: ${FRMENV_FBAPI_VER}"
echo "  Token present: $([ -n "$FRMENV_FBTOKEN" ] && echo 'YES' || echo 'NO')"
echo ""

total_recovered=0

# Process each episode
for episode in "01" "02"; do
  album_id="${episode_albums[$episode]}"
  
  echo "=========================================="
  echo "RECOVERING EPISODE $episode"
  echo "Album ID: $album_id"
  echo "=========================================="
  echo ""
  
  echo "# Episode $episode - Album: $album_id" >> "$RECOVERED_FILE"
  
  # Fetch photos from this specific album
  url="${FRMENV_API_ORIGIN}/${FRMENV_FBAPI_VER}/${album_id}/photos?fields=id,name,created_time&limit=100&access_token=${FRMENV_FBTOKEN}"
  
  page_count=0
  episode_count=0
  
  # Array to store all photos for this episode
  declare -a photo_data
  
  while [[ -n "$url" ]]; do
    page_count=$((page_count + 1))
    echo "Fetching page $page_count..."
    
    response=$(curl -s "$url")
    
    # Check for errors
    error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$error_msg" ]]; then
      echo "ERROR: $error_msg"
      echo "# ERROR on Episode $episode: $error_msg" >> "$RECOVERED_FILE"
      break
    fi
    
    # Get photos from this page
    photos=$(echo "$response" | jq -r '.data[]? | @json' 2>/dev/null)
    if [[ -z "$photos" ]]; then
      echo "No more photos found."
      break
    fi
    
    # Store photos
    while IFS= read -r photo; do
      if [[ -n "$photo" ]]; then
        photo_data+=("$photo")
      fi
    done <<< "$photos"
    
    photos_count=$(echo "$photos" | wc -l)
    episode_count=$((episode_count + photos_count))
    echo "  Found $photos_count photos (total for episode: $episode_count)"
    
    # Show sample of first 3 photo names to debug
    if [[ $page_count -eq 1 ]]; then
      echo ""
      echo "Sample photo names from this album:"
      echo "$photos" | head -3 | while IFS= read -r photo; do
        name=$(echo "$photo" | jq -r '.name // "NO NAME"' 2>/dev/null)
        id=$(echo "$photo" | jq -r '.id // "NO ID"' 2>/dev/null)
        echo "  - ID: $id"
        echo "    Name: $name"
      done
      echo ""
    fi
    
    # Get next page
    url=$(echo "$response" | jq -r '.paging.next // empty' 2>/dev/null)
    sleep 0.5
  done
  
  echo ""
  echo "Total photos found for Episode $episode: $episode_count"
  echo ""
  
  # Now process all photos for this episode
  if [[ ${#photo_data[@]} -gt 0 ]]; then
    echo "Processing ${#photo_data[@]} photos..."
    
    frame_num=1
    for photo in "${photo_data[@]}"; do
      post_id=$(echo "$photo" | jq -r '.id // empty' 2>/dev/null)
      name=$(echo "$photo" | jq -r '.name // empty' 2>/dev/null)
      
      if [[ -n "$post_id" ]]; then
        # Try to extract frame number from name if it exists
        if [[ -n "$name" ]] && echo "$name" | grep -qiE "Frame[[:space:]]*[0-9]+"; then
          extracted_frame=$(echo "$name" | grep -oiE "Frame[[:space:]]*[0-9]+" | grep -oE "[0-9]+" | head -1)
          if [[ -n "$extracted_frame" ]]; then
            frame_num=$extracted_frame
          fi
        fi
        
        # Construct Facebook URL
        fb_url="https://facebook.com/${post_id}"
        
        # Write in same format as original log
        log_entry="[√] Frame: ${frame_num}, Episode ${episode} ${fb_url}"
        echo "$log_entry" >> "$RECOVERED_FILE"
        
        total_recovered=$((total_recovered + 1))
        
        # Only show progress every 100 frames
        if (( frame_num % 100 == 0 )); then
          echo "  Processed frame $frame_num..."
        fi
        
        frame_num=$((frame_num + 1))
      fi
    done
    
    echo "Wrote $episode_count frames for Episode $episode"
  else
    echo "# No photos found for Episode $episode" >> "$RECOVERED_FILE"
    echo "No photos found for Episode $episode"
  fi
  
  echo "" >> "$RECOVERED_FILE"
  echo ""
  
  # Clear array for next episode
  unset photo_data
  declare -a photo_data
done

echo "=========================================="
echo "RECOVERY COMPLETE!"
echo "=========================================="
echo "Total frames recovered: $total_recovered"
echo "Recovered log saved to: $RECOVERED_FILE"
echo ""

if [[ $total_recovered -gt 0 ]]; then
  echo "SUCCESS! Found $total_recovered frames across Episode 01 and 02"
  echo "You can now merge recovered_log.txt with log.txt"
else
  echo "WARNING: No frames were recovered."
  echo "Check the recovered_log.txt file for error messages."
fi

# Always show file size
if [[ -f "$RECOVERED_FILE" ]]; then
  file_size=$(wc -c < "$RECOVERED_FILE")
  echo "Recovered log file size: $file_size bytes"
fi
