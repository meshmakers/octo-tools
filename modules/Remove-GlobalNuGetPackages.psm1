
function Remove-GlobalNuGetPackages {
    param(
        # Package cache to clean. Defaults to the global ~/.nuget/packages; Invoke-BuildAll passes the
        # lane-local cache (<lane>/.nuget-packages, set via RestorePackagesPath in <lane>/Octo.User.props)
        # so that cleaning one lane never touches the other lane's 999.0.0 packages.
        [string]$path = $globalNugetPackagesPath,
        [switch]$Json
    )

    if (!(Test-Path $path)) {
        if ($Json) {
            Write-OctoJson -Command 'Remove-GlobalNuGetPackages' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ removedCount = 0; skipped = "path $path does not exist" })
        } else {
            Write-Host "Package cache $path does not exist yet - nothing to remove" -ForegroundColor Yellow
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