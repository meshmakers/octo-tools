<#
    Test-OctoBuildChain - read-only "build doctor" for the base lane (AB#6350).

    One check answers: why does the DebugL build of the lane fail (NU1101/NU1102, odd restore results) and which is
    the smallest Invoke-BuildRange that fixes it. It never builds, copies, purges, switches or fetches anything.

    What it does NOT duplicate (octo-devstack, other repository): build_plan predicts build/skip per repository,
    stack_attention lists failed builds and lane problems, setup_check lists machine prerequisites. None of them looks
    at the branch of the base-lane repositories or at the global 999.0.0 cache outside a build; that is this module.
#>

$script:OctoLocalPackageVersion = '999.0.0'
$script:OctoChainGitReadOnly = @('--no-optional-locks')   # `git status` must not refresh the index

function Invoke-OctoChainGit {
    # The only way this module runs git: read-only subcommands, never a write, never the network.
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        [Parameter(Mandatory = $true)] [string[]]$gitArguments
    )
    $allowed = @('rev-parse', 'symbolic-ref', 'status', 'log', 'ls-files', 'grep')
    if ($gitArguments[0] -notin $allowed) { throw "Invoke-OctoChainGit: '$($gitArguments[0])' is not a read-only git command." }
    $output = & git @script:OctoChainGitReadOnly -C $path @gitArguments 2>$null
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($output | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
}

function Get-OctoChainRepoState {
    # Branch, detached state, dirtiness and last commit time of one repository checkout.
    param([Parameter(Mandatory = $true)] [object]$repo)

    $state = [ordered]@{
        name = $repo.Name; path = $repo.Path; group = $repo.Group
        isGit = $false; branch = $null; detached = $false; commit = $null; dirty = $false; dirtyCount = 0; commitTime = $null
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repo.Path '.git'))) { return [pscustomobject]$state }
    $head = Invoke-OctoChainGit -path $repo.Path -gitArguments @('rev-parse', '--short', 'HEAD')
    if ($head.ExitCode -ne 0) { return [pscustomobject]$state }
    $state.isGit = $true
    $state.commit = $head.Lines | Select-Object -First 1
    $branch = Invoke-OctoChainGit -path $repo.Path -gitArguments @('symbolic-ref', '-q', '--short', 'HEAD')
    if ($branch.ExitCode -eq 0 -and $branch.Lines.Count -gt 0) { $state.branch = $branch.Lines[0] } else { $state.detached = $true }
    $porcelain = Invoke-OctoChainGit -path $repo.Path -gitArguments @('status', '--porcelain')
    $state.dirtyCount = @($porcelain.Lines | Where-Object { $_ -ne '' }).Count
    $state.dirty = $state.dirtyCount -gt 0
    $time = Invoke-OctoChainGit -path $repo.Path -gitArguments @('log', '-1', '--format=%ct')
    if ($time.ExitCode -eq 0 -and $time.Lines.Count -gt 0 -and $time.Lines[0] -match '^\d+$') {
        $state.commitTime = [DateTimeOffset]::FromUnixTimeSeconds([long]$time.Lines[0]).UtcDateTime
    }
    return [pscustomobject]$state
}

function Get-OctoChainPackageIndex {
    # Which repository produces which Meshmakers.* package and which repository references which package ids.
    # Producer = a tracked csproj outside tests/samples with <GeneratePackageOnBuild>true and an explicit <PackageId>.
    # References = Include="Meshmakers.*" in tracked csproj/props/targets files (git grep: one fast call per repo).
    param([Parameter(Mandatory = $true)] [object[]]$repos)

    $producedBy = @{}
    $idCase = @{}
    $references = @{}
    foreach ($repo in $repos) {
        $references[$repo.Name] = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        if (-not (Test-Path -LiteralPath (Join-Path $repo.Path '.git'))) { continue }
        $projects = Invoke-OctoChainGit -path $repo.Path -gitArguments @('ls-files', '--', '*.csproj')
        foreach ($relative in $projects.Lines) {
            if ($relative -match '(^|/)(tests?|samples?)/' -or $relative -match '\.Tests?/') { continue }
            $file = Join-Path $repo.Path $relative
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
            $text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($text)) { continue }
            if ($text -match '<GeneratePackageOnBuild>\s*true\s*</GeneratePackageOnBuild>' -and $text -match '<PackageId>\s*(Meshmakers\.[^<\s]+)\s*</PackageId>') {
                $producedBy[$Matches[1].ToLowerInvariant()] = $repo.Name
                $idCase[$Matches[1].ToLowerInvariant()] = $Matches[1]
            }
        }
        $grep = Invoke-OctoChainGit -path $repo.Path -gitArguments @('grep', '-h', '-o', '-E', 'Include="Meshmakers\.[A-Za-z0-9._]+"', '--', '*.csproj', '*.props', '*.targets')
        foreach ($line in $grep.Lines) {
            if ($line -match 'Include="(Meshmakers\.[A-Za-z0-9._]+)"') { [void]$references[$repo.Name].Add($Matches[1].ToLowerInvariant()) }
        }
    }
    return [pscustomobject]@{ ProducedBy = $producedBy; IdCase = $idCase; References = $references }
}

function Get-OctoChainLaneArgument {
    # "-branch <lane>" for an Invoke-BuildRange command when the checked lane is not the profile's own checkout;
    # '' for the default lane, and for a -LaneRoot outside $rootPath (Invoke-BuildRange cannot name it).
    param([string]$branch, [string]$laneRoot, [bool]$laneRootGiven)
    if ($branch -ne '') { return "-branch $branch" }
    if (-not $laneRootGiven -or [string]::IsNullOrWhiteSpace([string]$global:rootPath)) { return '' }
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$global:rootPath))
    if ($laneRoot.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if ($laneRoot.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return '-branch ' + $laneRoot.Substring($prefix.Length).Replace('\', '/') }
    return ''
}

function Test-OctoChainRepoBuildable {
    # A repository the build order really builds: a solution or a build.ps1 in its root (octo-mesh-deployment and
    # octo-pipeline-templates are in the order but build nothing).
    param([Parameter(Mandatory = $true)] [string]$path)
    return [bool](Get-ChildItem -LiteralPath $path -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '*.sln' -or $_.Name -like '*.slnx' -or $_.Name -eq 'build.ps1' } | Select-Object -First 1)
}

function Get-OctoChainRange {
    # Smallest Invoke-BuildRange slice that rebuilds the producers of the affected packages.
    # -consumers adds the repositories that (transitively) reference what the slice rebuilds - the longer, safer slice.
    param(
        [Parameter(Mandatory = $true)] [string[]]$producers,
        [Parameter(Mandatory = $true)] [object[]]$order,
        [Parameter(Mandatory = $true)] [object]$index,
        [string[]]$consumer = @(),
        [switch]$consumers
    )

    $position = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $position[$order[$i].Name] = $i }
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($producer in $producers) { if ($position.ContainsKey($producer)) { [void]$set.Add($producer) } }
    if ($set.Count -eq 0) { return $null }
    $from = ($set | Sort-Object { $position[$_] } | Select-Object -First 1)

    if ($consumers) {
        do {
            $added = $false
            $providedIds = @($index.ProducedBy.Keys | Where-Object { $set.Contains($index.ProducedBy[$_]) })
            foreach ($repo in $order) {
                if ($set.Contains($repo.Name) -or $position[$repo.Name] -lt $position[$from]) { continue }
                if (@($providedIds | Where-Object { $index.References[$repo.Name].Contains($_) }).Count -gt 0) { [void]$set.Add($repo.Name); $added = $true }
            }
        } while ($added)
    }
    foreach ($name in @($consumer | Where-Object { $_ })) {
        if ($position.ContainsKey($name) -and $position[$name] -ge $position[$from]) { [void]$set.Add($name) }
    }
    $to = ($set | Sort-Object { $position[$_] } | Select-Object -Last 1)
    return [pscustomobject]@{ From = $from; To = $to }
}

function Format-OctoChainRangeCommand {
    param([Parameter(Mandatory = $true)] [object]$range, [switch]$purgeStaleCache, [string]$laneArgument = '')
    $command = "Invoke-BuildRange -from $($range.From) -to $($range.To)"
    if ($laneArgument) { $command += " $laneArgument" }
    if ($purgeStaleCache) { $command += ' -purgeStaleCache' }
    return $command
}

function Read-OctoChainBuildLog {
    # NU1101/NU1102/NU1103 "Unable to find package <id>" lines of a build log -> distinct (package id, consuming repo).
    # Only ids and repository names leave this function, never log text.
    param([Parameter(Mandatory = $true)] [string]$path, [string[]]$repoNames = @())

    $result = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [IO.File]::ReadLines($path)) {
        # The text of the message is translated with the UI culture of the SDK; the code is not. English text names the
        # package after "package"; otherwise the first Meshmakers.* token AFTER the error code is taken (the text before
        # it is the failing project's own path, which may contain Meshmakers.* too).
        $codeMatch = [regex]::Match($line, 'error\s+(?<code>NU110[123])\s*:')
        if (-not $codeMatch.Success) { continue }
        $code = $codeMatch.Groups['code'].Value
        $messageText = $line.Substring($codeMatch.Index + $codeMatch.Length)
        if ($messageText -match 'Unable to find (?:a stable )?package\s+(?<id>[A-Za-z0-9_.\-]+)') { $id = $Matches['id'].TrimEnd('.') }
        elseif ($messageText -match '(?<id>Meshmakers\.[A-Za-z0-9_.\-]*[A-Za-z0-9_])') { $id = $Matches['id'] }
        else { continue }
        $consumer = ''
        $normalized = $line -replace '\\', '/'
        foreach ($name in $repoNames) {
            if ($normalized -match "(^|[/\s'""\[(])$([regex]::Escape($name))/") { $consumer = $name; break }
        }
        if ($seen.Add("$id|$consumer|$code")) { $result.Add([pscustomobject]@{ PackageId = $id; Code = $code; Consumer = $consumer }) }
    }
    return $result.ToArray()
}

function Test-OctoBuildChain {
    <#
    .SYNOPSIS
        Read-only check of the base-lane build chain: wrong branches, missing or outdated 999.0.0 packages, stale
        package-cache folders and NU1101/NU1102 from a build log - each finding with the smallest fix as a command.

    .DESCRIPTION
        Runs against the base lane (default) or any checkout root. It writes nothing, runs only read-only git
        commands (rev-parse, symbolic-ref, status, log, ls-files, grep), never fetches and prints no environment
        variable except the lane paths (checkout, nuget feed, package cache). The fixes are only printed, never run.

        Checks (finding "check" values):
          branch         a chain repository is not on main (feature branch or detached HEAD). Blocking; a warning for a
                         repository that builds nothing (no solution, no build.ps1). Not checked in a feature environment
                         (<lane>/.octo/environment.json): its repositories are on feature branches or detached by design.
          dirty          a chain repository has uncommitted changes (the build uses them). Warning.
          missingPackage a package a chain repository produces is not in <lane>/nuget (the NU1101 case). Blocking.
          outdatedPackage the package in <lane>/nuget is older than the last commit of its repository. Warning.
          staleCache     a 999.0.0 folder of the lane's package cache differs from <lane>/nuget (hashMismatch, blocking)
                         or cannot be verified (noHashFile, warning); found with Get-OctoStaleGlobalPackages.
          buildLog       -BuildLog: NU1101/NU1102/NU1103 for a Meshmakers.* package, mapped to the producing repository. Blocking.
          notGit         a chain repository folder is not a git checkout. Warning.

        Exit code: $LASTEXITCODE is 1 when a blocking finding exists, else 0.

        Related (other repository, not duplicated here): octo-devstack build_plan (predicted build/skip per repository),
        stack_attention (failed builds, lane problems), setup_check (machine prerequisites).

    .PARAMETER branch
        Lane folder relative to $rootPath, like Invoke-BuildRange -branch. Default: the checkout the profile runs in.
        The printed Invoke-BuildRange commands then carry -branch <lane> (also for a -LaneRoot below $rootPath; a -LaneRoot
        elsewhere cannot be named by Invoke-BuildRange: run the command from that checkout's profile).

    .PARAMETER LaneRoot
        Absolute checkout root to check instead of -branch.

    .PARAMETER BuildLog
        Path of a build log; NU1101/NU1102/NU1103 package ids are mapped to the producing repository and the repository
        that failed (the fix then ends at that consumer).

    .PARAMETER GlobalPackagesPath
        Package cache(s) to check instead of the ones the lane restores into (tests, special setups).

    .PARAMETER Json
        Write one JSON document (envelope of OctoJsonOutput.psm1, command "Test-OctoBuildChain") instead of colored text.
        data: { success, exitCode, laneRoot, laneFeed, packageCaches[], elapsedSeconds,
        summary{ blocking, warning, recommendedFix },
        repositories[]{ name, group, branch, detached, dirty, dirtyCount, commit },
        findings[]{ id, check, severity (blocking|warning), repo, package, packages[], reason, message, fix,
        fixWithConsumers } }.

    .EXAMPLE
        Test-OctoBuildChain
    .EXAMPLE
        Test-OctoBuildChain -BuildLog ./build.log -Json | ConvertFrom-Json
    #>
    param(
        [string]$branch = '',
        [string]$LaneRoot = '',
        [string]$BuildLog = '',
        [string[]]$GlobalPackagesPath = @(),
        [switch]$Json
    )

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($branch -ne '' -and $LaneRoot -ne '') { throw 'Test-OctoBuildChain: use either -branch or -LaneRoot, not both.' }
    # A relative -LaneRoot / -BuildLog follows the PowerShell location ($PWD), never the process directory
    # ([IO.Path]::GetFullPath and [IO.File] resolve against that one, which Set-Location does not change; AB#8954).
    if ($LaneRoot -ne '') { $branchRootPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LaneRoot) }
    else { $branchRootPath = (Resolve-OctoBranchRootPath -branch $branch).BranchRootPath }
    $branchRootPath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($branchRootPath))
    if (-not (Test-Path -LiteralPath $branchRootPath -PathType Container)) { throw "Test-OctoBuildChain: lane root $branchRootPath does not exist." }

    $laneArgument = Get-OctoChainLaneArgument -branch $branch -laneRoot $branchRootPath -laneRootGiven ($LaneRoot -ne '')
    $laneSettings = Get-OctoLaneBuildSettings -laneRootPath $branchRootPath
    $feed = Join-Path $branchRootPath 'nuget'
    $caches = if ($GlobalPackagesPath.Count -gt 0) { @($GlobalPackagesPath) } else { @(Get-OctoRangePackageCaches -laneSettings $laneSettings) }

    $order = @(Get-OctoBuildOrder -branchRootPath $branchRootPath -excludeFrontend $true)
    $states = @($order | ForEach-Object { Get-OctoChainRepoState -repo $_ })
    $index = Get-OctoChainPackageIndex -repos $order
    # A feature environment (<lane>/.octo/environment.json) holds feature branches and detached consumer worktrees by
    # design (New-OctoEnvironment): no branch check there.
    $isEnvironment = Test-Path -LiteralPath (Join-Path (Join-Path $branchRootPath '.octo') 'environment.json') -PathType Leaf
    $findings = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$check, [string]$severity, [string]$repo, [string]$package, [string]$reason, [string]$message, [string]$fix, [string]$fixWithConsumers, [string[]]$packages = @())
        if ($package -and $packages.Count -eq 0) { $packages = @($package) }
        $findings.Add([pscustomobject][ordered]@{
                id = "F$($findings.Count + 1)"; check = $check; severity = $severity; repo = $repo; package = $package; packages = @($packages)
                reason = $reason; message = $message; fix = $fix; fixWithConsumers = $fixWithConsumers
            })
    }
    $rangeFixes = {
        param([string[]]$producers, [string[]]$consumer = @(), [switch]$purge)
        $small = Get-OctoChainRange -producers $producers -order $order -index $index -consumer $consumer
        $large = Get-OctoChainRange -producers $producers -order $order -index $index -consumer $consumer -consumers
        [pscustomobject]@{
            Small = if ($small) { Format-OctoChainRangeCommand -range $small -purgeStaleCache:$purge -laneArgument $laneArgument } else { '' }
            Large = if ($large) { Format-OctoChainRangeCommand -range $large -purgeStaleCache:$purge -laneArgument $laneArgument } else { '' }
            Range = $small
        }
    }
    $logConsumers = [System.Collections.Generic.List[string]]::new()

    # 1. branch / dirty
    foreach ($state in $states) {
        if (-not $state.isGit) {
            & $add 'notGit' 'warning' $state.name '' '' "$($state.name) is not a git checkout; branch and age cannot be checked." ''  ''
            continue
        }
        if (-not $isEnvironment -and ($state.detached -or $state.branch -ne 'main')) {
            $where = if ($state.detached) { "detached HEAD at $($state.commit)" } else { "branch '$($state.branch)'" }
            $switch = "git -C '$($state.path)' switch main"
            $reason = if ($state.detached) { 'detached' } else { 'featureBranch' }
            if (Test-OctoChainRepoBuildable -path $state.path) {
                $fixes = & $rangeFixes @($state.name)
                $after = if ($fixes.Small) { "; then $($fixes.Small)" } else { '' }
                $afterLarge = if ($fixes.Large) { "; then $($fixes.Large)" } else { '' }
                & $add 'branch' 'blocking' $state.name '' $reason "$($state.name) is on $where, the lane builds main." "Switch repo $($state.name) to main: $switch$after" "Switch repo $($state.name) to main: $switch$afterLarge"
            }
            else {
                & $add 'branch' 'warning' $state.name '' $reason "$($state.name) is on $where; it builds nothing, but the lane is meant to hold main." "Switch repo $($state.name) to main: $switch" ''
            }
        }
        if ($state.dirty) {
            & $add 'dirty' 'warning' $state.name '' '' "$($state.name) has $($state.dirtyCount) uncommitted change(s); the build uses them." "Commit, stash with a message or discard them in $($state.path), then rebuild the repository." ''
        }
    }

    # 2. packages of the chain repositories in <lane>/nuget
    $stateByName = @{}
    foreach ($state in $states) { $stateByName[$state.name] = $state }
    $feedFiles = @{}
    if (Test-Path -LiteralPath $feed -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $feed -File -Filter "*.$($script:OctoLocalPackageVersion).nupkg")) {
            $feedFiles[$file.Name.Substring(0, $file.Name.Length - ".$($script:OctoLocalPackageVersion).nupkg".Length).ToLowerInvariant()] = $file
        }
    }
    foreach ($producer in @($index.ProducedBy.Values | Sort-Object -Unique)) {
        $missing = @()
        $outdated = @()
        $time = $stateByName[$producer].commitTime
        foreach ($id in @($index.ProducedBy.Keys | Where-Object { $index.ProducedBy[$_] -eq $producer } | Sort-Object)) {
            $file = $feedFiles[$id]
            if (-not $file) { $missing += $index.IdCase[$id] }
            elseif ($time -and $file.LastWriteTimeUtc -lt $time) { $outdated += $index.IdCase[$id] }
        }
        if ($missing.Count -gt 0 -or $outdated.Count -gt 0) { $fixes = & $rangeFixes @($producer) }
        if ($missing.Count -gt 0) {
            & $add 'missingPackage' 'blocking' $producer $missing[0] 'missing' "$($missing.Count) package(s) of $producer are not in $feed (NU1101 in every consumer): $($missing -join ', ')." $fixes.Small $fixes.Large $missing
        }
        if ($outdated.Count -gt 0) {
            & $add 'outdatedPackage' 'warning' $producer $outdated[0] 'outdated' "$($outdated.Count) package(s) in $feed are older than the last commit of ${producer}: $($outdated -join ', ')." $fixes.Small $fixes.Large $outdated
        }
    }

    # 3. stale 999.0.0 cache folders (reuse of Invoke-BuildRange's check)
    $stale = @(Get-OctoStaleGlobalPackages -nugetPath $feed -globalPackagesPath $caches)
    foreach ($entry in $stale) {
        $producer = $index.ProducedBy[$entry.PackageId.ToLowerInvariant()]
        $severity = if ($entry.Reason -eq 'hashMismatch') { 'blocking' } else { 'warning' }
        if ($producer) {
            $fixes = & $rangeFixes @($producer) -purge
            & $add 'staleCache' $severity $producer $entry.PackageId $entry.Reason "Package cache folder $($entry.CachePath) is stale ($($entry.Reason))." $fixes.Small $fixes.Large
        }
        else {
            & $add 'staleCache' $severity '' $entry.PackageId $entry.Reason "Package cache folder $($entry.CachePath) is stale ($($entry.Reason)); no chain repository produces $($entry.PackageId)." '' ''
        }
    }

    # 4. build log
    if ($BuildLog -ne '') {
        $buildLogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BuildLog)
        if (-not (Test-Path -LiteralPath $buildLogPath -PathType Leaf)) {
            & $add 'buildLog' 'warning' '' '' 'logNotFound' "Build log $BuildLog does not exist." '' ''
        }
        else {
            foreach ($hit in @(Read-OctoChainBuildLog -path $buildLogPath -repoNames @($order | ForEach-Object Name))) {
                $producer = $index.ProducedBy[$hit.PackageId.ToLowerInvariant()]
                $consumerText = if ($hit.Consumer) { " in $($hit.Consumer)" } else { '' }
                if ($producer) {
                    if ($hit.Consumer) { $logConsumers.Add($hit.Consumer) }
                    $fixes = & $rangeFixes @($producer) $hit.Consumer
                    & $add 'buildLog' 'blocking' $producer $hit.PackageId $hit.Code "$($hit.Code): $($hit.PackageId) is not found$consumerText; produced by $producer." $fixes.Small $fixes.Large
                }
                else {
                    & $add 'buildLog' 'warning' '' $hit.PackageId $hit.Code "$($hit.Code): $($hit.PackageId) is not found$consumerText; no chain repository produces it (external package or feed problem)." '' ''
                }
            }
        }
    }

    # combined recommendation: one slice over every affected producer
    $blocking = @($findings | Where-Object severity -eq 'blocking').Count
    $warnings = @($findings | Where-Object severity -eq 'warning').Count
    $affected = @($findings | Where-Object { $_.repo -and $_.fix -and ($_.check -in 'missingPackage', 'outdatedPackage', 'staleCache', 'buildLog' -or ($_.check -eq 'branch' -and $_.severity -eq 'blocking')) } | ForEach-Object repo | Select-Object -Unique)
    $recommended = ''
    if ($affected.Count -gt 0) {
        $combined = Get-OctoChainRange -producers $affected -order $order -index $index -consumer @($logConsumers)
        # -purgeStaleCache only for a blocking stale-cache finding of a producer inside the combined range (a warning such
        # as noHashFile, or a stale folder no chain repository produces, does not need the purge).
        $needsPurge = @($findings | Where-Object { $_.check -eq 'staleCache' -and $_.severity -eq 'blocking' -and $_.repo -and $_.repo -in $affected }).Count -gt 0
        if ($combined) { $recommended = Format-OctoChainRangeCommand -range $combined -purgeStaleCache:$needsPurge -laneArgument $laneArgument }
    }

    $global:LASTEXITCODE = if ($blocking -gt 0) { 1 } else { 0 }
    $watch.Stop()

    if ($Json) {
        Write-OctoJson -Command 'Test-OctoBuildChain' -Data ([ordered]@{
                success       = ($blocking -eq 0)
                exitCode      = $global:LASTEXITCODE
                laneRoot      = $branchRootPath
                laneFeed      = $feed
                packageCaches = @($caches)
                elapsedSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 1)
                summary       = [ordered]@{ blocking = $blocking; warning = $warnings; recommendedFix = $recommended }
                repositories  = @($states | ForEach-Object { [ordered]@{ name = $_.name; group = $_.group; branch = $_.branch; detached = $_.detached; dirty = $_.dirty; dirtyCount = $_.dirtyCount; commit = $_.commit } })
                findings      = @($findings)
            })
        return
    }

    Write-Host "Build chain of $branchRootPath ($($order.Count) repositories, feed $feed)" -ForegroundColor Cyan
    Write-Host "Package cache(s): $($caches -join ', ')"
    if ($findings.Count -eq 0) {
        Write-Host "OK: no finding ($([math]::Round($watch.Elapsed.TotalSeconds, 1)) s)." -ForegroundColor Green
        return
    }
    foreach ($finding in $findings) {
        $color = if ($finding.severity -eq 'blocking') { 'Red' } else { 'Yellow' }
        Write-Host "[$($finding.severity)] $($finding.check): $($finding.message)" -ForegroundColor $color
        if ($finding.fix) { Write-Host "    fix: $($finding.fix)" }
        if ($finding.fixWithConsumers -and $finding.fixWithConsumers -ne $finding.fix) { Write-Host "    incl. consumers: $($finding.fixWithConsumers)" }
    }
    Write-Host "$blocking blocking, $warnings warning ($([math]::Round($watch.Elapsed.TotalSeconds, 1)) s)." -ForegroundColor $(if ($blocking -gt 0) { 'Red' } else { 'Yellow' })
    if ($recommended) { Write-Host "Smallest single range for all findings: $recommended" -ForegroundColor Cyan }
    Write-Host 'Nothing was changed; the fixes are only printed.'
}

Export-ModuleMember -Function @('Test-OctoBuildChain', 'Get-OctoChainRepoState', 'Get-OctoChainPackageIndex', 'Get-OctoChainRange', 'Read-OctoChainBuildLog')
