
<#
.SYNOPSIS
    Copies the Meshmakers.*.999.0.0.nupkg files of one repository into <checkout>/nuget.

.DESCRIPTION
    Searches every bin/DebugL folder below -directory and copies the DebugL packages into the
    nuget/ folder of the checkout selected by -branch (the DebugL restore source).

.PARAMETER branch
    Checkout whose nuget/ folder receives the packages (relative to `$rootPath`).

.PARAMETER directory
    Repository to search.

.PARAMETER modifiedSince
    Only copy packages written at or after this time (Invoke-BuildRange passes the start of the
    repository build so stale packages of projects that no longer exist are not copied over
    fresh ones produced by another repository). Default: copy everything.

.PARAMETER Json
    Emit { success, copiedCount, files } as a JSON document. `files` lists the copied file names.

.EXAMPLE
    Copy-NuGetPackages -directory ./octo-sdk -branch main
#>
function Copy-NuGetPackages
{
    param(
        [string]$branch = "",
        [string]$directory = ".\",
        [Nullable[DateTime]]$modifiedSince = $null,
        [switch]$Json
    )

    $filter = "Meshmakers.*.999.0.0.nupkg"
    $copiedCount = 0
    $copiedFiles = @()

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
            if ($null -ne $modifiedSince) {
                $nugetFiles = @($nugetFiles | Where-Object { $_.LastWriteTime -ge $modifiedSince })
            }

            foreach ($file in $nugetFiles) {
                if (-not $Json) { Write-Host "Copy $file" -ForegroundColor Green }
                Copy-Item -Path $file -Destination $branchNugetPath -Force
                $copiedCount++
                $copiedFiles += $file.Name
            }
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Copy-NuGetPackages' -Data ([ordered]@{ success = $true; copiedCount = $copiedCount; files = @($copiedFiles) })
        return
    }
}

Export-ModuleMember -Function @('Copy-NuGetPackages')