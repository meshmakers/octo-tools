<#
.SYNOPSIS
    Child process of a parallel Invoke-BuildRange run (AB#8814): builds ONE repository and writes the result file.

.DESCRIPTION
    Started by Start-OctoRepoBuildJob (Invoke-BuildRange.psm1) as `pwsh -NoProfile -NonInteractive -File <this>
    -RequestFile <json>`. The request names the repository (the plan entry), the configuration, the MSBuild
    properties and the environment of this one build. The environment is set HERE, in the child's own process -
    NUGET_PACKAGES, MSBUILDDISABLENODEREUSE, UseSharedCompilation and the per-repository RestoreSources never
    touch the parent or another repository's build. The work itself is Invoke-OctoBuildRangeRepoStep.
    Exit code 0 = the step ran (the result file says whether the build succeeded), 1 = it could not run.
#>
param(
    [Parameter(Mandatory = $true)] [string]$RequestFile
)
$ErrorActionPreference = 'Stop'
try {
    $modules = Split-Path -Parent $PSScriptRoot
    foreach ($name in @('OctoJsonOutput', 'Get-OctoLaneBuildSettings', 'OctoBuildOrder', 'OctoBuildStamp', 'Invoke-BuildRange')) {
        Import-Module (Join-Path $modules "$name.psm1") -Force
    }
    Invoke-OctoBuildRangeRepoStep -requestFile $RequestFile
    exit 0
}
catch {
    [Console]::Error.WriteLine("Invoke-BuildRangeRepoWorker: $($_.Exception.Message)`n$($_.ScriptStackTrace)")
    exit 1
}
