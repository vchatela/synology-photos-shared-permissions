#!/bin/bash

# Fix Ownership Script
# This script fixes orphaned ownership from PhotoStation migration to Synology Photos
#
# BACKGROUND:
# When migrating from PhotoStation to Synology Photos, folders created under PhotoStation
# retain their original ownership (UID 138862), which becomes orphaned after migration.
# These orphaned folders are not properly managed by Synology Photos and can cause
# permission sync issues.
#
# PROBLEM:
# - PhotoStation created folders with UID 138862 (PhotoStation service user)
# - After migration to Synology Photos, this UID becomes orphaned
# - Orphaned folders cannot be properly managed by permission sync scripts
# - May cause inconsistencies in access control
#
# SOLUTION:
# This script identifies and fixes orphaned folders by changing their ownership
# to SynologyPhotos:SynologyPhotos, ensuring proper integration with the permission
# management system.

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_fix() {
    echo -e "${BLUE}[FIX]${NC} $1"
}

# Function to check if SynologyPhotos user exists
check_synology_photos_user() {
    if ! id SynologyPhotos >/dev/null 2>&1; then
        log_error "SynologyPhotos user does not exist on this system"
        exit 1
    fi
    
    local uid=$(id -u SynologyPhotos)
    local gid=$(id -g SynologyPhotos)
    log_info "SynologyPhotos user found - UID: $uid, GID: $gid"
}

# Function to find folders with orphaned ownership
find_orphaned_folders() {
    log_info "Scanning for folders with orphaned PhotoStation ownership (UID 138862) at ALL levels..."
    log_info "These folders were created under PhotoStation and became orphaned after migration"
    
    find "/volume1/photo" -type d -uid 138862 2>/dev/null | while read folder; do
        if [ "$folder" != "/volume1/photo" ]; then
            echo "$folder"
        fi
    done
}

# Function to find folders owned by admin that should be SynologyPhotos
find_admin_owned_folders() {
    log_info "Scanning for folders owned by admin that should be SynologyPhotos at ALL levels..."
    
    find "/volume1/photo" -type d -user admin 2>/dev/null | while read folder; do
        if [ "$folder" != "/volume1/photo" ]; then
            echo "$folder"
        fi
    done
}

# Function to fix ownership for a single folder
fix_folder_ownership() {
    local folder="$1"
    local reason="$2"
    
    log_fix "Fixing ownership for: $folder ($reason)"
    
    # Get current ownership
    local current_owner=$(stat -c '%U:%G' "$folder" 2>/dev/null)
    log_info "Current owner: $current_owner"
    
    # Change ownership to SynologyPhotos:SynologyPhotos
    if chown SynologyPhotos:SynologyPhotos "$folder"; then
        log_info "✅ Successfully changed ownership to SynologyPhotos:SynologyPhotos"
        return 0
    else
        log_error "❌ Failed to change ownership for $folder"
        return 1
    fi
}

# Function to fix all orphaned folders
fix_orphaned_ownership() {
    local dry_run="$1"
    local fixed_count=0
    local failed_count=0
    
    log_info "=== FIXING ORPHANED PHOTOSTATION FOLDERS (UID 138862) ==="
    log_info "These folders were created under PhotoStation and became orphaned after migration"
    
    local orphaned_folders=$(find_orphaned_folders)
    
    if [ -z "$orphaned_folders" ]; then
        log_info "No orphaned folders found"
        return 0
    fi
    
    echo "$orphaned_folders" | while read folder; do
        if [ -n "$folder" ]; then
            if [ "$dry_run" = "true" ]; then
                log_warn "[DRY RUN] Would fix: $folder"
            else
                if fix_folder_ownership "$folder" "orphaned PhotoStation folder (UID 138862)"; then
                    ((fixed_count++))
                else
                    ((failed_count++))
                fi
            fi
        fi
    done
    
    return 0
}

# Function to fix admin-owned folders
fix_admin_ownership() {
    local dry_run="$1"
    local fixed_count=0
    local failed_count=0
    
    log_info "=== FIXING ADMIN-OWNED FOLDERS ==="
    
    local admin_folders=$(find_admin_owned_folders)
    
    if [ -z "$admin_folders" ]; then
        log_info "No admin-owned folders found"
        return 0
    fi
    
    echo "$admin_folders" | while read folder; do
        if [ -n "$folder" ]; then
            if [ "$dry_run" = "true" ]; then
                log_warn "[DRY RUN] Would fix: $folder"
            else
                if fix_folder_ownership "$folder" "admin-owned"; then
                    ((fixed_count++))
                else
                    ((failed_count++))
                fi
            fi
        fi
    done
    
    return 0
}

# Function to show summary of current ownership issues
show_ownership_summary() {
    log_info "=== OWNERSHIP SUMMARY ==="
    
    log_info "Folders by ownership type:"
    echo
    
    # Count by owner
    echo "Owner distribution in /volume1/photo:"
    ls -la "/volume1/photo" | grep '^d' | awk '{print $3}' | sort | uniq -c | sort -nr
    
    echo
    log_info "Problematic folders:"
    
    # Orphaned UID 138862
    local orphaned_count=$(find "/volume1/photo" -type d -uid 138862 2>/dev/null | wc -l)
    echo "  Orphaned PhotoStation folders (UID 138862): $orphaned_count folders"
    if [ $orphaned_count -gt 0 ]; then
        echo "    ↳ These are legacy folders from PhotoStation migration"
    fi
    
    # Admin owned
    local admin_count=$(find "/volume1/photo" -type d -user admin 2>/dev/null | wc -l)
    echo "  Admin-owned: $admin_count folders"
    
    # SynologyPhotos owned (good)
    local synology_count=$(find "/volume1/photo" -type d -user SynologyPhotos 2>/dev/null | wc -l)
    echo "  SynologyPhotos-owned: $synology_count folders (correct)"
}

# Main function
main() {
    local action="$1"
    
    echo "======================================================"
    echo "        SYNOLOGY PHOTOS OWNERSHIP FIXER"
    echo "======================================================"
    echo "Started at: $(date)"
    echo
    
    # Check prerequisites
    check_synology_photos_user
    echo
    
    case "$action" in
        "summary"|"")
            show_ownership_summary
            ;;
        "dry-run")
            log_info "=== DRY RUN MODE - NO CHANGES WILL BE MADE ==="
            echo
            fix_orphaned_ownership "true"
            echo
            fix_admin_ownership "true"
            ;;
        "fix-orphaned")
            log_warn "=== FIXING ORPHANED FOLDERS ONLY ==="
            echo
            fix_orphaned_ownership "false"
            ;;
        "fix-admin")
            log_warn "=== FIXING ADMIN-OWNED FOLDERS ONLY ==="
            echo
            fix_admin_ownership "false"
            ;;
        "fix-all")
            log_warn "=== FIXING ALL OWNERSHIP ISSUES ==="
            echo
            fix_orphaned_ownership "false"
            echo
            fix_admin_ownership "false"
            ;;
        *)
            echo "Usage: $0 [summary|dry-run|fix-orphaned|fix-admin|fix-all]"
            echo
            echo "This script fixes orphaned folders from PhotoStation → Synology Photos migration"
            echo "PhotoStation folders (UID 138862) become orphaned and need ownership correction"
            echo
            echo "Commands:"
            echo "  summary      - Show ownership summary (default)"
            echo "  dry-run      - Show what would be fixed without making changes"
            echo "  fix-orphaned - Fix only orphaned PhotoStation folders (UID 138862)"
            echo "  fix-admin    - Fix only admin-owned folders"
            echo "  fix-all      - Fix both orphaned and admin-owned folders"
            echo
            echo "WHEN TO RUN:"
            echo "  • After migrating from PhotoStation to Synology Photos"
            echo "  • When permission sync scripts report orphaned folder issues"
            echo "  • Before running batch permission synchronization on migrated systems"
            exit 1
            ;;
    esac
    
    echo
    echo "======================================================"
    echo "Completed at: $(date)"
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
