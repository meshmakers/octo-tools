function Invoke-BuildAll {
    param(
        [string]$configuration = "Release"
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    # Create a dictionary that contains the directory name and a status weather the build was successful or not
    $allStatus = @{}

    # Start a timer
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()


    foreach ($directory in $allDirectories) {

        # Check if a solution file exists
        $solutionFiles = Get-ChildItem -Path $directory.FullName -Filter "*.sln"
        if ($solutionFiles.Count -eq 0) {
            Write-Host "No solution file found in directory $( $directory.FullName )" -ForegroundColor Red
            continue
        }

        
        if ($directory.Name -like "*frontend*") {
            # frontends has to be published to build the angular app
            Invoke-Publish -repositoryPath $directory.FullName -configuration $configuration
        }
        else {
            Invoke-Build -repositoryPath $directory.FullName -configuration $configuration
        }

        $buildStatus = $global:LASTEXITCODE -eq 0
        $allStatus.Add($directory.Name, $buildStatus)
    }



    # Print the status of all builds
    
    # Store the count of all repositories in a variable
    $repositoryCount = $allDirectories.Count
    
    # Calculate percentage of successful builds
    $successfulBuilds = $allStatus.Values | Where-Object { $_ -eq $true }
    $percentageSuccessful = ($successfulBuilds.Count / $repositoryCount) * 100

    Write-Host "Summary:"
    Write-Host "---------------------------------"
    Write-Host "Building of $repositoryCount repositories took $($stopWatch.Elapsed.TotalSeconds) seconds"
    Write-Host "Percentage of successful builds: $percentageSuccessful%"
    Write-Host " "
    Write-Host "---------------------------------"
    Write-Host " "

    foreach ($key in $allStatus.Keys) {
        $wasSuccessful = $allStatus[$key]
        if ($wasSuccessful) {
            Write-Host "Build of ${key} was successful" -ForegroundColor Green
        }
        else {
            Write-Host "Build of ${key} failed" -ForegroundColor Red
        }
    }
}


Export-ModuleMember -Function @('Invoke-BuildAll')