function Invoke-Publish
{
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
        # dotnet publish parameters
        [Parameter(Mandatory=$false)]
        [string[]]
        $publishParameters = @(),
        # Lane isolation, same rules as Invoke-BuildAll (see Get-OctoRepositoryBuildEnvironment).
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        # Print the lane environment this publish would use and exit without running dotnet.
        [switch]$DryRun,
        [switch]$Json
    )

    $buildEnvironment = Get-OctoRepositoryBuildEnvironment -repositoryPath $repositoryPath -configuration $configuration -laneIsolation $laneIsolation
    if ($DryRun) {
        Write-OctoLaneDryRun -command 'Invoke-Publish' -repositoryPath $repositoryPath -configuration $configuration -buildEnvironment $buildEnvironment -Json:$Json
        return
    }

    # Set for this publish only and restored afterwards; empty outside a lane and in main (legacy behaviour).
    $savedEnvironment = Set-OctoBuildEnvironment -environment $buildEnvironment.environment
    try {
        Invoke-PublishCore -configuration $configuration -repositoryPath $repositoryPath -publishParameters $publishParameters -Json:$Json
    }
    finally {
        Restore-OctoBuildEnvironment -saved $savedEnvironment
    }
}

function Invoke-PublishCore
{
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
        [string[]]
        $publishParameters = @(),
        [switch]$Json
    )

    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }

    if (-not $Json) {
        Write-Host "[$configuration] Restore nuget packages $repositoryPath" -ForegroundColor Green
    }
    dotnet restore $repositoryPath -f > $logFile

    if (-not $Json) {
        Write-Host "[$configuration] Publishing git repository $repositoryPath $publishParameters" -ForegroundColor Green
    }
    dotnet publish $repositoryPath -c $configuration @publishParameters >> $logFile
    $exitCode = $LASTEXITCODE
    $state = $exitCode -eq 0
    if (-not $Json) {
        if ($state -eq $false) {
            Write-Host "[$configuration] Publish failed" -ForegroundColor Red
        }
        else {
            Write-Host "[$configuration] Publish finished" -ForegroundColor Green
        }
    }
    $Global:LASTEXITCODE = $exitCode

    if ($Json) {
        Write-OctoJson -Command 'Invoke-Publish' -Data (New-OctoActionResult -Success $state -ExitCode $exitCode -Extra @{
            configuration = $configuration
            logFile       = $logFile
        })
        return
    }
}


Export-ModuleMember -Function @('Invoke-Publish')