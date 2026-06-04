function Register-OctoCliContext {
    <#
    .SYNOPSIS
        Registers an octo-cli context for one of the known OctoMesh installations.

    .DESCRIPTION
        Unified replacement for Invoke-OctoCliLoginLocal / -Staging / -Production / -Test2.
        Builds the service URIs for the chosen installation, calls 'octo-cli -c AddContext',
        optionally switches to the new context and triggers an interactive login.

    .PARAMETER Installation
        Target OctoMesh installation: local, test-2, staging-1, prod-1 or prod-2.
        Cluster domain mapping:
          local     -> localhost
          test-2    -> *.test-2.mm.cloud
          staging-1 -> *.staging.octo-mesh.com         (Azure AKS staging-1)
          prod-1    -> *.prod-1.octo-mesh.com          (Exoscale SKS Vienna)
          prod-2    -> *.prod-2.octo-mesh.com          (Azure AKS prod-2)

    .PARAMETER TenantId
        Tenant id to bind the context to (required).

    .PARAMETER UriSuffix
        Optional URI suffix used for Test2 sub-environments (e.g. 'pr123' -> assets-pr123.test-2.mm.cloud).
        Also appended to the context name to keep contexts distinct.

    .PARAMETER IncludeReporting
        If set, also registers the reporting service URI (-rsu).

    .PARAMETER NoSwitch
        If set, skips 'UseContext' so the active context stays unchanged.

    .PARAMETER NoLogin
        If set, skips the interactive 'Login -i' step (useful for CI / client-credentials flow).

    .EXAMPLE
        Register-OctoCliContext -Installation staging-1 -TenantId meshtest

    .EXAMPLE
        Register-OctoCliContext -Installation test-2 -TenantId voest -UriSuffix pr123 -IncludeReporting

    .EXAMPLE
        Register-OctoCliContext -Installation prod-1 -TenantId meshmakers -NoLogin

    .EXAMPLE
        Register-OctoCliContext -Installation prod-2 -TenantId voest -IncludeReporting
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('local', 'test-2', 'staging-1', 'prod-1', 'prod-2')]
        [string]$Installation,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId,

        [string]$UriSuffix = "",

        [switch]$IncludeReporting,
        [switch]$NoSwitch,
        [switch]$NoLogin
    )

    $uriExtension = if ($UriSuffix) { "-$UriSuffix" } else { "" }
    $contextSuffix = if ($UriSuffix) { "_$UriSuffix" } else { "" }

    switch ($Installation) {
        'local' {
            $contextName = "local${contextSuffix}_$TenantId"
            $asu = "https://localhost:5001/"
            $isu = "https://localhost:5003/"
            $bsu = "https://localhost:5009/"
            $csu = "https://localhost:5015/"
            $rsu = "https://localhost:5007/"
        }
        'test-2' {
            $contextName = "test-2${contextSuffix}_$TenantId"
            $asu = "https://assets$uriExtension.test-2.mm.cloud/"
            $isu = "https://connect$uriExtension.test-2.mm.cloud/"
            $bsu = "https://bots$uriExtension.test-2.mm.cloud/"
            $csu = "https://communication$uriExtension.test-2.mm.cloud/"
            $rsu = "https://reporting$uriExtension.test-2.mm.cloud/"
        }
        'staging-1' {
            $contextName = "staging-1${contextSuffix}_$TenantId"
            $asu = "https://assets$uriExtension.staging.octo-mesh.com/"
            $isu = "https://connect$uriExtension.staging.octo-mesh.com/"
            $bsu = "https://bots$uriExtension.staging.octo-mesh.com/"
            $csu = "https://communication$uriExtension.staging.octo-mesh.com/"
            $rsu = "https://reporting$uriExtension.staging.octo-mesh.com/"
        }
        'prod-1' {
            $contextName = "prod-1${contextSuffix}_$TenantId"
            $asu = "https://assets$uriExtension.prod-1.octo-mesh.com/"
            $isu = "https://connect$uriExtension.prod-1.octo-mesh.com/"
            $bsu = "https://bots$uriExtension.prod-1.octo-mesh.com/"
            $csu = "https://communication$uriExtension.prod-1.octo-mesh.com/"
            $rsu = "https://reporting$uriExtension.prod-1.octo-mesh.com/"
        }
        'prod-2' {
            $contextName = "prod-2${contextSuffix}_$TenantId"
            $asu = "https://assets$uriExtension.prod-2.octo-mesh.com/"
            $isu = "https://connect$uriExtension.prod-2.octo-mesh.com/"
            $bsu = "https://bots$uriExtension.prod-2.octo-mesh.com/"
            $csu = "https://communication$uriExtension.prod-2.octo-mesh.com/"
            $rsu = "https://reporting$uriExtension.prod-2.octo-mesh.com/"
        }
    }

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
        Write-Host "Including reporting"
        $addArgs += @('-rsu', $rsu)
    }
    else {
        Write-Host "Excluding reporting"
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
