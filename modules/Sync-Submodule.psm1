<#
.Synopsis
Updates submodules of git repositories including submodules
.Description
This function changes to the directory provides by the argument repositoryPath
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
    git submodule update --init  --remote --merge --recursive
    Set-Location $basedir
}

Export-ModuleMember -Function @('Sync-Submodule')