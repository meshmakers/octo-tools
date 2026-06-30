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
        Tenant id to bind the context to (required).

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
        Register-OctoCliContext -Installation example-test -TenantId mytenant -UriSuffix pr123 -IncludeReporting
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Installation,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [string]$UriSuffix = "",

        [switch]$IncludeReporting,
        [switch]$IncludeAi,
        [switch]$NoSwitch,
        [switch]$NoLogin,
        [switch]$Json
    )

    $inst = Get-OctoInstallation -Name $Installation

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
        if (-not $Json) { Write-Host "Including reporting" }
        $addArgs += @('-rsu', $rsu)
    }
    else {
        if (-not $Json) { Write-Host "Excluding reporting" }
    }

    if ($IncludeAi) {
        if (-not $Json) { Write-Host "Including AI" }
        $addArgs += @('-aisu', $aisu)
    }
    else {
        if (-not $Json) { Write-Host "Excluding AI" }
    }

    if ($Json) {
        & octo-cli @addArgs | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-OctoJson -Command 'Register-OctoCliContext' -Data (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = 'octo-cli AddContext failed' })
            return
        }

        if (-not $NoSwitch) {
            & octo-cli -c UseContext -n $contextName | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-OctoJson -Command 'Register-OctoCliContext' -Data (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = 'octo-cli UseContext failed' })
                return
            }
        }

        if (-not $NoLogin) {
            & octo-cli -c Login -i | Out-Null
        }

        Write-OctoJson -Command 'Register-OctoCliContext' -Data (New-OctoActionResult -Success ($LASTEXITCODE -eq 0) -ExitCode $LASTEXITCODE)
        return
    }

    Write-Host "Registering context '$contextName' for installation '$Installation' (tenant '$TenantId')"
    & octo-cli @addArgs
    if ($LASTEXITCODE -ne 0) {
        throw "octo-cli AddContext failed with exit code $LASTEXITCODE"
    }

    if (-not $NoSwitch) {
        & octo-cli -c UseContext -n $contextName
        if ($LASTEXITCODE -ne 0) {
            throw "octo-cli UseContext failed with exit code $LASTEXITCODE"
        }
    }

    if (-not $NoLogin) {
        & octo-cli -c Login -i
    }
}

Export-ModuleMember -Function @('Register-OctoCliContext')
