<#
.SYNOPSIS
    Computes how a build in a given lane checkout (e.g. meshmakers/main, meshmakers/dev) must be isolated
    from the other lanes.

.DESCRIPTION
    Several lanes (main, dev, ...) build the same DebugL 999.0.0 packages. Two things are shared between
    them by default and let one lane silently consume the other lane's packages:

      1. The user-level NuGet.Config: its local feed (`local-nuget`) points at ONE lane's `nuget/` folder
         (usually main). Every repo whose Directory.Build.props does not set its own <RestoreSources>
         restores from that feed - in the dev lane that means main packages.
      2. The package cache: repos that do not import <lane>/Octo.User.props (which sets
         RestorePackagesPath=<lane>/.nuget-packages) extract into ~/.nuget/packages, which the other lane
         writes too. NuGet keys the cache on the version only, so 999.0.0 from the other lane is reused.

    A lane is "isolated" when its own `<lane>/nuget` folder is NOT one of the local feeds in the user-level
    NuGet.Config (auto mode). The lane the config points at (main) keeps the legacy behaviour unchanged:
    no environment variable is touched and no restore source is overridden.

    For an isolated lane the build gets:
      - NUGET_PACKAGES=<lane>/.nuget-packages  (same folder Octo.User.props uses; covers repos without it)
      - MSBUILDDISABLENODEREUSE=1             (no MSBuild node carries state into/out of the other lane)
      - RestoreSources=<lane>/nuget;nuget.org  ONLY for repos whose Directory.Build.props declares no
        <RestoreSources> of its own. Repos that declare one already restore DebugL from <repo>/../nuget,
        i.e. their own lane; a blanket RestoreSources env var would even break them, because their
        `'$(RestoreSources)'==''` default (e.g. the Telerik feed in octo-report-services) would no
        longer apply.

.PARAMETER laneRootPath
    The lane checkout root that contains the repositories and the `nuget/` feed folder.

.PARAMETER laneIsolation
    Auto (default): isolate when the lane feed is not a configured local feed. On / Off force it.

.PARAMETER nugetConfigPath
    User-level NuGet.Config to inspect. Defaults to the platform location.
#>
function Get-OctoLaneBuildSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$laneRootPath,
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto',
        [string]$nugetConfigPath = ""
    )

    $laneRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($laneRootPath))
    $laneFeed = Join-Path -Path $laneRoot -ChildPath "nuget"
    $laneCache = Join-Path -Path $laneRoot -ChildPath ".nuget-packages"

    if ($nugetConfigPath -eq "") {
        $nugetConfigPath = Get-OctoUserNuGetConfigPath
    }
    $configuredLocalFeeds = @(Get-OctoConfiguredLocalNuGetFeeds -nugetConfigPath $nugetConfigPath)
    $laneFeedIsConfigured = @($configuredLocalFeeds | Where-Object { $_ -ieq $laneFeed }).Count -gt 0

    switch ($laneIsolation) {
        'On' {
            $isolated = $true
            $reason = "forced by -laneIsolation On"
        }
        'Off' {
            $isolated = $false
            $reason = "disabled by -laneIsolation Off"
        }
        default {
            if ($configuredLocalFeeds.Count -eq 0) {
                $isolated = $false
                $reason = "no local feed in $nugetConfigPath - legacy behaviour"
            }
            elseif ($laneFeedIsConfigured) {
                $isolated = $false
                $reason = "lane feed $laneFeed is the configured local feed - legacy behaviour"
            }
            else {
                $isolated = $true
                $reason = "configured local feed(s) $($configuredLocalFeeds -join ', ') belong to another lane"
            }
        }
    }

    $environment = [ordered]@{}
    $restoreSourcesOverride = $null
    if ($isolated) {
        $environment['NUGET_PACKAGES'] = $laneCache
        $environment['MSBUILDDISABLENODEREUSE'] = '1'
        $restoreSourcesOverride = "$laneFeed;https://api.nuget.org/v3/index.json"
    }

    return [PSCustomObject][ordered]@{
        laneRoot               = $laneRoot
        laneFeed               = $laneFeed
        laneCache              = $laneCache
        isolated               = $isolated
        reason                 = $reason
        nugetConfigPath        = $nugetConfigPath
        configuredLocalFeeds   = $configuredLocalFeeds
        environment            = $environment
        restoreSourcesOverride = $restoreSourcesOverride
    }
}

function Get-OctoUserNuGetConfigPath {
    if ($IsWindows) {
        return Join-Path -Path $env:APPDATA -ChildPath "NuGet/NuGet.Config"
    }
    $userHome = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    return Join-Path -Path $userHome -ChildPath ".nuget/NuGet/NuGet.Config"
}

function Get-OctoConfiguredLocalNuGetFeeds {
    param(
        [string]$nugetConfigPath
    )

    if (-not (Test-Path -Path $nugetConfigPath -PathType Leaf)) {
        return @()
    }

    try {
        [xml]$config = Get-Content -Path $nugetConfigPath -Raw
    }
    catch {
        Write-Warning "Cannot parse $nugetConfigPath - lane isolation falls back to legacy behaviour: $_"
        return @()
    }

    $feeds = @()
    foreach ($source in @($config.configuration.packageSources.add)) {
        if ($null -eq $source) { continue }
        $value = [string]$source.value
        if ($value -match '^[a-zA-Z][a-zA-Z0-9+.-]*://') { continue }   # http(s) feeds
        if (-not [IO.Path]::IsPathRooted($value)) { continue }
        $feeds += [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($value))
    }
    return $feeds
}

<#
.SYNOPSIS
    Returns the RestoreSources override for one repository of an isolated lane, or $null.

.DESCRIPTION
    Only repos whose Directory.Build.props declares no <RestoreSources> get the lane feed injected (they
    would otherwise fall back to the user-level NuGet.Config, i.e. another lane's feed). Repos that
    declare one keep their own value, which already points DebugL at <repo>/../nuget.
#>
function Get-OctoRepoRestoreSourcesOverride {
    param(
        [Parameter(Mandatory = $true)]
        [string]$repositoryPath,
        [Parameter(Mandatory = $true)]
        $laneSettings
    )

    if (-not $laneSettings.isolated) {
        return $null
    }
    $props = Join-Path -Path $repositoryPath -ChildPath "Directory.Build.props"
    if ((Test-Path -Path $props -PathType Leaf) -and (Select-String -Path $props -Pattern '<RestoreSources' -SimpleMatch -Quiet)) {
        return $null
    }
    return $laneSettings.restoreSourcesOverride
}

<#
.SYNOPSIS
    Sets process environment variables and returns the previous values for Restore-OctoBuildEnvironment.
#>
function Set-OctoBuildEnvironment {
    param(
        [System.Collections.IDictionary]$environment
    )

    $saved = [ordered]@{}
    if ($null -eq $environment) {
        return $saved
    }
    foreach ($name in $environment.Keys) {
        $saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
        [System.Environment]::SetEnvironmentVariable($name, [string]$environment[$name])
    }
    return $saved
}

function Restore-OctoBuildEnvironment {
    param(
        [System.Collections.IDictionary]$saved
    )

    if ($null -eq $saved) {
        return
    }
    foreach ($name in $saved.Keys) {
        if ($null -eq $saved[$name]) {
            # Was unset before: remove it again so a lane build leaves no trace in the session. Do NOT pass
            # $null to SetEnvironmentVariable - PowerShell converts it to "" and the variable stays defined.
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            [System.Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

Export-ModuleMember -Function @(
    'Get-OctoLaneBuildSettings',
    'Get-OctoRepoRestoreSourcesOverride',
    'Set-OctoBuildEnvironment',
    'Restore-OctoBuildEnvironment'
)
