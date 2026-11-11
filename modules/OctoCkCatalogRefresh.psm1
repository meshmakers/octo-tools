<#
.SYNOPSIS
    One read of the remote CK catalogs per build run (AB#8831).

.DESCRIPTION
    Every CkCompile of a local build refreshes the public and the private CK catalog from the GitHub Pages mirror:
    about 190 sequential requests, 1 to 2.5 minutes, once per CK project and again when it is packed. The engine
    reuses its cache (~/.octo/ck-catalog/cache/*-github-catalog-cache.json) only while it is younger than 60
    seconds, which a refresh that takes that long never is. Measured on octo-common-services: 118.6 s per build,
    4.3 s with OctoRefreshRemoteCatalogs=false.

    The build cmdlets therefore read the remote catalogs at most once per run (Initialize-OctoRunCatalogs, before
    the first repository that uses a construction kit):
      - the remote caches are younger than -maxAgeMinutes (default 30): nothing is read;
      - otherwise `octo-ckc -c RefreshAllCatalogCaches` (the lane's octo-ckc, a feature environment's base lane's,
        or the one on PATH) refreshes them once;
      - the lane's local-catalog cache file is deleted, so the first compile rebuilds it from the catalog folder
        (the engine does that for a missing cache; it also rewrites the cache after every publish, so models
        published by a repository of the run are seen by the next one);
    and then pass OctoRefreshRemoteCatalogs=false to every dotnet build of the run. With it CkCompile does not
    refresh; it resolves dependencies and the compatibility baseline from the caches as they were read at the
    start of the run, and from the local catalog.

    What is given up: a model version published to a remote catalog while the run is going is not seen before the
    next run (or -refreshCatalogs). What is not: the intermediate-version sync (Sync-OctoCkIntermediateVersions)
    reads the private catalog itself and publishes into the local catalog, so OCTO-CK203 is handled as before.

    When the catalogs cannot be read once (no octo-ckc, the refresh fails), nothing is switched off: every compile
    refreshes as before. -refreshCatalogs on the build cmdlets does the same on purpose. A caller's own
    OctoRefreshRemoteCatalogs in -msbuildProperties is never overridden.

    Not covered: CkRestore (construction-kits.yaml, e.g. octo-cli, the octo-sdk sample) refreshes unconditionally;
    the engine has no switch for it.
#>

$script:CatalogProperty = 'OctoRefreshRemoteCatalogs'
$script:CkFileNames = @('ckModel.yaml', 'construction-kits.yaml')
$script:SkippedFolders = [System.Collections.Generic.HashSet[string]]::new([string[]]@('bin', 'obj', 'node_modules', '.git', '.vs', '.idea', 'dist', '.angular', 'TestResults'), [StringComparer]::OrdinalIgnoreCase)

function Test-OctoRepoUsesCk {
    <#
    .SYNOPSIS
        True when a build of the repository compiles or restores construction kit models: a ckModel.yaml or a
        construction-kits.yaml anywhere in it (src/, tests/, samples/; never bin, obj, node_modules or .git).
    #>
    param([Parameter(Mandatory = $true)] [string]$path)
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $false }
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            foreach ($name in $script:CkFileNames) { if ([IO.File]::Exists((Join-Path $directory $name))) { return $true } }
            foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                if ($script:SkippedFolders.Contains([IO.Path]::GetFileName($child))) { continue }
                if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($child)
            }
        }
        catch [System.UnauthorizedAccessException] { continue }
        catch [System.IO.IOException] { continue }
    }
    return $false
}

function Get-OctoCkRemoteCacheFiles {
    # The engine's cache files of the remote catalogs (user level, shared by every lane). OCTO_CK_CACHE_DIRECTORY
    # points somewhere else (tests).
    $directory = if (-not [string]::IsNullOrWhiteSpace($env:OCTO_CK_CACHE_DIRECTORY)) { $env:OCTO_CK_CACHE_DIRECTORY }
    else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.octo/ck-catalog/cache' }
    return @('public-github-catalog-cache.json', 'private-github-catalog-cache.json') | ForEach-Object { Join-Path $directory $_ }
}

function Resolve-OctoCkc {
    <#
    .SYNOPSIS
        The octo-ckc to use for a lane: the lane's own build, the base lane's for a feature environment without the
        engine, else the one on PATH. $null when there is none.
    #>
    param([string]$laneRootPath = '')
    $exeName = if ($IsWindows) { 'octo-ckc.exe' } else { 'octo-ckc' }
    $relative = "octo-construction-kit-engine/bin/DebugL/net10.0/publish/$exeName"
    if (-not [string]::IsNullOrWhiteSpace($laneRootPath)) {
        $candidates = @((Join-Path $laneRootPath $relative))
        $manifestPath = Join-Path $laneRootPath '.octo/environment.json'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $base = [string]$manifest.base
                if ($base) {
                    $basePath = if ([IO.Path]::IsPathRooted($base)) { $base } else { Join-Path (Split-Path -Parent $laneRootPath) $base }
                    $candidates += (Join-Path $basePath $relative)
                }
            }
            catch { Write-Verbose "Cannot read ${manifestPath}: $_" }
        }
        foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
    }
    $command = Get-Command octo-ckc -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Invoke-OctoCkcRefresh {
    # Runs `octo-ckc -c RefreshAllCatalogCaches`; returns { ExitCode; Output }. Mocked in the tests.
    param([Parameter(Mandatory = $true)] [string]$ckc)
    $output = @(& $ckc -c RefreshAllCatalogCaches 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Initialize-OctoRunCatalogs {
    <#
    .SYNOPSIS
        Reads the remote CK catalogs once for a build run. Returns { usable; mode; seconds; detail }:
          usable  $true: the builds of the run may pass OctoRefreshRemoteCatalogs=false
          mode    fresh (caches younger than -maxAgeMinutes, nothing read) | refreshed (octo-ckc read them) |
                  unavailable (no octo-ckc) | failed (the refresh failed)
        Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$laneRootPath,
        [int]$maxAgeMinutes = 30,
        [string]$ckc = ''
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = { param([bool]$usable, [string]$mode, [string]$detail) [pscustomobject]@{ usable = $usable; mode = $mode; seconds = $watch.Elapsed.TotalSeconds; detail = $detail } }
    try {
        $files = @(Get-OctoCkRemoteCacheFiles)
        $now = [DateTime]::UtcNow
        $ages = @($files | ForEach-Object { if (Test-Path -LiteralPath $_ -PathType Leaf) { ($now - [IO.File]::GetLastWriteTimeUtc($_)).TotalMinutes } else { [double]::PositiveInfinity } })
        $oldest = ($ages | Measure-Object -Maximum).Maximum
        $mode = 'fresh'
        $detail = "remote catalog caches are $([int]$oldest) minute(s) old (limit $maxAgeMinutes)"
        if ($oldest -gt $maxAgeMinutes) {
            if ([string]::IsNullOrWhiteSpace($ckc)) { $ckc = Resolve-OctoCkc -laneRootPath $laneRootPath }
            if ([string]::IsNullOrWhiteSpace($ckc)) {
                return & $result $false 'unavailable' 'no octo-ckc found (lane build, base lane, PATH) - every CK compile refreshes the catalogs itself'
            }
            $run = Invoke-OctoCkcRefresh -ckc $ckc
            if ($run.ExitCode -ne 0) {
                return & $result $false 'failed' "octo-ckc -c RefreshAllCatalogCaches exited with $($run.ExitCode): $(@($run.Output | Select-Object -Last 2) -join ' ') - every CK compile refreshes the catalogs itself"
            }
            $mode = 'refreshed'
            $detail = "remote catalogs read once with $ckc"
        }
        # The local catalog's cache is rebuilt from the folder by the first compile (the engine does that for a
        # missing cache file) - files that reached the catalog by a copy (environment sync) are in it then.
        $localCache = Join-Path $laneRootPath '.octo/local-catalog/cache/local-catalog-cache.json'
        if (Test-Path -LiteralPath $localCache -PathType Leaf) { Remove-Item -LiteralPath $localCache -Force -ErrorAction SilentlyContinue }
        return & $result $true $mode $detail
    }
    catch {
        return & $result $false 'failed' "$($_.Exception.Message) - every CK compile refreshes the catalogs itself"
    }
}

function Add-OctoCatalogProperty {
    <#
    .SYNOPSIS
        The MSBuild properties of one build with OctoRefreshRemoteCatalogs=false added - unless the caller set the
        property itself. Returns a new hashtable.
    #>
    param([System.Collections.IDictionary]$properties = $null)
    $merged = @{}
    if ($properties) { foreach ($key in $properties.Keys) { $merged[[string]$key] = $properties[$key] } }
    if (-not (Test-OctoCatalogPropertySet -properties $merged)) { $merged[$script:CatalogProperty] = 'false' }
    return $merged
}

function Test-OctoCatalogPropertySet {
    # The caller passed OctoRefreshRemoteCatalogs itself (any value): the run does not decide.
    param([System.Collections.IDictionary]$properties = $null)
    if (-not $properties) { return $false }
    foreach ($key in $properties.Keys) { if ([string]$key -ieq $script:CatalogProperty) { return $true } }
    return $false
}

Export-ModuleMember -Function @('Test-OctoRepoUsesCk', 'Get-OctoCkRemoteCacheFiles', 'Resolve-OctoCkc', 'Invoke-OctoCkcRefresh', 'Initialize-OctoRunCatalogs', 'Add-OctoCatalogProperty', 'Test-OctoCatalogPropertySet')
