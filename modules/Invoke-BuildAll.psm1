function Invoke-BuildAll
{
    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"
    
    foreach ($directory in $allDirectories) {

        # Check if a solution file exists
        $solutionFiles = Get-ChildItem -Path $directory.FullName -Filter "*.sln"

        # ensure there is a solution file and the directory name does not contain "octo-frontend-admin-panel"
        Write-Host "Directory Fullname: $($directory.FullName)"
        Write-Host "Directory Name: $($directory.Name)"
        
        if (($solutionFiles.Count -gt 0) -and ($directory.Name -ne "octo-frontend-admin-panel")) {
            Write-Host "Building git repository $($directory.FullName)" -ForegroundColor Green
            Invoke-Build $directory.FullName

        }elseif ($directory.Name -eq "octo-frontend-admin-panel") { # admin panel has to be published to build the angular app
            #Write-Host "Publishing git repository $($directory.FullName)" -ForegroundColor Green
            #Invoke-Publish $directory.FullName
        }        
    }
}


Export-ModuleMember -Function @('Invoke-BuildAll')