#!/usr/bin/env bash
# Off-site backup script for Kubernetes homelab
#
# Two-step workflow: pull backups from NAS to WSL2 staging, then encrypt to OneDrive via restic.
# All NAS access goes through SSH to cp1 (WSL2 cannot NFS mount).
#
# Subcommands: setup, pull, encrypt, status, prune, restore
#
# Prerequisites:
#   - restic installed (sudo apt install restic)
#   - SSH access to cp1 (wawashi@10.10.30.11) with sudo for mount/umount
#   - Copy config.example to config and edit for your machine
#
# Usage: ./scripts/backup/homelab-backup.sh <subcommand>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config"
PASSWORD_FILE="$SCRIPT_DIR/.password"
TODAY="$(TZ='Asia/Manila' date +%Y-%m-%d)"
NOW="$(TZ='Asia/Manila' date '+%Y-%m-%d %H:%M %Z')"
NOW_ISO="$(TZ='Asia/Manila' date -Iseconds)"

# --- Helpers ---

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
info() { echo "[*] $*"; }
err()  { echo "[-] $*" >&2; }

die() {
    err "$@"
    exit 1
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Config file not found: $CONFIG_FILE"
        echo "    Copy from config.example and edit for your machine:"
        echo "    cp $SCRIPT_DIR/config.example $SCRIPT_DIR/config"
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

check_password() {
    if [[ ! -f "$PASSWORD_FILE" ]]; then
        die "Password file not found. Run: $0 setup"
    fi
}

check_restic() {
    if ! command -v restic &>/dev/null; then
        die "restic not found. Install with: sudo apt install restic"
    fi
}

check_staging() {
    if [[ ! -d "$STAGING_DIR" ]]; then
        die "Staging directory not found: $STAGING_DIR"
    fi
    local count
    count=$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [[ "$count" -eq 0 ]]; then
        die "No backup data found in $STAGING_DIR. Run: $0 pull"
    fi
}

check_repo() {
    if [[ ! -d "$RESTIC_REPO" ]]; then
        die "Restic repo not found: $RESTIC_REPO (is OneDrive running?)"
    fi
}

ssh_mount_nfs() {
    info "Mounting NFS on cp1..."
    ssh -o StrictHostKeyChecking=accept-new "$SSH_HOST" \
        "sudo mkdir -p $NFS_MOUNT && sudo mount -t nfs4 $NFS_SERVER:$NFS_EXPORT $NFS_MOUNT" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        # Check if already mounted
        if ssh "$SSH_HOST" "mountpoint -q $NFS_MOUNT" 2>/dev/null; then
            warn "NFS already mounted on cp1 (reusing)"
            return 0
        fi
        die "NFS mount failed on cp1. Check NAS is online."
    fi
    return 0
}

ssh_umount_nfs() {
    info "Unmounting NFS on cp1..."
    ssh "$SSH_HOST" "sudo umount $NFS_MOUNT" 2>&1
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "NFS unmount failed on cp1 (stale mount will clean up on reboot)"
    fi
}

human_size() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        echo "$(( bytes / 1073741824 ))GB"
    elif [[ $bytes -ge 1048576 ]]; then
        echo "$(( bytes / 1048576 ))MB"
    elif [[ $bytes -ge 1024 ]]; then
        echo "$(( bytes / 1024 ))KB"
    else
        echo "${bytes}B"
    fi
}

# --- Subcommands ---

cmd_setup() {
    log "Setting up off-site backup"
    load_config
    check_restic

    # Step 1: Get password
    if [[ -f "$PASSWORD_FILE" ]]; then
        info "Password file already exists: $PASSWORD_FILE"
    else
        info "Fetching restic password..."
        local password=""

        # Try Vault first
        if command -v vault &>/dev/null; then
            info "Trying Vault at $VAULT_ADDR..."
            password=$(VAULT_ADDR="$VAULT_ADDR" vault kv get -field="$VAULT_SECRET_KEY" "$VAULT_SECRET_PATH" 2>/dev/null) || true
        fi

        if [[ -z "$password" ]]; then
            warn "Vault unavailable. Paste password from 1Password:"
            echo "    op://Kubernetes/Restic Backup Keys/k8s-configs-password"
            echo ""
            read -rsp "Password: " password
            echo ""
        fi

        if [[ -z "$password" ]]; then
            die "No password provided"
        fi

        echo -n "$password" > "$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        log "Password saved to $PASSWORD_FILE"
    fi

    # Step 2: Initialize restic repo if needed
    if restic -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE" cat config &>/dev/null; then
        info "Restic repo already initialized at: $RESTIC_REPO"
    else
        info "Initializing restic repo at: $RESTIC_REPO"
        restic init -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE"
        if [[ $? -ne 0 ]]; then
            die "Failed to initialize restic repo"
        fi
        log "Restic repo initialized"
    fi

    echo ""
    log "Setup complete"
    echo "    Config:   $CONFIG_FILE"
    echo "    Password: $PASSWORD_FILE"
    echo "    Repo:     $RESTIC_REPO"
    echo "    Staging:  $STAGING_DIR"
    echo ""
    echo "    Next: $0 pull"
}

cmd_pull() {
    log "Pulling backups from NAS to WSL2 staging"
    load_config

    # Check SSH connectivity
    info "Testing SSH to cp1..."
    if ! ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "$SSH_HOST" "echo ok" &>/dev/null; then
        die "Cannot reach cp1 ($SSH_HOST). Check VPN/network."
    fi

    # Mount NFS on cp1
    ssh_mount_nfs

    # Create today's staging directory
    local staging_today="$STAGING_DIR/$TODAY"
    if [[ -d "$staging_today" ]]; then
        warn "Updating existing pull for $TODAY"
    else
        mkdir -p "$staging_today"
    fi

    # Rsync each source
    local pulled=0
    local skipped=0
    local failed=0

    for source in $BACKUP_SOURCES; do
        info "Pulling $source..."
        # Check if source exists on NAS
        if ! ssh "$SSH_HOST" "test -d $NFS_MOUNT/$source" 2>/dev/null; then
            warn "  $source: directory not found on NAS (skipping)"
            skipped=$((skipped + 1))
            continue
        fi

        # Check if source has files
        local file_count
        file_count=$(ssh "$SSH_HOST" "find $NFS_MOUNT/$source -type f 2>/dev/null | wc -l")
        if [[ "$file_count" -eq 0 ]]; then
            warn "  $source: no files found (skipping)"
            skipped=$((skipped + 1))
            continue
        fi

        mkdir -p "$staging_today/$source"
        rsync -avz --delete --exclude='lost+found' --no-specials --no-devices \
            --rsync-path="sudo rsync" \
            -e "ssh -o StrictHostKeyChecking=accept-new" \
            "$SSH_HOST:$NFS_MOUNT/$source/" "$staging_today/$source/" 2>&1
        if [[ $? -ne 0 ]]; then
            warn "  $source: rsync had errors (partial data may exist)"
            failed=$((failed + 1))
        else
            log "  $source: $file_count files pulled"
            pulled=$((pulled + 1))
        fi
    done

    # Build manifest on WSL2 side using temp files (file list too large for args)
    info "Writing off-site manifest to NAS..."
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    # Build pulled_files JSON via temp file
    find "$staging_today" -type f -printf '%P\n' 2>/dev/null \
        | jq -R --arg d "$TODAY" '{(.): $d}' \
        | jq -s 'add // {}' > "$tmpdir/pulled_files.json"

    # Fetch existing manifest from NAS (preserve encrypt fields across pulls)
    local existing_file="$tmpdir/existing.json"
    ssh "$SSH_HOST" "cat $NFS_MOUNT/.offsite-manifest.json 2>/dev/null" > "$existing_file" || true

    # Build manifest, merging encrypt fields from existing if present
    jq -n \
        --arg pull "$NOW_ISO" \
        --slurpfile files "$tmpdir/pulled_files.json" \
        '{
            last_pull: $pull,
            last_encrypt: null,
            restic_snapshot: null,
            pulled_files: $files[0]
        }' > "$tmpdir/manifest.json"

    if [[ -s "$existing_file" ]]; then
        local old_encrypt old_snapshot
        old_encrypt=$(jq -r '.last_encrypt // empty' "$existing_file") || true
        old_snapshot=$(jq -r '.restic_snapshot // empty' "$existing_file") || true
        if [[ -n "$old_encrypt" ]]; then
            jq --arg enc "$old_encrypt" --arg snap "$old_snapshot" \
                '.last_encrypt = $enc | .restic_snapshot = $snap' \
                "$tmpdir/manifest.json" > "$tmpdir/manifest2.json"
            mv "$tmpdir/manifest2.json" "$tmpdir/manifest.json"
        fi
    fi

    # Write manifest to NAS via SSH
    cat "$tmpdir/manifest.json" | ssh "$SSH_HOST" "sudo tee $NFS_MOUNT/.offsite-manifest.json > /dev/null"
    if [[ $? -ne 0 ]]; then
        warn "Failed to write manifest to NAS (non-fatal)"
    else
        log "Manifest written to NAS"
    fi

    # Unmount
    ssh_umount_nfs

    # Summary
    local total_size
    total_size=$(du -sb "$staging_today" 2>/dev/null | awk '{print $1}')
    local total_files
    total_files=$(find "$staging_today" -type f 2>/dev/null | wc -l)

    echo ""
    log "Pull complete ($NOW)"
    echo "    Staging:  $staging_today"
    echo "    Sources:  $pulled pulled, $skipped skipped, $failed failed"
    echo "    Files:    $total_files"
    echo "    Size:     $(human_size "${total_size:-0}")"
    echo ""
    echo "    Next: $0 encrypt"
}

cmd_encrypt() {
    log "Encrypting staging backups to restic repo"
    load_config
    check_restic
    check_password
    check_staging
    check_repo

    info "Backing up $STAGING_DIR to restic repo..."
    restic backup "$STAGING_DIR" \
        -r "$RESTIC_REPO" \
        --password-file "$PASSWORD_FILE" \
        --tag "homelab-backup" \
        --tag "$TODAY"
    if [[ $? -ne 0 ]]; then
        die "Restic backup failed"
    fi
    log "Backup complete"

    # Get snapshot ID
    local snapshot_id
    snapshot_id=$(restic snapshots -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE" \
        --json --latest 1 | jq -r '.[0].short_id')
    info "Snapshot: $snapshot_id"

    # Apply retention policy
    info "Applying retention policy..."
    restic forget \
        -r "$RESTIC_REPO" \
        --password-file "$PASSWORD_FILE" \
        --keep-daily "$RESTIC_KEEP_DAILY" \
        --keep-weekly "$RESTIC_KEEP_WEEKLY" \
        --keep-monthly "$RESTIC_KEEP_MONTHLY" \
        --prune
    if [[ $? -ne 0 ]]; then
        warn "Retention/prune had errors (backup is safe)"
    fi

    # Verify repo integrity
    info "Checking repo integrity..."
    restic check --with-cache -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE"
    if [[ $? -ne 0 ]]; then
        warn "Repo check reported issues (investigate with: restic check -r \"$RESTIC_REPO\")"
    fi

    # Update manifest on NAS
    info "Updating manifest on NAS..."
    if ssh -o ConnectTimeout=10 "$SSH_HOST" "echo ok" &>/dev/null; then
        ssh_mount_nfs

        local existing
        existing=$(ssh "$SSH_HOST" "cat $NFS_MOUNT/.offsite-manifest.json 2>/dev/null") || true
        local manifest
        if [[ -n "$existing" ]]; then
            manifest=$(echo "$existing" | jq \
                --arg enc "$NOW_ISO" \
                --arg snap "$snapshot_id" \
                '.last_encrypt = $enc | .restic_snapshot = $snap')
        else
            manifest=$(jq -n \
                --arg enc "$NOW_ISO" \
                --arg snap "$snapshot_id" \
                '{
                    last_pull: null,
                    last_encrypt: $enc,
                    restic_snapshot: $snap,
                    pulled_files: {}
                }')
        fi

        echo "$manifest" | ssh "$SSH_HOST" "sudo tee $NFS_MOUNT/.offsite-manifest.json > /dev/null"
        if [[ $? -ne 0 ]]; then
            warn "Failed to update manifest on NAS (non-fatal)"
        else
            log "Manifest updated on NAS"
        fi

        ssh_umount_nfs
    else
        warn "Cannot reach cp1 - manifest not updated (non-fatal)"
    fi

    echo ""
    log "Encrypt complete ($NOW)"
    echo "    Snapshot: $snapshot_id"
    echo "    Repo:     $RESTIC_REPO"
    echo ""
    echo "    Next: $0 status"
}

cmd_status() {
    log "Backup status"
    load_config
    check_restic
    check_password

    # Read manifest from NAS
    echo ""
    echo "Off-Site Manifest:"
    if ssh -o ConnectTimeout=10 "$SSH_HOST" "echo ok" &>/dev/null; then
        ssh_mount_nfs

        local manifest
        manifest=$(ssh "$SSH_HOST" "cat $NFS_MOUNT/.offsite-manifest.json 2>/dev/null") || true
        if [[ -n "$manifest" ]]; then
            local last_pull last_encrypt snapshot file_count
            last_pull=$(echo "$manifest" | jq -r '.last_pull // "never"')
            last_encrypt=$(echo "$manifest" | jq -r '.last_encrypt // "never"')
            snapshot=$(echo "$manifest" | jq -r '.restic_snapshot // "none"')
            file_count=$(echo "$manifest" | jq '.pulled_files | length')

            echo "  Last pull:     $last_pull"
            echo "  Last encrypt:  $last_encrypt (snapshot $snapshot)"
            echo "  Files pulled:  $file_count"
        else
            warn "  No manifest found on NAS"
        fi

        ssh_umount_nfs
    else
        warn "  Cannot reach cp1 - manifest unavailable"
    fi

    # Staging info
    echo ""
    echo "Staging: $STAGING_DIR"
    if [[ -d "$STAGING_DIR" ]]; then
        local folders=0
        local total_size=0
        local latest=""
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            folders=$((folders + 1))
            local dirname
            dirname=$(basename "$dir")
            local dir_size
            dir_size=$(du -sb "$dir" 2>/dev/null | awk '{print $1}')
            total_size=$((total_size + dir_size))
            echo "  $dirname  $(human_size "$dir_size")"
            if [[ -z "$latest" || "$dirname" > "$latest" ]]; then
                latest="$dirname"
            fi
        done < <(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

        if [[ $folders -eq 0 ]]; then
            echo "  (empty)"
        else
            echo "  ---"
            echo "  Folders:     $folders"
            echo "  Total size:  $(human_size $total_size)"
            echo "  Latest:      $latest"
        fi
    else
        echo "  (not found)"
    fi

    # Restic repo info
    echo ""
    echo "Restic repo: $RESTIC_REPO"
    if [[ -d "$RESTIC_REPO" ]]; then
        local snapshots
        snapshots=$(restic snapshots -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE" --json 2>/dev/null) || true
        if [[ -n "$snapshots" && "$snapshots" != "null" ]]; then
            local snap_count latest_id latest_time
            snap_count=$(echo "$snapshots" | jq 'length')
            latest_id=$(echo "$snapshots" | jq -r '.[-1].short_id')
            latest_time=$(echo "$snapshots" | jq -r '.[-1].time')

            echo "  Snapshots:  $snap_count"
            echo "  Latest:     $latest_time ($latest_id)"

            # Repo size
            local repo_stats
            repo_stats=$(restic stats -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE" --json 2>/dev/null) || true
            if [[ -n "$repo_stats" ]]; then
                local repo_size
                repo_size=$(echo "$repo_stats" | jq -r '.total_size')
                echo "  Repo size:  $(human_size "$repo_size")"
            fi
        else
            echo "  (no snapshots)"
        fi
    else
        echo "  (not found - is OneDrive running?)"
    fi

    echo ""
}

cmd_prune() {
    log "Pruning old staging folders"
    load_config
    check_restic
    check_password

    if [[ ! -d "$STAGING_DIR" ]]; then
        info "Nothing to prune (staging directory not found)"
        return 0
    fi

    # List all date folders
    local folders=()
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        folders+=("$dir")
    done < <(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if [[ ${#folders[@]} -eq 0 ]]; then
        info "Nothing to prune."
        return 0
    fi

    # Get restic snapshots for verification
    local snapshots
    snapshots=$(restic snapshots -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE" --json 2>/dev/null) || true

    local cutoff_date
    cutoff_date=$(TZ='Asia/Manila' date -d "$STAGING_KEEP_DAYS days ago" +%Y-%m-%d)

    local to_delete=()
    local to_keep=()
    local skipped_unencrypted=()

    for dir in "${folders[@]}"; do
        local dirname
        dirname=$(basename "$dir")

        # Keep if newer than cutoff
        if [[ "$dirname" > "$cutoff_date" || "$dirname" == "$cutoff_date" ]]; then
            to_keep+=("$dirname")
            continue
        fi

        # Check if this date was encrypted (snapshot tagged with this date)
        local encrypted=false
        if [[ -n "$snapshots" && "$snapshots" != "null" ]]; then
            local match
            match=$(echo "$snapshots" | jq -r --arg d "$dirname" '[.[] | select(.tags[]? == $d)] | length')
            if [[ "$match" -gt 0 ]]; then
                encrypted=true
            fi
        fi

        if [[ "$encrypted" == "false" ]]; then
            warn "$dirname has not been encrypted yet. Skipping."
            skipped_unencrypted+=("$dirname")
            to_keep+=("$dirname")
        else
            to_delete+=("$dirname")
        fi
    done

    # Safety: refuse to delete all folders
    if [[ ${#to_keep[@]} -eq 0 && ${#to_delete[@]} -gt 0 ]]; then
        die "Would delete all staging data. Keep at least 1 folder."
    fi

    if [[ ${#to_delete[@]} -eq 0 ]]; then
        info "Nothing to prune."
        [[ ${#skipped_unencrypted[@]} -gt 0 ]] && warn "Unencrypted folders kept: ${skipped_unencrypted[*]}"
        return 0
    fi

    # Delete old encrypted folders
    for dirname in "${to_delete[@]}"; do
        info "Deleting $STAGING_DIR/$dirname..."
        rm -rf "$STAGING_DIR/$dirname"
        log "  Deleted $dirname"
    done

    echo ""
    log "Prune complete"
    echo "    Deleted: ${#to_delete[@]} folders (${to_delete[*]})"
    echo "    Kept:    ${#to_keep[@]} folders (${to_keep[*]})"
    [[ ${#skipped_unencrypted[@]} -gt 0 ]] && echo "    Skipped: ${skipped_unencrypted[*]} (not yet encrypted)"
}

cmd_restore() {
    log "Restore from restic repo"
    load_config
    check_restic
    check_password
    check_repo

    # List snapshots
    info "Available snapshots:"
    echo ""
    restic snapshots -r "$RESTIC_REPO" --password-file "$PASSWORD_FILE"
    echo ""

    # Prompt for snapshot
    read -rp "Enter snapshot ID to restore (or 'latest'): " snapshot_id
    if [[ -z "$snapshot_id" ]]; then
        die "No snapshot ID provided"
    fi

    # Prompt for target directory
    read -rp "Restore target directory [/tmp/homelab-restore]: " target_dir
    target_dir="${target_dir:-/tmp/homelab-restore}"

    mkdir -p "$target_dir"

    info "Restoring snapshot $snapshot_id to $target_dir..."
    restic restore "$snapshot_id" \
        --target "$target_dir" \
        -r "$RESTIC_REPO" \
        --password-file "$PASSWORD_FILE"
    if [[ $? -ne 0 ]]; then
        die "Restore failed"
    fi

    echo ""
    log "Restore complete"
    echo "    Snapshot: $snapshot_id"
    echo "    Target:   $target_dir"
    echo ""
    echo "    Verify restored files:"
    echo "    ls -la $target_dir"
    echo "    find $target_dir -type f | head -20"
}

# --- Main ---

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  setup    One-time: fetch password from Vault/1Password, init restic repo"
    echo "  pull     Pull backups from NAS to WSL2 staging via SSH+rsync"
    echo "  encrypt  Encrypt staging to restic repo on OneDrive"
    echo "  status   Show backup state (NAS manifest + staging + restic)"
    echo "  prune    Delete staging folders older than $STAGING_KEEP_DAYS days"
    echo "  restore  Restore files from a restic snapshot"
    echo ""
    echo "Typical workflow:  $0 pull && $0 encrypt && $0 prune"
}

case "${1:-}" in
    setup)   cmd_setup ;;
    pull)    cmd_pull ;;
    encrypt) cmd_encrypt ;;
    status)  cmd_status ;;
    prune)   cmd_prune ;;
    restore) cmd_restore ;;
    -h|--help|help) usage ;;
    *)
        if [[ -n "${1:-}" ]]; then
            err "Unknown command: $1"
            echo ""
        fi
        usage
        exit 1
        ;;
esac
