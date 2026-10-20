# OctoComposeInfra - deprecation notice and CrateDB image guard of the docker-compose infrastructure
# (Install-/Start-/Stop-/Uninstall-OctoInfrastructure, Backup-/Restore-OctoInfrastructure, AB#7141).
#
# kind (Install-OctoKubernetes) is the only supported local infrastructure. The compose setup stays
# until the removal date and must not be able to damage data meanwhile: CrateDB cannot be downgraded
# and compose recreates all three nodes at once. So the deprecated path NEVER changes the CrateDB image
# of existing volumes.

$script:OctoComposeRemovalDate = '2026-12-31'
$script:OctoComposeMigrationDoc = 'kubernetes/README.md, section "Migrating from docker-compose"'

function Get-OctoComposeCrateMarkerPath {
    # One record per user, not per checkout: the compose volumes (project "infrastructure") are shared by all checkouts.
    return Join-Path $HOME '.config/octo-tools/compose-crate-version.txt'
}

function Write-OctoComposeDeprecation {
    param([Parameter(Mandatory)] [string]$Command)
    Write-Warning ("DEPRECATED: $Command belongs to the docker-compose infrastructure, which is deprecated and will be removed on " +
        "$script:OctoComposeRemovalDate. kind is the only supported local infrastructure: use Install-OctoKubernetes. " +
        "How to move your data (or throw it away): $script:OctoComposeMigrationDoc.")
}

function Get-OctoComposeCrateVersion {
    # The CrateDB version the compose file pins (the highest, should the nodes differ).
    param([Parameter(Mandatory)] [string]$ComposeFile)
    if (-not (Test-Path $ComposeFile)) { throw "Compose file not found: $ComposeFile" }
    $versions = @([regex]::Matches((Get-Content $ComposeFile -Raw), '(?m)^\s*image:\s*crate:(\d+\.\d+\.\d+)\s*$') |
            ForEach-Object { [version]$_.Groups[1].Value })
    if ($versions.Count -eq 0) { throw "No 'image: crate:<x.y.z>' line found in $ComposeFile." }
    return ($versions | Sort-Object -Descending | Select-Object -First 1)
}

function Get-OctoComposeCrateDecision {
    # Pure decision. $StoredVersions: what is known to have written the data (images of existing cratedb
    # containers, the recorded version). $VolumesExist: crate data volumes are present.
    param(
        [Parameter(Mandatory)] [version]$ComposeVersion,
        [version[]]$StoredVersions = @(),
        [bool]$VolumesExist = $false,
        [switch]$AcceptUnknownCrateVolumes
    )
    $migrate = "Use Install-OctoKubernetes (kind) instead; $script:OctoComposeMigrationDoc. To discard the compose data, run Uninstall-OctoInfrastructure."
    $stored = $null
    if (@($StoredVersions).Count -gt 0) { $stored = @($StoredVersions) | Sort-Object -Descending | Select-Object -First 1 }

    if ($null -ne $stored) {
        if ($stored -eq $ComposeVersion) { return [pscustomobject]@{ Allowed = $true; Reason = 'same version' } }
        if ($stored -gt $ComposeVersion) {
            return [pscustomobject]@{ Allowed = $false; Reason = "The CrateDB data was written by $stored, the compose file pins the older $ComposeVersion. CrateDB cannot be downgraded. $migrate" }
        }
        return [pscustomobject]@{ Allowed = $false; Reason = "The CrateDB data was written by $stored, the compose file pins $ComposeVersion. The deprecated compose setup never changes the CrateDB image of existing volumes. $migrate" }
    }
    if (-not $VolumesExist) { return [pscustomobject]@{ Allowed = $true; Reason = 'no CrateDB data yet' } }
    if ($AcceptUnknownCrateVolumes) { return [pscustomobject]@{ Allowed = $true; Reason = 'unknown version accepted' } }
    return [pscustomobject]@{ Allowed = $false; Reason = ("CrateDB volumes exist, but nothing records which version wrote them (no container, no record). Starting $ComposeVersion over newer data would break them. " +
            "If you are sure the volumes were written by $ComposeVersion, pass -AcceptUnknownCrateVolumes once; the version is recorded then. $migrate") }
}

function Get-OctoComposeCrateImageVersions {
    # Versions of the images of all existing cratedb containers (running or stopped).
    $images = @(docker ps -a --filter 'name=cratedb' --format '{{.Image}}' 2>$null)
    return @($images | ForEach-Object { if ($_ -match 'crate:(\d+\.\d+\.\d+)') { [version]$Matches[1] } })
}

function Save-OctoComposeCrateVersion {
    param([Parameter(Mandatory)] [version]$Version)
    $marker = Get-OctoComposeCrateMarkerPath
    New-Item -ItemType Directory -Path (Split-Path $marker) -Force | Out-Null
    $current = if (Test-Path $marker) { try { [version](Get-Content $marker -Raw).Trim() } catch { $null } } else { $null }
    if ($null -eq $current -or $Version -gt $current) { Set-Content -Path $marker -Value "$Version" -NoNewline }
}

function Clear-OctoComposeCrateVersion {
    Remove-Item (Get-OctoComposeCrateMarkerPath) -Force -ErrorAction SilentlyContinue
}

function Save-OctoComposeCrateVersionFromContainers {
    # Called before the containers are removed ('compose down'), so that the version outlives them.
    $v = @(Get-OctoComposeCrateImageVersions)
    if ($v.Count -gt 0) { Save-OctoComposeCrateVersion -Version ($v | Sort-Object -Descending | Select-Object -First 1) }
}

function Assert-OctoComposeCrateImage {
    # $true when 'docker compose up' may run: it would not change the CrateDB image of existing data.
    # Writes an error and returns $false otherwise.
    param(
        [Parameter(Mandatory)] [string]$ComposeFile,
        [switch]$AcceptUnknownCrateVolumes
    )
    $compose = Get-OctoComposeCrateVersion -ComposeFile $ComposeFile
    $stored = @(Get-OctoComposeCrateImageVersions)
    $marker = Get-OctoComposeCrateMarkerPath
    if (Test-Path $marker) { try { $stored += [version](Get-Content $marker -Raw).Trim() } catch { } }
    $volumes = @(docker volume ls -q 2>$null | Where-Object { $_ -match '(^|_)crate-data\d+$' })
    $d = Get-OctoComposeCrateDecision -ComposeVersion $compose -StoredVersions $stored -VolumesExist ($volumes.Count -gt 0) -AcceptUnknownCrateVolumes:$AcceptUnknownCrateVolumes
    if (-not $d.Allowed) { Write-Error $d.Reason; return $false }
    return $true
}

Export-ModuleMember -Function @('Write-OctoComposeDeprecation', 'Assert-OctoComposeCrateImage', 'Get-OctoComposeCrateDecision',
    'Get-OctoComposeCrateVersion', 'Save-OctoComposeCrateVersion', 'Save-OctoComposeCrateVersionFromContainers', 'Clear-OctoComposeCrateVersion')
