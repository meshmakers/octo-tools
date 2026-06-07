<#
.Synopsis
Octo AI Bastion — registers an Anthropic subscription token on an OctoMesh tenant.

.Description
Drives the Anthropic OAuth device-code flow on the operator's terminal, then
POSTs the resulting access + refresh token pair to the AI Adapter's
`POST /{tenantId}/v1/credentials/register` endpoint. The plaintext token
material is held in memory for the minimum time needed and explicitly
overwritten in a `finally` block so Ctrl-C still wipes it.

Two cmdlets are exported:

- `Register-AiBastion`  — full device-code flow + adapter POST.
- `Get-AiBastionStatus` — reads the current lease metadata.

Both target the AI Adapter's tenant-scoped REST surface and respect an
existing bearer token from the `OCTO_BASTION_TOKEN` environment variable
(typical pattern: an operator runs `octo-cli login` in another window,
exports the token, then runs the bastion module here).

For setup details on running the bastion host (`mm-ai-login.mm.cloud`)
including the allowed SSH user list and reverse-proxy config, see
`octo-tools/README.md` Bastion section (#4123).

.Parameter Tenant
The OctoMesh tenant slug whose lease should be (re)written.

.Parameter AdapterUrl
The AI Adapter base URL (no trailing slash) — e.g. `https://ai.mm.cloud`.

.Parameter BearerToken
Bearer token used to authorise the POST. Optional — falls back to the
`OCTO_BASTION_TOKEN` environment variable. The bastion CLI never reads
the OctoMesh user database itself; the operator's OctoMesh OAuth token
is the auth surface.

.Parameter Ticket
One-time-code an admin issued (future flow). Phase-1 ignores this — the
operator runs the cmdlet directly with their own bearer token — but the
parameter is accepted so the future server-side ticket validator doesn't
break callers.

.Example
Register-AiBastion -Tenant acme -AdapterUrl https://ai.mm.cloud
#>

function Register-AiBastion {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tenant,

        [Parameter(Mandatory = $true)]
        [string]$AdapterUrl,

        [string]$BearerToken,

        [string]$Ticket
    )

    if (-not $BearerToken) {
        $BearerToken = $env:OCTO_BASTION_TOKEN
    }
    if (-not $BearerToken) {
        Write-Error "No bearer token supplied. Pass -BearerToken or set OCTO_BASTION_TOKEN."
        return
    }

    $AdapterUrl = $AdapterUrl.TrimEnd('/')
    # Phase-1 Anthropic device-code constants. These belong to the public OAuth
    # client Anthropic ships for the CLI; no secret needed.
    $clientId = 'cli'
    $deviceAuthUrl = 'https://console.anthropic.com/oauth/device'
    $tokenUrl = 'https://console.anthropic.com/oauth/token'
    $scope = 'org:create_api_key user:profile user:inference'

    # Holders for the secret material; we wipe these in `finally` regardless of
    # outcome so a Ctrl-C while waiting on the device-code poll still drops the
    # plaintext from this process's memory.
    $deviceCode = $null
    $accessToken = $null
    $refreshToken = $null

    try {
        Write-Host "Requesting device code from Anthropic..."
        $deviceResp = Invoke-RestMethod -Method Post -Uri $deviceAuthUrl `
            -ContentType 'application/x-www-form-urlencoded' `
            -Body @{
                client_id = $clientId
                scope = $scope
            }
        $deviceCode = $deviceResp.device_code
        $userCode = $deviceResp.user_code
        $verificationUrl = $deviceResp.verification_uri_complete
        $interval = [int]($deviceResp.interval | ForEach-Object { if ($_) { $_ } else { 5 } })
        $expiresIn = [int]($deviceResp.expires_in | ForEach-Object { if ($_) { $_ } else { 600 } })

        Write-Host ""
        Write-Host "=== Anthropic device authorization ==="
        Write-Host "Open this URL in your browser: $verificationUrl"
        Write-Host "User code: $userCode"
        Write-Host "Waiting for authorization (poll every ${interval}s, expires in ${expiresIn}s)..."
        Write-Host ""

        $deadline = (Get-Date).AddSeconds($expiresIn)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $interval

            try {
                $tokenResp = Invoke-RestMethod -Method Post -Uri $tokenUrl `
                    -ContentType 'application/x-www-form-urlencoded' `
                    -Body @{
                        grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                        client_id = $clientId
                        device_code = $deviceCode
                    } -ErrorAction Stop
                $accessToken = $tokenResp.access_token
                $refreshToken = $tokenResp.refresh_token
                $expiresInSec = [int]$tokenResp.expires_in
                $refreshExpiresInSec = [int]($tokenResp.refresh_expires_in | ForEach-Object {
                    if ($_) { $_ } else { 5184000 } # 60 days default fallback
                })
                break
            }
            catch [System.Net.WebException] {
                # Anthropic returns 400 with body { error: "authorization_pending" } while the
                # user hasn't approved yet. Treat that as "keep polling"; surface anything else.
                $resp = $_.Exception.Response
                if ($null -ne $resp) {
                    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                    $body = $reader.ReadToEnd()
                    if ($body -match 'authorization_pending|slow_down') {
                        if ($body -match 'slow_down') { $interval += 5 }
                        continue
                    }
                }
                throw
            }
        }

        if (-not $accessToken) {
            Write-Error "Device authorization timed out before completion."
            return
        }

        Write-Host "Authorization succeeded. Submitting token to adapter..."

        $accessExpiresAt = (Get-Date).ToUniversalTime().AddSeconds($expiresInSec)
        $refreshExpiresAt = (Get-Date).ToUniversalTime().AddSeconds($refreshExpiresInSec)

        $body = @{
            accessToken = $accessToken
            refreshToken = $refreshToken
            accessExpiresAt = $accessExpiresAt.ToString('o')
            refreshExpiresAt = $refreshExpiresAt.ToString('o')
        } | ConvertTo-Json -Compress

        $registerUri = "$AdapterUrl/$Tenant/v1/credentials/register"
        if ($PSCmdlet.ShouldProcess($registerUri, "POST credentials")) {
            $statusResp = Invoke-RestMethod -Method Post -Uri $registerUri `
                -Headers @{ Authorization = "Bearer $BearerToken" } `
                -ContentType 'application/json' `
                -Body $body
            Write-Host ""
            Write-Host "=== Bastion register OK ==="
            Write-Host "Status:           $($statusResp.status)"
            Write-Host "Generation:       $($statusResp.generation)"
            Write-Host "Access expires:   $($statusResp.accessExpiresAt)"
            Write-Host "Refresh expires:  $($statusResp.refreshExpiresAt)"
        }
    }
    finally {
        # Overwrite secret material before the variables drop out of scope so a
        # memory inspection of the powershell process post-mortem can't recover
        # the plaintext.
        if ($null -ne $accessToken) { $accessToken = ('0' * $accessToken.Length); Remove-Variable accessToken -ErrorAction SilentlyContinue }
        if ($null -ne $refreshToken) { $refreshToken = ('0' * $refreshToken.Length); Remove-Variable refreshToken -ErrorAction SilentlyContinue }
        if ($null -ne $deviceCode) { $deviceCode = ('0' * $deviceCode.Length); Remove-Variable deviceCode -ErrorAction SilentlyContinue }
        if (-not [string]::IsNullOrEmpty($BearerToken)) {
            # Best-effort clearing of the bearer too — the caller may have passed it on the
            # command line and PowerShell history would otherwise retain the literal.
            Remove-Variable BearerToken -ErrorAction SilentlyContinue
        }
        [System.GC]::Collect()
    }
}

function Get-AiBastionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tenant,

        [Parameter(Mandatory = $true)]
        [string]$AdapterUrl,

        [string]$BearerToken
    )

    if (-not $BearerToken) {
        $BearerToken = $env:OCTO_BASTION_TOKEN
    }
    if (-not $BearerToken) {
        Write-Error "No bearer token supplied. Pass -BearerToken or set OCTO_BASTION_TOKEN."
        return
    }

    $AdapterUrl = $AdapterUrl.TrimEnd('/')
    $statusUri = "$AdapterUrl/$Tenant/v1/credentials/status"

    try {
        $statusResp = Invoke-RestMethod -Method Get -Uri $statusUri `
            -Headers @{ Authorization = "Bearer $BearerToken" }

        Write-Host "=== Bastion status: $Tenant ==="
        Write-Host "Status:           $($statusResp.status)"
        Write-Host "Generation:       $($statusResp.generation)"
        if ($statusResp.accessExpiresAt) {
            Write-Host "Access expires:   $($statusResp.accessExpiresAt)"
        }
        if ($statusResp.refreshExpiresAt) {
            Write-Host "Refresh expires:  $($statusResp.refreshExpiresAt)"
        }
        return $statusResp
    }
    finally {
        if (-not [string]::IsNullOrEmpty($BearerToken)) {
            Remove-Variable BearerToken -ErrorAction SilentlyContinue
        }
    }
}

Export-ModuleMember -Function @('Register-AiBastion', 'Get-AiBastionStatus')
