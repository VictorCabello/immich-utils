#!/usr/bin/env python3
import sys
import re
import argparse
import subprocess
import shutil
from pathlib import Path
from collections import defaultdict
from datetime import datetime

DVD_CAPACITY_BYTES = 4_700_000_000

IMAGE_EXTS = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif', '.heic', '.webp'}
VIDEO_EXTS = {'.mp4', '.mov', '.avi', '.mkv', '.m4v', '.3gp', '.wmv', '.flv'}

GREEN = '\033[92m'
YELLOW = '\033[93m'
RED = '\033[91m'
RESET = '\033[0m'


def color(text, code):
    return f"{code}{text}{RESET}" if sys.stdout.isatty() else text


def ok(text):   return color(text, GREEN)
def warn(text): return color(text, YELLOW)
def err(text):  return color(text, RED)


def fmt_bytes(size):
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} PB"


def extract_date_from_filename(name):
    m = re.match(r'^(\d{4})(\d{2})(\d{2})[_\s]', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            pass
    m = re.match(r'^(\d{4})-(\d{2})-(\d{2})[\s_]', name)
    if m:
        try:
            return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        except ValueError:
            pass
    return None


def get_exif_dates(paths):
    if not shutil.which('exiftool'):
        return None
    cmd = ['exiftool', '-T', '-FileName', '-DateTimeOriginal'] + [str(p) for p in paths]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        dates = {}
        for line in result.stdout.strip().split('\n'):
            if '\t' in line:
                fname, date_str = line.split('\t', 1)
                date_str = date_str.strip()
                if date_str and date_str != '-':
                    dates[fname.strip()] = date_str
        return dates
    except Exception:
        return None


def verify_dvd(path, exif_sample=20, verbose=False, capacity=DVD_CAPACITY_BYTES):
    path = Path(path)
    issues = []

    if not path.exists():
        print(err(f"ERROR: path does not exist: {path}"))
        return False
    if not path.is_dir():
        print(err(f"ERROR: not a directory: {path}"))
        return False

    print(f"\nVerifying: {path}")
    print("=" * 60)

    # 1. Collect files
    all_files = [f for f in path.iterdir() if f.is_file()]
    by_type = defaultdict(list)
    total_size = 0

    for f in all_files:
        ext = f.suffix.lower()
        total_size += f.stat().st_size
        if ext in IMAGE_EXTS:
            by_type['image'].append(f)
        elif ext in VIDEO_EXTS:
            by_type['video'].append(f)
        else:
            by_type['other'].append(f)

    print(f"\nFiles")
    print(f"  Total : {len(all_files)}")
    print(f"  Images: {len(by_type['image'])}")
    print(f"  Videos: {len(by_type['video'])}")
    if by_type['other']:
        ext_counts = defaultdict(int)
        for f in by_type['other']:
            ext_counts[f.suffix.lower() or '(none)'] += 1
        summary = ', '.join(f"{k}:{v}" for k, v in sorted(ext_counts.items()))
        print(f"  Other : {len(by_type['other'])} ({summary})")

    # 2. Size
    pct = total_size / capacity * 100
    size_line = f"\nSize: {fmt_bytes(total_size)} ({pct:.1f}% of DVD capacity)"
    if total_size > capacity:
        print(warn(size_line))
        issues.append(f"exceeds DVD capacity ({pct:.1f}%)")
    else:
        print(ok(size_line))

    # 3. Date range from filenames
    dated: list[tuple[datetime, Path]] = sorted(
        [(d, f) for f in all_files
         if (d := extract_date_from_filename(f.name)) is not None],
        key=lambda x: x[0]
    )
    undated_count = len(all_files) - len(dated)

    print("\nDate range (from filenames)")
    if dated:
        print(f"  From : {dated[0][0].strftime('%Y-%m-%d')}  ({dated[0][1].name})")
        print(f"  To   : {dated[-1][0].strftime('%Y-%m-%d')}  ({dated[-1][1].name})")
        print(f"  With date in name    : {len(dated)}")
        print(f"  Without date in name : {undated_count}")
        if verbose and undated_count:
            for f in all_files:
                if extract_date_from_filename(f.name) is None:
                    print(f"    {f.name}")
    else:
        print(warn("  No files with recognizable date patterns in names"))

    # 4. Empty files
    empty = [f for f in all_files if f.stat().st_size == 0]
    empty_line = f"\nEmpty files: {len(empty)}"
    if empty:
        print(err(empty_line))
        issues.append(f"{len(empty)} empty file(s)")
        if verbose:
            for f in empty:
                print(f"  {f.name}")
    else:
        print(ok(empty_line))

    # 5. EXIF validation
    media = by_type['image'] + by_type['video']
    if media and exif_sample > 0:
        if not shutil.which('exiftool'):
            print(warn("\nEXIF validation: SKIPPED (exiftool not found)"))
            print("  Install: sudo pacman -S perl-image-exiftool")
        else:
            n = min(exif_sample, len(media))
            step = max(1, len(media) // n)
            sample = [media[i] for i in range(0, len(media), step)][:n]

            print(f"\nEXIF validation (sample: {len(sample)} files)")
            exif_dates = get_exif_dates(sample)

            if exif_dates is None:
                print(warn("  SKIPPED (exiftool error)"))
            else:
                with_exif = len(exif_dates)
                without_exif = len(sample) - with_exif
                print(f"  With EXIF date    : {with_exif}/{len(sample)}")
                print(f"  Without EXIF date : {without_exif}/{len(sample)}")

                mismatches = []
                for f in sample:
                    if f.name not in exif_dates:
                        continue
                    try:
                        exif_dt = datetime.strptime(exif_dates[f.name][:10], '%Y:%m:%d')
                    except ValueError:
                        continue
                    fname_dt = extract_date_from_filename(f.name)
                    if fname_dt and abs((exif_dt - fname_dt).days) > 1:
                        mismatches.append((f.name, fname_dt.date(), exif_dt.date()))

                if not mismatches:
                    print(ok("  Date consistency  : OK"))
                else:
                    print(warn(f"  Date consistency  : {len(mismatches)} mismatch(es)"))
                    issues.append(f"{len(mismatches)} EXIF date mismatch(es)")
                    if verbose:
                        for name, fn_date, ex_date in mismatches:
                            print(f"    {name}: filename={fn_date}  exif={ex_date}")
    elif exif_sample == 0:
        print("\nEXIF validation: SKIPPED (--exif-sample 0)")

    # Summary
    print("\n" + "=" * 60)
    if not issues:
        print(ok("RESULT: OK — no issues found"))
    else:
        print(warn(f"RESULT: {len(issues)} issue(s) found"))
        for i in issues:
            print(f"  - {i}")

    return len(issues) == 0


def main():
    parser = argparse.ArgumentParser(
        description="Verify the content of a DVD backup created by immich_dvd_backup_local.py.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  %(prog)s /run/media/user/DVD_1
  %(prog)s ./immich_backups/DVD_3 --verbose
  %(prog)s /mnt/dvd --exif-sample 50
  %(prog)s /mnt/dvd --exif-sample 0        # skip EXIF check
        """,
    )
    parser.add_argument("path", help="Path to the DVD mount point or backup directory")
    parser.add_argument(
        "--exif-sample", type=int, default=20, metavar="N",
        help="Files to sample for EXIF validation (default: 20, 0 to skip)"
    )
    parser.add_argument(
        "--verbose", "-v", action="store_true",
        help="Show per-file details for issues found"
    )
    parser.add_argument(
        "--capacity", type=int, default=DVD_CAPACITY_BYTES,
        help=f"DVD capacity in bytes (default: {DVD_CAPACITY_BYTES})"
    )

    args = parser.parse_args()
    ok_result = verify_dvd(args.path, exif_sample=args.exif_sample,
                           verbose=args.verbose, capacity=args.capacity)
    sys.exit(0 if ok_result else 1)


if __name__ == "__main__":
    main()
