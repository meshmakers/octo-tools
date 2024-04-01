<#
.Synopsis
Clones all main OctoMesh repositories
.Description
This function clones all major git repositories of
OctoMesh from GitHub
.Example
 Set-PsEnv
.Example
 # This is function is called by convention in PowerShell
 function prompt {
     Update-GitSubmodules
 }
#>
function Global:Invoke-CloneMainRepos {

    if (!(Test-Path $rootPath))
    {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $basedir = $PWD
    Write-Host Root directory $rootPath
    Clone-Repo "mm-common"
    Clone-Repo "octo-distributedEventHub"
    Clone-Repo "octo-construction-kit-engine"
    Clone-Repo "octo-construction-kit-engine-mongodb"
    Clone-Repo "octo-sdk"
    Clone-Repo "octo-common-services"
    Clone-Repo "octo-construction-kit"
    Clone-Repo "octo-cli"
    Clone-Repo "octo-identity-services"
    Clone-Repo "octo-asset-repo-services"
    Clone-Repo "octo-bot-services"
    Clone-Repo "octo-mesh-adapter"
    Clone-Repo "octo-communication-controller-services"
    Clone-Repo "octo-communication-operator"
    Clone-Repo "octo-frontend-admin-panel"
    Clone-Repo "octo-frontend-libraries"
}

function Clone-Repo
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($repositoryName = ".\")

    $basedir = $PWD
    $repositoryPath = Join-Path $rootPath $repositoryName
    if (Test-Path $repositoryPath)
    {
        Write-Warning "Repo already exists: $repositoryPath "
        return;
    }
    Push-Location $rootPath

    git clone --recurse-submodules git@github.com:meshmakers/$repositoryName.git

    Pop-Location

}

Export-ModuleMember -Function @('Invoke-CloneMainRepos')