#!/bin/bash

# Nightly Synology Photos Permission Sync and Audit Script
# This script runs batch sync followed by audit and relies on Synology's 
# built-in task scheduler email notifications when exit code != 0

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NIGHTLY_LOG="$LOG_DIR/nightly_sync_audit_$TIMESTAMP.log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to log with timestamp
log_with_timestamp() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$NIGHTLY_LOG"
}

# Main execution
main() {
    log_with_timestamp "Starting nightly Synology Photos permission sync and audit"
    
    # Step 1: Run batch sync in silent mode
    log_with_timestamp "Running batch permission sync..."
    if "$SCRIPT_DIR/batch_sync.sh" --silent >> "$NIGHTLY_LOG" 2>&1; then
        log_with_timestamp "Batch sync completed successfully"
    else
        log_with_timestamp "ERROR: Batch sync failed"
        exit 1
    fi
    
    # Step 2: Run permission audit
    log_with_timestamp "Running permission audit..."
    if "$SCRIPT_DIR/permission_audit.sh" summary >> "$NIGHTLY_LOG" 2>&1; then
        log_with_timestamp "Permission audit completed - All permissions aligned"
        
        # Clean up old logs (keep last 30 days)
        find "$LOG_DIR" -name "nightly_sync_audit_*.log" -mtime +30 -delete 2>/dev/null || true
        
        exit 0
    else
        log_with_timestamp "WARNING: Permission audit detected misalignments"
        exit 1
    fi
}

# Run main function
main "$@"
