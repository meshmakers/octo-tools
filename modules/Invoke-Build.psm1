<#
.SYNOPSIS
    Restores (forced) and builds the solution in one repository, with the lane isolation of Invoke-BuildAll.

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
        Invoke-BuildCore -configuration $configuration -repositoryPath $repositoryPath -propertyArgs $propertyArgs -Json:$Json
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
        [switch]$Json
    )
    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }

    $repositoryPath = $(Resolve-Path -Path $repositoryPath).Path

    if (-not $Json) {
        Write-Host "[$configuration] Restore nuget packages $repositoryPath" -ForegroundColor Green
    }
    dotnet restore $repositoryPath -p:Configuration=$configuration @propertyArgs -f > $logFile

    if (-not $Json) {
        Write-Host "[$configuration] Building git repository $repositoryPath" -ForegroundColor Green
    }
    dotnet build $repositoryPath -c $configuration @propertyArgs >> $logFile
    $exitCode = $LASTEXITCODE
    $state = $exitCode -eq 0
    if (-not $Json) {
        if ($state -eq $false) {
            Write-Host "[$configuration] Build failed" -ForegroundColor Red
        }
        else {
            Write-Host "[$configuration] Build finished" -ForegroundColor Green
        }
    }
    $Global:LASTEXITCODE = $exitCode

    if ($Json) {
        Write-OctoJson -Command 'Invoke-Build' -Data (New-OctoActionResult -Success $state -ExitCode $exitCode -Extra @{
            configuration = $configuration
            logFile       = $logFile
        })
        return
    }
}


Export-ModuleMember -Function @('Invoke-Build')