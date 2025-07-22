function Invoke-GitMergeMainIntoAllBranches {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$DryRun = $false,
        
        [Parameter()]
        [string]$MainBranch = "main",
        
        [Parameter()]
        [switch]$Push = $false
    )

    Write-Host "Merging '$MainBranch' branch into all repositories" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "[DRY RUN MODE] - No changes will be made" -ForegroundColor Yellow
    }
    
    # Get all main git repositories
    $repos = Find-AllGitRepos -IncludeSubmodules:$false
    
    if ($repos.Count -eq 0) {
        Write-Warning "No Git repositories found"
        return
    }
    
    Write-Host "Found $($repos.Count) repositories" -ForegroundColor Green
    
    # Status tracking arrays
    $mergesSuccessful = @()
    $mergesSkipped = @()
    $mergesSkippedUpToDate = @()
    $mergesSkippedNoChanges = @()
    $mergeConflicts = @()
    $errors = @()
    
    function Test-BranchNeedsMerge {
        param(
            [string]$MainBranch,
            [string]$RepoPath
        )
        
        try {
            Push-Location $RepoPath
            
            # Get current branch
            $currentBranch = git branch --show-current 2>&1
            if ($LASTEXITCODE -ne 0) {
                return @{ Error = "Failed to get current branch: $currentBranch" }
            }
            
            $currentBranch = $currentBranch.Trim()
            
            # If already on main branch, no merge needed
            if ($currentBranch -eq $MainBranch) {
                return @{ 
                    NeedsMerge = $false
                    Status = "OnMainBranch"
                    Behind = 0
                    Ahead = 0
                    WouldIntroduceChanges = $false
                }
            }
            
            # Get commit counts to determine relationship
            $behindCount = 0
            $aheadCount = 0
            
            $behindResult = git rev-list --count HEAD..origin/$MainBranch 2>&1
            if ($LASTEXITCODE -eq 0 -and $behindResult -match '^\d+$') {
                $behindCount = [int]$behindResult
            }
            
            $aheadResult = git rev-list --count origin/$MainBranch..HEAD 2>&1
            if ($LASTEXITCODE -eq 0 -and $aheadResult -match '^\d+$') {
                $aheadCount = [int]$aheadResult
            }
            
            # Determine status
            $status = switch ($true) {
                ($behindCount -eq 0 -and $aheadCount -eq 0) { "UpToDate" }
                ($behindCount -gt 0 -and $aheadCount -eq 0) { "Behind" }
                ($behindCount -eq 0 -and $aheadCount -gt 0) { "Ahead" }
                default { "Diverged" }
            }
            
            # Check if merge would introduce file changes (only if behind)
            $wouldIntroduceChanges = $false
            if ($behindCount -gt 0) {
                $changes = git diff --name-only HEAD...origin/$MainBranch 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $wouldIntroduceChanges = ($changes -and ($changes | Where-Object { $_.Trim() }).Count -gt 0)
                }
            }
            
            # Determine if merge is needed
            $needsMerge = switch ($status) {
                "UpToDate" { $false }
                "Behind" { $wouldIntroduceChanges }
                "Ahead" { $false }  # No merge needed - branch has latest main + additional commits
                "Diverged" { $true }  # Always try to merge diverged branches
            }
            
            return @{
                NeedsMerge = $needsMerge
                Status = $status
                Behind = $behindCount
                Ahead = $aheadCount
                WouldIntroduceChanges = $wouldIntroduceChanges
                CurrentBranch = $currentBranch
            }
        }
        catch {
            return @{ Error = $_.Exception.Message }
        }
        finally {
            Pop-Location
        }
    }
    
    function Invoke-MergeRepository {
        param(
            [string]$RepoPath,
            [string]$Branch,
            [switch]$IsDryRun,
            [switch]$ShouldPush
        )
        
        $repoName = Split-Path -Leaf $RepoPath
        Write-Host "Processing: $repoName" -ForegroundColor Yellow
        
        try {
            Push-Location $RepoPath
            
            # Check if repository is clean
            $statusOutput = git status --porcelain 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to get repository status: $statusOutput"
            }
            
            if ($statusOutput -and ($statusOutput | Out-String).Trim()) {
                Write-Host "  Repository has pending changes, skipping merge..." -ForegroundColor Yellow
                return @{ Status = "Skipped"; Reason = "Pending changes"; Repository = $RepoPath }
            }
            
            # Get current branch
            $currentBranch = git branch --show-current 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to get current branch: $currentBranch"
            }
            $currentBranch = $currentBranch.Trim()
            
            # Fetch latest from origin (always do this, even in dry run - it's read-only)
            Write-Verbose "Fetching from origin..."
            $fetchResult = git fetch origin 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to fetch from origin: $fetchResult"
            }
            
            # Check if main branch exists on origin
            if (-not $IsDryRun) {
                $remoteBranches = git branch -r 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to list remote branches: $remoteBranches"
                }
                
                $mainBranchExists = $remoteBranches -match "origin/$Branch"
                if (-not $mainBranchExists) {
                    Write-Host "  '$Branch' branch does not exist on origin, skipping..." -ForegroundColor Yellow
                    return @{ Status = "Skipped"; Reason = "Main branch not found on origin"; Repository = $RepoPath }
                }
            }
            
            # Perform the merge
            if (-not $IsDryRun) {
                Write-Host "  Merging 'origin/$Branch' into '$currentBranch'..." -ForegroundColor Green
                $mergeResult = git merge "origin/$Branch" 2>&1
                
                if ($LASTEXITCODE -ne 0) {
                    # Check if it's a merge conflict
                    $conflictStatus = git status --porcelain 2>&1
                    if ($conflictStatus -match "^(AA|UU|DD)" -or $mergeResult -match "CONFLICT") {
                        Write-Host "  ⚠️  Merge conflict detected - manual resolution required" -ForegroundColor Red
                        
                        # Abort the merge to leave repo in clean state
                        git merge --abort 2>&1 | Out-Null
                        
                        return @{ Status = "Conflict"; Repository = $RepoPath; ConflictDetails = $mergeResult }
                    } else {
                        throw "Merge failed: $mergeResult"
                    }
                } else {
                    Write-Host "  Successfully merged 'origin/$Branch' into '$currentBranch'" -ForegroundColor Green
                    
                    # Push if requested
                    if ($ShouldPush) {
                        Write-Host "  Pushing changes to origin..." -ForegroundColor Cyan
                        $pushResult = git push origin $currentBranch 2>&1
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to push changes: $pushResult"
                        }
                        Write-Host "  Successfully pushed changes" -ForegroundColor Green
                    }
                }
            } else {
                Write-Host "  [DRY RUN] Would merge 'origin/$Branch' into '$currentBranch'" -ForegroundColor Cyan
                if ($ShouldPush) {
                    Write-Host "  [DRY RUN] Would push changes to origin" -ForegroundColor Cyan
                }
            }
            
            return @{ Status = "Success"; Repository = $RepoPath }
        }
        catch {
            return @{ Status = "Error"; Repository = $RepoPath; Error = $_.Exception.Message }
        }
        finally {
            Pop-Location
        }
    }
    
    # Process all repositories
    foreach ($repo in $repos) {
        Write-Host "`nProcessing repository: $repo" -ForegroundColor Yellow
        
        # Test if merge is needed for this repository
        $testResult = Test-BranchNeedsMerge -MainBranch $MainBranch -RepoPath $repo
        
        if ($testResult.Error) {
            $errors += @{ Repository = $repo; Error = $testResult.Error }
            Write-Error "  Error testing branch: $($testResult.Error)"
            continue
        }
        
        # Handle different skip scenarios
        if (-not $testResult.NeedsMerge) {
            $repoName = Split-Path -Leaf $repo
            switch ($testResult.Status) {
                "OnMainBranch" {
                    Write-Host "  Already on '$MainBranch' branch, skipping..." -ForegroundColor Gray
                    $mergesSkipped += @{ Repository = $repo; Reason = "Already on main branch" }
                }
                "UpToDate" {
                    Write-Host "  Branch '$($testResult.CurrentBranch)' is up-to-date with '$MainBranch', skipping..." -ForegroundColor Green
                    $mergesSkippedUpToDate += @{ Repository = $repo; Branch = $testResult.CurrentBranch; Behind = $testResult.Behind }
                }
                "Behind" {
                    Write-Host "  Branch '$($testResult.CurrentBranch)' is $($testResult.Behind) commits behind but no file changes, skipping..." -ForegroundColor Cyan
                    $mergesSkippedNoChanges += @{ Repository = $repo; Branch = $testResult.CurrentBranch; Behind = $testResult.Behind }
                }
                "Ahead" {
                    Write-Host "  Branch '$($testResult.CurrentBranch)' is $($testResult.Ahead) commits ahead of '$MainBranch', no merge needed..." -ForegroundColor Green
                    $mergesSkippedUpToDate += @{ Repository = $repo; Branch = $testResult.CurrentBranch; Ahead = $testResult.Ahead }
                }
            }
            continue
        }
        
        # Repository needs merge - show what will be merged
        $repoName = Split-Path -Leaf $repo
        Write-Host "  Branch '$($testResult.CurrentBranch)' needs merge: $($testResult.Behind) commits behind, status: $($testResult.Status)" -ForegroundColor Green
        
        # Process the repository
        $result = Invoke-MergeRepository -RepoPath $repo -Branch $MainBranch -IsDryRun:$DryRun -ShouldPush:$Push
        
        switch ($result.Status) {
            "Success" { $mergesSuccessful += $result.Repository }
            "Skipped" { $mergesSkipped += @{ Repository = $result.Repository; Reason = $result.Reason } }
            "Conflict" { $mergeConflicts += @{ Repository = $result.Repository; Details = $result.ConflictDetails } }
            "Error" { $errors += @{ Repository = $result.Repository; Error = $result.Error } }
        }
    }
    
    # Summary
    $actionVerb = if ($DryRun) { "would be merged" } else { "merged" }
    Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
    Write-Host "Total repositories processed: $($repos.Count)" -ForegroundColor White
    
    if ($mergesSuccessful.Count -gt 0) {
        Write-Host "`nRepositories successfully $actionVerb ($($mergesSuccessful.Count)):" -ForegroundColor Green
        foreach ($repo in $mergesSuccessful) {
            $repoName = Split-Path -Leaf $repo
            Write-Host "  ✓ $repoName" -ForegroundColor Gray
        }
    }
    
    if ($mergesSkippedUpToDate.Count -gt 0) {
        Write-Host "`nRepositories already up-to-date with '$MainBranch' ($($mergesSkippedUpToDate.Count)):" -ForegroundColor Green
        foreach ($skip in $mergesSkippedUpToDate) {
            $repoName = Split-Path -Leaf $skip.Repository
            Write-Host "  ✓ $repoName (branch: $($skip.Branch))" -ForegroundColor Gray
        }
    }
    
    if ($mergesSkippedNoChanges.Count -gt 0) {
        Write-Host "`nRepositories behind '$MainBranch' but no file changes to merge ($($mergesSkippedNoChanges.Count)):" -ForegroundColor Cyan
        foreach ($skip in $mergesSkippedNoChanges) {
            $repoName = Split-Path -Leaf $skip.Repository
            Write-Host "  - $repoName (branch: $($skip.Branch), $($skip.Behind) commits behind)" -ForegroundColor Gray
        }
    }
    
    if ($mergesSkipped.Count -gt 0) {
        Write-Host "`nRepositories skipped for other reasons ($($mergesSkipped.Count)):" -ForegroundColor Yellow
        foreach ($skip in $mergesSkipped) {
            $repoName = Split-Path -Leaf $skip.Repository
            Write-Host "  - $repoName ($($skip.Reason))" -ForegroundColor Gray
        }
    }
    
    if ($mergeConflicts.Count -gt 0) {
        Write-Host "`nRepositories with merge conflicts ($($mergeConflicts.Count)):" -ForegroundColor Red
        Write-Host "  These require manual resolution:" -ForegroundColor Red
        foreach ($conflict in $mergeConflicts) {
            $repoName = Split-Path -Leaf $conflict.Repository
            Write-Host "  ⚠️  $repoName" -ForegroundColor Red
        }
        Write-Host "`nTo resolve conflicts:" -ForegroundColor Yellow
        Write-Host "  1. Navigate to the repository" -ForegroundColor Yellow
        Write-Host "  2. Run: git merge origin/$MainBranch" -ForegroundColor Yellow
        Write-Host "  3. Resolve conflicts manually" -ForegroundColor Yellow
        Write-Host "  4. Run: git commit" -ForegroundColor Yellow
    }
    
    if ($errors.Count -gt 0) {
        Write-Host "`nErrors encountered ($($errors.Count)):" -ForegroundColor Red
        foreach ($error in $errors) {
            $repoName = Split-Path -Leaf $error.Repository
            Write-Host "  ❌ $repoName`: $($error.Error)" -ForegroundColor Red
        }
    }
    
    if ($Push -and $mergesSuccessful.Count -gt 0 -and -not $DryRun) {
        Write-Host "`nAll successful merges were pushed to origin" -ForegroundColor Green
    } elseif (-not $Push -and $mergesSuccessful.Count -gt 0 -and -not $DryRun) {
        Write-Host "`nChanges were NOT pushed to origin (use -Push parameter to push)" -ForegroundColor Yellow
    }
    
    Write-Host "=============================" -ForegroundColor Cyan
}

Export-ModuleMember -Function Invoke-GitMergeMainIntoAllBranches