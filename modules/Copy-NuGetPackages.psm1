
<#
.SYNOPSIS
    Copies the Meshmakers.*.999.0.0.nupkg files of one repository into <checkout>/nuget.

.DESCRIPTION
    Searches every bin/DebugL folder below -directory and copies the DebugL packages into the
    nuget/ folder of the checkout selected by -branch (the DebugL restore source).

.PARAMETER branch
    Lane checkout whose nuget/ folder receives the packages (e.g. main, dev). Resolved like
    Invoke-BuildAll (Resolve-OctoBranchRootPath): relative to `$rootPath`; a value equal to the leaf
    of `$rootPath` means `$rootPath` itself.

.PARAMETER directory
    Repository to search.

.PARAMETER modifiedSince
    Only copy packages written at or after this time. Default: copy everything.

.PARAMETER onlyChanged
    Copy a package only when nuget/ needs it (used by Invoke-BuildRange):
      - nuget/ has no copy of it, or
      - the package is at least as new as the nuget/ copy AND its content differs (SHA-512).
    Pack is incremental, so this also picks up a package written by an earlier, interrupted run
    or by an IDE build - not only the ones written by the current build. Never copied:
      - "orphaned" packages: lying in <project>/bin/DebugL of a folder that no longer contains a
        project file (e.g. octo-sdk/src/Sdk.Common.Web after the project moved to
        octo-communication-sdk);
      - packages older than the nuget/ copy (another repository produced a newer one).

.PARAMETER Json
    Emit { success, copiedCount, files, skipped } as a JSON document. `files` lists the copied file
    names, `skipped` the packages left alone with the reason (unchanged / olderThanNuget / orphaned).

.EXAMPLE
    Copy-NuGetPackages -directory (Join-Path $rootPath 'main/octo-sdk') -branch main
#>
function Copy-NuGetPackages
{
    param(
        [string]$branch = "",
        [string]$directory = ".\",
        [Nullable[DateTime]]$modifiedSince = $null,
        [switch]$onlyChanged,
        [switch]$Json
    )

    $filter = "Meshmakers.*.999.0.0.nupkg"
    $copiedCount = 0
    $copiedFiles = @()
    $skipped = @()

    if (-not $Json) { Write-Host "Searching at $directory" }
    $binDirectories = Get-ChildItem -Path $directory -Filter 'DebugL' -Recurse -Directory | Where-Object { $_.FullName -like '*[/\]bin[/\]DebugL' }

    $branchRootPath = (Resolve-OctoBranchRootPath -branch $branch).BranchRootPath
    $repositoryRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($directory))
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
                if ($onlyChanged) {
                    $reason = Get-OctoPackageCopySkipReason -file $file -binDirectory $binDirectory.FullName -repositoryRoot $repositoryRoot -nugetPath $branchNugetPath
                    if ($reason) {
                        $skipped += [ordered]@{ file = $file.Name; reason = $reason }
                        if (-not $Json) { Write-Host "Skip $file ($reason)" -ForegroundColor DarkGray }
                        continue
                    }
                }
                if (-not $Json) { Write-Host "Copy $file" -ForegroundColor Green }
                Copy-Item -Path $file -Destination $branchNugetPath -Force
                $copiedCount++
                $copiedFiles += $file.Name
            }
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Copy-NuGetPackages' -Data ([ordered]@{ success = $true; copiedCount = $copiedCount; files = @($copiedFiles); skipped = @($skipped) })
        return
    }
}

function Get-OctoFileSha512 {
    param([Parameter(Mandatory = $true)] [string]$path)
    $stream = [IO.File]::OpenRead($path)
    try { return [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($stream)) }
    finally { $stream.Dispose() }
}

function Get-OctoPackageCopySkipReason {
    # -onlyChanged rules; $null = copy it. See the help of Copy-NuGetPackages.
    param(
        [Parameter(Mandatory = $true)] [IO.FileInfo]$file,
        [Parameter(Mandatory = $true)] [string]$binDirectory,
        [Parameter(Mandatory = $true)] [string]$repositoryRoot,
        [Parameter(Mandatory = $true)] [string]$nugetPath
    )
    # <project>/bin/DebugL: the project folder must still hold a project file. Packages in the
    # repository-level bin/DebugL (central output path) cannot be mapped and count as owned.
    $projectDirectory = Split-Path -Parent (Split-Path -Parent $binDirectory)
    if ([IO.Path]::TrimEndingDirectorySeparator($projectDirectory) -ine $repositoryRoot -and
        @(Get-ChildItem -Path $projectDirectory -File -Filter '*.*proj' -ErrorAction SilentlyContinue).Count -eq 0) {
        return 'orphaned'
    }
    $destination = Join-Path -Path $nugetPath -ChildPath $file.Name
    if (-not (Test-Path -Path $destination -PathType Leaf)) {
        return $null
    }
    $existing = Get-Item -Path $destination
    if ($file.LastWriteTimeUtc -lt $existing.LastWriteTimeUtc) {
        return 'olderThanNuget'
    }
    if ((Get-OctoFileSha512 -path $file.FullName) -eq (Get-OctoFileSha512 -path $existing.FullName)) {
        return 'unchanged'
    }
    return $null
}

Export-ModuleMember -Function @('Copy-NuGetPackages')