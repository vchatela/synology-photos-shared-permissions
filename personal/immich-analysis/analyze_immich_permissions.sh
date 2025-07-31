#!/bin/bash

# Permission Gap Analysis Script
# This script analyzes folders where mathilde and valentin have permissions
# and identifies where immich user is missing ANY permission (doesn't need to match their levels)

# Set up logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
EXPORTS_DIR="$SCRIPT_DIR/exports"
LOG_FILE="$LOG_DIR/permission_analysis_$(date +%Y%m%d_%H%M%S).log"

# Create directories if they don't exist
mkdir -p "$LOG_DIR"
mkdir -p "$EXPORTS_DIR"

# Color output for logging
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

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1" | tee -a "$LOG_FILE"
}

log_analysis() {
    echo -e "${CYAN}[ANALYSIS]${NC} $1" | tee -a "$LOG_FILE"
}

log_discrepancy() {
    echo -e "${MAGENTA}[DISCREPANCY]${NC} $1" | tee -a "$LOG_FILE"
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

# Function to get folders where both mathilde and valentin have permissions
get_shared_mathilde_valentin_folders() {
    sudo -u postgres psql -d synofoto -t -A -c "
WITH mathilde_folders AS (
    SELECT DISTINCT f.id, f.name, sp.permission as mathilde_permission
    FROM folder f
    JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
    JOIN user_info ui ON sp.target_id = ui.id
    WHERE ui.name = 'mathilde' 
      AND sp.permission > 0
      AND f.id > 1
      AND f.name IS NOT NULL 
      AND f.name != '/' 
      AND f.name != ''
      AND f.name NOT LIKE '%#recycle%'
      AND f.name NOT LIKE '%@eaDir%'
      AND f.name NOT LIKE '%.__%'
),
valentin_folders AS (
    SELECT DISTINCT f.id, f.name, sp.permission as valentin_permission
    FROM folder f
    JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
    JOIN user_info ui ON sp.target_id = ui.id
    WHERE ui.name = 'valentin' 
      AND sp.permission > 0
      AND f.id > 1
      AND f.name IS NOT NULL 
      AND f.name != '/' 
      AND f.name != ''
      AND f.name NOT LIKE '%#recycle%'
      AND f.name NOT LIKE '%@eaDir%'
      AND f.name NOT LIKE '%.__%'
)
SELECT 
    mf.id, 
    mf.name,
    mf.mathilde_permission,
    vf.valentin_permission
FROM mathilde_folders mf
INNER JOIN valentin_folders vf ON mf.id = vf.id
ORDER BY mf.id;
" 2>/dev/null
}

# Function to get immich user permissions for a specific folder
get_immich_permission() {
    local folder_id=$1
    
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT sp.permission
FROM share_permission sp
JOIN user_info ui ON sp.target_id = ui.id
JOIN folder f ON f.passphrase_share = sp.passphrase_share
WHERE f.id = $folder_id 
  AND ui.name = 'immich' 
  AND sp.permission > 0;
" 2>/dev/null | head -1
}

# Function to decode permission bitmap to role name
decode_permission_role() {
    local permission=$1
    
    case "$permission" in
        1) echo "viewer" ;;
        3) echo "downloader" ;;
        7) echo "uploader" ;;
        15) echo "manager" ;;
        31) echo "admin" ;;
        *) echo "unknown($permission)" ;;
    esac
}

# Function to analyze permission discrepancies
analyze_discrepancies() {
    local output_format=${1:-"console"}  # console, json, or csv
    local output_file=""
    
    if [ "$output_format" = "json" ]; then
        output_file="$EXPORTS_DIR/immich_permission_analysis_$(date +%Y%m%d_%H%M%S).json"
    elif [ "$output_format" = "csv" ]; then
        output_file="$EXPORTS_DIR/immich_permission_analysis_$(date +%Y%m%d_%H%M%S).csv"
    fi
    
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "    IMMICH PERMISSION DISCREPANCY ANALYSIS" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Started at: $(date)" | tee -a "$LOG_FILE"
    echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"
    if [ -n "$output_file" ]; then
        echo "Output file: $output_file" | tee -a "$LOG_FILE"
    fi
    echo | tee -a "$LOG_FILE"
    
    log_analysis "Finding folders where both mathilde and valentin have permissions..."
    
    local total_shared_folders=0
    local immich_missing_count=0
    local immich_has_access_count=0
    
    # Arrays to store results
    declare -a missing_folders
    declare -a compliant_folders
    
    # Start JSON output if requested
    if [ "$output_format" = "json" ]; then
        echo "{" > "$output_file"
        echo "  \"analysis_info\": {" >> "$output_file"
        echo "    \"timestamp\": \"$(date -Iseconds)\"," >> "$output_file"
        echo "    \"description\": \"Analysis of immich user permission gaps vs mathilde/valentin shared folders\"," >> "$output_file"
        echo "    \"analyzed_users\": [\"mathilde\", \"valentin\", \"immich\"]" >> "$output_file"
        echo "  }," >> "$output_file"
        echo "  \"discrepancies\": [" >> "$output_file"
    elif [ "$output_format" = "csv" ]; then
        echo "folder_id,folder_name,mathilde_permission,mathilde_role,valentin_permission,valentin_role,immich_permission,immich_role,recommended_permission,recommended_role,status,issue_type" > "$output_file"
    fi
    
    local json_first=true
    
    # Process each shared folder
    while IFS='|' read -r folder_id folder_name mathilde_perm valentin_perm; do
        if [ -z "$folder_id" ]; then continue; fi
        
        ((total_shared_folders++))
        
        # Get immich permission for this folder
        local immich_perm=$(get_immich_permission "$folder_id")
        
        # Decode role names
        local mathilde_role=$(decode_permission_role "$mathilde_perm")
        local valentin_role=$(decode_permission_role "$valentin_perm")
        local immich_role="none"
        
        # For immich, we just need ANY permission level - doesn't need to match mathilde/valentin
        # Default recommendation is viewer (1) - minimal access to see the folders
        local recommended_perm=1
        local recommended_role="viewer"
        
        local status=""
        local issue_type=""
        
        if [ -z "$immich_perm" ] || [ "$immich_perm" -eq 0 ]; then
            # Immich has no permission - needs any permission
            ((immich_missing_count++))
            status="MISSING"
            issue_type="no_permission"
            immich_role="none"
            missing_folders+=("$folder_id|$folder_name|$recommended_perm|$recommended_role")
            
            log_discrepancy "Folder $folder_id ($folder_name): immich has NO permission"
            log_discrepancy "  Mathilde: $mathilde_role ($mathilde_perm), Valentin: $valentin_role ($valentin_perm)"
            log_discrepancy "  Recommended: Give immich any permission (suggest $recommended_role)"
            
        else
            # Immich has some permission - that's sufficient
            immich_role=$(decode_permission_role "$immich_perm")
            ((immich_has_access_count++))
            status="COMPLIANT"
            issue_type="none"
            compliant_folders+=("$folder_id|$folder_name|$immich_perm|$immich_role")
            
            log_info "Folder $folder_id ($folder_name): immich has permission (sufficient)"
            log_debug "  Mathilde: $mathilde_role ($mathilde_perm), Valentin: $valentin_role ($valentin_perm), Immich: $immich_role ($immich_perm)"
        fi
        
        # Add to output files
        if [ "$output_format" = "json" ]; then
            if [ "$json_first" = false ]; then
                echo "," >> "$output_file"
            fi
            echo "    {" >> "$output_file"
            echo "      \"folder_id\": $folder_id," >> "$output_file"
            echo "      \"folder_name\": \"$folder_name\"," >> "$output_file"
            echo "      \"mathilde\": {\"permission\": $mathilde_perm, \"role\": \"$mathilde_role\"}," >> "$output_file"
            echo "      \"valentin\": {\"permission\": $valentin_perm, \"role\": \"$valentin_role\"}," >> "$output_file"
            echo "      \"immich\": {\"permission\": ${immich_perm:-0}, \"role\": \"$immich_role\"}," >> "$output_file"
            echo "      \"recommended\": {\"permission\": $recommended_perm, \"role\": \"$recommended_role\"}," >> "$output_file"
            echo "      \"status\": \"$status\"," >> "$output_file"
            echo "      \"issue_type\": \"$issue_type\"" >> "$output_file"
            echo -n "    }" >> "$output_file"
            json_first=false
        elif [ "$output_format" = "csv" ]; then
            echo "$folder_id,\"$folder_name\",$mathilde_perm,\"$mathilde_role\",$valentin_perm,\"$valentin_role\",${immich_perm:-0},\"$immich_role\",$recommended_perm,\"$recommended_role\",\"$status\",\"$issue_type\"" >> "$output_file"
        fi
        
        echo | tee -a "$LOG_FILE"
        
    done < <(get_shared_mathilde_valentin_folders)
    
    # Close JSON output
    if [ "$output_format" = "json" ]; then
        echo "" >> "$output_file"
        echo "  ]," >> "$output_file"
        echo "  \"summary\": {" >> "$output_file"
        echo "    \"total_shared_folders\": $total_shared_folders," >> "$output_file"
        echo "    \"immich_has_permission\": $immich_has_access_count," >> "$output_file"
        echo "    \"immich_missing_permission\": $immich_missing_count" >> "$output_file"
        echo "  }" >> "$output_file"
        echo "}" >> "$output_file"
    fi
    
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "                ANALYSIS SUMMARY" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Completed at: $(date)" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    log_analysis "Overall Statistics:"
    log_analysis "  Total folders where mathilde AND valentin have access: $total_shared_folders"
    log_analysis "  Immich has some permission: $immich_has_access_count"
    log_analysis "  Immich missing any permission: $immich_missing_count"
    echo
    
    if [ "$immich_missing_count" -eq 0 ]; then
        log_info "🎉 IMMICH HAS ACCESS TO ALL SHARED FOLDERS!"
        log_info "Immich user has some level of permission on all shared mathilde/valentin folders."
    else
        log_warn "⚠ PERMISSION GAPS DETECTED:"
        log_warn "  - $immich_missing_count folders where immich has NO permission at all"
        echo
        log_analysis "Recommendations:"
        log_analysis "  1. Give immich any permission level (suggest viewer) on missing folders"
        log_analysis "  2. Consider running the permission injection script (when available)"
        log_analysis "  3. Manually verify in Synology Photos admin interface"
    fi
    
    # Display detailed recommendations
    if [ "$immich_missing_count" -gt 0 ]; then
        echo
        echo "======================================================" | tee -a "$LOG_FILE"
        echo "     FOLDERS WHERE IMMICH NEEDS ANY PERMISSION" | tee -a "$LOG_FILE"
        echo "======================================================" | tee -a "$LOG_FILE"
        echo "ID   | Suggested Role   | Folder Name" | tee -a "$LOG_FILE"
        echo "-----|------------------|------------------------------------------" | tee -a "$LOG_FILE"
        for folder_info in "${missing_folders[@]}"; do
            IFS='|' read -r folder_id folder_name rec_perm rec_role <<< "$folder_info"
            printf "%-4s | %-16s | %s\n" "$folder_id" "$rec_role ($rec_perm)" "$folder_name" | tee -a "$LOG_FILE"
        done
    fi
    
    if [ -n "$output_file" ]; then
        echo
        log_info "📁 Detailed results saved to: $output_file"
        if [ "$output_format" = "json" ] && command -v jq &> /dev/null; then
            log_info "📊 JSON file is valid and formatted"
        fi
    fi
    
    # Return appropriate exit code
    if [ "$immich_missing_count" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Function to generate SQL commands for permission injection (RISKY - READ ONLY FOR NOW)
generate_injection_sql() {
    local dry_run=${1:-true}
    local sql_file="$EXPORTS_DIR/immich_permission_injection_$(date +%Y%m%d_%H%M%S).sql"
    
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "    GENERATING PERMISSION INJECTION SQL (DRY RUN)" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "Started at: $(date)" | tee -a "$LOG_FILE"
    echo "SQL file: $sql_file" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
    
    log_warn "🚨 WARNING: This generates SQL commands for database modification"
    log_warn "🚨 NEVER run these commands without thorough testing and backups!"
    echo
    
    # Start SQL file
    cat << 'EOF' > "$sql_file"
-- SYNOLOGY PHOTOS PERMISSION INJECTION SQL
-- WARNING: These commands modify the synofoto database directly
-- ALWAYS backup your database before running these commands!
-- Test on a copy of your database first!

-- IMPORTANT: Simple connection method works:
-- sudo -u postgres psql -d synofoto

-- Generated on: $(date)
-- Purpose: Add immich user permissions to match mathilde/valentin shared folders

BEGIN;

-- Get immich user ID (for reference)
-- SELECT id, name, uid FROM user_info WHERE name = 'immich';

EOF
    
    local commands_generated=0
    
    # Process each shared folder and generate SQL
    while IFS='|' read -r folder_id folder_name mathilde_perm valentin_perm; do
        if [ -z "$folder_id" ]; then continue; fi
        
        # Get immich permission for this folder
        local immich_perm=$(get_immich_permission "$folder_id")
        local recommended_perm=1  # Default to viewer permission
        
        if [ -z "$immich_perm" ] || [ "$immich_perm" -eq 0 ]; then
            # Generate SQL command to give immich downloader permission
            cat << EOF >> "$sql_file"

-- Folder ID: $folder_id, Name: $folder_name
-- Current immich permission: none, Adding: downloader (3)
-- Mathilde: $mathilde_perm, Valentin: $valentin_perm

-- Insert downloader permission for immich user (if they don't have any permission)
INSERT INTO share_permission (passphrase_share, id_user, target_id, target_type, permission)
SELECT 
    f.passphrase_share,
    0,
    ui.id,
    1,
    3
FROM folder f, user_info ui
WHERE f.id = $folder_id 
  AND ui.name = 'immich'
  AND NOT EXISTS (
    SELECT 1 FROM share_permission sp2 
    WHERE sp2.passphrase_share = f.passphrase_share 
      AND sp2.target_id = ui.id
  );

EOF
            ((commands_generated++))
            log_info "Generated SQL for folder $folder_id ($folder_name): adding downloader permission"
        else
            log_debug "Folder $folder_id ($folder_name): immich already has permission ($immich_perm)"
        fi
        
    done < <(get_shared_mathilde_valentin_folders)
    
    cat << 'EOF' >> "$sql_file"

-- COMMIT; -- Uncomment this line to actually apply changes
ROLLBACK; -- Comment this line when you're ready to apply changes

-- After running, verify with:
-- SELECT f.id, f.name, ui.name, sp.permission 
-- FROM folder f
-- JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
-- JOIN user_info ui ON sp.target_id = ui.id
-- WHERE ui.name IN ('mathilde', 'valentin', 'immich')
-- ORDER BY f.id, ui.name;
EOF
    
    log_info "SQL generation completed!"
    log_info "Commands generated: $commands_generated"
    log_info "SQL file: $sql_file"
    echo
    log_warn "🚨 REMEMBER:"
    log_warn "  1. BACKUP your database before running any SQL commands"
    log_warn "  2. Test on a copy of your database first"
    log_warn "  3. Change ROLLBACK to COMMIT when ready to apply"
    log_warn "  4. Verify results after applying changes"
    
    return 0
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [command] [options]"
    echo
    echo "Analyze permission gaps between mathilde/valentin and immich user"
    echo
    echo "This script finds folders where both mathilde and valentin have permissions"
    echo "and checks if immich user has ANY permission (any level is sufficient)."
    echo
    echo "Commands:"
    echo "  analyze              - Run console analysis (default)"
    echo "  analyze-json         - Run analysis and export to JSON"
    echo "  analyze-csv          - Run analysis and export to CSV"
    echo "  generate-sql         - Generate SQL injection commands (DRY RUN)"
    echo "  help                 - Show this help message"
    echo
    echo "Examples:"
    echo "  $0                   - Run basic console analysis"
    echo "  $0 analyze-json      - Analyze and save results to JSON"
    echo "  $0 analyze-csv       - Analyze and save results to CSV"
    echo "  $0 generate-sql      - Generate SQL commands for permission injection"
    echo
    echo "Output files are saved to: exports/"
    echo "All results are logged to: logs/permission_analysis_YYYYMMDD_HHMMSS.log"
    echo
    echo "NOTE: SQL injection commands are generated for reference only."
    echo "      Always backup your database before making any changes!"
}

# Main function
main() {
    local command=${1:-"analyze"}
    
    # Validate setup
    if ! validate_setup; then
        exit 1
    fi
    
    case "$command" in
        "analyze"|"")
            analyze_discrepancies "console"
            exit $?
            ;;
        "analyze-json")
            analyze_discrepancies "json"
            exit $?
            ;;
        "analyze-csv")
            analyze_discrepancies "csv"
            exit $?
            ;;
        "generate-sql")
            generate_injection_sql true
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
