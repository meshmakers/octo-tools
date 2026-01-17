function Get-BranchAvailability {
    <#
    .SYNOPSIS
    Lists all octo-* and mm-* repositories where a specific branch exists on remote

    .DESCRIPTION
    Scans for subdirectories starting with 'octo-' or 'mm-',
    checks if they are git repositories, and shows whether the specified branch
    exists on the remote (origin).

    .PARAMETER targetBranch
    The branch to search for (required)

    .PARAMETER Fetch
    Fetches from origin before checking (to get latest remote branch info)

    .EXAMPLE
    Get-BranchAvailability -targetBranch "feature/new-feature"

    .EXAMPLE
    Get-BranchAvailability -targetBranch "release/v2.0" -Fetch
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$targetBranch,

        [switch]$Fetch
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    Write-Host "Searching for branch '$targetBranch' on remote in octo-* and mm-* repositories..." -ForegroundColor Yellow
    Write-Host "Root path: $rootPath" -ForegroundColor DarkGray
    Write-Host ""

    $directories = Get-ChildItem -Directory -Path $rootPath | Where-Object { $_.Name -match '^(octo-|mm-)' } | Sort-Object Name

    if ($directories.Count -eq 0) {
        Write-Host "No octo-* or mm-* directories found" -ForegroundColor Red
        return
    }

    $found = @()
    $notFound = @()

    foreach ($dir in $directories) {
        Push-Location $dir.FullName
        try {
            # Check if it's a git repo
            if (!(Test-Path ".git")) {
                continue
            }

            # Optionally fetch latest
            if ($Fetch) {
                git fetch --all --quiet 2>$null | Out-Null
            }

            # Check remote branch
            $remoteBranch = git branch -r --list "origin/$targetBranch" 2>$null
            $hasRemote = $null -ne $remoteBranch -and $remoteBranch.Trim() -ne ""

            if ($hasRemote) {
                $found += $dir.Name
            }
            else {
                $notFound += $dir.Name
            }
        }
        catch {
            Write-Host "  $($dir.Name): Error - $($_.Exception.Message)" -ForegroundColor Red
        }
        finally {
            Pop-Location
        }
    }

    # Output results
    if ($found.Count -gt 0) {
        Write-Host "Branch exists on remote ($($found.Count)):" -ForegroundColor Green
        foreach ($repo in $found) {
            Write-Host "  ✓ $repo" -ForegroundColor Green
        }
        Write-Host ""
    }

    if ($notFound.Count -gt 0) {
        Write-Host "Branch NOT found ($($notFound.Count)):" -ForegroundColor DarkGray
        foreach ($repo in $notFound) {
            Write-Host "  ✗ $repo" -ForegroundColor DarkGray
        }
        Write-Host ""
    }

    # Summary
    Write-Host "Summary:" -ForegroundColor White
    Write-Host "  Total repositories: $($directories.Count)" -ForegroundColor White
    Write-Host "  Branch available:   $($found.Count)" -ForegroundColor Green
    Write-Host "  Branch missing:     $($notFound.Count)" -ForegroundColor DarkGray
}

Export-ModuleMember -Function Get-BranchAvailability
