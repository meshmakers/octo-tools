Write-Host "Loading Octo Profile"
$startPath = Get-Location
$modulePath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootPath = Join-Path $modulePath "../../"
$rootPath = Resolve-Path $rootPath
$env:PSModulePath += ":$modulePath"
$publishVersion = "net10.0"
$usersFolderPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
$privateProfilePath = Join-Path $usersFolderPath ".pwsh/profile.ps1";

if ($IsMacOS) {
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Release/$publishVersion/osx-x64"
    $env:PATH += ";$octoCliPath"
    $privateProfilePath = Join-Path $usersFolderPath ".config/powershell/Microsoft.PowerShell_profile_private.ps1";
}
elseif ($IsLinux) {
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Release/$publishVersion/linux-x64"
    $env:PATH += ";$octoCliPath"
}
else {
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Release/$publishVersion/win-x64"
    $env:PATH += ";$octoCliPath"
}
$toolsPath = Resolve-Path (Join-Path $rootPath "octo-tools/")
$infrastructurePath = Resolve-Path (Join-Path $toolsPath "infrastructure/")

$globalNugetPackagesPath = Join-Path $usersFolderPath ".nuget/packages/"

$Global:WantPromt = $true

$env:PATH += ";$toolsPath"

function Test-SubPath( [string]$directory, [string]$subpath ) {
    $dPath = [IO.Path]::GetFullPath( $directory )
    $sPath = [IO.Path]::GetFullPath( $subpath )
    return $sPath.StartsWith( $dPath, [StringComparison]::OrdinalIgnoreCase )
}

Import-Module "$modulePath/Get-OctoInfrastructureStatus.psm1"
Import-Module "$modulePath/Sync-AllGitRepos.psm1"
Import-Module "$modulePath/Sync-AllSubmodules.psm1"
Import-Module "$modulePath/Sync-GitRepo.psm1"
Import-Module "$modulePath/Sync-Submodule.psm1"
Import-Module "$modulePath/Push-GitRepo.psm1"
Import-Module "$modulePath/Push-AllGitRepos.psm1"
Import-Module "$modulePath/Install-OctoInfrastructure.psm1"
Import-Module "$modulePath/Uninstall-OctoInfrastructure.psm1"
Import-Module "$modulePath/Invoke-BuildAndStartOcto.psm1"
Import-Module "$modulePath/Invoke-Build.psm1"
Import-Module "$modulePath/Invoke-BuildAll.psm1"
Import-Module "$modulePath/Invoke-CloneMainRepos.psm1"
Import-Module "$modulePath/Start-Octo.psm1"
Import-Module "$modulePath/Start-OctoInfrastructure.psm1"
Import-Module "$modulePath/Stop-OctoInfrastructure.psm1"
Import-Module "$modulePath/Copy-AllNuGetPackages.psm1"
Import-Module "$modulePath/Copy-NuGetPackages.psm1"
Import-Module "$modulePath/Remove-GlobalNuGetPackages.psm1"
Import-Module "$modulePath/Invoke-Publish.psm1"
Import-Module "$modulePath/Sync-NuGetPackages.psm1"
Import-Module "$modulePath/Invoke-OctoCliLoginLocal.psm1"
Import-Module "$modulePath/Invoke-OctoCliLoginProduction.psm1"
Import-Module "$modulePath/Invoke-OctoCliLoginStaging.psm1"
Import-Module "$modulePath/Invoke-OctoCliLoginTest2.psm1"
Import-Module "$modulePath/Invoke-SetDebugConfiguration.psm1"
Import-Module "$modulePath/Invoke-KillDotnet.psm1"
Import-Module "$modulePath/Remove-BinAndObjFolders.psm1"
Import-Module "$modulePath/Get-AllGitRepStatus.psm1"
Import-Module "$modulePath/Invoke-BuildFrontend.psm1"
Import-Module "$modulePath/Join-KubeConfigs.psm1"
Import-Module "$modulePath/Remove-KubeConfig.psm1"
Import-Module "$modulePath/Invoke-OctoCliReconfigureLogLevel.psm1"
Import-Module "$modulePath/Invoke-CleanAllGitRepos.psm1"
Import-Module "$modulePath/Invoke-BuildZenonPlug.psm1"
Import-Module "$modulePath/New-RootCertificate.psm1"
Import-Module "$modulePath/New-ServerCertificate.psm1"
Import-Module "$modulePath/AspNetDeveloperCertificate.psm1"
Import-Module "$modulePath/Sync-YamlTemplates.psm1"
Import-Module "$modulePath/Update-MeshmakerVersion.psm1"
Import-Module "$modulePath/Find-AllGitRepos.psm1"
Import-Module "$modulePath/Invoke-SwitchAllBranches.psm1"
Import-Module "$modulePath/Compare-BranchStatus.psm1"
Import-Module "$modulePath/Invoke-MongoPortForward.psm1"
Import-Module "$modulePath/New-TestBranch.psm1"
Import-Module "$modulePath/Remove-TestBranch.psm1"

if (!(Test-SubPath $rootPath $startPath)) {
    Set-Location $rootPath
}

if (Test-Path $privateProfilePath) {
    Write-Host "Loading private profile '$privateProfilePath'"
    . $privateProfilePath
}

$Global:ROOTPATH = $rootPath
$env:ROOTPATH = $rootPath
$Global:GLOBALNUGETPACKAGESPATH = $globalNugetPackagesPath
$Global:INFRASTRUCTUREPATH = $infrastructurePath

write-host "ROOTPATH: $Global:ROOTPATH"
write-host "GLOBALNUGETPACKAGESPATH: $Global:GLOBALNUGETPACKAGESPATH"
write-host "INFRASTRUCTUREPATH: $Global:INFRASTRUCTUREPATH"
write-host "WANT PROMT: $Global:WantPromt"


if ($Global:WantPromt) {
    function  Global:prompt { "OCTO $PWD> " }
}