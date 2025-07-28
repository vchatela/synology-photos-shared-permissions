#!/bin/bash

# Synology Photos Permission Synchronization Script
# This script aligns filesystem ACLs with Synology Photos database permissions
#
# IMPORTANT: This script grants READ-ONLY access to users who have any permission (>0) 
# in the Synology Photos database. Write permissions are NOT granted to maintain security.
# The goal is to ensure users can only access via filesystem what they can see in Synology Photos.

# Color output for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Function to convert database permission bitmap to ACL permissions
# According to requirements: EVERYONE gets read-only access regardless of database permission level
# Permission bitmap meanings:
# 3 = view (read access)
# 7 = download (read + additional)
# 15 = upload (read + write)  
# 31 = manage (full access)
# BUT: We only grant read permissions for filesystem access
get_acl_permissions() {
    local perm=$1
    # For any permission > 0, grant read-only access
    if [ "$perm" -gt 0 ]; then
        echo "r-x---aARWc--"  # Read + execute + read attributes + read ACL
    else
        log_error "Invalid permission: $perm (must be > 0)"
        return 1
    fi
}

# Function to query database for folder permissions
get_folder_permissions() {
    local folder_id=$1
    
    # Connect to postgres and run the query - get actual usernames, not UIDs
    # Use 2>/dev/null to suppress any postgres connection messages
    su - postgres -c "psql -d synofoto -t -A -F: -c \"
SELECT ui.name, sp.permission
FROM share_permission sp
JOIN user_info ui ON sp.target_id = ui.id
JOIN folder f ON f.passphrase_share = sp.passphrase_share
WHERE f.id = $folder_id AND sp.target_id != 0 AND sp.permission > 0;
\"" 2>/dev/null | grep -v "^$"
}

# Function to get folder path from database
get_folder_path() {
    local folder_id=$1
    local folder_name=$(su - postgres -c "psql -d synofoto -t -A -c \"SELECT name FROM folder WHERE id = $folder_id;\"" 2>/dev/null)
    
    # Convert database folder name to filesystem path
    # Database stores "/Scans" but filesystem is "/volume1/photo/Scans"
    if [[ "$folder_name" == /* ]]; then
        echo "/volume1/photo${folder_name}"
    else
        echo "/volume1/photo/${folder_name}"
    fi
}

# Function to apply ACL permissions to a folder
apply_acl_permissions() {
    local folder_path=$1
    local username=$2
    local permission_bitmap=$3
    
    if [ ! -d "$folder_path" ]; then
        log_error "Folder does not exist: $folder_path"
        return 1
    fi
    
    local acl_perms=$(get_acl_permissions $permission_bitmap)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    log_info "Setting ACL for user '$username' with permissions '$acl_perms' on '$folder_path'"
    
    # Remove existing ACL for this user first (only level:0 entries to avoid inherited entry conflicts)
    local existing_indices=$(synoacltool -get "$folder_path" | grep "user:$username:.*level:0" | sed 's/.*\[\([0-9]*\)\].*/\1/')
    if [ ! -z "$existing_indices" ]; then
        # Remove in reverse order to maintain index validity
        for index in $(echo "$existing_indices" | sort -nr); do
            log_info "Removing existing level:0 ACL entry at index $index for user $username"
            synoacltool -del "$folder_path" "$index" 2>/dev/null || log_warn "Could not remove ACL entry at index $index (may be inherited)"
        done
    fi
    
    # Add new ACL entry
    synoacltool -add "$folder_path" "user:$username:allow:$acl_perms:fd--"
    
    if [ $? -eq 0 ]; then
        log_info "Successfully applied ACL for user $username"
    else
        log_error "Failed to apply ACL for user $username"
        return 1
    fi
}

# Function to remove ACL for users not in database
remove_unauthorized_users() {
    local folder_path=$1
    local authorized_users=$2
    
    log_info "Checking for unauthorized users on '$folder_path'"
    
    # Get current ACL users from level:0 only (excluding system deny rules and administrators group)
    local current_users=$(synoacltool -get "$folder_path" | grep "user:.*:allow:.*level:0" | sed 's/.*user:\([^:]*\):.*/\1/' | grep -v -E "^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal)$")
    
    for user in $current_users; do
        if ! echo "$authorized_users" | grep -q "\b$user\b"; then
            log_warn "User '$user' not authorized according to database, removing access"
            # Get all level:0 indices for this user
            local user_indices=$(synoacltool -get "$folder_path" | grep "user:$user:allow:.*level:0" | sed 's/.*\[\([0-9]*\)\].*/\1/')
            if [ ! -z "$user_indices" ]; then
                # Remove in reverse order to maintain index validity
                for index in $(echo "$user_indices" | sort -nr); do
                    synoacltool -del "$folder_path" "$index" 2>/dev/null || log_warn "Could not remove ACL entry at index $index (may be inherited)"
                done
                log_info "Removed ACL entry for unauthorized user $user"
            fi
        fi
    done
}

# Function to deny users who have inherited permissions but no database permissions
deny_inherited_unauthorized_users() {
    local folder_path=$1
    local authorized_users=$2
    
    log_info "Checking for users with inherited permissions but no database access"
    log_info "Authorized users: [$authorized_users]"
    
    # Get users with level:1 (inherited) allow permissions (excluding system users and admin group)
    local inherited_users=$(synoacltool -get "$folder_path" | grep "user:.*:allow:.*level:1" | sed 's/.*user:\([^:]*\):.*/\1/' | grep -v -E "^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal)$")
    log_info "Inherited users: [$inherited_users]"
    
    for user in $inherited_users; do
        log_info "Checking user: $user"
        if ! echo "$authorized_users" | grep -q "\b$user\b"; then
            log_info "User '$user' is NOT in authorized list - will add deny rule"
            # Check if user already has a level:0 entry (either allow or deny)
            local existing_level0=$(synoacltool -get "$folder_path" | grep "user:$user:.*level:0")
            if [ -z "$existing_level0" ]; then
                log_info "User '$user' has inherited permissions but no database access - adding explicit deny rule"
                # Add explicit deny rule at level:0 to override inherited allow at level:1
                synoacltool -add "$folder_path" "user:$user:deny:rwxpdDaARWcCo:fd--"
                if [ $? -eq 0 ]; then
                    log_info "Successfully added deny rule for user $user"
                else
                    log_error "Failed to add deny rule for user $user"
                fi
            else
                log_info "User '$user' already has level:0 rule, skipping deny"
            fi
        else
            log_info "User '$user' IS in authorized list - skipping deny rule"
        fi
    done
}

# Main function to sync permissions for a folder
sync_folder_permissions() {
    local folder_id=$1
    
    log_info "Starting permission sync for folder ID: $folder_id"
    
    # Get folder path
    local folder_path=$(get_folder_path $folder_id)
    log_info "Folder path: $folder_path"
    
    if [ ! -d "$folder_path" ]; then
        log_error "Folder does not exist: $folder_path"
        return 1
    fi
    
    # Get permissions from database
    log_info "Querying database for folder permissions..."
    local permissions=$(get_folder_permissions $folder_id)
    
    if [ -z "$permissions" ]; then
        log_warn "No permissions found in database for folder ID $folder_id"
        local authorized_users=""
    else
        log_info "Database permissions found:"
        local temp_file="/tmp/permissions.tmp"
        echo "$permissions" > "$temp_file"
        while IFS=: read -r username perm; do
            if [ ! -z "$username" ] && [ ! -z "$perm" ]; then
                log_info "  User: $username, DB Permission: $perm -> Will get READ-ONLY filesystem access"
            fi
        done < "$temp_file"
        rm -f "$temp_file"
        
        # Get list of authorized users
        local authorized_users=$(echo "$permissions" | cut -d: -f1 | tr '\n' ' ')
        
        # Apply permissions for each user
        local temp_file="/tmp/permissions.tmp"
        echo "$permissions" > "$temp_file"
        while IFS=: read -r username perm; do
            if [ ! -z "$username" ] && [ ! -z "$perm" ]; then
                apply_acl_permissions "$folder_path" "$username" "$perm"
            fi
        done < "$temp_file"
        rm -f "$temp_file"
        
        # Remove unauthorized users
        remove_unauthorized_users "$folder_path" "$authorized_users"
    fi
    
    # Deny users who have inherited permissions but no database permissions
    deny_inherited_unauthorized_users "$folder_path" "$authorized_users"
    
    # Ensure parent folder traversal permissions
    ensure_parent_traversal_permissions "$folder_path" "$authorized_users"
    
    log_info "Permission sync completed for folder ID: $folder_id"
}

# Function to ensure users can traverse parent folders to reach their authorized subfolder
ensure_parent_traversal_permissions() {
    local folder_path="$1"
    local authorized_users="$2"
    
    log_info "Checking parent folder traversal permissions for: $folder_path"
    
    # Get parent folder path (remove last component)
    local parent_path=$(dirname "$folder_path")
    
    # Skip if already at photo root
    if [ "$parent_path" = "/volume1/photo" ] || [ "$parent_path" = "/volume1" ]; then
        return 0
    fi
    
    # Check each authorized user
    for username in $authorized_users; do
        # Skip system users
        if [[ "$username" =~ ^(guest|admin|root|chef|temp_adm)$ ]]; then
            continue
        fi
        
        # Test if user can access parent folder
        if ! sudo -u "$username" test -x "$parent_path" 2>/dev/null; then
            log_info "User '$username' cannot traverse parent '$parent_path', granting minimal traversal permissions"
            
            # Grant minimal traversal permission (execute only) to parent folder
            synoacltool -add "$parent_path" "user:$username:allow:--x----------:fd--" 2>/dev/null || true
        fi
    done
}

# Function to validate setup
validate_setup() {
    log_info "Validating setup..."
    
    # Check if we're running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root"
        return 1
    fi
    
    # Check if synoacltool exists
    if ! command -v synoacltool &> /dev/null; then
        log_error "synoacltool not found"
        return 1
    fi
    
    # Check if postgres user exists and database is accessible
    if ! su - postgres -c "psql -d synofoto -c '\q'" &> /dev/null; then
        log_error "Cannot connect to synofoto database as postgres user"
        return 1
    fi
    
    log_info "Setup validation passed"
}

# Function to show current ACL status
show_current_acl() {
    local folder_path=$1
    log_info "Current ACL for '$folder_path':"
    synoacltool -get "$folder_path"
}

# Main execution
main() {
    local folder_id=${1:-92}  # Default to folder 92 if not specified
    
    echo "=== Synology Photos Permission Synchronization ==="
    echo "Folder ID: $folder_id"
    echo
    
    # Validate setup
    if ! validate_setup; then
        exit 1
    fi
    
    # Get folder path for display
    local folder_path=$(get_folder_path $folder_id)
    
    # Show current state
    log_info "=== BEFORE SYNC ==="
    show_current_acl "$folder_path"
    echo
    
    # Perform sync
    sync_folder_permissions "$folder_id"
    echo
    
    # Show result
    log_info "=== AFTER SYNC ==="
    show_current_acl "$folder_path"
    
    echo
    log_info "Synchronization completed!"
}

# Check if script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
