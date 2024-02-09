function Invoke-Build {
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\"
    )
    
    Write-Host "[$configuration] Building git repository $repositoryPath" -ForegroundColor Green
    dotnet build $repositoryPath -c $configuration
    $global:LASTEXITCODE = $LASTEXITCODE
}


Export-ModuleMember -Function @('Invoke-Build')