
function Sync-AllSubmodules
{
    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        $modulesFile = Join-Path -Path $directory.FullName -ChildPath ".gitmodules"
        
        # Check if the ".git" directory exists
        if ((Test-Path -Path $gitDirectory -PathType Container) -And (Test-Path -Path $modulesFile)) {
            Write-Host "Pulling git repository $($directory.FullName)"
            Sync-Submodule $directory.FullName
        }
    }
}

Export-ModuleMember -Function @('Sync-AllSubmodules')