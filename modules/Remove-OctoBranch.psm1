<#
.SYNOPSIS
    Removes a branch from all octo-* repositories and switches back to main

.DESCRIPTION
    This function searches for all directories starting with 'octo-' in the specified root path,
    switches each repository back to the main branch, and optionally deletes a specified branch
    both locally and remotely.
    
    The function automatically detects whether the repository uses 'main' or 'master' as the
    default branch.

.PARAMETER Branch
    The name of the branch to delete. Required parameter.
    Example: "dev/gerald/mcp"

.PARAMETER DeleteRemote
    Optional switch. If specified, the branch will also be deleted from the remote repository.
    Uses 'git push origin --delete <branch>'

.PARAMETER Pull
    Optional switch. If specified, pulls the latest changes after switching to main/master.

.PARAMETER RootPath
    Optional. Root directory path where octo-* directories are located.
    Default: Uses the global $ROOTPATH variable from the Octo profile

.EXAMPLE
    Remove-OctoBranch -Branch "dev/gerald/mcp"
    Switches all octo-* repositories to main/master and deletes the local branch

.EXAMPLE
    Remove-OctoBranch -Branch "dev/gerald/mcp" -DeleteRemote
    Deletes the branch both locally and remotely, then switches to main/master

.EXAMPLE
    Remove-OctoBranch -Branch "dev/gerald/mcp" -DeleteRemote -Pull
    Deletes the branch, switches to main/master, and pulls latest changes

.NOTES
    - Requires Git to be installed and configured
    - All octo-* directories must be Git repositories
    - The function automatically detects main vs master branch
    - Skips repositories that don't have the specified branch
    - Skips directories without .git folder
    - Will not delete main/master branches (safety check)

.FUNCTIONALITY
    1. Finds all octo-* directories in the root path
    2. For each repository:
       - Detects the default branch (main or master)
       - Switches to the default branch
       - Deletes the specified branch locally
       - Optionally deletes the branch remotely
       - Optionally pulls latest changes
#>
function Remove-OctoBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, HelpMessage = "Branch name to delete, e.g., dev/gerald/mcp")]
        [string]$Branch,
        
        [Parameter(Mandatory = $false, HelpMessage = "Also delete the branch from remote repository")]
        [switch]$DeleteRemote = $false,
        
        [Parameter(Mandatory = $false, HelpMessage = "Pull latest changes after switching to main")]
        [switch]$Pull = $false,
        
        [Parameter(Mandatory = $false, HelpMessage = "Root path where octo-* directories are located")]
        [string]$RootPath = $Global:ROOTPATH
    )

    function Get-DefaultBranch {
        param([string]$RepoPath)
        
        Push-Location $RepoPath
        try {
            # Try to get the default branch from remote
            $defaultBranch = git symbolic-ref refs/remotes/origin/HEAD 2>$null
            if ($defaultBranch) {
                return ($defaultBranch -split '/')[-1]
            }
            
            # Fallback: check if main exists, otherwise use master
            $branches = git branch -r
            if ($branches -match 'origin/main') {
                return "main"
            }
            elseif ($branches -match 'origin/master') {
                return "master"
            }
            else {
                # Last fallback: use main as default
                return "main"
            }
        }
        finally {
            Pop-Location
        }
    }

    function Process-OctoRepository {
        param(
            [string]$RepoPath,
            [string]$BranchToDelete,
            [bool]$DeleteRemote,
            [bool]$Pull
        )
        
        $repoName = Split-Path $RepoPath -Leaf
        Write-Host "`nProcessing repository: $repoName" -ForegroundColor Cyan
        
        Push-Location $RepoPath
        
        try {
            # Safety check: don't delete main/master branches
            if ($BranchToDelete -eq "main" -or $BranchToDelete -eq "master") {
                Write-Host "  ⚠️  Cannot delete main/master branch - skipping" -ForegroundColor Red
                return
            }
            
            # Get the default branch
            $defaultBranch = Get-DefaultBranch -RepoPath $RepoPath
            Write-Host "  Default branch: $defaultBranch" -ForegroundColor Gray
            
            # Switch to default branch
            Write-Host "  Switching to $defaultBranch" -ForegroundColor Green
            git checkout $defaultBranch
            
            # Check if the branch exists locally
            $localBranches = git branch --format="%(refname:short)"
            if ($localBranches -contains $BranchToDelete) {
                Write-Host "  Deleting local branch: $BranchToDelete" -ForegroundColor Yellow
                git branch -D $BranchToDelete
                Write-Host "  ✓ Local branch deleted" -ForegroundColor Green
            }
            else {
                Write-Host "  - Local branch '$BranchToDelete' does not exist" -ForegroundColor Gray
            }
            
            # Delete remote branch if requested
            if ($DeleteRemote) {
                $remoteBranches = git branch -r --format="%(refname:short)"
                if ($remoteBranches -contains "origin/$BranchToDelete") {
                    Write-Host "  Deleting remote branch: origin/$BranchToDelete" -ForegroundColor Yellow
                    git push origin --delete $BranchToDelete
                    Write-Host "  ✓ Remote branch deleted" -ForegroundColor Green
                }
                else {
                    Write-Host "  - Remote branch 'origin/$BranchToDelete' does not exist" -ForegroundColor Gray
                }
            }
            
            # Pull latest changes if requested
            if ($Pull) {
                Write-Host "  Pulling latest changes" -ForegroundColor Green
                git pull
                Write-Host "  ✓ Latest changes pulled" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "  ❌ Error processing repository: $_" -ForegroundColor Red
        }
        finally {
            Pop-Location
        }
    }

    # Main execution
    Write-Host "Starting branch cleanup: removing '$Branch'" -ForegroundColor White
    Write-Host "Root path: $RootPath" -ForegroundColor White

    if ($DeleteRemote) {
        Write-Host "Delete remote: Enabled" -ForegroundColor White
    }

    if ($Pull) {
        Write-Host "Pull latest: Enabled" -ForegroundColor White
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
            Process-OctoRepository -RepoPath $dir -BranchToDelete $Branch -DeleteRemote $DeleteRemote -Pull $Pull
        }
        else {
            Write-Host "`nSkipping $dir (no .git directory)" -ForegroundColor Yellow
        }
    }

    Write-Host "`nBranch cleanup completed!" -ForegroundColor Green
}

# Export the function
Export-ModuleMember -Function Remove-OctoBranch
