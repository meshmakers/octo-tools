<#
.Synopsis
Syncs a test branch with main for all octo-* git repositories
.Description
This function merges changes from main into a test branch with format test/0.x-word for all octo-* repositories.
It provides clear status information when manual intervention is required (e.g., merge conflicts).
Branch naming rules:
- Prefix 'test/' is mandatory
- Major version must be 0
- Minor version range: 2-999
- Description must be a single word (letters, numbers, underscore only)
- Separator '-' between version and description is mandatory
.Example
Sync-TestBranch -MinorVersion 5 -Description "queries"
# Merges main into test/0.5-queries for all repositories
.Example
Sync-TestBranch -MinorVersion 12 -Description "my_feature" -branch "branches/queries"
# Merges main into test/0.12-my_feature in subdirectory branches/queries
.Example
Sync-TestBranch -MinorVersion 5 -Description "queries" -NoPush
# Merges but does not push the result to origin
.Parameter MinorVersion
The minor version number (2-999) to use in branch name. Major version is always 0.
.Parameter Description
A single word (letters, numbers, underscore only) to append to branch name
.Parameter branch
Optional subdirectory path relative to rootPath where repositories are located
.Parameter NoPush
Skip pushing the merged branch to remote origin
#>
function Sync-TestBranch {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
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
        [switch]$NoPush
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
    $manualActionRequired = @()

    Write-Host "Syncing test branch '$branchName' with main in '$branchRootPath'" -ForegroundColor Cyan
    Write-Host ""

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

                # Fetch latest from origin
                Write-Host "  Fetching from origin..." -ForegroundColor Gray
                git fetch origin 2>$null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to fetch from origin"
                }

                # Check if test branch exists locally or remotely
                $localBranchExists = git branch --list $branchName 2>$null
                $remoteBranchExists = git ls-remote --heads origin $branchName 2>$null

                if (-not $localBranchExists -and -not $remoteBranchExists) {
                    Write-Host "  Branch '$branchName' does not exist (local or remote)" -ForegroundColor Yellow
                    Pop-Location
                    $status.Add($directoryName, @{
                        Success = $true
                        Status = "BranchNotFound"
                        Message = "Branch does not exist"
                    })
                    continue
                }

                # Save current branch to return later
                $originalBranch = git branch --show-current 2>$null

                # Checkout test branch
                if ($localBranchExists) {
                    git checkout $branchName 2>$null
                } else {
                    # Create local tracking branch from remote
                    git checkout -b $branchName origin/$branchName 2>$null
                }
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to checkout branch $branchName"
                }

                # Pull latest changes from test branch (if remote exists)
                if ($remoteBranchExists) {
                    Write-Host "  Pulling latest from origin/$branchName..." -ForegroundColor Gray
                    git pull origin $branchName 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to pull from origin/$branchName"
                    }
                }

                # Check if main exists
                $mainBranch = $null
                foreach ($defaultBranch in @("main", "master")) {
                    $exists = git ls-remote --heads origin $defaultBranch 2>$null
                    if ($exists) {
                        $mainBranch = $defaultBranch
                        break
                    }
                }

                if (-not $mainBranch) {
                    throw "No main or master branch found on remote"
                }

                # Check if there are uncommitted changes
                $uncommittedChanges = git status --porcelain 2>$null
                if ($uncommittedChanges) {
                    Write-Host "  WARNING: Uncommitted changes detected!" -ForegroundColor Red
                    Pop-Location
                    $manualActionRequired += @{
                        Repository = $directoryName
                        Reason = "Uncommitted changes"
                        Details = "Please commit or stash your changes first"
                        Path = $directory.FullName
                    }
                    $status.Add($directoryName, @{
                        Success = $false
                        Status = "UncommittedChanges"
                        Message = "Uncommitted changes detected"
                    })
                    continue
                }

                # Check if merge is needed
                $behindCount = git rev-list --count "$branchName..origin/$mainBranch" 2>$null
                if ($behindCount -eq 0) {
                    Write-Host "  Already up to date with $mainBranch" -ForegroundColor Blue
                    Pop-Location
                    $status.Add($directoryName, @{
                        Success = $true
                        Status = "UpToDate"
                        Message = "Already up to date"
                    })
                    continue
                }

                Write-Host "  $behindCount commit(s) behind $mainBranch, merging..." -ForegroundColor Yellow

                # Attempt merge
                $mergeOutput = git merge "origin/$mainBranch" --no-edit 2>&1
                if ($LASTEXITCODE -ne 0) {
                    # Check for merge conflicts
                    $conflictFiles = git diff --name-only --diff-filter=U 2>$null
                    if ($conflictFiles) {
                        Write-Host "  MERGE CONFLICT detected!" -ForegroundColor Red

                        # Abort the merge to leave repo in clean state
                        git merge --abort 2>$null

                        Pop-Location
                        $manualActionRequired += @{
                            Repository = $directoryName
                            Reason = "Merge conflict"
                            Details = "Conflicts in: $($conflictFiles -join ', ')"
                            Path = $directory.FullName
                            Command = "cd `"$($directory.FullName)`" && git merge origin/$mainBranch"
                        }
                        $status.Add($directoryName, @{
                            Success = $false
                            Status = "MergeConflict"
                            Message = "Merge conflict with $mainBranch"
                            ConflictFiles = $conflictFiles
                        })
                        continue
                    } else {
                        throw "Merge failed: $mergeOutput"
                    }
                }

                Write-Host "  Merge successful" -ForegroundColor Green

                # Push if not NoPush
                if (-not $NoPush) {
                    Write-Host "  Pushing to origin..." -ForegroundColor Gray
                    git push origin $branchName 2>$null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "  WARNING: Push failed!" -ForegroundColor Red
                        Pop-Location
                        $manualActionRequired += @{
                            Repository = $directoryName
                            Reason = "Push failed"
                            Details = "Merge was successful but push failed. Please push manually."
                            Path = $directory.FullName
                            Command = "cd `"$($directory.FullName)`" && git push origin $branchName"
                        }
                        $status.Add($directoryName, @{
                            Success = $false
                            Status = "PushFailed"
                            Message = "Merge successful but push failed"
                        })
                        continue
                    }
                    Write-Host "  Pushed successfully" -ForegroundColor Green
                }

                Pop-Location
                $status.Add($directoryName, @{
                    Success = $true
                    Status = "Synced"
                    Message = "Merged $behindCount commit(s) from $mainBranch"
                    CommitsMerged = $behindCount
                })

            } catch {
                Write-Host "  Error: $_" -ForegroundColor Red
                # Try to return to original branch
                git checkout $originalBranch 2>$null
                Pop-Location
                $status.Add($directoryName, @{
                    Success = $false
                    Status = "Error"
                    Message = $_.ToString()
                })
            }
        } else {
            Write-Host "Skipping $directoryName (no git repository)" -ForegroundColor Yellow
        }
    }

    # Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "SYNC SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $syncedCount = 0
    $upToDateCount = 0
    $notFoundCount = 0
    $failedCount = 0

    foreach($key in $status.Keys) {
        $repoStatus = $status[$key]
        switch ($repoStatus.Status) {
            "Synced" {
                Write-Host "  [OK] $key - $($repoStatus.Message)" -ForegroundColor Green
                $syncedCount++
            }
            "UpToDate" {
                Write-Host "  [OK] $key - Already up to date" -ForegroundColor Blue
                $upToDateCount++
            }
            "BranchNotFound" {
                Write-Host "  [--] $key - Branch not found" -ForegroundColor Gray
                $notFoundCount++
            }
            "MergeConflict" {
                Write-Host "  [!!] $key - MERGE CONFLICT" -ForegroundColor Red
                $failedCount++
            }
            "UncommittedChanges" {
                Write-Host "  [!!] $key - Uncommitted changes" -ForegroundColor Red
                $failedCount++
            }
            "PushFailed" {
                Write-Host "  [!!] $key - Push failed" -ForegroundColor Red
                $failedCount++
            }
            "Error" {
                Write-Host "  [!!] $key - Error: $($repoStatus.Message)" -ForegroundColor Red
                $failedCount++
            }
        }
    }

    Write-Host ""
    Write-Host "Totals: $syncedCount synced, $upToDateCount up-to-date, $notFoundCount not found, $failedCount failed" -ForegroundColor Cyan

    # Manual action required section
    if ($manualActionRequired.Count -gt 0) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host "MANUAL ACTION REQUIRED" -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""

        foreach ($action in $manualActionRequired) {
            Write-Host "Repository: $($action.Repository)" -ForegroundColor Yellow
            Write-Host "  Reason:  $($action.Reason)" -ForegroundColor White
            Write-Host "  Details: $($action.Details)" -ForegroundColor Gray
            Write-Host "  Path:    $($action.Path)" -ForegroundColor Gray
            if ($action.Command) {
                Write-Host "  Command: $($action.Command)" -ForegroundColor Cyan
            }
            Write-Host ""
        }

        Write-Host "Please resolve the above issues manually and run Sync-TestBranch again." -ForegroundColor Yellow
    }

    # Return status for programmatic use
    # Convert status hashtable to array of PSCustomObjects for better display
    $statusArray = foreach ($key in $status.Keys) {
        [PSCustomObject]@{
            Repository = $key
            Status = $status[$key].Status
            Success = $status[$key].Success
            Message = $status[$key].Message
        }
    }

    return [PSCustomObject]@{
        BranchName = $branchName
        Status = $statusArray
        ManualActionRequired = $manualActionRequired
        Summary = [PSCustomObject]@{
            Synced = $syncedCount
            UpToDate = $upToDateCount
            NotFound = $notFoundCount
            Failed = $failedCount
        }
    }
}

Export-ModuleMember -Function @('Sync-TestBranch')
