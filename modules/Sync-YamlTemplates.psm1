function Get-RepositoryPaths {
    param(
        [Parameter(Mandatory=$true)]
        [string]$branchPath
    )
    
    $repositories = @()
    
    # Get all octo-* and mm-* directories
    $octoDirectories = Get-ChildItem -Directory -Path $branchPath -Filter "octo-*"
    $mmDirectories = Get-ChildItem -Directory -Path $branchPath -Filter "mm-*"
    
    foreach ($dir in ($octoDirectories + $mmDirectories)) {
        $devopsBuildPath = Join-Path -Path $dir.FullName -ChildPath "devops-build"
        if (Test-Path $devopsBuildPath) {
            $repositories += $devopsBuildPath
        }
    }
    
    return $repositories
}

function Sync-YamlFiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$sourceDirectory,
        [Parameter(Mandatory=$true)]
        [string]$branchPath,
        [string[]]$excludeFiles = @("azure-pipelines.yml")
    )
    
    if (!(Test-Path $sourceDirectory)) {
        Write-Error "Source directory $sourceDirectory does not exist"
        return
    }
    
    if (!(Test-Path $branchPath)) {
        Write-Error "Branch path $branchPath does not exist"
        return
    }
    
    # Get all YAML files from source directory except excluded ones
    $sourceFiles = Get-ChildItem -Path $sourceDirectory -Filter "*.yml" | 
                   Where-Object { $_.Name -notin $excludeFiles }
    
    if ($sourceFiles.Count -eq 0) {
        Write-Host "No YAML files found to synchronize" -ForegroundColor Yellow
        return
    }
    
    # Get all repository paths that have devops-build directories
    $repositoryPaths = Get-RepositoryPaths -branchPath $branchPath
    
    if ($repositoryPaths.Count -eq 0) {
        Write-Host "No repositories with devops-build directories found" -ForegroundColor Yellow
        return
    }
    
    $syncedCount = 0
    $errorCount = 0
    
    Write-Host "Synchronizing YAML files..." -ForegroundColor Cyan
    Write-Host "Source: $sourceDirectory" -ForegroundColor Gray
    Write-Host "Files to sync: $($sourceFiles.Name -join ', ')" -ForegroundColor Gray
    Write-Host ""
    
    foreach ($repoPath in $repositoryPaths) {
        $repoName = Split-Path (Split-Path $repoPath -Parent) -Leaf
        
        try {
            $filesCopied = 0
            foreach ($sourceFile in $sourceFiles) {
                $targetPath = Join-Path -Path $repoPath -ChildPath $sourceFile.Name
                
                # Only copy if target file already exists
                if (Test-Path $targetPath) {
                    Copy-Item -Path $sourceFile.FullName -Destination $targetPath -Force
                    $filesCopied++
                }
            }
            
            if ($filesCopied -gt 0) {
                Write-Host "✓ Synced $repoName ($filesCopied files)" -ForegroundColor Green
                $syncedCount++
            } else {
                Write-Host "○ Skipped $repoName (no matching files)" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "✗ Failed to sync $repoName : $($_.Exception.Message)" -ForegroundColor Red
            $errorCount++
        }
    }
    
    Write-Host ""
    Write-Host "Synchronization completed:" -ForegroundColor Cyan
    Write-Host "  Repositories synced: $syncedCount" -ForegroundColor Green
    Write-Host "  Errors: $errorCount" -ForegroundColor $(if($errorCount -gt 0){"Red"}else{"Green"})
    Write-Host "  Files per repository: $($sourceFiles.Count)" -ForegroundColor Gray
}

function Invoke-SyncYamlTasks {
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$sourceRepo
    )
    
    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $sourceDirectory = Join-Path -Path $branchRootPath -ChildPath "$sourceRepo/devops-build"
    
    Sync-YamlFiles -sourceDirectory $sourceDirectory -branchPath $branchRootPath
}

Export-ModuleMember -Function @('Invoke-SyncYamlTasks')