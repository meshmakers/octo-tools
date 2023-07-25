<#
.Synopsis
Pushs a git repo
.Description
This function changes to the directory provides by the argument repositoryPath,
configures pushs to origin
.Example
Push-GitRepo
.Example
 # This is function is called by convention in PowerShell
 function prompt {
     Push-GitRepo
 }
#>
function Push-GitRepo() {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$repositoryPath = ".\", [string]$commitMessage = "Updated")

    $basedir = $PWD
    Write-Host Handling directory $repositoryPath
    Set-Location $repositoryPath
    git add .
    git commit -m $commitMessage
    git push origin
    Set-Location $basedir
}

Export-ModuleMember -Function @('Push-GitRepo')