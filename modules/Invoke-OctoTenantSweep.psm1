<#
.SYNOPSIS
    Runs one octo-cli command against many tenants (AB#6840).

.DESCRIPTION
    A thin loop around `octo-cli --context <ctx> -c <command>`. Authentication is entirely octo-cli's job
    (per-tenant sign-in or the tenant token exchange of AB#6836); this module never reads, prints, logs or
    writes a token, never opens the octo-cli context file and never sends an HTTP request itself.
    Everything octo-cli prints is scrubbed of JWT-shaped strings before the helper shows or returns it.
#>

$script:MinimumOctoCliVersion = [version]'3.5.27'

function Invoke-OctoCliCapture {
    # The single place that starts octo-cli. Returns the exit code and the combined output (stdout+stderr).
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $items = @(& octo-cli @Arguments 2>&1)
    $code = $LASTEXITCODE
    $output = $items | Out-String
    # Standard output only (stderr arrives as ErrorRecord): the clean answer of commands such as GraphQl.
    $stdout = @($items | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) | Out-String
    # Unix reports exit -4 as 252; normalise to the signed value octo-cli documents.
    if ($code -gt 127) { $code -= 256 }
    [pscustomobject]@{ ExitCode = $code; Output = $output; Stdout = $stdout }
}

function Protect-OctoSweepText {
    # Defence in depth: octo-cli does not print tokens, but a sweep must be able to promise it.
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = [regex]::Replace($Text, '(?i)\b(bearer|access_token|refresh_token|client_secret|id_token)\b(["'':= ]+)[^\s"'',;]+', '$1$2<removed>')
    $t = [regex]::Replace($t, 'eyJ[A-Za-z0-9_\-]{6,}(\.[A-Za-z0-9_\-]*){1,2}', '<token removed>')
    $t
}

function Get-OctoCliVersionInfo {
    [CmdletBinding()]
    param()

    $r = Invoke-OctoCliCapture -Arguments @('--help')
    $m = [regex]::Match($r.Output, 'Version\s+(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) { return $null }
    [version]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value)
}

function Assert-OctoCliVersion {
    [CmdletBinding()]
    param()

    $v = Get-OctoCliVersionInfo
    if ($null -eq $v) {
        throw "Cannot determine the octo-cli version (is octo-cli on the PATH?). Invoke-OctoTenantSweep needs octo-cli $($script:MinimumOctoCliVersion) or newer (per-tenant token exchange, AB#6836)."
    }
    if ($v -lt $script:MinimumOctoCliVersion) {
        throw "octo-cli $v is too old: Invoke-OctoTenantSweep needs $($script:MinimumOctoCliVersion) or newer (per-tenant token exchange, AB#6836). Update octo-cli and retry."
    }
}

function Resolve-OctoSweepOutcome {
    # Pure classification of one finished octo-cli call -> @{ Outcome; Cause }.
    [CmdletBinding()]
    param([int]$ExitCode, [string]$Output)

    $clean = Protect-OctoSweepText $Output
    $lines = @($clean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ExitCode -eq 0) { return @{ Outcome = 'Ok'; Cause = '' } }

    $denial = '(?i)ProvisionCurrentUser|not provisioned|access_denied|unauthorized_client|denied|forbidden|\b403\b|not allowed to exchange'
    $hit = $lines | Where-Object { $_ -match $denial } | Select-Object -First 1
    if ($ExitCode -eq -4 -or $hit) {
        $cause = if ($hit) { $hit } elseif ($lines.Count) { $lines[-1] } else { "exit code $ExitCode" }
        return @{ Outcome = 'Denied'; Cause = $cause }
    }
    $last = if ($lines.Count) { $lines[-1] } else { "exit code $ExitCode" }
    @{ Outcome = 'Failed'; Cause = $last }
}

function Resolve-OctoSweepTenants {
    [CmdletBinding()]
    param([string]$Context, [string[]]$Tenant, [switch]$AllTenants, [string[]]$Exclude)

    $list = @()
    if ($Tenant) { $list += $Tenant }
    if ($AllTenants) {
        $r = Invoke-OctoCliCapture -Arguments @('--context', $Context, '-c', 'GetTenants', '--all')
        if ($r.ExitCode -ne 0) {
            $why = (Resolve-OctoSweepOutcome -ExitCode $r.ExitCode -Output $r.Output).Cause
            throw "Listing the tenants with context '$Context' failed: $why"
        }
        $start = $r.Output.IndexOf('[')
        if ($start -lt 0) { throw "Context '$Context' returned no tenant list." }
        $parsed = $r.Output.Substring($start) | ConvertFrom-Json
        $list += @($parsed | ForEach-Object { $_.tenantId ?? $_.TenantId } | Where-Object { $_ })
    }
    @($list | ForEach-Object { "$_".ToLowerInvariant() } | Select-Object -Unique | Where-Object { $Exclude -notcontains $_ })
}

function Invoke-OctoTenantSweep {
    <#
    .SYNOPSIS
        Runs an octo-cli command against many tenants and reports one result row per tenant.

    .DESCRIPTION
        Two ways to address a tenant, because octo-cli itself has both:

        * Context per tenant (-ContextTemplate / -Installation): commands that act on "the context's
          tenant" (LibraryStatus, blueprint commands, GraphQL, ...). The helper calls
          `octo-cli --context <name> -c ...` with the context name built from the template.
          Create the contexts first: `Register-OctoCliContext -Installation <i> -TenantId a,b,c -NoSwitch`.
        * One context, tenant in the arguments (-Context): commands with their own tenant argument
          (`-tid`, `-ttid`). Put `{tenant}` into -CliArguments.

        Authentication is octo-cli's: a context for a child tenant whose token belongs to another tenant is
        exchanged per tenant (needs `ProvisionCurrentUser -ttid <tenant>` once per child tenant); a tenant
        where the operator is not provisioned is reported as Denied and the sweep continues. The active
        context is never changed. No token is read, printed, logged or written.

        -WhatIf lists the tenants and the exact octo-cli calls without running anything.

    .PARAMETER CliArguments
        Arguments for octo-cli after the context selection, e.g. '-c','LibraryStatus','-io'. `{tenant}` is
        replaced by the tenant id.

    .PARAMETER Installation
        Shortcut for -ContextTemplate '<Installation>[_<UriSuffix>]_{tenant}' (the names Register-OctoCliContext creates).

    .PARAMETER ContextTemplate
        Context name per tenant, `{tenant}` is replaced, e.g. 'test2_{tenant}'.

    .PARAMETER Context
        One fixed context (listing tenants with -AllTenants; tenant-argument commands). Mandatory with -AllTenants.

    .PARAMETER Tenant
        Tenant ids to process.

    .PARAMETER AllTenants
        Take the tenant list from `GetTenants --all` of -Context (system tenant context).

    .PARAMETER Exclude
        Tenant ids to leave out.

    .PARAMETER ShowOutput
        Also write the (scrubbed) octo-cli output of every tenant to the information stream.

    .PARAMETER IncludeOutput
        Add a `Stdout` property to every row: the scrubbed standard output of octo-cli (for `GraphQl` the
        response JSON, ready for ConvertFrom-Json). Rows are objects only; combine with -Json to get it in the envelope.

    .PARAMETER Json
        Emit the standard octo-tools JSON envelope instead of the table.

    .EXAMPLE
        Invoke-OctoTenantSweep -Installation test2 -Tenant tecob,lkv,wwc26 -CliArguments '-c','LibraryStatus','-io' -WhatIf

    .EXAMPLE
        Invoke-OctoTenantSweep -Context test2_octosystem -AllTenants -CliArguments '-c','ProvisionCurrentUser','-ttid','{tenant}'

    .EXAMPLE
        # GraphQL over many tenants (octo-cli GraphQl, AB#7027): one read-only query, the answer per tenant
        $q = '{ runtime { runtimeEntities(ckId:"System/Entity", first:1) { totalCount } } }'
        Invoke-OctoTenantSweep -Context test2_octosystem -Tenant tecob,lkv -IncludeOutput `
            -CliArguments '-c','GraphQl','-tid','{tenant}','-q',$q |
            ForEach-Object { [pscustomobject]@{ Tenant = $_.Tenant; Outcome = $_.Outcome; Total = ($_.Stdout | ConvertFrom-Json).data.runtime.runtimeEntities.totalCount } }
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Template')]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$CliArguments,

        [Parameter(ParameterSetName = 'Installation', Mandatory)]
        [string]$Installation,

        [Parameter(ParameterSetName = 'Installation')]
        [string]$UriSuffix = '',

        [Parameter(ParameterSetName = 'Template', Mandatory)]
        [string]$ContextTemplate,

        [Parameter(ParameterSetName = 'Fixed', Mandatory)]
        [string]$Context,

        [string[]]$Tenant,
        [switch]$AllTenants,
        [string[]]$Exclude = @(),
        [switch]$ShowOutput,
        [switch]$IncludeOutput,
        [switch]$Json
    )

    if ($CliArguments -contains '--context' -or $CliArguments -contains '-context' -or $CliArguments -contains '/context') {
        throw "-CliArguments must not contain --context; the helper selects the context per tenant."
    }
    if ($PSCmdlet.ParameterSetName -eq 'Installation') {
        $sfx = if ($UriSuffix) { "_$UriSuffix" } else { '' }
        $ContextTemplate = "${Installation}${sfx}_{tenant}"
    }
    $fixed = $PSCmdlet.ParameterSetName -eq 'Fixed'
    if ($AllTenants -and -not $fixed) {
        throw "-AllTenants needs -Context <system tenant context> to list the tenants."
    }
    if ($AllTenants -and $Tenant) { throw "Use either -Tenant or -AllTenants." }
    if (-not $AllTenants -and -not $Tenant) { throw "Name the tenants with -Tenant or use -AllTenants." }
    if (-not $fixed -and $ContextTemplate -notmatch '\{tenant\}') {
        throw "-ContextTemplate must contain {tenant}."
    }

    Assert-OctoCliVersion

    $tenants = Resolve-OctoSweepTenants -Context $Context -Tenant $Tenant -AllTenants:$AllTenants -Exclude $Exclude
    if (-not $tenants.Count) { throw "No tenants to process." }

    $plan = foreach ($t in $tenants) {
        $ctx = if ($fixed) { $Context } else { $ContextTemplate.Replace('{tenant}', $t) }
        $cliArgs = @('--context', $ctx) + @($CliArguments | ForEach-Object { $_.Replace('{tenant}', $t) })
        [pscustomobject]@{ Tenant = $t; Context = $ctx; CliArgs = $cliArgs }
    }

    $rows = foreach ($p in $plan) {
        $display = 'octo-cli ' + ($p.CliArgs -join ' ')
        if (-not $PSCmdlet.ShouldProcess($p.Tenant, $display)) {
            [pscustomobject]@{ Tenant = $p.Tenant; Context = $p.Context; Outcome = 'Planned'; ExitCode = $null; Cause = '' }
            continue
        }
        try {
            $r = Invoke-OctoCliCapture -Arguments $p.CliArgs
            $res = Resolve-OctoSweepOutcome -ExitCode $r.ExitCode -Output $r.Output
            if ($ShowOutput) { Write-Information (Protect-OctoSweepText $r.Output) -InformationAction Continue }
            $row = [ordered]@{ Tenant = $p.Tenant; Context = $p.Context; Outcome = $res.Outcome; ExitCode = $r.ExitCode; Cause = $res.Cause }
            if ($IncludeOutput) { $row['Stdout'] = (Protect-OctoSweepText $r.Stdout).Trim() }
            [pscustomobject]$row
        }
        catch {
            [pscustomobject]@{ Tenant = $p.Tenant; Context = $p.Context; Outcome = 'Failed'; ExitCode = $null; Cause = (Protect-OctoSweepText $_.Exception.Message) }
        }
    }
    $rows = @($rows)

    if ($Json) {
        $summary = [ordered]@{
            total  = $rows.Count
            ok     = @($rows | Where-Object Outcome -eq 'Ok').Count
            denied = @($rows | Where-Object Outcome -eq 'Denied').Count
            failed = @($rows | Where-Object Outcome -eq 'Failed').Count
        }
        Write-OctoJson -Command 'Invoke-OctoTenantSweep' -Data ([ordered]@{ summary = $summary; results = $rows })
        return
    }

    $rows
}

Export-ModuleMember -Function @('Invoke-OctoTenantSweep')
