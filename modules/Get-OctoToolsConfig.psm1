$script:CachedConfig = $null
$script:CachedConfigPath = $null

function Get-OctoToolsConfigPath {
    <#
    .SYNOPSIS
        Returns the absolute path to the user's octo-tools config file.

    .DESCRIPTION
        The config file holds environment-specific values that don't belong in the
        public octo-tools repo: the list of OctoMesh installations, the addresses of
        Rancher / Vault / Semaphore / the dev registry, etc.

        Resolution order:
          1. $env:OCTO_TOOLS_CONFIG (explicit override, useful for CI / tests)
          2. ~/.config/octo-tools/installations.json (POSIX convention, used on every OS)

        The file does not exist by default. Copy `installations.example.json` from the
        repo root, place it at the resolved path, and edit it for your environment.
    #>
    [CmdletBinding()]
    param()

    if ($env:OCTO_TOOLS_CONFIG) {
        return $env:OCTO_TOOLS_CONFIG
    }

    $userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    return Join-Path $userProfile '.config/octo-tools/installations.json'
}

function Get-OctoToolsConfig {
    <#
    .SYNOPSIS
        Loads and caches the user's octo-tools config.

    .DESCRIPTION
        Reads installations.json (see Get-OctoToolsConfigPath for resolution) and
        returns the parsed object. The result is cached for the current PowerShell
        session — pass `-Force` to re-read after editing the file.

        Throws a clear error with the expected path and a pointer to the example
        config if the file is missing.

    .PARAMETER Force
        Re-read the file even if a cached copy is in memory.

    .EXAMPLE
        $cfg = Get-OctoToolsConfig
        $cfg.installations | Where-Object name -eq 'local'
    #>
    [CmdletBinding()]
    param(
        [switch]$Force
    )

    $configPath = Get-OctoToolsConfigPath

    if (-not $Force -and $script:CachedConfig -and $script:CachedConfigPath -eq $configPath) {
        return $script:CachedConfig
    }

    if (-not (Test-Path $configPath)) {
        throw @"
octo-tools config not found at:
  $configPath

Copy installations.example.json (in the octo-tools repo root) to that path and
adapt the values to your environment. See docs/installations-config.md for the
schema reference.

You can override the location with the OCTO_TOOLS_CONFIG environment variable.
"@
    }

    try {
        $raw = Get-Content -Path $configPath -Raw -ErrorAction Stop
        $config = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to parse octo-tools config '$configPath': $($_.Exception.Message)"
    }

    $script:CachedConfig = $config
    $script:CachedConfigPath = $configPath
    return $config
}

function Get-OctoInstallation {
    <#
    .SYNOPSIS
        Returns the configured installation block for the given name.

    .PARAMETER Name
        The installation name as it appears in the `installations[].name` field
        (e.g. 'local', 'staging-1', 'prod-1').

    .EXAMPLE
        $inst = Get-OctoInstallation -Name 'local'
        $inst.services.identity
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $config = Get-OctoToolsConfig
    $installation = $config.installations | Where-Object { $_.name -eq $Name } | Select-Object -First 1

    if (-not $installation) {
        $known = ($config.installations | ForEach-Object { $_.name }) -join ', '
        throw "Installation '$Name' is not defined in your octo-tools config. Known installations: $known"
    }

    return $installation
}

Export-ModuleMember -Function @('Get-OctoToolsConfigPath', 'Get-OctoToolsConfig', 'Get-OctoInstallation')
