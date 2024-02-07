function Invoke-BuildAll
{
    param(
        [string]$configuration = "Release"
    )

    if (!(Test-Path $rootPath))
    {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    foreach ($directory in $allDirectories)
    {

        # Check if a solution file exists
        $solutionFiles = Get-ChildItem -Path $directory.FullName -Filter "*.sln"

        # ensure there is a solution file and the directory name does not contain "octo-frontend-admin-panel"
        Write-Host "Directory Fullname: $( $directory.FullName )"
        Write-Host "Directory Name: $( $directory.Name )"

        if ($directory.Name -like "*frontend*")
        {
            # frontends has to be published to build the angular app
            Invoke-Publish -repositoryPath $directory.FullName -configuration $configuration
        }
        else
        {
            Invoke-Build -repositoryPath $directory.FullName -configuration $configuration
        }
    }
}


Export-ModuleMember -Function @('Invoke-BuildAll')