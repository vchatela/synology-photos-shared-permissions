# Immich Permission Analysis Tool

This document explains the permission analysis tool that identifies folders where mathilde and valentin have access but immich user is missing permissions.

## Overview

The `analyze_immich_permissions.sh` script analyzes folders where both mathilde and valentin have permissions and identifies where the immich user is missing ANY permissions. This is useful for ensuring that Immich (self-hosted photo management) has some level of access to the same folders that mathilde and valentin can access.

## Script Location

```bash
/volume1/tools/Synology/synology-photos-shared-permissions/analyze_immich_permissions.sh
```

## Use Case

When running Immich to access Synology Photos through SAMBA, you want to ensure that:
1. Immich user has access to all folders that both mathilde and valentin can access
2. No folders are accidentally inaccessible to Immich when they should be

## Usage

### Basic Commands

```bash
# Basic console analysis
sudo ./analyze_immich_permissions.sh

# Analysis with JSON export
sudo ./analyze_immich_permissions.sh analyze-json

# Analysis with CSV export  
sudo ./analyze_immich_permissions.sh analyze-csv

# Generate SQL injection commands (dry run)
sudo ./analyze_immich_permissions.sh generate-sql

# Show help
./analyze_immich_permissions.sh help
```

### Output Locations

All outputs are now organized in dedicated folders:
- **JSON/CSV exports**: `exports/`
- **SQL injection files**: `exports/`
- **Log files**: `logs/`

## Analysis Logic

### Permission Comparison
1. **Find shared folders**: Identify all folders where BOTH mathilde AND valentin have permissions
2. **Check immich permissions**: For each shared folder, check if immich user has ANY permissions
3. **Categorize findings**: 
   - **MISSING**: Immich has no permission at all
   - **HAS_PERMISSION**: Immich has some level of permission

### Permission Hierarchy
- **viewer (1)**: View only
- **downloader (3)**: View + Download  
- **uploader (7)**: View + Download + Upload
- **manager (15)**: View + Download + Upload + Manage
- **admin (31)**: All permissions

## Output Formats

### Console Output
Displays results directly in the terminal with color-coded messages:
- **GREEN**: Info and compliant folders
- **YELLOW**: Warnings and insufficient permissions  
- **MAGENTA**: Missing permissions and discrepancies
- **RED**: Errors

### JSON Output
Structured JSON file with detailed analysis:

```json
{
  "analysis_info": {
    "timestamp": "2025-01-31T15:30:45+01:00",
    "description": "Analysis of immich user permissions vs mathilde/valentin shared folders",
    "analyzed_users": ["mathilde", "valentin", "immich"]
  },
  "missing_permissions": [
    {
      "folder_id": 304,
      "folder_name": "/Scans/2024/janvier",
      "mathilde": {"permission": 3, "role": "downloader"},
      "valentin": {"permission": 7, "role": "uploader"}, 
      "immich": {"permission": 0, "role": "none"},
      "status": "MISSING"
    }
  ],
  "summary": {
    "total_shared_folders": 25,
    "immich_has_access": 22,
    "immich_missing_access": 3
  }
}
```

### CSV Output
Spreadsheet-friendly format for further analysis:

```csv
folder_id,folder_name,mathilde_permission,mathilde_role,valentin_permission,valentin_role,immich_permission,immich_role,status
304,"/Scans/2024/janvier",3,"downloader",7,"uploader",0,"none","MISSING"
```

## SQL Injection Feature (Dry Run)

### Safety First
⚠️ **WARNING**: The SQL injection feature generates database modification commands. This is potentially risky and should be used with extreme caution.

### What It Does
- Analyzes permission discrepancies
- Generates SQL INSERT/UPDATE commands to fix permissions
- Creates commands with proper conflict handling
- Includes safety measures (ROLLBACK by default)

### Generated SQL Structure
```sql
-- Add immich permission for specific folder
INSERT INTO share_permission (passphrase_share, id_user, target_id, target_type, permission)
SELECT 
    f.passphrase_share,
    0,  -- Admin user
    ui.id,  -- Immich user ID
    1,  -- User type
    3   -- Downloader permission
FROM folder f, user_info ui
WHERE f.id = {folder_id}
  AND ui.name = 'immich'
  AND NOT EXISTS (
    SELECT 1 FROM share_permission sp2 
    WHERE sp2.passphrase_share = f.passphrase_share 
      AND sp2.target_id = ui.id
  );
```
    3  -- recommended permission level
FROM folder f, user_info ui
WHERE f.id = 304 
  AND ui.name = 'immich'
ON CONFLICT (passphrase_share, target_id) 
DO UPDATE SET permission = 3
WHERE share_permission.permission < 3;
```

### Safety Measures
1. **ROLLBACK by default**: All commands wrapped in transaction that rolls back
2. **Conflict handling**: Uses ON CONFLICT to update existing permissions safely
3. **Conditional updates**: Only increases permissions, never decreases
4. **Verification queries**: Includes commands to verify results

### Before Using SQL Injection
1. **Backup your database**: Create a full backup of the synofoto database
2. **Test on copy**: Run the SQL on a copy of your database first
3. **Understand the changes**: Review each generated command
4. **Change ROLLBACK to COMMIT**: Only when you're ready to apply changes

## Example Workflow

### 1. Initial Analysis
```bash
# Run basic analysis to see current state
sudo ./analyze_immich_permissions.sh

# Export detailed results
sudo ./analyze_immich_permissions.sh analyze-json
```

### 2. Generate SQL Commands (if needed)
```bash
# Generate SQL injection commands
sudo ./analyze_immich_permissions.sh generate-sql
```

### 3. Review Results
```bash
# Check the generated files
ls -la exports/
cat exports/immich_permission_analysis_*.json
cat exports/immich_permission_injection_*.sql
```

### 4. Apply Changes (RISKY)
```bash
# ONLY after backup and testing!
# Edit the SQL file to change ROLLBACK to COMMIT

# Simple connection method:
sudo -u postgres psql -d synofoto -f exports/immich_permission_injection_YYYYMMDD_HHMMSS.sql

# Manual execution:
sudo -u postgres psql -d synofoto
# Then in psql:
# \i exports/immich_permission_injection_YYYYMMDD_HHMMSS.sql
```

### 5. Verify Changes
```bash
# Re-run analysis to confirm fixes
sudo ./analyze_immich_permissions.sh
```

## Integration with Other Scripts

### Export Permissions First
```bash
# Create current state backup
sudo ./export_permissions_json.sh

# Then analyze
sudo ./analyze_immich_permissions.sh analyze-json
```

### Verify with Permission Audit
```bash
# After making changes, verify alignment
sudo ./permission_audit.sh summary
```

## Error Handling

The script includes comprehensive error handling:
- **Database connectivity validation**
- **User permission checks** 
- **Input validation**
- **Output file creation verification**
- **SQL syntax validation**

## Common Use Cases

### 1. Regular Immich Maintenance
```bash
# Monthly check for permission drift
sudo ./analyze_immich_permissions.sh analyze-json
```

### 2. After Adding New Shared Folders
```bash
# Check if immich needs access to new folders
sudo ./analyze_immich_permissions.sh
```

### 3. Immich Setup Verification
```bash
# Ensure immich has proper access during initial setup
sudo ./analyze_immich_permissions.sh analyze-csv
```

### 4. Permission Debugging
```bash
# When immich can't access expected folders
sudo ./analyze_immich_permissions.sh
sudo ./permission_audit.sh user immich
```

## Troubleshooting

### Common Issues

1. **"Cannot connect to synofoto database"**
   - Ensure PostgreSQL is running
   - Verify database access permissions

2. **"This script must be run as root"**
   - Use `sudo` to run the script

3. **No shared folders found**
   - Verify mathilde and valentin users exist
   - Check if they have any shared folder permissions

4. **Immich user not found**
   - Verify immich user exists in user_info table
   - Check user name spelling (case sensitive)

### Debug Information
All operations are logged with detailed information:
```bash
# Check the latest log file
tail -f logs/permission_analysis_*.log
```

## Related Scripts

- `export_permissions_json.sh`: Export current permissions to JSON
- `permission_audit.sh`: Validate filesystem vs database alignment  
- `sync_permissions.sh`: Apply database permissions to filesystem
- `batch_sync.sh`: Process all folders for permission synchronization
