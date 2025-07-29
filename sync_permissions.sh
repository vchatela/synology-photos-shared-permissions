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

# Function to remove an inherited duplicate by targeting the source folder
remove_inherited_duplicate() {
    local username=$1
    local permission_type=$2  # "allow" or "deny"
    local target_folder=$3
    
    if [[ ! -d "$target_folder" ]]; then
        log_warn "Target folder does not exist: $target_folder"
        return 1
    fi
    
    # Get ACL from target folder
    local target_acl=$(synoacltool -get "$target_folder")
    
    # Find level:0 entries for this user with matching permission type
    local matching_indices=$(echo "$target_acl" | grep "user:$username:" | grep ":$permission_type:" | grep "level:0" | sed 's/.*\[\([0-9]*\)\].*/\1/')
    
    # Count matching entries
    local count=$(echo "$matching_indices" | wc -w)
    
    if [[ $count -eq 0 ]]; then
        log_warn "No level:0 $permission_type entry found for user $username in $target_folder"
        return 1
    elif [[ $count -eq 1 ]]; then
        log_warn "Only one level:0 $permission_type entry found for user $username in $target_folder - cannot remove without causing issues"
        return 1
    else
        # Multiple entries found - remove one (keep the first, remove the second)
        local entries_array=($matching_indices)
        local index_to_remove=${entries_array[1]}  # Remove the second entry
        
        log_info "Removing duplicate level:0 $permission_type entry at index $index_to_remove for $username from $target_folder"
        
        if synoacltool -del "$target_folder" "$index_to_remove" 2>/dev/null; then
            return 0
        else
            log_warn "Failed to remove entry at index $index_to_remove from $target_folder"
            return 1
        fi
    fi
}

# Function to clean up duplicate ACL entries (improved to handle inheritance correctly)
cleanup_acl_duplicates() {
    local folder_path=$1
    
    log_info "Cleaning up duplicate ACL entries for: $folder_path"
    
    # Get current ACL and extract all users with multiple entries
    local acl_output=$(synoacltool -get "$folder_path")
    
    # Find users that appear multiple times (excluding system users)
    local duplicate_users=$(echo "$acl_output" | grep "user:" | sed 's/.*user:\([^:]*\):.*/\1/' | grep -v -E "^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal)$" | sort | uniq -d)
    
    if [ -z "$duplicate_users" ]; then
        log_info "No duplicate user entries found"
        return 0
    fi
    
    # Process each user with duplicates
    local temp_file="/tmp/cleanup_duplicates_$$"
    echo "$duplicate_users" > "$temp_file"
    
    while read -r username; do
        if [ -z "$username" ]; then continue; fi
        
        log_info "Cleaning up duplicate entries for user: $username"
        
        # Get fresh ACL each time (indices change after removals)
        local current_acl=$(synoacltool -get "$folder_path")
        
        # Get all indices for this user, sorted in reverse order for safe removal
        local user_indices=$(echo "$current_acl" | grep "user:$username:" | sed 's/.*\[\([0-9]*\)\].*/\1/' | sort -nr)
        
        # Track what we want to keep - only remove TRUE duplicates of the same type and level
        local kept_level0_allow=""
        local kept_level0_deny=""
        local kept_level1_allow=""
        local kept_level1_deny=""
        local kept_level2_allow=""
        local kept_level2_deny=""
        
        # Process each entry for this user (in reverse order for safe removal)
        for index in $user_indices; do
            local entry_line=$(echo "$current_acl" | grep "\[$index\]")
            
            if [ -z "$entry_line" ]; then continue; fi
            
            # Extract level from entry
            local entry_level=$(echo "$entry_line" | sed 's/.*level:\([0-9]\).*/\1/')
            local target_folder=$(get_acl_source_folder "$folder_path" "$entry_level")
            
            if echo "$entry_line" | grep -q "level:0"; then
                if echo "$entry_line" | grep -q ":allow:"; then
                    if [ -z "$kept_level0_allow" ]; then
                        kept_level0_allow="$index"
                        log_info "Keeping level:0 allow entry at index $index for $username"
                    else
                        log_info "Removing duplicate level:0 allow entry at index $index for $username"
                        synoacltool -del "$target_folder" "$index" 2>/dev/null || log_warn "Failed to remove entry at index $index"
                        # Update ACL after removal
                        current_acl=$(synoacltool -get "$folder_path")
                    fi
                elif echo "$entry_line" | grep -q ":deny:"; then
                    if [ -z "$kept_level0_deny" ]; then
                        kept_level0_deny="$index"
                        log_info "Keeping level:0 deny entry at index $index for $username"
                    else
                        log_info "Removing duplicate level:0 deny entry at index $index for $username"
                        synoacltool -del "$target_folder" "$index" 2>/dev/null || log_warn "Failed to remove entry at index $index"
                        # Update ACL after removal
                        current_acl=$(synoacltool -get "$folder_path")
                    fi
                fi
            elif echo "$entry_line" | grep -q "level:1"; then
                if echo "$entry_line" | grep -q ":allow:"; then
                    if [ -z "$kept_level1_allow" ]; then
                        kept_level1_allow="$index"
                        log_info "Keeping level:1 allow entry at index $index for $username"
                    else
                        log_info "Removing duplicate level:1 allow entry at index $index for $username (targeting $target_folder)"
                        # Find the corresponding level:0 entry in the parent folder to remove
                        if remove_inherited_duplicate "$username" "allow" "$target_folder"; then
                            log_info "Successfully removed inherited duplicate from parent folder"
                            # Update ACL after removal
                            current_acl=$(synoacltool -get "$folder_path")
                        else
                            log_warn "Failed to remove inherited duplicate from parent folder"
                        fi
                    fi
                elif echo "$entry_line" | grep -q ":deny:"; then
                    if [ -z "$kept_level1_deny" ]; then
                        kept_level1_deny="$index"
                        log_info "Keeping level:1 deny entry at index $index for $username"
                    else
                        log_info "Removing duplicate level:1 deny entry at index $index for $username (targeting $target_folder)"
                        if remove_inherited_duplicate "$username" "deny" "$target_folder"; then
                            log_info "Successfully removed inherited duplicate from parent folder"
                            # Update ACL after removal
                            current_acl=$(synoacltool -get "$folder_path")
                        else
                            log_warn "Failed to remove inherited duplicate from parent folder"
                        fi
                    fi
                fi
            elif echo "$entry_line" | grep -q "level:2"; then
                if echo "$entry_line" | grep -q ":allow:"; then
                    if [ -z "$kept_level2_allow" ]; then
                        kept_level2_allow="$index"
                        log_info "Keeping level:2 allow entry at index $index for $username"
                    else
                        log_info "Removing duplicate level:2 allow entry at index $index for $username (targeting $target_folder)"
                        if remove_inherited_duplicate "$username" "allow" "$target_folder"; then
                            log_info "Successfully removed inherited duplicate from grandparent folder"
                            # Update ACL after removal
                            current_acl=$(synoacltool -get "$folder_path")
                        else
                            log_warn "Failed to remove inherited duplicate from grandparent folder"
                        fi
                    fi
                elif echo "$entry_line" | grep -q ":deny:"; then
                    if [ -z "$kept_level2_deny" ]; then
                        kept_level2_deny="$index"
                        log_info "Keeping level:2 deny entry at index $index for $username"
                    else
                        log_info "Removing duplicate level:2 deny entry at index $index for $username (targeting $target_folder)"
                        if remove_inherited_duplicate "$username" "deny" "$target_folder"; then
                            log_info "Successfully removed inherited duplicate from grandparent folder"
                            # Update ACL after removal
                            current_acl=$(synoacltool -get "$folder_path")
                        else
                            log_warn "Failed to remove inherited duplicate from grandparent folder"
                        fi
                    fi
                fi
            fi
        done
        
    done < "$temp_file"
    
    rm -f "$temp_file"
    log_info "ACL cleanup completed for: $folder_path"
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

# Function to override inherited deny rules for authorized users
override_inherited_deny_rules() {
    local folder_path="$1"
    local authorized_users="$2"
    
    log_info "Checking for inherited deny rules that need to be overridden"
    
    # Get all level:1 (inherited) deny rules for users
    local inherited_deny_users=$(synoacltool -get "$folder_path" | grep "user:.*:deny:.*level:1" | sed 's/.*user:\([^:]*\):.*/\1/' | grep -v -E "^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal)$")
    
    for user in $inherited_deny_users; do
        if echo "$authorized_users" | grep -q "\b$user\b"; then
            log_info "User '$user' has database permission but inherited deny rule - ensuring level:0 override"
            
            # Check if user already has a level:0 allow rule
            local existing_level0_allow=$(synoacltool -get "$folder_path" | grep "user:$user:allow:.*level:0")
            
            if [ -n "$existing_level0_allow" ]; then
                log_info "User '$user' already has level:0 allow rule to override inherited deny"
            else
                log_info "User '$user' has no level:0 allow rule - adding one to override inherited deny"
                synoacltool -add "$folder_path" "user:$user:allow:r-x---aARWc--:fd--"
                if [ $? -eq 0 ]; then
                    log_info "Successfully added override allow rule for user $user"
                else
                    log_error "Failed to add override allow rule for user $user"
                fi
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
                # Ensure parent traversal permissions for this user
                replace_parent_deny_with_execute "$folder_path" "$username"
            fi
        done < "$temp_file"
        rm -f "$temp_file"
    fi
    
    # Get all users and add explicit deny rules for unauthorized users
    local all_users=$(get_all_system_users)
    for user in $all_users; do
        # Skip if user is authorized
        if echo "$authorized_users" | grep -q "\b$user\b"; then
            continue
        fi
        
        # Skip system users that shouldn't be modified
        if [[ "$user" =~ ^(backup|webdav_syno-j|unifi|temp_adm|shield|n8n|jeedom|cert-renewal|guest|admin|root|chef)$ ]]; then
            continue
        fi
        
        # Add explicit deny rule for unauthorized users
        # Note: These may be removed later by child folder processing if traversal access is needed
        log_info "Adding explicit deny rule for unauthorized user '$user'"
        synoacltool -add "$folder_path" "user:$user:deny:rwxpdDaARWcCo:fd--" 2>/dev/null || true
    done
    
    # Clean up duplicate ACL entries
    cleanup_acl_duplicates "$folder_path"
    
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
    
    log_info "User '$user' needs traversal access to parent '$parent_path' but no database permission - replacing deny with execute-only"
    
    # Check if user has level:0 deny rules in parent
    local parent_acl=$(synoacltool -get "$parent_path" 2>/dev/null)
    local deny_entries=$(echo "$parent_acl" | grep "user:$user:deny:" | grep "level:0")
    
    if [ -n "$deny_entries" ]; then
        # Remove all level:0 deny rules for this user from parent
        local deny_indices=$(echo "$parent_acl" | grep -n "user:$user:deny:" | grep "level:0" | cut -d: -f1)
        for line_num in $(echo "$deny_indices" | sort -nr); do
            # Convert line number to ACL index
            local acl_index=$(echo "$parent_acl" | sed -n "${line_num}p" | sed 's/.*\[\([0-9]*\)\].*/\1/')
            log_info "Removing deny rule at index $acl_index from parent '$parent_path'"
            synoacltool -del "$parent_path" "$acl_index" 2>/dev/null || log_warn "Failed to remove deny rule"
            # Refresh ACL after deletion
            parent_acl=$(synoacltool -get "$parent_path" 2>/dev/null)
        done
        
        # Add execute-only permission for traversal
        log_info "Adding execute-only permission for user '$user' on parent '$parent_path'"
        synoacltool -add "$parent_path" "user:$user:allow:--x----------:fd--" 2>/dev/null || log_warn "Failed to add execute permission"
    else
        # Check if user already has execute permission
        local exec_entries=$(echo "$parent_acl" | grep "user:$user:allow:" | grep "level:0")
        if [ -z "$exec_entries" ]; then
            log_info "Adding execute-only permission for user '$user' on parent '$parent_path'"
            synoacltool -add "$parent_path" "user:$user:allow:--x----------:fd--" 2>/dev/null || log_warn "Failed to add execute permission"
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
