function Invoke-SetDebugConfiguration
{
    param([switch]$Json)

    # Ensure that you have logged in to identity services (Invoke-OctoCliLoginLocal)

    if ($Json) {
        $exitCode = 0
        octo-cli -c AddAuthorizationCodeClient --clienturi https://localhost:44483/ --clientid octo-admin-panel-debug --redirectUri "https://localhost:44483/" --name "Admin Panel debug" | Out-Null
        if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
        $scopes = @('assetSystemAPI.full_access', 'octo_api', 'identityAPI.full_access', 'botAPI.full_access', 'communicationSystemAPI.full_access', 'communicationTenantAPI.full_access')
        foreach ($scope in $scopes) {
            octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name $scope | Out-Null
            if ($LASTEXITCODE -ne 0) { $exitCode = $LASTEXITCODE }
        }
        Write-OctoJson -Command 'Invoke-SetDebugConfiguration' -Data (New-OctoActionResult -Success ($exitCode -eq 0) -ExitCode $exitCode)
        return
    }

    octo-cli -c AddAuthorizationCodeClient --clienturi https://localhost:44483/ --clientid octo-admin-panel-debug --redirectUri "https://localhost:44483/" --name "Admin Panel debug"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "assetSystemAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "octo_api"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "identityAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "botAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "communicationSystemAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "communicationTenantAPI.full_access"
}

Export-ModuleMember -Function @('Invoke-SetDebugConfiguration')