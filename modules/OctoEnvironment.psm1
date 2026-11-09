<#
    Feature environments (AB#8700): small, isolated lane folders at <rootPath>/envs/<env>/.

    An environment holds git worktrees of the repositories a feature changes (role feature, on the feature branch)
    and of the repositories that must be rebuilt against them (role consumer, detached at the base checkout's
    commit), plus its own feed (nuget/), package cache (.nuget-packages/), CK and blueprint catalogs (.octo/), logs
    (logFiles/) and an Octo.User.props that declares RestorePackagesPath. The folders keep the plain repository names,
    so ../nuget, ../.octo/local-catalog, Find-OctoLaneRoot and Get-OctoBuildOrder resolve inside the environment and
    plain dotnet builds, Rider and Invoke-Build are isolated without extra properties.

    octo-tools owns everything on disk and every build; octo-devstack reads .octo/environment.json (schemaVersion 1,
    written only here) and runs the services. Main's packages and catalogs are copied as a snapshot (Sync-OctoEnvironment),
    never added as a second NuGet source.
#>

$script:ManifestSchemaVersion = 1
$script:DefaultBase = 'branches/main'
$script:CatalogFolders = @('local-catalog', 'local-blueprint-catalog')
$script:IgnoredSyncFiles = @('.catalog-index.lock', '.DS_Store')

# ---------------------------------------------------------------------------------------------------------------
# Paths, names, manifest
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoEnvironmentRootPath {
    # The workspace root ($rootPath of profile.ps1). Environments live in <root>/envs/<env>.
    $root = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace([string]$root)) {
        throw "`$rootPath is not set - load modules/profile.ps1 first."
    }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$root))
}

function Test-OctoEnvironmentName {
    param([string]$env)
    return ($env -cmatch '^[a-z0-9][a-z0-9-]{1,62}$')
}

function Get-OctoEnvironmentPath {
    # Absolute folder of an environment; throws for an invalid name.
    param([Parameter(Mandatory = $true)] [string]$env)
    if (-not (Test-OctoEnvironmentName -env $env)) {
        throw "Invalid environment name '$env': use a lower-case slug (a-z, 0-9, '-'), 2-63 characters, e.g. ab8625-enum-null."
    }
    return Join-Path (Join-Path (Get-OctoEnvironmentRootPath) 'envs') $env
}

function Get-OctoEnvironmentBasePath {
    param([Parameter(Mandatory = $true)] [string]$base)
    if ([IO.Path]::IsPathRooted($base)) { return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($base)) }
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Join-Path (Get-OctoEnvironmentRootPath) $base)))
}

function Test-OctoPathInside {
    # $true when $path is $parent or lies below it (separator-aware, case-insensitive).
    param([string]$path, [string]$parent)
    $p = ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($path)) -replace '\\', '/') + '/'
    $q = ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($parent)) -replace '\\', '/') + '/'
    return $p.StartsWith($q, [StringComparison]::OrdinalIgnoreCase)
}

function Get-OctoEnvironmentManifestPath {
    param([Parameter(Mandatory = $true)] [string]$environmentPath)
    return Join-Path $environmentPath '.octo/environment.json'
}

function Read-OctoEnvironmentManifest {
    # The manifest as an ordered hashtable, or $null when the environment does not exist.
    param([Parameter(Mandatory = $true)] [string]$env)
    $path = Get-OctoEnvironmentManifestPath -environmentPath (Get-OctoEnvironmentPath -env $env)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $manifest['repos'] = @($manifest['repos'] | Where-Object { $null -ne $_ })
    return $manifest
}

function Write-OctoEnvironmentManifest {
    param(
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary]$manifest
    )
    $path = Get-OctoEnvironmentManifestPath -environmentPath $environmentPath
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $ordered = [ordered]@{
        schemaVersion = $script:ManifestSchemaVersion
        name          = $manifest['name']
        workItem      = $manifest['workItem']
        base          = $manifest['base']
        created       = $manifest['created']
        owner         = $manifest['owner']
        repos         = @($manifest['repos'] | ForEach-Object {
                [ordered]@{ name = $_['name']; role = $_['role']; path = $_['path']; branch = $_['branch']; baseCommit = $_['baseCommit'] }
            })
        slot          = $manifest['slot']
    }
    $json = ConvertTo-Json -InputObject $ordered -Depth 6
    [IO.File]::WriteAllText($path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-OctoEnvironmentUserPropsContent {
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [Parameter(Mandatory = $true)] [string]$base,
        [Parameter(Mandatory = $true)] [string]$basePath
    )
    $baseProps = (Join-Path $basePath 'Octo.User.props') -replace '\\', '/'
    return @"
<Project>
    <!-- Feature environment $env (generated by New-OctoEnvironment, octo-tools). Do not edit by hand.
         The base lane's Octo.User.props is imported for its settings; the environment's package cache
         below overrides any RestorePackagesPath it declares. -->
    <PropertyGroup>
        <OctoEnvironment>$env</OctoEnvironment>
        <OctoEnvironmentBase>$base</OctoEnvironmentBase>
    </PropertyGroup>
    <Import Project="$baseProps" Condition="Exists('$baseProps')" />
    <PropertyGroup>
        <RestorePackagesPath>`$(MSBuildThisFileDirectory).nuget-packages</RestorePackagesPath>
    </PropertyGroup>
</Project>
"@
}

function ConvertTo-OctoWorkItem {
    param([string]$workItem)
    if ([string]::IsNullOrWhiteSpace($workItem)) { return $null }
    if ($workItem -match '^(?i:AB#)?(\d+)$') { return "AB#$($Matches[1])" }
    throw "Invalid work item '$workItem': use AB#<id> or <id>."
}

function Get-OctoEnvironmentDefaultBranchName {
    # <user>/AB#<id>_<desc> (agent-operating-rules), <user>/<desc> without a work item. <desc> is the
    # environment name without a leading ab<id>- prefix.
    param([string]$env, [string]$workItem)
    $user = ([Environment]::UserName).ToLowerInvariant() -replace '[^a-z0-9._-]', ''
    if ([string]::IsNullOrWhiteSpace($user)) { $user = 'dev' }
    $desc = $env -replace '^ab\d+-', ''
    if ([string]::IsNullOrWhiteSpace($desc)) { $desc = $env }
    if ($workItem) { return "$user/$($workItem)_$desc" }
    return "$user/$desc"
}

# ---------------------------------------------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------------------------------------------

function Invoke-OctoEnvironmentGit {
    # Runs git in a folder; returns { ExitCode; Output (string[]) }. Never throws on a non-zero exit.
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        [Parameter(Mandatory = $true)] [string[]]$arguments
    )
    $output = @(& git -C $path @arguments 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Resolve-OctoEnvironmentRepoName {
    # Exact folder name in the base lane, or the name with "octo-" prepended. Throws when neither exists.
    param([Parameter(Mandatory = $true)] [string]$repo, [Parameter(Mandatory = $true)] [string]$basePath)
    foreach ($candidate in @($repo, "octo-$repo")) {
        $folder = Join-Path $basePath $candidate
        if (Test-Path -LiteralPath (Join-Path $folder '.git')) { return $candidate }
    }
    throw "Repository '$repo' is not a git checkout in $basePath."
}

function Get-OctoEnvironmentRepoState {
    # Dirty / unpushed state of an environment worktree (Remove-OctoEnvironment refuses either).
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$repo)
    $path = [string]$repo['path']
    $state = [ordered]@{ name = $repo['name']; role = $repo['role']; path = $path; exists = $false; dirty = $false; unpushed = 0; problem = $null }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return [pscustomobject]$state }
    $state.exists = $true
    $status = Invoke-OctoEnvironmentGit -path $path -arguments @('status', '--porcelain')
    if ($status.ExitCode -ne 0) {
        $state.problem = "git status failed: $($status.Output -join ' ')"
        return [pscustomobject]$state
    }
    $state.dirty = @($status.Output | Where-Object { $_ }).Count -gt 0
    # Work done in the environment that no remote has: commits on top of the base commit that are on no remote
    # branch (the base commit itself may be an unpushed commit of the base checkout - not this environment's work).
    $exclude = @('--not', '--remotes')
    if ($repo['baseCommit']) { $exclude += [string]$repo['baseCommit'] }
    $unpushed = Invoke-OctoEnvironmentGit -path $path -arguments (@('rev-list', '--count', 'HEAD') + $exclude)
    if ($unpushed.ExitCode -ne 0) {
        $state.problem = "git rev-list failed: $($unpushed.Output -join ' ')"
        return [pscustomobject]$state
    }
    $state.unpushed = [int]($unpushed.Output | Select-Object -Last 1)
    return [pscustomobject]$state
}

function Add-OctoEnvironmentWorktree {
    # Creates one worktree; returns the manifest entry. Throws on failure.
    param(
        [Parameter(Mandatory = $true)] [string]$basePath,
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [string]$repo,
        [Parameter(Mandatory = $true)] [ValidateSet('feature', 'consumer')] [string]$role,
        [string]$branchName = ''
    )
    $source = Join-Path $basePath $repo
    $target = Join-Path $environmentPath $repo
    if (Test-Path -LiteralPath $target) { throw "$target already exists." }
    $head = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', 'HEAD')
    if ($head.ExitCode -ne 0) { throw "git rev-parse HEAD failed in ${source}: $($head.Output -join ' ')" }
    $baseCommit = [string]($head.Output | Select-Object -Last 1)

    if ($role -eq 'consumer') {
        $add = Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'add', '--detach', $target, $baseCommit)
        $branch = $null
    }
    else {
        $local = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', '--verify', '--quiet', "refs/heads/$branchName")
        $remote = Invoke-OctoEnvironmentGit -path $source -arguments @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$branchName")
        if ($local.ExitCode -eq 0 -or $remote.ExitCode -eq 0) {
            # Existing branch (resumed work): check it out; git creates the tracking branch from origin when needed.
            $add = Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'add', $target, $branchName)
        }
        else {
            $add = Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'add', '-b', $branchName, $target, $baseCommit)
        }
        $branch = $branchName
    }
    if ($add.ExitCode -ne 0) { throw "git worktree add failed for ${repo}: $($add.Output -join ' ')" }
    return [ordered]@{ name = $repo; role = $role; path = [IO.Path]::GetFullPath($target); branch = $branch; baseCommit = $baseCommit }
}

# ---------------------------------------------------------------------------------------------------------------
# Snapshot sync (port of octo-devstack Builds/PrivateFeed.cs, extended to the catalogs)
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoFileHash256 {
    param([Parameter(Mandatory = $true)] [string]$path)
    $stream = [IO.File]::OpenRead($path)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
    finally { $stream.Dispose() }
}

function Read-OctoSyncManifest {
    param([string]$path)
    $files = @{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $doc = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            if ($doc -and $doc['files']) { foreach ($key in $doc['files'].Keys) { $files[$key] = $doc['files'][$key] } }
        }
        catch { Write-Warning "Unreadable sync manifest $path - every differing file counts as environment-built: $_" }
    }
    return $files
}

function Write-OctoSyncManifest {
    param([string]$path, [hashtable]$files)
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    $sorted = [ordered]@{}
    foreach ($key in ($files.Keys | Sort-Object)) { $sorted[$key] = $files[$key] }
    $json = ConvertTo-Json -InputObject ([ordered]@{ schemaVersion = 1; files = $sorted }) -Depth 5
    [IO.File]::WriteAllText($path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Compare-OctoSemVer {
    # -1 / 0 / 1; non-SemVer strings compare ordinally.
    param([string]$a, [string]$b)
    $va = $null; $vb = $null
    $ca = ($a -split '[-+]')[0]; $cb = ($b -split '[-+]')[0]
    if ([version]::TryParse($ca, [ref]$va) -and [version]::TryParse($cb, [ref]$vb)) {
        $c = $va.CompareTo($vb)
        if ($c -ne 0) { return [Math]::Sign($c) }
    }
    return [Math]::Sign([string]::CompareOrdinal($a, $b))
}

function Merge-OctoCatalogIndex {
    <#
        Merges a catalog index (catalog.json) of the environment with the base lane's: the union of the entries, the
        environment's entry wins on a key collision.
          - "models": [{ modelName, (majorVersion), catalogPath }]  -> key modelName (+ majorVersion)
          - "versions": [{ version, ... }]                           -> key version, sorted descending; latestVersion
        Any other content keeps the environment's value. Returns the merged JSON text.
    #>
    param([Parameter(Mandatory = $true)] [string]$environmentJson, [Parameter(Mandatory = $true)] [string]$baseJson)
    $environment = $environmentJson | ConvertFrom-Json -AsHashtable
    $base = $baseJson | ConvertFrom-Json -AsHashtable
    $keyOf = {
        param($entry, [string]$kind)
        if ($kind -eq 'models') { return "$($entry['modelName'])|$($entry['majorVersion'])" }
        return [string]$entry['version']
    }
    foreach ($kind in @('models', 'versions')) {
        if (-not ($environment.Contains($kind) -and $base.Contains($kind))) { continue }
        $merged = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        foreach ($entry in @($environment[$kind])) { $seen[(& $keyOf $entry $kind)] = $true; $merged.Add($entry) }
        foreach ($entry in @($base[$kind])) { if (-not $seen.ContainsKey((& $keyOf $entry $kind))) { $merged.Add($entry) } }
        if ($kind -eq 'models') {
            $environment[$kind] = @($merged | Sort-Object -Property { [string]$_['modelName'] }, { [string]$_['majorVersion'] })
        }
        else {
            $list = [System.Collections.Generic.List[object]]::new($merged)
            $list.Sort([Comparison[object]] { param($x, $y) Compare-OctoSemVer ([string]$y['version']) ([string]$x['version']) })
            $environment[$kind] = @($list)
            if ($environment.Contains('latestVersion') -and $list.Count -gt 0) { $environment['latestVersion'] = [string]$list[0]['version'] }
        }
    }
    if ($environment.Contains('updatedAt')) { $environment['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o') }
    return (ConvertTo-Json -InputObject $environment -Depth 20)
}

function Sync-OctoEnvironmentFolder {
    <#
        Mirrors $source into $target with the PrivateFeed rules. The manifest records per relative path the hash of
        the file the sync wrote (target, $null when the environment owns it) and of the base file it last saw (source).
          - missing in the environment                     -> copied
          - unchanged since the sync wrote it, base changed -> refreshed
          - changed or built in the environment             -> kept (the environment's file wins), except:
              * a catalog index (catalog.json) whose base copy changed -> JSON-merged (Merge-OctoCatalogIndex)
              * a catalog cache file (cache/*-cache.json) whose base copy changed -> dropped (the tools rebuild it)
        $kind 'nuget' looks at *.nupkg in the top folder only; 'catalog' at every file below the folder.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$source,
        [Parameter(Mandatory = $true)] [string]$target,
        [Parameter(Mandatory = $true)] [string]$manifestPath,
        [Parameter(Mandatory = $true)] [ValidateSet('nuget', 'catalog')] [string]$kind,
        [switch]$dryRun
    )
    $result = [ordered]@{ source = $source; target = $target; copied = @(); refreshed = @(); kept = @(); merged = @(); dropped = @() }
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { return $result }
    $files = Read-OctoSyncManifest -path $manifestPath
    if (-not $dryRun -and -not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Force -Path $target | Out-Null }

    $sourceFiles = if ($kind -eq 'nuget') {
        @(Get-ChildItem -LiteralPath $source -File -Filter '*.nupkg')
    }
    else {
        @(Get-ChildItem -LiteralPath $source -File -Recurse | Where-Object { $_.Name -notin $script:IgnoredSyncFiles })
    }
    $sourceRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($source))
    foreach ($file in $sourceFiles) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName) -replace '\\', '/'
        $destination = Join-Path $target $relative
        $sourceHash = Get-OctoFileHash256 -path $file.FullName
        $entry = $files[$relative]
        $isCache = $kind -eq 'catalog' -and $relative -match '(^|/)cache/[^/]*-cache\.json$'
        $isIndex = $kind -eq 'catalog' -and $file.Name -eq 'catalog.json'

        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            if ($null -ne $entry -and $entry['dropped']) {
                # A cache file the sync dropped earlier: the tools own it now.
                $files[$relative] = @{ target = $null; source = $sourceHash; dropped = $true }
                continue
            }
            if (-not $dryRun) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination
            }
            $files[$relative] = @{ target = $sourceHash; source = $sourceHash }
            $result.copied += $relative
            continue
        }

        $targetHash = Get-OctoFileHash256 -path $destination
        $baseChanged = ($null -eq $entry) -or ([string]$entry['source'] -ne $sourceHash)
        if ($null -ne $entry -and [string]$entry['target'] -eq $targetHash) {
            if ($targetHash -ne $sourceHash) {
                if (-not $dryRun) { Copy-Item -LiteralPath $file.FullName -Destination $destination -Force }
                $files[$relative] = @{ target = $sourceHash; source = $sourceHash }
                $result.refreshed += $relative
            }
            else { $files[$relative] = @{ target = $targetHash; source = $sourceHash } }
            continue
        }
        if ($targetHash -eq $sourceHash) {
            # Same content as the base (e.g. built from the same commit): mirrored from now on.
            $files[$relative] = @{ target = $targetHash; source = $sourceHash }
            continue
        }
        if ($isIndex -and $baseChanged) {
            try {
                $mergedJson = Merge-OctoCatalogIndex -environmentJson (Get-Content -LiteralPath $destination -Raw) -baseJson (Get-Content -LiteralPath $file.FullName -Raw)
                if (-not $dryRun) { [IO.File]::WriteAllText($destination, $mergedJson + "`n", [Text.UTF8Encoding]::new($false)) }
                $files[$relative] = @{ target = $null; source = $sourceHash }
                $result.merged += $relative
            }
            catch {
                Write-Warning "Cannot merge catalog index $relative - the environment's copy is kept: $_"
                $files[$relative] = @{ target = $null; source = $sourceHash }
                $result.kept += $relative
            }
            continue
        }
        if ($isCache -and $baseChanged) {
            if (-not $dryRun) { Remove-Item -LiteralPath $destination -Force }
            $files[$relative] = @{ target = $null; source = $sourceHash; dropped = $true }
            $result.dropped += $relative
            continue
        }
        # Built or changed in the environment: it wins over the base's file.
        $files[$relative] = @{ target = $null; source = $sourceHash }
        $result.kept += $relative
    }
    if (-not $dryRun) { Write-OctoSyncManifest -path $manifestPath -files $files }
    return $result
}

function Clear-OctoEnvironmentStalePackageCache {
    # Port of PrivateFeed.PurgeStaleCache: deletes <cache>/<id>/<version> whose nupkg differs from the feed's copy
    # (NuGet never re-extracts a version it already has, and every local build is 999.0.0).
    param([Parameter(Mandatory = $true)] [string]$feed, [Parameter(Mandatory = $true)] [string]$cache, [switch]$dryRun)
    $purged = @()
    if (-not (Test-Path -LiteralPath $feed) -or -not (Test-Path -LiteralPath $cache)) { return $purged }
    foreach ($file in @(Get-ChildItem -LiteralPath $feed -File -Filter '*.nupkg')) {
        if ($file.Name -notmatch '^(?<id>.+?)\.(?<version>\d+\.\d+\.\d+(?:[-+][^/]*)?)\.nupkg$') { continue }
        $id = $Matches['id'].ToLowerInvariant()
        $version = $Matches['version'].ToLowerInvariant()
        $folder = Join-Path (Join-Path $cache $id) $version
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }
        $cached = Join-Path $folder "$id.$version.nupkg"
        if (-not (Test-Path -LiteralPath $cached -PathType Leaf) -or (Get-OctoFileHash256 -path $cached) -ne (Get-OctoFileHash256 -path $file.FullName)) {
            if (-not $dryRun) { Remove-Item -LiteralPath $folder -Recurse -Force }
            $purged += "$id/$version"
        }
    }
    return $purged
}

function Invoke-OctoEnvironmentSync {
    # Feed + catalogs + cache purge of one environment; returns the result object (Sync-OctoEnvironment's data).
    param(
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [string]$basePath,
        [switch]$dryRun
    )
    $syncState = Join-Path $environmentPath '.octo/sync'
    $nuget = Sync-OctoEnvironmentFolder -source (Join-Path $basePath 'nuget') -target (Join-Path $environmentPath 'nuget') -manifestPath (Join-Path $syncState 'nuget.json') -kind nuget -dryRun:$dryRun
    $catalogs = [ordered]@{}
    foreach ($folder in $script:CatalogFolders) {
        $catalogs[$folder] = Sync-OctoEnvironmentFolder -source (Join-Path $basePath ".octo/$folder") -target (Join-Path $environmentPath ".octo/$folder") -manifestPath (Join-Path $syncState "$folder.json") -kind catalog -dryRun:$dryRun
    }
    $purged = @(Clear-OctoEnvironmentStalePackageCache -feed (Join-Path $environmentPath 'nuget') -cache (Join-Path $environmentPath '.nuget-packages') -dryRun:$dryRun)
    return [ordered]@{
        dryRun          = [bool]$dryRun
        base            = $basePath
        nuget           = $nuget
        catalogs        = $catalogs
        purgedFromCache = $purged
    }
}

function Write-OctoEnvironmentSyncSummary {
    param($sync)
    $n = $sync.nuget
    Write-Host ("  feed: {0} copied, {1} refreshed, {2} built in the environment (kept)" -f @($n.copied).Count, @($n.refreshed).Count, @($n.kept).Count)
    foreach ($name in $sync.catalogs.Keys) {
        $c = $sync.catalogs[$name]
        Write-Host ("  {0}: {1} copied, {2} refreshed, {3} kept, {4} index merged, {5} cache dropped" -f $name, @($c.copied).Count, @($c.refreshed).Count, @($c.kept).Count, @($c.merged).Count, @($c.dropped).Count)
    }
    Write-Host ("  package cache: {0} stale folder(s) purged" -f @($sync.purgedFromCache).Count)
}

# ---------------------------------------------------------------------------------------------------------------
# Package graph
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoRepoPackageInfo {
    # Produced package ids and Meshmakers.* references of one repository, from its csproj (and props) files.
    param([Parameter(Mandatory = $true)] [string]$path)
    $produces = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $references = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Include '*.csproj', '*.props' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[/\\](bin|obj|node_modules|\.git)[/\\]' })
    foreach ($file in $files) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ([string]::IsNullOrEmpty($text)) { continue }
        foreach ($match in [regex]::Matches($text, '<PackageReference\s+[^>]*?Include\s*=\s*"(Meshmakers\.[^"]+)"', 'IgnoreCase')) {
            [void]$references.Add($match.Groups[1].Value)
        }
        if ($file.Extension -ne '.csproj') { continue }
        if ($text -match '<IsPackable>\s*false\s*</IsPackable>') { continue }
        $id = if ($text -match '<PackageId>\s*([^<$]+?)\s*</PackageId>') { $Matches[1] } else { [IO.Path]::GetFileNameWithoutExtension($file.Name) }
        [void]$produces.Add($id)
    }
    foreach ($id in $produces) { [void]$references.Remove($id) }   # a repository does not consume itself
    return [pscustomobject]@{ Produces = @($produces | Sort-Object); References = @($references | Sort-Object) }
}

function Get-OctoAffectedRepoGraph {
    <#
        Pure graph computation. $repos: ordered list of { Name; Path } in build order. $features: names of the changed
        repositories. Returns one row per affected repository (transitive consumer of a feature repository), in build
        order: { repo; depth; via = @("<package> (<producer>)") }.
    #>
    param([object[]]$repos = @(), [string[]]$features = @())
    $info = [ordered]@{}
    $producerOf = @{}
    foreach ($repo in $repos) {
        $info[$repo.Name] = Get-OctoRepoPackageInfo -path $repo.Path
        foreach ($id in $info[$repo.Name].Produces) { if (-not $producerOf.ContainsKey($id.ToLowerInvariant())) { $producerOf[$id.ToLowerInvariant()] = $repo.Name } }
    }
    # consumers[producer] = list of { consumer; package }
    $consumers = @{}
    foreach ($name in $info.Keys) {
        foreach ($id in $info[$name].References) {
            $producer = $producerOf[$id.ToLowerInvariant()]
            if (-not $producer -or $producer -eq $name) { continue }
            if (-not $consumers.ContainsKey($producer)) { $consumers[$producer] = [System.Collections.Generic.List[object]]::new() }
            $consumers[$producer].Add([pscustomobject]@{ Consumer = $name; Package = $id })
        }
    }
    $depth = @{}
    $via = @{}
    $queue = [System.Collections.Generic.Queue[string]]::new()
    foreach ($feature in $features) { $depth[$feature] = 0; $queue.Enqueue($feature) }
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $consumers.ContainsKey($current)) { continue }
        foreach ($edge in $consumers[$current]) {
            if ($features -contains $edge.Consumer) { continue }
            if (-not $via.ContainsKey($edge.Consumer)) { $via[$edge.Consumer] = [System.Collections.Generic.List[string]]::new() }
            $label = "$($edge.Package) ($current)"
            if (-not $via[$edge.Consumer].Contains($label)) { $via[$edge.Consumer].Add($label) }
            if (-not $depth.ContainsKey($edge.Consumer)) {
                $depth[$edge.Consumer] = $depth[$current] + 1
                $queue.Enqueue($edge.Consumer)
            }
        }
    }
    $rows = @()
    foreach ($repo in $repos) {
        if ($features -contains $repo.Name -or -not $depth.ContainsKey($repo.Name)) { continue }
        $rows += [pscustomobject][ordered]@{ repo = $repo.Name; depth = $depth[$repo.Name]; via = @($via[$repo.Name]) }
    }
    return [pscustomobject]@{ Affected = $rows; Consumers = $consumers }
}

function Get-OctoReposOnPath {
    # The affected repositories from which $target can be reached (they lie between a feature repository and the
    # target), plus the target itself when it is affected.
    param([Parameter(Mandatory = $true)] $graph, [Parameter(Mandatory = $true)] [string]$target)
    $affected = @($graph.Affected | ForEach-Object repo)
    $onPath = @()
    foreach ($name in $affected) {
        if ($name -eq $target) { $onPath += $name; continue }
        # BFS from $name along consumer edges; does it reach $target?
        $seen = @{ $name = $true }
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue($name)
        $reached = $false
        while ($queue.Count -gt 0 -and -not $reached) {
            $current = $queue.Dequeue()
            if (-not $graph.Consumers.ContainsKey($current)) { continue }
            foreach ($edge in $graph.Consumers[$current]) {
                if ($edge.Consumer -eq $target) { $reached = $true; break }
                if (-not $seen.ContainsKey($edge.Consumer)) { $seen[$edge.Consumer] = $true; $queue.Enqueue($edge.Consumer) }
            }
        }
        if ($reached) { $onPath += $name }
    }
    return $onPath
}

function Get-OctoEnvironmentRepoSet {
    # Build-order list { Name; Path } of the base lane, with the environment's worktrees replacing the base folders.
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$manifest, [Parameter(Mandatory = $true)] [string]$basePath)
    $environmentRepos = @{}
    foreach ($repo in $manifest['repos']) { $environmentRepos[$repo['name']] = $repo['path'] }
    $set = @()
    foreach ($entry in @(Get-OctoBuildOrder -branchRootPath $basePath -excludeFrontend $false -excludeAdditional $false)) {
        $path = if ($environmentRepos.ContainsKey($entry.Name) -and (Test-Path -LiteralPath $environmentRepos[$entry.Name])) { $environmentRepos[$entry.Name] } else { $entry.Path }
        $set += [pscustomobject]@{ Name = $entry.Name; Path = $path }
    }
    return $set
}

function Get-OctoEnvironmentAffected {
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$manifest, [Parameter(Mandatory = $true)] [string]$basePath)
    $features = @($manifest['repos'] | Where-Object { $_['role'] -eq 'feature' } | ForEach-Object { $_['name'] })
    $graph = Get-OctoAffectedRepoGraph -repos (Get-OctoEnvironmentRepoSet -manifest $manifest -basePath $basePath) -features $features
    return [pscustomobject]@{ Features = $features; Graph = $graph }
}

# ---------------------------------------------------------------------------------------------------------------
# Cmdlets
# ---------------------------------------------------------------------------------------------------------------

<#
.SYNOPSIS
    Creates a feature environment at <rootPath>/envs/<env>: feature worktrees, Octo.User.props, manifest, and a
    snapshot of the base lane's feed and catalogs.

.DESCRIPTION
    For every repository in -repos a git worktree <env>/<repo> is added from <base>/<repo> on the feature branch
    (-branchName, default <user>/AB#<id>_<desc>; an existing local or origin branch is checked out instead of
    created). The environment gets nuget/, .nuget-packages/, .octo/local-catalog, .octo/local-blueprint-catalog
    (copied from the base lane by Sync-OctoEnvironment rules), logFiles/, an Octo.User.props declaring
    RestorePackagesPath=<env>/.nuget-packages plus OctoEnvironment/OctoEnvironmentBase (the base lane's own
    Octo.User.props is imported for its other settings), and .octo/environment.json (schemaVersion 1).

    Refuses an existing environment, an invalid name, a base lane that does not exist and an environment folder
    inside the base lane (the kill scope and cache logic of the base would match it). -addAffected adds every
    transitive consumer of the feature repositories as a consumer worktree (Get-OctoAffectedRepos); for a single
    service use Add-OctoEnvironmentRepo -role consumer -addAffected instead.

.EXAMPLE
    New-OctoEnvironment -env ab8625-enum-null -repos octo-construction-kit-engine -workItem AB#8625
#>
function New-OctoEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [Parameter(Mandatory = $true)] [string[]]$repos,
        [string]$workItem = '',
        [string]$branchName = '',
        [string]$owner = '',
        [string]$base = $script:DefaultBase,
        [switch]$addAffected,
        [switch]$Json
    )

    $fail = {
        param([string]$message)
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'New-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $message }) }
        else { Write-Error $message }
    }

    try {
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $normalizedWorkItem = ConvertTo-OctoWorkItem -workItem $workItem
        $basePath = Get-OctoEnvironmentBasePath -base $base
    }
    catch { & $fail $_.Exception.Message; return }
    if (-not (Test-Path -LiteralPath $basePath -PathType Container)) { & $fail "Base lane $basePath does not exist."; return }
    if (Test-OctoPathInside -path $environmentPath -parent $basePath) {
        & $fail "Environment folder $environmentPath lies inside the base lane $basePath (`$rootPath points into the lane - load the profile from the octo-tools next to the lanes). Refused: the base lane's kill scope and package caches would include it."
        return
    }
    if (Test-Path -LiteralPath $environmentPath) { & $fail "Environment $env already exists ($environmentPath). Use Add-OctoEnvironmentRepo, or Remove-OctoEnvironment first."; return }
    try { $repoNames = @($repos | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { Resolve-OctoEnvironmentRepoName -repo $_.Trim() -basePath $basePath } | Select-Object -Unique) }
    catch { & $fail $_.Exception.Message; return }
    if ($repoNames.Count -eq 0) { & $fail "-repos names no repository."; return }
    if ([string]::IsNullOrWhiteSpace($branchName)) { $branchName = Get-OctoEnvironmentDefaultBranchName -env $env -workItem $normalizedWorkItem }
    $relativeBase = if ([IO.Path]::IsPathRooted($base)) { [IO.Path]::GetRelativePath((Get-OctoEnvironmentRootPath), $basePath) -replace '\\', '/' } else { $base -replace '\\', '/' }

    $manifest = [ordered]@{
        name     = $env
        workItem = $normalizedWorkItem
        base     = $relativeBase
        created  = (Get-Date).ToUniversalTime().ToString('o')
        owner    = if ($owner) { $owner } else { $branchName }
        repos    = @()
        slot     = $env
    }

    if (-not $PSCmdlet.ShouldProcess($environmentPath, "Create environment with feature worktree(s) $($repoNames -join ', ') on $branchName")) {
        $plan = [ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; path = $environmentPath; base = $basePath; branch = $branchName; repos = $repoNames }
        if ($Json) { Write-OctoJson -Command 'New-OctoEnvironment' -Data $plan }
        return
    }

    foreach ($folder in @('nuget', '.nuget-packages', '.octo', 'logFiles')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $environmentPath $folder) | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $environmentPath 'Octo.User.props') -Value (Get-OctoEnvironmentUserPropsContent -env $env -base $relativeBase -basePath $basePath)
    Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest

    $errors = @()
    foreach ($repo in $repoNames) {
        try {
            $manifest['repos'] = @($manifest['repos']) + @(Add-OctoEnvironmentWorktree -basePath $basePath -environmentPath $environmentPath -repo $repo -role feature -branchName $branchName)
            Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest
        }
        catch { $errors += $_.Exception.Message }
    }
    $sync = Invoke-OctoEnvironmentSync -environmentPath $environmentPath -basePath $basePath

    $addedConsumers = @()
    if ($addAffected -and $errors.Count -eq 0) {
        $affected = Get-OctoEnvironmentAffected -manifest $manifest -basePath $basePath
        foreach ($row in $affected.Graph.Affected) {
            try {
                $manifest['repos'] = @($manifest['repos']) + @(Add-OctoEnvironmentWorktree -basePath $basePath -environmentPath $environmentPath -repo $row.repo -role consumer)
                Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest
                $addedConsumers += $row.repo
            }
            catch { $errors += $_.Exception.Message }
        }
    }

    $success = $errors.Count -eq 0
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    if ($Json) {
        Write-OctoJson -Command 'New-OctoEnvironment' -Data (New-OctoActionResult -Success $success -ExitCode $global:LASTEXITCODE -Extra @{
                environment = $env; path = $environmentPath; branch = $branchName; manifest = $manifest
                consumersAdded = $addedConsumers; sync = $sync; errors = $errors
            })
        return
    }
    Write-Host "Environment $env at $environmentPath (base $basePath)" -ForegroundColor Green
    foreach ($repo in $manifest['repos']) { Write-Host ("  {0,-9} {1}  {2}" -f $repo['role'], $repo['name'], $(if ($repo['branch']) { $repo['branch'] } else { "detached at $($repo['baseCommit'].Substring(0, [Math]::Min(10, $repo['baseCommit'].Length)))" })) }
    Write-OctoEnvironmentSyncSummary -sync $sync
    foreach ($message in $errors) { Write-Warning $message }
    if ($success) { Write-Host "Next: Invoke-BuildEnvironment -env $env -verifyTests" -ForegroundColor Cyan }
}

<#
.SYNOPSIS
    Lists the feature environments, or shows one with the git state of its worktrees.
.EXAMPLE
    Get-OctoEnvironment -Json
.EXAMPLE
    Get-OctoEnvironment -env ab8625-enum-null
#>
function Get-OctoEnvironment {
    param(
        [string]$env = '',
        [switch]$Json
    )

    $environmentsRoot = Join-Path (Get-OctoEnvironmentRootPath) 'envs'
    $names = if ($env) { @($env) } elseif (Test-Path -LiteralPath $environmentsRoot) { @(Get-ChildItem -LiteralPath $environmentsRoot -Directory | ForEach-Object Name | Sort-Object) } else { @() }
    $rows = @()
    $missing = $null
    foreach ($name in $names) {
        try { $manifest = Read-OctoEnvironmentManifest -env $name }
        catch { $manifest = $null; if ($env) { $missing = $_.Exception.Message } }
        if ($null -eq $manifest) {
            if ($env -and -not $missing) { $missing = "Environment $name does not exist." }
            continue
        }
        $row = [ordered]@{
            name     = $manifest['name']
            path     = Get-OctoEnvironmentPath -env $name
            workItem = $manifest['workItem']
            base     = $manifest['base']
            owner    = $manifest['owner']
            created  = $manifest['created']
            slot     = $manifest['slot']
            repos    = @($manifest['repos'] | ForEach-Object { [ordered]@{ name = $_['name']; role = $_['role']; branch = $_['branch']; path = $_['path']; baseCommit = $_['baseCommit'] } })
        }
        if ($env) {
            $row['repos'] = @($manifest['repos'] | ForEach-Object {
                    $state = Get-OctoEnvironmentRepoState -repo $_
                    [ordered]@{ name = $_['name']; role = $_['role']; branch = $_['branch']; path = $_['path']; baseCommit = $_['baseCommit']; exists = $state.exists; dirty = $state.dirty; unpushed = $state.unpushed }
                })
        }
        $rows += [pscustomobject]$row
    }
    if ($missing) {
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Get-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ error = $missing }) }
        else { Write-Error $missing }
        return
    }
    if ($Json) {
        $data = if ($env) { $rows[0] } else { [ordered]@{ environments = @($rows) } }
        Write-OctoJson -Command 'Get-OctoEnvironment' -Data $data
        return
    }
    if ($rows.Count -eq 0) { Write-Host "No feature environments in $environmentsRoot"; return }
    foreach ($row in $rows) {
        Write-Host ("{0}  {1}  base {2}  {3}" -f $row.name, $(if ($row.workItem) { $row.workItem } else { '-' }), $row.base, $row.path) -ForegroundColor Cyan
        foreach ($repo in $row.repos) {
            $flags = @()
            if ($repo.Contains('exists') -and -not $repo['exists']) { $flags += 'MISSING' }
            if ($repo.Contains('dirty') -and $repo['dirty']) { $flags += 'dirty' }
            if ($repo.Contains('unpushed') -and $repo['unpushed'] -gt 0) { $flags += "$($repo['unpushed']) unpushed" }
            Write-Host ("  {0,-9} {1,-40} {2} {3}" -f $repo['role'], $repo['name'], $(if ($repo['branch']) { $repo['branch'] } else { 'detached' }), ($flags -join ', '))
        }
    }
}

<#
.SYNOPSIS
    Adds a repository to an environment: a feature worktree on the environment's branch, or a consumer worktree
    detached at the base checkout's commit.
.DESCRIPTION
    -role feature (default) uses the branch of the environment's existing feature repositories (or the default
    <user>/AB#<id>_<desc>). -role consumer adds a clean, detached worktree that is rebuilt against the
    environment's packages (read-only by convention). -addAffected also adds, as consumers, every affected
    repository on the path from a feature repository to -repo (Get-OctoAffectedRepos -target), so a service gets
    every intermediate library rebuilt.
.EXAMPLE
    Add-OctoEnvironmentRepo -env ab8625-enum-null -repo octo-asset-repo-services -role consumer -addAffected
#>
function Add-OctoEnvironmentRepo {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [Parameter(Mandatory = $true)] [string]$repo,
        [ValidateSet('feature', 'consumer')] [string]$role = 'feature',
        [switch]$addAffected,
        [switch]$Json
    )

    $fail = {
        param([string]$message)
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $message }) }
        else { Write-Error $message }
    }
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
        $name = Resolve-OctoEnvironmentRepoName -repo $repo -basePath $basePath
    }
    catch { & $fail $_.Exception.Message; return }

    $present = @($manifest['repos'] | ForEach-Object { $_['name'] })
    $toAdd = [System.Collections.Generic.List[object]]::new()
    if ($present -notcontains $name) { $toAdd.Add([pscustomobject]@{ Name = $name; Role = $role }) }
    if ($addAffected) {
        $affected = Get-OctoEnvironmentAffected -manifest $manifest -basePath $basePath
        if ($affected.Features.Count -eq 0) { & $fail "-addAffected needs at least one feature repository in $env."; return }
        foreach ($onPath in @(Get-OctoReposOnPath -graph $affected.Graph -target $name)) {
            if ($onPath -ne $name -and $present -notcontains $onPath) { $toAdd.Add([pscustomobject]@{ Name = $onPath; Role = 'consumer' }) }
        }
    }
    if ($toAdd.Count -eq 0) {
        $global:LASTEXITCODE = 0
        if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ environment = $env; added = @(); note = "$name is already in $env" }) }
        else { Write-Host "$name is already in $env - nothing to add." }
        return
    }
    $branchName = @($manifest['repos'] | Where-Object { $_['role'] -eq 'feature' -and $_['branch'] } | ForEach-Object { $_['branch'] } | Select-Object -First 1)
    $branchName = if ($branchName) { [string]$branchName[0] } else { Get-OctoEnvironmentDefaultBranchName -env $env -workItem $manifest['workItem'] }

    $plan = @($toAdd | ForEach-Object { "$($_.Role) $($_.Name)" })
    if (-not $PSCmdlet.ShouldProcess($environmentPath, "Add worktree(s): $($plan -join ', ')")) {
        if ($Json) { Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data ([ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; added = $plan }) }
        return
    }
    $added = @()
    $errors = @()
    foreach ($item in $toAdd) {
        try {
            $manifest['repos'] = @($manifest['repos']) + @(Add-OctoEnvironmentWorktree -basePath $basePath -environmentPath $environmentPath -repo $item.Name -role $item.Role -branchName $branchName)
            Write-OctoEnvironmentManifest -environmentPath $environmentPath -manifest $manifest
            $added += [ordered]@{ name = $item.Name; role = $item.Role }
        }
        catch { $errors += $_.Exception.Message }
    }
    $success = $errors.Count -eq 0
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    if ($Json) {
        Write-OctoJson -Command 'Add-OctoEnvironmentRepo' -Data (New-OctoActionResult -Success $success -ExitCode $global:LASTEXITCODE -Extra @{ environment = $env; added = $added; errors = $errors })
        return
    }
    foreach ($item in $added) { Write-Host ("Added {0} {1} to {2}" -f $item.role, $item.name, $env) -ForegroundColor Green }
    foreach ($message in $errors) { Write-Warning $message }
}

<#
.SYNOPSIS
    Refreshes an environment's snapshot of the base lane: feed, CK catalog and blueprint catalog.
.DESCRIPTION
    Port of octo-devstack's PrivateFeed rules: packages missing in the environment are copied; packages whose base
    copy changed are refreshed when the environment did not change them; packages built in the environment always
    win. Afterwards <env>/.nuget-packages/<id>/<version> folders whose nupkg differs from the feed are purged (NuGet
    never re-extracts a version it has). The catalogs follow the same rules; a catalog index (catalog.json) changed
    on both sides is JSON-merged (union, the environment's entry wins), a catalog cache file changed on both sides
    is dropped. The per-file state lives in <env>/.octo/sync/*.json. The base lane's feed is never written.
    Snapshot, not live: run it only when main is not being rebuilt (octo-devstack refuses a sync while a main
    build is queued or running).
.EXAMPLE
    Sync-OctoEnvironment -env ab8625-enum-null -WhatIf -Json
#>
function Sync-OctoEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [switch]$Json
    )
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
        if (-not (Test-Path -LiteralPath $basePath -PathType Container)) { throw "Base lane $basePath does not exist." }
    }
    catch {
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Sync-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $_.Exception.Message }) }
        else { Write-Error $_.Exception.Message }
        return
    }
    $dryRun = -not $PSCmdlet.ShouldProcess($environmentPath, "Sync feed and catalogs from $basePath")
    $sync = Invoke-OctoEnvironmentSync -environmentPath $environmentPath -basePath $basePath -dryRun:$dryRun
    $global:LASTEXITCODE = 0
    if ($Json) {
        $data = New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ environment = $env }
        foreach ($key in $sync.Keys) { $data[$key] = $sync[$key] }
        Write-OctoJson -Command 'Sync-OctoEnvironment' -Data $data
        return
    }
    Write-Host "Synced $env from $basePath$(if ($dryRun) { ' (dry run - nothing written)' })" -ForegroundColor Green
    Write-OctoEnvironmentSyncSummary -sync $sync
}

<#
.SYNOPSIS
    The repositories a feature environment's changes reach: transitive consumers of its feature repositories.
.DESCRIPTION
    Builds a package graph from every repository of the base lane (the environment's worktrees replace their base
    folders): produced package ids (packable csproj, <PackageId> or the project name; <IsPackable>false</IsPackable>
    produces nothing) and <PackageReference Include="Meshmakers.*"> entries of csproj and props files. A library change
    reaches a service only if every repository between them is rebuilt against the environment feed; prebuilt main
    packages of intermediate libraries would bind to the new library at runtime (MissingMethodException).
    -target limits the result to the repositories on the path from a feature repository to the given repositories.
.EXAMPLE
    Get-OctoAffectedRepos -env ab8625-enum-null -target octo-asset-repo-services -Json
#>
function Get-OctoAffectedRepos {
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [string[]]$target = @(),
        [switch]$Json
    )
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
        $targets = @($target | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { Resolve-OctoEnvironmentRepoName -repo $_.Trim() -basePath $basePath })
    }
    catch {
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Get-OctoAffectedRepos' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $_.Exception.Message }) }
        else { Write-Error $_.Exception.Message }
        return
    }
    $affected = Get-OctoEnvironmentAffected -manifest $manifest -basePath $basePath
    $rows = @($affected.Graph.Affected)
    if ($targets.Count -gt 0) {
        $keep = @{}
        foreach ($t in $targets) { foreach ($name in @(Get-OctoReposOnPath -graph $affected.Graph -target $t)) { $keep[$name] = $true } }
        $rows = @($rows | Where-Object { $keep.ContainsKey($_.repo) })
    }
    $present = @{}
    foreach ($repo in $manifest['repos']) { $present[$repo['name']] = $repo['role'] }
    $result = @($rows | ForEach-Object {
            [pscustomobject][ordered]@{ repo = $_.repo; depth = $_.depth; via = $_.via; inEnvironment = $present.ContainsKey($_.repo); role = $present[$_.repo] }
        })
    $global:LASTEXITCODE = 0
    if ($Json) {
        Write-OctoJson -Command 'Get-OctoAffectedRepos' -Data ([ordered]@{ environment = $env; features = $affected.Features; targets = $targets; affected = $result })
        return
    }
    Write-Host "Feature repositories: $($affected.Features -join ', ')" -ForegroundColor Cyan
    if ($result.Count -eq 0) { Write-Host "  no affected repositories"; return }
    foreach ($row in $result) {
        $mark = if ($row.inEnvironment) { "[$($row.role)]" } else { '[not in env]' }
        Write-Host ("  {0,-45} depth {1} {2,-13} via {3}" -f $row.repo, $row.depth, $mark, ($row.via -join ', '))
    }
}

<#
.SYNOPSIS
    Removes a feature environment: its worktrees and its folder (feed, cache, catalogs, logs).
.DESCRIPTION
    Refuses - and removes nothing - when a worktree has uncommitted or untracked changes, or commits that are on no
    remote (feature branch) / on no remote or local branch (consumer). There is no -force: commit and push, or
    discard, first. Feature branches are kept. Stop the environment's services first (octo-devstack env_remove does
    that and releases the lease).
.EXAMPLE
    Remove-OctoEnvironment -env ab8625-enum-null -WhatIf
#>
function Remove-OctoEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [switch]$Json
    )
    $fail = {
        param([string]$message, $states)
        $global:LASTEXITCODE = 1
        if ($Json) { Write-OctoJson -Command 'Remove-OctoEnvironment' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ environment = $env; error = $message; repos = $states }) }
        else { Write-Error $message }
    }
    try {
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist (no $(Get-OctoEnvironmentManifestPath -environmentPath $environmentPath))." }
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
    }
    catch { & $fail $_.Exception.Message @(); return }

    $states = @($manifest['repos'] | ForEach-Object { Get-OctoEnvironmentRepoState -repo $_ })
    $blocking = @($states | Where-Object { $_.dirty -or $_.unpushed -gt 0 -or $_.problem })
    if ($blocking.Count -gt 0) {
        $reasons = @($blocking | ForEach-Object {
                $why = @()
                if ($_.dirty) { $why += 'uncommitted changes' }
                if ($_.unpushed -gt 0) { $why += "$($_.unpushed) unpushed commit(s)" }
                if ($_.problem) { $why += $_.problem }
                "$($_.name): $($why -join ', ')"
            })
        & $fail "Remove-OctoEnvironment refused, nothing removed: $($reasons -join '; ')." $states
        return
    }

    if (-not $PSCmdlet.ShouldProcess($environmentPath, "Remove $(@($manifest['repos']).Count) worktree(s) and the environment folder")) {
        if ($Json) { Write-OctoJson -Command 'Remove-OctoEnvironment' -Data ([ordered]@{ success = $true; exitCode = 0; dryRun = $true; environment = $env; path = $environmentPath; repos = $states }) }
        return
    }
    $errors = @()
    foreach ($repo in $manifest['repos']) {
        $source = Join-Path $basePath $repo['name']
        if (Test-Path -LiteralPath $repo['path']) {
            # Clean by the check above; --force only lets git remove a worktree with submodules or ignored build output.
            $remove = Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'remove', '--force', $repo['path'])
            if ($remove.ExitCode -ne 0) { $errors += "git worktree remove failed for $($repo['name']): $($remove.Output -join ' ')"; continue }
        }
        [void](Invoke-OctoEnvironmentGit -path $source -arguments @('worktree', 'prune'))
    }
    if ($errors.Count -eq 0) {
        Remove-Item -LiteralPath $environmentPath -Recurse -Force
    }
    $success = $errors.Count -eq 0
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    if ($Json) {
        Write-OctoJson -Command 'Remove-OctoEnvironment' -Data (New-OctoActionResult -Success $success -ExitCode $global:LASTEXITCODE -Extra @{ environment = $env; path = $environmentPath; repos = $states; errors = $errors })
        return
    }
    if ($success) { Write-Host "Removed environment $env ($environmentPath); feature branches are kept." -ForegroundColor Green }
    foreach ($message in $errors) { Write-Error $message }
}

<#
.SYNOPSIS
    Builds a feature environment incrementally: optional sync with the base lane, then Invoke-BuildRange over the
    environment's repositories.
.DESCRIPTION
    Runs Invoke-BuildRange -branch envs/<env> from the first to the last repository of the environment in the
    shared build order (OctoBuildOrder.psm1; frontends included when the environment holds one). Packages go to
    <env>/nuget, the per-package purge hits only <env>/.nuget-packages (the environment is an isolated lane).
    -syncMain runs Sync-OctoEnvironment first. Before every hand-off use -verifyTests or -includeTests.
    -DryRun prints the plan (Invoke-BuildRange -WhatIf) and changes nothing, also no sync. -EventsFile writes the
    build events with command "Invoke-BuildEnvironment".
.EXAMPLE
    Invoke-BuildEnvironment -env ab8625-enum-null -syncMain -verifyTests
#>
function Invoke-BuildEnvironment {
    param(
        [Parameter(Mandatory = $true)] [string]$env,
        [switch]$syncMain,
        [switch]$verifyTests,
        [switch]$includeTests,
        [string]$EventsFile = '',
        [switch]$DryRun,
        [switch]$Json
    )
    $fail = {
        param([string]$message)
        $global:LASTEXITCODE = 1
        if ($EventsFile -and -not $DryRun) {
            Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-BuildEnvironment' -Event 'done' -Data ([ordered]@{ success = $false; failedRepo = $null; failedStep = 'preflight'; elapsedSeconds = 0 })
        }
        if ($Json) { Write-OctoJson -Command 'Invoke-BuildEnvironment' -Data ([ordered]@{ success = $false; error = $message; environment = $env; synced = $false; repositories = @() }) }
        else { Write-Error $message }
    }
    try {
        $manifest = Read-OctoEnvironmentManifest -env $env
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Get-OctoEnvironmentPath -env $env
        $basePath = Get-OctoEnvironmentBasePath -base ([string]$manifest['base'])
    }
    catch { & $fail $_.Exception.Message; return }
    $order = @(Get-OctoBuildOrder -branchRootPath $environmentPath -excludeFrontend $false -excludeAdditional $false)
    if ($order.Count -eq 0) { & $fail "Environment $env holds no repository."; return }

    $sync = $null
    if ($syncMain -and -not $DryRun) {
        if (-not (Test-Path -LiteralPath $basePath -PathType Container)) { & $fail "Base lane $basePath does not exist."; return }
        $sync = Invoke-OctoEnvironmentSync -environmentPath $environmentPath -basePath $basePath
        if (-not $Json) { Write-Host "Synced $env from $basePath" -ForegroundColor Green; Write-OctoEnvironmentSyncSummary -sync $sync }
    }

    $range = @{
        branch          = "envs/$env"
        from            = $order[0].Name
        to              = $order[-1].Name
        excludeFrontend = $false
        EventsCommand   = 'Invoke-BuildEnvironment'
    }
    if ($verifyTests) { $range['verifyTests'] = $true }
    if ($includeTests) { $range['includeTests'] = $true }
    if ($EventsFile) { $range['EventsFile'] = $EventsFile }
    if ($DryRun) { $range['WhatIf'] = $true }

    if (-not $Json) {
        Invoke-BuildRange @range
        return
    }
    $output = @(Invoke-BuildRange @range -Json)
    $exitCode = $global:LASTEXITCODE
    $data = [ordered]@{}
    try {
        $inner = ($output -join "`n") | ConvertFrom-Json -AsHashtable
        foreach ($key in $inner['data'].Keys) { $data[$key] = $inner['data'][$key] }
    }
    catch {
        $data['success'] = $false
        $data['error'] = "Invoke-BuildRange returned no JSON document: $($_.Exception.Message)"
        $exitCode = 1
    }
    $data['environment'] = [ordered]@{ name = $env; path = $environmentPath; base = $basePath; repos = @($order | ForEach-Object Name) }
    $data['synced'] = $null -ne $sync
    if ($null -ne $sync) { $data['sync'] = $sync }
    $global:LASTEXITCODE = $exitCode
    Write-OctoJson -Command 'Invoke-BuildEnvironment' -Data $data
}

Export-ModuleMember -Function @(
    'New-OctoEnvironment',
    'Get-OctoEnvironment',
    'Add-OctoEnvironmentRepo',
    'Sync-OctoEnvironment',
    'Get-OctoAffectedRepos',
    'Remove-OctoEnvironment',
    'Invoke-BuildEnvironment'
)
