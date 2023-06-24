function Invoke-BuildOcto
{
    if (!(Test-Path $rootPath))
    {
        Write-Error "Root path $rootPath does not exist"
        return;
    }
    
    dotnet publish (Join-Path $rootPath octo-identity-services/src/IdentityServices/)
    dotnet publish (Join-Path $rootPath octo-identity-services/src/PolicyServices/)
    dotnet publish (Join-Path $rootPath octo-asset-repo-services/src/AssetRepositoryServices/)
    dotnet publish (Join-Path $rootPath octo-time-series-repo-services/src/HistorianRepositoryServices/)
    dotnet publish (Join-Path $rootPath octo-bot-services/src/BotServices/)
    dotnet publish (Join-Path $rootPath octo-communication-controller-services/src/CommunicationControllerServices/)
    dotnet publish (Join-Path $rootPath octo-communication-operator/src/CommunicationOperator/)
    dotnet publish (Join-Path $rootPath octo-cli/src/ManagementTool/)
    dotnet publish (Join-Path $rootPath octo-frontend-libraries/src/FrontendLibraries)
    dotnet publish (Join-Path $rootPath octo-frontend-admin-panel/src/AdminPanel/)
}


Export-ModuleMember -Function @('Invoke-BuildOcto')