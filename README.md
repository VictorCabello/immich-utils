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

### `immich_upload_videos.sh`

Similar to the photo uploader, but specialized for video formats and includes pause/resume functionality.

### `immich_dvd_calc.sh`

A script to calculate the number of DVDs needed to backup all images and videos from your Immich server.

#### Features

*   **Storage Statistics:** Fetches real-time storage data from the Immich API.
*   **Precise Calculation:** Uses `awk` for floating-point math to provide exact and rounded-up DVD counts.
*   **Human-Readable Output:** Formats byte sizes into KB, MB, GB, or TB for easy reading.

#### Usage

```bash
./immich_dvd_calc.sh
```

---

### `immich_dvd_backup.sh`

A script to perform the actual backup of your Immich gallery into DVD-sized chunks.

#### Features

*   **State Management:** Tracks progress in a JSON state file, allowing you to stop and resume the backup at any time.
*   **Chunked Downloads:** Automatically groups assets into 4.7 GB (DVD-sized) directories.
*   **Oldest First:** Downloads assets in chronological order (oldest first).
*   **Conflict Resolution:** Handles duplicate filenames by appending the asset ID.

#### Configuration

In addition to the standard `IMMICH_URL` and `IMMICH_API_KEY`, this script uses:

| Variable                   | Description                                                                 |
| -------------------------- | --------------------------------------------------------------------------- |
| `IMMICH_BACKUP_DIR`        | Directory where DVD chunks will be saved (defaults to `./immich_backups`). |
| `IMMICH_BACKUP_STATE_FILE` | Path to the progress state file (defaults to `./immich_backup_state.json`). |

#### Usage

```bash
./immich_dvd_backup.sh
```

---

### `immich_dvd_backup_local.py`

An optimized Python script for **local** Immich instances. It bypasses the API for file transfers, making it significantly faster, and includes interactive ISO generation.

#### Features

*   **Interactive Selection:** Pre-calculates all required DVDs and lets you choose which one to back up.
*   **ISO Generation:** Automatically creates a bootable ISO image for each DVD chunk.
*   **Date-Based Organization:** Groups assets chronologically (e.g., "2008 to 2010") for logical archiving.
*   **High Performance:** Uses direct database access and local filesystem operations (hardlinks or parallel copying).
*   **Hardlink Support:** Use `--use-links` to make the "copy" process instantaneous and save disk space.

#### Dependencies

*   `python3`: To run the script.
*   `docker`: To access the Immich database.
*   `xorriso`, `genisoimage`, or `mkisofs`: To generate ISO images.

#### Usage

```bash
# Standard backup with 8 parallel threads
./immich_dvd_backup_local.py --backup-dir ./my_backups --threads 8

# Instantaneous backup using hardlinks (if on the same disk)
./immich_dvd_backup_local.py --backup-dir ./my_backups --use-links
```

---

### `immich_dvd_verify.py`

A Python script to verify the integrity and content of a DVD backup directory created by `immich_dvd_backup_local.py`.

#### Features

*   **File inventory:** Counts and categorizes files by type (images, videos, other).
*   **Size check:** Verifies total size against DVD capacity (4.7 GB by default).
*   **Date range:** Extracts the chronological range covered by the backup from filenames.
*   **Empty file detection:** Flags any zero-byte files.
*   **EXIF validation:** Samples a configurable number of files and checks that their EXIF `DateTimeOriginal` matches the date encoded in the filename.
*   **Exit code:** Returns `0` if no issues are found, `1` otherwise — suitable for use in scripts.

#### Dependencies

*   `python3`: To run the script.
*   `exiftool` *(optional)*: For EXIF date validation. Install with `sudo pacman -S perl-image-exiftool`. If not present, the EXIF check is skipped automatically.

#### Usage

```bash
# Basic verification
./immich_dvd_verify.py /run/media/user/DVD_1

# Show per-file details for any issues found
./immich_dvd_verify.py /run/media/user/DVD_1 --verbose

# Increase EXIF sample size
./immich_dvd_verify.py ./immich_backups/DVD_3 --exif-sample 50

# Skip EXIF check entirely
./immich_dvd_verify.py /mnt/dvd --exif-sample 0
```

| Argument | Default | Description |
| --- | --- | --- |
| `path` | *(required)* | Path to the DVD mount point or backup directory. |
| `--exif-sample N` | `20` | Number of files to sample for EXIF date validation. Set to `0` to skip. |
| `--verbose` / `-v` | off | Print per-file details for mismatches, empty files, and undated filenames. |
| `--capacity BYTES` | `4700000000` | Override the DVD capacity threshold used for the size check. |

#### Example output

```
Verifying: /run/media/user/DVD_1
============================================================

Files
  Total : 2360
  Images: 2261
  Videos: 89
  Other : 10 (.gif:10)

Size: 4.40 GB (95.5% of DVD capacity)

Date range (from filenames)
  From : 2012-11-11  (2012-11-11 13.32.12.jpg)
  To   : 2015-10-28  (20151028_191058.jpg)
  With date in name    : 1953
  Without date in name : 407

Empty files: 0

EXIF validation (sample: 20 files)
  With EXIF date    : 19/20
  Without EXIF date : 1/20
  Date consistency  : OK

============================================================
RESULT: OK — no issues found
```

---

## Dependencies

*   **Core Tools**: `curl`, `jq`, `awk`.
*   **Metadata**: `exiftool`.
*   **Local Backup**: `python3`, `docker`, `libisoburn` (for `xorriso`).
