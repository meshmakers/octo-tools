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
        [string]$repositoryPath = ".\",
        [switch]$Json
    )

    $basedir = $PWD
    if (-not $Json) { Write-Host "Pushing repository $repositoryPath" }
    Set-Location $repositoryPath
    git push origin
    $exitCode = $LASTEXITCODE
    Set-Location $basedir

    if ($Json) {
        Write-OctoJson -Command 'Push-GitRepo' -Data (New-OctoActionResult -Success ($exitCode -eq 0) -ExitCode $exitCode)
        return
    }
}

Export-ModuleMember -Function @('Push-GitRepo')