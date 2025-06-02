function Invoke-Build {
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\"
    )
    $logFile = Join-Path $repositoryPath "Invoke-Build.log"
    if (Test-Path $logFile) {
        Remove-Item $logFile
    }

    $repositoryPath = $(Resolve-Path -Path $repositoryPath).Path

    Write-Host "[$configuration] Restore nuget packages $repositoryPath" -ForegroundColor Green
    dotnet restore $repositoryPath -f > $logFile
    
    Write-Host "[$configuration] Building git repository $repositoryPath" -ForegroundColor Green
    dotnet build $repositoryPath -c $configuration >> $logFile
    $state = $LASTEXITCODE -eq 0
    if ($state -eq $false) {
        Write-Host "[$configuration] Build failed" -ForegroundColor Red
    }
    else {
        Write-Host "[$configuration] Build finished" -ForegroundColor Green
    }
    $Global:LASTEXITCODE = $LASTEXITCODE
}


Export-ModuleMember -Function @('Invoke-Build')