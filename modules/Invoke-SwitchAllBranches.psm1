function Invoke-SwitchAllBranches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter()]
        [switch]$Push = $false,
        
        [Parameter()]
        [switch]$IncludeSubmodules = $false
    )

    # Import the Find-AllGitRepos module if not already loaded
    if (-not (Get-Command Find-AllGitRepos -ErrorAction SilentlyContinue)) {
        $modulePath = Join-Path $PSScriptRoot "Find-AllGitRepos.psm1"
        Import-Module $modulePath -Force
    }

    Write-Host "Switching all repositories to branch: $Name" -ForegroundColor Cyan
    if ($IncludeSubmodules) {
        Write-Host "Including submodules in branch switching" -ForegroundColor Cyan
    }
    
    # Get all git repositories
    $repos = Find-AllGitRepos -IncludeSubmodules:$IncludeSubmodules
    
    if ($repos.Count -eq 0) {
        Write-Warning "No Git repositories found"
        return
    }
    
    Write-Host "Found $($repos.Count) repositories" -ForegroundColor Green
    
    $branchesCreated = @()
    $branchesExisted = @()
    $branchesSkipped = @()
    $errors = @()
    
    foreach ($repo in $repos) {
        Write-Host "`nProcessing: $repo" -ForegroundColor Yellow
        
        try {
            Push-Location $repo
            
            # Check if in detached HEAD state (common for submodules)
            $symbolicRef = git symbolic-ref -q HEAD 2>&1
            $isDetached = $LASTEXITCODE -ne 0
            
            if ($isDetached) {
                Write-Verbose "Repository is in detached HEAD state, attempting to checkout default branch first..."
                
                # Try to find and checkout the default branch
                $defaultBranch = git symbolic-ref refs/remotes/origin/HEAD
                if ($LASTEXITCODE -eq 0 -and $defaultBranch -match 'refs/remotes/origin/(.+)$') {
                    $defaultBranchName = $Matches[1]
                    Write-Verbose "Checking out default branch: $defaultBranchName"
                    $checkoutResult = git checkout $defaultBranchName 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        # If default branch doesn't exist locally, create it
                        $checkoutResult = git checkout -b $defaultBranchName origin/$defaultBranchName 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            Write-Verbose "Could not checkout default branch: $checkoutResult"
                        }
                    }
                } else {
                    # Fallback to main or master
                    $checkoutResult = git checkout main 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $checkoutResult = git checkout master 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            Write-Verbose "Could not checkout main or master branch"
                        }
                    }
                }
            }
            
            # Check if we're already on the target branch
            $currentBranch = git branch --show-current 2>&1
            if ($LASTEXITCODE -eq 0 -and $currentBranch -and $currentBranch.Trim() -eq $Name) {
                Write-Host "  Already on branch '$Name', skipping..." -ForegroundColor Gray
                $branchesSkipped += $repo
                continue
            }
            
            # Fetch latest from origin to ensure we have all remote branches
            Write-Verbose "Fetching from origin..."
            $fetchResult = git fetch origin 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to fetch from origin: $fetchResult"
            }
            
            # Check if branch exists on origin
            $remoteBranches = git branch -r 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to list remote branches: $remoteBranches"
            }
            
            $branchExistsOnOrigin = $remoteBranches -match "origin/$Name"
            
            if ($branchExistsOnOrigin) {
                Write-Host "  Branch '$Name' exists on origin, switching to it..." -ForegroundColor Green
                
                # Check if branch exists locally
                $localBranches = git branch 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to list local branches: $localBranches"
                }
                
                $branchExistsLocally = $localBranches -match "^\*?\s+$Name$"
                
                if ($branchExistsLocally) {
                    # Switch to existing local branch
                    $checkoutResult = git checkout $Name 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to checkout branch: $checkoutResult"
                    }
                    
                    # Ensure upstream tracking is configured for existing local branch
                    try {
                        Write-Verbose "Ensuring upstream tracking is configured for existing branch '$Name'..."
                        $upstreamResult = git branch --set-upstream-to=origin/$Name 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Verbose "  Upstream tracking configured for '$Name'"
                        } else {
                            Write-Verbose "  Note: Could not set upstream tracking: $upstreamResult"
                        }
                    } catch {
                        Write-Verbose "  Note: Could not set upstream tracking: $_"
                    }
                    
                    # Pull latest changes
                    $pullResult = git pull origin $Name 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to pull from origin: $pullResult"
                    }
                }
                else {
                    # Create local branch tracking remote
                    $checkoutResult = git checkout -b $Name origin/$Name 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to create tracking branch: $checkoutResult"
                    }
                }
                
                $branchesExisted += $repo
                Write-Host "  Successfully switched to branch '$Name'" -ForegroundColor Green
            }
            else {
                Write-Host "  Branch '$Name' does not exist on origin, creating new branch..." -ForegroundColor Yellow
                
                # Create and checkout new branch
                $checkoutResult = git checkout -b $Name 2>&1
                if ($LASTEXITCODE -ne 0) {
                    # Try to switch if branch exists locally
                    $checkoutResult = git checkout $Name 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to create or switch to branch: $checkoutResult"
                    }
                }
                
                # Set up upstream tracking for the branch (regardless of Push flag)
                try {
                    Write-Verbose "Setting up upstream tracking for branch '$Name'..."
                    $upstreamResult = git branch --set-upstream-to=origin/$Name 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Verbose "  Upstream tracking configured for '$Name'"
                    } else {
                        Write-Verbose "  Note: Could not set upstream tracking (branch may not exist on origin yet): $upstreamResult"
                    }
                } catch {
                    Write-Verbose "  Note: Could not set upstream tracking: $_"
                }
                
                $branchesCreated += $repo
                Write-Host "  Successfully created branch '$Name'" -ForegroundColor Green
                
                # Push to origin if requested
                if ($Push) {
                    Write-Host "  Pushing new branch to origin..." -ForegroundColor Cyan
                    $pushResult = git push -u origin $Name 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to push branch to origin: $pushResult"
                    }
                    Write-Host "  Successfully pushed branch to origin" -ForegroundColor Green
                }
            }
        }
        catch {
            $errors += @{
                Repository = $repo
                Error = $_.Exception.Message
            }
            Write-Error "  Error: $_"
        }
        finally {
            Pop-Location
        }
    }
    
    # Summary
    Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
    Write-Host "Total repositories processed: $($repos.Count)" -ForegroundColor White
    
    if ($branchesExisted.Count -gt 0) {
        Write-Host "`nBranches that already existed on origin ($($branchesExisted.Count)):" -ForegroundColor Green
        foreach ($repo in $branchesExisted) {
            Write-Host "  - $repo" -ForegroundColor Gray
        }
    }
    
    if ($branchesSkipped.Count -gt 0) {
        Write-Host "`nRepositories already on target branch ($($branchesSkipped.Count)):" -ForegroundColor Gray
        foreach ($repo in $branchesSkipped) {
            Write-Host "  - $repo" -ForegroundColor Gray
        }
    }
    
    if ($branchesCreated.Count -gt 0) {
        Write-Host "`nNew branches created ($($branchesCreated.Count)):" -ForegroundColor Yellow
        foreach ($repo in $branchesCreated) {
            Write-Host "  - $repo" -ForegroundColor Gray
        }
        
        if ($Push) {
            Write-Host "`nAll new branches were pushed to origin" -ForegroundColor Green
        }
        else {
            Write-Host "`nNew branches were NOT pushed to origin (use -Push parameter to push)" -ForegroundColor Yellow
        }
    }
    
    if ($errors.Count -gt 0) {
        Write-Host "`nErrors encountered ($($errors.Count)):" -ForegroundColor Red
        foreach ($error in $errors) {
            Write-Host "  - $($error.Repository): $($error.Error)" -ForegroundColor Red
        }
    }
    
    Write-Host "=============================" -ForegroundColor Cyan
}

Export-ModuleMember -Function Invoke-SwitchAllBranches