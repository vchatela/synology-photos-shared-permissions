#!/bin/bash

# Simple test script for the 3 specific folders
# IDs: 1 (root), 1424 (Anniversaires), 1821 (Valentin)

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if we're in the right directory and running as root
if [ ! -f "./sync_permissions.sh" ] || [ ! -f "./permission_audit.sh" ]; then
    echo "Error: Must be run from the directory containing sync_permissions.sh and permission_audit.sh"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Error: Must be run as root"
    exit 1
fi

echo "=== Simple Hierarchical Test ==="
echo "Processing 3 folders in order: 1 -> 1424 -> 1821"
echo

# Define the folders (parent to child)
declare -a folders=(
    "1:/volume1/photo/"
    "1424:/volume1/photo/Anniversaires/"
    "1821:/volume1/photo/Anniversaires/Valentin - 29-10-23"
)

log_info "Step 1: Running sync_permissions on all folders"
echo "================================================"

for folder in "${folders[@]}"; do
    id="${folder%%:*}"
    path="${folder#*:}"
    
    echo
    log_info "Syncing folder ID $id ($path)"
    echo "----------------------------------------"
    ./sync_permissions.sh "$id"
    echo "----------------------------------------"
    sleep 1
done

echo
log_info "Step 2: Running permission_audit on all folders"
echo "==============================================="

for folder in "${folders[@]}"; do
    id="${folder%%:*}"
    path="${folder#*:}"
    
    echo
    log_info "Auditing folder ID $id ($path)"
    echo "----------------------------------------"
    ./permission_audit.sh debug "$id"
    echo "----------------------------------------"
    sleep 1
done

echo
log_info "Test completed!"
echo "Processed folders:"
for folder in "${folders[@]}"; do
    id="${folder%%:*}"
    path="${folder#*:}"
    echo "  ✓ ID $id: $path"
done
