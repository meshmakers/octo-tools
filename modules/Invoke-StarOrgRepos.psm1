<#
.SYNOPSIS
    Stars every repository of a GitHub organization on behalf of the current gh CLI user.

.DESCRIPTION
    Fetches all repos of the given GitHub organization via the gh CLI, skips repos
    already starred by the authenticated user, then stars the remaining repos one by
    one in random order, waiting a random delay between each star so the stars land
    spread out over time instead of all at once.

    Requires the GitHub CLI (gh) to be installed and authenticated (`gh auth login`).

.PARAMETER Organization
    GitHub organization login whose repos should be starred.

.PARAMETER MinDelaySeconds
    Minimum random delay (in seconds) between two stars.

.PARAMETER MaxDelaySeconds
    Maximum random delay (in seconds) between two stars.

.PARAMETER DryRun
    Only print what would be starred, without calling the GitHub API.

.EXAMPLE
    Invoke-StarOrgRepos -Organization meshmakers

.EXAMPLE
    Invoke-StarOrgRepos -Organization meshmakers -MinDelaySeconds 30 -MaxDelaySeconds 90 -DryRun
#>
function Invoke-StarOrgRepos {
    param(
        [string]$Organization = "meshmakers",
        [int]$MinDelaySeconds = 15,
        [int]$MaxDelaySeconds = 60,
        [switch]$DryRun,
        [switch]$Json
    )

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Error "GitHub CLI (gh) not found. Install it from https://cli.github.com/ and run 'gh auth login' first."
        return
    }

    if (-not $Json) { Write-Host "Fetching repos of organization '$Organization'..." -ForegroundColor Cyan }
    $allRepos = @(gh repo list $Organization --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gh repo list failed with exit code $LASTEXITCODE"
        return
    }
    $allRepos = @($allRepos | Sort-Object -Unique)

    if (-not $allRepos) {
        Write-Error "No repos found for organization '$Organization'. Check the name and your gh auth."
        return
    }

    if (-not $Json) { Write-Host "Fetching repos already starred by the current user..." -ForegroundColor Cyan }
    $starredRepos = @(gh api /user/starred --paginate --jq '.[].full_name')
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gh api /user/starred failed with exit code $LASTEXITCODE"
        return
    }
    $starredRepos = @($starredRepos | Sort-Object -Unique)

    $toStar = @($allRepos | Where-Object { $starredRepos -notcontains $_ })
    $starred = @()
    $failed = @()

    if (-not $toStar) {
        if (-not $Json) { Write-Host "All $($allRepos.Count) repos of '$Organization' are already starred. Nothing to do." -ForegroundColor Green }
    }
    else {
        if (-not $Json) { Write-Host "$($toStar.Count) of $($allRepos.Count) repos still need a star." -ForegroundColor Yellow }

        $remaining = [System.Collections.Generic.List[string]]::new()
        $remaining.AddRange([string[]]$toStar)

        while ($remaining.Count -gt 0) {
            $delay = Get-Random -Minimum $MinDelaySeconds -Maximum ($MaxDelaySeconds + 1)
            if (-not $Json) { Write-Host "Waiting $delay s before the next star ($($remaining.Count) repos left)..." -ForegroundColor DarkGray }
            Start-Sleep -Seconds $delay

            $index = Get-Random -Minimum 0 -Maximum $remaining.Count
            $repo = $remaining[$index]
            $remaining.RemoveAt($index)

            if ($DryRun) {
                if (-not $Json) { Write-Host "[DryRun] Would star $repo" -ForegroundColor DarkYellow }
                $starred += $repo
                continue
            }

            gh api --method PUT "/user/starred/$repo" | Out-Null
            if ($LASTEXITCODE -eq 0) {
                if (-not $Json) { Write-Host "Starred $repo" -ForegroundColor Green }
                $starred += $repo
            }
            else {
                if (-not $Json) { Write-Warning "Failed to star $repo (gh exit code $LASTEXITCODE)" }
                $failed += $repo
            }
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Invoke-StarOrgRepos' -Data (New-OctoActionResult -Success ($failed.Count -eq 0) -ExitCode ($failed.Count -eq 0 ? 0 : 1) -Extra @{
                organization   = $Organization
                alreadyStarred = $starredRepos.Count
                starred        = $starred
                failed         = $failed
                dryRun         = [bool]$DryRun
            })
        return
    }

    Write-Host "Done." -ForegroundColor Cyan
}

Export-ModuleMember -Function @('Invoke-StarOrgRepos')
