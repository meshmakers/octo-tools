
function Remove-GlobalNuGetPackages {
    param(
        # Package cache to clean. Defaults to the global ~/.nuget/packages; Invoke-BuildAll passes the
        # lane-local cache (<lane>/.nuget-packages, set via RestorePackagesPath in <lane>/Octo.User.props)
        # so that cleaning one lane never touches the other lane's 999.0.0 packages.
        [string]$path = $globalNugetPackagesPath,
        [switch]$Json
    )

    # -PathType Container on purpose: a bare Test-Path also accepts a FILE. Measured on pwsh 7.6,
    # Get-ChildItem -Directory on a file does NOT throw - it quietly returns nothing - so the old
    # guard let a non-cache path through and this command then reported removedCount = 0 as if it
    # had inspected a cache. The container check makes the outcome honest instead of plausible
    # (review of the lane-local cache change).
    if (!(Test-Path $path -PathType Container)) {
        if ($Json) {
            Write-OctoJson -Command 'Remove-GlobalNuGetPackages' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ removedCount = 0; skipped = "path $path is not an existing directory" })
        } else {
            Write-Host "Package cache $path is not an existing directory - nothing to remove" -ForegroundColor Yellow
        }
        return;
    }

    if (-not $Json) {
        Write-Host "Searching in $path..."
    }

    $allDirectories = Get-ChildItem -Directory -Path $path -Filter "meshmakers.*"

    $removedCount = 0
    foreach ($directory in $allDirectories) {
        if (-not $Json) {
            Write-Host "Searching at $directory"
        }
        $packageDirectories = Join-Path $directory '999.0.0'

        if ((Test-Path $packageDirectories)) {

            if (-not $Json) {
                Write-Host "Deleting $packageDirectories" -ForegroundColor Blue
            }
            Remove-Item -Path $packageDirectories -Recurse -Force -ProgressAction SilentlyContinue
            $removedCount++
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Remove-GlobalNuGetPackages' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ removedCount = $removedCount })
        return
    }
}

function Remove-OctoLaneNuGetPackages {
    <#
    .SYNOPSIS
        Removes the local 999.0.0 Meshmakers packages from every package cache a lane restores into.
    .DESCRIPTION
        The caches come from Get-OctoRangePackageCaches (shared with Invoke-BuildRange):
          - isolated lane (dev): only <lane>/.nuget-packages, the global cache is never touched;
          - legacy lane (main): <lane>/.nuget-packages when Octo.User.props sets RestorePackagesPath, plus the
            global cache (NUGET_PACKAGES or ~/.nuget/packages).
        Each cache is cleaned with Remove-GlobalNuGetPackages, i.e. only meshmakers.*/999.0.0 folders.
        With -Json the nested emits are swallowed: the caller owes ONE machine-readable document.
    .PARAMETER laneSettings
        Result of Get-OctoLaneBuildSettings.
    .PARAMETER WhatIf
        Returns the caches that would be cleaned without deleting anything.
    #>
    param(
        [Parameter(Mandatory = $true)] $laneSettings,
        [switch]$Json,
        [switch]$WhatIf
    )

    $caches = @(Get-OctoRangePackageCaches -laneSettings $laneSettings)
    if (-not $WhatIf) {
        foreach ($cache in $caches) {
            if ($Json) { Remove-GlobalNuGetPackages -path $cache -Json | Out-Null } else { Remove-GlobalNuGetPackages -path $cache }
        }
    }
    return $caches
}

Export-ModuleMember -Function @('Remove-GlobalNuGetPackages', 'Remove-OctoLaneNuGetPackages')