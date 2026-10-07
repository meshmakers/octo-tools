# Which build path Compile-Repo takes for a repository. Shared with the -DryRun plan so the plan shows
# exactly what a real run would do.
function Get-RepoBuilder {
    param(
        [Parameter(Mandatory=$true)]
        [string]$path
    )

    if (Test-Path (Join-Path -Path $path -ChildPath "build.ps1")) {
        return "build.ps1"
    }
    $solutionFiles = @(Get-ChildItem -Path $path -File | Where-Object { $_.Extension -in '.sln','.slnx' })
    if ($solutionFiles.Count -eq 0) {
        return "none"
    }
    # The repo's own name. This used to read a dynamically scoped `$directory` from the caller, which
    # for the fixed-order slots was the last mm-* directory; the outcome is the same for every repo
    # built today, but the plan must not depend on caller variables.
    $repoName = Split-Path -Leaf $path
    if ($repoName -like "*frontend*") {
        return "Invoke-Publish"
    }
    if ($repoName -like "*octo-plug-zenon*") {
        return "Invoke-BuildZenonPlug"
    }
    return "Invoke-Build"
}

function Compile-Repo {
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$path,
        [Parameter(Mandatory=$true)]
        [string]$configuration,
        # Lane settings from Get-OctoLaneBuildSettings; $null = legacy behaviour.
        $laneSettings = $null
    )

    # Isolated lane only: repos without their own <RestoreSources> would restore from the user-level
    # NuGet.Config feed, which belongs to another lane. Give them the lane feed for this repo only.
    $savedEnvironment = $null
    if ($null -ne $laneSettings) {
        $restoreSourcesOverride = Get-OctoRepoRestoreSourcesOverride -repositoryPath $path -laneSettings $laneSettings
        if ($null -ne $restoreSourcesOverride) {
            Write-Host "RestoreSources for $path -> $restoreSourcesOverride" -ForegroundColor DarkGray
            $savedEnvironment = Set-OctoBuildEnvironment -environment @{ RestoreSources = $restoreSourcesOverride }
        }
    }
    try {
        return Compile-RepoCore -branch $branch -path $path -configuration $configuration
    }
    finally {
        Restore-OctoBuildEnvironment -saved $savedEnvironment
    }
}

function Compile-RepoCore {
    param(
        [string]$branch = "",
        [Parameter(Mandatory=$true)]
        [string]$path,
        [Parameter(Mandatory=$true)]
        [string]$configuration
    )

    $builder = Get-RepoBuilder -path $path

    # Check if a custom build script exists in the repository
    if ($builder -eq "build.ps1") {
        $buildScript = Join-Path -Path $path -ChildPath "build.ps1"
        Write-Host "Found custom build script in $path" -ForegroundColor Cyan
        & $buildScript -configuration $configuration
        return $LASTEXITCODE -eq 0
    }

    # Check if a solution file exists. Match both the legacy .sln and the modern
    # XML .slnx format (dotnet 8+) — octo-communication-sdk uses the latter, and
    # a .sln-only filter was silently skipping the whole repo (return $true with
    # no build), so dependent repos (mesh-adapter etc.) tried to restore against
    # an absent Sdk.Adapters / Sdk.Pipeline package in ../nuget/.
    if ($builder -eq "none") {
        Write-Host "No solution file found in directory $( $path )" -ForegroundColor Yellow
        return $true;
    }

    [Boolean]$state = $false;
    if ($builder -eq "Invoke-Publish") {
        # frontends has to be published to build the angular app
        # -laneIsolation Off: Invoke-BuildAll/Compile-Repo already set the lane environment for this repo;
        # the nested cmdlet must neither recompute nor override it (e.g. under -laneIsolation Off).
        Invoke-Publish -repositoryPath $path -configuration $configuration -laneIsolation Off
        $state = $Global:LASTEXITCODE -eq 0
    }
    elseif ($builder -eq "Invoke-BuildZenonPlug") {
        Invoke-BuildZenonPlug -repositoryPath $path -configuration $configuration
        $state = $Global:LASTEXITCODE -eq 0
    }
    else {
        Invoke-Build -repositoryPath $path -configuration $configuration -laneIsolation Off
        $state = $Global:LASTEXITCODE -eq 0
    }

    if ($configuration -ieq "DebugL" -And $state -eq $true) {
        Copy-NuGetPackages -directory $path -branch $branch
    }

    return $state;
}

# Repositories built in this fixed order right after the mm-* libraries, because the alphabetical
# fallback would build them after their consumers.
$script:OrderedCoreRepositories = @(
    "octo-distributedEventHub"
    "octo-construction-kit-engine"
    "octo-sdk"
    "octo-construction-kit-engine-mongodb"
    "octo-common-services"
    # Phase 3: octo-communication-sdk holds the adapter/pipeline framework (formerly
    # Sdk.Common/Adapters + EtlDataPipeline + Services in octo-sdk). Depends on
    # octo-sdk so builds AFTER it; needs to build BEFORE octo-mesh-adapter and the
    # other 8 adapter consumer repos so they can restore the new packages.
    "octo-communication-sdk"
    "octo-mesh-adapter"
    "octo-bot-services"
    # octo-communication-controller-services produces Meshmakers.Octo.ConstructionKit.Models.System.Communication,
    # consumed by octo-ai-services and octo-plug-zenon. Without this explicit slot it falls into the alphabetical
    # fallback and runs after octo-ai-services (a < c), breaking the AI services restore.
    "octo-communication-controller-services"
)

# Additional repositories that other additional repositories consume. They are built first in the
# additional phase (so they still honour -excludeAdditional), before the alphabetical rest.
$script:OrderedAdditionalRepositories = @(
    # octo-plug-dilos publishes Meshmakers.Octo.Communication.Dilos(.Nodes), consumed by
    # octo-adapter-weclapp (a < p). Built against octo-communication-sdk, which is in the core order.
    "octo-plug-dilos"
)

<#
.SYNOPSIS
    The ordered list of repositories Invoke-BuildAll builds (and -DryRun prints).
#>
function Get-BuildAllPlan {
    param(
        [Parameter(Mandatory=$true)]
        [string]$branchRootPath,
        $octoDirectories,
        $mmDirectories,
        [Boolean]$excludeAdditional = $false
    )

    $plan = [System.Collections.Generic.List[object]]::new()
    $planned = @{}

    # At commom libraries we do not have a build sequence
    foreach ($directory in $mmDirectories) {
        $plan.Add([PSCustomObject][ordered]@{ name = $directory.Name; path = $directory.FullName; phase = "common" })
        $planned[$directory.Name] = $true
    }

    # Build octo repostories that first that are dependent on other repositories
    foreach ($name in $script:OrderedCoreRepositories) {
        $repoDir = Get-ChildItem -Directory -Path $branchRootPath -Filter $name
        if ($repoDir) {
            $plan.Add([PSCustomObject][ordered]@{ name = $name; path = $repoDir.FullName; phase = "ordered" })
            $planned[$name] = $true
        }
    }

    # Build the rest of the octo repositories
    if ($excludeAdditional -eq $false) {
        foreach ($name in $script:OrderedAdditionalRepositories) {
            $directory = $octoDirectories | Where-Object { $_.Name -eq $name } | Select-Object -First 1
            if ($directory -and -not $planned.ContainsKey($directory.Name)) {
                $plan.Add([PSCustomObject][ordered]@{ name = $directory.Name; path = $directory.FullName; phase = "additional-ordered" })
                $planned[$directory.Name] = $true
            }
        }
        foreach ($directory in $octoDirectories) {
            # do not build already build repositories
            if ($planned.ContainsKey($directory.Name)) {
                continue
            }
            $plan.Add([PSCustomObject][ordered]@{ name = $directory.Name; path = $directory.FullName; phase = "additional" })
            $planned[$directory.Name] = $true
        }
    }

    return $plan
}

function Invoke-BuildAll {
    param(
        [string]$configuration = "Release",
        [string]$branch = "",
        [Boolean]$excludeAdditional = $false,
        [Boolean]$excludeFrontend = $false,
        # Lane isolation (see Get-OctoLaneBuildSettings): Auto isolates every lane whose nuget/ folder is
        # not the local feed of the user-level NuGet.Config (dev); that lane (main) keeps the legacy behaviour.
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        # Print the computed plan (order, builder, lane environment, restore sources) and exit: no dotnet
        # process is killed, no package is deleted, nothing is built.
        [switch]$DryRun,
        [switch]$Json
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # `$rootPath` is set in profile.ps1 to point at the branch checkout itself
    # (`.../meshmakers/<branch>/`), so a `-branch <name>` argument that matches the leaf segment
    # would build a non-existent `.../<branch>/<branch>/` path. Normalise that here so callers can
    # pass `-branch main` from inside the `main` checkout without breaking.
    if ($branch -ne "") {
        $rootLeaf = Split-Path -Leaf ([IO.Path]::GetFullPath($rootPath))
        if ($rootLeaf -ieq $branch) {
            if (-not $Json) {
                Write-Host "Branch '$branch' already matches root leaf — using root path directly" -ForegroundColor DarkGray
            }
            $branch = ""
        }
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    # Get all directories starting with "octo-" and "mm-""
    $octoDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $mmDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"

    if ($excludeFrontend -eq $true){
        $octoDirectories = $octoDirectories | Where-Object { $_.Name -notlike "octo-frontend-*" }
    }

    $laneSettings = Get-OctoLaneBuildSettings -laneRootPath $branchRootPath -laneIsolation $laneIsolation
    $plan = Get-BuildAllPlan -branchRootPath $branchRootPath -octoDirectories $octoDirectories -mmDirectories $mmDirectories -excludeAdditional $excludeAdditional

    if ($DryRun) {
        $planEntries = @(foreach ($entry in $plan) {
            $builder = Get-RepoBuilder -path $entry.path
            [ordered]@{
                order          = $plan.IndexOf($entry) + 1
                repo           = $entry.name
                phase          = $entry.phase
                builder        = $builder
                # Override only matters where something is restored (DebugL, and a repo that actually builds).
                restoreSources = if ($configuration -ieq "DebugL" -and $builder -ne "none") { Get-OctoRepoRestoreSourcesOverride -repositoryPath $entry.path -laneSettings $laneSettings } else { $null }
            }
        })
        $data = [ordered]@{
            dryRun        = $true
            branch        = $branch
            branchRoot    = $branchRootPath
            configuration = $configuration
            lane          = $laneSettings
            repositories  = $planEntries
        }
        if ($Json) {
            Write-OctoJson -Command 'Invoke-BuildAll' -Data $data
            return
        }
        Write-Host "Dry run - nothing is killed, deleted or built" -ForegroundColor Yellow
        Write-Host "Branch root:     $branchRootPath"
        Write-Host "Configuration:   $configuration"
        Write-Host "Lane isolated:   $($laneSettings.isolated) ($($laneSettings.reason))"
        foreach ($name in $laneSettings.environment.Keys) {
            Write-Host "  env $name=$($laneSettings.environment[$name])"
        }
        foreach ($entry in $planEntries) {
            $suffix = if ($entry.restoreSources) { "  RestoreSources=$($entry.restoreSources)" } else { "" }
            Write-Host ("{0,3}. {1,-45} {2,-19} {3}{4}" -f $entry.order, $entry.repo, $entry.phase, $entry.builder, $suffix)
        }
        return
    }

    if (-not $Json) {
        Write-Host "Building all repositories in branch $branch with configuration $configuration" -ForegroundColor Green
        if ($laneSettings.isolated) {
            Write-Host "Lane isolation: $($laneSettings.reason)" -ForegroundColor Yellow
            foreach ($name in $laneSettings.environment.Keys) {
                Write-Host "  env $name=$($laneSettings.environment[$name])" -ForegroundColor Yellow
            }
        }
    }

    # kill all dotnet processes. this is necessary to avoid file locks.
    Invoke-KillDotnet

    # Check if any repositories were found
    $octoCount = if ($octoDirectories) { @($octoDirectories).Count } else { 0 }
    $mmCount = if ($mmDirectories) { @($mmDirectories).Count } else { 0 }
    if ($octoCount -eq 0 -and $mmCount -eq 0) {
        Write-Warning "No octo-* or mm-* directories found in '$branchRootPath'"
        return
    }

    # Create a dictionary that contains the directory name and a status weather the build was successful or not
    $allStatus = [ordered]@{}

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

        # Each lane restores into its own package cache (<lane>/.nuget-packages via RestorePackagesPath in
        # <lane>/Octo.User.props); clean only that one so the other lane's 999.0.0 packages stay intact.
        $laneNugetCachePath = Join-Path -Path $branchRootPath -ChildPath ".nuget-packages"
        # Forward -Json and swallow the nested emit: in JSON mode this command owes the caller ONE
        # machine-readable document, and the helper's Write-Host would break it (review).
        if ($Json) { Remove-GlobalNuGetPackages -path $laneNugetCachePath -Json | Out-Null } else { Remove-GlobalNuGetPackages -path $laneNugetCachePath }
    }

    # Lane environment (NUGET_PACKAGES, MSBUILDDISABLENODEREUSE) for the whole run; empty for the legacy
    # lane. Restored afterwards so the session is left as it was found.
    $repoLaneSettings = if ($configuration -ieq "DebugL") { $laneSettings } else { $null }
    $savedEnvironment = Set-OctoBuildEnvironment -environment $laneSettings.environment
    try {
        foreach ($entry in $plan) {
            $repoStopWatch = [System.Diagnostics.Stopwatch]::StartNew()
            [Boolean]$buildStatus = Compile-Repo -branch $branch -path $entry.path -configuration $configuration -laneSettings $repoLaneSettings
            $repoStopWatch.Stop()
            $allStatus.Add($entry.name, @{ Success = $buildStatus; Duration = $repoStopWatch.Elapsed })
        }
    }
    finally {
        Restore-OctoBuildEnvironment -saved $savedEnvironment
    }

    # Print the status of all builds
    
    # Store the count of all repositories in a variable
    $repositoryCount = $octoDirectories.Count + $mmDirectories.Count
    
    # Calculate percentage of successful builds
    $successfulBuilds = $allStatus.Values | Where-Object { $_.Success -eq $true }
    $percentageSuccessful = ($successfulBuilds.Count / $repositoryCount) * 100

    if ($Json) {
        $repoEntries = @(foreach ($key in $allStatus.Keys) {
            [ordered]@{
                repo            = $key
                success         = [bool]$allStatus[$key].Success
                durationSeconds = $allStatus[$key].Duration.TotalSeconds
            }
        })
        $data = @{
            branch        = $branch
            configuration = $configuration
            repositories  = $repoEntries
            summary       = [ordered]@{
                total             = $repositoryCount
                succeeded         = $successfulBuilds.Count
                failed            = $repositoryCount - $successfulBuilds.Count
                percentSuccessful = $percentageSuccessful
                elapsedSeconds    = $stopWatch.Elapsed.TotalSeconds
            }
        }
        Write-OctoJson -Command 'Invoke-BuildAll' -Data $data
        return
    }

    Write-Host "Summary:"
    Write-Host "---------------------------------"
    Write-Host "Build branch $branch with configuration $configuration"
    Write-Host "Building of $repositoryCount repositories took $($stopWatch.Elapsed.TotalSeconds) seconds"
    Write-Host "Percentage of successful builds: $percentageSuccessful%"
    Write-Host " "
    Write-Host "---------------------------------"
    Write-Host " "

    foreach ($key in $allStatus.Keys) {
        $entry = $allStatus[$key]
        $duration = $entry.Duration
        $timeStr = ""
        if ($duration.TotalMinutes -ge 1) {
            $timeStr = "{0:N0}m {1:N0}s" -f [math]::Floor($duration.TotalMinutes), $duration.Seconds
        }
        else {
            $timeStr = "{0:N1}s" -f $duration.TotalSeconds
        }
        if ($entry.Success) {
            Write-Host "Build of ${key} was successful ($timeStr)" -ForegroundColor Green
        }
        else {
            Write-Host "Build of ${key} failed ($timeStr)" -ForegroundColor Red
        }
    }
}


Export-ModuleMember -Function @('Invoke-BuildAll')