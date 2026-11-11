<#
.SYNOPSIS
    Build stamps (AB#8814): what a repository was built from, so an unchanged repository is not built again.

.DESCRIPTION
    After every successful repository of a range build that records stamps (Invoke-BuildRange -recordStamps /
    -skipUnchanged; Invoke-BuildEnvironment always), <lane>/.octo/build-stamps/<repo>.json holds the inputs of that
    build:

      head        git HEAD of the repository folder
      sourceHash  SHA-256 over HEAD, the diff of the tracked files against HEAD (staged and unstaged, binary
                  included) and the name and content of every untracked, not ignored file - so a commit, an edit, a
                  new file and a reverted edit are all seen; ignored files (bin/, obj/) and Invoke-Build.log are not
      packages    SHA-256 of every nupkg the repository consumes from the lane feed (<lane>/nuget/<id>.999.0.0.nupkg)
      tests       'compiled' when the test projects were compiled (-verifyTests / -includeTests), else 'none'
      properties  SHA-256 of the MSBuild properties the build was given (-msbuildProperties, per repository), so a
                  build with other properties is not taken for the same build

    A repository is unchanged when all of that is the same as now, its tests level covers the requested one and
    (dotnet repositories) a bin/DebugL folder still exists. The stamp is deleted before a repository is built - by
    every DebugL range build, also one that records no stamps - and written after it succeeded, so a failed or
    interrupted build never leaves a stamp that matches. No stamp is written while the package cache holds another
    build of a package the repository consumes (Invoke-BuildRange without -purgeStaleCache).
    The output check is a guard against a wiped tree (Remove-BinAndObjFolders, git clean), not an inventory of
    the build output: single deleted files are not noticed.

    Not seen: dependencies that are no Meshmakers.* package of the feed (a CK model taken only from the local
    catalog, npm packages of a frontend) and changes outside the repository folder (Octo.User.props, the SDK).
    Build those with Invoke-BuildEnvironment -buildUnchanged.
#>

$script:StampSchemaVersion = 1
$script:StampPackageVersion = '999.0.0'
$script:IgnoredUntracked = @('Invoke-Build.log')
# sha256 of a feed file, cached per (path, length, last write) for the lifetime of the module.
$script:FileHashCache = @{}

function Get-OctoStampTextHash {
    param([AllowEmptyString()] [string]$text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$text))).ToLowerInvariant()
}

function Get-OctoStampFileHash {
    param([Parameter(Mandatory = $true)] [string]$path)
    $file = [IO.FileInfo]::new($path)
    $key = "$($file.FullName)|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
    if ($script:FileHashCache.ContainsKey($key)) { return $script:FileHashCache[$key] }
    $stream = [IO.File]::OpenRead($file.FullName)
    try { $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
    finally { $stream.Dispose() }
    $script:FileHashCache[$key] = $hash
    return $hash
}

function Get-OctoRepoSourceState {
    <#
    .SYNOPSIS
        The git state of a repository folder: { Head; Dirty; Hash; Problem }. Problem is set (and Hash is $null)
        when the folder is no git checkout or git fails - such a repository is never "unchanged".
    #>
    param([Parameter(Mandatory = $true)] [string]$path)
    $state = [ordered]@{ Head = $null; Dirty = $false; Hash = $null; Problem = $null }
    $head = @(& git -C $path rev-parse HEAD 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { $state.Problem = "no git state: $($head -join ' ')"; return [pscustomobject]$state }
    $state.Head = [string]($head | Select-Object -Last 1)
    # Tracked files: staged and unstaged changes against HEAD, binary files included.
    $diff = @(& git -C $path -c core.quotePath=false diff HEAD --binary --no-ext-diff --no-color 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { $state.Problem = "git diff failed: $($diff -join ' ')"; return [pscustomobject]$state }
    $untracked = @(& git -C $path -c core.quotePath=false ls-files --others --exclude-standard 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) { $state.Problem = "git ls-files failed: $($untracked -join ' ')"; return [pscustomobject]$state }
    $untracked = @($untracked | Where-Object { $_ -and $script:IgnoredUntracked -notcontains $_ } | Sort-Object)
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("head:$($state.Head)")
    $parts.Add("diff:$(Get-OctoStampTextHash -text ($diff -join "`n"))")
    foreach ($relative in $untracked) {
        $file = Join-Path $path $relative
        $content = if (Test-Path -LiteralPath $file -PathType Leaf) { try { Get-OctoStampFileHash -path $file } catch { 'unreadable' } } else { 'missing' }
        $parts.Add("untracked:${relative}:$content")
    }
    $state.Dirty = ($diff.Count -gt 0 -or $untracked.Count -gt 0)
    $state.Hash = Get-OctoStampTextHash -text ($parts -join "`n")
    return [pscustomobject]$state
}

function Get-OctoFeedPackageHashes {
    <#
    .SYNOPSIS
        id -> sha256 of <feed>/<id>.999.0.0.nupkg for the given package ids (ids the feed does not hold are left
        out). Without -packageIds: every Meshmakers.*.999.0.0.nupkg of the feed except -excludeIds.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$feedPath,
        [string[]]$packageIds = $null,
        [string[]]$excludeIds = @()
    )
    $hashes = [ordered]@{}
    if (-not (Test-Path -LiteralPath $feedPath -PathType Container)) { return $hashes }
    $suffix = ".$($script:StampPackageVersion).nupkg"
    $files = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $feedPath -File -Filter "Meshmakers.*$suffix")) {
        $files[$file.Name.Substring(0, $file.Name.Length - $suffix.Length).ToLowerInvariant()] = $file
    }
    $excluded = @($excludeIds | ForEach-Object { $_.ToLowerInvariant() })
    $wanted = if ($null -ne $packageIds) { @($packageIds | ForEach-Object { $_.ToLowerInvariant() }) } else { @($files.Keys) }
    foreach ($id in @($wanted | Where-Object { $excluded -notcontains $_ } | Sort-Object -Unique)) {
        if ($files.ContainsKey($id)) { $hashes[$id] = Get-OctoStampFileHash -path $files[$id].FullName }
    }
    return $hashes
}

function Get-OctoBuildStampPath {
    param([Parameter(Mandatory = $true)] [string]$stampRoot, [Parameter(Mandatory = $true)] [string]$repo)
    return Join-Path $stampRoot "$repo.json"
}

function Read-OctoBuildStamp {
    # The stamp as a hashtable, or $null when there is none or it cannot be read (= never built).
    param([Parameter(Mandatory = $true)] [string]$stampRoot, [Parameter(Mandatory = $true)] [string]$repo)
    $path = Get-OctoBuildStampPath -stampRoot $stampRoot -repo $repo
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $stamp = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        if ($null -eq $stamp -or $stamp['schemaVersion'] -ne $script:StampSchemaVersion) { return $null }
        return $stamp
    }
    catch { return $null }
}

function Remove-OctoBuildStamp {
    param([Parameter(Mandatory = $true)] [string]$stampRoot, [Parameter(Mandatory = $true)] [string]$repo)
    $path = Get-OctoBuildStampPath -stampRoot $stampRoot -repo $repo
    if (-not (Test-Path -LiteralPath $path)) { return }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    # A stamp that stays would vouch for a build that is about to be replaced: stop instead.
    if (Test-Path -LiteralPath $path) { throw "Build stamp $path cannot be deleted - the build of $repo is not started, a later run would take the old stamp for this build." }
}

function Get-OctoMsBuildPropertiesHash {
    # SHA-256 of the effective MSBuild properties of a build ('' without any). RestoreConfigFile is left out: it is a
    # temporary file with another name in every run (Invoke-BuildEnvironment, credentials of in-place worktrees).
    param([System.Collections.IDictionary]$properties = $null)
    if ($null -eq $properties -or $properties.Count -eq 0) { return '' }
    $lines = @($properties.Keys | ForEach-Object { [string]$_ } | Where-Object { $_ -ine 'RestoreConfigFile' } | Sort-Object | ForEach-Object { "$_=$([string]$properties[$_])" })
    if ($lines.Count -eq 0) { return '' }
    return Get-OctoStampTextHash -text ($lines -join "`n")
}

function Write-OctoBuildStamp {
    # Never throws: a stamp that cannot be written only means the repository is built again next time.
    param(
        [Parameter(Mandatory = $true)] [string]$stampRoot,
        [Parameter(Mandatory = $true)] [string]$repo,
        [Parameter(Mandatory = $true)] $inputs,
        [Parameter(Mandatory = $true)] [string]$configuration,
        [Parameter(Mandatory = $true)] [ValidateSet('none', 'compiled')] [string]$tests
    )
    try {
        if (-not (Test-Path -LiteralPath $stampRoot)) { New-Item -ItemType Directory -Force -Path $stampRoot | Out-Null }
        $stamp = [ordered]@{
            schemaVersion = $script:StampSchemaVersion
            repo          = $repo
            builtAt       = (Get-Date).ToUniversalTime().ToString('o')
            configuration = $configuration
            tests         = $tests
            head          = $inputs.Source.Head
            dirty         = [bool]$inputs.Source.Dirty
            sourceHash    = $inputs.Source.Hash
            packages      = $inputs.Packages
            properties    = [string]$inputs.Properties
        }
        $path = Get-OctoBuildStampPath -stampRoot $stampRoot -repo $repo
        $temporary = "$path.$PID.tmp"
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $stamp -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $path -Force
    }
    catch { Write-Warning "Build stamp of $repo could not be written ($($_.Exception.Message)) - it is built again next time." }
}

function Get-OctoRepoBuildInputs {
    <#
    .SYNOPSIS
        The current inputs of a repository: { Source (Get-OctoRepoSourceState); Packages (id -> sha256);
        Properties (Get-OctoMsBuildPropertiesHash) }.
    .PARAMETER packageIds
        The package ids the repository consumes from the feed. $null: unknown - every package of the feed except
        the repository's own (-ownPackageIds) counts.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        [Parameter(Mandatory = $true)] [string]$feedPath,
        [string[]]$packageIds = $null,
        [string[]]$ownPackageIds = @(),
        [System.Collections.IDictionary]$msbuildProperties = $null
    )
    return [pscustomobject]@{
        Source     = Get-OctoRepoSourceState -path $path
        Packages   = Get-OctoFeedPackageHashes -feedPath $feedPath -packageIds $packageIds -excludeIds $ownPackageIds
        Properties = Get-OctoMsBuildPropertiesHash -properties $msbuildProperties
    }
}

function Test-OctoRepoHasBuildOutput {
    # A bin/<configuration> folder in the repository root or up to three levels below it (src/<project>/bin/DebugL).
    param([Parameter(Mandatory = $true)] [string]$path, [Parameter(Mandatory = $true)] [string]$configuration)
    $level = @($path)
    for ($depth = 0; $depth -le 3; $depth++) {
        $next = @()
        foreach ($folder in $level) {
            if (Test-Path -LiteralPath (Join-Path $folder "bin/$configuration") -PathType Container) { return $true }
            if ($depth -lt 3) {
                try {
                    $next += @([IO.Directory]::EnumerateDirectories($folder) | Where-Object { @('bin', 'obj', 'node_modules', '.git') -notcontains [IO.Path]::GetFileName($_) })
                }
                catch { continue }
            }
        }
        $level = $next
    }
    return $false
}

function Compare-OctoBuildStamp {
    <#
    .SYNOPSIS
        Compares a repository's stamp with its current inputs. Returns { Unchanged; Reason; Detail }.
        Reason: unchanged | neverBuilt | noGitState | sourcesChanged | packagesChanged | propertiesChanged |
        testsNotCompiled | configurationChanged | noBuildOutput.
    #>
    param(
        [AllowNull()] $stamp,
        [Parameter(Mandatory = $true)] $inputs,
        [Parameter(Mandatory = $true)] [string]$configuration,
        [Parameter(Mandatory = $true)] [ValidateSet('none', 'compiled')] [string]$tests,
        # Check that build output exists (dotnet repositories).
        [string]$outputPath = ''
    )
    $result = { param([bool]$unchanged, [string]$reason, [string]$detail) [pscustomobject]@{ Unchanged = $unchanged; Reason = $reason; Detail = $detail } }
    if ($inputs.Source.Problem) { return & $result $false 'noGitState' $inputs.Source.Problem }
    if ($null -eq $stamp) { return & $result $false 'neverBuilt' 'no successful build recorded here' }
    if ([string]$stamp['configuration'] -ine $configuration) { return & $result $false 'configurationChanged' "last build was $($stamp['configuration'])" }
    if ([string]$stamp['sourceHash'] -ne $inputs.Source.Hash) {
        $short = { param($commit) $text = [string]$commit; $text.Substring(0, [Math]::Min(10, $text.Length)) }
        $detail = if ([string]$stamp['head'] -ne $inputs.Source.Head) { "HEAD $(& $short $stamp['head']) -> $(& $short $inputs.Source.Head)" } else { 'uncommitted changes differ from the last build' }
        return & $result $false 'sourcesChanged' $detail
    }
    $recorded = if ($stamp['packages']) { $stamp['packages'] } else { @{} }
    $changed = @()
    foreach ($id in $inputs.Packages.Keys) { if ([string]$recorded[$id] -ne [string]$inputs.Packages[$id]) { $changed += $id } }
    foreach ($id in @($recorded.Keys)) { if (-not $inputs.Packages.Contains($id)) { $changed += $id } }
    if ($changed.Count -gt 0) {
        $changed = @($changed | Sort-Object -Unique)
        $names = @($changed | Select-Object -First 5) -join ', '
        return & $result $false 'packagesChanged' "$($changed.Count) consumed package(s) of the feed changed: $names$(if ($changed.Count -gt 5) { ', ...' })"
    }
    if ([string]$stamp['properties'] -ne [string]$inputs.Properties) { return & $result $false 'propertiesChanged' 'the MSBuild properties of the build differ from the last build' }
    if ($tests -eq 'compiled' -and [string]$stamp['tests'] -ne 'compiled') { return & $result $false 'testsNotCompiled' 'the last build did not compile the test projects' }
    if ($outputPath -and -not (Test-OctoRepoHasBuildOutput -path $outputPath -configuration $configuration)) { return & $result $false 'noBuildOutput' "no bin/$configuration folder" }
    return & $result $true 'unchanged' "sources and consumed packages as at the last build ($($stamp['builtAt']))"
}

Export-ModuleMember -Function @('Get-OctoRepoSourceState', 'Get-OctoFeedPackageHashes', 'Get-OctoBuildStampPath', 'Read-OctoBuildStamp', 'Remove-OctoBuildStamp',
    'Write-OctoBuildStamp', 'Get-OctoRepoBuildInputs', 'Get-OctoMsBuildPropertiesHash', 'Test-OctoRepoHasBuildOutput', 'Compare-OctoBuildStamp')
