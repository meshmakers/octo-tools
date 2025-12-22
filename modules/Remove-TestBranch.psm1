<#
.Synopsis
Removes a test branch from all octo-* git repositories
.Description
This function removes a test branch with format test/0.x-word from all octo-* repositories.
Branch naming rules:
- Prefix 'test/' is mandatory
- Major version must be 0
- Minor version range: 2-999
- Description must be a single word (letters, numbers, underscore only)
- Separator '-' between version and description is mandatory
.Example
Remove-TestBranch -MinorVersion 5 -Description "queries"
# Removes branch test/0.5-queries (local and remote)
.Example
Remove-TestBranch -MinorVersion 12 -Description "my_feature" -LocalOnly
# Removes branch test/0.12-my_feature (local only, keeps remote)
.Example
Remove-TestBranch -MinorVersion 5 -Description "queries" -branch "branches/queries"
# Removes branch test/0.5-queries in subdirectory branches/queries
.Parameter MinorVersion
The minor version number (2-999) to use in branch name. Major version is always 0.
.Parameter Description
A single word (letters, numbers, underscore only) to append to branch name
.Parameter branch
Optional subdirectory path relative to rootPath where repositories are located
.Parameter LocalOnly
Only delete local branches, keep remote branches
#>
function Remove-TestBranch {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(2, 999)]
        [int]$MinorVersion,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-zA-Z0-9_]+$')]
        [ValidateScript({
            if ($_ -match '\s') {
                throw "Description must be a single word without spaces"
            }
            if ($_ -match '-') {
                throw "Description must not contain hyphens"
            }
            return $true
        })]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [string]$branch = "",

        [Parameter(Mandatory = $false)]
        [switch]$LocalOnly
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    if (!(Test-Path $branchRootPath)) {
        Write-Error "Branch root path $branchRootPath does not exist"
        return
    }

    $branchName = "test/0.$MinorVersion-$Description"
    $status = @{}

    Write-Host "Removing test branch '$branchName' in '$branchRootPath'" -ForegroundColor Cyan

    # Get all directories starting with "octo-"
    $octoDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"

    foreach ($directory in $octoDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        $directoryName = $directory.Name

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            try {
                Write-Host "Processing repository $directoryName" -ForegroundColor Green

                Push-Location $directory.FullName

                # Check current branch
                $currentBranch = git branch --show-current 2>$null
                if ($currentBranch -eq $branchName) {
                    # Switch to main/master first
                    Write-Host "  Currently on '$branchName', switching to default branch..." -ForegroundColor Yellow
                    $switched = $false
                    foreach ($defaultBranch in @("main", "master")) {
                        git checkout $defaultBranch 2>$null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "  Switched to '$defaultBranch'" -ForegroundColor Blue
                            $switched = $true
                            break
                        }
                    }
                    if (-not $switched) {
                        throw "Cannot switch away from branch '$branchName'. Please checkout another branch first."
                    }
                }

                $localDeleted = $false
                $remoteDeleted = $false

                # Check if local branch exists
                $localBranchExists = git branch --list $branchName 2>$null
                if ($localBranchExists) {
                    # Delete local branch
                    git branch -D $branchName
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to delete local branch $branchName"
                    }
                    Write-Host "  Local branch '$branchName' deleted" -ForegroundColor Blue
                    $localDeleted = $true
                } else {
                    Write-Host "  Local branch '$branchName' does not exist" -ForegroundColor Gray
                }

                # Delete remote branch if not LocalOnly
                if (-not $LocalOnly) {
                    $remoteBranchExists = git ls-remote --heads origin $branchName 2>$null
                    if ($remoteBranchExists) {
                        git push origin --delete $branchName
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to delete remote branch $branchName"
                        }
                        Write-Host "  Remote branch '$branchName' deleted" -ForegroundColor Blue
                        $remoteDeleted = $true
                    } else {
                        Write-Host "  Remote branch '$branchName' does not exist" -ForegroundColor Gray
                    }
                }

                Pop-Location
                $status.Add($directoryName, @{Success = $true; LocalDeleted = $localDeleted; RemoteDeleted = $remoteDeleted})

            } catch {
                Write-Host "Error processing repository $directoryName : $_" -ForegroundColor Red
                Pop-Location
                $status.Add($directoryName, @{Success = $false; LocalDeleted = $false; RemoteDeleted = $false})
            }
        } else {
            Write-Host "Skipping $directoryName (no git repository)" -ForegroundColor Yellow
        }
    }

    # Summary
    Write-Host ""
    Write-Host "Branch removal summary:" -ForegroundColor Cyan
    $localDeletedCount = 0
    $remoteDeletedCount = 0
    $skippedCount = 0
    $failedCount = 0

    foreach($key in $status.Keys) {
        $repoStatus = $status[$key]
        if ($repoStatus.Success) {
            if ($repoStatus.LocalDeleted -or $repoStatus.RemoteDeleted) {
                $deletedParts = @()
                if ($repoStatus.LocalDeleted) {
                    $deletedParts += "local"
                    $localDeletedCount++
                }
                if ($repoStatus.RemoteDeleted) {
                    $deletedParts += "remote"
                    $remoteDeletedCount++
                }
                Write-Host "  - $key - Deleted ($($deletedParts -join ', '))" -ForegroundColor Green
            } else {
                Write-Host "  - $key - Branch not found" -ForegroundColor Gray
                $skippedCount++
            }
        } else {
            Write-Host "  x $key - Failed" -ForegroundColor Red
            $failedCount++
        }
    }

    Write-Host ""
    Write-Host "Done. Branch '$branchName': $localDeletedCount local deleted, $remoteDeletedCount remote deleted, $skippedCount not found, $failedCount failed" -ForegroundColor Cyan
}

Export-ModuleMember -Function @('Remove-TestBranch')
