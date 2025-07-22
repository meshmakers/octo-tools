function Invoke-CommitSubmoduleUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryPath,
        
        [Parameter()]
        [switch]$DryRun = $false,
        
        [Parameter()]
        [switch]$Push = $false
    )

    Write-Host "Processing repository: $RepositoryPath" -ForegroundColor Yellow
    
    if (-not (Test-Path $RepositoryPath)) {
        Write-Error "Repository path does not exist: $RepositoryPath"
        return $false
    }
    
    try {
        Push-Location $RepositoryPath
        
        # Check if this is a git repository
        if (-not (Test-Path ".git")) {
            Write-Host "  Not a git repository, skipping..." -ForegroundColor Gray
            return $false
        }
        
        # Check if repository has submodules
        if (-not (Test-Path ".gitmodules")) {
            Write-Host "  No submodules found, skipping..." -ForegroundColor Gray
            return $false
        }
        
        # Check for submodule pointer changes
        $statusOutput = git status --porcelain 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to get git status: $statusOutput"
        }
        
        # Look for submodule changes (both staged 'M ' and unstaged ' M')
        $submoduleChanges = $statusOutput | Where-Object { 
            ($_ -match '^(M | M)\s+\S+') -and 
            (Test-Path (($_ -replace '^\s*[M]\s+', '').Trim() -split '\s+')[0] -PathType Container)
        }
        
        if ($submoduleChanges.Count -eq 0) {
            Write-Host "  No submodule pointer changes detected, skipping..." -ForegroundColor Gray
            return $false
        }
        
        Write-Host "  Found $($submoduleChanges.Count) submodule pointer change(s):" -ForegroundColor Green
        $submodulePaths = @()
        foreach ($change in $submoduleChanges) {
            $submodulePath = ($change -replace '^\s*[M]\s+', '').Trim() -split '\s+' | Select-Object -First 1
            $submodulePaths += $submodulePath
            Write-Host "    - $submodulePath" -ForegroundColor Gray
            
            # Check if the submodule itself has pending changes
            if (Test-Path $submodulePath) {
                try {
                    Push-Location $submodulePath
                    $submoduleStatus = git status --porcelain 2>&1
                    if ($LASTEXITCODE -eq 0 -and $submoduleStatus -and ($submoduleStatus | Out-String).Trim()) {
                        Write-Warning "    ⚠️  Submodule '$submodulePath' has pending changes - skipping commit"
                        Write-Host "      Pending changes in submodule:" -ForegroundColor Yellow
                        $submoduleStatus | ForEach-Object { Write-Host "        $_" -ForegroundColor Yellow }
                        return $false
                    }
                }
                finally {
                    Pop-Location
                }
            }
        }
        
        # Create commit message
        if ($submodulePaths.Count -eq 1) {
            $commitMessage = "Update submodule pointer for $($submodulePaths[0])"
        } else {
            $commitMessage = "Update submodule pointers for $($submodulePaths.Count) submodules"
        }
        
        if ($DryRun) {
            Write-Host "  [DRY RUN] Would commit submodule updates with message: '$commitMessage'" -ForegroundColor Cyan
            if ($Push) {
                Write-Host "  [DRY RUN] Would push changes to origin" -ForegroundColor Cyan
            }
            return $true
        }
        
        # Stage submodule changes
        Write-Host "  Staging submodule pointer changes..." -ForegroundColor Cyan
        $addResult = git add . 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to stage changes: $addResult"
        }
        
        # Commit the changes
        Write-Host "  Committing changes: '$commitMessage'" -ForegroundColor Cyan
        $commitResult = git commit -m $commitMessage 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to commit changes: $commitResult"
        }
        
        Write-Host "  Successfully committed submodule updates" -ForegroundColor Green
        
        # Push if requested
        if ($Push) {
            Write-Host "  Pushing changes to origin..." -ForegroundColor Cyan
            $pushResult = git push origin 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to push changes: $pushResult"
            }
            Write-Host "  Successfully pushed changes to origin" -ForegroundColor Green
        }
        
        return $true
    }
    catch {
        Write-Error "  Error: $_"
        return $false
    }
    finally {
        Pop-Location
    }
}

Export-ModuleMember -Function Invoke-CommitSubmoduleUpdate