
function Remove-GlobalNuGetPackages {
    param(
        [switch]$Json
    )

    if (!(Test-Path $globalNugetPackagesPath)) {
        Write-Error "Path $globalNugetPackagesPath does not exist"
        return;
    }

    if (-not $Json) {
        Write-Host "Searching in $globalNugetPackagesPath..."
    }

    $allDirectories = Get-ChildItem -Directory -Path $globalNugetPackagesPath -Filter "meshmakers.*"

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