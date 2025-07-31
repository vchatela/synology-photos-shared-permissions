# Personal Folder

This folder contains user-specific customizations and extensions that are not part of the core Synology Photos permission management system.

## Contents

### `immich-analysis/`
Personal tools for analyzing and managing Immich user permissions:

- **`analyze_immich_permissions.sh`**: Analyzes permission gaps between mathilde/valentin shared folders and immich user access
- **`IMMICH_ANALYSIS_README.md`**: Detailed documentation for the Immich analysis tools

#### Purpose
These tools help ensure that the immich user (used for self-hosted photo management with Immich) has access to folders that mathilde and valentin can access, enabling seamless integration between Synology Photos' permission system and external applications.

#### Usage
```bash
cd personal/immich-analysis/
sudo ./analyze_immich_permissions.sh
```

The analysis checks if immich has ANY permission level on shared folders (doesn't need to match mathilde/valentin permission levels).

## Adding Your Own Extensions

This personal folder structure allows you to:

1. **Create custom analysis scripts** for specific users or use cases
2. **Add integration tools** for other applications (like Immich, Nextcloud, etc.)
3. **Develop specialized reporting** without modifying core scripts
4. **Test experimental features** before potentially integrating them into the main system

### Recommended Structure
```
personal/
├── your-integration/
│   ├── your_script.sh
│   └── README.md
├── custom-reports/
│   ├── custom_analysis.sh
│   └── templates/
└── experimental/
    └── test_features.sh
```

## Note

Scripts in this folder are user-specific and may not be suitable for general use. They are designed for particular setups and requirements. Always review and understand any script before running it in your environment.
