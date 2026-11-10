<#
.SYNOPSIS
    Single source of truth for the OctoMesh repository build order, plus shared build helpers.

.DESCRIPTION
    Invoke-BuildAll (full chain) and Invoke-BuildRange (partial chain) build the repositories of a
    lane checkout in the same dependency order:

        1. every mm-* repository                         (phase 'common'; no internal ordering)
        2. Get-OctoPinnedBuildOrder, in that order       (phase 'ordered'; NuGet producers that
                                                          downstream repositories restore from ../nuget)
        3. Get-OctoAdditionalOrderedBuildOrder           (phase 'additional-ordered'; additional repos
                                                          that other additional repos consume)
        4. every remaining octo-* repository             (phase 'additional'; directory enumeration order,
                                                          i.e. alphabetical)

    Phases 3 and 4 are dropped with -excludeAdditional. Changing the order here changes it for both
    cmdlets. Keep the comments on each entry up to date - they explain why the slot exists.
#>

# Repositories built in this fixed order right after the mm-* libraries, because the alphabetical
# fallback would build them after their consumers.
$script:OctoPinnedBuildOrder = @(
    'octo-distributedEventHub'
    'octo-construction-kit-engine'
    'octo-sdk'
    'octo-construction-kit-engine-mongodb'
    'octo-common-services'
    # Phase 3: octo-communication-sdk holds the adapter/pipeline framework (formerly
    # Sdk.Common/Adapters + EtlDataPipeline + Services in octo-sdk). Depends on
    # octo-sdk so builds AFTER it; needs to build BEFORE octo-mesh-adapter and the
    # other adapter consumer repos so they can restore the new packages.
    'octo-communication-sdk'
    'octo-mesh-adapter'
    'octo-bot-services'
    # octo-communication-controller-services produces Meshmakers.Octo.ConstructionKit.Models.System.Communication,
    # consumed by octo-ai-services and octo-plug-zenon. Without this explicit slot it falls into the alphabetical
    # fallback and runs after octo-ai-services (a < c), breaking the AI services restore.
    'octo-communication-controller-services'
)

# Additional repositories that other additional repositories consume. They are built first in the
# additional phase (so they still honour -excludeAdditional), before the alphabetical rest.
$script:OctoAdditionalOrderedBuildOrder = @(
    # octo-plug-dilos publishes Meshmakers.Octo.Communication.Dilos(.Nodes), consumed by
    # octo-adapter-weclapp (a < p). Built against octo-communication-sdk, which is in the core order.
    'octo-plug-dilos'
)

function Get-OctoPinnedBuildOrder {
    <#
    .SYNOPSIS
        Returns the names of the pinned (phase 'ordered') octo-* repositories in build order.
    #>
    return $script:OctoPinnedBuildOrder
}

function Get-OctoAdditionalOrderedBuildOrder {
    <#
    .SYNOPSIS
        Returns the names of the additional repositories built first in the additional phase.
    #>
    return $script:OctoAdditionalOrderedBuildOrder
}

function Resolve-OctoBranchRootPath {
    <#
    .SYNOPSIS
        Resolves the checkout directory for -branch the same way Invoke-BuildAll does.
    .DESCRIPTION
        `$rootPath` (set by profile.ps1) already points at the branch checkout itself
        (`.../meshmakers/<branch>/`). A -branch value that equals the leaf segment of `$rootPath`
        is therefore normalised to "" so `-branch main` from inside the `main` checkout works.
        Returns an object with the normalised Branch and the BranchRootPath.
    #>
    param(
        [string]$branch = "",
        [string]$root = $rootPath
    )

    if ($branch -ne "") {
        $rootLeaf = Split-Path -Leaf ([IO.Path]::GetFullPath([string]$root).TrimEnd('/', '\'))
        if ($rootLeaf -ieq $branch) {
            $branch = ""
        }
    }

    [pscustomobject]@{
        Branch         = $branch
        BranchRootPath = (Join-Path -Path $root -ChildPath $branch)
    }
}

function Get-OctoBuildOrder {
    <#
    .SYNOPSIS
        Returns the repositories of a lane checkout in OctoMesh build order.

    .DESCRIPTION
        Enumerates the mm-* and octo-* directories below -branchRootPath and returns them in the
        order Invoke-BuildAll builds them. Each entry is a PSCustomObject with:
          Name      - directory name (e.g. octo-construction-kit-engine)
          Path      - full path
          Group     - phase: 'common' | 'ordered' | 'additional-ordered' | 'additional'
          Directory - the DirectoryInfo

    .PARAMETER branchRootPath
        The lane checkout that contains the repositories (e.g. .../meshmakers/main or .../dev).

    .PARAMETER excludeFrontend
        Drop octo-frontend-* repositories from the additional phases (same as Invoke-BuildAll).

    .PARAMETER excludeAdditional
        Drop both additional phases (same as Invoke-BuildAll).

    .PARAMETER additionalRepos
        Repositories that are not folders of the lane, keyed by repository name (mm-* / octo-*) with the folder
        they live in, e.g. an in-place worktree of a feature environment. They are ordered like a lane folder of
        that name; a lane folder of the same name wins.

    .EXAMPLE
        Get-OctoBuildOrder -branchRootPath (Join-Path $rootPath dev) | Format-Table Name, Group
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$branchRootPath,
        [Boolean]$excludeFrontend = $false,
        [Boolean]$excludeAdditional = $false,
        [hashtable]$additionalRepos = @{}
    )

    # octo-tools and octo-devstack are developer tools, not OctoMesh repositories: they sit next to octo-tools,
    # and when that folder is used as a lane (Invoke-BuildAll without -branch) they must not be built.
    # Candidates as { Name; Info }: Name is the repository name, Info the folder (for -additionalRepos the folder
    # name may differ from the repository name, e.g. wt-<lane>-octo-sdk).
    $octoDirectories = @(Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*" | Where-Object { $_.Name -notin @('octo-tools', 'octo-devstack') } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Info = $_ } })
    $mmDirectories = @(Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*" | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Info = $_ } })
    foreach ($name in @($additionalRepos.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
        if ($name -in @('octo-tools', 'octo-devstack')) { continue }
        if (@($octoDirectories + $mmDirectories | Where-Object { $_.Name -ieq $name }).Count -gt 0) { continue }
        $folder = [string]$additionalRepos[$name]
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "Get-OctoBuildOrder: folder $folder of $name does not exist." }
        $candidate = [pscustomobject]@{ Name = $name; Info = (Get-Item -LiteralPath $folder) }
        if ($name -like 'mm-*') { $mmDirectories += $candidate }
        elseif ($name -like 'octo-*') { $octoDirectories += $candidate }
        else { throw "Get-OctoBuildOrder: -additionalRepos key '$name' is not an mm-* or octo-* repository name." }
    }
    $octoDirectories = @($octoDirectories | Sort-Object Name)
    $mmDirectories = @($mmDirectories | Sort-Object Name)

    if ($excludeFrontend -eq $true) {
        $octoDirectories = @($octoDirectories | Where-Object { $_.Name -notlike "octo-frontend-*" })
    }

    $result = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $add = {
        param($candidate, [string]$group)
        if ($candidate -and $seen.Add($candidate.Name)) {
            $result.Add([pscustomobject]@{ Name = $candidate.Name; Path = $candidate.Info.FullName; Group = $group; Directory = $candidate.Info })
        }
    }

    foreach ($directory in $mmDirectories) { & $add $directory 'common' }

    foreach ($name in $script:OctoPinnedBuildOrder) {
        # Looked up independently of -excludeFrontend (none of them is a frontend).
        $pinned = Get-ChildItem -Directory -Path $branchRootPath -Filter $name | Select-Object -First 1
        $candidate = if ($pinned) { [pscustomobject]@{ Name = $pinned.Name; Info = $pinned } } else { @($octoDirectories | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1 }
        & $add $candidate 'ordered'
    }

    if ($excludeAdditional -eq $false) {
        foreach ($name in $script:OctoAdditionalOrderedBuildOrder) {
            & $add ($octoDirectories | Where-Object { $_.Name -eq $name } | Select-Object -First 1) 'additional-ordered'
        }
        foreach ($directory in $octoDirectories) { & $add $directory 'additional' }
    }

    return $result.ToArray()
}

function Hide-OctoUrlCredentials {
    <#
    .SYNOPSIS
        Masks credentials in URLs (scheme://user:password@host -> scheme://***@host) before a value is printed, logged
        or written to JSON, e.g. a private NuGet feed in RestoreSources. The value passed to dotnet stays unmasked.
    #>
    param([AllowNull()] [AllowEmptyString()] [string]$text)
    if ([string]::IsNullOrEmpty($text)) { return $text }
    return [regex]::Replace($text, '(?<=://)[^/@\s;"]+@', '***@')
}

function ConvertTo-OctoMsBuildPropertyArgs {
    <#
    .SYNOPSIS
        Converts a hashtable of MSBuild properties into `-p:Name=Value` arguments for dotnet.
    .DESCRIPTION
        Shared by Invoke-Build, Invoke-BuildAll and Invoke-BuildRange (-msbuildProperties).
        Global properties passed with -p override properties set inside project files, e.g.
        @{ OctoPublishCkModel = 'false' } keeps a CK model project that sets
        OctoPublishCkModel=true from publishing into the shared local catalog.
        `;` and `,` in values are escaped (%3B / %2C) because MSBuild treats them as separators.
        Keys are emitted sorted so the command line is deterministic.
    .EXAMPLE
        ConvertTo-OctoMsBuildPropertyArgs @{ OctoPublishCkModel = 'false' }   # -> -p:OctoPublishCkModel=false
    #>
    param(
        [hashtable]$properties = @{}
    )
    if ($null -eq $properties -or $properties.Count -eq 0) { return @() }
    $arguments = @()
    foreach ($key in ($properties.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_.-]*$') {
            throw "Invalid MSBuild property name '$key'."
        }
        $value = [string]$properties[$key]
        if ($properties[$key] -is [bool]) { $value = $value.ToLowerInvariant() }
        $value = $value.Replace('%', '%25').Replace(';', '%3B').Replace(',', '%2C')
        $arguments += "-p:$key=$value"
    }
    return $arguments
}

function Merge-OctoRepoMsBuildProperties {
    <#
    .SYNOPSIS
        Effective MSBuild properties for one repository: -msbuildProperties (all repositories),
        overridden by the repository's entry in -msbuildPropertiesPerRepo (key = repository name,
        compared case-insensitively).
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$repoName,
        [hashtable]$msbuildProperties = @{},
        [hashtable]$msbuildPropertiesPerRepo = @{}
    )
    $merged = @{}
    if ($msbuildProperties) { foreach ($key in $msbuildProperties.Keys) { $merged[[string]$key] = $msbuildProperties[$key] } }
    if ($msbuildPropertiesPerRepo) {
        foreach ($repoKey in $msbuildPropertiesPerRepo.Keys) {
            if ([string]$repoKey -ieq $repoName) {
                $repoProperties = $msbuildPropertiesPerRepo[$repoKey]
                foreach ($key in $repoProperties.Keys) { $merged[[string]$key] = $repoProperties[$key] }
            }
        }
    }
    return $merged
}

function Test-OctoCkPublishDisabled {
    <#
    .SYNOPSIS
        True when the properties set OctoPublishCkModel=false (CK model publishing into the local catalog off).
    #>
    param([hashtable]$properties = @{})
    if (-not $properties) { return $false }
    foreach ($key in $properties.Keys) {
        if ([string]$key -ieq 'OctoPublishCkModel' -and ([string]$properties[$key]) -ieq 'false') { return $true }
    }
    return $false
}

function Assert-OctoMsBuildPropertiesPerRepo {
    <#
    .SYNOPSIS
        Validates -msbuildPropertiesPerRepo: every key must be a repository of the build order and
        every value a hashtable of valid MSBuild properties. Throws otherwise.
    #>
    param(
        [hashtable]$msbuildPropertiesPerRepo = @{},
        [string[]]$knownRepos = @()
    )
    if (-not $msbuildPropertiesPerRepo) { return }
    foreach ($repoKey in $msbuildPropertiesPerRepo.Keys) {
        if (-not ($knownRepos | Where-Object { $_ -ieq [string]$repoKey })) {
            throw "-msbuildPropertiesPerRepo: '$repoKey' is not a repository of the build order."
        }
        $value = $msbuildPropertiesPerRepo[$repoKey]
        if ($value -isnot [hashtable]) {
            throw "-msbuildPropertiesPerRepo: the value for '$repoKey' must be a hashtable, e.g. @{ OctoPublishCkModel = 'false' }."
        }
        [void](ConvertTo-OctoMsBuildPropertyArgs -properties $value)
    }
}

function Get-OctoCkPublishDisabledWarning {
    <#
    .SYNOPSIS
        Returns a warning text when OctoPublishCkModel=false applies to more than one repository.
    .DESCRIPTION
        With CK publishing off, a rebuilt model never reaches the shared local catalog, so CK
        compiles in downstream repositories resolve stale model versions (or fail). Disabling it
        is only meant for the one repository whose model must not be published.
    #>
    param([string[]]$repoNames = @())
    if ($repoNames.Count -le 1) { return $null }
    return "OctoPublishCkModel=false applies to $($repoNames.Count) repositories ($($repoNames -join ', ')). Their CK models are not published into the local catalog, so downstream CK compiles see stale models. Prefer -msbuildPropertiesPerRepo @{ '<repo>' = @{ OctoPublishCkModel = 'false' } } for the one repository that must not publish."
}

Export-ModuleMember -Function @('Hide-OctoUrlCredentials', 'Get-OctoBuildOrder', 'Get-OctoPinnedBuildOrder', 'Get-OctoAdditionalOrderedBuildOrder', 'Resolve-OctoBranchRootPath', 'ConvertTo-OctoMsBuildPropertyArgs',
    'Merge-OctoRepoMsBuildProperties', 'Test-OctoCkPublishDisabled', 'Assert-OctoMsBuildPropertiesPerRepo', 'Get-OctoCkPublishDisabledWarning')
