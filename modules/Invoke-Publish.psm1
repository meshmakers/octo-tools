function Invoke-Publish
{
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\",
        # dotnet publish parameters
        [Parameter(Mandatory=$false)]
        [string]
        $publishParamerters = ""
    )

    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }

    Write-Host "[$configuration] Publishing git repository $repositoryPath $publishParamerters" -ForegroundColor Green
    dotnet publish $repositoryPath -c $configuration $publishParameters > $logFile
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