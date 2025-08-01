#!/bin/bash

# Permission Audit Script
# This script compares Synology Photos database permissions with actual filesystem access
# and provides a comprehensive report of alignment and discrepancies

# Set up logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/permission_audit_$(date +%Y%m%d_%H%M%S).log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function to log to both console and file
log_to_file() {
    echo "$1" | tee -a "$LOG_FILE"
}

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

log_audit() {
    echo -e "${BLUE}[AUDIT]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_mismatch() {
    echo -e "${MAGENTA}[MISMATCH]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to get all users from database
get_all_users() {
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT name FROM user_info 
WHERE name NOT LIKE '/volume1%' 
  AND name != '' 
  AND name IS NOT NULL
  AND name NOT IN ('guest', 'admin', 'root', 'chef', 'temp_adm')
ORDER BY name;
" 2>/dev/null | grep -v "^$"
}

# Function to get all shared folders from database
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

# Function to get database permissions for a specific folder and user
get_db_permission() {
    local folder_id=$1
    local username=$2
    
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT sp.permission
FROM share_permission sp
JOIN user_info ui ON sp.target_id = ui.id
JOIN folder f ON f.passphrase_share = sp.passphrase_share
WHERE f.id = $folder_id 
  AND ui.name = '$username' 
  AND sp.permission > 0;
" 2>/dev/null | head -1
}

# Function to test filesystem access for a user
test_filesystem_access() {
    local username=$1
    local folder_path=$2
    
    # Escape the folder path properly for shell execution
    local escaped_path=$(printf '%q' "$folder_path")
    
    # Test if user can actually read/list the directory contents
    if su "$username" -s /bin/bash -c "ls $escaped_path >/dev/null 2>&1"; then
        # User can list directory contents - they have full read access
        echo "accessible"
        return
    fi
    
    # Cannot list directory - check if they have execute-only (traversal) access
    # by testing if they can change into the directory
    if su "$username" -s /bin/bash -c "cd $escaped_path 2>/dev/null && pwd >/dev/null 2>&1"; then
        # Can access directory but not list it - execute-only (traversal)
        # This is used for parent folders where users need to traverse to reach child folders
        # but shouldn't have access to the parent folder contents
        echo "traversal_only"
    else
        # Cannot even access the directory - explicit deny or no permissions
        echo "denied"
    fi
}

# Function to check comprehensive ACL inheritance
check_comprehensive_acl() {
    local username=$1
    local folder_path=$2
    
    # Get all ACL entries for this user (all inheritance levels)
    local acl_entries=$(synoacltool -get "$folder_path" 2>/dev/null | grep "user:$username:" || true)
    
    if [ -z "$acl_entries" ]; then
        echo "no_acl"
        return
    fi
    
    # Check if user has explicit level 0 permissions (these override inheritance)
    local has_level0=$(echo "$acl_entries" | grep "level:0" || true)
    
    # Check if user has any allow permissions at any level
    local has_allow=$(echo "$acl_entries" | grep -E ":(allow|ALLOW):" | grep -E ":(r|read)" || true)
    
    # Check if user has explicit deny at level 0 (which overrides inheritance)
    local has_level0_deny=$(echo "$acl_entries" | grep "level:0" | grep -E ":(deny|DENY):" || true)
    
    if [ -n "$has_level0_deny" ]; then
        echo "explicit_deny_level0"
    elif [ -n "$has_level0" ]; then
        echo "has_level0_explicit"
    elif [ -n "$has_allow" ]; then
        echo "inherited_allow_only"
    else
        echo "no_access"
    fi
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

# Function to check if folder exists on filesystem
folder_exists() {
    local folder_path=$1
    # Use stat instead of -d test since -d might fail with restrictive permissions
    stat "$folder_path" >/dev/null 2>&1
}

# Function to run summary audit (without detailed folder output)
run_summary_audit() {
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "        SYNOLOGY PHOTOS PERMISSION AUDIT SUMMARY" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Started at: $(date)" | tee -a "$LOG_FILE"
    echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    log_audit "Running quick alignment check across all folders..."
    echo
    
    local total_folders=0
    local aligned_folders=0
    local misaligned_folders=0
    local missing_folders=0
    local total_mismatches=0
    
    # Arrays to track problematic folders
    local misaligned_folder_list=()
    local missing_folder_list=()
    
    # Arrays to track categorized issues per user
    declare -A missing_permissions_users  # Users who should have access but are denied
    declare -A over_privileged_users      # Users who shouldn't have access but can see files
    declare -A missing_permissions_folders
    declare -A over_privileged_folders
    
    # Process each shared folder silently
    while IFS='|' read -r folder_id folder_name; do
        if [ -z "$folder_id" ] || [ -z "$folder_name" ]; then continue; fi
        
        ((total_folders++))
        
        local folder_path=$(get_folder_path "$folder_name")
        if ! folder_exists "$folder_path"; then
            ((missing_folders++))
            missing_folder_list+=("$folder_id|$folder_name")
            continue
        fi
        
        local folder_mismatches=0
        
        # Check each user for this folder
        while IFS= read -r username; do
            if [ -z "$username" ]; then continue; fi
            
            # Get database permission
            local db_perm=$(get_db_permission "$folder_id" "$username")
            local has_db_access="false"
            if [ -n "$db_perm" ] && [ "$db_perm" -gt 0 ]; then
                has_db_access="true"
            fi
            
            # Test filesystem access
            local fs_access=$(test_filesystem_access "$username" "$folder_path")
            local has_fs_access="false"
            if [ "$fs_access" = "accessible" ]; then
                has_fs_access="true"
            fi
            # Note: traversal_only access is considered aligned with no DB permission
            # since it allows navigation to child folders without parent folder access
            
            # Check alignment - consider traversal_only as aligned when no DB permission
            # This allows parent folder traversal for child access without full parent access
            local is_aligned="false"
            if [ "$has_db_access" = "$has_fs_access" ]; then
                is_aligned="true"
            elif [ "$has_db_access" = "false" ] && [ "$fs_access" = "traversal_only" ]; then
                # Special case: no DB permission + traversal_only = aligned
                # This allows navigation to child folders without parent folder access
                is_aligned="true"
            elif [ "$folder_id" = "1" ] && [ "$has_db_access" = "false" ] && [ "$has_fs_access" = "true" ]; then
                # Special case for root folder (ID=1): users with no DB permission but FS access
                # are aligned due to root folder strategy that grants access for folder discovery
                is_aligned="true"
            fi
            
            if [ "$is_aligned" != "true" ]; then
                ((folder_mismatches++))
                ((total_mismatches++))
                
                # Categorize the mismatch
                if [ "$has_db_access" = "true" ] && [ "$has_fs_access" = "false" ]; then
                    # Missing permissions: DB says OK but FS is denied
                    missing_permissions_users["$username"]=$((${missing_permissions_users["$username"]:-0} + 1))
                    missing_permissions_folders["$username"]+="$folder_id ($folder_name), "
                elif [ "$has_db_access" = "false" ] && [ "$has_fs_access" = "true" ]; then
                    # Over privileges: No DB permission but FS is accessible (can see files)
                    # Note: Skip root folder (ID=1) as this is expected due to root folder strategy
                    if [ "$folder_id" != "1" ]; then
                        over_privileged_users["$username"]=$((${over_privileged_users["$username"]:-0} + 1))
                        over_privileged_folders["$username"]+="$folder_id ($folder_name), "
                    fi
                fi
            fi
            
        done < <(get_all_users)
        
        if [ "$folder_mismatches" -eq 0 ]; then
            ((aligned_folders++))
        else
            ((misaligned_folders++))
            misaligned_folder_list+=("$folder_id|$folder_name|$folder_mismatches")
            log_warn "Folder $folder_id ($folder_name): $folder_mismatches mismatches"
        fi
        
    done < <(get_all_shared_folders | tr '\t' '|')
    
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "                SUMMARY RESULTS" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Completed at: $(date)" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    log_audit "Overall Statistics:"
    log_audit "  Total shared folders: $total_folders"
    log_audit "  Fully aligned folders: $aligned_folders"
    log_audit "  Misaligned folders: $misaligned_folders"
    log_audit "  Missing folders: $missing_folders"
    log_audit "  Total individual mismatches: $total_mismatches"
    echo
    
    if [ "$misaligned_folders" -eq 0 ] && [ "$missing_folders" -eq 0 ]; then
        log_success "🎉 ALL FOLDERS ARE PERFECTLY ALIGNED!"
        log_success "Database permissions match filesystem access for all users and folders."
    else
        log_warn "⚠ MISALIGNMENTS DETECTED:"
        if [ "$misaligned_folders" -gt 0 ]; then
            log_warn "  - $misaligned_folders folders have permission mismatches"
            log_warn "  - $total_mismatches total individual user/folder mismatches"
        fi
        if [ "$missing_folders" -gt 0 ]; then
            log_warn "  - $missing_folders folders are missing from filesystem"
        fi
        echo
        log_audit "Recommendations:"
        log_audit "  1. Run 'fix_ownership.sh fix-all' to fix ownership issues"
        log_audit "  2. Run 'batch_sync.sh' to sync all folder permissions"
        log_audit "  3. Run 'permission_audit.sh full-audit' for detailed analysis"
        log_audit "  4. Re-run this audit to verify fixes"
    fi
    
    echo
    local success_rate=$(( (aligned_folders * 100) / total_folders ))
    log_audit "Alignment Success Rate: $success_rate%"
    
    # Display detailed list of problematic folders
    if [ "$misaligned_folders" -gt 0 ] || [ "$missing_folders" -gt 0 ]; then
        echo
        echo "======================================================" | tee -a "$LOG_FILE"
        echo "           DETAILED LIST OF FOLDERS WITH ISSUES" | tee -a "$LOG_FILE"
        echo "======================================================" | tee -a "$LOG_FILE"
        
        if [ "$misaligned_folders" -gt 0 ]; then
            echo | tee -a "$LOG_FILE"
            log_error "MISALIGNED FOLDERS ($misaligned_folders found):"
            echo "ID   | Mismatches | Folder Name" | tee -a "$LOG_FILE"
            echo "-----|------------|------------------------------------------" | tee -a "$LOG_FILE"
            for folder_info in "${misaligned_folder_list[@]}"; do
                IFS='|' read -r folder_id folder_name mismatch_count <<< "$folder_info"
                printf "%-4s | %-10s | %s\n" "$folder_id" "$mismatch_count" "$folder_name" | tee -a "$LOG_FILE"
            done
        fi
        
        if [ "$missing_folders" -gt 0 ]; then
            echo | tee -a "$LOG_FILE"
            log_error "MISSING FOLDERS ($missing_folders found):"
            echo "ID   | Folder Name" | tee -a "$LOG_FILE"
            echo "-----|------------------------------------------" | tee -a "$LOG_FILE"
            for folder_info in "${missing_folder_list[@]}"; do
                IFS='|' read -r folder_id folder_name <<< "$folder_info"
                printf "%-4s | %s\n" "$folder_id" "$folder_name" | tee -a "$LOG_FILE"
            done
        fi
    fi
    
    # Display categorized permission analysis
    if [ ${#missing_permissions_users[@]} -gt 0 ] || [ ${#over_privileged_users[@]} -gt 0 ]; then
        echo
        echo "======================================================" | tee -a "$LOG_FILE"
        echo "           CATEGORIZED PERMISSION ANALYSIS" | tee -a "$LOG_FILE"
        echo "======================================================" | tee -a "$LOG_FILE"
        
        # Missing Permissions Category
        if [ ${#missing_permissions_users[@]} -gt 0 ]; then
            echo | tee -a "$LOG_FILE"
            log_error "🚫 MISSING PERMISSIONS (DB permits but FS denies access):"
            echo "These users should have access according to the database but are denied by the filesystem:" | tee -a "$LOG_FILE"
            echo | tee -a "$LOG_FILE"
            echo "User                | Folders Affected | Folder List" | tee -a "$LOG_FILE"
            echo "--------------------|------------------|------------------------------------------" | tee -a "$LOG_FILE"
            
            for username in "${!missing_permissions_users[@]}"; do
                local count=${missing_permissions_users["$username"]}
                local folder_list=${missing_permissions_folders["$username"]}
                # Remove trailing comma and space
                folder_list=$(echo "$folder_list" | sed 's/, $//')
                printf "%-19s | %-16s | %s\n" "$username" "$count" "$folder_list" | tee -a "$LOG_FILE"
            done
        fi
        
        # Over Privileges Category  
        if [ ${#over_privileged_users[@]} -gt 0 ]; then
            echo | tee -a "$LOG_FILE"
            log_error "⚠️  OVER PRIVILEGES (No DB permission but FS allows file access):"
            echo "These users can see/access files on the filesystem but shouldn't according to the database:" | tee -a "$LOG_FILE"
            echo | tee -a "$LOG_FILE"
            echo "User                | Folders Affected | Folder List" | tee -a "$LOG_FILE"
            echo "--------------------|------------------|------------------------------------------" | tee -a "$LOG_FILE"
            
            for username in "${!over_privileged_users[@]}"; do
                local count=${over_privileged_users["$username"]}
                local folder_list=${over_privileged_folders["$username"]}
                # Remove trailing comma and space
                folder_list=$(echo "$folder_list" | sed 's/, $//')
                printf "%-19s | %-16s | %s\n" "$username" "$count" "$folder_list" | tee -a "$LOG_FILE"
            done
        fi
        
        echo | tee -a "$LOG_FILE"
        log_audit "Category Summary:"
        log_audit "  Users with missing permissions: ${#missing_permissions_users[@]}"
        log_audit "  Users with over privileges: ${#over_privileged_users[@]}"
    fi
    
    # Return appropriate exit code
    if [ "$misaligned_folders" -eq 0 ] && [ "$missing_folders" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}
audit_folder() {
    local folder_id=$1
    local folder_name=$2
    local folder_path=$(get_folder_path "$folder_name")
    
    if ! folder_exists "$folder_path"; then
        log_warn "Folder $folder_id ($folder_name) does not exist on filesystem"
        return 1
    fi
    
    echo "----------------------------------------"
    log_audit "Auditing Folder ID: $folder_id"
    log_audit "Folder Name: $folder_name"
    log_audit "Folder Path: $folder_path"
    echo
    
    local total_users=0
    local aligned_users=0
    local mismatched_users=0
    local db_accessible_users=0
    local fs_accessible_users=0
    
    # Get all users and check their permissions
    while IFS= read -r username; do
        if [ -z "$username" ]; then continue; fi
        
        ((total_users++))
        
        # Get database permission
        local db_perm=$(get_db_permission "$folder_id" "$username")
        local has_db_access="false"
        if [ -n "$db_perm" ] && [ "$db_perm" -gt 0 ]; then
            has_db_access="true"
            ((db_accessible_users++))
        fi
        
        # Test filesystem access
        local fs_access=$(test_filesystem_access "$username" "$folder_path")
        local has_fs_access="false"
        if [ "$fs_access" = "accessible" ]; then
            has_fs_access="true"
            ((fs_accessible_users++))
        fi
        # Note: traversal_only access is considered aligned with no DB permission
        # since it allows navigation to child folders without parent folder access
        
        # For detailed debugging of mismatches, check ACL details
        local acl_analysis=""
        local is_aligned="false"
        
        # Check alignment - consider traversal_only as aligned when no DB permission
        # This allows parent folder traversal for child access without full parent access
        if [ "$has_db_access" = "$has_fs_access" ]; then
            is_aligned="true"
        elif [ "$has_db_access" = "false" ] && [ "$fs_access" = "traversal_only" ]; then
            # Special case: no DB permission + traversal_only = aligned
            # This allows navigation to child folders without parent folder access
            is_aligned="true"
        elif [ "$folder_id" = "1" ] && [ "$has_db_access" = "false" ] && [ "$has_fs_access" = "true" ]; then
            # Special case for root folder (ID=1): users with no DB permission but FS access
            # are aligned due to root folder strategy that grants access for folder discovery
            is_aligned="true"
        else
            acl_analysis=$(check_comprehensive_acl "$username" "$folder_path")
        fi
        
        # Check alignment
        if [ "$is_aligned" = "true" ]; then
            ((aligned_users++))
            if [ "$has_db_access" = "true" ]; then
                log_success "  ✓ $username: DB permission ($db_perm) + FS accessible - ALIGNED"
            else
                if [ "$fs_access" = "traversal_only" ]; then
                    log_success "  ✓ $username: No DB permission + FS traversal-only - ALIGNED (traversal for child access)"
                elif [ "$folder_id" = "1" ] && [ "$fs_access" = "accessible" ]; then
                    log_success "  ✓ $username: No DB permission + FS accessible - ALIGNED (root folder strategy for discovery)"
                else
                    log_success "  ✓ $username: No DB permission + FS denied - ALIGNED"
                fi
            fi
        else
            ((mismatched_users++))
            if [ "$has_db_access" = "true" ] && [ "$has_fs_access" = "false" ]; then
                if [ "$fs_access" = "traversal_only" ]; then
                    log_mismatch "  ✗ $username: Has DB permission ($db_perm) but only FS TRAVERSAL - MISMATCH (ACL: $acl_analysis)"
                else
                    log_mismatch "  ✗ $username: Has DB permission ($db_perm) but FS DENIED - MISMATCH (ACL: $acl_analysis)"
                fi
            elif [ "$has_db_access" = "false" ] && [ "$has_fs_access" = "true" ]; then
                log_mismatch "  ✗ $username: No DB permission but FS ACCESSIBLE - MISMATCH (ACL: $acl_analysis)"
            fi
        fi
        
    done < <(get_all_users)
    
    echo
    log_audit "Folder Summary:"
    log_audit "  Total users checked: $total_users"
    log_audit "  Users with DB access: $db_accessible_users"
    log_audit "  Users with FS access: $fs_accessible_users"
    log_audit "  Aligned permissions: $aligned_users"
    log_audit "  Mismatched permissions: $mismatched_users"
    
    if [ "$mismatched_users" -eq 0 ]; then
        log_success "  Status: FULLY ALIGNED ✓"
        return 0
    else
        log_warn "  Status: MISALIGNED ($mismatched_users mismatches) ⚠"
        return 1
    fi
}

# Function to run full audit
run_full_audit() {
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "        SYNOLOGY PHOTOS PERMISSION AUDIT" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Started at: $(date)" | tee -a "$LOG_FILE"
    echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    log_audit "Discovering all users and shared folders..."
    echo
    
    local total_folders=0
    local aligned_folders=0
    local misaligned_folders=0
    local missing_folders=0
    
    # Process each shared folder
    while IFS='|' read -r folder_id folder_name; do
        if [ -z "$folder_id" ] || [ -z "$folder_name" ]; then continue; fi
        
        ((total_folders++))
        
        if audit_folder "$folder_id" "$folder_name"; then
            ((aligned_folders++))
        else
            local folder_path=$(get_folder_path "$folder_name")
            if ! folder_exists "$folder_path"; then
                ((missing_folders++))
            else
                ((misaligned_folders++))
            fi
        fi
        echo
        
    done < <(get_all_shared_folders | tr '\t' '|')
    
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "                AUDIT SUMMARY" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Completed at: $(date)" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    log_audit "Overall Statistics:"
    log_audit "  Total shared folders: $total_folders"
    log_audit "  Fully aligned folders: $aligned_folders"
    log_audit "  Misaligned folders: $misaligned_folders"
    log_audit "  Missing folders: $missing_folders"
    echo
    
    if [ "$misaligned_folders" -eq 0 ] && [ "$missing_folders" -eq 0 ]; then
        log_success "🎉 ALL FOLDERS ARE PERFECTLY ALIGNED!"
        log_success "Database permissions match filesystem access for all users and folders."
    else
        log_warn "⚠ MISALIGNMENTS DETECTED:"
        if [ "$misaligned_folders" -gt 0 ]; then
            log_warn "  - $misaligned_folders folders have permission mismatches"
        fi
        if [ "$missing_folders" -gt 0 ]; then
            log_warn "  - $missing_folders folders are missing from filesystem"
        fi
        echo
        log_audit "Recommendations:"
        log_audit "  1. Run 'fix_ownership.sh fix-all' to fix ownership issues"
        log_audit "  2. Run 'batch_sync.sh' to sync all folder permissions"
        log_audit "  3. Re-run this audit to verify fixes"
    fi
    
    echo
    local success_rate=$(( (aligned_folders * 100) / total_folders ))
    log_audit "Alignment Success Rate: $success_rate%"
    
    # Return appropriate exit code
    if [ "$misaligned_folders" -eq 0 ] && [ "$missing_folders" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Function to audit a specific folder
audit_single_folder() {
    local folder_id=$1
    
    echo "======================================================"
    echo "        SINGLE FOLDER PERMISSION AUDIT"
    echo "======================================================"
    echo "Started at: $(date)"
    echo
    
    # Get folder name
    local folder_name=$(sudo -u postgres psql -d synofoto -t -A -c "SELECT name FROM folder WHERE id = $folder_id;" 2>/dev/null)
    
    if [ -z "$folder_name" ]; then
        log_error "Folder ID $folder_id not found in database"
        return 1
    fi
    
    if audit_folder "$folder_id" "$folder_name"; then
        log_success "Folder $folder_id is fully aligned"
        return 0
    else
        log_warn "Folder $folder_id has misalignments"
        return 1
    fi
}

# Function to audit a specific user across all folders
audit_user() {
    local target_user=$1
    
    # Check if user is in excluded list
    if [[ "$target_user" =~ ^(guest|admin|root|chef|temp_adm)$ ]]; then
        log_warn "User '$target_user' is excluded from audit (system/admin user)"
        return 1
    fi
    
    echo "======================================================"
    echo "        USER PERMISSION AUDIT"
    echo "======================================================"
    echo "Started at: $(date)"
    echo "Target User: $target_user"
    echo
    
    local total_folders=0
    local user_has_db_access=0
    local user_has_fs_access=0
    local aligned_folders=0
    local mismatched_folders=0
    
    # Process each shared folder for this user
    while IFS='|' read -r folder_id folder_name; do
        if [ -z "$folder_id" ] || [ -z "$folder_name" ]; then continue; fi
        
        local folder_path=$(get_folder_path "$folder_name")
        if ! folder_exists "$folder_path"; then
            continue
        fi
        
        ((total_folders++))
        
        # Get database permission
        local db_perm=$(get_db_permission "$folder_id" "$target_user")
        local has_db_access="false"
        if [ -n "$db_perm" ] && [ "$db_perm" -gt 0 ]; then
            has_db_access="true"
            ((user_has_db_access++))
        fi
        
        # Test filesystem access
        local fs_access=$(test_filesystem_access "$target_user" "$folder_path")
        local has_fs_access="false"
        if [ "$fs_access" = "accessible" ]; then
            has_fs_access="true"
            ((user_has_fs_access++))
        fi
        # Note: traversal_only access is considered aligned with no DB permission
        # since it allows navigation to child folders without parent folder access
        
        # For detailed debugging of mismatches, check ACL details
        local acl_analysis=""
        local is_aligned="false"
        
        # Check alignment - consider traversal_only as aligned when no DB permission
        # This allows parent folder traversal for child access without full parent access
        if [ "$has_db_access" = "$has_fs_access" ]; then
            is_aligned="true"
        elif [ "$has_db_access" = "false" ] && [ "$fs_access" = "traversal_only" ]; then
            # Special case: no DB permission + traversal_only = aligned
            # This allows navigation to child folders without parent folder access
            is_aligned="true"
        else
            acl_analysis=$(check_comprehensive_acl "$target_user" "$folder_path")
        fi
        
        # Check alignment
        if [ "$is_aligned" = "true" ]; then
            ((aligned_folders++))
            if [ "$has_db_access" = "true" ]; then
                log_success "  ✓ Folder $folder_id ($folder_name): DB perm ($db_perm) + FS access - ALIGNED"
            fi
        else
            ((mismatched_folders++))
            if [ "$has_db_access" = "true" ] && [ "$has_fs_access" = "false" ]; then
                if [ "$fs_access" = "traversal_only" ]; then
                    log_mismatch "  ✗ Folder $folder_id ($folder_name): Has DB perm ($db_perm) but only FS TRAVERSAL (ACL: $acl_analysis)"
                else
                    log_mismatch "  ✗ Folder $folder_id ($folder_name): Has DB perm ($db_perm) but FS DENIED (ACL: $acl_analysis)"
                fi
            elif [ "$has_db_access" = "false" ] && [ "$has_fs_access" = "true" ]; then
                log_mismatch "  ✗ Folder $folder_id ($folder_name): No DB perm but FS ACCESSIBLE (ACL: $acl_analysis)"
            fi
        fi
        
    done < <(get_all_shared_folders | tr '\t' '|')
    
    echo
    log_audit "User Summary for '$target_user':"
    log_audit "  Total folders checked: $total_folders"
    log_audit "  Folders with DB access: $user_has_db_access"
    log_audit "  Folders with FS access: $user_has_fs_access"
    log_audit "  Aligned folders: $aligned_folders"
    log_audit "  Mismatched folders: $mismatched_folders"
    
    if [ "$mismatched_folders" -eq 0 ]; then
        log_success "User '$target_user' has fully aligned permissions across all folders ✓"
        return 0
    else
        log_warn "User '$target_user' has $mismatched_folders misaligned folders ⚠"
        return 1
    fi
}

# Function to debug ACL details for a specific folder and users
debug_acl_details() {
    local folder_id=$1
    local folder_name=$2
    local folder_path=$(get_folder_path "$folder_name")
    
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "        ACL DEBUG ANALYSIS" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Folder ID: $folder_id" | tee -a "$LOG_FILE"
    echo "Folder Name: $folder_name" | tee -a "$LOG_FILE"
    echo "Folder Path: $folder_path" | tee -a "$LOG_FILE"
    echo "Started at: $(date)" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    if ! folder_exists "$folder_path"; then
        log_error "Folder does not exist on filesystem"
        return 1
    fi
    
    # Get the complete ACL dump
    log_info "Complete ACL structure:" | tee -a "$LOG_FILE"
    synoacltool -get "$folder_path" 2>/dev/null | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    # Check each user's specific situation
    log_info "User-by-user analysis:" | tee -a "$LOG_FILE"
    while IFS= read -r username; do
        if [ -z "$username" ]; then continue; fi
        
        # Get database permission
        local db_perm=$(get_db_permission "$folder_id" "$username")
        local has_db_access="false"
        if [ -n "$db_perm" ] && [ "$db_perm" -gt 0 ]; then
            has_db_access="true"
        fi
        
        # Test filesystem access
        local fs_access=$(test_filesystem_access "$username" "$folder_path")
        local has_fs_access="false"
        if [ "$fs_access" = "accessible" ]; then
            has_fs_access="true"
        fi
        
        # Get user's ACL entries
        local user_acl=$(synoacltool -get "$folder_path" 2>/dev/null | grep "user:$username:" || echo "No ACL entries")
        
        # Check alignment
        local is_aligned="false"
        if [ "$has_db_access" = "$has_fs_access" ]; then
            is_aligned="true"
        elif [ "$has_db_access" = "false" ] && [ "$fs_access" = "traversal_only" ]; then
            is_aligned="true"
        fi
        
        if [ "$is_aligned" = "true" ]; then
            log_success "✓ $username: ALIGNED (DB: $has_db_access, FS: $fs_access)" | tee -a "$LOG_FILE"
        else
            log_mismatch "✗ $username: MISMATCH (DB: $has_db_access, FS: $fs_access)" | tee -a "$LOG_FILE"
            log_info "  DB Permission: ${db_perm:-none}" | tee -a "$LOG_FILE"
            log_info "  FS Access: $fs_access" | tee -a "$LOG_FILE"
            log_info "  ACL Entries:" | tee -a "$LOG_FILE"
            echo "    $user_acl" | tee -a "$LOG_FILE"
            
            # Test individual ACL commands for troubleshooting
            log_info "  Manual access tests:" | tee -a "$LOG_FILE"
            echo -n "    ls test: " | tee -a "$LOG_FILE"
            local ls_output=$(su "$username" -s /bin/bash -c "ls '$folder_path' 2>/dev/null")
            local ls_exit_code=$?
            if [ $ls_exit_code -eq 0 ]; then
                local file_count=$(echo "$ls_output" | wc -l)
                if [ -z "$ls_output" ]; then
                    file_count=0
                fi
                echo "SUCCESS (can list, $file_count items visible)" | tee -a "$LOG_FILE"
            else
                echo "FAILED (cannot list)" | tee -a "$LOG_FILE"
            fi
            
            echo -n "    cd test: " | tee -a "$LOG_FILE"
            if su "$username" -s /bin/bash -c "cd '$folder_path' 2>/dev/null && pwd >/dev/null 2>&1"; then
                echo "SUCCESS (can access)" | tee -a "$LOG_FILE"
            else
                echo "FAILED (cannot access)" | tee -a "$LOG_FILE"
            fi
            
            echo -n "    stat test: " | tee -a "$LOG_FILE"
            if su "$username" -s /bin/bash -c "stat '$folder_path' >/dev/null 2>&1"; then
                echo "SUCCESS (can stat)" | tee -a "$LOG_FILE"
            else
                echo "FAILED (cannot stat)" | tee -a "$LOG_FILE"
            fi
            
            # Test read directory permissions specifically
            echo -n "    readdir test: " | tee -a "$LOG_FILE"
            local readdir_output=$(su "$username" -s /bin/bash -c "ls -la '$folder_path' 2>/dev/null | head -10")
            if [ $? -eq 0 ] && [ -n "$readdir_output" ]; then
                echo "SUCCESS (can read directory contents)" | tee -a "$LOG_FILE"
            else
                echo "FAILED (cannot read directory contents - pure traversal only)" | tee -a "$LOG_FILE"
            fi
        fi
        echo | tee -a "$LOG_FILE"
        
    done < <(get_all_users)
    
    # Check parent folder ACLs if this is a subfolder
    if [[ "$folder_name" == */* ]]; then
        local parent_path=$(dirname "$folder_path")
        log_info "Parent folder ACL analysis:" | tee -a "$LOG_FILE"
        log_info "Parent Path: $parent_path" | tee -a "$LOG_FILE"
        synoacltool -get "$parent_path" 2>/dev/null | tee -a "$LOG_FILE"
    fi
    
    return 0
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [command] [options]"
    echo
    echo "Commands:"
    echo "  full-audit           - Audit all users and folders with detailed output (default)"
    echo "  summary              - Quick summary audit without detailed folder output"
    echo "  folder <folder_id>   - Audit specific folder"
    echo "  user <username>      - Audit specific user across all folders"
    echo "  debug <folder_id>    - Debug ACL details for specific folder"
    echo "  help                 - Show this help message"
    echo
    echo "Examples:"
    echo "  $0                   - Run full detailed audit"
    echo "  $0 summary           - Run quick summary audit"
    echo "  $0 folder 432        - Audit folder ID 432"
    echo "  $0 user famille      - Audit user 'famille' across all folders"
    echo "  $0 debug 304         - Debug ACL details for folder ID 304"
    echo
    echo "All results are logged to: logs/permission_audit_YYYYMMDD_HHMMSS.log"
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
    local command=${1:-"full-audit"}
    
    # Validate setup
    if ! validate_setup; then
        exit 1
    fi
    
    case "$command" in
        "full-audit"|"")
            run_full_audit
            exit $?
            ;;
        "summary")
            run_summary_audit
            exit $?
            ;;
        "folder")
            local folder_id=$2
            if [ -z "$folder_id" ]; then
                log_error "Please specify a folder ID"
                show_usage
                exit 1
            fi
            audit_single_folder "$folder_id"
            exit $?
            ;;
        "user")
            local username=$2
            if [ -z "$username" ]; then
                log_error "Please specify a username"
                show_usage
                exit 1
            fi
            audit_user "$username"
            exit $?
            ;;
        "debug")
            local folder_id=$2
            if [ -z "$folder_id" ]; then
                log_error "Please specify a folder ID"
                show_usage
                exit 1
            fi
            # Get folder name
            local folder_name=$(sudo -u postgres psql -d synofoto -t -A -c "SELECT name FROM folder WHERE id = $folder_id;" 2>/dev/null)
            if [ -z "$folder_name" ]; then
                log_error "Folder ID $folder_id not found in database"
                exit 1
            fi
            debug_acl_details "$folder_id" "$folder_name"
            exit $?
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
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
