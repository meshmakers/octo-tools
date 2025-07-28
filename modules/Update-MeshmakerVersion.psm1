function Update-MeshmakerVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [string]$branch = ""
    )
    
    Write-Host "Updating MeshmakerVersion to $Version in all octo-* repositories..." -ForegroundColor Green

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
    
    # Find all octo-* directories
    $octoDirectories = Get-ChildItem -Path $branchRootPath -Directory -Name "octo-*"
    
    if ($octoDirectories.Count -eq 0) {
        Write-Warning "No octo-* directories found in $branchRootPath"
        return
    }
    
    $updatedCount = 0
    
    foreach ($dir in $octoDirectories) {
        $fullPath = Join-Path $branchRootPath $dir
        $buildPropsPath = Join-Path $fullPath "Directory.Build.props"
        
        if (Test-Path $buildPropsPath) {
            Write-Host "Processing: $dir" -ForegroundColor Cyan
            
            try {
                $content = Get-Content $buildPropsPath -Raw
                
                # Pattern for MeshmakerVersion Property
                $pattern = '(<MeshmakerVersion>)[^<]*(</MeshmakerVersion>)'
                
                if ($content -match $pattern) {
                    $newContent = $content -replace $pattern, "`$1$Version`$2"
                    Set-Content -Path $buildPropsPath -Value $newContent -NoNewline
                    Write-Host "  ✓ Updated MeshmakerVersion to $Version" -ForegroundColor Green
                    $updatedCount++
                } else {
                    Write-Warning "  ⚠ MeshmakerVersion property not found in $buildPropsPath"
                }
            }
            catch {
                Write-Error "  ✗ Failed to update $buildPropsPath`: $($_.Exception.Message)"
            }
        } else {
            Write-Warning "  ⚠ Directory.Build.props not found in $dir"
        }
    }
    
    Write-Host "`nSummary: Updated $updatedCount of $($octoDirectories.Count) repositories" -ForegroundColor Green
}

Export-ModuleMember -Function Update-MeshmakerVersion
