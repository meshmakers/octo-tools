# Octo PowerShell Modules

This directory contains PowerShell modules for managing OctoMesh repositories.

## Modules

### Update-OctoVersionAndBranches
Updates the OctoVersion in all `octo-*` repositories and manages Git branches including submodules.

- `Update-OctoVersionAndBranches.psm1` - PowerShell Module
- `Update-OctoVersionAndBranches.psd1` - Module Manifest

### Remove-OctoBranch  
Removes branches from all `octo-*` repositories and switches back to main.

- `Remove-OctoBranch.psm1` - PowerShell Module
- `Remove-OctoBranch.psd1` - Module Manifest

## Installation

Both modules are automatically loaded when you source the Octo profile:

```powershell
. /path/to/octo-tools/modules/profile.ps1
```

## Usage

### Update-OctoVersionAndBranches

```powershell
# Update version only (affects 0.x versions)
Update-OctoVersionAndBranches -Version "0.2"

# Update version and create new branch with submodule management
Update-OctoVersionAndBranches -Version "0.3" -Branch "dev/gerald/mcp"

# Update version, create branch, manage submodules and push changes
Update-OctoVersionAndBranches -Version "0.3" -Branch "dev/gerald/mcp" -Push
```

### Remove-OctoBranch

```powershell
# Delete local branch and switch to main
Remove-OctoBranch -Branch "dev/gerald/mcp"

# Delete both local and remote branch
Remove-OctoBranch -Branch "dev/gerald/mcp" -DeleteRemote

# Delete branch, switch to main and pull latest
Remove-OctoBranch -Branch "dev/gerald/mcp" -DeleteRemote -Pull
```

## Parameters

### Update-OctoVersionAndBranches
- **Version** (Required): The new version number (e.g., "0.2", "0.3")
- **Branch** (Optional): Name of the branch to create
- **Push** (Optional): Automatically push changes to remote
- **RootPath** (Optional): Root directory path (uses `$Global:ROOTPATH`)

### Remove-OctoBranch
- **Branch** (Required): Name of the branch to delete
- **DeleteRemote** (Optional): Also delete from remote repository
- **Pull** (Optional): Pull latest changes after switching to main
- **RootPath** (Optional): Root directory path (uses `$Global:ROOTPATH`)

## Submodule Management

### Update-OctoVersionAndBranches handles complex submodule structures:

**octo-common-services structure:**
- Contains `octo-construction-kit-engine-mongodb` as submodule
- When creating branches, both main repo and submodule get the same branch

**Other OctoMesh services structure:**
- Contain `octo-common-services` as submodule  
- `octo-common-services` contains `octo-construction-kit-engine-mongodb` as nested submodule
- When creating branches, all levels (main → submodule → nested submodule) get the same branch

**Automatic handling:**
- Detects submodule relationships automatically
- Creates branches in submodules when they don't exist
- Switches to existing branches in submodules when available
- Manages nested submodules (octo-construction-kit-engine-mongodb within octo-common-services)

## How they work

Both modules:
1. Search for all `octo-*` directories in the root path
2. Skip directories without `.git` folder
3. Process each Git repository individually
4. Provide colorized output for better visibility

### Update-OctoVersionAndBranches specifically:
- Updates only lines starting with "0." (not major versions like "3.2.*")
- Pattern: `<OctoVersion Condition="'$(OctoNugetPrivateServer)'!='' And '$(OctoVersion)'==''">`0.x.*</OctoVersion>`
- Manages Git submodules automatically
- Creates consistent branch structure across all repositories and submodules
- Only commits if changes were made

### Remove-OctoBranch specifically:  
- Auto-detects main vs master branch
- Safety check: won't delete main/master branches
- Handles both local and remote branch deletion

## Requirements

- Git installed and configured
- PowerShell Core
- All octo-* repositories must be Git repositories
- Octo profile loaded (provides `$Global:ROOTPATH`)
- Proper Git submodule setup for octo-common-services relationships

## Help

For detailed help and examples, run:
```powershell
Get-Help Update-OctoVersionAndBranches -Full
Get-Help Remove-OctoBranch -Full
```

## Integration

Both modules are automatically imported in the Octo profile, so the functions are available immediately after loading the profile.

## Migration Note

The old `Update-OctoVersion` function has been replaced by `Update-OctoVersionAndBranches` to better reflect its enhanced capabilities with submodule management.
