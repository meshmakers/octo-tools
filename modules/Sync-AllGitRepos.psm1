function Sync-AllGitRepos {

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"
    $status = @{}
    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            try {
                Write-Host "Pulling git repository $($directory.FullName)" -ForegroundColor Green
                Sync-GitRepo $directory.FullName
                $status.Add($directory.FullName, $true)
            }
            catch {
                Write-Host "Error pulling git repository $($directory.FullName)" -ForegroundColor Red
                $status.Add($directory.FullName, $false)
            }
        }
    }
    
    foreach($key in $status.Keys) {
        if($status[$key] -eq $true) {
            Write-Host "Pulling repository ${key} was successful.)" -ForegroundColor Green
        }else {
            Write-Host "Pulling repository ${key} failed." -ForegroundColor Red
        }
    }

    Write-Host " "
    Write-Host "Done"
    Write-Host "To sync all submodules use 'Sync-AllSubmodules'"
}

Export-ModuleMember -Function @('Sync-AllGitRepos')