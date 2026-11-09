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
        Write-Host "[$configuration] dotnet build $buildTarget $($propertyArgs -join ' ')" -ForegroundColor Green
    }
    "Invoke-BuildRange: dotnet build $buildTarget -c $configuration -nodeReuse:false $($propertyArgs -join ' ')" | Set-Content -Path $logFile
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
    "Invoke-BuildRange -verifyTests: dotnet build $filter -c $configuration -nodeReuse:false $($propertyArgs -join ' ')" | Add-Content -Path $logFile
    & dotnet build $filter -c $configuration -nodeReuse:false @propertyArgs *>> $logFile
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{ Success = ($exitCode -eq 0); Skipped = $false; LogFile = $logFile; ExitCode = $exitCode }
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
        Write-Host "  MSBuild properties (all repositories): $($propertyArgs -join ' ')" -ForegroundColor DarkGray
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
        Write-Host ("{0,2}. {1} [{2}] -> {3}" -f $index, $entry.Name, $entry.Group, $entry.Target) -ForegroundColor Green
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
    isolated lane (e.g. dev, whose nuget/ is not the local feed of the user-level NuGet.Config)
    builds with NUGET_PACKAGES=<lane>/.nuget-packages and MSBUILDDISABLENODEREUSE=1, and in DebugL
    repositories without their own <RestoreSources> get RestoreSources=<lane>/nuget;nuget.org.
    The environment is restored afterwards. The package cache that is purged and checked follows
    the lane (Get-OctoRangePackageCaches): <lane>/.nuget-packages for an isolated lane; for the
    legacy lane (main) the global cache (NUGET_PACKAGES or ~/.nuget/packages), plus
    <lane>/.nuget-packages if <lane>/Octo.User.props sets RestorePackagesPath.

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

.PARAMETER EventsFile
    Append build progress events to this file while the run is going (one JSON object per line,
    see Write-OctoBuildEvent): plan, then per repository repoStart, phase (build, tests, packages,
    purge) and repoDone, and finally done - also on an early refusal or a throw (success=false).
    Nothing is written under -WhatIf. The -Json output is not affected.

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
        [string]$feedPath = '',
        [string]$EventsFile = '',
        [switch]$Json
    )

    # The run itself lives in Invoke-OctoBuildRangeCore; this wrapper guarantees the closing `done`
    # event of -EventsFile, also when the run refuses early or throws.
    # The core is a simple function: -WhatIf / -ErrorAction reach it as the preference variables of this
    # scope, and its Write-Error lands in this cmdlet's error stream (-ErrorVariable) like before.
    $skip = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters) + @('EventsFile')
    $forward = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -in $skip) { continue }
        $forward[$key] = $PSBoundParameters[$key]
    }
    $events = New-OctoBuildEventState -Path $EventsFile -Command 'Invoke-BuildRange'
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
        [string]$branchRootPath = ""
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
        if (-not [string]::IsNullOrWhiteSpace($branchRootPath)) {
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
        [string]$feedPath = '',
        [hashtable]$events,
        [switch]$Json
    )

    $eventsPath = [string]$events.Path
    $emit = {
        param([string]$name, [System.Collections.IDictionary]$data)
        Write-OctoBuildEvent -Path $eventsPath -Command 'Invoke-BuildRange' -Event $name -Data $data
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

    $order = @(Get-OctoBuildOrder -branchRootPath $branchRootPath -excludeFrontend $excludeFrontend -excludeAdditional $false)
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
    try { $repoPathMap = Resolve-OctoRepoPathOverrides -repoPaths $repoPaths -order $order -branchRootPath $branchRootPath }
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
                    $perRepo = if ($msbuildPropertiesPerRepo.ContainsKey($repo.Name)) { $msbuildPropertiesPerRepo[$repo.Name] } else { @{} }
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
        $entry | Add-Member -NotePropertyName PropertyArgs -NotePropertyValue @(ConvertTo-OctoMsBuildPropertyArgs -properties $properties) -Force
    }
    $publishWarning = Get-OctoCkPublishDisabledWarning -repoNames @($plan | Where-Object { $_.Mode -eq 'dotnet' -and (Test-OctoCkPublishDisabled -properties $_.MsBuildProperties) } | ForEach-Object { $_.Name })
    if ($publishWarning) { Write-Warning $publishWarning }
    $runningProcesses = @(Get-OctoRunningRepoProcesses -repos @($plan | Where-Object { $_.Mode -ne 'none' }))
    $purgeEnabled = $configuration -ieq 'DebugL'
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
                    configuration    = $configuration
                    nugetPath        = $nugetTarget
                    feedPath         = if ($privateFeed) { $nugetTarget } else { $null }
                    repoPaths        = $repoPathsReport
                    repositories     = @($plan | ForEach-Object {
                            [ordered]@{ repo = $_.Name; group = $_.Group; mode = $_.Mode; target = $_.Target; path = $_.Path; solution = $_.Solution; projects = @($_.Projects); purge = @(if ($purgeCaches) { $_.PurgePaths }); olderThanLastBuild = @($_.OlderPaths); msbuildProperties = @($_.PropertyArgs); restoreSources = $_.RestoreSources; testProjects = if ($verify) { @($_.TestProjects) } else { @() }; notes = @($_.Notes) }
                        })
                    runningProcesses = @($runningProcesses | ForEach-Object { [ordered]@{ repo = $_.Repo; pid = $_.Pid; command = $_.Command } })
                    msbuildProperties = @($propertyArgs)
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
    & $emit 'plan' ([ordered]@{ repos = @($plan | ForEach-Object { [ordered]@{ repo = $_.Name; mode = $_.Mode } }); count = $repoCount })
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
    try {
    foreach ($entry in $plan) {
        $repoIndex++
        $repoWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $events.Repo = $entry.Name
        $events.Index = $repoIndex
        $events.Count = $repoCount
        $events.Phase = $null
        $events.RepoDone = $false
        $events.RepoWatch = $repoWatch
        $events.LogFile = $null
        & $emit 'repoStart' ([ordered]@{ repo = $entry.Name; index = $repoIndex; count = $repoCount })
        if (-not $Json) { Write-Host "==> $($entry.Name)" -ForegroundColor Cyan }
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
                $packageWatch.Stop()
                $result.packageDuration = $packageWatch.Elapsed
                $result.success = $false
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
        $results.Add($result)
        & $emitRepoDone $result $repoIndex $repoWatch.Elapsed
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
    if (-not $includeTests -and -not $verify -and @($plan | Where-Object { $_.Mode -eq 'dotnet' -and $_.Target -eq 'slnf' }).Count -gt 0) {
        $testsHint = "Only src/ projects were built - test projects were not compiled. Before handing off, rerun with -verifyTests (compile tests, do not run them) or -includeTests."
    }

    if ($Json) {
        Write-OctoJson -Command 'Invoke-BuildRange' -Data ([ordered]@{
                branchRootPath = $branchRootPath
                configuration  = $configuration
                success        = ($null -eq $failed)
                failedRepo     = if ($failed) { $failed.Name } else { $null }
                failedStep     = $failedStep
                lane           = [ordered]@{ isolated = $laneSettings.isolated; reason = $laneSettings.reason; environment = $runEnvironment }
                packageCaches  = @($globalPackagesPath)
                feedPath       = if ($privateFeed) { $nugetTarget } else { $null }
                repoPaths      = $repoPathsReport
                testsCompiled  = [bool]($includeTests -or $verify)
                hint           = $testsHint
                repositories   = @($results | ForEach-Object {
                        [ordered]@{
                            repo                   = $_.repo
                            success                = $_.success
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
                notBuilt       = @($plan | Select-Object -Skip $results.Count | ForEach-Object { $_.Name })
                msbuildProperties = @($propertyArgs)
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
            $line = "{0,-45} build {1,8}   copy+purge {2,8}" -f $result.repo, (Format-OctoDuration $result.buildDuration), (Format-OctoDuration $result.packageDuration)
            if ($verify) { $line += "   tests {0,8}" -f (Format-OctoDuration $result.testDuration) }
            Write-Host $line -ForegroundColor $(if ($result.success) { 'Green' } else { 'Red' })
        }
        foreach ($skipped in @($plan | Select-Object -Skip $results.Count)) {
            Write-Host ("{0,-45} not built (stopped after failure)" -f $skipped.Name) -ForegroundColor DarkGray
        }
        Write-Host "---------------------------------"
        Write-Host "Total: $(Format-OctoDuration $totalWatch.Elapsed)"
        if ($testsHint -and -not $failed) { Write-Host $testsHint -ForegroundColor Yellow }
    }

    if ($failed) {
        $global:LASTEXITCODE = 1
        $message = if ($failedStep -eq 'tests') { "Invoke-BuildRange: test projects of $($failed.Name) do not compile (-verifyTests)." } else { "Invoke-BuildRange: build of $($failed.Name) failed." }
        $logFile = $results[$results.Count - 1].logFile
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

Export-ModuleMember -Function @('Invoke-BuildRange')
