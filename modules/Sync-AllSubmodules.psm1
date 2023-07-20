
function Sync-AllSubmodules
{
    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

     # Get all directories starting with "octo-"
    $octoDirectories = Get-ChildItem -Directory -Path $rootDirectory -Filter "octo-*"

    foreach ($directory in $octoDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        $modulesFile = Join-Path -Path $directory.FullName -ChildPath ".gitmodules"
        
        # Check if the ".git" directory exists
        if ((Test-Path -Path $gitDirectory -PathType Container) -And (Test-Path -Path $modulesFile)) {
            Write-Host "Pulling git repository $($directory.FullName)"
            Pull-Submodule $directory.FullName $commitMessage
        }
    }
}

Export-ModuleMember -Function @('Sync-AllSubmodules')