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

function Get-OctoGlobalPackagesPath {
    if ($env:NUGET_PACKAGES) { return $env:NUGET_PACKAGES }
    if ($Global:GLOBALNUGETPACKAGESPATH) { return [string]$Global:GLOBALNUGETPACKAGESPATH }
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.nuget/packages'
}

function Get-OctoGlobalPackageDirectories {
    # Maps package ids to their ~/.nuget/packages/<id lower>/999.0.0 folders.
    param(
        [string[]]$packageIds = @(),
        [Parameter(Mandatory = $true)] [string]$globalPackagesPath
    )
    return @($packageIds | Sort-Object -Unique | ForEach-Object {
            Join-Path -Path (Join-Path -Path $globalPackagesPath -ChildPath $_.ToLowerInvariant()) -ChildPath $script:OctoLocalPackageVersion
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
    # the global packages cache (shared by all checkouts, e.g. main and dev). NuGet records the
    # SHA-512 of the extracted nupkg in <id>.999.0.0.nupkg.sha512; when it differs from the local
    # package, restores in this checkout silently use the other build ("hashMismatch").
    # A cache folder without the hash file cannot be verified ("noHashFile").
    param(
        [Parameter(Mandatory = $true)] [string]$nugetPath,
        [Parameter(Mandatory = $true)] [string]$globalPackagesPath
    )
    $stale = @()
    if (!(Test-Path $nugetPath)) { return $stale }
    foreach ($file in @(Get-ChildItem -Path $nugetPath -File -Filter $script:OctoPackageFilter)) {
        $id = (Get-OctoPackageIdFromFile -fileName $file.Name).ToLowerInvariant()
        $cacheDirectory = Join-Path -Path (Join-Path -Path $globalPackagesPath -ChildPath $id) -ChildPath $script:OctoLocalPackageVersion
        if (!(Test-Path $cacheDirectory)) { continue }   # not extracted yet - the next restore takes the local one
        $hashFile = Join-Path -Path $cacheDirectory -ChildPath "$id.$($script:OctoLocalPackageVersion).nupkg.sha512"
        $reason = $null
        if (!(Test-Path $hashFile)) {
            $reason = 'noHashFile'
        }
        else {
            # Per package, never reuse a value from the previous iteration: an empty hash file
            # (interrupted extraction) reads as $null and counts as missing.
            $rawHash = Get-Content -Path $hashFile -Raw -ErrorAction SilentlyContinue
            $cacheHash = if ($null -eq $rawHash) { '' } else { ([string]$rawHash).Trim() }
            if ([string]::IsNullOrEmpty($cacheHash)) {
                $reason = 'noHashFile'
            }
            else {
                $stream = [IO.File]::OpenRead($file.FullName)
                try { $localHash = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($stream)) }
                finally { $stream.Dispose() }
                if ($cacheHash -ne $localHash) { $reason = 'hashMismatch' }
            }
        }
        if ($reason) {
            $stale += [pscustomobject]@{ PackageId = $id; CachePath = $cacheDirectory; Reason = $reason }
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

    # Windows exposes no working directory here; services there are matched by command line only.
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
        [Parameter(Mandatory = $true)] [string]$globalPackagesPath
    )

    $plan = @()
    foreach ($repo in $repos) {
        $mode = Get-OctoRepoBuildMode -repo $repo
        $solution = Get-OctoRepoSolution -path $repo.Path
        $projects = @()
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
    $checkout = [IO.Path]::GetFullPath((Split-Path -Parent (Split-Path -Parent $solutionPath)))
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
            Invoke-Publish -repositoryPath $entry.Path -configuration $configuration
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
        [string[]]$propertyArgs = @()
    )
    $purgeEnabled = $configuration -ieq 'DebugL'
    Write-Host "Invoke-BuildRange plan ($configuration) in $branchRootPath" -ForegroundColor Cyan
    Write-Host "  NuGet folder: $(Join-Path $branchRootPath 'nuget') (not wiped; Copy-NuGetPackages after each repository)" -ForegroundColor DarkGray
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
        if ($entry.Mode -eq 'dotnet') {
            Write-Host "    solution: $(Split-Path -Leaf $entry.Solution) ($($entry.Projects.Count) project(s))"
            foreach ($project in $entry.Projects) { Write-Host "      - $project" }
        }
        if (@($entry.PropertyArgs).Count -gt 0) { Write-Host "    msbuild: $($entry.PropertyArgs -join ' ')" }
        foreach ($note in $entry.Notes) { Write-Host "    note: $note" -ForegroundColor Yellow }
        if ($entry.Mode -ne 'none') {
            if ($purgeEnabled) {
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
         - no forced restore (`-f`): the implicit restore only re-extracts what was purged;
         - repositories with build.ps1, frontends and the zenon plug are built the same way
           Invoke-BuildAll builds them;
      2. (DebugL only) Copy-NuGetPackages -modifiedSince <build start> into <checkout>/nuget,
         i.e. only the packages this build (re)wrote - stale nupkgs of removed projects are
         left alone;
      3. (DebugL only) purges ~/.nuget/packages/<id>/999.0.0 for exactly those packages, so the
         next repository in the range restores the fresh ones from <checkout>/nuget.

    Unlike Invoke-BuildAll it does NOT wipe <checkout>/nuget, does NOT delete every
    meshmakers.* package from the global cache and does NOT kill dotnet processes.

    Stops at the first failing repository (fail fast) and prints the repository name and the
    tail of its log. Per-repository timings are printed at the end (or emitted with -Json).

    Refuses to start while processes run out of a repository in the range (e.g. services started
    by Start-Octo - their bin/DebugL output would be overwritten). Use -stopServices to send
    Stop-Octo first, or -ignoreRunningServices to build anyway.

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
    Before the first build, purge the ~/.nuget/packages/<id>/999.0.0 folders whose recorded
    SHA-512 differs from <checkout>/nuget/<id>.999.0.0.nupkg (e.g. extracted from the dev
    checkout's build). Without the switch they are only reported (warning, -WhatIf, -Json).

.PARAMETER WhatIf
    Print the plan (repositories, projects, global-cache folders to purge, running processes)
    and do nothing.

.PARAMETER Json
    Emit a single JSON document (plan under -WhatIf, per-repository results otherwise).

.EXAMPLE
    Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-asset-repo-services -WhatIf

.EXAMPLE
    Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services -include octo-asset-repo-services,octo-identity-services,octo-cli

.EXAMPLE
    Invoke-BuildRange -branch main -from octo-asset-repo-services -includeTests

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
        [switch]$Json
    )

    # Every early exit reports through the same path: Write-Error, LASTEXITCODE 1 and, with -Json,
    # a JSON document with success=false.
    $fail = {
        param([string]$message)
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

    $globalPackagesPath = Get-OctoGlobalPackagesPath
    $plan = @(Get-OctoBuildRangePlan -repos $repos -includeTests:$includeTests -globalPackagesPath $globalPackagesPath)

    # Per-repository MSBuild properties: keys accept the same name forms as -from/-to.
    $perRepo = @{}
    try {
        foreach ($repoKey in @($msbuildPropertiesPerRepo.Keys)) {
            $perRepo[(Resolve-OctoBuildRangeRepo -name ([string]$repoKey) -order $order).Name] = $msbuildPropertiesPerRepo[$repoKey]
        }
        Assert-OctoMsBuildPropertiesPerRepo -msbuildPropertiesPerRepo $perRepo -knownRepos @($order.Name)
    }
    catch { & $fail $_.Exception.Message; return }
    foreach ($entry in $plan) {
        $properties = Merge-OctoRepoMsBuildProperties -repoName $entry.Name -msbuildProperties $msbuildProperties -msbuildPropertiesPerRepo $perRepo
        $entry | Add-Member -NotePropertyName MsBuildProperties -NotePropertyValue $properties -Force
        $entry | Add-Member -NotePropertyName PropertyArgs -NotePropertyValue @(ConvertTo-OctoMsBuildPropertyArgs -properties $properties) -Force
    }
    $publishWarning = Get-OctoCkPublishDisabledWarning -repoNames @($plan | Where-Object { $_.Mode -eq 'dotnet' -and (Test-OctoCkPublishDisabled -properties $_.MsBuildProperties) } | ForEach-Object { $_.Name })
    if ($publishWarning) { Write-Warning $publishWarning }
    $runningProcesses = @(Get-OctoRunningRepoProcesses -repos @($plan | Where-Object { $_.Mode -ne 'none' }))
    $purgeEnabled = $configuration -ieq 'DebugL'
    $staleCache = @()
    if ($purgeEnabled) {
        $staleCache = @(Get-OctoStaleGlobalPackages -nugetPath (Join-Path $branchRootPath 'nuget') -globalPackagesPath $globalPackagesPath)
    }

    if ($WhatIfPreference) {
        if ($Json) {
            Write-OctoJson -Command 'Invoke-BuildRange' -Data ([ordered]@{
                    whatIf           = $true
                    branchRootPath   = $branchRootPath
                    configuration    = $configuration
                    nugetPath        = (Join-Path $branchRootPath 'nuget')
                    repositories     = @($plan | ForEach-Object {
                            [ordered]@{ repo = $_.Name; group = $_.Group; mode = $_.Mode; target = $_.Target; solution = $_.Solution; projects = @($_.Projects); purge = if ($purgeEnabled) { @($_.PurgePaths) } else { @() }; olderThanLastBuild = @($_.OlderPaths); msbuildProperties = @($_.PropertyArgs); notes = @($_.Notes) }
                        })
                    runningProcesses = @($runningProcesses | ForEach-Object { [ordered]@{ repo = $_.Repo; pid = $_.Pid; command = $_.Command } })
                    msbuildProperties = @($propertyArgs)
                    staleGlobalCache = @($staleCache | ForEach-Object { [ordered]@{ packageId = $_.PackageId; cachePath = $_.CachePath; reason = $_.Reason } })
                    purgeStaleCache  = [bool]$purgeStaleCache
                })
        }
        else {
            Write-OctoBuildRangePlan -plan $plan -branchRootPath $branchRootPath -configuration $configuration -runningProcesses $runningProcesses -staleCache $staleCache -purgeStaleCache:$purgeStaleCache -propertyArgs $propertyArgs
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
        Write-OctoBuildRangePlan -plan $plan -branchRootPath $branchRootPath -configuration $configuration -staleCache $staleCache -purgeStaleCache:$purgeStaleCache -propertyArgs $propertyArgs
        Write-Host ""
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
    $totalWatch = [System.Diagnostics.Stopwatch]::StartNew()

    foreach ($entry in $plan) {
        if (-not $Json) { Write-Host "==> $($entry.Name)" -ForegroundColor Cyan }
        # Packages written from here on are "produced by this build"; older ones in bin/DebugL are
        # stale (e.g. Sdk.Common.Web in octo-sdk after it moved to octo-communication-sdk) and are
        # neither copied nor purged. Pack is incremental, so an unchanged project keeps its old
        # nupkg - that is fine, its content did not change.
        $buildStartedAt = (Get-Date).AddSeconds(-1)
        $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $build = Invoke-OctoBuildRangeRepo -entry $entry -configuration $configuration -msbuildProperties $entry.MsBuildProperties -Json:$Json
        $buildWatch.Stop()

        $result = [ordered]@{
            repo            = $entry.Name
            success         = [bool]$build.Success
            buildDuration   = $buildWatch.Elapsed
            packageDuration = [TimeSpan]::Zero
            copiedCount     = 0
            purged          = @()
            staleSkipped    = @()
            logFile         = $build.LogFile
            msbuildProperties = @($entry.PropertyArgs)
        }

        if (-not $build.Success) {
            $results.Add($result)
            $failed = $entry
            break
        }

        if ($purgeEnabled -and $entry.Mode -ne 'none') {
            $packageWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $copy = Copy-NuGetPackages -directory $entry.Path -branch $branch -modifiedSince $buildStartedAt -Json | ConvertFrom-Json
            $copiedFiles = @($copy.data.files | Where-Object { $_ })
            $result.copiedCount = $copiedFiles.Count
            # Purge list = what this build actually produced (and was just copied), not the prediction.
            $packageIds = @($copiedFiles | ForEach-Object { Get-OctoPackageIdFromFile -fileName $_ })
            $purgeDirectories = @(Get-OctoGlobalPackageDirectories -packageIds $packageIds -globalPackagesPath $globalPackagesPath)
            $result.purged = @(Remove-OctoGlobalPackageVersions -directories $purgeDirectories)
            $result.staleSkipped = @(Get-OctoRepoPackageFiles -path $entry.Path | Where-Object { $_.LastWriteTime -lt $buildStartedAt } | ForEach-Object { $_.Name } | Sort-Object -Unique)
            $packageWatch.Stop()
            $result.packageDuration = $packageWatch.Elapsed
            if (-not $Json) {
                Write-Host "    copied $($result.copiedCount) package(s), purged $($result.purged.Count) global-cache folder(s), left $($result.staleSkipped.Count) unchanged/stale package(s) untouched" -ForegroundColor DarkGray
            }
        }
        $results.Add($result)
    }
    $totalWatch.Stop()

    if ($Json) {
        Write-OctoJson -Command 'Invoke-BuildRange' -Data ([ordered]@{
                branchRootPath = $branchRootPath
                configuration  = $configuration
                success        = ($null -eq $failed)
                failedRepo     = if ($failed) { $failed.Name } else { $null }
                repositories   = @($results | ForEach-Object {
                        [ordered]@{
                            repo                   = $_.repo
                            success                = $_.success
                            buildSeconds           = $_.buildDuration.TotalSeconds
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
            Write-Host $line -ForegroundColor $(if ($result.success) { 'Green' } else { 'Red' })
        }
        foreach ($skipped in @($plan | Select-Object -Skip $results.Count)) {
            Write-Host ("{0,-45} not built (stopped after failure)" -f $skipped.Name) -ForegroundColor DarkGray
        }
        Write-Host "---------------------------------"
        Write-Host "Total: $(Format-OctoDuration $totalWatch.Elapsed)"
    }

    if ($failed) {
        $global:LASTEXITCODE = 1
        $message = "Invoke-BuildRange: build of $($failed.Name) failed."
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
