<#
.SYNOPSIS
    Restores (forced) and builds the solution in one repository, with the lane isolation of Invoke-BuildAll.

.DESCRIPTION
    A failed `dotnet restore` stops the run: the build is not started and the result is
    success=false with the restore's exit code (it used to continue and report the build's result).

.PARAMETER configuration
    Build configuration (default Release; DebugL for local development).

.PARAMETER repositoryPath
    Repository root containing the solution. A relative path follows the PowerShell location (Set-Location), not
    the folder pwsh was started in; it is resolved once, before the lane is chosen (AB#8954). The build refuses
    when the repository does not lie under the lane root that was found.

.PARAMETER laneIsolation
    Auto (default) / On / Off - see Get-OctoRepositoryBuildEnvironment.

.PARAMETER msbuildProperties
    Extra MSBuild global properties passed as -p:Name=Value to restore and build of this
    repository (they override values set in the projects), e.g. @{ OctoPublishCkModel = 'false' }
    to keep this repository's CK model projects from publishing into the local catalog.

.PARAMETER DryRun
    Print the lane environment this build would use and exit without running dotnet.

.PARAMETER EventsFile
    Append build progress events (one JSON object per line: plan, repoStart, phase restore/build,
    repoDone, done) to this file while the build runs - see Write-OctoBuildEvent. `done` is also
    written when the build throws. Not written by -DryRun. The -Json output is not affected.

.EXAMPLE
    Invoke-Build -repositoryPath ./octo-identity-services -configuration DebugL -msbuildProperties @{ OctoPublishCkModel = 'false' }
#>
function Invoke-Build {
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
        # Lane isolation, same rules as Invoke-BuildAll (see Get-OctoRepositoryBuildEnvironment).
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        # Print the lane environment this build would use and exit without running dotnet.
        [switch]$DryRun,
        [hashtable]$msbuildProperties = @{},
        # AB#8831: let every CK compile refresh the remote CK catalogs itself (as before). Default: a repository that
        # uses a construction kit reads them at most once (not at all while the caches are younger than 30 minutes)
        # and builds with OctoRefreshRemoteCatalogs=false - see OctoCkCatalogRefresh.psm1. A caller that passes
        # OctoRefreshRemoteCatalogs in -msbuildProperties (Invoke-BuildAll does) decides itself.
        [switch]$refreshCatalogs,
        # Progress events, one JSON line each (Write-OctoBuildEvent).
        [string]$EventsFile = '',
        [switch]$Json
    )

    # AB#8954: resolve once, against the PowerShell location. [IO.Path]::GetFullPath would use the process
    # directory, so `Set-Location wt-<env>/<repo>; Invoke-Build -repositoryPath .` in a pwsh started in
    # branches/main built in branches/main.
    $repositoryPath = Resolve-OctoLocationPath -path $repositoryPath

    if ($DryRun -or [string]::IsNullOrWhiteSpace($EventsFile)) {
        Invoke-BuildMain -configuration $configuration -repositoryPath $repositoryPath -laneIsolation $laneIsolation -DryRun:$DryRun -msbuildProperties $msbuildProperties -refreshCatalogs:$refreshCatalogs -Json:$Json
        return
    }

    # Shared with Invoke-BuildCore, which writes plan/repoStart/phase/repoDone once the repository is
    # found and records the result; a run that stops before (missing folder, invalid arguments) gets
    # only `done` with failedStep "preflight" (Complete-OctoBuildEvents).
    $events = New-OctoBuildEventState -Path $EventsFile -Command 'Invoke-Build'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-BuildMain -configuration $configuration -repositoryPath $repositoryPath -laneIsolation $laneIsolation -msbuildProperties $msbuildProperties -refreshCatalogs:$refreshCatalogs -events $events -Json:$Json
    }
    finally {
        # Also after a throw: repoDone(success=false) once the repository had started, then done. Best-effort on Ctrl+C.
        $watch.Stop()
        Complete-OctoBuildEvents -State $events -ElapsedSeconds $watch.Elapsed.TotalSeconds
    }
}

function Invoke-BuildMain {
    param(
        [string]$configuration,
        [string]$repositoryPath,
        [string]$laneIsolation,
        [switch]$DryRun,
        [hashtable]$msbuildProperties = @{},
        [switch]$refreshCatalogs,
        $events = $null,
        [switch]$Json
    )

    if (-not $DryRun -and -not (Test-Path -LiteralPath $repositoryPath -PathType Container)) {
        # Refused before anything runs (events: only `done` with failedStep "preflight").
        $message = "Invoke-Build: repository folder $repositoryPath does not exist."
        $Global:LASTEXITCODE = 1
        if ($Json) {
            Write-OctoJson -Command 'Invoke-Build' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ configuration = $configuration; error = $message })
        }
        Write-Error $message
        return
    }

    $propertyArgs = @(ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties)
    $buildEnvironment = Get-OctoRepositoryBuildEnvironment -repositoryPath $repositoryPath -configuration $configuration -laneIsolation $laneIsolation
    if ($buildEnvironment.laneRoot -and -not (Test-OctoPathInLane -path $repositoryPath -laneRoot $buildEnvironment.laneRoot)) {
        # Safety net (AB#8954): never build with the environment of a lane the repository is not part of.
        $message = "Invoke-Build: repository $repositoryPath does not lie under the lane root $($buildEnvironment.laneRoot) - refused, dotnet was not started."
        $Global:LASTEXITCODE = 1
        if ($Json) {
            Write-OctoJson -Command 'Invoke-Build' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ configuration = $configuration; repositoryPath = $repositoryPath; laneRoot = $buildEnvironment.laneRoot; error = $message })
        }
        Write-Error $message
        return
    }
    if ($DryRun) {
        Write-OctoLaneDryRun -command 'Invoke-Build' -repositoryPath $repositoryPath -configuration $configuration -buildEnvironment $buildEnvironment -Json:$Json
        return
    }

    # Set for this build only and restored afterwards; empty outside a lane and in main (legacy behaviour).
    $savedEnvironment = Set-OctoBuildEnvironment -environment $buildEnvironment.environment
    try {
        Invoke-BuildCore -configuration $configuration -repositoryPath $repositoryPath -propertyArgs $propertyArgs -msbuildProperties $msbuildProperties -refreshCatalogs:$refreshCatalogs -events $events -Json:$Json
    }
    finally {
        Restore-OctoBuildEnvironment -saved $savedEnvironment
    }
}

function Invoke-BuildCore {
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
        [string[]]$propertyArgs = @(),
        # -EventsFile state (New-OctoBuildEventState); this function writes plan/repoStart/phase/repoDone and the result. $null = no events.
        $events = $null,
        # The properties behind $propertyArgs and the caller's -refreshCatalogs: the one read of the remote CK
        # catalogs (AB#8831) happens here, inside the repository's progress (phase "catalogs").
        [hashtable]$msbuildProperties = @{},
        [switch]$refreshCatalogs,
        [switch]$Json
    )
    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }

    $repositoryPath = $(Resolve-Path -Path $repositoryPath).Path

    $eventsOn = ($null -ne $events) -and -not [string]::IsNullOrWhiteSpace([string]$events.Path)
    if ($eventsOn) {
        $repoName = Split-Path -Leaf ([IO.Path]::TrimEndingDirectorySeparator($repositoryPath))
        Write-OctoBuildEvent -Path $events.Path -Command $events.Command -Event 'plan' -Data ([ordered]@{ repos = @([ordered]@{ repo = $repoName; mode = 'dotnet' }); count = 1 })
        $events.Repo = $repoName
        $events.Index = 1
        $events.Count = 1
        $events.RepoDone = $false
        $events.RepoWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $events.LogFile = $logFile
        Write-OctoBuildEvent -Path $events.Path -Command $events.Command -Event 'repoStart' -Data ([ordered]@{ repo = $repoName; index = 1; count = 1 })
    }

    $setPhase = {
        param([string]$phase)
        if ($eventsOn) {
            $events.Phase = $phase
            Write-OctoBuildEvent -Path $events.Path -Command $events.Command -Event 'phase' -Data ([ordered]@{ repo = $events.Repo; phase = $phase })
        }
    }
    $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()

    # AB#8831: one read of the remote CK catalogs, then the CK compiles of this build do not refresh them again.
    # After repoStart, as its own phase: the read can take minutes and belongs to the repository's duration.
    $catalogs = [ordered]@{ mode = $(if ($refreshCatalogs) { 'perCompile' } else { 'notNeeded' }); usable = $false; seconds = 0.0; detail = $null }
    if (-not $refreshCatalogs -and -not (Test-OctoCatalogPropertySet -properties $msbuildProperties) -and (Test-OctoRepoUsesCk -path $repositoryPath)) {
        & $setPhase 'catalogs'
        $laneRoot = Find-OctoLaneRoot -path $repositoryPath
        if (-not $laneRoot) { $laneRoot = Split-Path -Parent ([IO.Path]::TrimEndingDirectorySeparator($repositoryPath)) }
        $read = Initialize-OctoRunCatalogs -laneRootPath $laneRoot
        $catalogs.mode = $read.mode; $catalogs.usable = [bool]$read.usable; $catalogs.seconds = [double]$read.seconds; $catalogs.detail = $read.detail
        if (-not $Json) { Write-Host "CK catalogs: $($read.mode) - $($read.detail)" -ForegroundColor $(if ($read.usable) { 'DarkGray' } else { 'Yellow' }) }
        if ($read.usable) { $propertyArgs = @(ConvertTo-OctoMsBuildPropertyArgs -properties (Add-OctoCatalogProperty -properties $msbuildProperties)) }
    }

    if (-not $Json) {
        Write-Host "[$configuration] Restore nuget packages $repositoryPath" -ForegroundColor Green
    }
    & $setPhase 'restore'
    $restoreWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $compileWatch = [System.Diagnostics.Stopwatch]::new()
    dotnet restore $repositoryPath -p:Configuration=$configuration @propertyArgs -f > $logFile
    $exitCode = $LASTEXITCODE
    $restoreWatch.Stop()
    $failedStep = $null
    if ($exitCode -ne 0) {
        # A failed restore must not fall through to the build (which would report its own result).
        $failedStep = 'restore'
        if (-not $Json) {
            Write-Host "[$configuration] Restore failed (exit code $exitCode), see $logFile" -ForegroundColor Red
        }
    }
    else {
        if (-not $Json) {
            Write-Host "[$configuration] Building repository $repositoryPath" -ForegroundColor Green
        }
        & $setPhase 'build'
        $compileWatch.Start()
        # --no-restore: the restore above did it; compileSeconds is the build alone.
        dotnet build $repositoryPath -c $configuration --no-restore @propertyArgs >> $logFile
        $exitCode = $LASTEXITCODE
        $compileWatch.Stop()
        if ($exitCode -ne 0) { $failedStep = 'build' }
        if (-not $Json) {
            if ($exitCode -ne 0) {
                Write-Host "[$configuration] Build failed" -ForegroundColor Red
            }
            else {
                Write-Host "[$configuration] Build finished" -ForegroundColor Green
            }
        }
    }
    $buildWatch.Stop()
    $state = $exitCode -eq 0
    $Global:LASTEXITCODE = $exitCode
    if ($eventsOn) {
        $events.RepoWatch.Stop()
        Write-OctoBuildEvent -Path $events.Path -Command $events.Command -Event 'repoDone' -Data ([ordered]@{
                repo           = $events.Repo
                index          = 1
                count          = 1
                success        = $state
                seconds        = $events.RepoWatch.Elapsed.TotalSeconds
                buildSeconds   = $buildWatch.Elapsed.TotalSeconds
                testSeconds    = 0
                packageSeconds = 0
                catalogSeconds = $(if ($catalogs) { [double]$catalogs.seconds } else { 0.0 })
                restoreSeconds = $restoreWatch.Elapsed.TotalSeconds
                compileSeconds = $compileWatch.Elapsed.TotalSeconds
                copied         = 0
                purged         = 0
                logFile        = $logFile
            })
        $events.RepoDone = $true
        $events.Success = $state
        $events.FailedRepo = if ($state) { $null } else { $events.Repo }
        $events.FailedStep = $failedStep
        $events.Completed = $true
    }

    if ($Json) {
        Write-OctoJson -Command 'Invoke-Build' -Data (New-OctoActionResult -Success $state -ExitCode $exitCode -Extra @{
            configuration  = $configuration
            logFile        = $logFile
            restoreSeconds = $restoreWatch.Elapsed.TotalSeconds
            compileSeconds = $compileWatch.Elapsed.TotalSeconds
            catalogs       = $catalogs
        })
        return
    }
}


Export-ModuleMember -Function @('Invoke-Build')
