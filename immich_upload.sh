#!/bin/bash

# A script to recursively upload photos from a directory to an Immich server.

# --- Configuration ---
# Your Immich server URL.
# Can be overridden by the second argument.
IMMICH_URL_DEFAULT="http://localhost:2283"

# --- Script ---

set -e
set -o pipefail

# --- Helper Functions ---
function print_usage() {
  echo "Usage: $0 <directory> <immich_url> <api_key>"
  echo "  <directory>:   The directory containing photos to upload."
  echo "  <immich_url>:  The URL of your Immich server (e.g., ${IMMICH_URL_DEFAULT})."
  echo "  <api_key>:     Your Immich API key."
  echo ""
  echo "This script will recursively find all .jpg and .jpeg files in <directory> and upload them."
  echo "It uses 'exiftool' to read the original creation date of the photo."
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

# --- Main Logic ---

check_deps

# Validate arguments
if [ "$#" -ne 3 ]; then
  print_usage
  exit 1
fi

TARGET_DIR="$1"
IMMICH_URL="$2"
API_KEY="$3"

if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory '$TARGET_DIR' not found." >&2
  exit 1
fi

# Find and upload files
find "$TARGET_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -print0 | while IFS= read -r -d $'\0' file;
do
  echo "Processing: $file"

  # Get the creation date from EXIF data. Fallback to file modification time.
  createdAt=$(exiftool -s -s -s -DateTimeOriginal -d "%Y-%m-%dT%H:%M:%S.%NZ" "$file")
  if [ -z "$createdAt" ] || [ "$createdAt" = "0000:00:00 00:00:00" ]; then
      createdAt=$(exiftool -s -s -s -FileModifyDate -d "%Y-%m-%dT%H:%M:%S.%NZ" "$file")
      echo "  -> Warning: No DateTimeOriginal EXIF tag found. Using file modification date: $createdAt"
  else
      echo "  -> Found creation date: $createdAt"
  fi

  # Get the file modification date for the modifiedAt field.
  modifiedAt=$(exiftool -s -s -s -FileModifyDate -d "%Y-%m-%dT%H:%M:%S.%NZ" "$file")

  # Create a unique ID for the asset to prevent re-uploads of the same file.
  # Using a combination of filename and a nanosecond timestamp.
  deviceAssetId="cli-upload-$(basename "$file")-$(date +%s%N)"

  # Perform the upload
  response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" \
    -X POST "${IMMICH_URL}/api/asset/upload" \
    -H "x-api-key: ${API_KEY}" \
    -F "deviceAssetId=${deviceAssetId}" \
    -F "deviceId=cli-uploader" \
    -F "assetData=@${file}" \
    -F "createdAt=${createdAt}" \
    -F "modifiedAt=${modifiedAt}")

  # Process response
  http_status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  body=$(echo "$response" | sed -e 's/HTTPSTATUS\:.*//g')

  if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
    echo "  -> Success: Uploaded successfully."
    id=$(echo "$body" | sed -n 's/.*"id":"\([^'\"]*\)".*/\1/p')
    echo "  -> Immich ID: $id"
  else
    echo "  -> Error: Upload failed with status ${http_code}." >&2
    echo "  -> Server response: $body" >&2
  fi
  echo "" # Newline for readability
done

echo "Upload script finished."
