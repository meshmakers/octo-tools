function Test-RimrafAvailable {
    try {
        $null = & rimraf -h 2>$null
        return $true
    }
    catch {
        return $false
    }
}

function Remove-DirectoryForced {
    param([string]$Path)
    
    if (Test-RimrafAvailable) {
        Write-Host "Using rimraf to delete $Path"
        & rimraf $Path -I
    }
    else {
        Write-Host "Using Remove-Item to delete $Path"
        Remove-Item -Path $Path -Recurse -Force
    }
}

function Invoke-BuildFrontend {

    param(
        [string]$configuration = "Release")
    $npmVersion = npm --version
    $nodeVersion = node --version
    
    Write-Host "npm version: $npmVersion"
    Write-Host "node version: $nodeVersion"
    
    $frontendAdminPanelRootPath = Join-Path $rootPath "octo-frontend-admin-panel"
    $frontendLibrariesPath = Join-Path $rootPath "octo-frontend-admin-panel\src\octo-frontend-libraries\src\FrontendLibraries\ClientApp"
    $frontendAdminPanelPath = Join-Path $rootPath "octo-frontend-admin-panel\src\AdminPanel\ClientApp"
    $frontendLibrariesPackageLockPath = Join-Path $frontendLibrariesPath "package-lock.json"
    $frontendAdminPanelPackagesLockPath = Join-Path $frontendAdminPanelPath "package-lock.json"
    
    $frontendLibrariesNodeModulesPath = Join-Path $frontendLibrariesPath "node_modules"
    if (Test-Path $frontendLibrariesNodeModulesPath) {
        Write-Host "Delete node_modules in $frontendLibrariesNodeModulesPath"
        Remove-DirectoryForced -Path $frontendLibrariesNodeModulesPath
    }
    
    if (Test-Path $frontendLibrariesPackageLockPath) {
        Write-Host "Delete $frontendLibrariesPackageLockPath"
        Remove-Item -Path $frontendLibrariesPackageLockPath -Force
    }
    
    # rm -rf node_modules in "octo-frontend-admin-panel"
    $frontendAdminPanelNodeModulesPath = Join-Path $frontendAdminPanelPath "node_modules"
    if (Test-Path $frontendAdminPanelNodeModulesPath) {
        Write-Host "Delete node_modules in $frontendAdminPanelNodeModulesPath"
        Remove-DirectoryForced -Path $frontendAdminPanelNodeModulesPath
    }

    if (Test-Path $frontendAdminPanelPackagesLockPath) {
        Write-Host "Delete $frontendAdminPanelPackagesLockPath"
        Remove-Item -Path $frontendAdminPanelPackagesLockPath -Force
    }
    
    Write-Host "Publishing adminpanel..."
    Push-Location -Path $frontendAdminPanelRootPath
    Invoke-Publish -configuration $configuration
    Pop-Location
    
}
Export-ModuleMember -Function @('Invoke-BuildFrontend')