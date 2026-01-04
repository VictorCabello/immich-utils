#!/bin/bash

# A script to backup the Immich gallery to DVD-sized chunks.
# Tracks progress via a state file to allow for resuming.

# --- Configuration ---
IMMICH_URL_DEFAULT="http://localhost:2283"
DVD_CAPACITY_BYTES=4700000000
DEFAULT_BACKUP_DIR="./immich_backups"
DEFAULT_STATE_FILE="./immich_backup_state.json"

# --- Script ---
set -e
set -o pipefail

# --- Helper Functions ---
function print_usage() {
  echo "Usage: immich_dvd_backup.sh [immich_url] [api_key]"
  echo ""
  echo "This script downloads your Immich gallery in DVD-sized chunks."
  echo ""
  echo "CONFIGURATION:"
  echo "  Priority: Command-line Arguments > Environment Variables > Config File > Defaults."
  echo ""
  echo "  CONFIG FILE PROPERTIES:"
  echo "    IMMICH_URL:           Immich server URL."
  echo "    IMMICH_API_KEY:       Immich API key."
  echo "    IMMICH_BACKUP_DIR:    Directory to save backups."
  echo "    IMMICH_BACKUP_STATE_FILE: Path to the progress state file."
}

function check_deps() {
  for dep in curl jq awk; do
    if ! command -v "$dep" &> /dev/null; then
      echo "Error: $dep is not installed." >&2
      exit 1
    fi
  done
}

_CFG_IMMICH_URL=""
_CFG_API_KEY=""
_CFG_BACKUP_DIR=""
_CFG_STATE_FILE=""

function load_config() {
  CONFIG_FILES=(
    "./immich-uploader.conf"
    "$HOME/.immich-uploader.conf"
    "$HOME/.config/immich-uploader.conf"
  )

  for config_file in "${CONFIG_FILES[@]}"; do
    if [ -f "$config_file" ]; then
      echo "Info: Loading config from '$config_file'"
      while IFS='=' read -r key value; do
          key=$(echo "$key" | tr -d '[:space:]')
          value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
          case "$key" in
              IMMICH_URL) _CFG_IMMICH_URL="$value" ;;
              IMMICH_API_KEY) _CFG_API_KEY="$value" ;;
              IMMICH_BACKUP_DIR) _CFG_BACKUP_DIR="$value" ;;
              IMMICH_BACKUP_STATE_FILE) _CFG_STATE_FILE="$value" ;;
          esac
      done < <(grep -E '^(IMMICH_URL|IMMICH_API_KEY|IMMICH_BACKUP_DIR|IMMICH_BACKUP_STATE_FILE)' "$config_file")
      return
    fi
  done
}

function format_bytes() {
  local bytes=$1
  awk -v b="$bytes" "BEGIN {
    split(\"B KB MB GB TB\", units);
    i = 1;
    while (b >= 1024 && i < 5) {
      b /= 1024;
      i++;
    }
    printf \"%.2f %s\", b, units[i];
  }"
}

# --- Main Logic ---
check_deps

# Handle --help flag
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    print_usage
    exit 0
fi

load_config

FINAL_IMMICH_URL="${1:-${IMMICH_URL:-${_CFG_IMMICH_URL:-${IMMICH_URL_DEFAULT}}}}"
FINAL_API_KEY="${2:-${IMMICH_API_KEY:-${_CFG_API_KEY}}}"
FINAL_BACKUP_DIR="${IMMICH_BACKUP_DIR:-${_CFG_BACKUP_DIR:-${DEFAULT_BACKUP_DIR}}}"
FINAL_STATE_FILE="${IMMICH_BACKUP_STATE_FILE:-${_CFG_STATE_FILE:-${DEFAULT_STATE_FILE}}}"

if [ -z "$FINAL_IMMICH_URL" ] || [ -z "$FINAL_API_KEY" ]; then
    echo "Error: Immich URL or API Key not specified." >&2
    print_usage
    exit 1
fi

# Ensure backup directory exists
mkdir -p "$FINAL_BACKUP_DIR"

# Load State
LAST_ASSET_ID=""
CURRENT_DVD=1
CURRENT_DVD_SIZE=0

if [ -f "$FINAL_STATE_FILE" ]; then
  echo "Info: Loading state from '$FINAL_STATE_FILE'"
  LAST_ASSET_ID=$(jq -r '.last_asset_id // ""' "$FINAL_STATE_FILE")
  CURRENT_DVD=$(jq -r '.current_dvd // 1' "$FINAL_STATE_FILE")
  CURRENT_DVD_SIZE=$(jq -r '.current_dvd_size // 0' "$FINAL_STATE_FILE")
else
  echo "Info: No state file found. Starting fresh."
fi

function save_state() {
  jq -n \
    --arg id "$LAST_ASSET_ID" \
    --arg dvd "$CURRENT_DVD" \
    --arg size "$CURRENT_DVD_SIZE" \
    '{last_asset_id: $id, current_dvd: ($dvd|tonumber), current_dvd_size: ($size|tonumber)}' > "$FINAL_STATE_FILE"
}

# Fetch Assets
echo "Fetching asset list from Immich..."
# We'll fetch assets in pages of 1000
PAGE=1
HAS_MORE=true
SKIPPING=true
if [ -z "$LAST_ASSET_ID" ]; then
  SKIPPING=false
fi

while [ "$HAS_MORE" = true ]; do
  echo "  Processing page $PAGE..."
  
  # Search assets sorted by creation date, oldest first
  # Note: The search endpoint might vary by Immich version. 
  # Using /api/search/metadata with order=asc
  RESPONSE=$(curl --silent -X POST "${FINAL_IMMICH_URL}/api/search/metadata" \
    -H "x-api-key: ${FINAL_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"order\": \"asc\",
      \"page\": $PAGE,
      \"size\": 1000
    }")

  ASSETS=$(echo "$RESPONSE" | jq -c '.assets.items[]')
  
  if [ -z "$ASSETS" ]; then
    HAS_MORE=false
    break
  fi

  while read -r asset; do
    ID=$(echo "$asset" | jq -r '.id')
    SIZE=$(echo "$asset" | jq -r '.exifInfo.fileSizeInBytes // 0')
    FILENAME=$(echo "$asset" | jq -r '.originalFileName // .id')
    EXT=$(echo "$asset" | jq -r '.originalPath' | awk -F. '{print $NF}')
    
    # Handle skipping already processed assets
    if [ "$SKIPPING" = true ]; then
      if [ "$ID" = "$LAST_ASSET_ID" ]; then
        SKIPPING=false
      fi
      continue
    fi

    # Check if we need to start a new DVD
    if [ $((CURRENT_DVD_SIZE + SIZE)) -gt $DVD_CAPACITY_BYTES ]; then
      echo "DVD $CURRENT_DVD is full ($(format_bytes $CURRENT_DVD_SIZE)). Starting DVD $((CURRENT_DVD + 1))."
      CURRENT_DVD=$((CURRENT_DVD + 1))
      CURRENT_DVD_SIZE=0
      save_state
    fi

    DVD_DIR="$FINAL_BACKUP_DIR/DVD_$CURRENT_DVD"
    mkdir -p "$DVD_DIR"

    # Download Asset
    TARGET_FILE="$DVD_DIR/$FILENAME.$EXT"
    # If file exists, we might want to append a suffix to avoid collisions
    if [ -f "$TARGET_FILE" ]; then
        TARGET_FILE="$DVD_DIR/${FILENAME}_${ID}.$EXT"
    fi

    echo "  Downloading: $FILENAME ($ID) to DVD_$CURRENT_DVD..."
    curl --silent -X GET "${FINAL_IMMICH_URL}/api/assets/$ID/original" \
      -H "x-api-key: ${FINAL_API_KEY}" \
      --output "$TARGET_FILE"

    CURRENT_DVD_SIZE=$((CURRENT_DVD_SIZE + SIZE))
    LAST_ASSET_ID="$ID"
    save_state

  done <<< "$ASSETS"

  PAGE=$((PAGE + 1))
done

echo ""
echo "Backup process completed."
echo "Total DVDs created: $CURRENT_DVD"
echo "Final state saved to: $FINAL_STATE_FILE"
