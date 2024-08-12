Write-Host "Loading Octo Profile"
$startPath = Get-Location
$modulePath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootPath = Join-Path $modulePath "../../"
$rootPath = Resolve-Path $rootPath
$env:PSModulePath += ":$modulePath"
$publishVersion = "net8.0"
if ($IsMacOS) {
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Release/$publishVersion/osx-x64"
    $env:PATH += ";$octoCliPath"
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
$nugetPath = Join-Path $rootPath "nuget/"
$usersFolderPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
$globalNugetPackagesPath = Join-Path $usersFolderPath ".nuget/packages/"
$privateProfilePath = Join-Path $usersFolderPath ".pwsh/profile.ps1";
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
Import-Module "$modulePath/Invoke-SetDebugConfiguration.psm1"
Import-Module "$modulePath/Invoke-KillDotnet.psm1"
Import-Module "$modulePath/Remove-BinAndObjFolders.psm1"
Import-Module "$modulePath/Get-AllGitRepStatus.psm1"
Import-Module "$modulePath/Join-KubeConfigs.psm1"
Import-Module "$modulePath/Remove-KubeConfig.psm1"


if (!(Test-Path $nugetPath)) {
    Write-Host "Creating nuget packages path $nugetPath."
    New-Item -Path $nugetPath -ItemType Directory | out-null
}

if (!(Test-SubPath $rootPath $startPath)) {
    Set-Location $rootPath
}

if (Test-Path $privateProfilePath) {
    Write-Host "Loading private profile '$privateProfilePath'"
    . $privateProfilePath
}

$Global:ROOTPATH = $rootPath
$Global:GLOBALNUGETPACKAGESPATH = $globalNugetPackagesPath
$Global:INFRASTRUCTUREPATH = $infrastructurePath
$Global:NUGETPATH = $nugetPath

if ($Global:WantPromt) {
    function  Global:prompt { "OCTO $PWD> " }
}