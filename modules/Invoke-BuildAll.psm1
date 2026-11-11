# Which build path Compile-Repo takes for a repository. Shared with the -DryRun plan so the plan shows
# exactly what a real run would do.
function Get-RepoBuilder {
    param(
        [Parameter(Mandatory=$true)]
        [string]$path
    )

    if (Test-Path (Join-Path -Path $path -ChildPath "build.ps1")) {
        return "build.ps1"
    }
    $solutionFiles = @(Get-ChildItem -Path $path -File | Where-Object { $_.Extension -in '.sln','.slnx' })
    if ($solutionFiles.Count -eq 0) {
        return "none"
    }
    # The repo's own name. This used to read a dynamically scoped `$directory` from the caller, which
    # for the fixed-order slots was the last mm-* directory; the outcome is the same for every repo
    # built today, but the plan must not depend on caller variables.
    $repoName = Split-Path -Leaf $path
    if ($repoName -like "*frontend*") {
        return "Invoke-Publish"
    }
    if ($repoName -like "*octo-plug-zenon*") {
        return "Invoke-BuildZenonPlug"
    }
    return "Invoke-Build"
}

function Compile-Repo {
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$path,
        [Parameter(Mandatory=$true)]
        [string]$configuration,
        # Lane settings from Get-OctoLaneBuildSettings; $null = legacy behaviour.
        $laneSettings = $null,
        # Effective MSBuild properties for this repository (-msbuildProperties merged with -msbuildPropertiesPerRepo).
        [hashtable]$msbuildProperties = @{},
        # -EventsFile state of Invoke-BuildAll ($null = no events).
        $events = $null,
        # Invoke-BuildAll decided about the remote CK catalogs for the whole run (AB#8831): the repository's own
        # Invoke-Build must not read them again - neither after -refreshCatalogs nor after a read that failed.
        [switch]$catalogsDecided
    )

    # Isolated lane only: repos without their own <RestoreSources> would restore from the user-level
    # NuGet.Config feed, which belongs to another lane. Give them the lane feed for this repo only.
    $savedEnvironment = $null
    if ($null -ne $laneSettings) {
        $restoreSourcesOverride = Get-OctoRepoRestoreSourcesOverride -repositoryPath $path -laneSettings $laneSettings
        if ($null -ne $restoreSourcesOverride) {
            Write-Host "RestoreSources for $path -> $restoreSourcesOverride" -ForegroundColor DarkGray
            $savedEnvironment = Set-OctoBuildEnvironment -environment @{ RestoreSources = $restoreSourcesOverride }
        }
    }
    try {
        return Compile-RepoCore -branch $branch -path $path -configuration $configuration -msbuildProperties $msbuildProperties -events $events -catalogsDecided:$catalogsDecided
    }
    finally {
        Restore-OctoBuildEnvironment -saved $savedEnvironment
    }
}

function Compile-RepoCore {
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$path,
        [Parameter(Mandatory=$true)]
        [string]$configuration,
        [hashtable]$msbuildProperties = @{},
        $events = $null,
        [switch]$catalogsDecided
    )

    $builder = Get-RepoBuilder -path $path
    if ($msbuildProperties.Count -gt 0 -and $builder -in @('build.ps1', 'Invoke-Publish', 'Invoke-BuildZenonPlug')) {
        Write-Warning "-msbuildProperties is not applied to $path ($builder build)"
    }

    # Check if a custom build script exists in the repository
    if ($builder -eq "build.ps1") {
        $buildScript = Join-Path -Path $path -ChildPath "build.ps1"
        Write-Host "Found custom build script in $path" -ForegroundColor Cyan
        & $buildScript -configuration $configuration
        return $LASTEXITCODE -eq 0
    }

    # Check if a solution file exists. Match both the legacy .sln and the modern
    # XML .slnx format (dotnet 8+) — octo-communication-sdk uses the latter, and
    # a .sln-only filter was silently skipping the whole repo (return $true with
    # no build), so dependent repos (mesh-adapter etc.) tried to restore against
    # an absent Sdk.Adapters / Sdk.Pipeline package in ../nuget/.
    if ($builder -eq "none") {
        Write-Host "No solution file found in directory $( $path )" -ForegroundColor Yellow
        return $true;
    }

    [Boolean]$state = $false;
    if ($builder -eq "Invoke-Publish") {
        # frontends has to be published to build the angular app
        # -laneIsolation Off: Invoke-BuildAll/Compile-Repo already set the lane environment for this repo;
        # the nested cmdlet must neither recompute nor override it (e.g. under -laneIsolation Off).
        Invoke-Publish -repositoryPath $path -configuration $configuration -laneIsolation Off
        $state = $Global:LASTEXITCODE -eq 0
    }
    elseif ($builder -eq "Invoke-BuildZenonPlug") {
        Invoke-BuildZenonPlug -repositoryPath $path -configuration $configuration
        $state = $Global:LASTEXITCODE -eq 0
    }
    else {
        # -refreshCatalogs = "do not decide about the catalogs": the run did (the property is in $msbuildProperties or not).
        Invoke-Build -repositoryPath $path -configuration $configuration -laneIsolation Off -msbuildProperties $msbuildProperties -refreshCatalogs:$catalogsDecided
        $state = $Global:LASTEXITCODE -eq 0
    }

    if ($configuration -ieq "DebugL" -And $state -eq $true) {
        if ($null -ne $events -and $events.Path) {
            $events.Phase = 'packages'
            Write-OctoBuildEvent -Path $events.Path -Command 'Invoke-BuildAll' -Event 'phase' -Data ([ordered]@{ repo = (Split-Path -Leaf $path); phase = 'packages' })
        }
        Copy-NuGetPackages -directory $path -branch $branch
    }

    return $state;
}

<#
.SYNOPSIS
    The ordered list of repositories Invoke-BuildAll builds (and -DryRun prints).

.DESCRIPTION
    Thin adapter over Get-OctoBuildOrder (OctoBuildOrder.psm1), the build order shared with
    Invoke-BuildRange. Edit the pinned lists there, not here.
#>
function Get-BuildAllPlan {
    param(
        [Parameter(Mandatory=$true)]
        [string]$branchRootPath,
        [Boolean]$excludeFrontend = $false,
        [Boolean]$excludeAdditional = $false
    )

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-OctoBuildOrder -branchRootPath $branchRootPath -excludeFrontend $excludeFrontend -excludeAdditional $excludeAdditional)) {
        $plan.Add([PSCustomObject][ordered]@{ name = $entry.Name; path = $entry.Path; phase = $entry.Group })
    }
    return $plan
}

<#
.SYNOPSIS
    Builds all repositories of a lane checkout in dependency order (full chain).

.DESCRIPTION
    Order comes from Get-OctoBuildOrder (OctoBuildOrder.psm1). In DebugL it first wipes <lane>/nuget
    and the 999.0.0 packages of the lane's package caches (Remove-OctoLaneNuGetPackages), then builds each repository with a forced restore (Invoke-Build)
    and copies its packages into <lane>/nuget. Lane isolation: see Get-OctoLaneBuildSettings.
    For partial rebuilds use Invoke-BuildRange.

.PARAMETER configuration
    Build configuration (default Release; DebugL for local development).

.PARAMETER branch
    Lane checkout to build (e.g. main, dev).

.PARAMETER excludeAdditional
    Build only mm-* and the pinned octo-* repositories.

.PARAMETER excludeFrontend
    Skip octo-frontend-* repositories.

.PARAMETER laneIsolation
    Auto (default) / On / Off - see Get-OctoLaneBuildSettings.

.PARAMETER msbuildProperties
    Extra MSBuild global properties (-p:Name=Value) for the dotnet restore/build of EVERY
    repository (e.g. @{ ContinuousIntegrationBuild = 'true' }). Global properties override values
    set in project files. Not applied to build.ps1 / frontend / zenon builds (a warning is printed).
    Do not use it for OctoPublishCkModel: that would stop every CK model of the run from being
    published into the local catalog (downstream CK compiles then see stale models) - use
    -msbuildPropertiesPerRepo for the one repository instead. A warning is printed when
    OctoPublishCkModel=false applies to more than one repository.

.PARAMETER msbuildPropertiesPerRepo
    Extra MSBuild properties for single repositories, keyed by repository name; they override
    -msbuildProperties for that repository, e.g.
    @{ 'octo-identity-services' = @{ OctoPublishCkModel = 'false' } }.

.PARAMETER DryRun
    Print the plan (order, builder, lane environment, restore sources, MSBuild properties) and exit.

.PARAMETER skipKill
    Do not call Invoke-KillDotnet (for callers that stop the lane's processes themselves).
    Without it Invoke-BuildAll stops only the dotnet processes of this lane (Invoke-KillDotnet
    -branchRootPath; Windows only, other OSes report them), never other lanes. On Windows a DebugL run
    whose purge includes the global package cache (legacy lane, e.g. main) runs `dotnet build-server
    shutdown` right before the purge (compiler servers can lock 999.0.0 analyzer DLLs there).
    For the whole run MSBUILDDISABLENODEREUSE=1 is set (restored afterwards), so no reused MSBuild node keeps
    files locked. On Windows UseSharedCompilation=false is set as well: a compiler server keeps the analyzer DLLs
    of 999.0.0 packages open there. macOS and Linux keep the shared compiler server (an open file does not block
    a delete there, and a build without it compiles 1.7 to 2.5 times slower - AB#8831).

.PARAMETER EventsFile
    Append build progress events (plan, repoStart, phase build/packages, repoDone, done) to this file,
    see Write-OctoBuildEvent. Not written by -DryRun. The -Json output is not affected.

.PARAMETER Json
    Emit one JSON document with per-repository results.

.EXAMPLE
    Invoke-BuildAll -branch dev -configuration DebugL -excludeFrontend $true -DryRun

.EXAMPLE
    Invoke-BuildAll -branch main -configuration DebugL -excludeFrontend $true -msbuildPropertiesPerRepo @{ 'octo-identity-services' = @{ OctoPublishCkModel = 'false' } }
#>
function Invoke-BuildAll {
    param(
        [string]$configuration = "Release",
        [string]$branch = "",
        [Boolean]$excludeAdditional = $false,
        [Boolean]$excludeFrontend = $false,
        # Lane isolation (see Get-OctoLaneBuildSettings): Auto isolates every lane whose Octo.User.props
        # declares RestorePackagesPath; a lane without it keeps the legacy behaviour (shared cache).
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        [hashtable]$msbuildProperties = @{},
        [hashtable]$msbuildPropertiesPerRepo = @{},
        # Print the computed plan (order, builder, lane environment, restore sources) and exit: no dotnet
        # process is killed, no package is deleted, nothing is built.
        [switch]$DryRun,
        # AB#7974: skip the sync of private-only intermediate CK versions into <lane>/.octo/local-catalog (DebugL).
        [switch]$skipCkSync,
        # AB#8831: let every CK compile refresh the remote CK catalogs itself (as before). Default: the run reads them
        # at most once, before the first repository that uses a construction kit (OctoCkCatalogRefresh.psm1).
        [switch]$refreshCatalogs,
        # Do not call Invoke-KillDotnet (the caller stops the lane's processes itself).
        [switch]$skipKill,
        # Progress events, one JSON line each (Write-OctoBuildEvent). Not written by -DryRun.
        [string]$EventsFile = '',
        [switch]$Json
    )

    # The run lives in Invoke-BuildAllCore; this wrapper guarantees the closing `done` event of
    # -EventsFile, also on an early exit or a throw.
    $forward = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'EventsFile') { $forward[$key] = $PSBoundParameters[$key] }
    }
    $events = New-OctoBuildEventState -Path $EventsFile -Command 'Invoke-BuildAll'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-BuildAllCore @forward -events $events
    }
    finally {
        # Also after a throw: repoDone(success=false) of the running repository, then done. Best-effort on Ctrl+C.
        $watch.Stop()
        if (-not $DryRun) { Complete-OctoBuildEvents -State $events -ElapsedSeconds $watch.Elapsed.TotalSeconds }
    }
}

# Separate so tests can take the Windows path on any OS (Windows PowerShell 5.1: $IsWindows is $null).
function Test-OctoBuildAllWindows {
    return ($IsWindows -ne $false)
}

# The builder of Get-RepoBuilder in the mode vocabulary of Invoke-BuildRange's plan (events).
function Get-RepoBuildMode {
    param([string]$builder)
    switch ($builder) {
        'build.ps1' { return 'script' }
        'Invoke-Publish' { return 'frontend' }
        'Invoke-BuildZenonPlug' { return 'zenon' }
        'none' { return 'none' }
        default { return 'dotnet' }
    }
}

function Invoke-BuildAllCore {
    # The body of Invoke-BuildAll (see its help); $events is the -EventsFile state shared with the wrapper.
    param(
        [string]$configuration = "Release",
        [string]$branch = "",
        [Boolean]$excludeAdditional = $false,
        [Boolean]$excludeFrontend = $false,
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        [hashtable]$msbuildProperties = @{},
        [hashtable]$msbuildPropertiesPerRepo = @{},
        [switch]$DryRun,
        [switch]$skipCkSync,
        [switch]$refreshCatalogs,
        [switch]$skipKill,
        [hashtable]$events = @{},
        [switch]$Json
    )

    $eventsPath = [string]$events.Path
    $emit = {
        param([string]$name, [System.Collections.IDictionary]$data)
        Write-OctoBuildEvent -Path $eventsPath -Command 'Invoke-BuildAll' -Event $name -Data $data
    }

    # Validate early so a typo fails before anything is wiped or killed.
    try { [void](ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties) }
    catch { Write-Error $_.Exception.Message; return }

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # `$rootPath` is set in profile.ps1 to point at the branch checkout itself
    # (`.../meshmakers/<branch>/`), so a `-branch <name>` argument that matches the leaf segment
    # would build a non-existent `.../<branch>/<branch>/` path. Normalise that here so callers can
    # pass `-branch main` from inside the `main` checkout without breaking.
    if ($branch -ne "") {
        $rootLeaf = Split-Path -Leaf ([IO.Path]::GetFullPath($rootPath))
        if ($rootLeaf -ieq $branch) {
            if (-not $Json) {
                Write-Host "Branch '$branch' already matches root leaf — using root path directly" -ForegroundColor DarkGray
            }
            $branch = ""
        }
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    # Get all directories starting with "octo-" and "mm-""
    $octoDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $mmDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"

    if ($excludeFrontend -eq $true){
        $octoDirectories = $octoDirectories | Where-Object { $_.Name -notlike "octo-frontend-*" }
    }

    $laneSettings = Get-OctoLaneBuildSettings -laneRootPath $branchRootPath -laneIsolation $laneIsolation
    $plan = Get-BuildAllPlan -branchRootPath $branchRootPath -excludeFrontend $excludeFrontend -excludeAdditional $excludeAdditional

    # Per-repository MSBuild properties: validated against the plan before anything is wiped or killed.
    try { Assert-OctoMsBuildPropertiesPerRepo -msbuildPropertiesPerRepo $msbuildPropertiesPerRepo -knownRepos @($plan | ForEach-Object { $_.name }) }
    catch { Write-Error $_.Exception.Message; return }
    $repoProperties = @{}
    foreach ($entry in $plan) {
        $repoProperties[$entry.name] = Merge-OctoRepoMsBuildProperties -repoName $entry.name -msbuildProperties $msbuildProperties -msbuildPropertiesPerRepo $msbuildPropertiesPerRepo
    }
    $publishWarning = Get-OctoCkPublishDisabledWarning -repoNames @($plan | Where-Object { Test-OctoCkPublishDisabled -properties $repoProperties[$_.name] } | ForEach-Object { $_.name })
    if ($publishWarning) { Write-Warning $publishWarning }

    # Run environment: the lane's plus no node reuse and no shared compiler server for the whole run, so no
    # MSBuild node or VBCSCompiler of this run keeps files locked (Invoke-KillDotnet no longer kills them).
    $runEnvironment = [ordered]@{}
    foreach ($name in @($laneSettings.environment.Keys)) { $runEnvironment[$name] = $laneSettings.environment[$name] }
    $runEnvironment['MSBUILDDISABLENODEREUSE'] = '1'
    # The compiler server only locks files on Windows; elsewhere it stays on (AB#8831: 1.7-2.5x compile time without it).
    if (Test-OctoBuildAllWindows) { $runEnvironment['UseSharedCompilation'] = 'false' }
    # Windows, DebugL, purge that includes the global package cache (legacy lane, e.g. main): a running
    # compiler server / MSBuild node can hold meshmakers.*/999.0.0 analyzer DLLs there and make the purge
    # fail. Then `dotnet build-server shutdown` runs right before the purge (servers restart on demand).
    $shutdownBuildServer = ($configuration -ieq "DebugL") -and (Test-OctoBuildAllWindows) -and -not $laneSettings.isolated

    if ($DryRun) {
        $planEntries = @(foreach ($entry in $plan) {
            $builder = Get-RepoBuilder -path $entry.path
            [ordered]@{
                order          = $plan.IndexOf($entry) + 1
                repo           = $entry.name
                phase          = $entry.phase
                builder        = $builder
                # Override only matters where something is restored (DebugL, and a repo that actually builds).
                restoreSources = if ($configuration -ieq "DebugL" -and $builder -ne "none") { Get-OctoRepoRestoreSourcesOverride -repositoryPath $entry.path -laneSettings $laneSettings } else { $null }
                msbuildProperties = @(ConvertTo-OctoMsBuildPropertyArgs -properties $repoProperties[$entry.name])
            }
        })
        $data = [ordered]@{
            dryRun        = $true
            branch        = $branch
            branchRoot    = $branchRootPath
            configuration = $configuration
            lane          = $laneSettings
            runEnvironment = $runEnvironment
            killDotnet    = if ($skipKill) { 'skipped (-skipKill)' } else { "lane processes only ($branchRootPath)" }
            buildServerShutdown = [bool]$shutdownBuildServer
            packageCachesToPurge = @(if ($configuration -ieq 'DebugL') { Remove-OctoLaneNuGetPackages -laneSettings $laneSettings -WhatIf })
            repositories  = $planEntries
        }
        if ($Json) {
            Write-OctoJson -Command 'Invoke-BuildAll' -Data $data
            return
        }
        Write-Host "Dry run - nothing is killed, deleted or built" -ForegroundColor Yellow
        Write-Host "Branch root:     $branchRootPath"
        Write-Host "Configuration:   $configuration"
        Write-Host "Lane isolated:   $($laneSettings.isolated) ($($laneSettings.reason))"
        foreach ($name in $laneSettings.environment.Keys) {
            Write-Host "  env $name=$($laneSettings.environment[$name])"
        }
        Write-Host "Run environment: $(@($runEnvironment.Keys | Where-Object { $_ -in 'MSBUILDDISABLENODEREUSE', 'UseSharedCompilation' } | ForEach-Object { "$_=$($runEnvironment[$_])" }) -join ', ') (whole run, restored afterwards)"
        Write-Host "Kill dotnet:     $(if ($skipKill) { 'skipped (-skipKill)' } else { "only processes of this lane ($branchRootPath)" })"
        if ($shutdownBuildServer) { Write-Host "Build server:    dotnet build-server shutdown before the purge (Windows; the purge includes the global package cache)" }
        if ($configuration -ieq 'DebugL') {
            foreach ($cache in @(Remove-OctoLaneNuGetPackages -laneSettings $laneSettings -WhatIf)) {
                Write-Host "Purges meshmakers.*/999.0.0 in: $cache"
            }
        }
        foreach ($entry in $planEntries) {
            $suffix = if ($entry.restoreSources) { "  RestoreSources=$($entry.restoreSources)" } else { "" }
            if ($entry.msbuildProperties.Count -gt 0) { $suffix += "  $($entry.msbuildProperties -join ' ')" }
            Write-Host ("{0,3}. {1,-45} {2,-19} {3}{4}" -f $entry.order, $entry.repo, $entry.phase, $entry.builder, $suffix)
        }
        return
    }

    if (-not $Json) {
        Write-Host "Building all repositories in branch $branch with configuration $configuration" -ForegroundColor Green
        if ($laneSettings.isolated) {
            Write-Host "Lane isolation: $($laneSettings.reason)" -ForegroundColor Yellow
            foreach ($name in $laneSettings.environment.Keys) {
                Write-Host "  env $name=$($laneSettings.environment[$name])" -ForegroundColor Yellow
            }
        }
    }

    # Refusals before the first repository emit only `done` (failedStep preflight) - check before the plan event.
    # Check if any repositories were found
    $octoCount = if ($octoDirectories) { @($octoDirectories).Count } else { 0 }
    $mmCount = if ($mmDirectories) { @($mmDirectories).Count } else { 0 }
    if ($octoCount -eq 0 -and $mmCount -eq 0) {
        Write-Warning "No octo-* or mm-* directories found in '$branchRootPath'"
        return
    }

    $repoModes = @{}
    foreach ($entry in $plan) { $repoModes[$entry.name] = Get-RepoBuildMode -builder (Get-RepoBuilder -path $entry.path) }
    $repoCount = $plan.Count
    & $emit 'plan' ([ordered]@{ repos = @($plan | ForEach-Object { [ordered]@{ repo = $_.name; mode = $repoModes[$_.name] } }); count = $repoCount })

    # Stop the dotnet processes of this lane (file locks on Windows) - never other lanes, a local daemon
    # or the shared build server. -skipKill: the caller stopped them itself.
    # A failed lane cleanup (a process that could not be stopped, or a refused lane folder) ends the run before
    # anything is built or purged: done reports failedStep "cleanup", -Json a failed document.
    # Returns the failure message (and reports it) or $null; the caller emits nothing else and returns.
    $cleanupFailure = {
        if ($LASTEXITCODE -eq 0) { return $null }
        $events.FailedStep = 'cleanup'
        return "Invoke-BuildAll: the lane cleanup (Invoke-KillDotnet -branchRootPath $branchRootPath) failed with exit code $LASTEXITCODE; nothing was built."
    }
    $reportCleanupFailure = {
        param([string]$message)
        if ($Json) {
            Write-OctoJson -Command 'Invoke-BuildAll' -Data ([ordered]@{ branch = $branch; configuration = $configuration; success = $false; error = $message; repositories = @() })
        }
        Write-Error $message -ErrorAction Continue
    }
    if (-not $skipKill) {
        $global:LASTEXITCODE = 0   # a stale exit code of an earlier native call must not count as a cleanup failure
        [void](Invoke-KillDotnet -branchRootPath $branchRootPath -Json:$Json)
        $failure = & $cleanupFailure
        if ($failure) { & $reportCleanupFailure $failure; return }
    }


    # Create a dictionary that contains the directory name and a status weather the build was successful or not
    $allStatus = [ordered]@{}

    # Start a timer
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()

    $purgeErrors = @()
    if ($configuration -ieq "DebugL"){
        # Again right before the package folders are wiped (lane processes only, see above).
        if (-not $skipKill) {
            $global:LASTEXITCODE = 0   # a stale exit code of an earlier native call must not count as a cleanup failure
            [void](Invoke-KillDotnet -branchRootPath $branchRootPath -Json:$Json)
            $failure = & $cleanupFailure
            if ($failure) { & $reportCleanupFailure $failure; return }
        }

        # Delete all nuget packages in the octo mesh nuget folder
        $branchNugetPath = Join-Path -Path $branchRootPath -ChildPath "nuget"
        # Ensure the nuget directory exists
        if (!(Test-Path $branchNugetPath)) {
            Write-Host "Creating directory $branchNugetPath" -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $branchNugetPath | Out-Null
        }
        # Errors are still shown, and collected so a reset that left locked files behind is not reported as success.
        Get-ChildItem -Path $branchNugetPath -File | Remove-Item -Force -ErrorVariable +purgeErrors

        # Purge the meshmakers.*/999.0.0 folders of every package cache this lane restores into
        # (Get-OctoRangePackageCaches): an isolated lane (dev) only <lane>/.nuget-packages; the main lane
        # also the global cache (NUGET_PACKAGES or ~/.nuget/packages) - it has no <lane>/.nuget-packages
        # unless Octo.User.props sets RestorePackagesPath. Never the whole cache, never another lane's.
        # -Json is forwarded and the nested emits swallowed (one machine-readable document).
        if ($shutdownBuildServer) {
            if (-not $Json) { Write-Host "Shutdown the dotnet build servers (they may lock 999.0.0 analyzers in the global package cache; they restart on demand)" -ForegroundColor Yellow }
            dotnet build-server shutdown *>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                # Not fatal: the servers restart on demand. But the purge below may now fail on locked files.
                Write-Warning "dotnet build-server shutdown exited with code $LASTEXITCODE; the package purge may fail on locked files."
            }
        }
        # The errors are still shown, and collected (-ErrorVariable) so a purge that left files behind stops the run.
        Remove-OctoLaneNuGetPackages -laneSettings $laneSettings -Json:$Json -ErrorVariable +purgeErrors | Out-Null

        # A reset that left packages behind (locked files on Windows) would build against stale 999.0.0 packages:
        # stop before building; done reports failedStep "purge".
        if ($purgeErrors.Count -gt 0) {
            $events.FailedStep = 'purge'
            & $reportCleanupFailure "Invoke-BuildAll: the DebugL package purge failed ($($purgeErrors.Count) error(s), first: $($purgeErrors[0])); nothing was built. Stop the processes that lock the files and run it again."
            return
        }
    }

    # Lane environment (NUGET_PACKAGES, MSBUILDDISABLENODEREUSE) for the whole run; empty for the legacy
    # lane. Restored afterwards so the session is left as it was found.
    $repoLaneSettings = if ($configuration -ieq "DebugL") { $laneSettings } else { $null }
    $savedEnvironment = Set-OctoBuildEnvironment -environment $runEnvironment
    $repoIndex = 0
    $firstFailedRepo = $null
    $runError = $null
    # AB#8831: one read of the remote CK catalogs for the whole run (see OctoCkCatalogRefresh.psm1).
    $catalogRun = [ordered]@{ decided = $false; usable = $false; mode = $(if ($refreshCatalogs) { 'perCompile' } else { 'notNeeded' }); seconds = 0.0; detail = $null; repo = $null }
    try {
        foreach ($entry in $plan) {
            $repoIndex++
            $events.Repo = $entry.name
            $events.Index = $repoIndex
            $events.Count = $repoCount
            $events.Phase = 'build'
            $events.RepoDone = $false
            $events.RepoWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $events.LogFile = if ($repoModes[$entry.name] -eq 'dotnet') { Join-Path $entry.path 'Invoke-Build.log' } else { $null }
            & $emit 'repoStart' ([ordered]@{ repo = $entry.name; index = $repoIndex; count = $repoCount })
            # Restore and build are one step here (Invoke-Build); the package copy is the 'packages' phase (DebugL).
            & $emit 'phase' ([ordered]@{ repo = $entry.name; phase = 'build' })
            $repoStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
            # AB#7974: the private catalog's intermediate versions of the repo's ckLanguage 2 models into the lane's
            # local catalog before its CK compile gate runs (warning + fix command on failure, never a build stop).
            if ($configuration -ieq "DebugL" -and -not $skipCkSync) {
                [void](Sync-OctoCkIntermediateVersions -repositoryPath $entry.path -localCatalogRoot (Join-Path $branchRootPath '.octo/local-catalog') -Quiet:$Json)
            }
            $buildProperties = $repoProperties[$entry.name]
            $catalogSeconds = 0.0
            if (-not $refreshCatalogs -and $repoModes[$entry.name] -eq 'dotnet' -and -not (Test-OctoCatalogPropertySet -properties $buildProperties) -and (Test-OctoRepoUsesCk -path $entry.path)) {
                if (-not $catalogRun.decided) {
                    & $emit 'phase' ([ordered]@{ repo = $entry.name; phase = 'catalogs' })
                    $read = Initialize-OctoRunCatalogs -laneRootPath $branchRootPath
                    $catalogRun.decided = $true; $catalogRun.usable = [bool]$read.usable; $catalogRun.mode = $read.mode
                    $catalogRun.seconds = [double]$read.seconds; $catalogRun.detail = $read.detail; $catalogRun.repo = $entry.name
                    $catalogSeconds = [double]$read.seconds
                    if (-not $Json) { Write-Host "CK catalogs: $($read.mode) - $($read.detail)" -ForegroundColor $(if ($read.usable) { 'DarkGray' } else { 'Yellow' }) }
                }
                if ($catalogRun.usable) { $buildProperties = Add-OctoCatalogProperty -properties $buildProperties }
            }
            # A failed package copy (Copy-NuGetPackages throws) leaves the dependent repositories without the new
            # packages: the repository counts as failed and the run stops.
            $copyError = $null
            try {
                [Boolean]$buildStatus = Compile-Repo -branch $branch -path $entry.path -configuration $configuration -laneSettings $repoLaneSettings -msbuildProperties $buildProperties -events $events -catalogsDecided
            }
            catch {
                if ($_.FullyQualifiedErrorId -notlike 'OctoPackageCopyFailed*') { throw }
                $buildStatus = $false
                $copyError = "$($entry.name): $($_.Exception.Message)"
            }
            $repoStopWatch.Stop()
            $allStatus.Add($entry.name, @{ Success = $buildStatus; Duration = $repoStopWatch.Elapsed })
            # Invoke-BuildAll measures one duration per repository and copies without a per-repository
            # count: buildSeconds = seconds, copied/purged = null (the lane caches are purged up front).
            & $emit 'repoDone' ([ordered]@{
                    repo           = $entry.name
                    index          = $repoIndex
                    count          = $repoCount
                    success        = $buildStatus
                    seconds        = $repoStopWatch.Elapsed.TotalSeconds
                    buildSeconds   = $repoStopWatch.Elapsed.TotalSeconds
                    testSeconds    = 0
                    packageSeconds = 0
                    catalogSeconds = $catalogSeconds
                    copied         = $null
                    purged         = $null
                    logFile        = $events.LogFile
                })
            $events.RepoDone = $true
            if (-not $buildStatus -and -not $firstFailedRepo) { $firstFailedRepo = $entry.name }
            if ($copyError) { $runError = $copyError; break }
        }
    }
    finally {
        Restore-OctoBuildEnvironment -saved $savedEnvironment
    }
    # Invoke-BuildAll does not stop at a failing repository; done reports the first one. A DebugL reset
    # whose purge left files behind (locked on Windows) is not a success either: failedStep "purge".
    $events.Success = ($null -eq $firstFailedRepo)
    $events.FailedRepo = $firstFailedRepo
    $events.FailedStep = if ($runError) { 'packages' } elseif ($firstFailedRepo) { 'build' } else { $null }
    $events.Completed = $true

    # Print the status of all builds
    
    # Store the count of all repositories in a variable
    $repositoryCount = $octoDirectories.Count + $mmDirectories.Count
    
    # Calculate percentage of successful builds
    $successfulBuilds = $allStatus.Values | Where-Object { $_.Success -eq $true }
    $percentageSuccessful = ($successfulBuilds.Count / $repositoryCount) * 100

    if ($Json) {
        $repoEntries = @(foreach ($key in $allStatus.Keys) {
            [ordered]@{
                repo            = $key
                success         = [bool]$allStatus[$key].Success
                durationSeconds = $allStatus[$key].Duration.TotalSeconds
            }
        })
        $data = @{
            branch        = $branch
            configuration = $configuration
            success       = [bool]$events.Success
            repositories  = $repoEntries
            summary       = [ordered]@{
                total             = $repositoryCount
                succeeded         = $successfulBuilds.Count
                failed            = $repositoryCount - $successfulBuilds.Count
                percentSuccessful = $percentageSuccessful
                elapsedSeconds    = $stopWatch.Elapsed.TotalSeconds
            }
        }
        $data.catalogs = [ordered]@{ mode = $catalogRun.mode; usable = [bool]$catalogRun.usable; seconds = $catalogRun.seconds; detail = $catalogRun.detail; repo = $catalogRun.repo }
        if ($runError) { $data.error = "Package copy failed, the run stopped: $runError" }
        Write-OctoJson -Command 'Invoke-BuildAll' -Data $data
        if ($runError) { Write-Error $data.error }
        return
    }

    if ($runError) { Write-Error "Package copy failed, the run stopped: $runError" }
    Write-Host "Summary:"
    Write-Host "---------------------------------"
    Write-Host "Build branch $branch with configuration $configuration"
    Write-Host "Building of $repositoryCount repositories took $($stopWatch.Elapsed.TotalSeconds) seconds"
    Write-Host "Percentage of successful builds: $percentageSuccessful%"
    Write-Host " "
    Write-Host "---------------------------------"
    Write-Host " "

    foreach ($key in $allStatus.Keys) {
        $entry = $allStatus[$key]
        $duration = $entry.Duration
        $timeStr = ""
        if ($duration.TotalMinutes -ge 1) {
            $timeStr = "{0:N0}m {1:N0}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
        }
        else {
            $timeStr = "{0:N1}s" -f $duration.TotalSeconds
        }
        if ($entry.Success) {
            Write-Host "Build of ${key} was successful ($timeStr)" -ForegroundColor Green
        }
        else {
            Write-Host "Build of ${key} failed ($timeStr)" -ForegroundColor Red
        }
    }
}


Export-ModuleMember -Function @('Invoke-BuildAll')