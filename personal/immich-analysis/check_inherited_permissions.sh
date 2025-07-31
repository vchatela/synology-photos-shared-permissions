#!/bin/bash

# Inherited Permissions Detection Script
# This script identifies subfolders of /Anniversaires and /Noël that have identical 
# user permissions to their parent folder, indicating they are using default inherited permissions

# Set up logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
EXPORTS_DIR="$SCRIPT_DIR/exports"
LOG_FILE="$LOG_DIR/inherited_permissions_$(date +%Y%m%d_%H%M%S).log"

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

log_inherited() {
    echo -e "${MAGENTA}[INHERITED]${NC} $1" | tee -a "$LOG_FILE"
}

# Function to validate prerequisites
validate_prerequisites() {
    log_info "Validating prerequisites..."
    
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root to access the PostgreSQL database"
        log_error "Please run with: sudo $0"
        exit 1
    fi
    
    # Check if PostgreSQL is accessible
    if ! PGPASSWORD="" sudo -u postgres psql -d synofoto -c "SELECT 1;" >/dev/null 2>&1; then
        log_error "Cannot connect to synofoto database"
        log_error "Ensure PostgreSQL is running and synofoto database exists"
        exit 1
    fi
    
    log_info "Prerequisites validated successfully"
}

# Function to get users with permissions for a specific folder
get_folder_users() {
    local folder_id="$1"
    
    PGPASSWORD="" sudo -u postgres psql -d synofoto -t -c "
        SELECT DISTINCT ui.name
        FROM folder f
        JOIN share_permission sp ON f.passphrase_share = sp.passphrase_share
        JOIN user_info ui ON sp.target_id = ui.id
        WHERE f.id = $folder_id
        AND sp.target_type = 1
        ORDER BY ui.name;
    " 2>/dev/null | tr -d ' ' | grep -v '^$'
}

# Function to get parent folder info
get_parent_folder_info() {
    local parent_name="$1"
    
    PGPASSWORD="" sudo -u postgres psql -d synofoto -t -c "
        SELECT id, name
        FROM folder 
        WHERE name = '$parent_name'
        AND id_user = 0
        AND shared = true;
    " 2>/dev/null | sed 's/|/\t/' | grep -v '^$'
}

# Function to get subfolders
get_subfolders() {
    local parent_id="$1"
    
    PGPASSWORD="" sudo -u postgres psql -d synofoto -t -c "
        SELECT id, name
        FROM folder 
        WHERE parent = $parent_id
        ORDER BY name;
    " 2>/dev/null | sed 's/|/\t/' | grep -v '^$'
}

# Function to check if user sets are identical
compare_user_sets() {
    local parent_users="$1"
    local subfolder_users="$2"
    
    # Sort and compare user lists
    local parent_sorted=$(echo "$parent_users" | sort)
    local subfolder_sorted=$(echo "$subfolder_users" | sort)
    
    if [ "$parent_sorted" = "$subfolder_sorted" ]; then
        return 0  # Identical
    else
        return 1  # Different
    fi
}

# Function to analyze inherited permissions
analyze_inherited_permissions() {
    local output_format="$1"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local console_output=""
    local csv_output=""
    local json_output=""
    
    log_info "Starting inherited permissions analysis..."
    echo
    
    # Initialize outputs
    if [ "$output_format" = "csv" ] || [ "$output_format" = "all" ]; then
        local csv_file="$EXPORTS_DIR/inherited_permissions_$timestamp.csv"
        csv_output="parent_folder,parent_id,subfolder,subfolder_id,status,users_list"
        echo "$csv_output" > "$csv_file"
        log_info "CSV output will be saved to: $csv_file"
    fi
    
    if [ "$output_format" = "json" ] || [ "$output_format" = "all" ]; then
        local json_file="$EXPORTS_DIR/inherited_permissions_$timestamp.json"
        json_output='{"analysis_info":{"timestamp":"'$(date -Iseconds)'","description":"Analysis of inherited permissions in /Anniversaires and /Noël subfolders","target_folders":["/Anniversaires","/Noël"]},"inherited_folders":[],"summary":{"total_subfolders":0,"inherited_count":0,"custom_count":0}}'
        log_info "JSON output will be saved to: $json_file"
    fi
    
    local total_subfolders=0
    local inherited_count=0
    local custom_count=0
    
    # Analyze both target folders
    for parent_folder in "/Anniversaires" "/Noël"; do
        log_analysis "Analyzing folder: $parent_folder"
        
        # Get parent folder info
        local parent_info=$(get_parent_folder_info "$parent_folder")
        if [ -z "$parent_info" ]; then
            log_warn "Parent folder '$parent_folder' not found in database"
            continue
        fi
        
        local parent_id=$(echo "$parent_info" | cut -f1)
        local parent_name=$(echo "$parent_info" | cut -f2)
        
        log_debug "Parent folder ID: $parent_id, Name: $parent_name"
        
        # Get users with permissions on parent folder
        local parent_users=$(get_folder_users "$parent_id")
        local parent_user_count=$(echo "$parent_users" | wc -l)
        
        log_debug "Parent folder users ($parent_user_count): $(echo "$parent_users" | tr '\n' ', ' | sed 's/,$//')"
        
        # Get all subfolders using parent ID
        local subfolders=$(get_subfolders "$parent_id")
        
        if [ -z "$subfolders" ]; then
            log_info "No subfolders found for $parent_folder"
            continue
        fi
        
        echo
        log_analysis "Found $(echo "$subfolders" | wc -l) subfolders in $parent_folder"
        
        # Process each subfolder
        while IFS=$'\t' read -r subfolder_id subfolder_name; do
            if [ -z "$subfolder_id" ]; then continue; fi
            
            ((total_subfolders++))
            
            # Get users with permissions on subfolder
            local subfolder_users=$(get_folder_users "$subfolder_id")
            local subfolder_user_count=$(echo "$subfolder_users" | wc -l)
            
            # Compare user sets
            if compare_user_sets "$parent_users" "$subfolder_users"; then
                # Inherited permissions detected
                ((inherited_count++))
                local status="INHERITED"
                local users_list=$(echo "$subfolder_users" | tr '\n' ', ' | sed 's/,$//')
                
                log_inherited "📁 $subfolder_name (ID: $subfolder_id)"
                log_inherited "   └── Same users as parent: $users_list"
                
                # Add to CSV
                if [ "$output_format" = "csv" ] || [ "$output_format" = "all" ]; then
                    echo "\"$parent_name\",$parent_id,\"$subfolder_name\",$subfolder_id,$status,\"$users_list\"" >> "$csv_file"
                fi
                
                # Add to JSON (will be processed later)
                
            else
                # Custom permissions
                ((custom_count++))
                local status="CUSTOM"
                local users_list=$(echo "$subfolder_users" | tr '\n' ', ' | sed 's/,$//')
                
                log_info "✅ $subfolder_name (ID: $subfolder_id) - Custom permissions"
                log_debug "   └── Custom users: $users_list"
                
                # Add to CSV
                if [ "$output_format" = "csv" ] || [ "$output_format" = "all" ]; then
                    echo "\"$parent_name\",$parent_id,\"$subfolder_name\",$subfolder_id,$status,\"$users_list\"" >> "$csv_file"
                fi
            fi
            
        done <<< "$subfolders"
        
    done
    
    # Generate final summary
    echo
    echo "======================================================" | tee -a "$LOG_FILE"
    echo "                 INHERITED PERMISSIONS SUMMARY" | tee -a "$LOG_FILE"
    echo "======================================================" | tee -a "$LOG_FILE"
    log_analysis "Total subfolders analyzed: $total_subfolders"
    log_inherited "Folders with inherited permissions: $inherited_count"
    log_info "Folders with custom permissions: $custom_count"
    
    if [ $inherited_count -gt 0 ]; then
        echo
        log_warn "⚠️  Found $inherited_count subfolder(s) that may need permission updates"
        log_warn "   These folders are using default inherited permissions"
        log_warn "   Consider setting specific permissions for better access control"
    else
        log_info "✅ All subfolders have custom permissions configured"
    fi
    
    # Finalize JSON output
    if [ "$output_format" = "json" ] || [ "$output_format" = "all" ]; then
        # Update summary in JSON
        json_output=$(echo "$json_output" | jq --argjson total "$total_subfolders" --argjson inherited "$inherited_count" --argjson custom "$custom_count" '.summary.total_subfolders = $total | .summary.inherited_count = $inherited | .summary.custom_count = $custom')
        
        # Write JSON file
        echo "$json_output" | jq '.' > "$json_file"
        log_info "JSON analysis saved to: $json_file"
    fi
    
    echo "Completed at: $(date)" | tee -a "$LOG_FILE"
}

# Function to display help
show_help() {
    echo "Inherited Permissions Checker - Synology Photos"
    echo "Identifies subfolders using inherited permissions from parent folders"
    echo
    echo "Usage:"
    echo "  $0                   - Console analysis only"
    echo "  $0 csv              - Analysis with CSV export"  
    echo "  $0 json             - Analysis with JSON export"
    echo "  $0 all              - Analysis with both CSV and JSON export"
    echo "  $0 help             - Show this help"
    echo
    echo "Target Folders:"
    echo "  /Anniversaires      - Birthday celebration folders"
    echo "  /Noël              - Christmas celebration folders"
    echo
    echo "Purpose:"
    echo "  Detects subfolders that have identical user permissions to their parent"
    echo "  folder, indicating they are using default inherited permissions rather"
    echo "  than custom configured permissions."
    echo
    echo "Output Files:"
    echo "  CSV exports: exports/inherited_permissions_YYYYMMDD_HHMMSS.csv"
    echo "  JSON exports: exports/inherited_permissions_YYYYMMDD_HHMMSS.json"
    echo "  Log files: logs/inherited_permissions_YYYYMMDD_HHMMSS.log"
}

# Main execution
case "${1:-console}" in
    "console"|"")
        validate_prerequisites
        analyze_inherited_permissions "console"
        ;;
    "csv")
        validate_prerequisites
        analyze_inherited_permissions "csv"
        ;;
    "json")
        validate_prerequisites
        analyze_inherited_permissions "json"
        ;;
    "all")
        validate_prerequisites
        analyze_inherited_permissions "all"
        ;;
    "help"|"-h"|"--help")
        show_help
        ;;
    *)
        log_error "Unknown option: $1"
        echo
        show_help
        exit 1
        ;;
esac
