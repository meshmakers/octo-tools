<#
.SYNOPSIS
    Computes how a build in a given lane checkout (branches/main, branches/dev, wt-<env>, ...) must be
    isolated from the other lanes.

.DESCRIPTION
    Several lanes (main, dev, feature environments) build the same DebugL 999.0.0 packages. NuGet keys its
    package cache on id and version only, so a shared ~/.nuget/packages lets whichever lane restored last
    poison the others.

    A lane is "isolated" exactly when its <lane>/Octo.User.props declares <RestorePackagesPath> (written by
    Initialize-OctoLaneUserProps and New-OctoEnvironment as $(MSBuildThisFileDirectory).nuget-packages).
    Every repo's Directory.Build.props imports that file, so Rider and plain dotnet builds use the lane
    cache too; this command makes the octo-tools builds match it. The user-level NuGet.Config is not
    consulted. A lane without the line (a checkout that was never switched) keeps the legacy behaviour:
    shared ~/.nuget/packages, no environment variables, no restore source override.

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
    Auto (default): isolate when <lane>/Octo.User.props declares RestorePackagesPath. On / Off force it.
#>
function Get-OctoLaneBuildSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$laneRootPath,
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto'
    )

    $laneRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($laneRootPath))
    $laneFeed = Join-Path -Path $laneRoot -ChildPath "nuget"
    $laneCache = Join-Path -Path $laneRoot -ChildPath ".nuget-packages"
    $laneUserProps = Join-Path -Path $laneRoot -ChildPath "Octo.User.props"
    $declaresRestorePackagesPath = Test-OctoLaneUserPropsRestorePackagesPath -propsPath $laneUserProps

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
            if ($declaresRestorePackagesPath) {
                $isolated = $true
                $reason = "$laneUserProps declares RestorePackagesPath - lane-local package cache"
            }
            elseif (Test-Path -Path $laneUserProps -PathType Leaf) {
                $isolated = $false
                $reason = "$laneUserProps declares no RestorePackagesPath - legacy behaviour (Initialize-OctoLaneUserProps -AddRestorePackagesPath isolates the lane)"
            }
            else {
                # No Octo.User.props: not a lane checkout (a repo built with Invoke-Build outside the lanes)
                # or a lane that was never initialized. Never invent a cache next to it.
                $isolated = $false
                $reason = "no Octo.User.props in $laneRoot - legacy behaviour"
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
        laneRoot                    = $laneRoot
        laneFeed                    = $laneFeed
        laneCache                   = $laneCache
        isolated                    = $isolated
        reason                      = $reason
        userPropsPath               = $laneUserProps
        declaresRestorePackagesPath = $declaresRestorePackagesPath
        environment                 = $environment
        restoreSourcesOverride      = $restoreSourcesOverride
    }
}

<#
.SYNOPSIS
    $true when the given Octo.User.props declares a <RestorePackagesPath> property.
#>
function Test-OctoLaneUserPropsRestorePackagesPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$propsPath
    )

    if (-not (Test-Path -Path $propsPath -PathType Leaf)) {
        return $false
    }
    $text = Get-Content -Path $propsPath -Raw
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $false
    }
    try {
        [xml]$xml = $text
    }
    catch {
        Write-Warning "Cannot parse $propsPath - treated as declaring no RestorePackagesPath: $_"
        return $false
    }
    $nodes = $xml.SelectNodes("//*[local-name()='RestorePackagesPath']")
    return ($null -ne $nodes -and $nodes.Count -gt 0)
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
    # Like MSBuild, take the nearest Directory.Build.props above the path (Invoke-Publish may be pointed
    # at a project folder inside the repo), but never look above the lane root.
    $directory = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($repositoryPath))
    while ($directory -and $directory.StartsWith($laneSettings.laneRoot, [StringComparison]::OrdinalIgnoreCase) -and $directory -ine $laneSettings.laneRoot) {
        $props = Join-Path -Path $directory -ChildPath "Directory.Build.props"
        if (Test-Path -Path $props -PathType Leaf) {
            if (Select-String -Path $props -Pattern '<RestoreSources' -SimpleMatch -Quiet) {
                return $null
            }
            break
        }
        $directory = Split-Path -Parent $directory
    }
    return $laneSettings.restoreSourcesOverride
}

<#
.SYNOPSIS
    The lane checkout a repository (or a folder inside it) belongs to: the nearest ancestor that holds an
    Octo.User.props - the same file MSBuild finds via GetPathOfFileAbove. $null outside any lane.
#>
function Find-OctoLaneRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$path
    )

    $directory = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($path))
    while ($directory) {
        if (Test-Path -Path (Join-Path -Path $directory -ChildPath "Octo.User.props") -PathType Leaf) {
            return $directory
        }
        $parent = Split-Path -Parent $directory
        if ($parent -eq $directory) { break }
        $directory = $parent
    }
    return $null
}

<#
.SYNOPSIS
    Lane settings plus the complete environment for building ONE repository (Invoke-Build, Invoke-Publish).

.DESCRIPTION
    Same rules as Invoke-BuildAll: an isolated lane gets NUGET_PACKAGES + MSBUILDDISABLENODEREUSE, and in
    DebugL a repo without its own <RestoreSources> additionally gets RestoreSources. Outside a lane, and in
    a lane whose Octo.User.props declares no RestorePackagesPath, the environment is empty (legacy behaviour).
#>
function Get-OctoRepositoryBuildEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$repositoryPath,
        [string]$configuration = "Release",
        [ValidateSet('Auto', 'On', 'Off')]
        [string]$laneIsolation = 'Auto'
    )

    $environment = [ordered]@{}
    $laneRoot = Find-OctoLaneRoot -path $repositoryPath
    if ($null -eq $laneRoot) {
        return [PSCustomObject][ordered]@{
            laneRoot    = $null
            isolated    = $false
            reason      = "no Octo.User.props above $repositoryPath - not a lane checkout, legacy behaviour"
            environment = $environment
        }
    }

    $laneSettings = Get-OctoLaneBuildSettings -laneRootPath $laneRoot -laneIsolation $laneIsolation
    foreach ($name in $laneSettings.environment.Keys) {
        $environment[$name] = $laneSettings.environment[$name]
    }
    if ($configuration -ieq "DebugL") {
        $restoreSourcesOverride = Get-OctoRepoRestoreSourcesOverride -repositoryPath $repositoryPath -laneSettings $laneSettings
        if ($null -ne $restoreSourcesOverride) {
            $environment['RestoreSources'] = $restoreSourcesOverride
        }
    }
    return [PSCustomObject][ordered]@{
        laneRoot    = $laneSettings.laneRoot
        isolated    = $laneSettings.isolated
        reason      = $laneSettings.reason
        environment = $environment
    }
}

# Shared -DryRun output of Invoke-Build / Invoke-Publish.
function Write-OctoLaneDryRun {
    param(
        [string]$command,
        [string]$repositoryPath,
        [string]$configuration,
        $buildEnvironment,
        [switch]$Json
    )

    if ($Json) {
        Write-OctoJson -Command $command -Data ([ordered]@{
            dryRun         = $true
            repositoryPath = [IO.Path]::GetFullPath($repositoryPath)
            configuration  = $configuration
            laneRoot       = $buildEnvironment.laneRoot
            isolated       = $buildEnvironment.isolated
            reason         = $buildEnvironment.reason
            environment    = $buildEnvironment.environment
        })
        return
    }
    Write-Host "Dry run ($command) - dotnet is not started" -ForegroundColor Yellow
    Write-Host "Repository:      $([IO.Path]::GetFullPath($repositoryPath))"
    Write-Host "Configuration:   $configuration"
    Write-Host "Lane root:       $($buildEnvironment.laneRoot)"
    Write-Host "Lane isolated:   $($buildEnvironment.isolated) ($($buildEnvironment.reason))"
    foreach ($name in $buildEnvironment.environment.Keys) {
        Write-Host "  env $name=$($buildEnvironment.environment[$name])"
    }
}

<#
.SYNOPSIS
    Creates <lane>/Octo.User.props with the lane-local package cache, checks an existing one, or (with
    -AddRestorePackagesPath) adds the cache to an existing one.

.DESCRIPTION
    Octo.User.props is a per-checkout, uncommitted file that every OctoMesh repo's Directory.Build.props
    imports (GetPathOfFileAbove). Its RestorePackagesPath=<lane>/.nuget-packages keeps Rider, dotnet and
    MSBuild builds of one lane out of the other lanes' 999.0.0 packages, and it is what makes octo-tools
    treat the lane as isolated (Get-OctoLaneBuildSettings).

    Without -AddRestorePackagesPath the file is written only when it is MISSING; an existing file is only
    checked and a warning is printed when it lacks the line.

    With -AddRestorePackagesPath an existing file that lacks RestorePackagesPath gets a new PropertyGroup
    with the line, inserted before </Project>. Everything else in the file stays byte for byte; the previous
    content is saved next to it as Octo.User.props.bak (Octo.User.props.<timestamp>.bak when a .bak exists).
    Idempotent: a file that already declares RestorePackagesPath is left alone. Supports -WhatIf.

    After the switch the lane restores into <lane>/.nuget-packages; nothing in octo-tools purges
    ~/.nuget/packages for it any more. The first restore after the switch extracts every package once.

.EXAMPLE
    Initialize-OctoLaneUserProps -branch dev

.EXAMPLE
    Initialize-OctoLaneUserProps -branch main -AddRestorePackagesPath -WhatIf
#>
function Initialize-OctoLaneUserProps {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$branch = "",
        [switch]$AddRestorePackagesPath,
        [switch]$Json
    )

    $standardLine = '<RestorePackagesPath>$(MSBuildThisFileDirectory).nuget-packages</RestorePackagesPath>'
    $laneRoot = [IO.Path]::GetFullPath((Join-Path -Path $rootPath -ChildPath $branch))
    if (-not (Test-Path -Path $laneRoot -PathType Container)) {
        Write-Error "Lane root $laneRoot does not exist"
        return
    }
    $propsPath = Join-Path -Path $laneRoot -ChildPath "Octo.User.props"
    $backupPath = $null
    $status = ""
    if (-not (Test-Path -Path $propsPath -PathType Leaf)) {
        $content = @'
<Project>
    <!-- Lane-local NuGet package cache (generated by Initialize-OctoLaneUserProps, octo-tools).
         Every lane builds the same 999.0.0 DebugL packages; a shared ~/.nuget/packages
         lets whichever lane restored last poison the others. RestorePackagesPath is the
         MSBuild equivalent of NUGET_PACKAGES and is honored by dotnet, MSBuild and Rider. -->
    <PropertyGroup>
        <RestorePackagesPath>$(MSBuildThisFileDirectory).nuget-packages</RestorePackagesPath>
    </PropertyGroup>
</Project>
'@
        if ($PSCmdlet.ShouldProcess($propsPath, "Create Octo.User.props with RestorePackagesPath")) {
            Set-Content -Path $propsPath -Value $content -NoNewline:$false
            $status = "created"
        }
        else {
            $status = "would-create"
        }
    }
    elseif (Test-OctoLaneUserPropsRestorePackagesPath -propsPath $propsPath) {
        # Only a real declaration counts (XML, so a commented-out line is no setting). The standard value is ok;
        # another value is isolated per Get-OctoLaneBuildSettings, yet octo-tools purges and sets NUGET_PACKAGES for
        # <lane>/.nuget-packages - never rewrite a value somebody chose.
        $declared = @(([xml](Get-Content -Path $propsPath -Raw)).SelectNodes("//*[local-name()='RestorePackagesPath']") | ForEach-Object { ([string]$_.InnerText).Trim() })
        $status = if ($declared -contains '$(MSBuildThisFileDirectory).nuget-packages') { "ok" } else { "custom-restore-packages-path" }
    }
    elseif (-not $AddRestorePackagesPath) {
        $status = "missing-restore-packages-path"
    }
    else {
        $original = [IO.File]::ReadAllText($propsPath)
        $closing = $original.LastIndexOf('</Project>', [StringComparison]::Ordinal)
        if ($closing -lt 0) {
            Write-Error "$propsPath has no closing </Project> - left unchanged"
            $status = "invalid"
        }
        else {
            $newline = if ($original.Contains("`r`n")) { "`r`n" } else { "`n" }
            $block = "    <!-- Lane-local NuGet package cache (added by Initialize-OctoLaneUserProps -AddRestorePackagesPath, octo-tools). -->$newline" +
                "    <PropertyGroup>$newline        $standardLine$newline    </PropertyGroup>$newline"
            $updated = $original.Substring(0, $closing) + $block + $original.Substring($closing)
            try {
                [xml]$null = $updated
            }
            catch {
                Write-Error "Adding RestorePackagesPath to $propsPath would not yield valid XML - left unchanged: $_"
                $updated = $null
                $status = "invalid"
            }
            if ($null -ne $updated) {
                $backupPath = "$propsPath.bak"
                if (Test-Path -Path $backupPath) {
                    $backupPath = Join-Path -Path $laneRoot -ChildPath ("Octo.User.props.{0}.bak" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
                }
                if ($PSCmdlet.ShouldProcess($propsPath, "Add RestorePackagesPath (backup: $backupPath)")) {
                    Copy-Item -Path $propsPath -Destination $backupPath
                    [IO.File]::WriteAllText($propsPath, $updated, [Text.UTF8Encoding]::new($false))
                    $status = "added"
                }
                else {
                    $status = "would-add"
                    $backupPath = $null
                }
            }
        }
    }

    $success = $status -notin @("missing-restore-packages-path", "invalid")
    if ($Json) {
        Write-OctoJson -Command 'Initialize-OctoLaneUserProps' -Data (New-OctoActionResult -Success $success -ExitCode 0 -Extra @{ path = $propsPath; status = $status; backupPath = $backupPath })
        return
    }
    switch ($status) {
        "created" { Write-Host "Created $propsPath (RestorePackagesPath=<lane>/.nuget-packages)" -ForegroundColor Green }
        "added" { Write-Host "Added RestorePackagesPath=<lane>/.nuget-packages to $propsPath (backup: $backupPath). The lane is isolated from now on; the next restore fills <lane>/.nuget-packages." -ForegroundColor Green }
        "ok" { Write-Host "$propsPath already sets the lane-local package cache - left unchanged" -ForegroundColor Green }
        "custom-restore-packages-path" { Write-Warning "$propsPath sets RestorePackagesPath to another folder than <lane>/.nuget-packages - left unchanged; octo-tools builds use <lane>/.nuget-packages" }
        "would-create" { }
        "would-add" { }
        "invalid" { }
        default { Write-Warning "$propsPath exists but does not set RestorePackagesPath=`$(MSBuildThisFileDirectory).nuget-packages - left unchanged; run Initialize-OctoLaneUserProps -AddRestorePackagesPath to add it" }
    }
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

function Get-OctoGlobalPackagesPath {
    if ($env:NUGET_PACKAGES) { return $env:NUGET_PACKAGES }
    if ($Global:GLOBALNUGETPACKAGESPATH) { return [string]$Global:GLOBALNUGETPACKAGESPATH }
    return Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.nuget/packages'
}

function Get-OctoRangePackageCaches {
    # The package cache(s) the restores of a lane extract 999.0.0 packages into - the folders the
    # per-package purge and the stale-cache check must look at. Follows the lane isolation of
    # Get-OctoLaneBuildSettings (AB#4924) instead of assuming ~/.nuget/packages:
    #   - isolated lane (Octo.User.props declares RestorePackagesPath, every environment):
    #     NUGET_PACKAGES=<lane>/.nuget-packages for every repo -> only that one;
    #   - legacy lane (no RestorePackagesPath, or -laneIsolation Off): repos importing an Octo.User.props that
    #     sets RestorePackagesPath use <lane>/.nuget-packages, all others the session/global cache
    #     (NUGET_PACKAGES or ~/.nuget/packages).
    param([Parameter(Mandatory = $true)] $laneSettings)

    if ($laneSettings.isolated) {
        return @($laneSettings.laneCache)
    }
    $caches = @()
    $userProps = Join-Path -Path $laneSettings.laneRoot -ChildPath 'Octo.User.props'
    if (Test-OctoLaneUserPropsRestorePackagesPath -propsPath $userProps) {
        $caches += $laneSettings.laneCache
    }
    $caches += Get-OctoGlobalPackagesPath
    return @($caches | ForEach-Object { [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath([string]$_)) } | Select-Object -Unique)
}

Export-ModuleMember -Function @(
    'Get-OctoLaneBuildSettings',
    'Test-OctoLaneUserPropsRestorePackagesPath',
    'Find-OctoLaneRoot',
    'Get-OctoRepositoryBuildEnvironment',
    'Initialize-OctoLaneUserProps',
    'Write-OctoLaneDryRun',
    'Get-OctoRepoRestoreSourcesOverride',
    'Set-OctoBuildEnvironment',
    'Restore-OctoBuildEnvironment',
    'Get-OctoGlobalPackagesPath',
    'Get-OctoRangePackageCaches'
)
