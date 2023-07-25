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
function Sync-Submodule {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($repositoryPath = ".\")

    $basedir = $PWD
    Write-Host Handling directory $repositoryPath
    Set-Location $repositoryPath
    git submodule update --remote
    Set-Location $basedir
}

Export-ModuleMember -Function @('Sync-Submodule')