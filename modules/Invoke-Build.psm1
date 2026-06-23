function Invoke-Build {
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
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
    dotnet restore $repositoryPath -p:Configuration=$configuration -f > $logFile

    if (-not $Json) {
        Write-Host "[$configuration] Building git repository $repositoryPath" -ForegroundColor Green
    }
    dotnet build $repositoryPath -c $configuration >> $logFile
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