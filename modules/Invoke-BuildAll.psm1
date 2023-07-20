function Invoke-BuildAll
{
    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-"
    $octoDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"

    foreach ($directory in $octoDirectories) {

        # Check if a solution file exists
        $solutionFiles = Get-ChildItem -Path $directory.FullName -Filter "*.sln"

        if ($solutionFiles.Count -gt 0) {
            
            Write-Host "Building git repository $($directory.FullName)"
            Invoke-Build $directory.FullName
        }
    }
}


Export-ModuleMember -Function @('Invoke-BuildAll')