# Inherited Permissions Checker

This script analyzes subfolders of `/Anniversaires` and `/Noël` to identify folders that are using inherited (default) permissions rather than custom configured permissions.

## Purpose

When a subfolder has identical user permissions to its parent folder, it indicates that:
- The subfolder is using inherited permissions (default behavior)
- No custom permissions have been configured for that specific subfolder
- This might need attention for better access control

## How It Works

1. **Target Folders**: Finds shared folders named `/Anniversaires` and `/Noël` owned by admin (id_user=0)
2. **Parent-Child Relationship**: Uses the database `parent` field to find direct subfolders
3. **User Comparison**: Compares the list of users who have permissions on:
   - Parent folder (e.g., admin-owned `/Anniversaires`)
   - Each direct subfolder (using `parent` field relationship)
4. **Detection Logic**: If the user lists are identical, the subfolder is marked as "INHERITED"
5. **Permission Levels**: Only compares which users have access, not their specific permission levels

## Usage

### Basic Commands

```bash
# Console analysis only
sudo ./check_inherited_permissions.sh

# Generate CSV export
sudo ./check_inherited_permissions.sh csv

# Generate JSON export  
sudo ./check_inherited_permissions.sh json

# Generate both CSV and JSON
sudo ./check_inherited_permissions.sh all

# Show help
./check_inherited_permissions.sh help
```

### Example Output

```
[ANALYSIS] Analyzing folder: /Anniversaires
[ANALYSIS] Found 5 subfolders in /Anniversaires
[INHERITED] 📁 /Anniversaires/Birthday Party 2023 (ID: 156)
   └── Same users as parent: mathilde, valentin
[INFO] ✅ /Anniversaires/Special Event (ID: 157) - Custom permissions
[INHERITED] 📁 /Anniversaires/Another Party (ID: 158)
   └── Same users as parent: mathilde, valentin

======================================================
                 INHERITED PERMISSIONS SUMMARY
======================================================
[ANALYSIS] Total subfolders analyzed: 5
[INHERITED] Folders with inherited permissions: 2
[INFO] Folders with custom permissions: 3
[WARN] ⚠️  Found 2 subfolder(s) that may need permission updates
```

## Output Formats

### CSV Output
```csv
parent_folder,parent_id,subfolder,subfolder_id,status,users_list
"/Anniversaires",35,"/Anniversaires/Birthday Party 2023",156,INHERITED,"mathilde, valentin"
"/Noël",43,"/Noël/Christmas 2023",159,INHERITED,"mathilde, valentin, immich"
```

### JSON Output
```json
{
  "analysis_info": {
    "timestamp": "2025-07-31T14:30:45+02:00",
    "description": "Analysis of inherited permissions in /Anniversaires and /Noël subfolders",
    "target_folders": ["/Anniversaires", "/Noël"]
  },
  "inherited_folders": [
    {
      "parent_folder": "/Anniversaires",
      "parent_id": 35,
      "subfolder": "/Anniversaires/Birthday Party 2023",
      "subfolder_id": 156,
      "status": "INHERITED",
      "users": ["mathilde", "valentin"]
    }
  ],
  "summary": {
    "total_subfolders": 12,
    "inherited_count": 4,
    "custom_count": 8
  }
}
```

## Use Cases

### When to Use This Script
- **Permission Audit**: Regular checks to ensure proper access control
- **Security Review**: Identify folders that might need specific permissions
- **Custom Setup**: Before setting up specific permissions for events
- **Cleanup**: Find folders that can be customized for better organization

### Action Items from Results
When a folder shows as "INHERITED":
1. **Review the folder content**: Does it need different permissions than the parent?
2. **Consider custom permissions**: Should some users have different access levels?
3. **Update if needed**: Use Synology Photos interface to set custom permissions
4. **Document decisions**: Keep track of which folders intentionally use inherited permissions

## Integration with Other Scripts

This script complements the other tools in the suite:
- **`export_permissions_json.sh`**: Get detailed permission information
- **`analyze_immich_permissions.sh`**: Check immich user access
- **Permission sync scripts**: Apply changes after permission updates

## Output Locations

- **CSV files**: `exports/inherited_permissions_YYYYMMDD_HHMMSS.csv`
- **JSON files**: `exports/inherited_permissions_YYYYMMDD_HHMMSS.json`
- **Log files**: `logs/inherited_permissions_YYYYMMDD_HHMMSS.log`

## Technical Notes

### Database Queries
- Uses PostgreSQL queries against the `synofoto` database
- Focuses on `folder`, `share_permission`, and `user_info` tables
- Only considers user permissions (`target_type = 1`)

### Performance
- Lightweight analysis, focuses only on two parent folders
- Efficient SQL queries with minimal database load
- Fast execution for typical folder structures

### Safety
- **Read-only operations**: Never modifies the database
- **No permission changes**: Only analyzes existing permissions
- **Safe to run anytime**: Can be executed during normal system operation
