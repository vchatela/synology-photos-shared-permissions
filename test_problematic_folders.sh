#!/bin/bash

# Test Script for Problematic Folders
# This script tests the problematic folders found by permission_audit.sh
# and processes them in the same order as batch_sync.sh

# Set up logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/test_problematic_$(date +%Y%m%d_%H%M%S).log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1" | tee -a "$LOG_FILE"
}

log_action() {
    echo -e "${CYAN}[ACTION]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to get database connection info
get_all_shared_folders() {
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT DISTINCT f.id, f.name 
FROM folder f
JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
WHERE f.id > 1 
  AND f.name IS NOT NULL 
  AND f.name != '/' 
  AND f.name != ''
  AND f.name NOT LIKE '%#recycle%'
  AND f.name NOT LIKE '%@eaDir%'
  AND f.name NOT LIKE '%.__%'
  AND sp.permission > 0
ORDER BY f.id;
" 2>/dev/null | grep -v "^$"
}

# Function to get folder path from database name
get_folder_path() {
    local folder_name=$1
    
    if [[ "$folder_name" == /* ]]; then
        echo "/volume1/photo${folder_name}"
    else
        echo "/volume1/photo/${folder_name}"
    fi
}

# Function to find all parent folders of a given folder
get_parent_folders() {
    local folder_name=$1
    local parents=()
    
    # Add root folder first
    parents+=("1|/")
    
    # If it's already root, return just root
    if [[ "$folder_name" == "/" ]]; then
        printf '%s\n' "${parents[@]}"
        return
    fi
    
    # Build path components
    local current_path=""
    IFS='/' read -ra PATH_PARTS <<< "$folder_name"
    
    for part in "${PATH_PARTS[@]}"; do
        if [[ -n "$part" ]]; then
            current_path="$current_path/$part"
            # Look up this folder in database
            local folder_info=$(sudo -u postgres psql -d synofoto -t -A -c "
SELECT f.id, f.name 
FROM folder f
JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
WHERE f.name = '$current_path' 
  AND sp.permission > 0
LIMIT 1;
" 2>/dev/null)
            
            if [[ -n "$folder_info" ]]; then
                parents+=("$folder_info")
            fi
        fi
    done
    
    printf '%s\n' "${parents[@]}"
}

# Function to find problematic folders from recent audit
find_problematic_folders() {
    local latest_log=$(find "$LOG_DIR" -name "permission_audit_*.log" -type f -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
    
    if [[ -z "$latest_log" ]]; then
        log_error "No recent permission audit log found. Please run './permission_audit.sh summary' first"
        return 1
    fi
    
    echo "Analyzing latest audit log: $latest_log" >> "$LOG_FILE"
    
    # Extract problematic folder IDs from the audit log
    local problematic_folders=()
    while IFS= read -r line; do
        # Look for lines like: [WARN] Folder 304 (/CDs): 2 mismatches
        if echo "$line" | grep -E '^\[WARN\] Folder [0-9]+ \([^)]+\): [0-9]+ mismatches' >/dev/null; then
            local folder_id=$(echo "$line" | sed -E 's/.*Folder ([0-9]+) .*/\1/')
            local folder_name=$(echo "$line" | sed -E 's/.*Folder [0-9]+ \(([^)]+)\).*/\1/')
            local mismatch_count=$(echo "$line" | sed -E 's/.*: ([0-9]+) mismatches.*/\1/')
            problematic_folders+=("$folder_id|$folder_name|$mismatch_count")
            echo "Found problematic folder: ID $folder_id ($folder_name) with $mismatch_count mismatches" >> "$LOG_FILE"
        fi
    done < "$latest_log"
    
    if [[ ${#problematic_folders[@]} -eq 0 ]]; then
        echo "No problematic folders found in latest audit" >> "$LOG_FILE"
        return 0
    fi
    
    printf '%s\n' "${problematic_folders[@]}"
    return 0
}

# Function to sort folders by ID order (like batch_sync.sh)
sort_folders_by_id() {
    local folders=("$@")
    local sorted_folders=()
    
    # Sort by folder ID ascending (same as batch_sync.sh)
    while IFS= read -r folder_info; do
        sorted_folders+=("$folder_info")
    done < <(
        for folder_info in "${folders[@]}"; do
            IFS='|' read -r folder_id folder_name rest <<< "$folder_info"
            echo "$folder_id|$folder_info"
        done | sort -n | cut -d'|' -f2-
    )
    
    printf '%s\n' "${sorted_folders[@]}"
}

# Function to run sync for a specific folder
run_sync_for_folder() {
    local folder_id=$1
    local folder_name=$2
    
    log_action "Running sync_permissions.sh for folder $folder_id ($folder_name)"
    
    if [[ -f "$SCRIPT_DIR/sync_permissions.sh" ]]; then
        "$SCRIPT_DIR/sync_permissions.sh" "$folder_id" 2>&1 | tee -a "$LOG_FILE"
        local exit_code=${PIPESTATUS[0]}
        if [[ $exit_code -eq 0 ]]; then
            log_info "Sync completed successfully for folder $folder_id"
        else
            log_error "Sync failed for folder $folder_id with exit code $exit_code"
        fi
        return $exit_code
    else
        log_error "sync_permissions.sh not found in $SCRIPT_DIR"
        return 1
    fi
}

# Function to run debug audit for a specific folder
run_debug_for_folder() {
    local folder_id=$1
    local folder_name=$2
    
    log_action "Running debug audit for folder $folder_id ($folder_name)"
    
    if [[ -f "$SCRIPT_DIR/permission_audit.sh" ]]; then
        "$SCRIPT_DIR/permission_audit.sh" debug "$folder_id" 2>&1 | tee -a "$LOG_FILE"
        local exit_code=${PIPESTATUS[0]}
        if [[ $exit_code -eq 0 ]]; then
            log_info "Debug audit completed for folder $folder_id"
        else
            log_warn "Debug audit had issues for folder $folder_id"
        fi
        return $exit_code
    else
        log_error "permission_audit.sh not found in $SCRIPT_DIR"
        return 1
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [command] [options]"
    echo
    echo "Commands:"
    echo "  auto                 - Auto-detect problematic folders and process them (default)"
    echo "  sync-only            - Only run sync_permissions.sh for problematic folders"
    echo "  debug-only           - Only run debug audit for problematic folders"
    echo "  folders <id1,id2>    - Test specific folder IDs (comma-separated)"
    echo "  help                 - Show this help message"
    echo
    echo "Examples:"
    echo "  $0                   - Auto-detect and process problematic folders"
    echo "  $0 sync-only         - Only sync problematic folders"
    echo "  $0 debug-only        - Only debug problematic folders"
    echo "  $0 folders 304,1272  - Test specific folders 304 and 1272"
    echo
    echo "The script processes folders in ID order (same as batch_sync.sh)"
    echo "and logs all output to: logs/test_problematic_YYYYMMDD_HHMMSS.log"
}

# Function to validate prerequisites
validate_setup() {
    # Check if we're running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        return 1
    fi
    
    # Check if postgres user exists and database is accessible
    if ! sudo -u postgres psql -d synofoto -c '\q' &> /dev/null; then
        log_error "Cannot connect to synofoto database as postgres user"
        return 1
    fi
    
    return 0
}

# Main function
main() {
    local command=${1:-"auto"}
    
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "        PROBLEMATIC FOLDERS TEST SCRIPT" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Started at: $(date)" | tee -a "$LOG_FILE"
    echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    # Validate setup
    if ! validate_setup; then
        exit 1
    fi
    
    local folders_to_process=()
    local run_sync=true
    local run_debug=true
    
    case "$command" in
        "auto"|"")
            log_info "Auto-detecting problematic folders from latest audit..."
            local problematic_output
            if problematic_output=$(find_problematic_folders); then
                if [[ -n "$problematic_output" ]]; then
                    mapfile -t problematic_folders <<< "$problematic_output"
                else
                    log_info "No problematic folders found. Exiting."
                    exit 0
                fi
            else
                exit 1
            fi
            
            # Get all parent folders for each problematic folder
            local all_folders=()
            for folder_info in "${problematic_folders[@]}"; do
                IFS='|' read -r folder_id folder_name rest <<< "$folder_info"
                log_debug "Processing problematic folder: $folder_id ($folder_name)"
                
                # Add the folder itself
                all_folders+=("$folder_id|$folder_name")
                
                # Add all its parents
                while IFS= read -r parent_info; do
                    if [[ -n "$parent_info" ]]; then
                        all_folders+=("$parent_info")
                    fi
                done < <(get_parent_folders "$folder_name")
            done
            
            # Remove duplicates and sort by ID
            mapfile -t folders_to_process < <(printf '%s\n' "${all_folders[@]}" | sort -u)
            mapfile -t folders_to_process < <(sort_folders_by_id "${folders_to_process[@]}")
            ;;
            
        "sync-only")
            local problematic_output
            if problematic_output=$(find_problematic_folders); then
                if [[ -n "$problematic_output" ]]; then
                    mapfile -t problematic_folders <<< "$problematic_output"
                else
                    log_info "No problematic folders found. Exiting."
                    exit 0
                fi
            else
                exit 1
            fi
            
            # Process only the problematic folders and their parents
            local all_folders=()
            for folder_info in "${problematic_folders[@]}"; do
                IFS='|' read -r folder_id folder_name rest <<< "$folder_info"
                all_folders+=("$folder_id|$folder_name")
                while IFS= read -r parent_info; do
                    if [[ -n "$parent_info" ]]; then
                        all_folders+=("$parent_info")
                    fi
                done < <(get_parent_folders "$folder_name")
            done
            
            mapfile -t folders_to_process < <(printf '%s\n' "${all_folders[@]}" | sort -u)
            mapfile -t folders_to_process < <(sort_folders_by_id "${folders_to_process[@]}")
            run_debug=false
            ;;
            
        "debug-only")
            local problematic_output
            if problematic_output=$(find_problematic_folders); then
                if [[ -n "$problematic_output" ]]; then
                    mapfile -t problematic_folders <<< "$problematic_output"
                else
                    log_info "No problematic folders found. Exiting."
                    exit 0
                fi
            else
                exit 1
            fi
            
            # Process only the problematic folders (no need for parents in debug)
            for folder_info in "${problematic_folders[@]}"; do
                IFS='|' read -r folder_id folder_name rest <<< "$folder_info"
                folders_to_process+=("$folder_id|$folder_name")
            done
            run_sync=false
            ;;
            
        "folders")
            local folder_ids_str=$2
            if [[ -z "$folder_ids_str" ]]; then
                log_error "Please specify folder IDs (comma-separated)"
                show_usage
                exit 1
            fi
            
            IFS=',' read -ra folder_ids <<< "$folder_ids_str"
            for folder_id in "${folder_ids[@]}"; do
                folder_id=$(echo "$folder_id" | tr -d ' ')
                # Get folder name from database
                local folder_name=$(sudo -u postgres psql -d synofoto -t -A -c "SELECT name FROM folder WHERE id = $folder_id;" 2>/dev/null)
                if [[ -n "$folder_name" ]]; then
                    folders_to_process+=("$folder_id|$folder_name")
                    # NOTE: NOT adding parents - process only specified folders in ID order like batch_sync.sh
                else
                    log_error "Folder ID $folder_id not found in database"
                fi
            done
            
            # Sort by ID order (like batch_sync.sh)
            mapfile -t folders_to_process < <(sort_folders_by_id "${folders_to_process[@]}")
            ;;
            
        "help"|"-h"|"--help")
            show_usage
            exit 0
            ;;
            
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
    
    log_info "Found ${#folders_to_process[@]} folders to process:"
    for folder_info in "${folders_to_process[@]}"; do
        IFS='|' read -r folder_id folder_name rest <<< "$folder_info"
        log_info "  - Folder $folder_id: $folder_name"
    done
    echo | tee -a "$LOG_FILE"
    
    # Process each folder
    local total_folders=${#folders_to_process[@]}
    local current=0
    local sync_success=0
    local sync_failed=0
    
    for folder_info in "${folders_to_process[@]}"; do
        IFS='|' read -r folder_id folder_name rest <<< "$folder_info"
        ((current++))
        
        echo "======================================================" | tee -a "$LOG_FILE"
        log_info "Processing folder $current/$total_folders: ID $folder_id ($folder_name)"
        echo "======================================================" | tee -a "$LOG_FILE"
        
        if [[ "$run_sync" == "true" ]]; then
            if run_sync_for_folder "$folder_id" "$folder_name"; then
                ((sync_success++))
            else
                ((sync_failed++))
            fi
            echo | tee -a "$LOG_FILE"
        fi
        
        if [[ "$run_debug" == "true" ]]; then
            run_debug_for_folder "$folder_id" "$folder_name"
            echo | tee -a "$LOG_FILE"
        fi
    done
    
    # Final summary
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "                FINAL SUMMARY" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Completed at: $(date)" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    log_info "Processing Summary:"
    log_info "  Total folders processed: $total_folders"
    if [[ "$run_sync" == "true" ]]; then
        log_info "  Sync successful: $sync_success"
        log_info "  Sync failed: $sync_failed"
    fi
    
    if [[ "$sync_failed" -gt 0 ]]; then
        log_warn "Some sync operations failed. Check the log for details."
        exit 1
    else
        log_info "All operations completed successfully."
        exit 0
    fi
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
