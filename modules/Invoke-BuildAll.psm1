function Compile-Repo {
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$path,
        [Parameter(Mandatory=$true)]
        [string]$configuration
    )

    # Check if a custom build script exists in the repository
    $buildScript = Join-Path -Path $path -ChildPath "build.ps1"
    if (Test-Path $buildScript) {
        Write-Host "Found custom build script in $path" -ForegroundColor Cyan
        & $buildScript -configuration $configuration
        return $LASTEXITCODE -eq 0
    }

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
    elseif ($directory.Name -like "*octo-plug-zenon*") {
        Invoke-BuildZenonPlug -repositoryPath $path -configuration $configuration
        $state = $Global:LASTEXITCODE -eq 0
    }
    else {
        Invoke-Build -repositoryPath $path -configuration $configuration
        $state = $Global:LASTEXITCODE -eq 0
    }

    if ($configuration -ieq "DebugL" -And $state -eq $true) {
        Copy-NuGetPackages -directory $path -branch $branch
    }

    return $state;
}

function Compile-RepoIfExists
{
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$name,
        [Parameter(Mandatory=$true)]
        [string]$configuration,
        [Parameter(Mandatory=$true)]
        [hashtable]$status
    )

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $repoDir = Get-ChildItem -Directory -Path $branchRootPath -Filter $name
    if ($repoDir) {
        [Boolean]$buildStatus = Compile-Repo -branch $branch -path $repoDir.FullName -configuration $configuration
        $status.Add($name, $buildStatus)
    }
}

function Invoke-BuildAll {
    param(
        [string]$configuration = "Release",
        [string]$branch = "",
        [Boolean]$excludeAdditional = $false,
        [Boolean]$excludeFrontend = $false
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    Write-Host "Building all repositories in branch $branch with configuration $configuration" -ForegroundColor Green

    # kill all dotnet processes. this is necessary to avoid file locks.
    Invoke-KillDotnet

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    # Get all directories starting with "octo-" and "mm-""
    $octoDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $mmDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"
    
    if ($excludeFrontend -eq $true){
        $octoDirectories = $octoDirectories | Where-Object { $_.Name -notlike "octo-frontend-*" }
    }

    # Check if any repositories were found
    $octoCount = if ($octoDirectories) { @($octoDirectories).Count } else { 0 }
    $mmCount = if ($mmDirectories) { @($mmDirectories).Count } else { 0 }
    if ($octoCount -eq 0 -and $mmCount -eq 0) {
        Write-Warning "No octo-* or mm-* directories found in '$branchRootPath'"
        return
    }

    # Create a dictionary that contains the directory name and a status weather the build was successful or not
    $allStatus = @{}

    # Start a timer
    $stopWatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($configuration -ieq "DebugL"){
        # Kill all dotnet processes. This is necessary to avoid file locks.
        Invoke-KillDotnet

        # Delete all nuget packages in the octo mesh nuget folder
        $branchNugetPath = Join-Path -Path $branchRootPath -ChildPath "nuget"
        # Ensure the nuget directory exists
        if (!(Test-Path $branchNugetPath)) {
            Write-Host "Creating directory $branchNugetPath" -ForegroundColor Yellow
            New-Item -ItemType Directory -Path $branchNugetPath | Out-Null
        }
        Get-ChildItem -Path $branchNugetPath -File | Remove-Item -Force

        Remove-GlobalNuGetPackages -branch $branch
    }


    # At commom libraries we do not have a build sequence
    foreach ($directory in $mmDirectories) {
        [Boolean]$buildStatus = Compile-Repo -branch $branch -path $directory.FullName -configuration $configuration
        $allStatus.Add($directory.Name, $buildStatus)
    }
    
    # Build octo repostories that first that are dependent on other repositories
    Compile-RepoIfExists -branch $branch -name "octo-distributedEventHub" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -branch $branch -name "octo-construction-kit-engine" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -branch $branch -name "octo-sdk" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -branch $branch -name "octo-construction-kit-engine-mongodb" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -branch $branch -name "octo-common-services" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -branch $branch -name "octo-mesh-adapter" -configuration $configuration -status $allStatus
    Compile-RepoIfExists -branch $branch -name "octo-bot-services" -configuration $configuration -status $allStatus

    # Build the rest of the octo repositories
    if ($excludeAdditional -eq $false) {
        foreach ($directory in $octoDirectories) {

            # do not build already build repositories
            if ($allStatus.ContainsKey($directory.Name)) {
                continue
            }

            [Boolean]$buildStatus = Compile-Repo -branch $branch -path $directory.FullName -configuration $configuration
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
    Write-Host "Build branch $branch with configuration $configuration"
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