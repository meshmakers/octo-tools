
<#
.SYNOPSIS
    Copies every Meshmakers.*.999.0.0.nupkg found in the bin/DebugL folders of a checkout into its nuget/ folder.

.DESCRIPTION
    Scans all octo-* (except frontends) and mm-* repositories of the checkout selected by -branch and
    copies their DebugL packages into <checkout>/nuget, the DebugL restore source.
    When several repositories contain the same package (e.g. a stale nupkg left in the bin folder
    of the repository a project moved away from), the newest file wins and a warning names the
    ignored ones. A package already in nuget/ that is newer than every candidate is kept.

.PARAMETER branch
    Checkout to work on (e.g. main). Resolved like Invoke-BuildAll: relative to `$rootPath`; a value
    equal to the leaf of `$rootPath` means `$rootPath` itself.

.EXAMPLE
    Copy-AllNuGetPackages -branch main
#>
function Copy-AllNuGetPackages
{
    param(
        [string]$branch = "",
        [switch]$Json
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # $nugetPath used to be read from an undefined profile variable, so the copy target was $null.
    $branchRoot = (Resolve-OctoBranchRootPath -branch $branch).BranchRootPath
    $nugetPath = Join-Path -Path $branchRoot -ChildPath "nuget"
    if (!(Test-Path $nugetPath)) {
        New-Item -ItemType Directory -Path $nugetPath | Out-Null
    }

    if (-not $Json) {
        Write-Host "Copying nuget packages to $nugetPath"
        Write-Host "Searching in $branchRoot..."
    }

    $filter = "Meshmakers.*.999.0.0.nupkg"
    # Get all directories starting with "octo-" and "mm-"
    $allDirectories = @(Get-ChildItem -Directory -Path $branchRoot -Filter "octo-*" | Where-Object { $_.Name -notlike "*frontend*" })
    $allDirectories += @(Get-ChildItem -Directory -Path $branchRoot -Filter "mm-*")

    # Collect first, copy second: the same package can lie in several repositories (e.g. an old
    # Sdk.Common.Web in octo-sdk/bin after the project moved to octo-communication-sdk). Copying in
    # directory order would let whichever repo sorts last win, so the newest file per package wins
    # instead, and duplicates are reported.
    $candidates = @()
    foreach ($directory in $allDirectories) {
        if (-not $Json) { Write-Host "Searching at $directory" }
        $binDirectories = Get-ChildItem -Path $directory -Filter 'DebugL' -Recurse -Directory | Where-Object { $_.FullName -like '*[/\]bin[/\]DebugL' }
        foreach ($binDirectory in $binDirectories) {
            $candidates += @(Get-ChildItem -Path $binDirectory -Recurse -File -Filter $filter |
                ForEach-Object { [pscustomobject]@{ File = $_; Repo = $directory.Name } })
        }
    }

    $copiedCount = 0
    $duplicates = @()
    $skippedOlder = @()
    foreach ($group in @($candidates | Group-Object -Property { $_.File.Name.ToLowerInvariant() })) {
        $sorted = @($group.Group | Sort-Object -Property { $_.File.LastWriteTime } -Descending)
        $winner = $sorted[0]
        if ($sorted.Count -gt 1) {
            $duplicates += [ordered]@{
                package = $winner.File.Name
                used    = $winner.File.FullName
                ignored = @($sorted | Select-Object -Skip 1 | ForEach-Object { $_.File.FullName })
            }
            if (-not $Json) {
                $ignored = ($sorted | Select-Object -Skip 1 | ForEach-Object { "$($_.Repo) ($($_.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" }) -join ', '
                Write-Warning "$($winner.File.Name) is produced by several repositories; using $($winner.Repo) ($($winner.File.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))), ignoring $ignored"
            }
        }

        # Never replace a newer package that is already in nuget/ with an older one.
        $destination = Join-Path -Path $nugetPath -ChildPath $winner.File.Name
        if ((Test-Path $destination) -and (Get-Item $destination).LastWriteTime -gt $winner.File.LastWriteTime) {
            $skippedOlder += $winner.File.FullName
            if (-not $Json) { Write-Host "Skip $($winner.File.FullName) (nuget/ has a newer copy)" -ForegroundColor DarkGray }
            continue
        }

        if (-not $Json) { Write-Host "Copy $($winner.File.FullName)" -ForegroundColor Green }
        Copy-Item -Path $winner.File.FullName -Destination $nugetPath -Force
        $copiedCount++
    }

    if ($Json) {
        Write-OctoJson -Command 'Copy-AllNuGetPackages' -Data ([ordered]@{ success = $true; copiedCount = $copiedCount; duplicates = @($duplicates); skippedOlder = @($skippedOlder) })
        return
    }
}

Export-ModuleMember -Function @('Copy-AllNuGetPackages')