<#
.Synopsis
Pushes a git repo
.Description
This function changes to the directory provided by the argument repositoryPath
and pushes existing local commits to origin.
.Parameter repositoryPath
The path to the git repository to push.
.Example
Push-GitRepo
.Example
Push-GitRepo -repositoryPath ".\my-repo"
#>
function Push-GitRepo() {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$repositoryPath = ".\"
    )

    $basedir = $PWD
    Write-Host "Pushing repository $repositoryPath"
    Set-Location $repositoryPath
    git push origin
    Set-Location $basedir
}

Export-ModuleMember -Function @('Push-GitRepo')