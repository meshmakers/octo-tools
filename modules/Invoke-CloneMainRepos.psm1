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
        [string]$branch = "",
        [switch]$Json
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

    if (-not $Json) { Write-Host "Cloning repositories to $branchRootPath" -ForegroundColor Green }

    $repoNames = @(
        "mm-common"
        "octo-distributedEventHub"
        "octo-construction-kit-engine"
        "octo-construction-kit-engine-mongodb"
        "octo-sdk"
        "octo-common-services"
        # Phase 3 of the YAML migration: adapter/pipeline framework lives here, carved
        # out of octo-sdk (Sdk.Common/Adapters + EtlDataPipeline + Services + the
        # Plug.Simulation / SimulationNodes / CommunicationAdapter / Common.Web projects).
        # Depends on octo-sdk via Meshmakers.Octo.Sdk.Common / .ServiceClient packages.
        "octo-communication-sdk"
        "octo-construction-kit"
        "octo-cli"
        "octo-identity-services"
        "octo-asset-repo-services"
        "octo-bot-services"
        "octo-mesh-adapter"
        "octo-communication-controller-services"
        "octo-communication-operator"
        "octo-platform-services"
        # Ships the CRDs + Communication Operator Helm charts; required by the local kind
        # dev env (Install-OctoKubernetes / Deploy-OctoOperator) which read them from
        # octo-helm-core/src/. Easy to miss because it isn't a .NET service repo.
        "octo-helm-core"
        "octo-frontend-libraries"
        "octo-frontend-refinery-studio"
    )

    $repoResults = [System.Collections.Generic.List[object]]::new()
    $allOk = $true

    foreach ($repoName in $repoNames) {
        # Reset so an already-exists early-return (no git run) counts as success
        # rather than inheriting a stale exit code from a previous clone.
        $global:LASTEXITCODE = 0
        Clone-Repo -branch $branch $repoName
        $repoSuccess = ($LASTEXITCODE -eq 0)
        if (-not $repoSuccess) { $allOk = $false }
        if ($Json) {
            $repoResults.Add([ordered]@{ repo = $repoName; success = [bool]$repoSuccess }) | Out-Null
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Invoke-CloneMainRepos' -Data (New-OctoActionResult -Success ([bool]$allOk) -Extra @{ repositories = @($repoResults) })
        return
    }
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