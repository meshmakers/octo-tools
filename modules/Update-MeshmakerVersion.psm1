function Update-MeshmakerVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version,

        [string]$branch = "",

        [switch]$Json
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
    $repoResults = [System.Collections.Generic.List[object]]::new()

    foreach ($dir in $octoDirectories) {
        $fullPath = Join-Path $branchRootPath $dir
        $buildPropsPath = Join-Path $fullPath "Directory.Build.props"
        
        $repoStatus = "skipped"

        if (Test-Path $buildPropsPath) {
            Write-Host "Processing: $dir" -ForegroundColor Cyan

            try {
                $content = Get-Content $buildPropsPath -Raw

                # Pattern for MeshmakerVersion Property
                $pattern = '(<MeshmakerVersion>)[^<]*(</MeshmakerVersion>)'

                if ($content -match $pattern) {
                    # Scriptblock replacement inserts $Version as a plain string, so neither a
                    # leading digit ($14) nor a literal $ in the version is parsed as a backreference.
                    $newContent = $content -replace $pattern, { $_.Groups[1].Value + $Version + $_.Groups[2].Value }
                    Set-Content -Path $buildPropsPath -Value $newContent -NoNewline
                    Write-Host "  ✓ Updated MeshmakerVersion to $Version" -ForegroundColor Green
                    $updatedCount++
                    $repoStatus = "updated"
                } else {
                    Write-Warning "  ⚠ MeshmakerVersion property not found in $buildPropsPath"
                    $repoStatus = "failed"
                }
            }
            catch {
                Write-Error "  ✗ Failed to update $buildPropsPath`: $($_.Exception.Message)"
                $repoStatus = "failed"
            }
        } else {
            Write-Warning "  ⚠ Directory.Build.props not found in $dir"
            $repoStatus = "failed"
        }

        $repoResults.Add([ordered]@{ repo = $dir; status = $repoStatus }) | Out-Null
    }

    if ($Json) {
        $failedCount = @($repoResults | Where-Object { $_.status -eq "failed" }).Count
        Write-OctoJson -Command 'Update-MeshmakerVersion' -Data ([ordered]@{
            version      = $Version
            repositories = @($repoResults)
            summary      = [ordered]@{
                total   = $octoDirectories.Count
                updated = $updatedCount
                failed  = $failedCount
            }
        })
        return
    }

    Write-Host "`nSummary: Updated $updatedCount of $($octoDirectories.Count) repositories" -ForegroundColor Green
}

Export-ModuleMember -Function Update-MeshmakerVersion
