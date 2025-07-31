#!/bin/bash

# Synology Photos Permissions JSON Export Script
# This script exports all shared folder permissions from the Synology Photos database to JSON format
# It includes folder information and all users with their permission bitmaps

# Set up logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
EXPORTS_DIR="$SCRIPT_DIR/exports"
LOG_FILE="$LOG_DIR/export_permissions_$(date +%Y%m%d_%H%M%S).log"

# Create logs and exports directories if they don't exist
mkdir -p "$LOG_DIR"
mkdir -p "$EXPORTS_DIR"

# Default output files
OUTPUT_FILE="$EXPORTS_DIR/synology_photos_permissions_$(date +%Y%m%d_%H%M%S).json"
SUMMARY_FILE="$EXPORTS_DIR/synology_photos_permissions_summary_$(date +%Y%m%d_%H%M%S).txt"
CSV_FILE="$EXPORTS_DIR/synology_photos_permissions_$(date +%Y%m%d_%H%M%S).csv"

# Color output for logging
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    
    # Check if jq is available for JSON formatting (optional)
    if ! command -v jq &> /dev/null; then
        log_warn "jq not found - JSON will not be formatted (but still valid)"
    fi
    
    return 0
}

# Function to get all unique users
get_all_users() {
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT DISTINCT ui.name as username
FROM folder f
JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
LEFT JOIN user_info ui ON sp.target_id = ui.id
WHERE f.id > 1 
  AND f.name IS NOT NULL 
  AND f.name != '/' 
  AND f.name != ''
  AND f.name NOT LIKE '%#recycle%'
  AND f.name NOT LIKE '%@eaDir%'
  AND f.name NOT LIKE '%.__%'
  AND sp.target_id != 0
  AND ui.name IS NOT NULL
ORDER BY ui.name;
" 2>/dev/null
}

# Function to get all unique folders
get_all_folders() {
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
ORDER BY f.name;
" 2>/dev/null
}

# Function to get simplified permissions data for summary table
get_folder_permissions_summary() {
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT 
    f.id as folder_id,
    f.name as folder_name,
    ui.name as username,
    CASE WHEN sp.permission > 0 THEN 1 ELSE 0 END as has_permission
FROM folder f
JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
LEFT JOIN user_info ui ON sp.target_id = ui.id
WHERE f.id > 1 
  AND f.name IS NOT NULL 
  AND f.name != '/' 
  AND f.name != ''
  AND f.name NOT LIKE '%#recycle%'
  AND f.name NOT LIKE '%@eaDir%'
  AND f.name NOT LIKE '%.__%'
  AND sp.target_id != 0
  AND ui.name IS NOT NULL
ORDER BY f.name, ui.name;
" 2>/dev/null
}

# Function to decode permission bitmap to human-readable format
decode_permission_bitmap() {
    local permission=$1
    local role_name=""
    local permissions=()
    
    # Permission bitmap mapping based on roles:
    # 1 = viewer (view only)
    # 3 = downloader (view + download)
    # 7 = uploader (view + download + upload)
    # 15 = manager (view + download + upload + manage)
    # 31 = admin (all permissions)
    
    case "$permission" in
        1)
            role_name="viewer"
            permissions=("view")
            ;;
        3)
            role_name="downloader"
            permissions=("view" "download")
            ;;
        7)
            role_name="uploader"
            permissions=("view" "download" "upload")
            ;;
        15)
            role_name="manager"
            permissions=("view" "download" "upload" "manage")
            ;;
        31)
            role_name="admin"
            permissions=("view" "download" "upload" "manage" "admin")
            ;;
        *)
            role_name="unknown"
            permissions=("unknown_permission_$permission")
            ;;
    esac
    
    # Return as JSON object with both role and individual permissions
    printf '{"role": "%s", "permissions": [' "$role_name"
    local first=true
    for perm in "${permissions[@]}"; do
        if [ "$first" = true ]; then
            printf '"%s"' "$perm"
            first=false
        else
            printf ', "%s"' "$perm"
        fi
    done
    printf ']}'
}

# Function to get all shared folders with their permissions
get_all_folder_permissions() {
    sudo -u postgres psql -d synofoto -t -A -c "
SELECT 
    f.id as folder_id,
    f.name as folder_name,
    f.passphrase_share,
    ui.id as user_id,
    ui.name as username,
    ui.uid as user_uid,
    sp.permission as permission_bitmap,
    sp.target_id
FROM folder f
JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
LEFT JOIN user_info ui ON sp.target_id = ui.id
WHERE f.id > 1 
  AND f.name IS NOT NULL 
  AND f.name != '/' 
  AND f.name != ''
  AND f.name NOT LIKE '%#recycle%'
  AND f.name NOT LIKE '%@eaDir%'
  AND f.name NOT LIKE '%.__%'
  AND sp.permission > 0
  AND sp.target_id != 0
ORDER BY f.id, ui.name;
" 2>/dev/null
}

# Function to export permissions to JSON
export_to_json() {
    local output_file=$1
    
    log_info "Starting permissions export to JSON..."
    log_info "Output file: $output_file"
    
    # Get the current timestamp
    local timestamp=$(date -Iseconds)
    local export_info="Exported on $(date) from Synology Photos database"
    
    # Start building JSON
    echo "{" > "$output_file"
    echo "  \"export_info\": {" >> "$output_file"
    echo "    \"timestamp\": \"$timestamp\"," >> "$output_file"
    echo "    \"description\": \"$export_info\"," >> "$output_file"
    echo "    \"source_database\": \"synofoto\"," >> "$output_file"
    echo "    \"permission_bitmap_legend\": {" >> "$output_file"
    echo "      \"1\": \"viewer (view only)\"," >> "$output_file"
    echo "      \"3\": \"downloader (view + download)\"," >> "$output_file"
    echo "      \"7\": \"uploader (view + download + upload)\"," >> "$output_file"
    echo "      \"15\": \"manager (view + download + upload + manage)\"," >> "$output_file"
    echo "      \"31\": \"admin (all permissions)\"," >> "$output_file"
    echo "      \"note\": \"Permissions are role-based, not individual bits\"" >> "$output_file"
    echo "    }" >> "$output_file"
    echo "  }," >> "$output_file"
    echo "  \"shared_folders\": [" >> "$output_file"
    
    local current_folder_id=""
    local current_folder_name=""
    local folder_count=0
    local user_count=0
    local first_folder=true
    local first_user=true
    
    # Process the database results
    while IFS='|' read -r folder_id folder_name passphrase_share user_id username user_uid permission_bitmap target_id; do
        # Skip empty lines
        if [ -z "$folder_id" ]; then continue; fi
        
        # If this is a new folder, close previous folder and start new one
        if [ "$folder_id" != "$current_folder_id" ]; then
            # Close previous folder if it exists
            if [ -n "$current_folder_id" ]; then
                echo "" >> "$output_file"
                echo "      ]" >> "$output_file"
                echo "    }" >> "$output_file"
                first_folder=false
            fi
            
            # Start new folder
            if [ "$first_folder" = false ]; then
                echo "," >> "$output_file"
            fi
            
            echo "    {" >> "$output_file"
            echo "      \"folder_id\": $folder_id," >> "$output_file"
            echo "      \"folder_name\": \"$folder_name\"," >> "$output_file"
            echo "      \"passphrase_share\": \"$passphrase_share\"," >> "$output_file"
            echo "      \"users\": [" >> "$output_file"
            
            current_folder_id="$folder_id"
            current_folder_name="$folder_name"
            ((folder_count++))
            first_user=true
            
            log_debug "Processing folder $folder_id: $folder_name"
        fi
        
        # Add user permission if user info is available
        if [ -n "$user_id" ] && [ -n "$username" ]; then
            if [ "$first_user" = false ]; then
                echo "," >> "$output_file"
            fi
            
            # Decode permission bitmap to human-readable format
            local decoded_perms=$(decode_permission_bitmap "$permission_bitmap")
            
            echo "        {" >> "$output_file"
            echo "          \"user_id\": $user_id," >> "$output_file"
            echo "          \"username\": \"$username\"," >> "$output_file"
            echo "          \"user_uid\": \"$user_uid\"," >> "$output_file"
            echo "          \"permission_bitmap\": $permission_bitmap," >> "$output_file"
            echo "          \"permissions_decoded\": $decoded_perms" >> "$output_file"
            echo -n "        }" >> "$output_file"
            
            first_user=false
            ((user_count++))
            
            log_debug "  User: $username (UID: $user_uid) - Permission: $permission_bitmap"
        fi
        
    done < <(get_all_folder_permissions)
    
    # Close the last folder if it exists
    if [ -n "$current_folder_id" ]; then
        echo "" >> "$output_file"
        echo "      ]" >> "$output_file"
        echo "    }" >> "$output_file"
    fi
    
    # Close the JSON structure
    echo "" >> "$output_file"
    echo "  ]," >> "$output_file"
    echo "  \"summary\": {" >> "$output_file"
    echo "    \"total_shared_folders\": $folder_count," >> "$output_file"
    echo "    \"total_user_permissions\": $user_count" >> "$output_file"
    echo "  }" >> "$output_file"
    echo "}" >> "$output_file"
    
    log_info "Export completed successfully!"
    log_info "Total shared folders exported: $folder_count"
    log_info "Total user permissions exported: $user_count"
    
    # Validate JSON if jq is available
    if command -v jq &> /dev/null; then
        if jq . "$output_file" > /dev/null 2>&1; then
            log_info "✓ JSON validation passed"
            
            # Optionally format the JSON (create a formatted version)
            local formatted_file="${output_file%.json}_formatted.json"
            jq . "$output_file" > "$formatted_file" 2>/dev/null
            if [ $? -eq 0 ]; then
                log_info "✓ Formatted version created: $formatted_file"
            fi
        else
            log_error "✗ JSON validation failed - please check the output file"
            return 1
        fi
    fi
    
    return 0
}

# Function to export permissions summary table
export_summary_table() {
    local output_file=$1
    
    log_info "Starting permissions summary export..."
    log_info "Summary output file: $output_file"
    
    # Get all users and folders
    local users=()
    local folders=()
    
    # Read users into array
    while IFS= read -r username; do
        if [ -n "$username" ]; then
            users+=("$username")
        fi
    done < <(get_all_users)
    
    # Read folders into associative array (folder_name -> folder_id)
    declare -A folder_names
    while IFS='|' read -r folder_id folder_name; do
        if [ -n "$folder_name" ]; then
            folders+=("$folder_name")
            folder_names["$folder_name"]="$folder_id"
        fi
    done < <(get_all_folders)
    
    log_info "Found ${#users[@]} users and ${#folders[@]} shared folders"
    
    # Create permissions matrix
    declare -A permission_matrix
    
    # Initialize matrix with no permissions
    for folder in "${folders[@]}"; do
        for user in "${users[@]}"; do
            permission_matrix["$folder|$user"]="-"
        done
    done
    
    # Fill matrix with actual permissions
    while IFS='|' read -r folder_id folder_name username has_permission; do
        if [ -n "$folder_name" ] && [ -n "$username" ]; then
            if [ "$has_permission" = "1" ]; then
                permission_matrix["$folder_name|$username"]="X"
            fi
        fi
    done < <(get_folder_permissions_summary)
    
    # Write header to file
    {
        echo "======================================================"
        echo "    SYNOLOGY PHOTOS PERMISSIONS SUMMARY TABLE"
        echo "======================================================"
        echo "Generated on: $(date)"
        echo "Legend: X = Has Permission, - = No Permission"
        echo ""
        echo "Total Folders: ${#folders[@]}"
        echo "Total Users: ${#users[@]}"
        echo "======================================================"
        echo ""
        
        # Calculate column widths
        local max_folder_width=15
        for folder in "${folders[@]}"; do
            if [ ${#folder} -gt $max_folder_width ]; then
                max_folder_width=${#folder}
            fi
        done
        
        # Ensure minimum width for readability
        if [ $max_folder_width -lt 20 ]; then
            max_folder_width=20
        fi
        
        # Print table header
        printf "%-${max_folder_width}s" "FOLDER NAME"
        for user in "${users[@]}"; do
            printf " | %-8s" "${user:0:8}"  # Truncate usernames to 8 chars for table formatting
        done
        echo ""
        
        # Print separator line
        printf "%s" "$(printf "%-${max_folder_width}s" "" | tr ' ' '-')"
        for user in "${users[@]}"; do
            printf "%s" "-+-$(printf "%-8s" "" | tr ' ' '-')"
        done
        echo ""
        
        # Print data rows
        for folder in "${folders[@]}"; do
            # Truncate folder name if too long, but show full name in parentheses
            local display_folder="$folder"
            if [ ${#folder} -gt $max_folder_width ]; then
                display_folder="${folder:0:$((max_folder_width-3))}..."
            fi
            
            printf "%-${max_folder_width}s" "$display_folder"
            for user in "${users[@]}"; do
                local perm="${permission_matrix["$folder|$user"]}"
                printf " | %-8s" "$perm"
            done
            echo ""
        done
        
        echo ""
        echo "======================================================"
        echo "SUMMARY STATISTICS"
        echo "======================================================"
        
        # Calculate statistics
        local total_permissions=0
        local total_possible=$((${#folders[@]} * ${#users[@]}))
        
        for folder in "${folders[@]}"; do
            for user in "${users[@]}"; do
                if [ "${permission_matrix["$folder|$user"]}" = "X" ]; then
                    ((total_permissions++))
                fi
            done
        done
        
        local coverage_percent=0
        if [ $total_possible -gt 0 ]; then
            coverage_percent=$((total_permissions * 100 / total_possible))
        fi
        
        echo "Total shared folders: ${#folders[@]}"
        echo "Total users: ${#users[@]}"
        echo "Total permissions granted: $total_permissions"
        echo "Total possible permissions: $total_possible"
        echo "Permission coverage: $coverage_percent%"
        echo ""
        
        # User statistics
        echo "USER PERMISSION COUNTS:"
        echo "----------------------"
        for user in "${users[@]}"; do
            local user_perms=0
            for folder in "${folders[@]}"; do
                if [ "${permission_matrix["$folder|$user"]}" = "X" ]; then
                    ((user_perms++))
                fi
            done
            local user_percent=0
            if [ ${#folders[@]} -gt 0 ]; then
                user_percent=$((user_perms * 100 / ${#folders[@]}))
            fi
            printf "%-15s: %d/%d folders (%d%%)\n" "$user" "$user_perms" "${#folders[@]}" "$user_percent"
        done
        
        echo ""
        echo "FOLDER SHARING STATISTICS:"
        echo "-------------------------"
        for folder in "${folders[@]}"; do
            local folder_users=0
            for user in "${users[@]}"; do
                if [ "${permission_matrix["$folder|$user"]}" = "X" ]; then
                    ((folder_users++))
                fi
            done
            local folder_percent=0
            if [ ${#users[@]} -gt 0 ]; then
                folder_percent=$((folder_users * 100 / ${#users[@]}))
            fi
            printf "%-30s: %d/%d users (%d%%)\n" "${folder:0:30}" "$folder_users" "${#users[@]}" "$folder_percent"
        done
        
        echo ""
        echo "Export completed at: $(date)"
        echo "======================================================"
        
    } > "$output_file"
    
    log_info "Summary table export completed successfully!"
    log_info "Total permissions: $total_permissions out of $total_possible possible"
    log_info "Coverage: $coverage_percent%"
    
    return 0
}

# Function to export permissions to CSV
export_to_csv() {
    local output_file=$1
    
    log_info "Starting permissions CSV export..."
    log_info "CSV output file: $output_file"
    
    # Get all users and folders
    local users=()
    local folders=()
    
    # Read users into array
    while IFS= read -r username; do
        if [ -n "$username" ]; then
            users+=("$username")
        fi
    done < <(get_all_users)
    
    # Read folders into array
    while IFS='|' read -r folder_id folder_name; do
        if [ -n "$folder_name" ]; then
            folders+=("$folder_name")
        fi
    done < <(get_all_folders)
    
    log_info "Found ${#users[@]} users and ${#folders[@]} shared folders"
    
    # Create permissions matrix
    declare -A permission_matrix
    
    # Initialize matrix with no permissions
    for folder in "${folders[@]}"; do
        for user in "${users[@]}"; do
            permission_matrix["$folder|$user"]="-"
        done
    done
    
    # Fill matrix with actual permissions
    while IFS='|' read -r folder_id folder_name username has_permission; do
        if [ -n "$folder_name" ] && [ -n "$username" ]; then
            if [ "$has_permission" = "1" ]; then
                permission_matrix["$folder_name|$username"]="X"
            fi
        fi
    done < <(get_folder_permissions_summary)
    
    # Write CSV header
    {
        printf "Folder"
        for user in "${users[@]}"; do
            printf ",%s" "$user"
        done
        echo ""
        
        # Write data rows
        for folder in "${folders[@]}"; do
            # Escape folder name for CSV (handle commas and quotes)
            local escaped_folder="$folder"
            if [[ "$folder" == *","* ]] || [[ "$folder" == *"\""* ]]; then
                escaped_folder="\"$(echo "$folder" | sed 's/"/""/g')\""
            fi
            
            printf "%s" "$escaped_folder"
            for user in "${users[@]}"; do
                local perm="${permission_matrix["$folder|$user"]}"
                printf ",%s" "$perm"
            done
            echo ""
        done
        
    } > "$output_file"
    
    log_info "CSV export completed successfully!"
    log_info "Total folders: ${#folders[@]}"
    log_info "Total users: ${#users[@]}"
    
    return 0
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [options] [output_file]"
    echo
    echo "Export Synology Photos shared folder permissions in various formats"
    echo
    echo "Options:"
    echo "  -s, --summary     Generate a summary table instead of detailed JSON"
    echo "  -c, --csv         Generate a CSV file for spreadsheet analysis"
    echo "  -h, --help        Show this help message"
    echo
    echo "Arguments:"
    echo "  output_file       - Optional path to output file"
    echo "                      Default: synology_photos_permissions_YYYYMMDD_HHMMSS.json"
    echo "                      or synology_photos_permissions_summary_YYYYMMDD_HHMMSS.txt for summary"
    echo "                      or synology_photos_permissions_YYYYMMDD_HHMMSS.csv for CSV"
    echo
    echo "Examples:"
    echo "  $0                                    - Export detailed JSON to default timestamped file"
    echo "  $0 my_permissions.json               - Export detailed JSON to specific file"
    echo "  $0 --summary                         - Export summary table to default file"
    echo "  $0 --summary permissions_table.txt   - Export summary table to specific file"
    echo "  $0 --csv                             - Export CSV to default file"
    echo "  $0 --csv permissions.csv             - Export CSV to specific file"
    echo "  $0 /path/to/backup/permissions.json  - Export detailed JSON to specific path"
    echo
    echo "JSON Output Structure:"
    echo "  - export_info: Metadata about the export"
    echo "  - shared_folders: Array of folders with user permissions"
    echo "    - folder_id: Database folder ID"
    echo "    - folder_name: Folder name/path"
    echo "    - users: Array of users with permissions"
    echo "      - user_id: Database user ID"
    echo "      - username: Username"
    echo "      - user_uid: User UID"
    echo "      - permission_bitmap: Raw permission bitmap from database"
    echo "      - permissions_decoded: Human-readable permission array"
    echo "  - summary: Export statistics"
    echo
    echo "Summary Table Output:"
    echo "  - Text table with folders as rows and users as columns"
    echo "  - 'X' indicates user has permission on folder"
    echo "  - '-' indicates user has no permission on folder"
    echo "  - Includes summary statistics and coverage percentages"
    echo
    echo "CSV Output:"
    echo "  - Spreadsheet-friendly format with folders as rows and users as columns"
    echo "  - 'X' indicates user has permission on folder"
    echo "  - '-' indicates user has no permission on folder"
    echo "  - Perfect for filtering and analysis in Excel/LibreOffice/Google Sheets"
    echo
    echo "Permission Bitmap Values:"
    echo "  1 = viewer (view only)"
    echo "  3 = downloader (view + download)"
    echo "  7 = uploader (view + download + upload)"
    echo "  15 = manager (view + download + upload + manage)"
    echo "  31 = admin (all permissions)"
    echo "  (Permissions are role-based, not individual bits)"
    echo
    echo "Results are logged to: logs/export_permissions_YYYYMMDD_HHMMSS.log"
}

# Main function
main() {
    local summary_mode=false
    local csv_mode=false
    local output_file=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--summary)
                summary_mode=true
                shift
                ;;
            -c|--csv)
                csv_mode=true
                shift
                ;;
            -h|--help|help)
                show_usage
                exit 0
                ;;
            *)
                if [ -z "$output_file" ]; then
                    output_file="$1"
                else
                    log_error "Unknown option: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Check for conflicting options
    if [ "$summary_mode" = true ] && [ "$csv_mode" = true ]; then
        log_error "Cannot specify both --summary and --csv options"
        show_usage
        exit 1
    fi
    
    # Set default output file based on mode
    if [ -z "$output_file" ]; then
        if [ "$summary_mode" = true ]; then
            output_file="$SUMMARY_FILE"
        elif [ "$csv_mode" = true ]; then
            output_file="$CSV_FILE"
        else
            output_file="$OUTPUT_FILE"
        fi
    fi
    
    echo "======================================================"
    if [ "$summary_mode" = true ]; then
        echo "    SYNOLOGY PHOTOS PERMISSIONS SUMMARY EXPORT"
    elif [ "$csv_mode" = true ]; then
        echo "    SYNOLOGY PHOTOS PERMISSIONS CSV EXPORT"
    else
        echo "    SYNOLOGY PHOTOS PERMISSIONS JSON EXPORT"
    fi
    echo "======================================================"
    echo "Started at: $(date)"
    echo "Log file: $LOG_FILE"
    echo
    
    # Validate setup
    if ! validate_setup; then
        exit 1
    fi
    
    # Check if output file already exists
    if [ -f "$output_file" ]; then
        log_warn "Output file already exists: $output_file"
        read -p "Overwrite? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Export cancelled by user"
            exit 0
        fi
    fi
    
    # Create output directory if it doesn't exist
    local output_dir=$(dirname "$output_file")
    if [ ! -d "$output_dir" ]; then
        mkdir -p "$output_dir"
        if [ $? -ne 0 ]; then
            log_error "Cannot create output directory: $output_dir"
            exit 1
        fi
    fi
    
    # Export based on mode
    if [ "$summary_mode" = true ]; then
        # Export summary table
        if export_summary_table "$output_file"; then
            echo
            log_info "🎉 Summary export completed successfully!"
            log_info "📁 Output file: $output_file"
            log_info "📊 File size: $(du -h "$output_file" | cut -f1)"
            
            # Show a preview of the table
            echo
            log_info "📋 Preview of summary table:"
            echo "----------------------------------------"
            head -30 "$output_file" | tail -20
            echo "----------------------------------------"
            echo "(Use 'cat $output_file' to view the complete table)"
            
            exit 0
        else
            log_error "Summary export failed"
            exit 1
        fi
    elif [ "$csv_mode" = true ]; then
        # Export CSV
        if export_to_csv "$output_file"; then
            echo
            log_info "🎉 CSV export completed successfully!"
            log_info "📁 Output file: $output_file"
            log_info "📊 File size: $(du -h "$output_file" | cut -f1)"
            
            # Show a preview of the CSV
            echo
            log_info "📋 Preview of CSV data (first 10 rows):"
            echo "----------------------------------------"
            head -11 "$output_file" | while IFS= read -r line; do
                # Truncate long lines for preview
                if [ ${#line} -gt 100 ]; then
                    echo "${line:0:97}..."
                else
                    echo "$line"
                fi
            done
            echo "----------------------------------------"
            echo "(Open $output_file in Excel/LibreOffice/Google Sheets for full analysis)"
            
            exit 0
        else
            log_error "CSV export failed"
            exit 1
        fi
    else
        # Export to JSON
        if export_to_json "$output_file"; then
            echo
            log_info "🎉 Export completed successfully!"
            log_info "📁 Output file: $output_file"
            log_info "📊 File size: $(du -h "$output_file" | cut -f1)"
            
            # Show a preview of the JSON structure
            if command -v jq &> /dev/null; then
                echo
                log_info "📋 Preview of exported data:"
                echo "----------------------------------------"
                jq -r '.summary' "$output_file" 2>/dev/null || echo "Summary preview unavailable"
                echo "----------------------------------------"
                jq -r '.shared_folders[0] | {folder_id, folder_name, user_count: (.users | length)}' "$output_file" 2>/dev/null || echo "Folder preview unavailable"
                echo "----------------------------------------"
            fi
            
            exit 0
        else
            log_error "Export failed"
            exit 1
        fi
    fi
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
