<#
.SYNOPSIS
    Restores (forced) and builds the solution in one repository, with the lane isolation of Invoke-BuildAll.

.DESCRIPTION
    A failed `dotnet restore` stops the run: the build is not started and the result is
    success=false with the restore's exit code (it used to continue and report the build's result).

.PARAMETER configuration
    Build configuration (default Release; DebugL for local development).

.PARAMETER repositoryPath
    Repository root containing the solution.

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
        # Progress events, one JSON line each (Write-OctoBuildEvent).
        [string]$EventsFile = '',
        [switch]$Json
    )

    if ($DryRun -or [string]::IsNullOrWhiteSpace($EventsFile)) {
        Invoke-BuildMain -configuration $configuration -repositoryPath $repositoryPath -laneIsolation $laneIsolation -DryRun:$DryRun -msbuildProperties $msbuildProperties -Json:$Json
        return
    }

    $repoName = Split-Path -Leaf ([IO.Path]::TrimEndingDirectorySeparator($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($repositoryPath)))
    # Shared with Invoke-BuildCore, which records the current phase and the result.
    $events = @{ Path = $EventsFile; Command = 'Invoke-Build'; Repo = $repoName; Phase = $null; Result = $null }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-Build' -Event 'plan' -Data ([ordered]@{ repos = @([ordered]@{ repo = $repoName; mode = 'dotnet' }); count = 1 })
    Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-Build' -Event 'repoStart' -Data ([ordered]@{ repo = $repoName; index = 1; count = 1 })
    try {
        Invoke-BuildMain -configuration $configuration -repositoryPath $repositoryPath -laneIsolation $laneIsolation -msbuildProperties $msbuildProperties -events $events -Json:$Json
    }
    finally {
        # Also reached when the build throws: repoDone and done with success=false.
        $watch.Stop()
        $result = $events.Result
        $success = ($null -ne $result) -and [bool]$result.Success
        $failedStep = if ($success) { $null } elseif ($null -ne $result) { $result.FailedStep } elseif ($events.Phase) { $events.Phase } else { 'restore' }
        $buildSeconds = if ($null -ne $result) { $result.BuildSeconds } else { $watch.Elapsed.TotalSeconds }
        Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-Build' -Event 'repoDone' -Data ([ordered]@{
                repo           = $repoName
                index          = 1
                count          = 1
                success        = $success
                seconds        = $watch.Elapsed.TotalSeconds
                buildSeconds   = $buildSeconds
                testSeconds    = 0
                packageSeconds = 0
                copied         = 0
                purged         = 0
                logFile        = if ($null -ne $result) { $result.LogFile } else { $null }
            })
        Write-OctoBuildEvent -Path $EventsFile -Command 'Invoke-Build' -Event 'done' -Data ([ordered]@{
                success        = $success
                failedRepo     = if ($success) { $null } else { $repoName }
                failedStep     = $failedStep
                elapsedSeconds = $watch.Elapsed.TotalSeconds
            })
    }
}

function Invoke-BuildMain {
    param(
        [string]$configuration,
        [string]$repositoryPath,
        [string]$laneIsolation,
        [switch]$DryRun,
        [hashtable]$msbuildProperties = @{},
        $events = $null,
        [switch]$Json
    )

    $propertyArgs = @(ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties)
    $buildEnvironment = Get-OctoRepositoryBuildEnvironment -repositoryPath $repositoryPath -configuration $configuration -laneIsolation $laneIsolation
    if ($DryRun) {
        Write-OctoLaneDryRun -command 'Invoke-Build' -repositoryPath $repositoryPath -configuration $configuration -buildEnvironment $buildEnvironment -Json:$Json
        return
    }

    # Set for this build only and restored afterwards; empty outside a lane and in main (legacy behaviour).
    $savedEnvironment = Set-OctoBuildEnvironment -environment $buildEnvironment.environment
    try {
        Invoke-BuildCore -configuration $configuration -repositoryPath $repositoryPath -propertyArgs $propertyArgs -events $events -Json:$Json
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
        # Event state of Invoke-Build -EventsFile (Path, Command, Repo); Phase and Result are set here. $null = no events.
        $events = $null,
        [switch]$Json
    )
    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }

    $repositoryPath = $(Resolve-Path -Path $repositoryPath).Path

    $setPhase = {
        param([string]$phase)
        if ($null -ne $events) {
            $events.Phase = $phase
            Write-OctoBuildEvent -Path $events.Path -Command $events.Command -Event 'phase' -Data ([ordered]@{ repo = $events.Repo; phase = $phase })
        }
    }
    $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not $Json) {
        Write-Host "[$configuration] Restore nuget packages $repositoryPath" -ForegroundColor Green
    }
    & $setPhase 'restore'
    dotnet restore $repositoryPath -p:Configuration=$configuration @propertyArgs -f > $logFile
    $exitCode = $LASTEXITCODE
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
        dotnet build $repositoryPath -c $configuration @propertyArgs >> $logFile
        $exitCode = $LASTEXITCODE
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
    if ($null -ne $events) {
        $events.Result = [pscustomobject]@{ Success = $state; FailedStep = $failedStep; LogFile = $logFile; BuildSeconds = $buildWatch.Elapsed.TotalSeconds }
    }

    if ($Json) {
        Write-OctoJson -Command 'Invoke-Build' -Data (New-OctoActionResult -Success $state -ExitCode $exitCode -Extra @{
            configuration = $configuration
            logFile       = $logFile
        })
        return
    }
}


Export-ModuleMember -Function @('Invoke-Build')
