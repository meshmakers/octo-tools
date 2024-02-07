function Invoke-Publish
{
    param(
        [string]$configuration = "Release",
        [string]$repositoryPath = ".\"
    )

    Write-Host "[$configuration] Publishing git repository $repositoryPath" -ForegroundColor Green
    dotnet publish $repositoryPath -f "net8.0" -c $configuration
}


Export-ModuleMember -Function @('Invoke-Publish')