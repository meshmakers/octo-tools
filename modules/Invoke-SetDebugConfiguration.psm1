function Invoke-SetDebugConfiguration
{
    # Ensure that you have logged in to identity services (Invoke-OctoCliLoginLocal)

    octo-cli -c AddAuthorizationCodeClient --clienturi https://localhost:44483/ --clientid octo-admin-panel-debug --redirectUri "https://localhost:44483/" --name "Admin Panel debug"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "assetSystemAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "assetTenantAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "identityAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "botAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "communicationSystemAPI.full_access"
    octo-cli -c AddScopeToClient --clientid octo-admin-panel-debug --name "communicationTenantAPI.full_access"
}

Export-ModuleMember -Function @('Invoke-SetDebugConfiguration')