<#
.SYNOPSIS
    Fast partial DebugL rebuild of a slice of the OctoMesh build chain (AB#5662).

.DESCRIPTION
    Invoke-BuildAll rebuilds the whole chain: it wipes <checkout>/nuget, deletes every
    ~/.nuget/packages/meshmakers.*/999.0.0 folder, forces a restore and builds whole solutions
    including tests. Invoke-BuildRange rebuilds only the repositories between -from and -to in the
    same order (OctoBuildOrder.psm1 is the shared source of truth) and touches only what those
    repositories produce.
#>

$script:OctoLocalPackageVersion = '999.0.0'
$script:OctoPackageFilter = "Meshmakers.*.$($script:OctoLocalPackageVersion).nupkg"

function Resolve-OctoBuildRangeRepo {
    # Resolves a user-supplied repository name against the build order.
    # Accepts the exact directory name, the name without the "octo-" prefix, or a unique substring.
    param(
        [Parameter(Mandatory = $true)] [string]$name,
        [Parameter(Mandatory = $true)] [object[]]$order
    )

    $exact = @($order | Where-Object { $_.Name -ieq $name })
    if ($exact.Count -eq 1) { return $exact[0] }

    $prefixed = @($order | Where-Object { $_.Name -ieq "octo-$name" })
    if ($prefixed.Count -eq 1) { return $prefixed[0] }

    $partial = @($order | Where-Object { $_.Name -like "*$name*" })
    if ($partial.Count -eq 1) { return $partial[0] }
    if ($partial.Count -gt 1) {
        throw "Repository name '$name' is ambiguous. Candidates: $(($partial.Name) -join ', ')"
    }
    throw "Repository '$name' is not part of the build order. Known repositories: $(($order.Name) -join ', ')"
}

function Get-OctoBuildRangeRepos {
    # Returns the ordered slice [from..to] of the build order, plus -include, minus -exclude.
    param(
        [Parameter(Mandatory = $true)] [object[]]$order,
        [Parameter(Mandatory = $true)] [string]$from,
        [string]$to = "",
        [string[]]$include = @(),
        [string[]]$exclude = @()
    )

    if ([string]::IsNullOrWhiteSpace($to)) { $to = $from }

    $fromRepo = Resolve-OctoBuildRangeRepo -name $from -order $order
    $toRepo = Resolve-OctoBuildRangeRepo -name $to -order $order

    $names = @($order.Name)
    $fromIndex = [Array]::IndexOf($names, $fromRepo.Name)
    $toIndex = [Array]::IndexOf($names, $toRepo.Name)
    if ($fromIndex -gt $toIndex) {
        throw "-from '$($fromRepo.Name)' (position $($fromIndex + 1)) comes after -to '$($toRepo.Name)' (position $($toIndex + 1)) in the build order."
    }

    $selected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($i = $fromIndex; $i -le $toIndex; $i++) { [void]$selected.Add($names[$i]) }
    foreach ($name in @($include | Where-Object { $_ })) {
        [void]$selected.Add((Resolve-OctoBuildRangeRepo -name $name -order $order).Name)
    }
    foreach ($name in @($exclude | Where-Object { $_ })) {
        [void]$selected.Remove((Resolve-OctoBuildRangeRepo -name $name -order $order).Name)
    }

    # Keep the global build order, also for -include entries outside the range.
    return @($order | Where-Object { $selected.Contains($_.Name) })
}

function Get-OctoRepoSolution {
    # The single .sln/.slnx in the repository root (first one alphabetically if there are several).
    param([Parameter(Mandatory = $true)] [string]$path)
    return Get-ChildItem -Path $path -File |
        Where-Object { $_.Extension -in '.sln', '.slnx' } |
        Sort-Object Name |
        Select-Object -First 1
}

function Get-OctoSolutionProjects {
    # Returns the project paths listed in a .sln or .slnx, exactly as written in the solution
    # (a .slnf must reference them verbatim). Solution folders are skipped.
    param([Parameter(Mandatory = $true)] [string]$solutionPath)

    if ($solutionPath -like '*.slnx') {
        [xml]$xml = Get-Content -Path $solutionPath -Raw
        return @($xml.SelectNodes('//Project') | ForEach-Object { $_.GetAttribute('Path') } | Where-Object { $_ -match 'proj$' })
    }

    $pattern = '^Project\("\{[^}]+\}"\)\s*=\s*"[^"]*",\s*"(?<path>[^"]+)"'
    return @(Get-Content -Path $solutionPath |
        ForEach-Object { if ($_ -match $pattern) { $Matches['path'] } } |
        Where-Object { $_ -match 'proj$' })
}

function Get-OctoSrcProjects {
    # Filters solution project paths down to the ones below src/.
    param([string[]]$projects = @())
    return @($projects | Where-Object { ($_ -replace '\\', '/') -like 'src/*' })
}

function Get-OctoRepoBuildMode {
    # Mirrors the dispatch in Invoke-BuildAll's Compile-Repo.
    param([Parameter(Mandatory = $true)] [object]$repo)

    if (Test-Path (Join-Path -Path $repo.Path -ChildPath 'build.ps1')) { return 'script' }
    if (-not (Get-OctoRepoSolution -path $repo.Path)) { return 'none' }
    if ($repo.Name -like '*frontend*') { return 'frontend' }
    if ($repo.Name -like '*octo-plug-zenon*') { return 'zenon' }
    return 'dotnet'
}

function Get-OctoRepoPackageFiles {
    # The DebugL packages of a repository, discovered exactly like Copy-NuGetPackages does
    # (every Meshmakers.*.999.0.0.nupkg below a bin/DebugL folder).
    param([Parameter(Mandatory = $true)] [string]$path)

    $binDirectories = Get-ChildItem -Path $path -Filter 'DebugL' -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*[/\]bin[/\]DebugL' }
    return @($binDirectories | ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -File -Filter $script:OctoPackageFilter })
}

function Get-OctoPackageIdFromFile {
    param([Parameter(Mandatory = $true)] [string]$fileName)
    return $fileName.Substring(0, $fileName.Length - ".$($script:OctoLocalPackageVersion).nupkg".Length)
}

function Get-OctoGlobalPackageDirectories {
    # Maps package ids to their <cache>/<id lower>/999.0.0 folders, for every package cache given.
    param(
        [string[]]$packageIds = @(),
        [Parameter(Mandatory = $true)] [string[]]$globalPackagesPath
    )
    $ids = @($packageIds | Sort-Object -Unique)
    return @(foreach ($cache in $globalPackagesPath) {
            foreach ($id in $ids) {
                Join-Path -Path (Join-Path -Path $cache -ChildPath $id.ToLowerInvariant()) -ChildPath $script:OctoLocalPackageVersion
            }
        })
}

function Remove-OctoGlobalPackageVersions {
    # Per-package purge: deletes only the given 999.0.0 folders (never the whole cache).
    param([string[]]$directories = @())
    $removed = @()
    foreach ($directory in $directories) {
        if (Test-Path $directory) {
            Remove-Item -Path $directory -Recurse -Force -ProgressAction SilentlyContinue
            $removed += $directory
        }
    }
    return $removed
}

function Get-OctoStaleGlobalPackages {
    # Compares every <checkout>/nuget/<id>.999.0.0.nupkg with the 999.0.0 folder of the same id in
    # each package cache the lane restores into (Get-OctoRangePackageCaches). NuGet records the
    # SHA-512 of the extracted nupkg in <id>.999.0.0.nupkg.sha512; when it differs from the local
    # package, restores in this checkout silently use another build, e.g. another lane's
    # ("hashMismatch"). A cache folder without a (non-empty) hash file cannot be verified ("noHashFile").
    param(
        [Parameter(Mandatory = $true)] [string]$nugetPath,
        [Parameter(Mandatory = $true)] [string[]]$globalPackagesPath
    )
    $stale = @()
    if (!(Test-Path $nugetPath)) { return $stale }
    foreach ($file in @(Get-ChildItem -Path $nugetPath -File -Filter $script:OctoPackageFilter)) {
        $id = (Get-OctoPackageIdFromFile -fileName $file.Name).ToLowerInvariant()
        $localHash = $null   # computed once per package, only when a cache has a hash to compare
        foreach ($cache in $globalPackagesPath) {
            $cacheDirectory = Join-Path -Path (Join-Path -Path $cache -ChildPath $id) -ChildPath $script:OctoLocalPackageVersion
            if (!(Test-Path $cacheDirectory)) { continue }   # not extracted yet - the next restore takes the local one
            $hashFile = Join-Path -Path $cacheDirectory -ChildPath "$id.$($script:OctoLocalPackageVersion).nupkg.sha512"
            $reason = $null
            if (!(Test-Path $hashFile)) {
                $reason = 'noHashFile'
            }
            else {
                # Read per package and cache, never reuse a previous value: an empty hash file
                # (interrupted extraction) reads as $null and counts as missing.
                $rawHash = Get-Content -Path $hashFile -Raw -ErrorAction SilentlyContinue
                $cacheHash = if ($null -eq $rawHash) { '' } else { ([string]$rawHash).Trim() }
                if ([string]::IsNullOrEmpty($cacheHash)) {
                    $reason = 'noHashFile'
                }
                else {
                    if ($null -eq $localHash) {
                        $stream = [IO.File]::OpenRead($file.FullName)
                        try { $localHash = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($stream)) }
                        finally { $stream.Dispose() }
                    }
                    if ($cacheHash -ne $localHash) { $reason = 'hashMismatch' }
                }
            }
            if ($reason) {
                $stale += [pscustomobject]@{ PackageId = $id; CachePath = $cacheDirectory; Reason = $reason }
            }
        }
    }
    return $stale
}

function Get-OctoRepoBinPrefixes {
    # "<repo>/bin/" for every repository (both separators, trailing separator included).
    param([object[]]$repos = @())
    return @($repos | ForEach-Object {
            $full = [IO.Path]::GetFullPath($_.Path).TrimEnd('/', '\')
            [pscustomobject]@{ Repo = $_.Name; Prefixes = @("$full/bin/", "$full\bin\") }
        })
}

function Select-OctoRepoProcessCandidates {
    # Pre-filter on the command line only: dotnet-hosted Meshmakers services (`dotnet Meshmakers.X.dll`,
    # started by Start-Octo with a relative dll and cwd <repo>/bin/<config>/<tfm>/) and anything that
    # executes from <repo>/bin/. Shells (e.g. Start-Octo's pwsh job workers started with -wd <repo>),
    # MSBuild nodes and compiler servers are not services and never lock the outputs we replace.
    param(
        [object[]]$candidates = @(),
        [object[]]$repos = @(),
        [int]$ownPid = $PID
    )
    $binPrefixes = @(Get-OctoRepoBinPrefixes -repos $repos)
    return @($candidates | Where-Object {
            $command = [string]$_.Command
            $executable = ($command -split '\s+', 2)[0]
            $_.Pid -ne $ownPid -and
            $command -notmatch '(MSBuild\.dll|VBCSCompiler|Roslyn|build-server)' -and
            (Split-Path -Leaf $executable) -notmatch '^(pwsh|powershell|zsh|bash|sh|fish|cmd)(\.exe)?$' -and
            ($command -match 'Meshmakers\.[^\s"]*\.(dll|exe)' -or
                @($binPrefixes | Where-Object { foreach ($prefix in $_.Prefixes) { if ($command.IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $true; break } } }).Count -gt 0)
        })
}

function Select-OctoRepoProcesses {
    # Assigns pre-filtered candidates (with Cwd resolved where possible) to repositories: a process
    # belongs to a repository when its working directory or its command line points into <repo>/bin/.
    param(
        [object[]]$candidates = @(),
        [object[]]$repos = @()
    )
    $found = @()
    $binPrefixes = @(Get-OctoRepoBinPrefixes -repos $repos)
    foreach ($candidate in $candidates) {
        $cwd = if ($candidate.Cwd) { [IO.Path]::GetFullPath([string]$candidate.Cwd).TrimEnd('/', '\') + [IO.Path]::DirectorySeparatorChar } else { $null }
        foreach ($entry in $binPrefixes) {
            $hit = $false
            foreach ($prefix in $entry.Prefixes) {
                if (($cwd -and $cwd.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) -or
                    ([string]$candidate.Command).IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true; break }
            }
            if ($hit) {
                $found += [pscustomobject]@{ Repo = $entry.Repo; Pid = $candidate.Pid; Command = $candidate.Command }
                break
            }
        }
    }
    return $found
}

function Get-OctoRunningRepoProcesses {
    # Finds processes that run out of <repo>/bin/ of the given repositories (Start-Octo services,
    # tools such as octo-ckc started from a build output). See Select-OctoRepoProcessCandidates.
    param([object[]]$repos = @())

    if ($repos.Count -eq 0) { return @() }

    $all = @()
    if ($IsWindows) {
        $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine } |
            ForEach-Object { [pscustomobject]@{ Pid = [int]$_.ProcessId; Command = $_.CommandLine; Cwd = $null } })
    }
    else {
        $all = @(& ps -axo 'pid=,command=' 2>$null | ForEach-Object {
                if ($_ -match '^\s*(\d+)\s+(.*)$') { [pscustomobject]@{ Pid = [int]$Matches[1]; Command = $Matches[2]; Cwd = $null } }
            })
    }

    $candidates = @(Select-OctoRepoProcessCandidates -candidates $all -repos $repos)

    # Windows exposes no working directory here; services there are matched by command line only,
    # which misses Start-Octo's `dotnet <Name>.dll` (relative path) - documented gap (T-L4).
    if (-not $IsWindows -and $candidates.Count -gt 0 -and (Get-Command lsof -ErrorAction SilentlyContinue)) {
        $pidList = ($candidates.Pid) -join ','
        $currentPid = $null
        foreach ($line in @(& lsof -a -d cwd -p $pidList -Fpn 2>$null)) {
            if ($line -like 'p*') { $currentPid = [int]$line.Substring(1) }
            elseif ($line -like 'n*' -and $currentPid) {
                $candidate = $candidates | Where-Object { $_.Pid -eq $currentPid } | Select-Object -First 1
                if ($candidate) { $candidate.Cwd = $line.Substring(1) }
            }
        }
    }

    return @(Select-OctoRepoProcesses -candidates $candidates -repos $repos)
}

function Get-OctoBuildRangePlan {
    # Builds the per-repository plan (mode, solution, projects, predicted packages). Read-only.
    param(
        [Parameter(Mandatory = $true)] [object[]]$repos,
        [switch]$includeTests,
        [Parameter(Mandatory = $true)] [string[]]$globalPackagesPath
    )

    $plan = @()
    foreach ($repo in $repos) {
        $mode = Get-OctoRepoBuildMode -repo $repo
        $solution = Get-OctoRepoSolution -path $repo.Path
        $projects = @()
        $testProjects = @()
        $target = $null
        $notes = @()
        switch ($mode) {
            'dotnet' {
                $allProjects = @(Get-OctoSolutionProjects -solutionPath $solution.FullName)
                $srcProjects = @(Get-OctoSrcProjects -projects $allProjects)
                if ($includeTests) {
                    $target = 'solution'
                    $projects = $allProjects
                }
                elseif ($srcProjects.Count -eq 0) {
                    $target = 'solution'
                    $projects = $allProjects
                    $notes += 'no src/ projects in the solution - building the whole solution'
                }
                else {
                    $target = 'slnf'
                    $projects = $srcProjects
                    # Everything outside src/ (tests, samples): compiled by -verifyTests, never run.
                    $testProjects = @($allProjects | Where-Object { $srcProjects -notcontains $_ })
                }
            }
            'script' { $target = 'build.ps1'; $notes += 'custom build.ps1 - src-only filtering does not apply' }
            'frontend' { $target = 'Invoke-Publish'; $notes += 'frontend - src-only filtering does not apply' }
            'zenon' { $target = 'Invoke-BuildZenonPlug'; $notes += 'zenon plug - src-only filtering does not apply' }
            'none' { $target = 'skip'; $notes += 'no solution file - nothing to build' }
        }

        $packageFiles = @(Get-OctoRepoPackageFiles -path $repo.Path)
        $packageIds = @($packageFiles | ForEach-Object { Get-OctoPackageIdFromFile -fileName $_.Name } | Sort-Object -Unique)
        # Packages more than an hour older than the repository's newest package were not rewritten
        # by its last build (incremental pack or a project that no longer exists).
        $olderIds = @()
        if ($packageFiles.Count -gt 0) {
            $newest = ($packageFiles | Measure-Object -Property LastWriteTime -Maximum).Maximum
            $olderIds = @($packageFiles | Where-Object { $_.LastWriteTime -lt $newest.AddHours(-1) } | ForEach-Object { Get-OctoPackageIdFromFile -fileName $_.Name } | Sort-Object -Unique)
        }
        if ($mode -ne 'none' -and $packageIds.Count -eq 0) {
            $notes += 'no DebugL packages found from a previous build - the purge list is determined after the build'
        }

        $plan += [pscustomobject]@{
            Name          = $repo.Name
            Path          = $repo.Path
            Group         = $repo.Group
            Mode          = $mode
            Target        = $target
            Solution      = if ($solution) { $solution.FullName } else { $null }
            Projects      = $projects
            TestProjects  = $testProjects
            PackageIds    = $packageIds
            PurgePaths    = @(Get-OctoGlobalPackageDirectories -packageIds $packageIds -globalPackagesPath $globalPackagesPath)
            OlderPaths    = @(Get-OctoGlobalPackageDirectories -packageIds $olderIds -globalPackagesPath $globalPackagesPath)
            Notes         = $notes
        }
    }
    return $plan
}

function New-OctoSolutionFilter {
    # Writes a .slnf that selects $projects from $solutionPath. The filter lives in the temp
    # folder so the repository stays clean; SolutionDir still resolves to the repository root.
    param(
        [Parameter(Mandatory = $true)] [string]$solutionPath,
        [Parameter(Mandatory = $true)] [string[]]$projects,
        [Parameter(Mandatory = $true)] [string]$name
    )
    # One folder per checkout (hash of the solution's parent directory) so concurrent runs in the
    # main and dev checkouts never overwrite each other's filters.
    # The repository folder, not the lane: a worktree and the lane repo of the same solution name must not
    # share a filter file when they build at the same time.
    $checkout = [IO.Path]::GetFullPath((Split-Path -Parent $solutionPath))
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($checkout.ToLowerInvariant()))).Substring(0, 12)
    $directory = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "octo-buildrange/$hash"
    if (!(Test-Path $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $filterPath = Join-Path -Path $directory -ChildPath "$name.slnf"
    @{ solution = @{ path = $solutionPath; projects = @($projects) } } | ConvertTo-Json -Depth 5 | Set-Content -Path $filterPath -Encoding utf8
    return $filterPath
}

function Invoke-OctoBuildRangeRepo {
    # Builds one repository according to its plan entry. No forced restore (-f): the implicit
    # restore of `dotnet build` re-extracts exactly the packages that were purged from the global
    # cache (NuGet's no-op check verifies the expected package folders), everything else stays.
    # -nodeReuse:false keeps long-lived MSBuild nodes from holding the old MsBuildTasks package.
    param(
        [Parameter(Mandatory = $true)] [object]$entry,
        [Parameter(Mandatory = $true)] [string]$configuration,
        [hashtable]$msbuildProperties = @{},
        [switch]$Json
    )

    $logFile = Join-Path -Path $entry.Path -ChildPath 'Invoke-Build.log'
    $propertyArgs = @(ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties)
    if ($propertyArgs.Count -gt 0 -and $entry.Mode -in @('script', 'frontend', 'zenon')) {
        Write-Warning "-msbuildProperties is not applied to $($entry.Name) ($($entry.Mode) build)"
    }
    switch ($entry.Mode) {
        'none' { return [pscustomobject]@{ Success = $true; LogFile = $null } }
        'script' {
            & (Join-Path -Path $entry.Path -ChildPath 'build.ps1') -configuration $configuration
            return [pscustomobject]@{ Success = ($LASTEXITCODE -eq 0); LogFile = $null }
        }
        'frontend' {
            # -laneIsolation Off: the range run already set the lane environment (and the per-repo
            # RestoreSources) for this repository, exactly like Invoke-BuildAll's Compile-Repo.
            Invoke-Publish -repositoryPath $entry.Path -configuration $configuration -laneIsolation Off
            return [pscustomobject]@{ Success = ($Global:LASTEXITCODE -eq 0); LogFile = $null }
        }
        'zenon' {
            Invoke-BuildZenonPlug -repositoryPath $entry.Path -configuration $configuration
            return [pscustomobject]@{ Success = ($Global:LASTEXITCODE -eq 0); LogFile = $null }
        }
    }

    $buildTarget = $entry.Solution
    if ($entry.Target -eq 'slnf') {
        $buildTarget = New-OctoSolutionFilter -solutionPath $entry.Solution -projects $entry.Projects -name $entry.Name
    }
    if (-not $Json) {
        Write-Host "[$configuration] dotnet build $buildTarget $(Hide-OctoUrlCredentials ($propertyArgs -join ' '))" -ForegroundColor Green
    }
    "Invoke-BuildRange: dotnet build $buildTarget -c $configuration -nodeReuse:false $(Hide-OctoUrlCredentials ($propertyArgs -join ' '))" | Set-Content -Path $logFile
    & dotnet build $buildTarget -c $configuration -nodeReuse:false @propertyArgs *>> $logFile
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ Success = ($exitCode -eq 0); LogFile = $logFile; ExitCode = $exitCode }
}

function Invoke-OctoBuildRangeTests {
    # -verifyTests (R2-5): compiles the solution's projects outside src/ (tests, samples) of a
    # repository whose src/ projects were just built - without running any test. A plain range build
    # skips them, so a test project that no longer compiles against the rebuilt packages stays
    # invisible until CI (R2-1). Appends to the repository's Invoke-Build.log.
    param(
        [Parameter(Mandatory = $true)] [object]$entry,
        [Parameter(Mandatory = $true)] [string]$configuration,
        [hashtable]$msbuildProperties = @{},
        [switch]$Json
    )
    if ($entry.Mode -ne 'dotnet' -or @($entry.TestProjects).Count -eq 0) {
        return [pscustomobject]@{ Success = $true; Skipped = $true; LogFile = $null }
    }
    $propertyArgs = @(ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties)
    $logFile = Join-Path -Path $entry.Path -ChildPath 'Invoke-Build.log'
    $filter = New-OctoSolutionFilter -solutionPath $entry.Solution -projects $entry.TestProjects -name "$($entry.Name).tests"
    if (-not $Json) {
        Write-Host "[$configuration] verify tests compile: dotnet build $filter" -ForegroundColor Green
    }
    "Invoke-BuildRange -verifyTests: dotnet build $filter -c $configuration -nodeReuse:false $(Hide-OctoUrlCredentials ($propertyArgs -join ' '))" | Add-Content -Path $logFile
    & dotnet build $filter -c $configuration -nodeReuse:false @propertyArgs *>> $logFile
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ Success = ($exitCode -eq 0); Skipped = $false; LogFile = $logFile; ExitCode = $exitCode }
}

# ---------------------------------------------------------------------------------------------------------------
# Parallel runs (AB#8814): one child pwsh per repository
# ---------------------------------------------------------------------------------------------------------------

function Test-OctoRepoHasCkModel {
    # A ckModel.yaml below <repo>/src: the build of this repository publishes a CK model into the lane's local
    # catalog (and Sync-OctoCkIntermediateVersions writes there for it). bin/obj/node_modules are not entered.
    param([Parameter(Mandatory = $true)] [string]$path)
    $src = Join-Path $path 'src'
    if (-not (Test-Path -LiteralPath $src -PathType Container)) { return $false }
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($src)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            if ([IO.File]::Exists((Join-Path $directory 'ckModel.yaml'))) { return $true }
            foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                if (@('bin', 'obj', 'node_modules', '.git') -contains [IO.Path]::GetFileName($child)) { continue }
                if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($child)
            }
        }
        catch [System.UnauthorizedAccessException] { continue }
        catch [System.IO.IOException] { continue }
    }
    return $false
}

function Write-OctoJobFile {
    # Atomic: written under a temporary name in the same folder, then renamed - a reader never sees half a file.
    param([Parameter(Mandatory = $true)] [string]$path, [Parameter(Mandatory = $true)] [string]$text)
    $temporary = "$path.$PID.tmp"
    [IO.File]::WriteAllText($temporary, $text, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $path, $true)
}

function Invoke-OctoBuildRangeRepoStep {
    <#
    .SYNOPSIS
        The build step of one repository inside its child process (see scripts/Invoke-BuildRangeRepoWorker.ps1):
        sets the request's environment in this process, builds (Invoke-OctoBuildRangeRepo), compiles the test
        projects when asked (Invoke-OctoBuildRangeTests) and writes the result file. Not for interactive use.
    #>
    param([Parameter(Mandatory = $true)] [string]$requestFile)
    $request = Get-Content -LiteralPath $requestFile -Raw | ConvertFrom-Json -AsHashtable
    foreach ($name in @($request['environment'].Keys)) { [Environment]::SetEnvironmentVariable([string]$name, [string]$request['environment'][$name]) }
    if ($request['rootPath']) { $global:rootPath = [string]$request['rootPath'] }
    $entry = [pscustomobject]$request['entry']
    $properties = @{}
    foreach ($key in @($request['msbuildProperties'].Keys)) { $properties[[string]$key] = $request['msbuildProperties'][$key] }
    $result = [ordered]@{ success = $false; logFile = $null; buildSeconds = 0.0; testSeconds = 0.0; tests = $null; error = $null }
    try {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $build = Invoke-OctoBuildRangeRepo -entry $entry -configuration ([string]$request['configuration']) -msbuildProperties $properties -Json
        $watch.Stop()
        $result.success = [bool]$build.Success
        $result.logFile = $build.LogFile
        $result.buildSeconds = $watch.Elapsed.TotalSeconds
        if ($build.Success -and $request['verifyTests']) {
            Write-OctoJobFile -path ([string]$request['phaseFile']) -text 'tests'
            $watch.Restart()
            $tests = Invoke-OctoBuildRangeTests -entry $entry -configuration ([string]$request['configuration']) -msbuildProperties $properties -Json
            $watch.Stop()
            $result.testSeconds = $watch.Elapsed.TotalSeconds
            $result.tests = [ordered]@{ success = [bool]$tests.Success; skipped = [bool]$tests.Skipped; logFile = $tests.LogFile }
        }
    }
    catch { $result.error = $_.Exception.Message }
    Write-OctoJobFile -path ([string]$request['resultFile']) -text (ConvertTo-Json -InputObject $result -Depth 5)
}

function Start-OctoRepoBuildJob {
    <#
    .SYNOPSIS
        Starts the build of one repository in its own child pwsh and returns the job handle
        { Name; Process; ResultFile; PhaseFile; WorkerLog }. The child's environment is $environment on top of
        what this process has; nothing is set in this process.
    #>
    param(
        [Parameter(Mandatory = $true)] [object]$entry,
        [Parameter(Mandatory = $true)] [string]$configuration,
        [hashtable]$msbuildProperties = @{},
        [switch]$verifyTests,
        [System.Collections.IDictionary]$environment = @{},
        [Parameter(Mandatory = $true)] [string]$workDirectory
    )
    $base = Join-Path $workDirectory $entry.Name
    $request = [ordered]@{
        rootPath          = [string](Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
        configuration     = $configuration
        verifyTests       = [bool]$verifyTests
        environment       = $environment
        msbuildProperties = $msbuildProperties
        resultFile        = "$base.result.json"
        phaseFile         = "$base.phase"
        entry             = [ordered]@{ Name = $entry.Name; Path = $entry.Path; Mode = $entry.Mode; Target = $entry.Target; Solution = $entry.Solution; Projects = @($entry.Projects); TestProjects = @($entry.TestProjects) }
    }
    # The request can carry feed settings: it lives in the run's owner-only temporary folder and is deleted with it.
    [IO.File]::WriteAllText("$base.request.json", (ConvertTo-Json -InputObject $request -Depth 6), [Text.UTF8Encoding]::new($false))
    $worker = Join-Path $PSScriptRoot 'scripts/Invoke-BuildRangeRepoWorker.ps1'
    $pwsh = [Environment]::ProcessPath
    if (-not $pwsh -or (Split-Path -Leaf $pwsh) -notmatch '^pwsh') { $pwsh = 'pwsh' }
    $process = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $worker, '-RequestFile', "$base.request.json") `
        -RedirectStandardOutput "$base.worker.log" -RedirectStandardError "$base.worker.err.log" -PassThru -NoNewWindow
    [void]$process.Handle   # keeps the exit state readable after the process is gone
    return [pscustomobject]@{ Name = $entry.Name; Process = $process; ResultFile = "$base.result.json"; PhaseFile = "$base.phase"; WorkerLog = "$base.worker.err.log" }
}

function Get-OctoRepoBuildJobState {
    <#
    .SYNOPSIS
        { Done; Phase (build|tests); Build ({ Success; LogFile }); Tests ($null | { Success; Skipped; LogFile });
        BuildSeconds; TestSeconds } of a job started by Start-OctoRepoBuildJob. A child that ended without a
        result file is a failed build whose log is the child's error output.
    #>
    param([Parameter(Mandatory = $true)] $job)
    $state = [ordered]@{ Done = $false; Phase = 'build'; Build = $null; Tests = $null; BuildSeconds = 0.0; TestSeconds = 0.0 }
    if (Test-Path -LiteralPath $job.PhaseFile) { $state.Phase = 'tests' }
    if (-not $job.Process.HasExited) { return [pscustomobject]$state }
    $state.Done = $true
    if (Test-Path -LiteralPath $job.ResultFile) {
        $result = Get-Content -LiteralPath $job.ResultFile -Raw | ConvertFrom-Json
        $state.Build = [pscustomobject]@{ Success = [bool]$result.success; LogFile = $result.logFile }
        if ($result.error) { Write-Warning "$($job.Name): $($result.error)" }
        if ($null -ne $result.tests) { $state.Tests = [pscustomobject]@{ Success = [bool]$result.tests.success; Skipped = [bool]$result.tests.skipped; LogFile = $result.tests.logFile } }
        $state.BuildSeconds = [double]$result.buildSeconds
        $state.TestSeconds = [double]$result.testSeconds
    }
    else {
        $state.Build = [pscustomobject]@{ Success = $false; LogFile = $job.WorkerLog }
    }
    return [pscustomobject]$state
}

function Stop-OctoRepoBuildJob {
    # Kills the child and everything it started (dotnet, MSBuild nodes). Never throws.
    param([Parameter(Mandatory = $true)] $job)
    try { if ($job.Process -and -not $job.Process.HasExited) { $job.Process.Kill($true) } } catch { }
}

function Format-OctoDuration {
    param([TimeSpan]$duration)
    if ($duration.TotalMinutes -ge 1) {
        return "{0:N0}m {1:N0}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
    }
    return "{0:N1}s" -f $duration.TotalSeconds
}

function Write-OctoBuildRangePlan {
    param(
        [object[]]$plan,
        [string]$branchRootPath,
        [string]$configuration,
        [object[]]$runningProcesses = @(),
        [object[]]$staleCache = @(),
        [switch]$purgeStaleCache,
        [string[]]$propertyArgs = @(),
        $laneSettings = $null,
        [string[]]$packageCaches = @(),
        [switch]$verifyTests,
        # -feedPath (empty = <checkout>/nuget) and -repoPaths of the run.
        [string]$feedPath = '',
        [System.Collections.IDictionary]$repoPaths = $null,
        # Environment the run sets (the lane's; with -feedPath without NUGET_PACKAGES/RestoreSources). $null = the lane's.
        [System.Collections.IDictionary]$environment = $null
    )
    $privateFeed = -not [string]::IsNullOrWhiteSpace($feedPath)
    $purgeEnabled = $configuration -ieq 'DebugL'
    Write-Host "Invoke-BuildRange plan ($configuration) in $branchRootPath" -ForegroundColor Cyan
    if ($privateFeed) {
        Write-Host "  NuGet folder: $feedPath (private feed, -feedPath; Copy-NuGetPackages after each repository, the lane's package caches are NOT purged, the caller's NUGET_PACKAGES / RestoreSources are kept)" -ForegroundColor DarkGray
    }
    else {
        Write-Host "  NuGet folder: $(Join-Path $branchRootPath 'nuget') (not wiped; Copy-NuGetPackages after each repository)" -ForegroundColor DarkGray
    }
    if ($null -ne $repoPaths -and $repoPaths.Count -gt 0) {
        Write-Host "  Repository folders (-repoPaths):" -ForegroundColor DarkGray
        foreach ($name in $repoPaths.Keys) { Write-Host "    $name -> $($repoPaths[$name])" -ForegroundColor DarkGray }
    }
    if ($null -ne $laneSettings) {
        if ($null -eq $environment) { $environment = $laneSettings.environment }
        Write-Host "  Lane isolated: $($laneSettings.isolated) ($($laneSettings.reason))" -ForegroundColor DarkGray
        foreach ($name in $environment.Keys) { Write-Host "    env $name=$($environment[$name])" -ForegroundColor DarkGray }
    }
    if ($packageCaches.Count -gt 0 -and -not $privateFeed) {
        Write-Host "  Package cache(s) purged per package / checked for stale 999.0.0 folders: $($packageCaches -join ', ')" -ForegroundColor DarkGray
    }
    if ($propertyArgs.Count -gt 0) {
        Write-Host "  MSBuild properties (all repositories): $(Hide-OctoUrlCredentials ($propertyArgs -join ' '))" -ForegroundColor DarkGray
    }
    if ($staleCache.Count -gt 0) {
        $action = if ($purgeStaleCache) { 'will be purged before the first build (-purgeStaleCache)' } else { 'restores would use them silently - pass -purgeStaleCache to purge them' }
        Write-Host "  Global-cache 999.0.0 folders that differ from $(Join-Path $branchRootPath 'nuget') ($action):" -ForegroundColor Yellow
        foreach ($item in $staleCache) { Write-Host "    - $($item.CachePath) ($($item.Reason))" -ForegroundColor Yellow }
    }
    $index = 0
    foreach ($entry in $plan) {
        $index++
        Write-Host ""
        $decision = $entry.PSObject.Properties['Decision']
        if ($decision -and $decision.Value.Action -eq 'skip' -and $entry.Mode -ne 'none') {
            Write-Host ("{0,2}. {1} [{2}] -> not built: {3}{4}" -f $index, $entry.Name, $entry.Group, $decision.Value.Reason, $(if ($decision.Value.Detail) { " ($($decision.Value.Detail))" })) -ForegroundColor DarkGray
            continue
        }
        Write-Host ("{0,2}. {1} [{2}] -> {3}" -f $index, $entry.Name, $entry.Group, $entry.Target) -ForegroundColor Green
        if ($decision -and $decision.Value.Reason -ne 'always') { Write-Host "    build because: $($decision.Value.Reason)$(if ($decision.Value.Detail) { " ($($decision.Value.Detail))" })" }
        if ($null -ne $repoPaths -and $repoPaths.Contains($entry.Name)) { Write-Host "    path: $($entry.Path) (-repoPaths)" }
        if ($entry.Mode -eq 'dotnet') {
            Write-Host "    solution: $(Split-Path -Leaf $entry.Solution) ($($entry.Projects.Count) project(s))"
            foreach ($project in $entry.Projects) { Write-Host "      - $project" }
        }
        if (@($entry.PropertyArgs).Count -gt 0) { Write-Host "    msbuild: $($entry.PropertyArgs -join ' ')" }
        if ($entry.RestoreSources) { Write-Host "    env RestoreSources=$($entry.RestoreSources)" }
        if ($verifyTests -and @($entry.TestProjects).Count -gt 0) {
            Write-Host "    then: verify $(@($entry.TestProjects).Count) test/sample project(s) compile (-verifyTests, not run)"
        }
        foreach ($note in $entry.Notes) { Write-Host "    note: $note" -ForegroundColor Yellow }
        if ($entry.Mode -ne 'none') {
            if ($purgeEnabled -and $privateFeed) {
                Write-Host "    then: Copy-NuGetPackages into $feedPath (no package-cache purge)"
            }
            elseif ($purgeEnabled) {
                Write-Host "    then: Copy-NuGetPackages + purge of the packages this build rewrites; candidates from the previous build output ($($entry.PurgePaths.Count)):"
                foreach ($path in $entry.PurgePaths) {
                    if ($entry.OlderPaths -contains $path) {
                        Write-Host "      - $path  (older than the last build - stale or unchanged, purged only if rewritten)" -ForegroundColor DarkGray
                    }
                    else { Write-Host "      - $path" }
                }
            }
            else {
                Write-Host "    then: no package copy / purge (configuration is not DebugL)"
            }
        }
    }
    if ($runningProcesses.Count -gt 0) {
        Write-Host ""
        Write-Host "Running processes out of repositories in the range (a real run refuses unless -stopServices / -ignoreRunningServices):" -ForegroundColor Yellow
        foreach ($process in $runningProcesses) {
            $command = if ($process.Command.Length -gt 160) { $process.Command.Substring(0, 157) + '...' } else { $process.Command }
            Write-Host ("  - {0}: pid {1} {2}" -f $process.Repo, $process.Pid, $command) -ForegroundColor Yellow
        }
    }
}

<#
.SYNOPSIS
    Rebuilds only the repositories between -from and -to of the OctoMesh build order (fast local loop).

.DESCRIPTION
    Takes the slice [-from .. -to] of the build order used by Invoke-BuildAll (see
    Get-OctoBuildOrder), optionally extended by -include and reduced by -exclude, and for each
    repository in order:

      1. builds it with `dotnet build -c <configuration> -nodeReuse:false`
         - only the solution's src/ projects (via a temporary .slnf), unless -includeTests;
           with -verifyTests the projects outside src/ (tests, samples) are compiled right after,
           without running them;
         - no forced restore (`-f`): the implicit restore only re-extracts what was purged;
         - repositories with build.ps1, frontends and the zenon plug are built the same way
           Invoke-BuildAll builds them;
      2. (DebugL only) Copy-NuGetPackages -onlyChanged into <checkout>/nuget: every package of
         the repository that nuget/ lacks or holds in an older, different version - also one
         written by an earlier interrupted run or an IDE build (pack is incremental). Orphaned
         nupkgs of removed projects and packages older than the nuget/ copy are left alone;
      3. (DebugL only) purges <cache>/<id>/999.0.0 for exactly the copied packages, so the next
         repository in the range restores the fresh ones from <checkout>/nuget.

    Lane isolation (AB#4924) is the same as Invoke-BuildAll's (Get-OctoLaneBuildSettings): an
    isolated lane (its Octo.User.props declares RestorePackagesPath: every feature environment)
    builds with NUGET_PACKAGES=<lane>/.nuget-packages and MSBUILDDISABLENODEREUSE=1, and in DebugL
    repositories without their own <RestoreSources> get RestoreSources=<lane>/nuget;nuget.org.
    The environment is restored afterwards. The package cache that is purged and checked follows
    the lane (Get-OctoRangePackageCaches): <lane>/.nuget-packages for an isolated lane; for the
    legacy lane (no RestorePackagesPath, or -laneIsolation Off) the global cache (NUGET_PACKAGES or
    ~/.nuget/packages), plus <lane>/.nuget-packages if <lane>/Octo.User.props sets RestorePackagesPath.

    Unlike Invoke-BuildAll it does NOT wipe <checkout>/nuget, does NOT delete every
    meshmakers.* package from the package cache and does NOT kill dotnet processes.

    Test projects are NOT compiled by default. Before handing a change to others, run with
    -includeTests (whole solutions) or -verifyTests (src/ first, then the test projects compile,
    nothing is run); a plain run prints a reminder at the end (R2-5).

    Stops at the first failing repository (fail fast) and prints the repository name and the
    tail of its log. Per-repository timings are printed at the end (or emitted with -Json).

    Refuses to start while processes run out of a repository in the range (e.g. services started
    by Start-Octo - their bin/DebugL output would be overwritten). Use -stopServices to send
    Stop-Octo first, or -ignoreRunningServices to build anyway.
    Known gap on Windows: Win32_Process exposes no working directory, and Start-Octo starts the
    services as `dotnet <Name>.dll` with a relative path, so they are not detected there; the build
    then fails on locked files instead of refusing. Stop the services (Stop-Octo) first on Windows.

    Repositories outside the range are not rebuilt. If they consume a package that was rebuilt,
    they pick it up on their next build (the global-cache copy was purged).

.PARAMETER from
    First repository of the range. Exact directory name, the name without "octo-", or a unique
    substring (e.g. octo-construction-kit-engine, construction-kit-engine, asset-repo).

.PARAMETER to
    Last repository of the range (inclusive). Defaults to -from (single repository).

.PARAMETER branch
    Checkout to build (e.g. main), resolved like Invoke-BuildAll.

.PARAMETER configuration
    Build configuration. Defaults to DebugL. Package copy and global-cache purge only run for DebugL.

.PARAMETER include
    Additional repositories to build (placed at their position in the build order), e.g.
    -from octo-construction-kit-engine -to octo-common-services -include octo-asset-repo-services,octo-identity-services.

.PARAMETER exclude
    Repositories inside the range to skip.

.PARAMETER includeTests
    Build the whole solution (src + tests + samples) instead of src/ projects only.

.PARAMETER verifyTests
    After each repository's src/ build, compile its projects outside src/ (tests, samples) with a
    second temporary .slnf - without running any test. Fails fast like a build failure. Ignored
    with -includeTests (the whole solution is built anyway). Timing column "tests".

.PARAMETER laneIsolation
    Auto (default) / On / Off - see Get-OctoLaneBuildSettings.

.PARAMETER excludeFrontend
    Drop octo-frontend-* repositories from the build order. Defaults to $true (frontends do not
    produce NuGet packages and take minutes); pass $false to include them.

.PARAMETER stopServices
    If processes run out of a repository in the range, call Stop-Octo -branch <branch> and wait
    (up to 120 s) for them to exit before building.

.PARAMETER ignoreRunningServices
    Build even though processes run out of a repository in the range.

.PARAMETER msbuildProperties
    Extra MSBuild global properties passed as -p:Name=Value to the dotnet build of EVERY
    repository in the run. Global properties override values set in project files. Not applied
    to build.ps1 / frontend / zenon builds (a warning is printed).
    Do not use it for OctoPublishCkModel: it would stop every CK model of the run from being
    published into the local catalog, so downstream CK compiles see stale models. Use
    -msbuildPropertiesPerRepo for the one repository instead. A warning is printed when
    OctoPublishCkModel=false applies to more than one repository.

.PARAMETER msbuildPropertiesPerRepo
    Extra MSBuild properties for single repositories, keyed by repository name (same name forms
    as -from/-to); they override -msbuildProperties for that repository, e.g.
    @{ 'octo-identity-services' = @{ OctoPublishCkModel = 'false' } } so only identity's CK model
    is kept out of the shared local catalog.

.PARAMETER purgeStaleCache
    Before the first build, purge the <cache>/<id>/999.0.0 folders whose recorded SHA-512
    differs from <checkout>/nuget/<id>.999.0.0.nupkg (e.g. extracted from another lane's build).
    Without the switch they are only reported (warning, -WhatIf, -Json).

.PARAMETER repoPaths
    Build single repositories from another folder instead of <checkout>/<repo>, keyed by repository
    name (same name forms as -from/-to), e.g. a git worktree:
    @{ 'octo-construction-kit-engine' = '/Users/me/meshmakers/branches/main/wt-8625-octo-construction-kit-engine' }.
    The repository keeps its position in the build order. The folder must be an absolute path, exist,
    contain a .sln/.slnx in its root or a src/ folder, and be that repository: a git worktree whose
    .git file points to <repo>/.git/worktrees/<name>, or a clone whose .git folder sits in a folder
    named like the repository; otherwise the run is refused. A folder that is not next to the lane's
    repositories gets a warning (repositories with their own <RestoreSources> use ../nuget).
    A key for a repository outside the selected range is not applied (warning).

.PARAMETER externalRepoPaths
    Repositories that are NOT folders of the lane, keyed by their exact repository name, with the folder
    to build them from (e.g. an in-place worktree adopted by a feature environment). They are placed in
    the build order like a lane folder of that name (Get-OctoBuildOrder -additionalRepos), validated like
    -repoPaths, and built from that folder. The caller provides their isolation through
    -msbuildPropertiesPerRepo (RestoreSources, RestorePackagesPath): the folder's ../nuget is not the
    lane feed, so no "not next to the lane" warning is printed for them.

.PARAMETER feedPath
    Private feed: copy the built DebugL packages into this folder (created when missing) instead of
    <checkout>/nuget, and do NOT purge the lane's package caches. The caller provides the isolation
    (NUGET_PACKAGES, RestoreSources): with -feedPath the run neither sets the lane's NUGET_PACKAGES nor
    the per-repository RestoreSources override, the stale-cache check of <checkout>/nuget is skipped
    and -purgeStaleCache is refused. DebugL only. Reported as `feedPath` in the -Json document. A
    relative path resolves against $PWD. With more than one dotnet repository in the range the run is
    refused unless -msbuildProperties contains both RestoreSources and RestorePackagesPath (see below).
    Note: repositories that declare their own <RestoreSources>, and a lane whose Octo.User.props sets
    RestorePackagesPath, ignore the environment - pass -msbuildProperties @{ RestoreSources = ..;
    RestorePackagesPath = .. } (global properties win) when the downstream repositories of the range
    must restore from the private feed into the private cache.

.PARAMETER skipUnchanged
    AB#8814: do not build a repository whose sources and consumed feed packages are the same as at its last
    successful build in this lane (build stamps, <lane>/.octo/build-stamps/<repo>.json, see OctoBuildStamp.psm1).
    The check runs when the repository's turn comes, so packages rebuilt earlier in the same run count. DebugL
    only. Implies -recordStamps. A skipped repository is reported with status "skipped", reason "unchanged".

.PARAMETER recordStamps
    Write the build stamp of every repository that was built successfully (DebugL), without skipping anything.

.PARAMETER repoInputs
    Per repository (exact name) what the caller knows about its dependencies:
    @{ '<repo>' = @{ packages = @('<package id>', ..); dependsOn = @('<repo>', ..) } }. packages: the feed
    packages the repository consumes (hashed into its stamp); without it every package of the feed except the
    repository's own counts. dependsOn: repositories of the range it depends on - only used for the -WhatIf
    prediction ("upstreamBuilt"); without it every repository built earlier in the range counts.
    Invoke-BuildEnvironment passes both from the package graph.

.PARAMETER skipRepos
    Repositories of the range that are not built in this run, keyed by exact name, with the reason:
    @{ '<repo>' = @{ reason = 'notSelected'; detail = '..' } } (or a plain string as the reason). They stay in the
    plan and are reported as skipped (status "skipped", event repoSkipped); nothing of them is checked, built,
    copied or purged and their stamp is left alone. Used by Invoke-BuildEnvironment -repos / -skip.

.PARAMETER maxParallel
    AB#8814: how many repositories build at the same time. 1 (default) is the sequential run. With more, a
    repository starts as soon as every repository of the range it depends on is finished - built, tested, its
    packages copied into the feed and purged from the package cache - and a slot is free:
      - dependencies: -repoInputs.<repo>.dependsOn (Invoke-BuildEnvironment passes the transitive package graph);
        a repository without that entry depends on every repository before it in the range, so a plain
        Invoke-BuildRange -maxParallel 2 without -repoInputs still builds one after the other;
      - each repository builds in its own child pwsh (scripts/Invoke-BuildRangeRepoWorker.ps1) that sets its own
        environment (NUGET_PACKAGES, MSBUILDDISABLENODEREUSE, the repository's RestoreSources and
        UseSharedCompilation=false), so nothing bleeds between two builds; log: <repo>/Invoke-Build.log as always;
      - this process alone copies packages (temporary name + rename, a restore never sees half a nupkg), purges
        the package cache, writes build stamps and the events file - one after the other;
      - repositories with a CK model (a ckModel.yaml below src/) never build at the same time and keep their
        build order: the CK publish into <lane>/.octo/local-catalog and the intermediate-version sync stay serial;
      - build.ps1, frontend and zenon repositories build alone (their dependencies are not in the package graph);
      - after a failure nothing new starts; repositories that are running finish (packages, stamp, repoDone), the
        rest is reported as not built. failedRepo is the first failure, failedRepos lists all.
    Events: index is the start order (1..count) and repoDone repeats the index of its repoStart; plan and the
    -Json document carry parallel / maxParallel, plan.repos[] and -WhatIf repositories[] carry dependsOn.

.PARAMETER EventsFile
    Append build progress events to this file while the run is going (one JSON object per line,
    see Write-OctoBuildEvent): plan, then per repository repoStart, phase (build, tests, packages,
    purge) and repoDone - or a single repoSkipped for a repository that is not built - and finally done,
    also on an early refusal or a throw (success=false).
    Nothing is written under -WhatIf. The -Json output is not affected.

.PARAMETER EventsCommand
    The command name recorded in every event of -EventsFile. Default Invoke-BuildRange; wrappers such as
    Invoke-BuildEnvironment pass their own name so a reader sees which cmdlet ran the build.

.PARAMETER WhatIf
    Print the plan (repositories, projects, global-cache folders to purge, running processes,
    -repoPaths and -feedPath) and do nothing.

.PARAMETER Json
    Emit a single JSON document (plan under -WhatIf, per-repository results otherwise).

.EXAMPLE
    Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-asset-repo-services -WhatIf

.EXAMPLE
    Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services -include octo-asset-repo-services,octo-identity-services,octo-cli

.EXAMPLE
    Invoke-BuildRange -branch main -from octo-asset-repo-services -includeTests

.EXAMPLE
    Invoke-BuildRange -branch dev -from octo-construction-kit-engine -to octo-common-services -include octo-asset-repo-services -verifyTests

.EXAMPLE
    Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services -include octo-identity-services -msbuildPropertiesPerRepo @{ 'octo-identity-services' = @{ OctoPublishCkModel = 'false' } } -purgeStaleCache
#>
function Invoke-BuildRange {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$from,
        [string]$to = "",
        [string]$branch = "",
        [string]$configuration = "DebugL",
        [string[]]$include = @(),
        [string[]]$exclude = @(),
        [switch]$includeTests,
        [Boolean]$excludeFrontend = $true,
        [switch]$stopServices,
        [switch]$ignoreRunningServices,
        [hashtable]$msbuildProperties = @{},
        [hashtable]$msbuildPropertiesPerRepo = @{},
        [switch]$purgeStaleCache,
        [switch]$verifyTests,
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        # AB#7974: skip the sync of private-only intermediate CK versions into <lane>/.octo/local-catalog.
        [switch]$skipCkSync,
        [hashtable]$repoPaths = @{},
        [hashtable]$externalRepoPaths = @{},
        [string]$feedPath = '',
        [switch]$skipUnchanged,
        [switch]$recordStamps,
        [hashtable]$repoInputs = @{},
        [hashtable]$skipRepos = @{},
        [ValidateRange(1, 16)] [int]$maxParallel = 1,
        [string]$EventsFile = '',
        [string]$EventsCommand = 'Invoke-BuildRange',
        [switch]$Json
    )

    # The run itself lives in Invoke-OctoBuildRangeCore; this wrapper guarantees the closing `done`
    # event of -EventsFile, also when the run refuses early or throws.
    # The core is a simple function: -WhatIf / -ErrorAction reach it as the preference variables of this
    # scope, and its Write-Error lands in this cmdlet's error stream (-ErrorVariable) like before.
    $skip = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters) + @('EventsFile', 'EventsCommand')
    $forward = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -in $skip) { continue }
        $forward[$key] = $PSBoundParameters[$key]
    }
    $events = New-OctoBuildEventState -Path $EventsFile -Command $EventsCommand
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-OctoBuildRangeCore @forward -events $events
    }
    finally {
        # Also after a throw: repoDone(success=false) of the running repository, then done. Best-effort on Ctrl+C.
        $watch.Stop()
        if (-not $WhatIfPreference) { Complete-OctoBuildEvents -State $events -ElapsedSeconds $watch.Elapsed.TotalSeconds }
    }
}

function Resolve-OctoRepoPathOverrides {
    # -repoPaths: resolves the keys against the build order and validates the folders. Returns a
    # map repository name -> absolute folder; throws on an invalid entry.
    param(
        [hashtable]$repoPaths = @{},
        [Parameter(Mandatory = $true)] [object[]]$order,
        # Lane checkout; a folder that is not next to the lane's repositories gets a warning.
        [string]$branchRootPath = "",
        # Repositories whose folder is outside the lane on purpose (-externalRepoPaths): no warning.
        [string[]]$noLaneWarning = @()
    )
    $map = [ordered]@{}
    foreach ($key in @($repoPaths.Keys)) {
        $name = (Resolve-OctoBuildRangeRepo -name ([string]$key) -order $order).Name
        $folder = [string]$repoPaths[$key]
        if ([string]::IsNullOrWhiteSpace($folder) -or -not [IO.Path]::IsPathRooted($folder)) {
            throw "-repoPaths: the folder for $name must be an absolute path (got '$folder')."
        }
        $folder = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($folder))
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            throw "-repoPaths: folder $folder for $name does not exist."
        }
        $hasSolution = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.sln', '.slnx' }).Count -gt 0
        $hasSrc = Test-Path -LiteralPath (Join-Path $folder 'src') -PathType Container
        if (-not $hasSolution -and -not $hasSrc) {
            throw "-repoPaths: folder $folder for $name contains no repository (no .sln/.slnx in its root and no src/ folder)."
        }
        # It must be THIS repository: a git worktree (.git file) of <repo>, or a clone (.git folder) named <repo>.
        $gitPath = Join-Path $folder '.git'
        if (Test-Path -LiteralPath $gitPath -PathType Leaf) {
            $gitText = [string](Get-Content -LiteralPath $gitPath -Raw -ErrorAction SilentlyContinue)
            $gitDir = $null
            if ($gitText -match '(?m)^[ \t]*gitdir:[ \t]*(\S[^\r\n]*?)[ \t]*\r?$') { $gitDir = $Matches[1] }
            if (-not $gitDir) {
                throw "-repoPaths: $gitPath of $name has no gitdir line."
            }
            if (-not [IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $folder $gitDir }
            # <repo>/.git/worktrees/<name> -> <repo>
            $gitDir = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($gitDir))
            $mainRepo = Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $gitDir)))
            if ($mainRepo -ine $name) {
                throw "-repoPaths: $folder is a worktree of '$mainRepo' (gitdir $gitDir), not of $name."
            }
        }
        elseif (Test-Path -LiteralPath $gitPath -PathType Container) {
            if ((Split-Path -Leaf $folder) -ine $name) {
                throw "-repoPaths: $folder is a clone named '$(Split-Path -Leaf $folder)', not $name."
            }
        }
        else {
            throw "-repoPaths: $folder for $name is no git repository or worktree (no .git) - cannot verify that it holds $name."
        }
        # Repos whose own <RestoreSources> use ../nuget resolve the feed next to the folder.
        if (-not [string]::IsNullOrWhiteSpace($branchRootPath) -and $noLaneWarning -notcontains $name) {
            $parent = [IO.Path]::TrimEndingDirectorySeparator((Split-Path -Parent $folder))
            $lane = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($branchRootPath))
            if ($parent -ine $lane) {
                Write-Warning "-repoPaths: $folder is not next to the lane's repositories ($lane) - a repository whose own <RestoreSources> uses ../nuget restores from $(Join-Path $parent 'nuget') instead of the lane feed."
            }
        }
        $map[$name] = $folder
    }
    return $map
}

function Invoke-OctoBuildRangeCore {
    # The body of Invoke-BuildRange (see its help). $events is the -EventsFile state shared with the
    # wrapper: Path (empty = no events), Repo/Phase (what runs now), Success/FailedRepo/FailedStep/Completed.
    # Deliberately a simple function (no [CmdletBinding()] / [Parameter()]), see Invoke-BuildRange.
    param(
        [string]$from,
        [string]$to = "",
        [string]$branch = "",
        [string]$configuration = "DebugL",
        [string[]]$include = @(),
        [string[]]$exclude = @(),
        [switch]$includeTests,
        [Boolean]$excludeFrontend = $true,
        [switch]$stopServices,
        [switch]$ignoreRunningServices,
        [hashtable]$msbuildProperties = @{},
        [hashtable]$msbuildPropertiesPerRepo = @{},
        [switch]$purgeStaleCache,
        [switch]$verifyTests,
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        [switch]$skipCkSync,
        [hashtable]$repoPaths = @{},
        [hashtable]$externalRepoPaths = @{},
        [string]$feedPath = '',
        [switch]$skipUnchanged,
        [switch]$recordStamps,
        [hashtable]$repoInputs = @{},
        [hashtable]$skipRepos = @{},
        [int]$maxParallel = 1,
        [hashtable]$events,
        [switch]$Json
    )

    $eventsPath = [string]$events.Path
    $emit = {
        param([string]$name, [System.Collections.IDictionary]$data)
        Write-OctoBuildEvent -Path $eventsPath -Command ([string]$events.Command) -Event $name -Data $data
    }

    # Every early exit reports through the same path: Write-Error, LASTEXITCODE 1 and, with -Json,
    # a JSON document with success=false.
    $fail = {
        param([string]$message)
        $events.Success = $false
        $events.FailedStep = 'preflight'
        $events.Completed = $true
        $global:LASTEXITCODE = 1
        if ($Json) {
            Write-OctoJson -Command 'Invoke-BuildRange' -Data ([ordered]@{ success = $false; error = $message; repositories = @() })
        }
        Write-Error $message
    }

    if (!(Test-Path $rootPath)) {
        & $fail "Root path $rootPath does not exist"
        return
    }

    try { $propertyArgs = @(ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties) }
    catch { & $fail $_.Exception.Message; return }

    $resolved = Resolve-OctoBranchRootPath -branch $branch
    $branch = $resolved.Branch
    $branchRootPath = $resolved.BranchRootPath
    if (!(Test-Path $branchRootPath)) {
        & $fail "Checkout $branchRootPath does not exist"
        return
    }

    try { $order = @(Get-OctoBuildOrder -branchRootPath $branchRootPath -excludeFrontend $excludeFrontend -excludeAdditional $false -additionalRepos $externalRepoPaths) }
    catch { & $fail $_.Exception.Message; return }
    foreach ($name in @($externalRepoPaths.Keys)) {
        if (Test-Path -LiteralPath (Join-Path $branchRootPath $name) -PathType Container) {
            & $fail "-externalRepoPaths: $name is a folder of the lane $branchRootPath - use -repoPaths."
            return
        }
    }
    try {
        $repos = @(Get-OctoBuildRangeRepos -order $order -from $from -to $to -include $include -exclude $exclude)
    }
    catch {
        & $fail $_.Exception.Message
        return
    }
    if ($repos.Count -eq 0) {
        & $fail "No repositories selected."
        return
    }

    # -repoPaths: build single repositories from another folder (e.g. a git worktree), same position.
    $allRepoPaths = @{}
    foreach ($key in @($repoPaths.Keys)) { $allRepoPaths[$key] = $repoPaths[$key] }
    foreach ($key in @($externalRepoPaths.Keys)) { $allRepoPaths[$key] = $externalRepoPaths[$key] }
    try { $repoPathMap = Resolve-OctoRepoPathOverrides -repoPaths $allRepoPaths -order $order -branchRootPath $branchRootPath -noLaneWarning @($externalRepoPaths.Keys) }
    catch { & $fail $_.Exception.Message; return }
    $repoPathsOutside = @($repoPathMap.Keys | Where-Object { $name = $_; -not ($repos | Where-Object { $_.Name -ieq $name }) } | Sort-Object)
    if ($repoPathsOutside.Count -gt 0) {
        Write-Warning "-repoPaths: $($repoPathsOutside -join ', ') not in the selected range - their folders are not built. Add them with -include if they should be built."
    }
    $repos = @($repos | ForEach-Object {
            if ($repoPathMap.Contains($_.Name)) {
                [pscustomobject]@{ Name = $_.Name; Path = $repoPathMap[$_.Name]; Group = $_.Group; Directory = (Get-Item -LiteralPath $repoPathMap[$_.Name]) }
            }
            else { $_ }
        })

    # -feedPath: private feed instead of <checkout>/nuget, no purge of the lane's package caches.
    $privateFeed = -not [string]::IsNullOrWhiteSpace($feedPath)
    $nugetTarget = Join-Path $branchRootPath 'nuget'
    if ($privateFeed) {
        if ($configuration -ine 'DebugL') {
            & $fail "-feedPath needs -configuration DebugL (packages are only copied for DebugL)."
            return
        }
        if ($purgeStaleCache) {
            & $fail "-feedPath and -purgeStaleCache cannot be combined: a private-feed run never purges the lane's package caches."
            return
        }
        # Relative to $PWD (GetFullPath would resolve against the process start directory).
        $nugetTarget = [IO.Path]::TrimEndingDirectorySeparator($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($feedPath))
    }
    $repoPathsReport = [ordered]@{}
    foreach ($name in $repoPathMap.Keys) { $repoPathsReport[$name] = $repoPathMap[$name] }

    $laneSettings = Get-OctoLaneBuildSettings -laneRootPath $branchRootPath -laneIsolation $laneIsolation
    $globalPackagesPath = @(Get-OctoRangePackageCaches -laneSettings $laneSettings)
    # The environment of the run: the lane's, but with -feedPath the caller's NUGET_PACKAGES /
    # RestoreSources stay in force (only node reuse is still switched off).
    $runEnvironment = [ordered]@{}
    foreach ($name in @($laneSettings.environment.Keys)) {
        if ($privateFeed -and $name -in @('NUGET_PACKAGES', 'RestoreSources')) { continue }
        $runEnvironment[$name] = $laneSettings.environment[$name]
    }
    $plan = @(Get-OctoBuildRangePlan -repos $repos -includeTests:$includeTests -globalPackagesPath $globalPackagesPath)
    $verify = [bool]$verifyTests -and -not $includeTests

    # -feedPath with more than one dotnet repository: the downstream repositories must restore the
    # private packages from the feed into a private cache. The environment is not enough (repos with their
    # own <RestoreSources>, a lane RestorePackagesPath in Octo.User.props win over it) - only global
    # MSBuild properties are; without them they build against old lane packages or extract the private
    # 999.0.0 packages into the lane cache.
    if ($privateFeed) {
        $dotnetRepos = @($plan | Where-Object { $_.Mode -eq 'dotnet' })
        if ($dotnetRepos.Count -gt 1) {
            # Effective properties per repository: the run-wide ones, overridden by -msbuildPropertiesPerRepo.
            $missing = @(foreach ($repo in $dotnetRepos) {
                    # Keys accept the same name forms as -from/-to (e.g. without the octo- prefix): resolve them first.
                    $perRepo = @{}
                    foreach ($repoKey in @($msbuildPropertiesPerRepo.Keys)) {
                        $resolved = try { (Resolve-OctoBuildRangeRepo -name ([string]$repoKey) -order $order).Name } catch { [string]$repoKey }
                        if ($resolved -eq $repo.Name) { $perRepo = $msbuildPropertiesPerRepo[$repoKey] }
                    }
                    foreach ($key in @('RestoreSources', 'RestorePackagesPath')) {
                        if (-not $msbuildProperties.ContainsKey($key) -and -not $perRepo.ContainsKey($key)) { "$($repo.Name): $key" }
                    }
                })
            if ($missing.Count -gt 0) {
                & $fail "-feedPath with $($dotnetRepos.Count) dotnet repositories ($(($dotnetRepos.Name) -join ', ')) needs RestoreSources (the private feed first) and RestorePackagesPath (a private package cache) for every one of them, via -msbuildProperties or -msbuildPropertiesPerRepo; missing: $($missing -join ', ')."
                return
            }
        }
    }
    foreach ($entry in $plan) {
        # Per-repo RestoreSources of an isolated lane (DebugL, repos without their own <RestoreSources>).
        $restoreSources = $null
        if ($configuration -ieq 'DebugL' -and $entry.Mode -ne 'none' -and -not $privateFeed) {
            $restoreSources = Get-OctoRepoRestoreSourcesOverride -repositoryPath $entry.Path -laneSettings $laneSettings
        }
        $entry | Add-Member -NotePropertyName RestoreSources -NotePropertyValue $restoreSources -Force
    }

    # Per-repository MSBuild properties: keys accept the same name forms as -from/-to.
    $perRepo = @{}
    try {
        foreach ($repoKey in @($msbuildPropertiesPerRepo.Keys)) {
            $perRepo[(Resolve-OctoBuildRangeRepo -name ([string]$repoKey) -order $order).Name] = $msbuildPropertiesPerRepo[$repoKey]
        }
        Assert-OctoMsBuildPropertiesPerRepo -msbuildPropertiesPerRepo $perRepo -knownRepos @($order.Name)
    }
    catch { & $fail $_.Exception.Message; return }
    # T-L3: a key for a repository outside the selected range does nothing - say so (forgotten -include?).
    $outsideRange = @($perRepo.Keys | Where-Object { $name = $_; -not ($plan | Where-Object { $_.Name -ieq $name }) } | Sort-Object)
    if ($outsideRange.Count -gt 0) {
        Write-Warning "-msbuildPropertiesPerRepo: $($outsideRange -join ', ') not in the selected range - their properties are not applied. Add them with -include if they should be built."
    }
    foreach ($entry in $plan) {
        $properties = Merge-OctoRepoMsBuildProperties -repoName $entry.Name -msbuildProperties $msbuildProperties -msbuildPropertiesPerRepo $perRepo
        $entry | Add-Member -NotePropertyName MsBuildProperties -NotePropertyValue $properties -Force
        # Display only (plan, -Json): credentials in feed URLs are masked; the build converts MsBuildProperties itself.
        $entry | Add-Member -NotePropertyName PropertyArgs -NotePropertyValue @(ConvertTo-OctoMsBuildPropertyArgs -properties $properties | ForEach-Object { Hide-OctoUrlCredentials $_ }) -Force
    }
    $publishWarning = Get-OctoCkPublishDisabledWarning -repoNames @($plan | Where-Object { $_.Mode -eq 'dotnet' -and (Test-OctoCkPublishDisabled -properties $_.MsBuildProperties) } | ForEach-Object { $_.Name })
    if ($publishWarning) { Write-Warning $publishWarning }
    $purgeEnabled = $configuration -ieq 'DebugL'

    # AB#8814: build stamps. -skipRepos: repositories the caller took out of this run. -skipUnchanged: repositories
    # whose inputs are those of their last successful build.
    $skipMap = @{}
    foreach ($key in @($skipRepos.Keys)) {
        $value = $skipRepos[$key]
        $known = @($plan | Where-Object { $_.Name -ieq [string]$key })
        if ($known.Count -eq 0) { & $fail "-skipRepos: '$key' is not a repository of the selected range."; return }
        $skipMap[$known[0].Name] = if ($value -is [System.Collections.IDictionary]) { [pscustomobject]@{ Reason = [string]$value['reason']; Detail = [string]$value['detail'] } } else { [pscustomobject]@{ Reason = [string]$value; Detail = '' } }
    }
    foreach ($key in @($repoInputs.Keys)) {
        if ($repoInputs[$key] -isnot [System.Collections.IDictionary]) { & $fail "-repoInputs: the value for '$key' must be a hashtable @{ packages = ..; dependsOn = .. }."; return }
    }
    $stampsEnabled = $purgeEnabled -and ($skipUnchanged -or $recordStamps)
    $skipUnchangedEnabled = $purgeEnabled -and $skipUnchanged
    $stampRoot = Join-Path $branchRootPath '.octo/build-stamps'
    $stampTests = if ($includeTests -or $verify) { 'compiled' } else { 'none' }
    $inputsOf = {
        param($entry)
        $known = $null
        foreach ($key in @($repoInputs.Keys)) { if ([string]$key -ieq $entry.Name -and $repoInputs[$key].Contains('packages')) { $known = [string[]]@($repoInputs[$key]['packages']) } }
        Get-OctoRepoBuildInputs -path $entry.Path -feedPath $nugetTarget -packageIds $known -ownPackageIds @($entry.PackageIds)
    }
    # { Action build|skip; Reason; Detail; Inputs } for one repository, as things are now.
    $decide = {
        param($entry)
        if ($skipMap.ContainsKey($entry.Name)) { return [pscustomobject]@{ Action = 'skip'; Reason = $skipMap[$entry.Name].Reason; Detail = $skipMap[$entry.Name].Detail; Inputs = $null } }
        if ($entry.Mode -eq 'none') { return [pscustomobject]@{ Action = 'skip'; Reason = 'nothingToBuild'; Detail = 'no solution file'; Inputs = $null } }
        if (-not $stampsEnabled) { return [pscustomobject]@{ Action = 'build'; Reason = 'always'; Detail = 'unchanged repositories are not skipped in this run'; Inputs = $null } }
        $inputs = & $inputsOf $entry
        if (-not $skipUnchangedEnabled) { return [pscustomobject]@{ Action = 'build'; Reason = 'always'; Detail = 'unchanged repositories are not skipped in this run'; Inputs = $inputs } }
        $compare = Compare-OctoBuildStamp -stamp (Read-OctoBuildStamp -stampRoot $stampRoot -repo $entry.Name) -inputs $inputs -configuration $configuration -tests $stampTests -outputPath $(if ($entry.Mode -eq 'dotnet') { $entry.Path } else { '' })
        # AB#8819: a consumer app builds against the sibling octo-frontend-libraries (its build.ps1 installs their dist),
        # an input neither its own sources nor the feed show. Built before the libraries' last build = stale.
        if ($compare.Unchanged -and $entry.Group -eq 'app') {
            $own = Read-OctoBuildStamp -stampRoot $stampRoot -repo $entry.Name
            $libraries = Read-OctoBuildStamp -stampRoot $stampRoot -repo 'octo-frontend-libraries'
            if ($null -ne $own -and $null -ne $libraries) {
                $ownBuilt = [DateTimeOffset]::MinValue; $librariesBuilt = [DateTimeOffset]::MinValue
                $styles = [Globalization.DateTimeStyles]::AssumeUniversal
                $readable = [DateTimeOffset]::TryParse(([string]$(if ($own['builtAt'] -is [DateTime]) { $own['builtAt'].ToUniversalTime().ToString('o') } else { $own['builtAt'] })), [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$ownBuilt) -and
                    [DateTimeOffset]::TryParse(([string]$(if ($libraries['builtAt'] -is [DateTime]) { $libraries['builtAt'].ToUniversalTime().ToString('o') } else { $libraries['builtAt'] })), [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$librariesBuilt)
                if (-not $readable -or $librariesBuilt -gt $ownBuilt) {
                    return [pscustomobject]@{ Action = 'build'; Reason = 'librariesBuilt'; Detail = 'octo-frontend-libraries was built after the last build of this app'; Inputs = $inputs }
                }
            }
        }
        return [pscustomobject]@{ Action = $(if ($compare.Unchanged) { 'skip' } else { 'build' }); Reason = $compare.Reason; Detail = $compare.Detail; Inputs = $inputs }
    }
    # Prediction for the plan (-WhatIf, the plan event): a repository that is unchanged now is still built when a
    # repository it depends on is built before it (its packages change).
    $predictedBuild = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $plan) {
        $decision = & $decide $entry
        if ($decision.Action -eq 'skip' -and $decision.Reason -eq 'unchanged') {
            $dependsOn = $null
            foreach ($key in @($repoInputs.Keys)) { if ([string]$key -ieq $entry.Name -and $repoInputs[$key].Contains('dependsOn')) { $dependsOn = @($repoInputs[$key]['dependsOn']) } }
            $upstream = if ($null -ne $dependsOn) { @($predictedBuild | Where-Object { $dependsOn -contains $_ }) } else { @($predictedBuild) }
            if ($upstream.Count -gt 0) { $decision = [pscustomobject]@{ Action = 'build'; Reason = 'upstreamBuilt'; Detail = "depends on $($upstream -join ', '), built before it in this run"; Inputs = $decision.Inputs } }
        }
        if ($decision.Action -eq 'build') { $predictedBuild.Add($entry.Name) }
        $entry | Add-Member -NotePropertyName Decision -NotePropertyValue $decision -Force
    }
    # Scheduling facts (-maxParallel): what a repository waits for. Without -repoInputs.dependsOn: everything before it.
    $parallel = $maxParallel -gt 1
    $planNames = @($plan | ForEach-Object { $_.Name })
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $entry = $plan[$i]
        $dependsOn = $null
        foreach ($key in @($repoInputs.Keys)) { if ([string]$key -ieq $entry.Name -and $repoInputs[$key].Contains('dependsOn')) { $dependsOn = @($repoInputs[$key]['dependsOn'] | Where-Object { $planNames -contains $_ -and $_ -ine $entry.Name }) } }
        if ($null -eq $dependsOn) { $dependsOn = @($planNames | Select-Object -First $i) }
        $entry | Add-Member -NotePropertyName DependsOn -NotePropertyValue @($dependsOn) -Force
        $entry | Add-Member -NotePropertyName Exclusive -NotePropertyValue ($entry.Mode -in @('script', 'frontend', 'zenon')) -Force
        $entry | Add-Member -NotePropertyName CkWriter -NotePropertyValue ($parallel -and $entry.Mode -eq 'dotnet' -and (Test-OctoRepoHasCkModel -path $entry.Path)) -Force
    }
    $runningProcesses = @(Get-OctoRunningRepoProcesses -repos @($plan | Where-Object { $_.Mode -ne 'none' -and -not $skipMap.ContainsKey($_.Name) }))
    # Purge of the lane's package caches: DebugL, never for a private feed.
    $purgeCaches = $purgeEnabled -and -not $privateFeed
    $staleCache = @()
    if ($purgeCaches) {
        $staleCache = @(Get-OctoStaleGlobalPackages -nugetPath (Join-Path $branchRootPath 'nuget') -globalPackagesPath $globalPackagesPath)
    }

    if ($WhatIfPreference) {
        if ($Json) {
            Write-OctoJson -Command 'Invoke-BuildRange' -Data ([ordered]@{
                    whatIf           = $true
                    branchRootPath   = $branchRootPath
                    lane             = [ordered]@{ isolated = $laneSettings.isolated; reason = $laneSettings.reason; environment = $runEnvironment }
                    packageCaches    = @($globalPackagesPath)
                    verifyTests      = $verify
                    skipUnchanged    = [bool]$skipUnchangedEnabled
                    parallel         = $parallel
                    maxParallel      = $maxParallel
                    configuration    = $configuration
                    nugetPath        = $nugetTarget
                    feedPath         = if ($privateFeed) { $nugetTarget } else { $null }
                    repoPaths        = $repoPathsReport
                    repositories     = @($plan | ForEach-Object {
                            [ordered]@{ repo = $_.Name; group = $_.Group; mode = $_.Mode; target = $_.Target; path = $_.Path; solution = $_.Solution; projects = @($_.Projects); purge = @(if ($purgeCaches) { $_.PurgePaths }); olderThanLastBuild = @($_.OlderPaths); msbuildProperties = @($_.PropertyArgs); restoreSources = $_.RestoreSources; testProjects = if ($verify) { @($_.TestProjects) } else { @() }; notes = @($_.Notes); action = $_.Decision.Action; reason = $_.Decision.Reason; detail = $_.Decision.Detail; dependsOn = @($_.DependsOn); exclusive = [bool]($_.Exclusive -or $_.CkWriter) }
                        })
                    runningProcesses = @($runningProcesses | ForEach-Object { [ordered]@{ repo = $_.Repo; pid = $_.Pid; command = $_.Command } })
                    msbuildProperties = @($propertyArgs | ForEach-Object { Hide-OctoUrlCredentials $_ })
                    staleGlobalCache = @($staleCache | ForEach-Object { [ordered]@{ packageId = $_.PackageId; cachePath = $_.CachePath; reason = $_.Reason } })
                    purgeStaleCache  = [bool]$purgeStaleCache
                })
        }
        else {
            Write-OctoBuildRangePlan -plan $plan -branchRootPath $branchRootPath -configuration $configuration -runningProcesses $runningProcesses -staleCache $staleCache -purgeStaleCache:$purgeStaleCache -propertyArgs $propertyArgs -laneSettings $laneSettings -packageCaches $globalPackagesPath -verifyTests:$verify -feedPath $(if ($privateFeed) { $nugetTarget } else { '' }) -repoPaths $repoPathsReport -environment $runEnvironment
            Write-Host ""
            Write-Host "WhatIf: nothing was built, copied or purged." -ForegroundColor Cyan
        }
        return
    }

    if ($runningProcesses.Count -gt 0) {
        $list = ($runningProcesses | ForEach-Object { "$($_.Repo) (pid $($_.Pid))" }) -join ', '
        if ($stopServices) {
            if (-not $Json) { Write-Host "Stopping services via Stop-Octo: $list" -ForegroundColor Yellow }
            Stop-Octo -branch $branch | Out-Null
            $deadline = [DateTime]::UtcNow.AddSeconds(120)
            do {
                Start-Sleep -Seconds 2
                $runningProcesses = @(Get-OctoRunningRepoProcesses -repos @($plan | Where-Object { $_.Mode -ne 'none' }))
            } while ($runningProcesses.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
            if ($runningProcesses.Count -gt 0) {
                & $fail "Processes still running after Stop-Octo: $(($runningProcesses | ForEach-Object { "$($_.Repo) (pid $($_.Pid))" }) -join ', ')"
                return
            }
        }
        elseif ($ignoreRunningServices) {
            if (-not $Json) { Write-Warning "Building although processes run out of the range: $list" }
        }
        else {
            & $fail "Processes run out of repositories in the range: $list. Stop them (Stop-Octo -branch $branch) or pass -stopServices / -ignoreRunningServices."
            return
        }
    }

    if (-not $Json) {
        Write-OctoBuildRangePlan -plan $plan -branchRootPath $branchRootPath -configuration $configuration -staleCache $staleCache -purgeStaleCache:$purgeStaleCache -propertyArgs $propertyArgs -laneSettings $laneSettings -packageCaches $globalPackagesPath -verifyTests:$verify -feedPath $(if ($privateFeed) { $nugetTarget } else { '' }) -repoPaths $repoPathsReport -environment $runEnvironment
        Write-Host ""
    }

    $repoCount = $plan.Count
    # action/reason are the prediction made before the run; repoDone / repoSkipped say what happened.
    & $emit 'plan' ([ordered]@{ repos = @($plan | ForEach-Object { [ordered]@{ repo = $_.Name; mode = $_.Mode; action = $_.Decision.Action; reason = $_.Decision.Reason; dependsOn = @($_.DependsOn) } }); count = $repoCount; parallel = $parallel; maxParallel = $maxParallel })
    if ($privateFeed -and !(Test-Path -LiteralPath $nugetTarget)) {
        New-Item -ItemType Directory -Force -Path $nugetTarget | Out-Null
    }

    $stalePurged = @()
    if ($staleCache.Count -gt 0) {
        if ($purgeStaleCache) {
            $stalePurged = @(Remove-OctoGlobalPackageVersions -directories @($staleCache.CachePath))
        }
        elseif (-not $Json) {
            Write-Warning "$($staleCache.Count) global-cache 999.0.0 package(s) differ from $(Join-Path $branchRootPath 'nuget') (e.g. built in another checkout) and will be used as they are. Pass -purgeStaleCache to purge them."
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $failed = $null
    $failedStep = $null
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Lane environment (NUGET_PACKAGES, MSBUILDDISABLENODEREUSE) for the whole run, empty for the
    # legacy lane; restored afterwards so the session is left as it was found. -feedPath keeps the
    # caller's NUGET_PACKAGES / RestoreSources ($runEnvironment).
    $savedLaneEnvironment = Set-OctoBuildEnvironment -environment $runEnvironment
    # -EventsFile: repoDone of one repository (also for the failing one).
    $emitRepoDone = {
        param($result, [int]$index, [TimeSpan]$elapsed)
        & $emit 'repoDone' ([ordered]@{
                repo           = $result.repo
                index          = $index
                count          = $repoCount
                success        = [bool]$result.success
                status         = $result.status
                reason         = $result.reason
                seconds        = $elapsed.TotalSeconds
                buildSeconds   = $result.buildDuration.TotalSeconds
                testSeconds    = $result.testDuration.TotalSeconds
                packageSeconds = $result.packageDuration.TotalSeconds
                copied         = [int]$result.copiedCount
                purged         = @($result.purged).Count
                logFile        = $result.logFile
            })
        $events.RepoDone = $true
    }
    $repoIndex = 0
    $failedNames = @()
    try {
    if ($parallel) {
        # AB#8814 - see -maxParallel. This process schedules, the children build; everything that writes shared
        # state of the lane (feed, package cache, stamps, events, the CK sync) happens here, one step at a time.
        $workDirectory = [IO.Directory]::CreateTempSubdirectory('octo-buildrange-').FullName
        $status = @{}
        foreach ($name in $planNames) { $status[$name] = 'pending' }
        $running = [System.Collections.Generic.List[object]]::new()
        $childEnvironment = [ordered]@{}
        foreach ($name in @($runEnvironment.Keys)) { $childEnvironment[$name] = [string]$runEnvironment[$name] }
        # The compiler server is left as the sequential run has it (shared, the SDK default): UseSharedCompilation=false
        # in the children made every build about three times slower in real builds, and the server is built for
        # concurrent clients. A caller that wants it off passes -msbuildProperties @{ UseSharedCompilation = 'false' }.
        $isReady = {
            param([int]$position)
            $entry = $plan[$position]
            foreach ($name in $entry.DependsOn) { if ($status[$name] -ne 'finished') { return $false } }
            for ($j = 0; $j -lt $position; $j++) {
                $earlier = $plan[$j]
                if ($status[$earlier.Name] -eq 'finished') { continue }
                # Builds alone: nothing starts past an unfinished build.ps1/frontend/zenon repository, and such a
                # repository waits for everything before it. CK repositories keep their order among themselves.
                if ($earlier.Exclusive -or $entry.Exclusive) { return $false }
                if ($entry.CkWriter -and $earlier.CkWriter) { return $false }
            }
            if ($entry.Exclusive -and $running.Count -gt 0) { return $false }
            return $true
        }
        # Everything after the build step of one repository: package copy, cache purge, stamp, result, repoDone.
        $finishRepo = {
            param($slot, $build, $tests, [TimeSpan]$buildDuration, [TimeSpan]$testDuration)
            $entry = $slot.Entry
            $result = [ordered]@{
                repo = $entry.Name; success = [bool]$build.Success; status = $(if ($build.Success) { 'built' } else { 'failed' })
                reason = $slot.Decision.Reason; detail = $slot.Decision.Detail
                buildDuration = $buildDuration; packageDuration = [TimeSpan]::Zero; testDuration = $testDuration
                testsCompiled = if ($null -ne $tests -and -not $tests.Skipped) { [bool]$tests.Success } else { $null }
                copiedCount = 0; purged = @(); staleSkipped = @(); logFile = $build.LogFile; msbuildProperties = @($entry.PropertyArgs)
            }
            $step = $null
            if (-not $build.Success) { $step = 'build' }
            elseif ($null -ne $tests -and -not $tests.Success) { $result.success = $false; $result.status = 'failed'; $result.logFile = $tests.LogFile; $step = 'tests' }
            elseif ($purgeEnabled) {
                & $emit 'phase' ([ordered]@{ repo = $entry.Name; phase = 'packages' })
                $packageWatch = [System.Diagnostics.Stopwatch]::StartNew()
                $copyArgs = @{ directory = $entry.Path; branch = $branch; onlyChanged = $true; Json = $true }
                if ($privateFeed) { $copyArgs['nugetPath'] = $nugetTarget }
                $copy = Copy-NuGetPackages @copyArgs | ConvertFrom-Json
                $copiedFiles = @($copy.data.files | Where-Object { $_ })
                $result.copiedCount = $copiedFiles.Count
                $copyFailed = ($null -eq $copy -or $copy.data.success -ne $true)
                if ($purgeCaches -and $copiedFiles.Count -gt 0) {
                    # Only what this repository produced. No running build restores these packages: a repository
                    # that consumes them depends on this one and starts only after this block.
                    if (-not $copyFailed) { & $emit 'phase' ([ordered]@{ repo = $entry.Name; phase = 'purge' }) }
                    $packageIds = @($copiedFiles | ForEach-Object { Get-OctoPackageIdFromFile -fileName $_ })
                    $result.purged = @(Remove-OctoGlobalPackageVersions -directories @(Get-OctoGlobalPackageDirectories -packageIds $packageIds -globalPackagesPath $globalPackagesPath))
                }
                if ($copyFailed) {
                    $result.success = $false; $result.status = 'failed'; $step = 'packages'
                    Write-Error "Copy-NuGetPackages failed for $($entry.Name)$(if ($copy.data.error) { ": $($copy.data.error)" })"
                }
                else { $result.staleSkipped = @($copy.data.skipped | Where-Object { $_ } | ForEach-Object { "$($_.file) ($($_.reason))" } | Sort-Object -Unique) }
                $packageWatch.Stop()
                $result.packageDuration = $packageWatch.Elapsed
            }
            if ($result.success -and $stampsEnabled -and $null -ne $slot.Decision.Inputs -and -not $slot.Decision.Inputs.Source.Problem) {
                Write-OctoBuildStamp -stampRoot $stampRoot -repo $entry.Name -inputs $slot.Decision.Inputs -configuration $configuration -tests $stampTests
            }
            $results.Add($result)
            & $emitRepoDone $result $slot.Index $slot.Watch.Elapsed
            if ($result.success) {
                $status[$entry.Name] = 'finished'
                if (-not $Json) { Write-Host ("<== {0}: built in {1} (copied {2} package(s), purged {3} cache folder(s))" -f $entry.Name, (Format-OctoDuration $slot.Watch.Elapsed), $result.copiedCount, @($result.purged).Count) -ForegroundColor Green }
            }
            else {
                $status[$entry.Name] = 'failed'
                $failures.Add([pscustomobject]@{ Entry = $entry; Step = $step })
                if (-not $Json) { Write-Host "<== $($entry.Name): FAILED ($step) - nothing new is started, running repositories finish" -ForegroundColor Red }
            }
        }
        $failures = [System.Collections.Generic.List[object]]::new()
        $completedRun = $false
        try {
            while ($true) {
                # 1. Start what is ready, in build order, while a slot is free and nothing failed.
                $progress = $false
                if ($failures.Count -eq 0) {
                    for ($position = 0; $position -lt $plan.Count; $position++) {
                        $entry = $plan[$position]
                        if ($status[$entry.Name] -ne 'pending' -or -not (& $isReady $position)) { continue }
                        # No free slot: wait (also with the unchanged check, it reads git and hashes packages).
                        if ($running.Count -ge $maxParallel -and $entry.Mode -ne 'none' -and -not $skipMap.ContainsKey($entry.Name)) { continue }
                        # Decided now: the packages of everything it depends on are in the feed.
                        $decision = & $decide $entry
                        $skip = $decision.Action -eq 'skip' -and ($entry.Mode -ne 'none' -or $skipMap.ContainsKey($entry.Name))
                        $repoIndex++
                        $progress = $true
                        if ($skip) {
                            $results.Add([ordered]@{
                                    repo = $entry.Name; success = $true; status = 'skipped'; reason = $decision.Reason; detail = $decision.Detail
                                    buildDuration = [TimeSpan]::Zero; packageDuration = [TimeSpan]::Zero; testDuration = [TimeSpan]::Zero; testsCompiled = $null
                                    copiedCount = 0; purged = @(); staleSkipped = @(); logFile = $null; msbuildProperties = @($entry.PropertyArgs)
                                })
                            & $emit 'repoSkipped' ([ordered]@{ repo = $entry.Name; index = $repoIndex; count = $repoCount; reason = $decision.Reason; detail = $decision.Detail })
                            if (-not $Json) { Write-Host "==> $($entry.Name): skipped ($($decision.Reason)$(if ($decision.Detail) { " - $($decision.Detail)" }))" -ForegroundColor DarkGray }
                            $status[$entry.Name] = 'finished'
                            continue
                        }
                        $slot = [pscustomobject]@{ Entry = $entry; Index = $repoIndex; Decision = $decision; Watch = [System.Diagnostics.Stopwatch]::StartNew(); Job = $null; Phase = 'build' }
                        & $emit 'repoStart' ([ordered]@{ repo = $entry.Name; index = $repoIndex; count = $repoCount })
                        & $emit 'phase' ([ordered]@{ repo = $entry.Name; phase = 'build' })
                        if ($entry.Mode -eq 'none') {
                            # Nothing to build: the same repoStart/repoDone pair as the sequential run.
                            $result = [ordered]@{
                                repo = $entry.Name; success = $true; status = 'skipped'; reason = $decision.Reason; detail = $decision.Detail
                                buildDuration = [TimeSpan]::Zero; packageDuration = [TimeSpan]::Zero; testDuration = [TimeSpan]::Zero; testsCompiled = $null
                                copiedCount = 0; purged = @(); staleSkipped = @(); logFile = $null; msbuildProperties = @($entry.PropertyArgs)
                            }
                            $results.Add($result)
                            & $emitRepoDone $result $slot.Index $slot.Watch.Elapsed
                            $status[$entry.Name] = 'finished'
                            continue
                        }
                        if (-not $Json) { Write-Host "==> $($entry.Name)$(if ($skipUnchangedEnabled) { " ($($decision.Reason)$(if ($decision.Detail) { ": $($decision.Detail)" }))" }) [$($running.Count + 1) of $maxParallel running]" -ForegroundColor Cyan }
                        if ($stampsEnabled) { Remove-OctoBuildStamp -stampRoot $stampRoot -repo $entry.Name }
                        $status[$entry.Name] = 'running'
                        if ($configuration -ieq 'DebugL' -and $entry.Mode -eq 'dotnet' -and -not $skipCkSync) {
                            # Writes the lane's local catalog: here, never in a child (CK repositories are serial).
                            [void](Sync-OctoCkIntermediateVersions -repositoryPath $entry.Path -localCatalogRoot (Join-Path $branchRootPath '.octo/local-catalog') -Quiet:$Json)
                        }
                        if ($entry.Exclusive) {
                            # build.ps1 / frontend / zenon: alone and in this process, exactly like the sequential run.
                            $running.Add($slot)
                            $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()
                            $savedRepoEnvironment = if ($entry.RestoreSources) { Set-OctoBuildEnvironment -environment @{ RestoreSources = $entry.RestoreSources } } else { $null }
                            try { $build = Invoke-OctoBuildRangeRepo -entry $entry -configuration $configuration -msbuildProperties $entry.MsBuildProperties -Json:$Json }
                            finally { Restore-OctoBuildEnvironment -saved $savedRepoEnvironment }
                            $buildWatch.Stop()
                            [void]$running.Remove($slot)
                            & $finishRepo $slot $build $null $buildWatch.Elapsed ([TimeSpan]::Zero)
                            break   # re-evaluate from the top: it may have failed
                        }
                        $environment = [ordered]@{}
                        foreach ($name in @($childEnvironment.Keys)) { $environment[$name] = $childEnvironment[$name] }
                        if ($entry.RestoreSources) { $environment['RestoreSources'] = [string]$entry.RestoreSources }
                        $running.Add($slot)
                        $slot.Job = Start-OctoRepoBuildJob -entry $entry -configuration $configuration -msbuildProperties $entry.MsBuildProperties -verifyTests:$verify -environment $environment -workDirectory $workDirectory
                    }
                }
                # 2. Collect what finished.
                foreach ($slot in @($running)) {
                    $state = Get-OctoRepoBuildJobState -job $slot.Job
                    if ($state.Phase -ne $slot.Phase) { $slot.Phase = $state.Phase; & $emit 'phase' ([ordered]@{ repo = $slot.Entry.Name; phase = $state.Phase }) }
                    if (-not $state.Done) { continue }
                    [void]$running.Remove($slot)
                    $progress = $true
                    & $finishRepo $slot $state.Build $state.Tests ([TimeSpan]::FromSeconds($state.BuildSeconds)) ([TimeSpan]::FromSeconds($state.TestSeconds))
                }
                if ($running.Count -eq 0) {
                    if ($failures.Count -gt 0 -or @($planNames | Where-Object { $status[$_] -eq 'pending' }).Count -eq 0) { break }
                    if (-not $progress) { throw "Invoke-BuildRange: no repository can start - the dependencies of $(@($planNames | Where-Object { $status[$_] -eq 'pending' }) -join ', ') form a cycle." }
                }
                elseif (-not $progress) { Start-Sleep -Milliseconds 200 }
            }
            $completedRun = $true
        }
        finally {
            # A throw or Ctrl+C: no child is left behind, and every repository that was running gets its repoDone.
            if (-not $completedRun) {
                foreach ($slot in @($running)) {
                    if ($slot.Job) { Stop-OctoRepoBuildJob -job $slot.Job }
                    & $emit 'repoDone' ([ordered]@{ repo = $slot.Entry.Name; index = $slot.Index; count = $repoCount; success = $false; status = 'failed'; reason = $slot.Decision.Reason; seconds = $slot.Watch.Elapsed.TotalSeconds; buildSeconds = $null; testSeconds = $null; packageSeconds = $null; copied = $null; purged = $null; logFile = $null })
                    if (-not $events.FailedRepo) { $events.FailedRepo = $slot.Entry.Name; $events.FailedStep = $slot.Phase }
                }
                # Complete-OctoBuildEvents: the repoDone events are written; a throw between two repositories is no preflight failure.
                $events.Repo = $null
                $events.RepoDone = $true
                if (-not $events.FailedStep) { $events.FailedStep = 'build' }
            }
            Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($failures.Count -gt 0) {
            $failed = $failures[0].Entry
            $failedStep = $failures[0].Step
            $failedNames = @($failures | ForEach-Object { $_.Entry.Name })
        }
        # Report in build order, whatever order the repositories finished in.
        $ordered = @($planNames | ForEach-Object { $name = $_; $results | Where-Object { $_.repo -eq $name } })
        $results.Clear()
        foreach ($result in $ordered) { $results.Add($result) }
    }
    else {
    foreach ($entry in $plan) {
        $repoIndex++
        # Decided now, not from the plan: packages rebuilt earlier in this run are in the feed by now.
        # (A repository without a solution keeps its repoStart/repoDone pair; it is reported as skipped, nothingToBuild.)
        $decision = & $decide $entry
        if ($decision.Action -eq 'skip' -and ($entry.Mode -ne 'none' -or $skipMap.ContainsKey($entry.Name))) {
            $results.Add([ordered]@{
                    repo = $entry.Name; success = $true; status = 'skipped'; reason = $decision.Reason; detail = $decision.Detail
                    buildDuration = [TimeSpan]::Zero; packageDuration = [TimeSpan]::Zero; testDuration = [TimeSpan]::Zero; testsCompiled = $null
                    copiedCount = 0; purged = @(); staleSkipped = @(); logFile = $null; msbuildProperties = @($entry.PropertyArgs)
                })
            & $emit 'repoSkipped' ([ordered]@{ repo = $entry.Name; index = $repoIndex; count = $repoCount; reason = $decision.Reason; detail = $decision.Detail })
            if (-not $Json) { Write-Host "==> $($entry.Name): skipped ($($decision.Reason)$(if ($decision.Detail) { " - $($decision.Detail)" }))" -ForegroundColor DarkGray }
            continue
        }
        # A stamp only ever describes a build that succeeded: gone while the repository is built.
        if ($stampsEnabled -and $entry.Mode -ne 'none') { Remove-OctoBuildStamp -stampRoot $stampRoot -repo $entry.Name }
        $repoWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $events.Repo = $entry.Name
        $events.Index = $repoIndex
        $events.Count = $repoCount
        $events.Phase = $null
        $events.RepoDone = $false
        $events.RepoWatch = $repoWatch
        $events.LogFile = $null
        & $emit 'repoStart' ([ordered]@{ repo = $entry.Name; index = $repoIndex; count = $repoCount })
        if (-not $Json) { Write-Host "==> $($entry.Name)$(if ($skipUnchangedEnabled -and $entry.Mode -ne 'none') { " ($($decision.Reason)$(if ($decision.Detail) { ": $($decision.Detail)" }))" })" -ForegroundColor Cyan }
        $events.Phase = 'build'
        & $emit 'phase' ([ordered]@{ repo = $entry.Name; phase = 'build' })
        $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $savedRepoEnvironment = $null
        if ($entry.RestoreSources) {
            $savedRepoEnvironment = Set-OctoBuildEnvironment -environment @{ RestoreSources = $entry.RestoreSources }
        }
        try {
            # AB#7974: before the CK compile gate of this repository runs, bring the private catalog's intermediate
            # versions of its ckLanguage 2 models into the lane's local catalog (warning + fix command on failure).
            if ($configuration -ieq 'DebugL' -and $entry.Mode -eq 'dotnet' -and -not $skipCkSync) {
                [void](Sync-OctoCkIntermediateVersions -repositoryPath $entry.Path -localCatalogRoot (Join-Path $branchRootPath '.octo/local-catalog') -Quiet:$Json)
            }
            $build = Invoke-OctoBuildRangeRepo -entry $entry -configuration $configuration -msbuildProperties $entry.MsBuildProperties -Json:$Json
            $buildWatch.Stop()
            $tests = $null
            $testWatch = [System.Diagnostics.Stopwatch]::new()
            if ($build.Success -and $verify) {
                $events.Phase = 'tests'
                & $emit 'phase' ([ordered]@{ repo = $entry.Name; phase = 'tests' })
                $testWatch.Start()
                $tests = Invoke-OctoBuildRangeTests -entry $entry -configuration $configuration -msbuildProperties $entry.MsBuildProperties -Json:$Json
                $testWatch.Stop()
            }
        }
        finally {
            Restore-OctoBuildEnvironment -saved $savedRepoEnvironment
        }

        $result = [ordered]@{
            repo            = $entry.Name
            success         = [bool]$build.Success
            status          = if ($entry.Mode -eq 'none') { 'skipped' } elseif ($build.Success) { 'built' } else { 'failed' }
            reason          = $decision.Reason
            detail          = $decision.Detail
            buildDuration   = $buildWatch.Elapsed
            packageDuration = [TimeSpan]::Zero
            testDuration    = $testWatch.Elapsed
            testsCompiled   = if ($null -ne $tests -and -not $tests.Skipped) { [bool]$tests.Success } else { $null }
            copiedCount     = 0
            purged          = @()
            staleSkipped    = @()
            logFile         = $build.LogFile
            msbuildProperties = @($entry.PropertyArgs)
        }

        if (-not $build.Success) {
            $results.Add($result)
            $failed = $entry
            $failedStep = 'build'
            & $emitRepoDone $result $repoIndex $repoWatch.Elapsed
            break
        }
        if ($null -ne $tests -and -not $tests.Success) {
            $result.success = $false
            $result.status = 'failed'
            $result.logFile = $tests.LogFile
            $results.Add($result)
            $failed = $entry
            $failedStep = 'tests'
            & $emitRepoDone $result $repoIndex $repoWatch.Elapsed
            break
        }

        if ($purgeEnabled -and $entry.Mode -ne 'none') {
            $events.Phase = 'packages'
            & $emit 'phase' ([ordered]@{ repo = $entry.Name; phase = 'packages' })
            $packageWatch = [System.Diagnostics.Stopwatch]::StartNew()
            # T-M1: not "written since this build started" - pack is incremental, so a package from an
            # earlier, interrupted run (e.g. a -verifyTests failure) or an IDE build would be missed.
            # -onlyChanged copies what nuget/ lacks or holds in another (older) version.
            $copyArgs = @{ directory = $entry.Path; branch = $branch; onlyChanged = $true; Json = $true }
            if ($privateFeed) { $copyArgs['nugetPath'] = $nugetTarget }
            $copy = Copy-NuGetPackages @copyArgs | ConvertFrom-Json
            if ($null -eq $copy -or $copy.data.success -ne $true) {
                # e.g. an unwritable -feedPath: a repository whose packages did not land is not a success.
                # Packages that did land are purged from the lane caches as usual, so no cache keeps an old copy
                # of a package that changed in <lane>/nuget.
                $partialFiles = @($copy.data.files | Where-Object { $_ })
                $result.copiedCount = $partialFiles.Count
                if ($purgeCaches -and $partialFiles.Count -gt 0) {
                    $packageIds = @($partialFiles | ForEach-Object { Get-OctoPackageIdFromFile -fileName $_ })
                    $purgeDirectories = @(Get-OctoGlobalPackageDirectories -packageIds $packageIds -globalPackagesPath $globalPackagesPath)
                    $result.purged = @(Remove-OctoGlobalPackageVersions -directories $purgeDirectories)
                }
                $packageWatch.Stop()
                $result.packageDuration = $packageWatch.Elapsed
                $result.success = $false
                $result.status = 'failed'
                $results.Add($result)
                $failed = $entry
                $failedStep = 'packages'
                Write-Error "Copy-NuGetPackages failed for $($entry.Name)$(if ($copy.data.error) { ": $($copy.data.error)" })"
                & $emitRepoDone $result $repoIndex $repoWatch.Elapsed
                break
            }
            $copiedFiles = @($copy.data.files | Where-Object { $_ })
            $result.copiedCount = $copiedFiles.Count
            if ($purgeCaches) {
                $events.Phase = 'purge'
                & $emit 'phase' ([ordered]@{ repo = $entry.Name; phase = 'purge' })
                # Purge list = what this build actually produced (and was just copied), not the prediction.
                $packageIds = @($copiedFiles | ForEach-Object { Get-OctoPackageIdFromFile -fileName $_ })
                $purgeDirectories = @(Get-OctoGlobalPackageDirectories -packageIds $packageIds -globalPackagesPath $globalPackagesPath)
                $result.purged = @(Remove-OctoGlobalPackageVersions -directories $purgeDirectories)
            }
            $result.staleSkipped = @($copy.data.skipped | Where-Object { $_ } | ForEach-Object { "$($_.file) ($($_.reason))" } | Sort-Object -Unique)
            $packageWatch.Stop()
            $result.packageDuration = $packageWatch.Elapsed
            if (-not $Json) {
                $target = if ($privateFeed) { " into $nugetTarget (private feed, no cache purge)" } else { '' }
                Write-Host "    copied $($result.copiedCount) package(s)$target, purged $($result.purged.Count) global-cache folder(s), left $($result.staleSkipped.Count) unchanged/stale package(s) untouched" -ForegroundColor DarkGray
            }
        }
        # Built, tests compiled (when asked) and packages copied: record what it was built from.
        if ($stampsEnabled -and $entry.Mode -ne 'none' -and $null -ne $decision.Inputs -and -not $decision.Inputs.Source.Problem) {
            Write-OctoBuildStamp -stampRoot $stampRoot -repo $entry.Name -inputs $decision.Inputs -configuration $configuration -tests $stampTests
        }
        $results.Add($result)
        & $emitRepoDone $result $repoIndex $repoWatch.Elapsed
    }
    }
    }
    finally {
        Restore-OctoBuildEnvironment -saved $savedLaneEnvironment
    }
    $totalWatch.Stop()
    # For the closing `done` event written by the Invoke-BuildRange wrapper.
    $events.Success = ($null -eq $failed)
    $events.FailedRepo = if ($failed) { $failed.Name } else { $null }
    $events.FailedStep = $failedStep
    $events.Completed = $true

    # R2-5: a src-only run never compiled the test projects - say so instead of implying "all green".
    $testsHint = $null
    $builtNames = @($results | Where-Object { $_.status -ne 'skipped' } | ForEach-Object { $_.repo })
    if (-not $includeTests -and -not $verify -and @($plan | Where-Object { $_.Mode -eq 'dotnet' -and $_.Target -eq 'slnf' -and $builtNames -contains $_.Name }).Count -gt 0) {
        $testsHint = "Only src/ projects were built - test projects were not compiled. Before handing off, rerun with -verifyTests (compile tests, do not run them) or -includeTests."
    }

    if ($Json) {
        Write-OctoJson -Command 'Invoke-BuildRange' -Data ([ordered]@{
                branchRootPath = $branchRootPath
                configuration  = $configuration
                success        = ($null -eq $failed)
                failedRepo     = if ($failed) { $failed.Name } else { $null }
                failedStep     = $failedStep
                failedRepos    = @(if ($failedNames.Count -gt 0) { $failedNames } elseif ($failed) { $failed.Name })
                parallel       = $parallel
                maxParallel    = $maxParallel
                lane           = [ordered]@{ isolated = $laneSettings.isolated; reason = $laneSettings.reason; environment = $runEnvironment }
                packageCaches  = @($globalPackagesPath)
                feedPath       = if ($privateFeed) { $nugetTarget } else { $null }
                repoPaths      = $repoPathsReport
                testsCompiled  = [bool]($includeTests -or $verify)
                skipUnchanged  = [bool]$skipUnchangedEnabled
                builtCount     = @($results | Where-Object { $_.status -eq 'built' }).Count
                skippedCount   = @($results | Where-Object { $_.status -eq 'skipped' }).Count
                hint           = $testsHint
                repositories   = @($results | ForEach-Object {
                        [ordered]@{
                            repo                   = $_.repo
                            success                = $_.success
                            status                 = $_.status
                            reason                 = $_.reason
                            detail                 = $_.detail
                            buildSeconds           = $_.buildDuration.TotalSeconds
                            testCompileSeconds     = $_.testDuration.TotalSeconds
                            testsCompiled          = $_.testsCompiled
                            packageSeconds         = $_.packageDuration.TotalSeconds
                            copiedCount            = $_.copiedCount
                            purged                 = @($_.purged)
                            unchangedOrStale       = @($_.staleSkipped)
                            logFile                = $_.logFile
                            msbuildProperties      = @($_.msbuildProperties)
                        }
                    })
                notBuilt       = @($plan | Where-Object { $name = $_.Name; -not ($results | Where-Object { $_.repo -eq $name }) } | ForEach-Object { $_.Name })
                msbuildProperties = @($propertyArgs | ForEach-Object { Hide-OctoUrlCredentials $_ })
                staleGlobalCache = @($staleCache | ForEach-Object { [ordered]@{ packageId = $_.PackageId; cachePath = $_.CachePath; reason = $_.Reason } })
                staleGlobalCachePurged = @($stalePurged)
                elapsedSeconds = $totalWatch.Elapsed.TotalSeconds
            })
    }
    else {
        Write-Host ""
        Write-Host "Summary (Invoke-BuildRange, $configuration):"
        Write-Host "---------------------------------"
        foreach ($result in $results) {
            if ($result.status -eq 'skipped') {
                Write-Host ("{0,-45} skipped ({1})" -f $result.repo, $result.reason) -ForegroundColor DarkGray
                continue
            }
            $line = "{0,-45} build {1,8}   copy+purge {2,8}" -f $result.repo, (Format-OctoDuration $result.buildDuration), (Format-OctoDuration $result.packageDuration)
            if ($verify) { $line += "   tests {0,8}" -f (Format-OctoDuration $result.testDuration) }
            Write-Host $line -ForegroundColor $(if ($result.success) { 'Green' } else { 'Red' })
        }
        foreach ($skipped in @($plan | Where-Object { $name = $_.Name; -not ($results | Where-Object { $_.repo -eq $name }) })) {
            Write-Host ("{0,-45} not built (stopped after failure)" -f $skipped.Name) -ForegroundColor DarkGray
        }
        Write-Host "---------------------------------"
        Write-Host "Total: $(Format-OctoDuration $totalWatch.Elapsed)"
        if ($testsHint -and -not $failed) { Write-Host $testsHint -ForegroundColor Yellow }
    }

    if ($failed) {
        $global:LASTEXITCODE = 1
        $message = if ($failedStep -eq 'tests') { "Invoke-BuildRange: test projects of $($failed.Name) do not compile (-verifyTests)." } else { "Invoke-BuildRange: build of $($failed.Name) failed." }
        $logFile = @($results | Where-Object { $_.repo -eq $failed.Name })[0].logFile
        if ($logFile -and (Test-Path $logFile)) {
            $message += " Log: $logFile"
            if (-not $Json) {
                $errorLines = @(Get-Content $logFile | Where-Object { $_ -match '\berror\b' } | Select-Object -Unique -Last 20)
                if ($errorLines.Count -eq 0) { $errorLines = @(Get-Content $logFile -Tail 20) }
                $errorLines | ForEach-Object { Write-Host $_ -ForegroundColor Red }
            }
        }
        Write-Error $message
        return
    }
    $global:LASTEXITCODE = 0
}

Export-ModuleMember -Function @('Invoke-BuildRange', 'Invoke-OctoBuildRangeRepoStep')
