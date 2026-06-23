function Invoke-Publish
{
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
        # dotnet publish parameters
        [Parameter(Mandatory=$false)]
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