<#
.Synopsis
Updates submodules of git repositories including commit and push.
.Description
This function changes to the directory provides by the argument repositoryPath,
configures to use pull.rebase option, pulls from origin and updates the submodules
from remote. After that the changes are commited and pushed.
.Example
 Set-PsEnv
.Example
 # This is function is called by convention in PowerShell
 function prompt {
     Update-GitSubmodules
 }
#>
function Push-GitRepo() {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$repositoryPath = ".\", [string]$commitMessage = "Updated")

    $basedir = $PWD
    Write-Host Handling directory $repositoryPath
    Set-Location $repositoryPath
    git config pull.rebase true
    git pull origin
  
    git commit -m $commitMessage
    git push origin
    Set-Location $basedir
}

Export-ModuleMember -Function @('Push-GitRepo')