<#
.SYNOPSIS
    Shared helpers of New-TestBranch, Sync-TestBranch and Remove-TestBranch (AB#9259).

.DESCRIPTION
    - Get-OctoMainRepoNames: the one list of repositories that Invoke-CloneMainRepos clones and the
      test-branch cmdlets branch, sync and remove.
    - Resolve-OctoTestBranchRoot: the checkout directory of a pre-release 0.x line. Without -Branch it is
      <parent of rootPath>/0.<n>-<description>; an explicit -Branch is a folder relative to rootPath, as before.
    - Get-OctoTestBranchRepoDirectories: the existing git checkouts of that list inside a directory.
#>

function Get-OctoMainRepoNames {
    <#
    .SYNOPSIS
        Names of the main OctoMesh repositories (clone order).
    #>
    return @(
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
}

function Resolve-OctoTestBranchRoot {
    <#
    .SYNOPSIS
        Directory that holds the repositories of the pre-release line test/0.<n>-<description>.
    .PARAMETER Branch
        Explicit folder relative to RootPath. Empty: <parent of RootPath>/0.<n>-<description>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$MinorVersion,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$Branch = '',
        [Parameter(Mandatory = $true)][string]$RootPath
    )

    if ($Branch) {
        return Join-Path -Path $RootPath -ChildPath $Branch
    }
    $parent = Split-Path -Parent ([IO.Path]::TrimEndingDirectorySeparator($PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RootPath)))
    return Join-Path -Path $parent -ChildPath "0.$MinorVersion-$Description"
}

function Get-OctoTestBranchRepoDirectories {
    <#
    .SYNOPSIS
        The git checkouts of Get-OctoMainRepoNames that exist in Root (others are skipped, so older
        checkouts such as dev or demo that miss a repository keep working).
    #>
    param([Parameter(Mandatory = $true)][string]$Root)

    foreach ($name in (Get-OctoMainRepoNames)) {
        $path = Join-Path -Path $Root -ChildPath $name
        if ((Test-Path -LiteralPath $path -PathType Container) -and (Test-Path -LiteralPath (Join-Path $path '.git'))) {
            Get-Item -LiteralPath $path
        }
    }
}

Export-ModuleMember -Function @('Get-OctoMainRepoNames', 'Resolve-OctoTestBranchRoot', 'Get-OctoTestBranchRepoDirectories')
