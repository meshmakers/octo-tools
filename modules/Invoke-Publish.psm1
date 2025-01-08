function Invoke-Publish
{
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\"
    )

    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }

    Write-Host "[$configuration] Publishing git repository $repositoryPath" -ForegroundColor Green
    dotnet publish $repositoryPath -f "net9.0" -c $configuration > $logFile
    $state = $LASTEXITCODE -eq 0
    if ($state -eq $false) {
        Write-Host "[$configuration] Publish failed" -ForegroundColor Red
    }
    else {
        Write-Host "[$configuration] Publish finished" -ForegroundColor Green
    }
    $Global:LASTEXITCODE = $LASTEXITCODE
}


Export-ModuleMember -Function @('Invoke-Publish')