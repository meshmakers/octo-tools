<#
.SYNOPSIS
    Updates OctoVersion and manages branches in all octo-* repositories including submodules

.DESCRIPTION
    This function searches for all directories starting with 'octo-' in the specified root path,
    finds Directory.Build.props files within those directories, and updates the OctoVersion
    line that contains the OctoNugetPrivateServer condition.
    
    Additionally, it handles Git submodules by converting them to symlinks:
    - Automatically converts all submodules to symlinks pointing to $ROOTPATH repositories
    - No need for manual submodule branch management
    - Uses existing repositories from $ROOTPATH

.PARAMETER Version
    The new version number (e.g., "0.2", "0.3"). Required parameter.
    The function will append ".*" to create patterns like "0.2.*"

.PARAMETER Branch
    Optional. Name of the branch to create before making changes.
    Example: "dev/gerald/mcp"

.PARAMETER Push
    Optional switch. If specified, changes will be pushed to the remote repository.
    If a branch is specified, it will be pushed with -u origin flag.

.PARAMETER RootPath
    Optional. Root directory path where octo-* directories are located.
    Default: Uses the global $ROOTPATH variable from the Octo profile

.EXAMPLE
    Update-OctoVersionAndBranches -Version "0.2"
    Updates OctoVersion to 0.2.* in all octo-* repositories

.EXAMPLE
    Update-OctoVersionAndBranches -Version "0.3" -Branch "dev/gerald/mcp"
    Creates branch dev/gerald/mcp and updates OctoVersion to 0.3.* including submodules

.EXAMPLE
    Update-OctoVersionAndBranches -Version "0.3" -Branch "dev/gerald/mcp" -Push
    Creates branch, updates version, handles submodules, and pushes changes to remote

.NOTES
    - Requires Git to be installed and configured
    - All octo-* directories must be Git repositories
    - The function looks for the specific pattern with OctoNugetPrivateServer condition
    - Only updates versions starting with "0." (not major versions like "3.2.*")
    - Handles submodule conversion to symlinks automatically
    - Uses existing repositories from $ROOTPATH for symlinks
    - Only commits and pushes if changes were actually made
    - Skips directories without .git folder

.FUNCTIONALITY
    1. Finds all octo-* directories in the root path
    2. For each repository:
       - Creates optional new branch
       - Converts submodules to symlinks (using existing $ROOTPATH repositories)
       - Searches for all Directory.Build.props files
       - Updates the OctoVersion line with OctoNugetPrivateServer condition (0.x versions only)
       - Commits changes if any were made
       - Optionally pushes changes
#>
function Update-OctoVersionAndBranches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Version number like 0.2 or 0.3")]
        [string]$Version,
        
        [Parameter(Mandatory = $false, HelpMessage = "Branch name to create, e.g., dev/gerald/mcp")]
        [string]$Branch = $null,
        
        [Parameter(Mandatory = $false, HelpMessage = "Push changes to remote repository")]
        [switch]$Push = $false,
        
        [Parameter(Mandatory = $false, HelpMessage = "Root path where octo-* directories are located")]
        [string]$RootPath = $Global:ROOTPATH
    )

    function Update-OctoVersionFile {
        param(
            [string]$FilePath,
            [string]$NewVersion
        )
        
        Write-Host "Updating $FilePath" -ForegroundColor Green
        
        $content = Get-Content $FilePath -Raw
        # Only match OctoVersion lines that start with "0." (not major versions like "3.2.*")
        $pattern = '(<OctoVersion Condition="[^"]*OctoNugetPrivateServer[^"]*"[^>]*>)0\.[^<]*(</OctoVersion>)'
        $replacement = '${1}' + $NewVersion + '.*${2}'
        
        $newContent = $content -replace $pattern, $replacement
        
        if ($content -ne $newContent) {
            Set-Content -Path $FilePath -Value $newContent -NoNewline
            Write-Host "  ✓ Updated to version $NewVersion.*" -ForegroundColor Yellow
            return $true
        }
        else {
            Write-Host "  - No changes needed (no 0.x version found)" -ForegroundColor Gray
            return $false
        }
    }

    function Convert-SubmodulesToSymlinks {
        param(
            [string]$RepoPath,
            [string]$RepoName
        )
        
        Write-Host "  🔗 Converting submodules to symlinks in: $RepoName" -ForegroundColor Magenta
        
        # Check if .gitmodules exists
        $gitmodulesPath = Join-Path $RepoPath ".gitmodules"
        if (-not (Test-Path $gitmodulesPath)) {
            Write-Host "    - No submodules found" -ForegroundColor Gray
            return
        }
        
        try {
            # Use the Convert-SubmodulesToSymlinks function from the imported module
            Push-Location $RepoPath
            Convert-AllSubmodulesToSymlinks -RepositoryPath $RepoPath
            Write-Host "    ✓ Submodules converted to symlinks" -ForegroundColor Green
        }
        catch {
            Write-Warning "    Failed to convert submodules to symlinks: $_"
        }
        finally {
            Pop-Location
        }
    }

    function Process-OctoRepository {
        param(
            [string]$RepoPath,
            [string]$Version,
            [string]$Branch,
            [bool]$Push
        )
        
        $repoName = Split-Path $RepoPath -Leaf
        Write-Host "`nProcessing repository: $repoName" -ForegroundColor Cyan
        
        Push-Location $RepoPath
        
        try {
            # Create branch if specified
            if ($Branch) {
                Write-Host "Creating branch: $Branch" -ForegroundColor Magenta
                git checkout -b $Branch
            }
            
            # Convert submodules to symlinks
            Convert-SubmodulesToSymlinks -RepoPath $RepoPath -RepoName $repoName
            
            # Find and update Directory.Build.props files
            $propsFiles = Get-ChildItem -Path . -Name "Directory.Build.props" -Recurse
            $updated = $false
            
            foreach ($file in $propsFiles) {
                $fullPath = Join-Path $RepoPath $file
                if (Update-OctoVersionFile -FilePath $fullPath -NewVersion $Version) {
                    $updated = $true
                }
            }
            
            # Commit changes if any were made
            if ($updated -or $Branch) {
                git add . -A
                $commitMessage = if ($updated) {
                    "Update OctoVersion to $Version.* and convert submodules to symlinks for branch $Branch"
                } else {
                    "Create branch $Branch and convert submodules to symlinks"
                }
                git commit -m $commitMessage
                Write-Host "  ✓ Changes committed" -ForegroundColor Green
                
                # Push if requested
                if ($Push) {
                    if ($Branch) {
                        git push -u origin $Branch
                    }
                    else {
                        git push
                    }
                    Write-Host "  ✓ Changes pushed" -ForegroundColor Green
                }
            }
        }
        finally {
            Pop-Location
        }
    }

    # Main execution
    Write-Host "Starting OctoVersion update to $Version with branch management" -ForegroundColor White
    Write-Host "Root path: $RootPath" -ForegroundColor White

    if ($Branch) {
        Write-Host "Branch: $Branch (including submodules)" -ForegroundColor White
    }

    if ($Push) {
        Write-Host "Push: Enabled" -ForegroundColor White
    }

    # Find all octo-* directories
    $octoDirectories = Get-ChildItem -Path $RootPath -Directory -Name "octo-*" | ForEach-Object {
        Join-Path $RootPath $_
    }

    Write-Host "`nFound $($octoDirectories.Count) octo-* directories:" -ForegroundColor White
    $octoDirectories | ForEach-Object { Write-Host "  - $(Split-Path $_ -Leaf)" -ForegroundColor Gray }

    # Process each directory
    foreach ($dir in $octoDirectories) {
        if (Test-Path (Join-Path $dir ".git")) {
            Process-OctoRepository -RepoPath $dir -Version $Version -Branch $Branch -Push $Push
        }
        else {
            Write-Host "`nSkipping $dir (no .git directory)" -ForegroundColor Yellow
        }
    }

    Write-Host "`nUpdate completed!" -ForegroundColor Green
}

# Export the function
Export-ModuleMember -Function Update-OctoVersionAndBranches
