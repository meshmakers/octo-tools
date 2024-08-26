function Invoke-BuildFrontend {
    
    # rm -rf node_modules in "octo-frontend-libraries" and "octo-frontend-admin-panel"
    $frontendLibrariesPath = Join-Path $rootPath "octo-frontend-libraries"
    $frontendAdminPanelPath = Join-Path $rootPath "octo-frontend-admin-panel"
    
    $frontendLibrariesPath = Join-Path $frontendLibrariesPath "src\FrontendLibraries\ClientApp"
    $frontendAdminPanelPath = Join-Path $frontendAdminPanelPath "src\AdminPanel\ClientApp"
    
    Write-Host "Delete node_modules in $frontendLibrariesPath"
    if (Test-Path $frontendLibrariesPath) {
        Remove-Item -Path $frontendLibrariesPath\node_modules -Recurse -Force
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
    Write-Host "Delete node_modules in $frontendAdminPanelPath"
    if (Test-Path $frontendAdminPanelPath) {
        Remove-Item -Path $frontendAdminPanelPath\node_modules -Recurse -Force
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