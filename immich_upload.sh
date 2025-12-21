#!/bin/bash

# A script to recursively upload photos from a directory to an Immich server.

# --- Configuration ---
# Default Immich server URL.
# Can be overridden by config file, environment variables, or command-line arguments.
IMMICH_URL_DEFAULT="http://localhost:2283"

# --- Script ---

set -e
set -o pipefail

# --- Helper Functions ---
function print_usage() {
  echo "Usage: $0 [directory] [immich_url] [api_key]"
  echo ""
  echo "This script recursively finds and uploads images from a directory to Immich."
  echo ""
  echo "ARGUMENTS:"
  echo "  [directory]:   The directory to upload photos from. Overrides config and env var."
  echo "  [immich_url]:  Your Immich server URL. Overrides config and env var."
  echo "  [api_key]:     Your Immich API key. Overrides config and env var."
  echo ""
  echo "CONFIGURATION:"
  echo "  Settings can be provided via a config file, environment variables, or arguments."
  echo "  Priority: Command-line Arguments > Environment Variables > Config File > Defaults."
  echo ""
  echo "  ENVIRONMENT VARIABLES:"
  echo "    IMMICH_TARGET_DIR:  Target directory."
  echo "    IMMICH_URL:         Immich server URL."
  echo "    IMMICH_API_KEY:     Immich API key."
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
          esac
      done < <(grep -E '^(IMMICH_URL|IMMICH_API_KEY|IMMICH_TARGET_DIR)' "$config_file")
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
echo "Starting upload..."
echo "  Target Directory: $FINAL_TARGET_DIR"
echo "  Immich URL:       $FINAL_IMMICH_URL"
echo ""

# Find and upload files
find "$FINAL_TARGET_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.webp" \) -print0 | while IFS= read -r -d $'\0' file;
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
    echo "  -> Error: Could not determine creation date for file. Skipping." >&2
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
    echo "  -> Success: Uploaded successfully."
    id=$(echo "$body" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    echo "  -> Immich ID: $id"
  else
    echo "  -> Error: Upload failed with status ${http_status}." >&2
    echo "  -> Server response: $body" >&2
  fi
  echo "" # Newline for readability
done

echo "Upload script finished."
