
function Copy-NuGetPackages
{
    param(
        [string]$branch = "",
        [string]$directory = ".\",
        [switch]$Json
    )

    $filter = "Meshmakers.*.999.0.0.nupkg"
    $copiedCount = 0

    if (-not $Json) { Write-Host "Searching at $directory" }
    $binDirectories = Get-ChildItem -Path $directory -Filter 'DebugL' -Recurse -Directory | Where-Object { $_.FullName -like '*[/\]bin[/\]DebugL' }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $branchNugetPath = Join-Path -Path $branchRootPath -ChildPath "nuget"
    if (-not $Json) { Write-Host "Branch NuGet Path: $branchNugetPath" }

    # Check if the branch NuGet path exists, if not create it
    if (!(Test-Path $branchNugetPath)) {
        if (-not $Json) { Write-Host "Creating directory $branchNugetPath" -ForegroundColor Yellow }
        New-Item -ItemType Directory -Path $branchNugetPath | Out-Null
    }

    foreach ($binDirectory in $binDirectories) {

        if (-not $Json) { Write-Host "Working on $binDirectory" }
        if ((Test-Path $binDirectory)) {

            $nugetFiles = Get-ChildItem -Path $binDirectory -Recurse -Filter $filter

            foreach ($file in $nugetFiles) {
                if (-not $Json) { Write-Host "Copy $file" -ForegroundColor Green }
                Copy-Item -Path $file -Destination $branchNugetPath -Force
                $copiedCount++
            }
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Copy-NuGetPackages' -Data ([ordered]@{ success = $true; copiedCount = $copiedCount })
        return
    }
}

Export-ModuleMember -Function @('Copy-NuGetPackages')