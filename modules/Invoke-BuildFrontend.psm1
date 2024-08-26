function Invoke-BuildFrontend {
    
    # rm -rf node_modules in "octo-frontend-libraries" and "octo-frontend-admin-panel"
    $frontendLibrariesPath = Join-Path $rootPath "octo-frontend-admin-panel\src\octo-frontend-libraries\src\FrontendLibraries\ClientApp"
    $frontendAdminPanelPath = Join-Path $rootPath "octo-frontend-admin-panel\src\AdminPanel\ClientApp"

    Write-Host "Build frontend libraries in $frontendLibrariesPath" 
    
    $frontendLibrariesNodeModulesPath =  Join-Path $frontendLibrariesPath "node_modules"
    if (Test-Path $frontendLibrariesNodeModulesPath) {
        Write-Host "Delete node_modules in $frontendLibrariesNodeModulesPath" 
        Remove-Item -Path $frontendLibrariesNodeModulesPath -Recurse -Force
    }
    
    # npm install in "octo-frontend-libraries"

    if (Test-Path $frontendLibrariesPath) {
        Write-Host "npm install in $frontendLibrariesPath" 
        Push-Location $frontendLibrariesPath
        npm install
        Pop-Location
    }
    
    # npm run build in "octo-frontend-libraries"
    if (Test-Path $frontendLibrariesPath) {
        Write-Host "npm run build in $frontendLibrariesPath" 
        
        Push-Location $frontendLibrariesPath
        npm run build
        Pop-Location
    }


    Write-Host "Build frontend libraries in $frontendAdminPanelPath" 
    
    # rm -rf node_modules in "octo-frontend-admin-panel"
    $frontendAdminPanelNodeModulesPath = Join-Path $frontendAdminPanelPath "node_modules"
    if (Test-Path $frontendAdminPanelNodeModulesPath) {
        Write-Host "Delete node_modules in $frontendAdminPanelNodeModulesPath"  
        
        Remove-Item -Path $frontendAdminPanelNodeModulesPath -Recurse -Force
    }

    # npm install in "octo-frontend-admin-panel"
    if (Test-Path $frontendAdminPanelPath) {
        Write-Host "npm install in $frontendAdminPanelPath" 
        
        Push-Location $frontendAdminPanelPath
        npm install
        Pop-Location
    }

    # npm run build in "octo-frontend-admin-panel"
    if (Test-Path $frontendAdminPanelPath) {
        Write-Host "npm run build in $frontendAdminPanelPath" 
        
        Push-Location $frontendAdminPanelPath
        npm run build
        Pop-Location
    }

}
Export-ModuleMember -Function @('Invoke-BuildFrontend')