#!/bin/bash

# Batch Permission Synchronization Script
# This script runs the sync_permissions.sh on multiple folders

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

log_batch() {
    echo -e "${BLUE}[BATCH]${NC} $1"
}

# Function to get folder name from database
get_folder_name() {
    local folder_id=$1
    su - postgres -c "psql -d synofoto -t -c \"SELECT name FROM folder WHERE id = $folder_id;\"" 2>/dev/null | xargs
}

# Function to get all shared folder IDs from database
get_shared_folder_ids() {
    echo "Querying database for shared folders..." >&2
    
    # Get folder IDs that have share permissions and exist on filesystem
    # Filter for folders that:
    # 1. Have share permissions (share_permission table)
    # 2. Are not the root folder (id != 1)
    # 3. Have meaningful names (not empty, not just "/")
    # 4. Exclude system/temporary folders
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT DISTINCT f.id 
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
" 2>/dev/null | grep -E '^[0-9]+$'
}

# Function to filter folder IDs by filesystem existence
filter_existing_folders() {
    local folder_ids_input="$1"
    local existing_ids=()
    local missing_count=0
    
    echo "Filtering folders that exist on filesystem..." >&2
    
    # Convert input to array
    local folder_ids=($folder_ids_input)
    
    for folder_id in "${folder_ids[@]}"; do
        # Ensure folder_id is numeric
        if [[ ! "$folder_id" =~ ^[0-9]+$ ]]; then
            echo "Skipping invalid folder ID: '$folder_id'" >&2
            continue
        fi
        
        local folder_name=$(get_folder_name $folder_id)
        if [ -n "$folder_name" ] && folder_path=$(check_folder_exists "$folder_name"); then
            existing_ids+=($folder_id)
            echo "✓ Folder ID $folder_id: $folder_name" >&2
        else
            echo "✗ Folder ID $folder_id: $folder_name (missing from filesystem)" >&2
            ((missing_count++))
        fi
    done
    
    echo "Found ${#existing_ids[@]} existing folders, $missing_count missing from filesystem" >&2
    echo "${existing_ids[@]}"
}

# Function to setup logging
setup_logging() {
    local log_dir="/volume1/tools/Synology/synology-photos-shared-permissions/logs"
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local log_file="$log_dir/batch_sync_$timestamp.log"
    
    # Create log directory if it doesn't exist
    mkdir -p "$log_dir"
    
    # Rotate logs - keep last 10
    log_batch "Setting up logging in $log_file"
    if [ -d "$log_dir" ]; then
        cd "$log_dir" || exit 1
        ls -1t batch_sync_*.log 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
        cd - > /dev/null || exit 1
    fi
    
    # Export log file path for use in other functions
    export BATCH_LOG_FILE="$log_file"
    
    # Redirect all output to both console and log file
    exec > >(tee -a "$log_file")
    exec 2>&1
    
    log_batch "Log rotation complete, keeping last 10 log files"
    log_batch "Current log file: $log_file"
}

# Function to check if folder exists on filesystem
check_folder_exists() {
    local folder_name=$1
    local folder_path
    
    if [[ "$folder_name" == /* ]]; then
        folder_path="/volume1/photo${folder_name}"
    else
        folder_path="/volume1/photo/${folder_name}"
    fi
    
    if [ -d "$folder_path" ]; then
        echo "$folder_path"
        return 0
    else
        return 1
    fi
}

# Function to run sync for a single folder
sync_single_folder() {
    local folder_id=$1
    local folder_name=$(get_folder_name $folder_id)
    local script_dir="/volume1/tools/Synology/synology-photos-shared-permissions"
    local sync_script="$script_dir/sync_permissions.sh"
    
    log_batch "Processing Folder ID: $folder_id"
    log_info "Folder name: $folder_name"
    
    # Check if folder exists on filesystem
    if folder_path=$(check_folder_exists "$folder_name"); then
        log_info "Folder exists at: $folder_path"
        
        # Run the sync script
        log_info "Running sync_permissions.sh for folder ID $folder_id..."
        if "$sync_script" "$folder_id"; then
            log_info "✅ Successfully synced folder ID $folder_id"
            return 0
        else
            log_error "❌ Failed to sync folder ID $folder_id"
            return 1
        fi
    else
        log_warn "⚠️  Folder does not exist on filesystem: $folder_name"
        log_warn "    Expected path would be: /volume1/photo${folder_name}"
        return 1
    fi
}

# Main batch processing function
main() {
    # Setup logging first
    setup_logging
    
    echo "======================================================"
    echo "     BATCH PERMISSION SYNCHRONIZATION"
    echo "======================================================"
    echo "Started at: $(date)"
    echo
    
    # Get shared folder IDs from database
    log_batch "Getting shared folder IDs from database..."
    local all_folder_ids
    all_folder_ids=$(get_shared_folder_ids)
    
    if [ -z "$all_folder_ids" ]; then
        log_error "Failed to get shared folder IDs from database"
        exit 1
    fi
    
    log_batch "Database returned folder IDs: $all_folder_ids"
    
    # Filter to only folders that exist on filesystem
    log_batch "Filtering folders that exist on filesystem..."
    local folder_ids_filtered
    folder_ids_filtered=$(filter_existing_folders "$all_folder_ids")
    
    if [ -z "$folder_ids_filtered" ]; then
        log_error "No valid folders found to process"
        exit 1
    fi
    
    # Convert to array
    local folder_ids_array=($folder_ids_filtered)
    
    local total_count=${#folder_ids_array[@]}
    log_batch "Processing $total_count folders dynamically retrieved from database..."
    echo
    
    # Validate that sync script exists
    local script_dir="/volume1/tools/Synology/synology-photos-shared-permissions"
    local sync_script="$script_dir/sync_permissions.sh"
    
    if [ ! -f "$sync_script" ]; then
        log_error "sync_permissions.sh not found at $sync_script"
        exit 1
    fi
    
    # Make sure sync script is executable
    chmod +x "$sync_script"
    
    local success_count=0
    local failed_folders=()
    
    # Process each folder
    for folder_id in "${folder_ids_array[@]}"; do
        echo "------------------------------------------------------"
        if sync_single_folder "$folder_id"; then
            ((success_count++))
        else
            failed_folders+=("$folder_id")
        fi
        echo
        sleep 1  # Small delay between folders
    done
    
    echo "======================================================"
    echo "                BATCH SUMMARY"
    echo "======================================================"
    echo "Completed at: $(date)"
    log_batch "Total folders processed: $total_count"
    log_batch "Successfully synced: $success_count"
    log_batch "Failed: $((total_count - success_count))"
    
    if [ ${#failed_folders[@]} -gt 0 ]; then
        echo
        log_warn "Failed folder IDs: ${failed_folders[*]}"
        echo
        log_info "You can manually process failed folders with:"
        for failed_id in "${failed_folders[@]}"; do
            echo "  ./sync_permissions.sh $failed_id"
        done
    fi
    
    echo
    if [ $success_count -eq $total_count ]; then
        log_info "🎉 All folders successfully processed!"
        log_batch "Batch sync completed successfully - log saved to: $BATCH_LOG_FILE"
        exit 0
    else
        log_warn "⚠️  Some folders failed to process. Check the logs above."
        log_batch "Batch sync completed with errors - log saved to: $BATCH_LOG_FILE"
        exit 1
    fi
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
