Write-Host "Loading Octo Profile"
$modulePath = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rootPath = Join-Path $modulePath "../../"
$rootPath = Resolve-Path $rootPath
$env:PSModulePath += ":$modulePath"
if ($IsMacOS)
{
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Debug/Tool/net7.0/osx-x64/publish"
    $env:PATH += ";$octoCliPath"
}
elseif ($IsLinux)
{
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Debug/Tool/net7.0/linux-x64/publish"
    $env:PATH += ";$octoCliPath"
}
else
{
    $octoCliPath = Join-Path $rootPath "octo-cli/bin/Debug/Tool/net7.0/win-x64/publish"
    $env:PATH += ";$octoCliPath"
}
$toolsPath = Resolve-Path (Join-Path $rootPath "octo-tools/")

$env:PATH += ";$rootPath" + "octo-tools/"

Import-Module "$modulePath/Invoke-PullGitRepo.psm1"
Import-Module "$modulePath/Invoke-PullAllGitRepos.psm1"
Import-Module "$modulePath/Update-GitSubmodules.psm1"
Import-Module "$modulePath/Update-GitReposAndSubmodules.psm1"
Import-Module "$modulePath/Invoke-BuildOcto.psm1"
Import-Module "$modulePath/Invoke-StartOcto.psm1"
Import-Module "$modulePath/Invoke-BuildAndStartOcto.psm1"

Set-Location $rootPath
$Global:rootPath = $rootPath

function  Global:prompt {"OCTO $PWD> "}