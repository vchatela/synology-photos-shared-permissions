#!/bin/bash

# Validation script to test the permission synchronization
# This script validates that filesystem permissions match database permissions

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
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

# Function to test user access to a folder
test_user_access() {
    local username=$1
    local folder_path=$2
    local expected_access=$3  # "allow" or "deny"
    
    log_info "Testing access for user '$username' to '$folder_path'"
    
    # Test read access
    if su - "$username" -s /bin/bash -c "test -r '$folder_path'" 2>/dev/null; then
        if [ "$expected_access" = "allow" ]; then
            echo -e "  ${GREEN}✓${NC} READ access: GRANTED (Expected: GRANTED)"
        else
            echo -e "  ${RED}✗${NC} READ access: GRANTED (Expected: DENIED)"
            return 1
        fi
    else
        if [ "$expected_access" = "deny" ]; then
            echo -e "  ${GREEN}✓${NC} READ access: DENIED (Expected: DENIED)"
        else
            echo -e "  ${RED}✗${NC} READ access: DENIED (Expected: GRANTED)"
            return 1
        fi
    fi
    
    # Test write access (should always be denied for regular users)
    if su - "$username" -s /bin/bash -c "touch '$folder_path/test_write_$$' 2>/dev/null && rm '$folder_path/test_write_$$' 2>/dev/null"; then
        echo -e "  ${RED}✗${NC} WRITE access: GRANTED (Expected: DENIED)"
        return 1
    else
        echo -e "  ${GREEN}✓${NC} WRITE access: DENIED (Expected: DENIED)"
    fi
    
    return 0
}

# Function to get authorized users from database
get_authorized_users() {
    local folder_id=$1
    su - postgres -c "psql -d synofoto -t -A -F: -c \"
SELECT ui.name
FROM share_permission sp
JOIN user_info ui ON sp.target_id = ui.id
JOIN folder f ON f.passphrase_share = sp.passphrase_share
WHERE f.id = $folder_id AND sp.target_id != 0 AND sp.permission > 0;
\"" | grep -v "^$"
}

# Function to validate folder permissions
validate_folder_permissions() {
    local folder_id=$1
    local folder_path="/volume1/photo/Scans"  # Hardcoded for now, could be made dynamic
    
    echo "=== Validating Permissions for Folder ID: $folder_id ==="
    echo "Folder: $folder_path"
    echo
    
    # Get authorized users from database
    local authorized_users=$(get_authorized_users $folder_id)
    log_info "Users authorized in database:"
    echo "$authorized_users" | while read user; do
        if [ ! -z "$user" ]; then
            echo "  - $user"
        fi
    done
    echo
    
    # Test authorized users
    log_info "Testing authorized users:"
    local all_passed=true
    echo "$authorized_users" | while read user; do
        if [ ! -z "$user" ]; then
            if ! test_user_access "$user" "$folder_path" "allow"; then
                all_passed=false
            fi
            echo
        fi
    done
    
    # Test a service account that has explicit deny rules in ACL
    log_info "Testing service account with deny rule:"
    local deny_user="backup"  # This user has explicit deny in ACL
    if id "$deny_user" &>/dev/null; then
        test_user_access "$deny_user" "$folder_path" "deny"
        echo
    else
        log_info "Service account '$deny_user' not found on system"
        echo
    fi
    
    # Show current ACL
    log_info "Current filesystem ACL:"
    synoacltool -get "$folder_path"
    
    echo
    log_info "Validation completed!"
}

# Main execution
main() {
    local folder_id=${1:-92}
    
    echo "=== Permission Validation Script ==="
    echo
    
    validate_folder_permissions "$folder_id"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
