
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

Export-ModuleMember -Function @('Remove-GlobalNuGetPackages')