function Invoke-BuildFrontend {
    
    # rm -rf node_modules in "octo-frontend-libraries" and "octo-frontend-admin-panel"
    $frontendLibrariesPath = Join-Path $rootPath "octo-frontend-admin-panel\src\octo-frontend-libraries\FrontendLibraries\ClientApp"
    $frontendAdminPanelPath = Join-Path $rootPath "octo-frontend-admin-panel\src\AdminPanel\ClientApp"
    
    
    $frontendLibrariesNodeModulesPath =  Join-Path $frontendLibrariesPath "node_modules"
    Write-Host "Delete node_modules in $frontendLibrariesNodeModulesPath"
    if (Test-Path $frontendLibrariesNodeModulesPath) {
        Remove-Item -Path $frontendLibrariesNodeModulesPath -Recurse -Force
    }
    
    # npm install in "octo-frontend-libraries"
    Write-Host "npm install in $frontendLibrariesPath"
    if (Test-Path $frontendLibrariesPath) {
        Push-Location $frontendLibrariesPath
        npm install
        Pop-Location
    }
    
    # npm run build in "octo-frontend-libraries"
    Write-Host "npm run build in $frontendLibrariesPath"
    if (Test-Path $frontendLibrariesPath) {
        Push-Location $frontendLibrariesPath
        npm run build
        Pop-Location
    }
    
    
    
    # rm -rf node_modules in "octo-frontend-admin-panel"
    $frontendAdminPanelNodeModulesPath = Join-Path $frontendAdminPanelPath "node_modules"
    Write-Host "Delete node_modules in $frontendAdminPanelNodeModulesPath"
    if (Test-Path $frontendAdminPanelNodeModulesPath) {
        Remove-Item -Path $frontendAdminPanelNodeModulesPath -Recurse -Force
    }

    # npm install in "octo-frontend-admin-panel"
    Write-Host "npm install in $frontendAdminPanelPath"
    if (Test-Path $frontendAdminPanelPath) {
        Push-Location $frontendAdminPanelPath
        npm install
        Pop-Location
    }

    # npm run build in "octo-frontend-admin-panel"
    Write-Host "npm run build in $frontendAdminPanelPath"
    if (Test-Path $frontendAdminPanelPath) {
        Push-Location $frontendAdminPanelPath
        npm run build
        Pop-Location
    }

}
Export-ModuleMember -Function @('Invoke-BuildFrontend')