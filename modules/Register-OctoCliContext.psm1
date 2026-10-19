function Register-OctoCliContext {
    <#
    .SYNOPSIS
        Registers an octo-cli context for one of the OctoMesh installations defined
        in your octo-tools config.

    .DESCRIPTION
        Unified login for every OctoMesh installation listed under `installations[]`
        in `~/.config/octo-tools/installations.json` (replaced the former
        per-environment Invoke-OctoCliLogin{Local,Staging,Production,Test2} helpers).

        Looks the installation up by name, builds the service URIs from the
        configured `services.*` templates (replacing the `{0}` placeholder with
        `-$UriSuffix` if supplied), calls `octo-cli -c AddContext`, and optionally
        switches to the new context and triggers an interactive login.

        See `installations.example.json` in the repo root for the schema and
        `docs/installations-config.md` for the full reference.

    .PARAMETER Installation
        Name of an installation defined in your config (typical values:
        `local`, your test cluster, your staging or prod clusters).

    .PARAMETER TenantId
        Tenant id to bind the context to (required). Accepts a list: one context per tenant is
        registered in one call (`-TenantId a,b,c`, AB#6840), named `<installation>[_<suffix>]_<tenant>`.
        With more than one tenant the active context is never switched (like -NoSwitch); a login is
        still started per tenant unless -NoLogin is set. Pair with Invoke-OctoTenantSweep.

    .PARAMETER UriSuffix
        Optional URI suffix used for sub-environments (e.g. 'pr123' becomes the
        substitution for `{0}` in the configured service URL templates, so a
        template like `https://assets{0}.test.example.com/` resolves to
        `https://assets-pr123.test.example.com/`).
        Also appended to the context name to keep contexts distinct.

    .PARAMETER IncludeReporting
        If set, also registers the reporting service URI (-rsu).

    .PARAMETER IncludeAi
        If set, also registers the AI service URI (-aisu).

    .PARAMETER NoSwitch
        If set, skips 'UseContext' so the active context stays unchanged.

    .PARAMETER NoLogin
        If set, skips the interactive 'Login -i' step (useful for CI / client-credentials flow).

    .EXAMPLE
        Register-OctoCliContext -Installation local -TenantId meshtest

    .EXAMPLE
        Register-OctoCliContext -Installation example-test -TenantId tenant-a,tenant-b,tenant-c -NoSwitch -NoLogin

    .EXAMPLE
        Register-OctoCliContext -Installation example-test -TenantId mytenant -UriSuffix pr123 -IncludeReporting
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Installation,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$TenantId,

        [string]$UriSuffix = "",

        [switch]$IncludeReporting,
        [switch]$IncludeAi,
        [switch]$NoSwitch,
        [switch]$NoLogin,
        [switch]$Json
    )

    $inst = Get-OctoInstallation -Name $Installation
    $tenants = @($TenantId | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if (-not $tenants.Count) { throw "TenantId must name at least one tenant." }
    $multi = $tenants.Count -gt 1
    $switchContext = (-not $NoSwitch) -and (-not $multi)
    $results = @()

    $errors = @()
    foreach ($tenant in $tenants) {
        try {
            $results += Register-OctoCliContextForTenant -Inst $inst -Installation $Installation -TenantId $tenant `
                -UriSuffix $UriSuffix -IncludeReporting:$IncludeReporting -IncludeAi:$IncludeAi `
                -SwitchContext:$switchContext -NoLogin:$NoLogin -Json:$Json -Quiet:$multi
        }
        catch {
            if (-not $multi) { throw }
            # One tenant must not stop the others; report all failures at the end.
            $errors += "${tenant}: $($_.Exception.Message)"
            $results += [pscustomobject]@{ TenantId = $tenant; ContextName = $null; Data = (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{ error = $_.Exception.Message }) }
        }
    }
    if ($errors.Count -and -not $Json) {
        throw "Registering contexts failed for $($errors.Count) of $($tenants.Count) tenants: $($errors -join '; ')"
    }

    if (-not $Json) { return }

    if (-not $multi) {
        Write-OctoJson -Command 'Register-OctoCliContext' -Data $results[0].Data
        return
    }
    $ok = -not ($results | Where-Object { -not $_.Data.success })
    Write-OctoJson -Command 'Register-OctoCliContext' -Data (New-OctoActionResult -Success $ok -ExitCode ($results | ForEach-Object { $_.Data.exitCode } | Where-Object { $_ } | Select-Object -First 1) -Extra @{
        contexts = @($results | ForEach-Object { [ordered]@{ tenantId = $_.TenantId; context = $_.ContextName; success = $_.Data.success; exitCode = $_.Data.exitCode } })
    })
}

function Register-OctoCliContextForTenant {
    # One tenant of Register-OctoCliContext. Unchanged behaviour of the former single-tenant cmdlet;
    # under -Json it returns the action result instead of writing it so the caller can aggregate.
    [CmdletBinding()]
    param($Inst, [string]$Installation, [string]$TenantId, [string]$UriSuffix, [switch]$IncludeReporting,
        [switch]$IncludeAi, [switch]$SwitchContext, [switch]$NoLogin, [switch]$Json, [switch]$Quiet)

    $inst = $Inst
    $NoSwitch = -not $SwitchContext

    $uriExtension = if ($UriSuffix) { "-$UriSuffix" } else { "" }
    $contextSuffix = if ($UriSuffix) { "_$UriSuffix" } else { "" }
    $contextName = "${Installation}${contextSuffix}_$TenantId"

    function Resolve-ServiceUri {
        param([string]$Key)
        $template = $inst.services.$Key
        if (-not $template) {
            throw "Installation '$Installation' does not define a '$Key' service URL in your octo-tools config."
        }
        return $template -f $uriExtension
    }

    $asu  = Resolve-ServiceUri 'assets'
    $isu  = Resolve-ServiceUri 'identity'
    $bsu  = Resolve-ServiceUri 'bots'
    $csu  = Resolve-ServiceUri 'communication'
    $rsu  = if ($IncludeReporting) { Resolve-ServiceUri 'reporting' } else { $null }
    $aisu = if ($IncludeAi)        { Resolve-ServiceUri 'ai' }        else { $null }

    $addArgs = @(
        '-c', 'AddContext',
        '-n', $contextName,
        '-asu', $asu,
        '-isu', $isu,
        '-bsu', $bsu,
        '-csu', $csu,
        '-tid', $TenantId
    )

    if ($IncludeReporting) {
        if (-not $Json -and -not $Quiet) { Write-Host "Including reporting" }
        $addArgs += @('-rsu', $rsu)
    }
    else {
        if (-not $Json -and -not $Quiet) { Write-Host "Excluding reporting" }
    }

    if ($IncludeAi) {
        if (-not $Json -and -not $Quiet) { Write-Host "Including AI" }
        $addArgs += @('-aisu', $aisu)
    }
    else {
        if (-not $Json -and -not $Quiet) { Write-Host "Excluding AI" }
    }

    if ($Json) {
        & octo-cli @addArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            return [pscustomobject]@{ TenantId = $TenantId; ContextName = $contextName; Data = (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = 'octo-cli AddContext failed' }) }
        }

        if (-not $NoSwitch) {
            & octo-cli -c UseContext -n $contextName | Out-Null
            if ($LASTEXITCODE -ne 0) {
                return [pscustomobject]@{ TenantId = $TenantId; ContextName = $contextName; Data = (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = 'octo-cli UseContext failed' }) }
            }
        }

        if (-not $NoLogin) {
            & octo-cli --context $contextName -c Login -i | Out-Null
        }

        return [pscustomobject]@{ TenantId = $TenantId; ContextName = $contextName; Data = (New-OctoActionResult -Success ($LASTEXITCODE -eq 0) -ExitCode $LASTEXITCODE) }
    }

    Write-Host "Registering context '$contextName' for installation '$Installation' (tenant '$TenantId')"
    & octo-cli @addArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "octo-cli AddContext failed with exit code $LASTEXITCODE"
    }

    if (-not $NoSwitch) {
        & octo-cli -c UseContext -n $contextName | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "octo-cli UseContext failed with exit code $LASTEXITCODE"
        }
    }

    if (-not $NoLogin) {
        & octo-cli --context $contextName -c Login -i | Out-Host
    }

    if (-not $Json) {
        [pscustomobject]@{ TenantId = $TenantId; ContextName = $contextName; Data = $null }
    }
}

Export-ModuleMember -Function @('Register-OctoCliContext')
