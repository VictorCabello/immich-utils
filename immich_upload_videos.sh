#!/bin/bash

# A script to recursively upload videos from a directory to an Immich server.

# --- Configuration ---
# Default Immich server URL.
# Can be overridden by config file, environment variables, or command-line arguments.
IMMICH_URL_DEFAULT="http://localhost:2283"

# Default delay between uploads in seconds.
# Can be overridden by config file or environment variables.
IMMICH_UPLOAD_DELAY_DEFAULT="30.5"

# --- Script ---

set -e
set -o pipefail

# --- Helper Functions ---
function print_usage() {
  echo "Usage: immich_upload_videos.sh [directory] [immich_url] [api_key]"
  echo ""
  echo "This script recursively finds and uploads videos from a directory to Immich."
  echo ""
  echo "ARGUMENTS:"
  echo "  [directory]:   The directory to upload videos from. Overrides config and env var."
  echo "  [immich_url]:  Your Immich server URL. Overrides config and env var."
  echo "  [api_key]:     Your Immich API key. Overrides config and env var."
  echo ""
  echo "CONFIGURATION:"
  echo "  Settings can be provided via a config file, environment variables, or arguments."
  echo "  Priority: Command-line Arguments > Environment Variables > Config File > Defaults."
  echo ""
  echo "  ENVIRONMENT VARIABLES:"
  echo "    IMMICH_TARGET_DIR:    Target directory."
  echo "    IMMICH_URL:           Immich server URL."
  echo "    IMMICH_API_KEY:       Immich API key."
  echo "    IMMICH_UPLOAD_DELAY:  Delay in seconds between each upload. Defaults to 0.5."
  echo ""
  echo "  CONFIG FILE:"
  echo "    The script searches for 'immich-uploader.conf' in the following locations:"
  echo "    - ./immich-uploader.conf"
  echo "    - ~/.immich-uploader.conf"
  echo "    - ~/.config/immich-uploader.conf"
  echo ""
  echo "    Example 'immich-uploader.conf':"
  echo '    IMMICH_URL="http://your-immich.local:2283"'
  echo '    IMMICH_API_KEY="your-api-key-here"'
  echo '    IMMICH_TARGET_DIR="/path/to/photos"'
  echo '    IMMICH_UPLOAD_DELAY="0.5"'
}

function check_deps() {
  if ! command -v curl &> /dev/null; then
    echo "Error: curl is not installed. Please install it to continue." >&2
    exit 1
  fi
  if ! command -v exiftool &> /dev/null; then
    echo "Error: exiftool is not installed. Please install it to continue." >&2
    exit 1
  fi
}

# These variables will hold values from the config file.
_CFG_IMMICH_URL=""
_CFG_API_KEY=""
_CFG_TARGET_DIR=""
_CFG_UPLOAD_DELAY=""

function load_config() {
  CONFIG_FILES=(
    "./immich-uploader.conf"
    "$HOME/.immich-uploader.conf"
    "$HOME/.config/immich-uploader.conf"
  )

  for config_file in "${CONFIG_FILES[@]}"; do
    if [ -f "$config_file" ]; then
      echo "Info: Loading config from '$config_file'"
      # Read file line by line and assign values to our config variables
      while IFS='=' read -r key value; do
          # remove whitespace from key
          key=$(echo "$key" | tr -d '[:space:]')
          # remove quotes and surrounding whitespace from value
          value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
          case "$key" in
              IMMICH_URL) _CFG_IMMICH_URL="$value" ;; 
              IMMICH_API_KEY) _CFG_API_KEY="$value" ;; 
              IMMICH_TARGET_DIR) _CFG_TARGET_DIR="$value" ;; 
              IMMICH_UPLOAD_DELAY) _CFG_UPLOAD_DELAY="$value" ;; 
          esac
      done < <(grep -E '^(IMMICH_URL|IMMICH_API_KEY|IMMICH_TARGET_DIR|IMMICH_UPLOAD_DELAY)' "$config_file")
      return # Load only the first config file found
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
FINAL_TARGET_DIR="${1:-${IMMICH_TARGET_DIR:-${_CFG_TARGET_DIR}}}"
FINAL_IMMICH_URL="${2:-${IMMICH_URL:-${_CFG_IMMICH_URL:-${IMMICH_URL_DEFAULT}}}}"
FINAL_API_KEY="${3:-${IMMICH_API_KEY:-${_CFG_API_KEY}}}"
FINAL_UPLOAD_DELAY="${IMMICH_UPLOAD_DELAY:-${_CFG_UPLOAD_DELAY:-${IMMICH_UPLOAD_DELAY_DEFAULT}}}"

# --- Configuration Validation ---
if [ -z "$FINAL_TARGET_DIR" ]; then
  echo "Error: Target directory not specified." >&2
  echo "Please provide it as an argument, in a config file, or via the IMMICH_TARGET_DIR environment variable." >&2
  echo ""
  print_usage
  exit 1
fi

if [ -z "$FINAL_IMMICH_URL" ]; then
    echo "Error: Immich URL not specified." >&2
    echo "Please provide it as an argument, in a config file, or via the IMMICH_URL environment variable." >&2
    echo ""
    print_usage
    exit 1
fi

if [ -z "$FINAL_API_KEY" ]; then
  echo "Error: API key not specified." >&2
  echo "Please provide it as an argument, in a config file, or via the IMMICH_API_KEY environment variable." >&2
  echo ""
  print_usage
  exit 1
fi

if [ ! -d "$FINAL_TARGET_DIR" ]; then
  echo "Error: Directory '$FINAL_TARGET_DIR' not found." >&2
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

# --- Upload Logic ---
REPORT_FILE="immich_video_upload_report_$(date +%Y-%m-%d_%H%M%S).log"
SUCCESS_COUNT=0
FAIL_COUNT=0

echo "Starting upload..."
echo "  Target Directory: $FINAL_TARGET_DIR"
echo "  Immich URL:       $FINAL_IMMICH_URL"
echo "  Upload Delay:     ${FINAL_UPLOAD_DELAY}s"
echo "A detailed log will be saved to: $REPORT_FILE"
echo ""

# Initialize report file
echo "Immich Upload Report" > "$REPORT_FILE"
echo "===================" >> "$REPORT_FILE"
echo "Date: $(date)" >> "$REPORT_FILE"
echo "Target Directory: $FINAL_TARGET_DIR" >> "$REPORT_FILE"
echo "Immich URL: $FINAL_IMMICH_URL" >> "$REPORT_FILE"
echo "===================" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Find and upload files
find "$FINAL_TARGET_DIR" -type f \( -iname "*.mp4" -o -iname "*.mov" -o -iname "*.avi" -o -iname "*.mkv" -o -iname "*.webm" -o -iname "*.mpg" -o -iname "*.mpeg" \) -print0 | while IFS= read -r -d $'\0' file;
do
  echo "Processing: $file"

  # Get the creation date from EXIF data. Fallback to file modification time.
  createdAt=$(exiftool -s -s -s -DateTimeOriginal -d "%Y-%m-%dT%H:%M:%S.000Z" "$file")
  if [ -z "$createdAt" ] || [ "$createdAt" = "0000:00:00 00:00:00" ]; then
      createdAt=$(exiftool -s -s -s -FileModifyDate -d "%Y-%m-%dT%H:%M:%S.000Z" "$file")
      echo "  -> Warning: No DateTimeOriginal EXIF tag found. Using file modification date: $createdAt"
  else
      echo "  -> Found creation date: $createdAt"
  fi

  if [ -z "$createdAt" ]; then
    error_message="Could not determine creation date for file. Skipping."
    echo "  -> Error: $error_message" >&2
    echo "[ERROR] File: $file - $error_message" >> "$REPORT_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  # Get the file modification date for the modifiedAt field.
  modifiedAt=$(exiftool -s -s -s -FileModifyDate -d "%Y-%m-%dT%H:%M:%S.000Z" "$file")

  # Create a unique ID for the asset to prevent re-uploads of the same file.
  # Using a combination of filename and a nanosecond timestamp.
  deviceAssetId="cli-upload-$(basename "$file")-$(date +%s%N)"

  # Perform the upload
  response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" \
    -X POST "${FINAL_IMMICH_URL}/api/assets" \
    -H "x-api-key: ${FINAL_API_KEY}" \
    -F "deviceAssetId=${deviceAssetId}" \
    -F "deviceId=cli-uploader" \
    -F "assetData=@${file}" \
    -F "fileCreatedAt=${createdAt}" \
    -F "fileModifiedAt=${modifiedAt}")

  # Process response
  http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  body=$(echo "$response" | sed -e 's/HTTPSTATUS:.*//g')

  if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
    id=$(echo "$body" | sed -n 's/.*"id":"\([^'\"]*\)".*/\1/p')
    echo "  -> Success: Uploaded successfully."
    echo "  -> Immich ID: $id"
    echo "[SUCCESS] File: $file - Immich ID: $id" >> "$REPORT_FILE"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    error_message="Upload failed with status ${http_status}. Server response: $body"
    echo "  -> Error: $error_message" >&2
    echo "[FAIL] File: $file - $error_message" >> "$REPORT_FILE"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo "" # Newline for readability

  # Pause between uploads to avoid overwhelming the server
  sleep "$FINAL_UPLOAD_DELAY"
done

echo "======== Upload Summary ========"
echo "Successfully uploaded: $SUCCESS_COUNT files"
echo "Failed to upload:      $FAIL_COUNT files"
echo "==============================="
echo "Detailed log saved to: $REPORT_FILE"

echo -e "\n\n======== Summary ========" >> "$REPORT_FILE"
echo "Successfully uploaded: $SUCCESS_COUNT files" >> "$REPORT_FILE"
echo "Failed to upload:      $FAIL_COUNT files" >> "$REPORT_FILE"
echo "=========================" >> "$REPORT_FILE"

echo "Upload script finished."
