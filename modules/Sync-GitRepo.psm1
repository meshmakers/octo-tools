<#
.Synopsis
Pulls the given git repository
.Description
This function pulls the git repository given at parameter
repositoryPath
.Example
Invoke-PullGitRepo
.Example
 # This is function is called by convention in PowerShell
 function prompt {
     Pull-GitRepo
 }
#>
function Sync-GitRepo {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($repositoryPath = ".\")

    $basedir = $PWD
    Write-Host Pulling directory $repositoryPath
    Push-Location $repositoryPath
    git config pull.rebase true
    git pull origin --recurse-submodules
    if ($LASTEXITCODE -ne 0)
    {
        throw "Git pull failed"
    }

    Pop-Location
}

Export-ModuleMember -Function @('Sync-GitRepo')