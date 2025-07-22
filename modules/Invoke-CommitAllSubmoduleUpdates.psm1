function Invoke-CommitAllSubmoduleUpdates {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$DryRun = $false,
        
        [Parameter()]
        [switch]$Push = $false
    )

    # Import required modules
    if (-not (Get-Command Find-AllGitRepos -ErrorAction SilentlyContinue)) {
        $modulePath = Join-Path $PSScriptRoot "Find-AllGitRepos.psm1"
        Import-Module $modulePath -Force
    }
    
    if (-not (Get-Command Invoke-CommitSubmoduleUpdate -ErrorAction SilentlyContinue)) {
        $modulePath = Join-Path $PSScriptRoot "Invoke-CommitSubmoduleUpdate.psm1"
        Import-Module $modulePath -Force
    }

    Write-Host "Committing submodule updates across all repositories" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "DRY RUN MODE - No changes will be made" -ForegroundColor Yellow
    }
    if ($Push) {
        Write-Host "Changes will be pushed to origin" -ForegroundColor Cyan
    }
    
    # Get all git repositories (exclude submodules - we only want main repos)
    $repos = Find-AllGitRepos -IncludeSubmodules:$false
    
    if ($repos.Count -eq 0) {
        Write-Warning "No Git repositories found"
        return
    }
    
    Write-Host "Found $($repos.Count) main repositories" -ForegroundColor Green
    
    $reposWithUpdates = @()
    $reposSkipped = @()
    $reposWithPendingChanges = @()
    $errors = @()
    
    foreach ($repo in $repos) {
        Write-Host "`nProcessing: $repo" -ForegroundColor Yellow
        
        try {
            $result = Invoke-CommitSubmoduleUpdate -RepositoryPath $repo -DryRun:$DryRun -Push:$Push
            
            if ($result) {
                $reposWithUpdates += $repo
            } else {
                # Check if it was skipped due to pending changes vs no changes
                Push-Location $repo
                try {
                    if (Test-Path ".gitmodules") {
                        $statusOutput = git status --porcelain 2>&1
                        if ($LASTEXITCODE -eq 0) {
                            $submoduleChanges = $statusOutput | Where-Object { 
                                ($_ -match '^(M | M)\s+\S+') -and 
                                (Test-Path (($_ -replace '^\s*[M]\s+', '').Trim() -split '\s+')[0] -PathType Container)
                            }
                            if ($submoduleChanges.Count -gt 0) {
                                # Has submodule changes but was skipped - likely due to pending changes in submodule
                                $reposWithPendingChanges += $repo
                            } else {
                                $reposSkipped += $repo
                            }
                        } else {
                            $reposSkipped += $repo
                        }
                    } else {
                        $reposSkipped += $repo
                    }
                }
                finally {
                    Pop-Location
                }
            }
        }
        catch {
            $errors += @{
                Repository = $repo
                Error = $_.Exception.Message
            }
            Write-Error "  Error processing $repo`: $_"
        }
    }
    
    # Summary
    Write-Host "`n========== Summary ===========" -ForegroundColor Cyan
    Write-Host "Total repositories processed: $($repos.Count)" -ForegroundColor White
    
    if ($reposWithUpdates.Count -gt 0) {
        $actionVerb = if ($DryRun) { "Would commit" } else { "Committed" }
        Write-Host "`nRepositories with submodule updates $actionVerb ($($reposWithUpdates.Count)):" -ForegroundColor Green
        foreach ($repo in $reposWithUpdates) {
            Write-Host "  ✓ $repo" -ForegroundColor Green
        }
        
        if ($Push -and -not $DryRun) {
            Write-Host "`nAll commits were pushed to origin" -ForegroundColor Green
        } elseif ($Push -and $DryRun) {
            Write-Host "`nWould push all commits to origin" -ForegroundColor Yellow
        } elseif (-not $DryRun) {
            Write-Host "`nCommits were NOT pushed (use -Push parameter to push)" -ForegroundColor Yellow
        }
    }
    
    if ($reposWithPendingChanges.Count -gt 0) {
        Write-Host "`nRepositories skipped due to pending changes in submodules ($($reposWithPendingChanges.Count)):" -ForegroundColor Yellow
        foreach ($repo in $reposWithPendingChanges) {
            Write-Host "  ⚠️  $repo" -ForegroundColor Yellow
        }
        Write-Host "  Resolve pending changes in submodules before committing pointer updates" -ForegroundColor Yellow
    }
    
    if ($reposSkipped.Count -gt 0) {
        Write-Host "`nRepositories with no submodule updates ($($reposSkipped.Count)):" -ForegroundColor Gray
        foreach ($repo in $reposSkipped) {
            Write-Host "  - $repo" -ForegroundColor Gray
        }
    }
    
    if ($errors.Count -gt 0) {
        Write-Host "`nErrors encountered ($($errors.Count)):" -ForegroundColor Red
        foreach ($error in $errors) {
            Write-Host "  ❌ $($error.Repository): $($error.Error)" -ForegroundColor Red
        }
    }
    
    Write-Host "==============================" -ForegroundColor Cyan
}

Export-ModuleMember -Function Invoke-CommitAllSubmoduleUpdates