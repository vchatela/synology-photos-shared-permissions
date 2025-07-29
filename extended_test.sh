#!/bin/bash

# Extended Test Script for Synology Photos Permission Synchronization
# This script tests folder IDs 1-50 with sync and audit operations
#
# Usage: ./extended_test.sh [start_id] [end_id]
# Example: ./extended_test.sh 1 50
# Example: ./extended_test.sh 10 20  (test only IDs 10-20)

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to log messages
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_section() {
    echo -e "${BLUE}=================================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}=================================================================================${NC}"
}

log_subsection() {
    echo -e "${CYAN}--- $1 ---${NC}"
}

# Function to check if folder exists in database
folder_exists_in_db() {
    local folder_id=$1
    local folder_name=$(su - postgres -c "psql -d synofoto -t -A -c \"SELECT name FROM folder WHERE id = $folder_id;\"" 2>/dev/null)
    
    if [ -n "$folder_name" ] && [ "$folder_name" != "" ]; then
        return 0  # Folder exists
    else
        return 1  # Folder doesn't exist
    fi
}

# Function to get folder path from database
get_folder_path_from_db() {
    local folder_id=$1
    local folder_name=$(su - postgres -c "psql -d synofoto -t -A -c \"SELECT name FROM folder WHERE id = $folder_id;\"" 2>/dev/null)
    
    # Convert database folder name to filesystem path
    if [[ "$folder_name" == /* ]]; then
        echo "/volume1/photo${folder_name}"
    else
        echo "/volume1/photo/${folder_name}"
    fi
}

# Function to run sync for a folder
run_sync() {
    local folder_id=$1
    log_subsection "SYNC: Folder ID $folder_id"
    
    if ! folder_exists_in_db "$folder_id"; then
        log_warn "Folder ID $folder_id does not exist in database - skipping"
        return 1
    fi
    
    local folder_path=$(get_folder_path_from_db "$folder_id")
    log_info "Processing: $folder_path"
    
    # Check if folder exists on filesystem
    if [ ! -d "$folder_path" ]; then
        log_warn "Folder does not exist on filesystem: $folder_path - skipping"
        return 1
    fi
    
    # Run sync with error handling
    if ./sync_permissions.sh "$folder_id" > /tmp/sync_${folder_id}.log 2>&1; then
        log_info "✓ Sync completed successfully for folder ID $folder_id"
        return 0
    else
        log_error "✗ Sync failed for folder ID $folder_id - check /tmp/sync_${folder_id}.log"
        return 1
    fi
}

# Function to run audit for a folder
run_audit() {
    local folder_id=$1
    log_subsection "AUDIT: Folder ID $folder_id"
    
    if ! folder_exists_in_db "$folder_id"; then
        log_warn "Folder ID $folder_id does not exist in database - skipping"
        return 1
    fi
    
    local folder_path=$(get_folder_path_from_db "$folder_id")
    
    # Check if folder exists on filesystem
    if [ ! -d "$folder_path" ]; then
        log_warn "Folder does not exist on filesystem: $folder_path - skipping"
        return 1
    fi
    
    # Run audit with error handling
    if ./permission_audit.sh folder "$folder_id" > /tmp/audit_${folder_id}.log 2>&1; then
        # Extract better summary from audit log - get all user results and summary
        local user_results=$(grep -E "\[SUCCESS\].*✓|\[MISMATCH\].*✗" /tmp/audit_${folder_id}.log)
        
        if [ -n "$user_results" ]; then
            # Show just the count and status for brevity
            local success_count=$(echo "$user_results" | grep -c "SUCCESS")
            local mismatch_count=$(echo "$user_results" | grep -c "MISMATCH")
            local total_count=$((success_count + mismatch_count))
            
            echo "Users audited: $total_count | ✓ Aligned: $success_count | ✗ Mismatched: $mismatch_count"
            
            # Show any mismatches in detail
            if [ $mismatch_count -gt 0 ]; then
                echo "MISMATCHES:"
                echo "$user_results" | grep "MISMATCH"
            fi
            
            # Show folder status
            local status_line=$(grep "Status:" /tmp/audit_${folder_id}.log)
            if [ -n "$status_line" ]; then
                echo "$status_line"
            fi
        else
            log_info "✓ Audit completed for folder ID $folder_id"
        fi
        return 0
    else
        log_error "✗ Audit failed for folder ID $folder_id - check /tmp/audit_${folder_id}.log"
        return 1
    fi
}

# Function to generate summary report
generate_summary() {
    local start_id=$1
    local end_id=$2
    local total_processed=$3
    local total_synced=$4
    local total_audited=$5
    local total_skipped=$6
    local total_errors=$7
    
    log_section "EXTENDED TEST SUMMARY REPORT"
    
    echo "Test Range: Folder IDs $start_id to $end_id"
    echo "Total Folders Processed: $total_processed"
    echo "Successfully Synced: $total_synced"
    echo "Successfully Audited: $total_audited"
    echo "Skipped (non-existent): $total_skipped"
    echo "Errors: $total_errors"
    echo ""
    
    # Success rate calculation
    if [ $total_processed -gt 0 ]; then
        local success_rate=$(( (total_synced * 100) / total_processed ))
        echo "Sync Success Rate: ${success_rate}%"
    fi
    
    echo ""
    echo "Log files generated in /tmp/ with pattern:"
    echo "  - sync_[folder_id].log (sync operation logs)"
    echo "  - audit_[folder_id].log (audit operation logs)"
    echo ""
    
    # Find folders with issues
    local problem_folders=()
    for ((id=start_id; id<=end_id; id++)); do
        if [ -f "/tmp/audit_${id}.log" ]; then
            if grep -q "MISMATCH" "/tmp/audit_${id}.log"; then
                problem_folders+=($id)
            fi
        fi
    done
    
    if [ ${#problem_folders[@]} -gt 0 ]; then
        log_warn "Folders with permission mismatches found:"
        for folder_id in "${problem_folders[@]}"; do
            local folder_path=$(get_folder_path_from_db "$folder_id")
            echo "  - Folder ID $folder_id: $folder_path"
        done
        echo ""
        echo "To debug specific folders, run:"
        echo "  ./permission_audit.sh debug [folder_id]"
    else
        log_info "No permission mismatches detected in processed folders!"
    fi
}

# Main execution
main() {
    local start_id=${1:-1}    # Default start at ID 1
    local end_id=${2:-50}     # Default end at ID 50
    
    # Validate inputs
    if ! [[ "$start_id" =~ ^[0-9]+$ ]] || ! [[ "$end_id" =~ ^[0-9]+$ ]]; then
        log_error "Invalid input: start_id and end_id must be numbers"
        echo "Usage: $0 [start_id] [end_id]"
        echo "Example: $0 1 50"
        exit 1
    fi
    
    if [ "$start_id" -gt "$end_id" ]; then
        log_error "start_id ($start_id) cannot be greater than end_id ($end_id)"
        exit 1
    fi
    
    log_section "EXTENDED PERMISSION SYNC & AUDIT TEST"
    echo "Testing folder IDs: $start_id to $end_id"
    echo "Started at: $(date)"
    echo ""
    
    # Check if required scripts exist
    if [ ! -f "./sync_permissions.sh" ]; then
        log_error "sync_permissions.sh not found in current directory"
        exit 1
    fi
    
    if [ ! -f "./permission_audit.sh" ]; then
        log_error "permission_audit.sh not found in current directory"
        exit 1
    fi
    
    # Make sure scripts are executable
    chmod +x ./sync_permissions.sh
    chmod +x ./permission_audit.sh
    
    # Initialize counters
    local total_processed=0
    local total_synced=0
    local total_audited=0
    local total_skipped=0
    local total_errors=0
    
    # Process each folder ID
    for ((folder_id=start_id; folder_id<=end_id; folder_id++)); do
        log_section "PROCESSING FOLDER ID: $folder_id"
        
        # Check if folder exists in database
        if ! folder_exists_in_db "$folder_id"; then
            log_warn "Folder ID $folder_id does not exist in database - skipping"
            ((total_skipped++))
            continue
        fi
        
        ((total_processed++))
        
        # Run sync operation
        if run_sync "$folder_id"; then
            ((total_synced++))
            
            # If sync succeeded, run audit
            if run_audit "$folder_id"; then
                ((total_audited++))
            else
                ((total_errors++))
            fi
        else
            ((total_errors++))
        fi
        
        echo "" # Add spacing between folders
        
        # Add a small delay to prevent overwhelming the system
        sleep 1
    done
    
    # Generate final summary
    generate_summary "$start_id" "$end_id" "$total_processed" "$total_synced" "$total_audited" "$total_skipped" "$total_errors"
    
    echo "Completed at: $(date)"
    log_info "Extended test completed!"
}

# Check if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
