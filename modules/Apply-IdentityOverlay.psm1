if (Get-Module -ListAvailable -Name 'powershell-yaml') {
    Import-Module powershell-yaml -ErrorAction SilentlyContinue
}

function Apply-IdentityOverlay {
    <#
.SYNOPSIS
Fans octo-cli ApplyClientOverlay across the blueprint-managed clients listed in an overlay file.

.DESCRIPTION
Reads an overlay YAML file (default: octo-tools/overlays/identity-local-dev.yaml relative to
the script's repo root) and invokes `octo-cli -c ApplyClientOverlay -id <client> -n <overlayName>
-r ... -plr ... -co ...` for each client entry. Each invocation hits the AB#4209 Step 4 PR 1
endpoint POST {tenantId}/v1/clients/{id}/overlayUris, which appends new URIs with
Source = "overlay:<OverlayName>" and dedupes by URI string (any source).

The endpoint and the cmdlet are both idempotent: re-running on the same DB is a no-op (no DB
write, no cache invalidation, server returns 200 with Added=0/SkippedDuplicate=N counts). The
cmdlet exits non-zero only when an individual client invocation fails — one failed client does
not abort the batch. Per-client log lines show Added/SkippedDuplicate counts so the operator
can spot the actual deltas.

The octo-cli ambient context (active context's TenantId + IdentityServiceUrl + auth tokens)
is used. Switch contexts beforehand with `Register-OctoCliContext -Installation local` (or equivalent) to target
a different tenant.

.PARAMETER OverlayFile
Path to the overlay YAML file. Defaults to
'octo-tools/overlays/identity-local-dev.yaml' relative to `$Global:ROOTPATH` (set by
profile.ps1). Pass an absolute path or a different overlay file when applying a non-default
overlay (e.g. 'overlays/gerald-laptop.yaml').

.PARAMETER OverlayName
Overrides the `overlayName` field declared inside the file. Useful for one-off overlays
applied from the local-dev file under a different marker. Defaults to the file's value.

.PARAMETER DryRun
Parses + validates the overlay file and prints the octo-cli invocations that would run,
without calling out. Useful when iterating on the overlay file shape.

.PARAMETER OctoCli
Path / name of the octo-cli executable. Default: 'octo-cli' (resolved from PATH).

.EXAMPLE
Apply-IdentityOverlay

Applies the default local-dev overlay to the active context's tenant.

.EXAMPLE
Apply-IdentityOverlay -DryRun

Shows what would be invoked without calling octo-cli. Sanity check after editing the overlay
file.

.EXAMPLE
Apply-IdentityOverlay -OverlayFile ~/dev/gerald-laptop.yaml -OverlayName gerald-laptop

Applies a personal overlay from outside the repo, marked under its own overlay name so the
DumpTenant --clean filter strips them without touching the shared local-dev entries.
#>
    [CmdletBinding()]
    param(
        [string]$OverlayFile,
        [string]$OverlayName,
        [switch]$DryRun,
        [string]$OctoCli = 'octo-cli',
        [switch]$Json
    )

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Error "PowerShell 7+ required. Current version: $($PSVersionTable.PSVersion)"
        return
    }

    $yamlModule = Get-Module -ListAvailable -Name 'powershell-yaml' | Select-Object -First 1
    if (-not $yamlModule) {
        Write-Error "powershell-yaml module not found. Install with: Install-Module -Name powershell-yaml -Scope CurrentUser"
        return
    }

    if (-not $OverlayFile) {
        if (-not $Global:ROOTPATH) {
            Write-Error "OverlayFile not specified and `$Global:ROOTPATH is not set (run from a profile.ps1-loaded shell or pass -OverlayFile explicitly)."
            return
        }
        $OverlayFile = Join-Path $Global:ROOTPATH 'octo-tools/overlays/identity-local-dev.yaml'
    }

    if (-not (Test-Path $OverlayFile)) {
        Write-Error "Overlay file not found: $OverlayFile"
        return
    }

    if (-not $DryRun) {
        $octoCliCmd = Get-Command $OctoCli -ErrorAction SilentlyContinue
        if (-not $octoCliCmd) {
            Write-Error "octo-cli executable '$OctoCli' not found in PATH. Pass -DryRun to validate the overlay file without calling out."
            return
        }
    }

    if (-not $Json) {
        Write-Host "Reading overlay file: $OverlayFile" -ForegroundColor Cyan
    }
    try {
        $overlayContent = Get-Content $OverlayFile -Raw
        $overlay = ConvertFrom-Yaml -Yaml $overlayContent
    }
    catch {
        Write-Error "Failed to parse overlay file: $_"
        return
    }

    if (-not $OverlayName) {
        $OverlayName = $overlay.overlayName
    }
    if (-not $OverlayName) {
        Write-Error "overlayName missing from file and -OverlayName not supplied."
        return
    }
    if ($OverlayName -notmatch '^[A-Za-z0-9._-]+$') {
        Write-Error "OverlayName '$OverlayName' contains characters outside [A-Za-z0-9._-]. Identity server rejects with 400."
        return
    }

    $clients = $overlay.clients
    if (-not $clients -or $clients.Count -eq 0) {
        Write-Error "Overlay file declares no clients."
        return
    }

    if (-not $Json) {
        Write-Host "Overlay name : $OverlayName" -ForegroundColor Cyan
        Write-Host "Clients      : $($clients.Count)" -ForegroundColor Cyan
        if ($DryRun) {
            Write-Host "Mode         : DRY RUN (no octo-cli invocations)" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    $clientResults = [System.Collections.Generic.List[object]]::new()
    $failures = 0
    foreach ($client in $clients) {
        $clientId = $client.clientId
        if (-not $clientId) {
            Write-Warning "Skipping client entry without clientId."
            $failures++
            if ($Json) {
                $clientResults.Add([ordered]@{ client = $null; status = 'skipped-no-clientId' }) | Out-Null
            }
            continue
        }

        $redirectUris = if ($client.redirectUris) { $client.redirectUris -join ',' } else { '' }
        $postLogoutRedirectUris = if ($client.postLogoutRedirectUris) { $client.postLogoutRedirectUris -join ',' } else { '' }
        $allowedCorsOrigins = if ($client.allowedCorsOrigins) { $client.allowedCorsOrigins -join ',' } else { '' }

        if (-not $redirectUris -and -not $postLogoutRedirectUris -and -not $allowedCorsOrigins) {
            Write-Warning "[$clientId] no URIs declared — skipping (server would reject with 400)."
            if ($Json) {
                $clientResults.Add([ordered]@{ client = $clientId; status = 'skipped-no-uris' }) | Out-Null
            }
            continue
        }

        $argList = @('-c', 'ApplyClientOverlay', '-id', $clientId, '-n', $OverlayName)
        if ($redirectUris) { $argList += @('-r', $redirectUris) }
        if ($postLogoutRedirectUris) { $argList += @('-plr', $postLogoutRedirectUris) }
        if ($allowedCorsOrigins) { $argList += @('-co', $allowedCorsOrigins) }

        if ($DryRun) {
            if ($Json) {
                $clientResults.Add([ordered]@{ client = $clientId; status = "planned: $OctoCli $($argList -join ' ')" }) | Out-Null
            }
            else {
                Write-Host "[$clientId] $OctoCli $($argList -join ' ')" -ForegroundColor DarkGray
            }
            continue
        }

        if (-not $Json) {
            Write-Host "[$clientId] applying overlay..." -ForegroundColor Cyan
        }
        & $OctoCli @argList
        $clientExit = $LASTEXITCODE
        if ($clientExit -ne 0) {
            if (-not $Json) {
                Write-Warning "[$clientId] octo-cli exited $clientExit — continuing with remaining clients."
            }
            $failures++
        }
        if ($Json) {
            $clientResults.Add([ordered]@{ client = $clientId; status = (($clientExit -eq 0) ? 'applied' : "failed (exit $clientExit)") }) | Out-Null
        }
    }

    if ($Json) {
        $data = [ordered]@{
            overlayFile = $OverlayFile
            dryRun      = [bool]$DryRun
            clients     = @($clientResults)
            summary     = [ordered]@{
                total  = $clients.Count
                failed = $failures
            }
        }
        if ($failures -gt 0) {
            $global:LASTEXITCODE = 1
        }
        Write-OctoJson -Command 'Apply-IdentityOverlay' -Data $data
        return
    }

    Write-Host ""
    if ($failures -gt 0) {
        Write-Warning "$failures client(s) failed. Re-run after fixing the issue — overlay apply is idempotent."
        $global:LASTEXITCODE = 1
    }
    else {
        Write-Host "Apply-IdentityOverlay complete." -ForegroundColor Green
    }
}

Export-ModuleMember -Function @('Apply-IdentityOverlay')
