# Clean ACL Approach - Implementation Summary

## Problem Solved

The original script had overly complex logic to handle existing ACL entries, duplicates, and conflicts. This led to:
- Complex duplicate detection and cleanup functions
- Error-prone logic trying to handle existing vs new permissions  
- Difficult to debug and maintain code
- Race conditions when multiple tools managed the same ACLs

## New Clean Approach

### Key Principle
**Start fresh for each folder by cleaning all level:0 ACL entries first, then apply only what's needed.**

### Implementation Steps

1. **Clean Slate**: Remove ALL level:0 ACL entries from the target folder
   - `clean_all_level0_acl_entries()` removes every level:0 entry regardless of user or permission type
   - Inherited entries (level:1+) are preserved as they come from parent folders

2. **Apply Database Permissions**: Add level:0 allow entries for authorized users
   - Only users with database permissions > 0 get filesystem access
   - All get read-only permissions regardless of database permission level

3. **Deny Unauthorized Users**: Add level:0 deny entries for unauthorized users
   - All system users without database permissions get explicit deny rules
   - This prevents inherited permissions from granting unintended access

### Functions Removed (No Longer Needed)

- `remove_inherited_duplicate()` - No more duplicates to handle
- `cleanup_acl_duplicates()` - No more duplicates since we start fresh
- `remove_unauthorized_users()` - Handled by clean + selective add approach
- `deny_inherited_unauthorized_users()` - Simplified into the main flow

### Functions Simplified

- `apply_acl_permissions()` - No longer needs to remove existing entries first
- `sync_folder_permissions()` - Much cleaner 3-step process

### Benefits

1. **Simpler Logic**: Clear, predictable 3-step process
2. **No Race Conditions**: Each folder operation is atomic
3. **No Duplicate Handling**: Impossible to have duplicates when starting fresh
4. **Easier Debugging**: Clear before/after state for each folder
5. **More Reliable**: Less complex conditional logic = fewer edge cases

### Inherited Permissions Handling

- **Preserved**: Level:1+ entries are never touched (they represent valid inheritance)
- **Override**: Level:0 entries take precedence over inherited entries
- **Parent Traversal**: `replace_parent_deny_with_execute()` still ensures users can reach their authorized subfolders

## Code Quality Improvement

- **Before**: ~753 lines with complex duplicate handling
- **After**: ~500 lines with straightforward logic
- **Maintainability**: Much easier to understand and modify
- **Reliability**: Fewer edge cases and conditional branches

## Example Flow

For folder `/volume1/photo/Scans`:

1. **Clean**: Remove all level:0 entries (any user, any permission)
2. **Database Query**: Find users with permissions (e.g., `alice:7`, `bob:3`)  
3. **Apply Allow**: Add `user:alice:allow:r-x---aARWc--:fd--` and `user:bob:allow:r-x---aARWc--:fd--`
4. **Apply Deny**: Add `user:charlie:deny:rwxpdDaARWcCo:fd--` for all other system users
5. **Parent Access**: Ensure alice/bob can traverse parent folders if needed

Result: Clean, predictable ACL state that exactly matches database permissions.
