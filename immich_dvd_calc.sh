#!/bin/bash

# A script to calculate the number of DVDs needed to backup all images and videos from an Immich server.

# --- Configuration ---
# Default Immich server URL.
IMMICH_URL_DEFAULT="http://localhost:2283"

# DVD Capacity in Bytes (Standard 4.7 GB DVD-R)
# 4.7 * 1000 * 1000 * 1000 (Manufacturers use 1000, not 1024)
DVD_CAPACITY_BYTES=4700000000

# --- Script ---

set -e
set -o pipefail

# --- Helper Functions ---
function print_usage() {
  echo "Usage: immich_dvd_calc.sh [immich_url] [api_key]"
  echo ""
  echo "This script connects to Immich and calculates the number of DVDs needed for backup."
  echo ""
  echo "ARGUMENTS:"
  echo "  [immich_url]:  Your Immich server URL. Overrides config and env var."
  echo "  [api_key]:     Your Immich API key. Overrides config and env var."
  echo ""
  echo "CONFIGURATION:"
  echo "  Settings can be provided via a config file, environment variables, or arguments."
  echo "  Priority: Command-line Arguments > Environment Variables > Config File > Defaults."
  echo ""
  echo "  ENVIRONMENT VARIABLES:"
  echo "    IMMICH_URL:           Immich server URL."
  echo "    IMMICH_API_KEY:       Immich API key."
  echo ""
  echo "  CONFIG FILE:"
  echo "    The script searches for 'immich-uploader.conf' in the following locations:"
  echo "    - ./immich-uploader.conf"
  echo "    - ~/.immich-uploader.conf"
  echo "    - ~/.config/immich-uploader.conf"
}

function check_deps() {
  if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install it to continue." >&2
    exit 1
  fi
  if ! command -v jq &> /dev/null; then
    echo "Error: jq is not installed. Please install it to continue." >&2
    exit 1
  fi
}

# These variables will hold values from the config file.
_CFG_IMMICH_URL=""
_CFG_API_KEY=""

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
          esac
      done < <(grep -E '^(IMMICH_URL|IMMICH_API_KEY)' "$config_file")
      return
    fi
  done
}

# --- Main Logic ---

check_deps

# Handle --help flag
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    print_usage
    exit 0
fi

# --- Configuration Loading ---
load_config

# Determine final values with priority: CLI > ENV > Config > Default
FINAL_IMMICH_URL="${1:-${IMMICH_URL:-${_CFG_IMMICH_URL:-${IMMICH_URL_DEFAULT}}}}"
FINAL_API_KEY="${2:-${IMMICH_API_KEY:-${_CFG_API_KEY}}}"

# --- Configuration Validation ---
if [ -z "$FINAL_IMMICH_URL" ]; then
    echo "Error: Immich URL not specified." >&2
    exit 1
fi

if [ -z "$FINAL_API_KEY" ]; then
  echo "Error: API key not specified." >&2
  exit 1
fi

function ping_server() {
  echo "Pinging server..."
  ping_response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -X GET "${FINAL_IMMICH_URL}/api/server/ping")
  http_status=$(echo "$ping_response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

  if [ "$http_status" -eq 200 ]; then
    echo "Server is reachable."
  else
    echo "Error: Server is not reachable. Status: $http_status" >&2
    exit 1
  fi
}

# --- Server Ping ---
ping_server

# --- Fetch Statistics ---
echo "Fetching storage statistics..."
stats_response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" \
  -X GET "${FINAL_IMMICH_URL}/api/server/statistics" \
  -H "x-api-key: ${FINAL_API_KEY}")

http_status=$(echo "$stats_response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
body=$(echo "$stats_response" | sed -e 's/HTTPSTATUS:.*//g')

if [ "$http_status" -ne 200 ]; then
  echo "Error: Failed to fetch statistics. Status: $http_status" >&2
  echo "Response: $body" >&2
  exit 1
fi

# Parse statistics using jq
usage_photos=$(echo "$body" | jq -r '.usagePhotos // 0')
usage_videos=$(echo "$body" | jq -r '.usageVideos // 0')
total_photos=$(echo "$body" | jq -r '.photos // 0')
total_videos=$(echo "$body" | jq -r '.videos // 0')

total_usage_bytes=$((usage_photos + usage_videos))

# Calculate DVD count
dvd_count=$(awk -v t="$total_usage_bytes" -v c="$DVD_CAPACITY_BYTES" "BEGIN {printf \"%.2f\", t / c}")
dvd_count_ceil=$(awk -v t="$total_usage_bytes" -v c="$DVD_CAPACITY_BYTES" "BEGIN {print int((t + c - 1) / c)}")

# Format bytes to human readable
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

echo ""
echo "======== Immich Storage Summary ========"
echo "Total Photos: $total_photos ($(format_bytes "$usage_photos"))"
echo "Total Videos: $total_videos ($(format_bytes "$usage_videos"))"
echo "----------------------------------------"
echo "Total Backup Size: $(format_bytes "$total_usage_bytes")"
echo "DVD Capacity:      $(format_bytes "$DVD_CAPACITY_BYTES")"
echo "----------------------------------------"
echo "Estimated DVDs needed: $dvd_count_ceil"
echo "(Exact calculation: $dvd_count DVDs)"
echo "========================================"
