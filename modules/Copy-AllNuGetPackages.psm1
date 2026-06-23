
function Copy-AllNuGetPackages
{
    param(
        [switch]$Json
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    if (-not $Json) {
        Write-Host "Copying nuget packages to $nugetPath"
        Write-Host "Searching in $rootPath..."
    }

    $filter = "Meshmakers.*.999.0.0.nupkg"
    $copiedCount = 0
     # Get all directories starting with "octo-" and "mm-"
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*" | Where-Object { $_.Name -notlike "*frontend*" }
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    foreach ($directory in $allDirectories) {
        if (-not $Json) { Write-Host "Searching at $directory" }
        $binDirectories = Get-ChildItem -Path $directory -Filter 'DebugL' -Recurse -Directory | Where-Object { $_.FullName -like '*[/\]bin[/\]DebugL' }

        foreach ($binDirectory in $binDirectories) {

            if (-not $Json) { Write-Host "Working on $binDirectory" }
            if ((Test-Path $binDirectory)) {

                $nugetFiles = Get-ChildItem -Path $binDirectory -Recurse -Filter $filter

                foreach ($file in $nugetFiles) {
                    if (-not $Json) { Write-Host "Copy $file" -ForegroundColor Green }
                    Copy-Item -Path $file -Destination $nugetPath -Force
                    $copiedCount++
                }
            }
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Copy-AllNuGetPackages' -Data ([ordered]@{ success = $true; copiedCount = $copiedCount })
        return
    }
}

Export-ModuleMember -Function @('Copy-AllNuGetPackages')