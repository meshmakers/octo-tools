
function Update-GitReposAndSubmodules
{
    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $path = Join-Path $rootPath "octo-common-services"
    Update-GitSubmodules $path
    $path = Join-Path $rootPath "octo-asset-repo-services"
    Update-GitSubmodules $path
    $path = Join-Path $rootPath "octo-bot-services"
    Update-GitSubmodules $path
    $path = Join-Path $rootPath "octo-identity-services"
    Update-GitSubmodules $path
    $path = Join-Path $rootPath "octo-time-series-repo-services"
    Update-GitSubmodules $path
    $path = Join-Path $rootPath "octo-communication-controller-services"
    Update-GitSubmodules $path
}

Export-ModuleMember -Function @('Update-GitReposAndSubmodules')