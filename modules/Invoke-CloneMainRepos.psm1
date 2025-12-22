<#
.Synopsis
Clones all main OctoMesh repositories
.Description
This function clones all major git repositories of
OctoMesh from GitHub
.Example
 Invoke-CloneMainRepos
.Example
 Invoke-CloneMainRepos -branch "branches/queries"
#>
function Global:Invoke-CloneMainRepos {
    param(
        [string]$branch = ""
    )

    if (!(Test-Path $rootPath))
    {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    # Ensure the branch directory exists
    if (!(Test-Path $branchRootPath)) {
        Write-Host "Creating directory $branchRootPath" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $branchRootPath | Out-Null
    }

    Write-Host "Cloning repositories to $branchRootPath" -ForegroundColor Green
    Clone-Repo -branch $branch "mm-common"
    Clone-Repo -branch $branch "octo-distributedEventHub"
    Clone-Repo -branch $branch "octo-construction-kit-engine"
    Clone-Repo -branch $branch "octo-construction-kit-engine-mongodb"
    Clone-Repo -branch $branch "octo-sdk"
    Clone-Repo -branch $branch "octo-common-services"
    Clone-Repo -branch $branch "octo-construction-kit"
    Clone-Repo -branch $branch "octo-cli"
    Clone-Repo -branch $branch "octo-identity-services"
    Clone-Repo -branch $branch "octo-asset-repo-services"
    Clone-Repo -branch $branch "octo-bot-services"
    Clone-Repo -branch $branch "octo-mesh-adapter"
    Clone-Repo -branch $branch "octo-communication-controller-services"
    Clone-Repo -branch $branch "octo-communication-operator"
    Clone-Repo -branch $branch "octo-frontend-admin-panel"
    Clone-Repo -branch $branch "octo-frontend-libraries"
    Clone-Repo -branch $branch "octo-frontend-refinery-studio"
}

function Clone-Repo
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$repositoryName
    )

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $repositoryPath = Join-Path -Path $branchRootPath -ChildPath $repositoryName
    if (Test-Path $repositoryPath)
    {
        Write-Warning "Repo already exists: $repositoryPath"
        return;
    }
    Push-Location $branchRootPath

    git clone --recurse-submodules git@github.com:meshmakers/$repositoryName.git

    Pop-Location

}

Export-ModuleMember -Function @('Invoke-CloneMainRepos')