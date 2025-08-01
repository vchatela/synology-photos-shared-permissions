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

# Function to get all system users
get_all_system_users() {
    # Get users from the system that might need permission management
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT name FROM user_info 
WHERE name NOT LIKE '/volume1%' 
  AND name != '' 
  AND name IS NOT NULL
ORDER BY name;
" 2>/dev/null | grep -v "^$"
}

# Function to get all users who have database permissions in ANY folder (for root folder strategy)
get_users_with_any_folder_permissions() {
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT DISTINCT ui.name
FROM share_permission sp
JOIN user_info ui ON sp.target_id = ui.id
JOIN folder f ON f.passphrase_share = sp.passphrase_share
WHERE f.id > 1 
  AND sp.permission > 0
  AND ui.name NOT LIKE '/volume1%' 
  AND ui.name != '' 
  AND ui.name IS NOT NULL
  AND ui.name NOT IN ('guest', 'admin', 'root', 'chef', 'temp_adm', 'backup', 'webdav_syno-j', 'unifi', 'shield', 'n8n', 'jeedom', 'cert-renewal')
ORDER BY ui.name;
" 2>/dev/null | grep -v "^$"
}

# Function to apply root folder permissions strategy
# Root folder (ID=1, /volume1/photo) gets special handling:
# - Users with permissions in ANY subfolder get read+execute access to root
# - This allows discovery and traversal without granting unnecessary access
apply_root_folder_strategy() {
    local root_path="/volume1/photo"
    
    log_info "=== APPLYING ROOT FOLDER STRATEGY ==="
    log_info "Root folder: $root_path (Special handling for folder ID=1)"
    
    if [ ! -d "$root_path" ]; then
        log_error "Root folder does not exist: $root_path"
        return 1
    fi
    
    # Get users who have permissions in any subfolders
    log_info "Getting users with subfolder permissions..."
    local authorized_users=$(get_users_with_any_folder_permissions)
    
    if [ -z "$authorized_users" ]; then
        log_warn "No users found with subfolder permissions"
        return 0
    fi
    
    log_info "Users with subfolder permissions (will get root folder read+execute):"
    echo "$authorized_users" | while read -r user; do
        log_info "  - $user"
    done
    
    # Clean existing level:0 ACL entries from root folder
    log_info "Cleaning existing level:0 ACL entries from root folder..."
    clean_all_level0_acl_entries "$root_path"
    
    # Apply read+execute permissions for authorized users
    log_info "Applying read+execute permissions for authorized users..."
    echo "$authorized_users" | while read -r username; do
        if [ -n "$username" ]; then
            log_info "Granting root folder read+execute to user: $username"
            # Grant read+execute (discovery and traversal) permissions
            synoacltool -add "$root_path" "user:$username:allow:r-x---aARWc--:fd--" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_info "Successfully granted root folder access to $username"
            else
                log_error "Failed to grant root folder access to $username"
            fi
        fi
    done
    
    # Apply deny rules for users who don't have ANY subfolder permissions
    log_info "Applying deny rules for unauthorized users..."
    local all_users=$(get_all_system_users)
    for user in $all_users; do
        # Skip if user is authorized
        if echo "$authorized_users" | grep -q "^$user$"; then
            continue
        fi
        
        # Skip system users that shouldn't be modified
        if [[ "$user" =~ ^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal|guest|admin|root|chef)$ ]]; then
            continue
        fi
        
        # Add explicit deny rule for unauthorized users
        log_info "Adding deny rule for unauthorized user: $user"
        synoacltool -add "$root_path" "user:$user:deny:rwxpdDaARWcCo:fd--" 2>/dev/null || true
    done
    
    log_info "=== ROOT FOLDER STRATEGY COMPLETED ==="
    return 0
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

# Function to get the source folder for an inherited ACL entry
get_acl_source_folder() {
    local folder_path=$1
    local level=$2
    
    # Level 0 = current folder
    if [[ "$level" == "0" ]]; then
        echo "$folder_path"
        return
    fi
    
    # Level 1 = parent folder, Level 2 = grandparent, etc.
    local current_path="$folder_path"
    for ((i=0; i<level; i++)); do
        current_path=$(dirname "$current_path")
        # Don't go above /volume1/photo
        if [[ "$current_path" == "/volume1" ]]; then
            echo "/volume1/photo"
            return
        fi
    done
    echo "$current_path"
}

# Function to clean all level:0 ACL entries from a folder
clean_all_level0_acl_entries() {
    local folder_path="$1"
    
    log_info "Cleaning all level:0 ACL entries from '$folder_path'"
    
    # Keep removing level:0 entries until none are found
    local removed_something=true
    while [ "$removed_something" = true ]; do
        removed_something=false
        
        # Get fresh ACL each time (indices change after each removal)
        local current_acl=$(synoacltool -get "$folder_path" 2>/dev/null)
        if [ -z "$current_acl" ]; then
            break
        fi
        
        # Find the first level:0 entry (any user, any permission type)
        local level0_line=$(echo "$current_acl" | grep "level:0" | head -1)
        
        if [ -n "$level0_line" ]; then
            # Extract the ACL index from the bracketed number
            local acl_index=$(echo "$level0_line" | sed -n 's/.*\[\([0-9]\+\)\].*/\1/p')
            
            if [ -n "$acl_index" ]; then
                log_info "Removing level:0 ACL entry at index $acl_index"
                if synoacltool -del "$folder_path" "$acl_index" >/dev/null 2>&1; then
                    removed_something=true
                else
                    log_warn "Failed to remove ACL entry at index $acl_index"
                    break
                fi
            fi
        fi
    done
    
    log_info "Finished cleaning level:0 ACL entries from '$folder_path'"
}

# Function to remove inherited deny rules for users who should have database access
remove_inherited_deny_rules_for_authorized_users() {
    local folder_path="$1"
    local folder_id="$2"
    
    log_info "Checking for inherited deny rules that would block authorized users"
    
    # Get users who will have database permissions for this folder
    local permissions=$(get_folder_permissions $folder_id)
    if [ -z "$permissions" ]; then
        log_info "No database permissions found - no inherited deny rules to remove"
        return 0
    fi
    
    # Extract authorized usernames
    local authorized_users=$(echo "$permissions" | cut -d: -f1 | tr '\n' ' ')
    
    # Get current ACL and check for inherited deny rules
    local current_acl=$(synoacltool -get "$folder_path" 2>/dev/null)
    if [ -z "$current_acl" ]; then
        return 0
    fi
    
    # Find inherited deny rules (level:1+) for authorized users
    for username in $authorized_users; do
        if [ -z "$username" ]; then continue; fi
        
        # Check if user has inherited deny rules in current folder
        local inherited_deny_lines=$(echo "$current_acl" | grep "user:$username:deny:" | grep -v "level:0")
        
        if [ -n "$inherited_deny_lines" ]; then
            log_warn "User '$username' has inherited deny rules that would block database access - removing from ALL source levels"
            
            # Create temporary file to process each deny rule (avoid subshell issues)
            local temp_deny_file="/tmp/deny_rules_$$"
            echo "$inherited_deny_lines" > "$temp_deny_file"
            
            while read -r deny_line; do
                if [ -z "$deny_line" ]; then continue; fi
                
                # Extract the level from this specific deny rule
                local deny_level=$(echo "$deny_line" | sed 's/.*level:\([0-9]\+\).*/\1/')
                
                if [ -n "$deny_level" ] && [ "$deny_level" -gt 0 ]; then
                    # Get the source folder path for this specific level
                    local source_folder=$(get_acl_source_folder "$folder_path" "$deny_level")
                    
                    log_info "Removing deny rules for user '$username' from source folder '$source_folder' (level:$deny_level)"
                    
                    # Remove ALL deny rules for this user from the source folder
                    remove_all_deny_rules_for_user "$source_folder" "$username"
                    
                    # Add execute-only permission if needed for traversal
                    add_execute_only_if_needed "$source_folder" "$username"
                fi
            done < "$temp_deny_file"
            
            rm -f "$temp_deny_file"
        fi
    done
}

# Function to remove all deny rules for a specific user from a folder
remove_all_deny_rules_for_user() {
    local target_folder="$1"
    local username="$2"
    
    if [ ! -d "$target_folder" ]; then
        log_warn "Target folder does not exist: $target_folder"
        return 1
    fi
    
    log_info "Removing all deny rules for user '$username' from '$target_folder'"
    
    # Keep removing deny rules until none are found
    local removed_something=true
    while [ "$removed_something" = true ]; do
        removed_something=false
        
        # Get fresh ACL each time
        local current_acl=$(synoacltool -get "$target_folder" 2>/dev/null)
        if [ -z "$current_acl" ]; then
            break
        fi
        
        # Find the first deny rule for this user (any level)
        local deny_line=$(echo "$current_acl" | grep -n "user:$username:deny:" | head -1)
        
        if [ -n "$deny_line" ]; then
            # Extract the ACL index
            local acl_index=$(echo "$deny_line" | sed -n 's/.*\[\([0-9]\+\)\].*/\1/p')
            
            if [ -n "$acl_index" ]; then
                log_info "Removing deny rule at index $acl_index for user '$username' from '$target_folder'"
                if synoacltool -del "$target_folder" "$acl_index" >/dev/null 2>&1; then
                    removed_something=true
                else
                    log_warn "Failed to remove deny rule at index $acl_index"
                    break
                fi
            fi
        fi
    done
}

# Function to add execute-only permission if user has no access
add_execute_only_if_needed() {
    local target_folder="$1"
    local username="$2"
    
    # Check if user has any allow rules in the target folder
    local current_acl=$(synoacltool -get "$target_folder" 2>/dev/null)
    local existing_allow=$(echo "$current_acl" | grep "user:$username:allow:")
    
    if [ -z "$existing_allow" ]; then
        log_info "User '$username' has no access to '$target_folder' - adding execute-only for traversal"
        synoacltool -add "$target_folder" "user:$username:allow:--x----------:fd--" 2>/dev/null || log_warn "Failed to add execute permission"
    else
        log_info "User '$username' already has some access to '$target_folder'"
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
    
    # Add new ACL entry (no need to remove existing since we clean all level:0 entries first)
    synoacltool -add "$folder_path" "user:$username:allow:$acl_perms:fd--"
    
    if [ $? -eq 0 ]; then
        log_info "Successfully applied ACL for user $username"
    else
        log_error "Failed to apply ACL for user $username"
        return 1
    fi
}

# Function to remove ACL for users not in database
# Function to apply ACL permissions to a folder

# Function to apply ACL permissions to a folder

# Function to deny users who have inherited permissions but no database permissions
deny_inherited_unauthorized_users() {
    local folder_path=$1
    local authorized_users=$2
    
    log_info "Checking for users with inherited permissions but no database access"
    log_info "Authorized users: [$authorized_users]"
    
    # Get users with level:1 (inherited) allow permissions (excluding system users and admin group)
    local inherited_users=$(synoacltool -get "$folder_path" | grep "user:.*:allow:.*level:1" | sed 's/.*user:\([^:]*\):.*/\1/' | grep -v -E "^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal)$")
    log_info "Found inherited users: [$inherited_users]"
    
    for user in $inherited_users; do
        log_info "Checking user: $user"
        if ! echo "$authorized_users" | grep -q "\b$user\b"; then
            log_info "User '$user' is NOT in authorized list - checking for level:0 deny rule"
            # Check if user already has a level:0 deny entry
            local existing_level0_deny=$(synoacltool -get "$folder_path" | grep "user:$user:deny:.*level:0")
            if [ -z "$existing_level0_deny" ]; then
                log_info "User '$user' has inherited permissions but no database access - adding explicit deny rule"
                # Add explicit deny rule at level:0 to override inherited allow at level:1
                synoacltool -add "$folder_path" "user:$user:deny:rwxpdDaARWcCo:fd--"
                if [ $? -eq 0 ]; then
                    log_info "Successfully added deny rule for user $user"
                else
                    log_error "Failed to add deny rule for user $user"
                fi
            else
                log_info "User '$user' already has level:0 deny rule, no action needed"
            fi
        else
            log_info "User '$user' IS in authorized list - ensuring no deny rule blocks access"
            # Check if user has a level:0 deny rule that would block their authorized access
            local existing_level0_deny=$(synoacltool -get "$folder_path" | grep "user:$user:deny:.*level:0")
            if [ -n "$existing_level0_deny" ]; then
                log_warn "User '$user' is authorized but has level:0 deny rule - this should be reviewed"
            fi
        fi
    done
}

# Main function to sync permissions for a folder
sync_folder_permissions() {
    local folder_id=$1
    
    # Special handling for root folder (ID=1)
    if [ "$folder_id" = "1" ]; then
        log_warn "Root folder (ID=1) detected - applying special root folder strategy"
        apply_root_folder_strategy
        return $?
    fi
    
    log_info "Starting permission sync for folder ID: $folder_id"
    
    # Get folder path
    local folder_path=$(get_folder_path $folder_id)
    log_info "Folder path: $folder_path"
    
    if [ ! -d "$folder_path" ]; then
        log_error "Folder does not exist: $folder_path"
        return 1
    fi
    
    # STEP 1: Clean all level:0 ACL entries to start fresh
    clean_all_level0_acl_entries "$folder_path"
    
    # STEP 1.5: Remove inherited deny rules for users who should have access
    remove_inherited_deny_rules_for_authorized_users "$folder_path" "$folder_id"
    
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
        
        # STEP 2: Apply permissions for each authorized user
        local temp_file="/tmp/permissions.tmp"
        echo "$permissions" > "$temp_file"
        while IFS=: read -r username perm; do
            if [ ! -z "$username" ] && [ ! -z "$perm" ]; then
                apply_acl_permissions "$folder_path" "$username" "$perm"
                # IMMEDIATELY handle parent traversal for this user to avoid inherited deny conflicts
                replace_parent_deny_with_execute "$folder_path" "$username"
            fi
        done < "$temp_file"
        rm -f "$temp_file"
    fi
    
    # STEP 3: Add explicit deny rules for unauthorized users
    # This includes users who have root folder access but no permission for THIS specific folder
    local all_users=$(get_all_system_users)
    local users_with_any_subfolder_access=$(get_users_with_any_folder_permissions)
    
    for user in $all_users; do
        # Skip if user is authorized for THIS folder
        if echo "$authorized_users" | grep -q "\b$user\b"; then
            continue
        fi
        
        # Skip system users that shouldn't be modified
        if [[ "$user" =~ ^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal|guest|admin|root|chef)$ ]]; then
            continue
        fi
        
        # Add explicit deny rule for unauthorized users
        # This is CRITICAL: users who have root access due to other folder permissions
        # must be explicitly denied access to folders they don't have permission for
        if echo "$users_with_any_subfolder_access" | grep -q "^$user$"; then
            log_info "Adding explicit deny rule for user '$user' (has root access but no permission for this folder)"
        else
            log_info "Adding explicit deny rule for unauthorized user '$user'"
        fi
        synoacltool -add "$folder_path" "user:$user:deny:rwxpdDaARWcCo:fd--" 2>/dev/null || true
    done
    
    log_info "Permission sync completed for folder ID: $folder_id"
}

# Function to remove conflicting deny rules from current directory and parent directories
remove_local_conflicting_deny_rules() {
    local folder_path="$1"
    local authorized_users="$2"
    
    # Only proceed if we have authorized users (i.e., we're granting access)
    if [ -z "$authorized_users" ]; then
        log_info "No authorized users for $folder_path - skipping deny rule cleanup"
        return 0
    fi
    
    log_info "Checking for conflicting deny rules for: $folder_path"
    
    # Process each authorized user
    for user in $authorized_users; do
        # Skip empty usernames
        if [ -z "$user" ]; then continue; fi
        
        log_info "Checking for conflicting deny rules for user '$user'"
        
        # Step 1: Remove level:0 deny rules from current directory
        remove_level0_deny_rules_from_directory "$folder_path" "$user"
        
        # Step 2: Check if user has inherited deny rules that would conflict
        if has_inherited_deny_rule "$folder_path" "$user"; then
            log_info "User '$user' has inherited deny rule - replacing parent deny with execute-only"
            # Replace parent deny rules with execute-only permissions for traversal
            replace_parent_deny_with_execute "$folder_path" "$user"
        fi
    done
}

# Function to remove level:0 deny rules for a user from a specific directory
remove_level0_deny_rules_from_directory() {
    local target_path="$1"
    local user="$2"
    
    # Check if directory has ACL
    if ! synoacltool -get "$target_path" >/dev/null 2>&1; then
        return 0
    fi
    
    # Keep removing level:0 deny rules until none are found
    local removed_something=true
    while [ "$removed_something" = true ]; do
        removed_something=false
        
        # Get fresh ACL each time
        local current_acl=$(synoacltool -get "$target_path" 2>/dev/null)
        if [ -z "$current_acl" ]; then
            break
        fi
        
        # Find ONLY level:0 deny rules for this user
        local deny_line=$(echo "$current_acl" | grep -n "user:$user:deny:" | grep "level:0" | head -1)
        
        if [ -n "$deny_line" ]; then
            # Extract the ACL index from the bracketed number in the line
            local acl_index=$(echo "$deny_line" | sed -n 's/.*\[\([0-9]\+\)\].*/\1/p')
            
            if [ -n "$acl_index" ]; then
                log_info "Removing level:0 deny rule for user '$user' from '$target_path' at index $acl_index"
                if synoacltool -del "$target_path" "$acl_index" >/dev/null 2>&1; then
                    log_info "Successfully removed level:0 deny rule for user '$user' from '$target_path'"
                    removed_something=true
                else
                    log_warn "Failed to remove level:0 deny rule for user '$user' from '$target_path'"
                    break
                fi
            fi
        fi
    done
}

# Function to check if user has any inherited deny rules in current directory
has_inherited_deny_rule() {
    local folder_path="$1"
    local user="$2"
    
    # Check if directory has ACL
    if ! synoacltool -get "$folder_path" >/dev/null 2>&1; then
        return 1
    fi
    
    # Check for any level > 0 deny rules for this user
    local inherited_deny=$(synoacltool -get "$folder_path" 2>/dev/null | grep "user:$user:deny:" | grep -v "level:0")
    
    if [ -n "$inherited_deny" ]; then
        return 0  # Has inherited deny rule
    else
        return 1  # No inherited deny rule
    fi
}

# Function to replace parent deny rules with execute-only permissions for a specific user
replace_parent_deny_with_execute() {
    local folder_path="$1"
    local user="$2"
    
    # Get parent folder path (remove last component)
    local parent_path=$(dirname "$folder_path")
    
    # Don't process if we've reached the root photo directory
    if [ "$parent_path" = "/volume1/photo" ] || [ "$parent_path" = "/" ]; then
        return 0
    fi
    
    # Check if parent directory has ACL
    if ! synoacltool -get "$parent_path" >/dev/null 2>&1; then
        log_info "Parent directory $parent_path has no ACL, skipping"
        return 0
    fi
    
    # Check if user has database permission for parent - if yes, don't change anything
    local parent_folder_id=$(get_folder_id_from_path "$parent_path")
    if [ -n "$parent_folder_id" ]; then
        if user_has_database_permission "$parent_folder_id" "$user"; then
            log_info "User '$user' has database permission for parent '$parent_path' - no need to change"
            return 0
        fi
    fi
    
    # Check if user already has level:0 allow access to parent (from current folder processing)
    local existing_level0_allow=$(synoacltool -get "$parent_path" 2>/dev/null | grep "user:$user:allow:.*level:0")
    if [ -n "$existing_level0_allow" ]; then
        log_info "User '$user' already has level:0 allow access to parent '$parent_path' - no need to add execute-only"
        # Still need to recurse to check grandparents
        replace_parent_deny_with_execute "$parent_path" "$user"
        return 0
    fi
    
    log_info "User '$user' needs traversal access to parent '$parent_path' but no database permission - replacing deny with execute-only"
    
    # Get fresh ACL
    local parent_acl=$(synoacltool -get "$parent_path" 2>/dev/null)
    
    # Find and remove ALL deny rules for this user (level:0, level:1, level:2, etc.)
    # because deny rules block access to ALL child folders
    local all_deny_entries=$(echo "$parent_acl" | grep "user:$user:deny:")
    
    if [ -n "$all_deny_entries" ]; then
        log_info "Found deny rules for user '$user' in parent - removing all to prevent child folder blocking"
        
        # Remove all deny rules in reverse order to maintain index validity
        local deny_indices=$(echo "$parent_acl" | grep -n "user:$user:deny:" | sed 's/\([0-9]*\):.*\[\([0-9]*\)\].*/\2/' | sort -nr)
        
        for acl_index in $deny_indices; do
            log_info "Removing deny rule at index $acl_index from parent '$parent_path'"
            if synoacltool -del "$parent_path" "$acl_index" 2>/dev/null; then
                log_info "Successfully removed deny rule for user '$user' at index $acl_index"
            else
                log_warn "Failed to remove deny rule at index $acl_index"
            fi
            # Refresh ACL after each deletion
            parent_acl=$(synoacltool -get "$parent_path" 2>/dev/null)
        done
        
        # Add execute-only permission for traversal (but not read)
        log_info "Adding execute-only permission for user '$user' on parent '$parent_path'"
        if synoacltool -add "$parent_path" "user:$user:allow:--x----------:fd--" 2>/dev/null; then
            log_info "Successfully added execute-only permission for traversal"
        else
            log_warn "Failed to add execute permission"
        fi
    else
        # No deny rules found, but check if user has any access at all
        local any_allow_entries=$(echo "$parent_acl" | grep "user:$user:allow:")
        if [ -z "$any_allow_entries" ]; then
            log_info "User '$user' has no access to parent '$parent_path' - adding execute-only for traversal"
            synoacltool -add "$parent_path" "user:$user:allow:--x----------:fd--" 2>/dev/null || log_warn "Failed to add execute permission"
        else
            log_info "User '$user' already has some access to parent '$parent_path' - checking if it's sufficient for traversal"
        fi
    fi
    
    # Recursively check grandparent directories
    replace_parent_deny_with_execute "$parent_path" "$user"
}

# Function to get folder ID from filesystem path
get_folder_id_from_path() {
    local folder_path="$1"
    # Convert filesystem path to database path format
    local db_path="${folder_path#/volume1/photo}"
    if [ -z "$db_path" ]; then
        db_path="/"
    fi
    
    # Query database for folder ID
    su - postgres -c "psql -d synofoto -t -A -c \"SELECT id FROM folder WHERE name = '$db_path';\"" 2>/dev/null
}

# Function to check if user has database permission for a specific folder
user_has_database_permission() {
    local folder_id="$1"
    local username="$2"
    
    # Query database to check if user has permission for this folder
    local permission=$(su - postgres -c "psql -d synofoto -t -A -c \"
SELECT sp.permission
FROM share_permission sp
JOIN user_info ui ON sp.target_id = ui.id
JOIN folder f ON f.passphrase_share = sp.passphrase_share
WHERE f.id = $folder_id AND ui.name = '$username' AND sp.permission > 0;
\"" 2>/dev/null)
    
    if [ -n "$permission" ]; then
        return 0  # User has permission
    else
        return 1  # User does not have permission
    fi
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
    
    # Special note for root folder
    if [ "$folder_id" = "1" ]; then
        echo "NOTE: Root folder (ID=1) uses special permission strategy"
        echo "      Users with ANY subfolder permissions get read+execute on root"
    fi
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
