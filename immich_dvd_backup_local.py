#!/usr/bin/env python3
import os
import json
import subprocess
import shutil
import sys
import argparse
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import List, Dict, Any, Tuple
from datetime import datetime

# --- Defaults ---
DVD_CAPACITY_BYTES = 4700000000
DEFAULT_BACKUP_DIR = "./immich_backups"
DEFAULT_STATE_FILE = "./immich_backup_state.json"
CONTAINER_UPLOAD_PATH = "/usr/src/app/upload"
HOST_UPLOAD_PATH = "/mnt/backup/immich-app/library"

class BackupState:
    def __init__(self, state_file: str):
        self.state_file = state_file
        self.lock = threading.Lock()
        self.last_asset_id = None
        self.current_dvd = 1
        self.current_dvd_size = 0
        self.load()

    def load(self):
        if os.path.exists(self.state_file):
            try:
                with open(self.state_file, 'r') as f:
                    state = json.load(f)
                    self.last_asset_id = state.get("last_asset_id")
                    self.current_dvd = state.get("current_dvd", 1)
                    self.current_dvd_size = state.get("current_dvd_size", 0)
            except Exception as e:
                print(f"Warning: Could not load state file: {e}. Starting fresh.")

    def save(self):
        with self.lock:
            with open(self.state_file, 'w') as f:
                json.dump({
                    "last_asset_id": self.last_asset_id,
                    "current_dvd": self.current_dvd,
                    "current_dvd_size": self.current_dvd_size
                }, f)

    def update(self, asset_id: str, size: int, dvd: int, dvd_size: int):
        with self.lock:
            self.last_asset_id = asset_id
            self.current_dvd = dvd
            self.current_dvd_size = dvd_size

def run_command(cmd: List[str]) -> str:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error running command: {' '.join(cmd)}")
        print(f"Stderr: {e.stderr}")
        raise

def get_assets_from_db() -> List[Dict[str, Any]]:
    print("Fetching asset list from database...")
    query = """
    SELECT 
        a.id, 
        a."originalPath", 
        a."originalFileName", 
        a."fileCreatedAt",
        e."fileSizeInByte" 
    FROM asset a 
    JOIN asset_exif e ON a.id = e."assetId" 
    ORDER BY a."fileCreatedAt" ASC
    """
    query_json = f"SELECT json_agg(t) FROM ({query}) t;"
    cmd = [
        "docker", "exec", "immich_postgres", 
        "psql", "-U", "postgres", "-d", "immich", "-t", "-A",
        "-c", query_json
    ]
    output = run_command(cmd)
    if not output.strip():
        return []
    return json.loads(output)

def format_bytes(size: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if size < 1024:
            return f"{size:.2f} {unit}"
        size /= 1024
    return f"{size:.2f} PB"

def copy_asset(asset: Dict[str, Any], dvd_dir: str, dry_run: bool, use_links: bool) -> bool:
    asset_id = asset['id']
    container_path = asset['originalPath']
    original_filename = asset['originalFileName']
    
    if container_path.startswith(CONTAINER_UPLOAD_PATH):
        host_path = container_path.replace(CONTAINER_UPLOAD_PATH, HOST_UPLOAD_PATH, 1)
    else:
        return False
        
    if not os.path.exists(host_path):
        return False
        
    ext = os.path.splitext(host_path)[1]
    target_filename = f"{original_filename}{ext}" if not original_filename.lower().endswith(ext.lower()) else original_filename
    target_path = os.path.join(dvd_dir, target_filename)
    
    if os.path.exists(target_path):
        target_path = os.path.join(dvd_dir, f"{os.path.splitext(target_filename)[0]}_{asset_id}{ext}")
        
    if dry_run:
        return True

    try:
        if use_links:
            try:
                os.link(host_path, target_path)
            except OSError:
                shutil.copy2(host_path, target_path)
        else:
            shutil.copy2(host_path, target_path)
        return True
    except Exception as e:
        print(f"Error copying {host_path} to {target_path}: {e}")
        return False

def create_iso(source_dir: str, iso_path: str):
    print(f"Generating ISO image: {iso_path}...")
    # Try xorriso first, then genisoimage, then mkisofs
    tools = [
        ["xorriso", "-as", "mkisofs", "-o", iso_path, "-J", "-R", "-V", os.path.basename(source_dir), source_dir],
        ["genisoimage", "-o", iso_path, "-J", "-R", "-V", os.path.basename(source_dir), source_dir],
        ["mkisofs", "-o", iso_path, "-J", "-R", "-V", os.path.basename(source_dir), source_dir]
    ]
    
    for cmd in tools:
        if shutil.which(cmd[0]):
            try:
                run_command(cmd)
                print(f"ISO created successfully: {iso_path}")
                return True
            except Exception as e:
                print(f"Error creating ISO with {cmd[0]}: {e}")
    
    print("Error: No ISO creation tool found (xorriso, genisoimage, or mkisofs).")
    print("Please install one of them (e.g., 'sudo pacman -S libisoburn' for xorriso).")
    return False

def main():
    parser = argparse.ArgumentParser(description="Backup Immich gallery to DVD ISO images.")
    parser.add_argument("--backup-dir", default=DEFAULT_BACKUP_DIR, help=f"Directory to save backups (default: {DEFAULT_BACKUP_DIR})")
    parser.add_argument("--state-file", default=DEFAULT_STATE_FILE, help=f"Path to progress state file (default: {DEFAULT_STATE_FILE})")
    parser.add_argument("--capacity", type=int, default=DVD_CAPACITY_BYTES, help=f"DVD capacity in bytes (default: {DVD_CAPACITY_BYTES})")
    parser.add_argument("--dry-run", action="store_true", help="Do not copy files or create ISOs")
    parser.add_argument("--use-links", action="store_true", help="Use hardlinks instead of copying when possible")
    parser.add_argument("--threads", type=int, default=4, help="Number of parallel copy threads (default: 4)")
    
    args = parser.parse_args()
    
    os.makedirs(args.backup_dir, exist_ok=True)
    state = BackupState(args.state_file)
    
    assets = get_assets_from_db()
    if not assets:
        print("No assets found in database.")
        return

    # Organize assets into DVDs
    all_dvds = []
    current_dvd_assets = []
    dvd_size = 0
    dvd_num = 1
    
    print("Organizing assets into DVD chunks by date...")
    for asset in assets:
        size = asset['fileSizeInByte'] or 0
        if dvd_size + size > args.capacity and current_dvd_assets:
            # Calculate date range
            start_date = current_dvd_assets[0]['fileCreatedAt'].split('T')[0]
            end_date = current_dvd_assets[-1]['fileCreatedAt'].split('T')[0]
            all_dvds.append({
                'num': dvd_num,
                'assets': current_dvd_assets,
                'size': dvd_size,
                'start': start_date,
                'end': end_date
            })
            dvd_num += 1
            dvd_size = 0
            current_dvd_assets = []
            
        current_dvd_assets.append(asset)
        dvd_size += size
        
    if current_dvd_assets:
        start_date = current_dvd_assets[0]['fileCreatedAt'].split('T')[0]
        end_date = current_dvd_assets[-1]['fileCreatedAt'].split('T')[0]
        all_dvds.append({
            'num': dvd_num,
            'assets': current_dvd_assets,
            'size': dvd_size,
            'start': start_date,
            'end': end_date
        })

    # Display menu
    print("\nAvailable DVDs for backup:")
    print(f"{'DVD #':<6} | {'Date Range':<25} | {'Size':<10} | {'Assets':<6}")
    print("-" * 55)
    for dvd in all_dvds:
        print(f"{dvd['num']:<6} | {dvd['start']} to {dvd['end']:<10} | {format_bytes(dvd['size']):<10} | {len(dvd['assets']):<6}")
    
    print("\nOptions:")
    print("  [number]  - Backup a specific DVD")
    print("  all       - Backup all DVDs")
    print("  q         - Quit")
    
    choice = input("\nSelect an option: ").strip().lower()
    
    to_process = []
    if choice == 'q':
        return
    elif choice == 'all':
        to_process = all_dvds
    else:
        try:
            dvd_idx = int(choice) - 1
            if 0 <= dvd_idx < len(all_dvds):
                to_process = [all_dvds[dvd_idx]]
            else:
                print("Invalid DVD number.")
                return
        except ValueError:
            print("Invalid input.")
            return

    for dvd in to_process:
        dvd_num = dvd['num']
        dvd_assets = dvd['assets']
        dvd_dir = os.path.join(args.backup_dir, f"DVD_{dvd_num}")
        iso_path = os.path.join(args.backup_dir, f"immich_backup_dvd_{dvd_num}_{dvd['start']}_{dvd['end']}.iso")
        
        if not args.dry_run:
            os.makedirs(dvd_dir, exist_ok=True)
            
        print(f"\nProcessing DVD {dvd_num} ({len(dvd_assets)} assets, {format_bytes(dvd['size'])})...")
        
        with ThreadPoolExecutor(max_workers=args.threads) as executor:
            futures = {executor.submit(copy_asset, asset, dvd_dir, args.dry_run, args.use_links): asset for asset in dvd_assets}
            
            processed = 0
            for future in as_completed(futures):
                success = future.result()
                if success:
                    processed += 1
                    if processed % 100 == 0:
                        print(f"  Progress: {processed}/{len(dvd_assets)} files copied...")
                else:
                    asset = futures[future]
                    print(f"  Failed to copy asset {asset['id']}")

        if not args.dry_run:
            if create_iso(dvd_dir, iso_path):
                print(f"Cleaning up temporary directory {dvd_dir}...")
                shutil.rmtree(dvd_dir)
            
    print("\nProcess completed.")

if __name__ == "__main__":
    main()
