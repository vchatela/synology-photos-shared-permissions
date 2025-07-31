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

# Default output file
OUTPUT_FILE="$EXPORTS_DIR/synology_photos_permissions_$(date +%Y%m%d_%H%M%S).json"

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

# Function to show usage
show_usage() {
    echo "Usage: $0 [output_file]"
    echo
    echo "Export Synology Photos shared folder permissions to JSON format"
    echo
    echo "Arguments:"
    echo "  output_file    - Optional path to output JSON file"
    echo "                   Default: synology_photos_permissions_YYYYMMDD_HHMMSS.json"
    echo
    echo "Examples:"
    echo "  $0                                    - Export to default timestamped file"
    echo "  $0 my_permissions.json               - Export to specific file"
    echo "  $0 /path/to/backup/permissions.json  - Export to specific path"
    echo
    echo "Output JSON Structure:"
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
    local output_file=${1:-$OUTPUT_FILE}
    
    echo "======================================================"
    echo "    SYNOLOGY PHOTOS PERMISSIONS JSON EXPORT"
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
}

# Check if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Check for help flag
    if [[ "$1" == "help" ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        show_usage
        exit 0
    fi
    
    main "$@"
fi
