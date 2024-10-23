function Invoke-BuildFrontend {

    $npmVersion = npm --version
    $nodeVersion = node --version
    
    Write-Host "npm version: $npmVersion"
    Write-Host "node version: $nodeVersion"
    
    $frontendAdminPanelRootPath = Join-Path $rootPath "octo-frontend-admin-panel"
    $frontendLibrariesPath = Join-Path $rootPath "octo-frontend-admin-panel\src\octo-frontend-libraries\src\FrontendLibraries\ClientApp"
    $frontendAdminPanelPath = Join-Path $rootPath "octo-frontend-admin-panel\src\AdminPanel\ClientApp"
    $frontendLibrariesPackageLockPath = Join-Path $frontendLibrariesPath "package-lock.json"
    $frontendAdminPanelPackagesLockPath = Join-Path $frontendAdminPanelPath "package-lock.json"
    
    $frontendLibrariesNodeModulesPath =  Join-Path $frontendLibrariesPath "node_modules"
    if (Test-Path $frontendLibrariesNodeModulesPath) {
        Write-Host "Delete node_modules in $frontendLibrariesNodeModulesPath" 
        Remove-Item -Path $frontendLibrariesNodeModulesPath -Recurse -Force
        
        Write-Host "Delete $frontendLibrariesPackageLockPath"
        Remove-Item -Path $frontendLibrariesPackageLockPath -Force
    }
    
    # rm -rf node_modules in "octo-frontend-admin-panel"
    $frontendAdminPanelNodeModulesPath = Join-Path $frontendAdminPanelPath "node_modules"
    if (Test-Path $frontendAdminPanelNodeModulesPath) {
        Write-Host "Delete node_modules in $frontendAdminPanelNodeModulesPath"
        Remove-Item -Path $frontendAdminPanelNodeModulesPath -Recurse -Force

        Write-Host "Delete $frontendAdminPanelPackagesLockPath"
        Remove-Item -Path $frontendAdminPanelPackagesLockPath -Force
    }
    
    Write-Host "Publishing adminpanel..."
    Push-Location -Path $frontendAdminPanelRootPath
    Invoke-Publish 
    Pop-Location
    
}
Export-ModuleMember -Function @('Invoke-BuildFrontend')