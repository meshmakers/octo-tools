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
    Write-Host Handling directory $repositoryPath
    Set-Location $repositoryPath
    git config pull.rebase true
    git pull origin
    if ($LASTEXITCODE -ne 0)
    {
        throw "Git update failed"
    }
    Set-Location $basedir
}

Export-ModuleMember -Function @('Sync-GitRepo')