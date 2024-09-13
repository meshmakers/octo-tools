function Compile-Repo {
    param(
        [Parameter(Mandatory=$true)]
        [string]$path,
        [Parameter(Mandatory=$true)]
        [string]$configuration
    )
    # Check if a solution file exists
    $solutionFiles = Get-ChildItem -Path $path -Filter "*.sln"
    if ($solutionFiles.Count -eq 0) {
        Write-Host "No solution file found in directory $( $path )" -ForegroundColor Yellow
        return $true;
    }

    [Boolean]$state = $false;
    if ($directory.Name -like "*frontend*") {
        # frontends has to be published to build the angular app
        Invoke-Publish -repositoryPath $path -configuration $configuration
        $state = $Global:LASTEXITCODE -eq 0
    }
    else {
        Invoke-Build -repositoryPath $path -configuration $configuration
        $state = $Global:LASTEXITCODE -eq 0
    }

    if ($configuration -ieq "DebugL" -And $state -eq $true) {
        Copy-NuGetPackages -directory $path
    }
    
    return $state;
}

function Compile-RepoIfExists
{
    param(
        [Parameter(Mandatory=$true)]
        [string]$name,
        [Parameter(Mandatory=$true)]
        [string]$configuration,
        [Parameter(Mandatory=$true)]
        [hashtable]$status
    )

    $repoDir = Get-ChildItem -Directory -Path $rootPath -Filter $name
    if ($repoDir) {
        [Boolean]$buildStatus = Compile-Repo -path $repoDir.FullName -configuration $configuration
        $status.Add($name, $buildStatus)
    }
}

function Invoke-BuildAll {
    param(
        [string]$configuration = "Release",
        [Boolean]$excludeAdditional = $false,
        [Boolean]$excludeFrontend = $false
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # kill all dotnet processes. this is necessary to avoid file locks.
    Invoke-KillDotnet

    # Get all directories starting with "octo-" and "mm-""
    $octoDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $mmDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"
    
    if ($excludeFrontend -eq $true){
        $octoDirectories = $octoDirectories | Where-Object { $_.Name -notlike "octo-frontend-*" }
    }
    
    # Create a dictionary that contains the directory name and a status weather the build was successful or not
    $allStatus = @{}

    # Start a timer
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($configuration -ieq "DebugL"){
        # Kill all dotnet processes. This is necessary to avoid file locks.
        Invoke-KillDotnet

        # Delete all nuget packages in the octo mesh nuget folder
        Get-ChildItem -Path $nugetPath -File | Remove-Item -Force
        
        Remove-GlobalNuGetPackages
    }

    # At commom libraries we do not have a build sequence
    foreach ($directory in $mmDirectories) {
        [Boolean]$buildStatus = Compile-Repo -path $directory.FullName -configuration $configuration
        $allStatus.Add($directory.Name, $buildStatus)
    }
    
    # Build octo repostories that first that are dependent on other repositories
    Compile-RepoIfExists -name "octo-distributedEventHub" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -name "octo-construction-kit-engine" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -name "octo-sdk" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -name "octo-construction-kit-engine-mongodb" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -name "octo-common-services" -configuration $configuration -status $allStatus
    
    # Build the rest of the octo repositories
    if ($excludeAdditional -eq $false) {
        foreach ($directory in $octoDirectories) {

            # do not build already build repositories
            if ($allStatus.ContainsKey($directory.Name)) {
                continue
            }

            [Boolean]$buildStatus = Compile-Repo -path $directory.FullName -configuration $configuration
            $allStatus.Add($directory.Name, $buildStatus)
        }
    }

    # Print the status of all builds
    
    # Store the count of all repositories in a variable
    $repositoryCount = $octoDirectories.Count + $mmDirectories.Count
    
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