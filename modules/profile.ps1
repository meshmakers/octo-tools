Write-Host "Loading Octo Profile"
$startPath = Get-Location
$modulePath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootPath = Join-Path $modulePath "../../"
$rootPath = Resolve-Path $rootPath
$env:PSModulePath += ":$modulePath"
$publishVersion = "net8.0"
if ($IsMacOS)
{
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Debug/Tool/$publishVersion/osx-x64/publish"
    $env:PATH += ";$octoCliPath"
}
elseif ($IsLinux)
{
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Debug/Tool/$publishVersion/linux-x64/publish"
    $env:PATH += ";$octoCliPath"
}
else
{
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Debug/Tool/$publishVersion/win-x64/publish"
    $env:PATH += ";$octoCliPath"
}
$toolsPath = Resolve-Path (Join-Path $rootPath "octo-tools/")
$infrastructurePath = Resolve-Path (Join-Path $toolsPath "infrastructure/")
$nugetPath = Resolve-Path (Join-Path $rootPath "nuget/")

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
Import-Module "$modulePath/Copy-AllNugetPackages.psm1"


if (!(Test-Path $nugetPath)) {
    Write-Error "Creating nuget packages path $nugetPath."
    New-Item -Path $nugetPath -ItemType Directory    
}

if (!(Test-SubPath $rootPath $startPath))
{
    Set-Location $rootPath
}

$Global:ROOTPATH = $rootPath
$Global:INFRASTRUCTUREPATH = $infrastructurePath
$Global:NUGETPATH = $nugetPath

function  Global:prompt {"OCTO $PWD> "}