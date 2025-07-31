#!/bin/bash

# Test script for the JSON export functionality
# This script demonstrates how to use the export_permissions_json.sh script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPORT_SCRIPT="$SCRIPT_DIR/export_permissions_json.sh"

echo "======================================================"
echo "    SYNOLOGY PHOTOS PERMISSIONS JSON EXPORT TEST"
echo "======================================================"
echo

# Check if export script exists
if [ ! -f "$EXPORT_SCRIPT" ]; then
    echo "ERROR: Export script not found at $EXPORT_SCRIPT"
    exit 1
fi

# Check if script is executable
if [ ! -x "$EXPORT_SCRIPT" ]; then
    echo "ERROR: Export script is not executable"
    echo "Run: chmod +x $EXPORT_SCRIPT"
    exit 1
fi

echo "✓ Export script found and executable"
echo

# Show help first
echo "1. Showing help information:"
echo "----------------------------------------"
"$EXPORT_SCRIPT" help
echo

# Test export with default filename
echo "2. Testing export with default filename:"
echo "----------------------------------------"
echo "Running: $EXPORT_SCRIPT"
echo

# Note: Since this requires root access and database connectivity,
# we'll just show what would happen
echo "NOTE: This test script shows the commands that would be run."
echo "To actually run the export, you need:"
echo "  - Root access (sudo)"
echo "  - Access to the synofoto PostgreSQL database"
echo "  - The Synology Photos service running"
echo
echo "To run the actual export:"
echo "  sudo $EXPORT_SCRIPT"
echo
echo "To export to a specific file:"
echo "  sudo $EXPORT_SCRIPT /path/to/my_export.json"
echo
echo "Example output JSON structure would be:"
cat << 'EOF'
{
  "export_info": {
    "timestamp": "2025-01-31T12:34:56Z",
    "description": "Exported on ... from Synology Photos database",
    "source_database": "synofoto",
    "permission_bitmap_legend": {
      "1": "viewer (view only)",
      "3": "downloader (view + download)", 
      "7": "uploader (view + download + upload)",
      "15": "manager (view + download + upload + manage)",
      "31": "admin (all permissions)",
      "note": "Permissions are role-based, not individual bits"
    }
  },
  "shared_folders": [
    {
      "folder_id": 92,
      "folder_name": "/Family Photos/Vacation 2024",
      "passphrase_share": "abc123def456",
      "users": [
        {
          "user_id": 3,
          "username": "valentin",
          "user_uid": "1026", 
          "permission_bitmap": 15,
          "permissions_decoded": {
            "role": "manager",
            "permissions": ["view", "download", "upload", "manage"]
          }
        },
        {
          "user_id": 10,
          "username": "bonzac",
          "user_uid": "1033",
          "permission_bitmap": 3,
          "permissions_decoded": {
            "role": "downloader", 
            "permissions": ["view", "download"]
          }
        }
      ]
    }
  ],
  "summary": {
    "total_shared_folders": 25,
    "total_user_permissions": 157
  }
}
EOF

echo
echo "======================================================"
echo "                    TEST COMPLETE"
echo "======================================================"
echo
echo "The export script is ready to use. Remember to run it as root:"
echo "  sudo $EXPORT_SCRIPT [optional_output_file]"
