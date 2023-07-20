
function Push-GitRepos
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]    
    param($commitMessage = "Updated")
    
    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }
    
    
    # Get all directories starting with "octo-"
    $octoDirectories = Get-ChildItem -Directory -Path $rootDirectory -Filter "octo-*"

    foreach ($directory in $octoDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            Write-Host "Pushing git repository $($directory.FullName)"
            Push-GitRepo $directory.FullName $commitMessage
        }
    }
}

Export-ModuleMember -Function @('Push-GitRepos')