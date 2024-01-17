function Sync-AllGitRepos {

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-"
    $octoDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"

    foreach ($directory in $octoDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            Write-Host "Pulling git repository $($directory.FullName)" -ForegroundColor Green
            Sync-GitRepo $directory.FullName
        }
    }
    
    Write-Host "Done"
    Write-Host "To sync all submodules use 'Sync-AllSubmodules'"
}

Export-ModuleMember -Function @('Sync-AllGitRepos')