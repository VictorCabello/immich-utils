# Immich Utils

This repository stores a collection of scripts to help manage a personal [Immich](https://github.com/immich-app/immich) instance.

## Scripts

### `immich_upload_photos.sh`

A shell script that recursively finds and uploads photos and videos from a specified directory to your Immich server.

#### Features

*   **Recursive Upload:** Scans a directory and its subdirectories for media to upload.
*   **Configuration:** Flexible configuration via a config file, environment variables, or command-line arguments.
*   **Dependency Check:** Verifies that required tools (`curl`, `exiftool`) are installed.
*   **Logging:** Creates a detailed report of successful and failed uploads.
*   **EXIF Data:** Reads creation date from EXIF data to correctly place photos in the Immich timeline.

#### Dependencies

*   `curl`: To make HTTP requests to the Immich API.
*   `exiftool`: To read metadata from media files.

#### Configuration

The script can be configured in three ways, with the following order of precedence:

1.  **Command-line arguments**
2.  **Environment variables**
3.  **Configuration file**

A configuration file named `immich-uploader.conf` can be placed in one of the following locations:

*   `./immich-uploader.conf` (in the same directory as the script)
*   `~/.immich-uploader.conf`
*   `~/.config/immich-uploader.conf`

You can use the provided `immich-uploader.conf.example` as a template.

| Variable              | Description                                                                 |
| --------------------- | --------------------------------------------------------------------------- |
| `IMMICH_URL`          | Your Immich server URL (e.g., `http://localhost:2283`).                      |
| `IMMICH_API_KEY`      | Your Immich API key.                                                        |
| `IMMICH_TARGET_DIR`   | The directory to upload photos from.                                        |
| `IMMICH_UPLOAD_DELAY` | The delay in seconds between each upload (defaults to `0.5`).                 |

#### Usage

To run the script, you can provide the target directory, Immich URL, and API key as arguments:

```bash
./immich_upload_photos.sh /path/to/your/photos http://your-immich-instance:2283 YOUR_API_KEY
```

Alternatively, you can configure the script using environment variables or a configuration file and simply run:

```bash
./immich_upload_photos.sh
```
