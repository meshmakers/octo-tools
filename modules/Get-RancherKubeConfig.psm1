function Get-RancherKubeConfig {
    <#
    .SYNOPSIS
        Fetches a kubeconfig for a managed cluster from Rancher and merges it
        into ~/.kube/config via Join-KubeConfigs.

    .DESCRIPTION
        Calls the Rancher v3 API to:
          1. Resolve the supplied cluster name to its Rancher cluster id.
          2. Generate a kubeconfig via `POST /v3/clusters/{id}?action=generateKubeconfig`.
          3. Rewrite the internal cluster id inside the kubeconfig so the
             context/cluster/user are named after the Rancher cluster name
             (e.g. `prod-1`) instead of Rancher's internal id (`c-j52ds`).
          4. Remove a previous context with the same name (if any) via
             Remove-KubeConfig and merge the new one via Join-KubeConfigs.

        The resulting kubeconfig carries whatever permissions the API token's
        user has — by design this is the everyday read-only access path. For
        write access, use Request-BreakGlassKubeConfig.

        Required env vars:
          RANCHER_URL         (shared, set in profile.ps1)
          RANCHER_API_TOKEN   (per-developer, set in private profile)

        Create the API token at:
          Rancher UI -> User Avatar -> Account & API Keys -> Create API Key
        Choose "No Scope" (or a cluster-scope if you want a per-cluster token)
        and an explicit expiry.

    .PARAMETER Cluster
        Cluster name as shown in Rancher.

    .PARAMETER RancherUrl
        Rancher base URL. Default: $env:RANCHER_URL.

    .PARAMETER RancherApiToken
        Rancher API token (format `token-xxxxx:secret`).
        Default: $env:RANCHER_API_TOKEN.

    .PARAMETER ContextName
        Optional override for the context/cluster/user name written into
        ~/.kube/config. Default: same as -Cluster.

    .PARAMETER SkipTlsVerify
        Skip TLS certificate validation when talking to Rancher.

    .EXAMPLE
        Get-RancherKubeConfig -Cluster prod-1

    .EXAMPLE
        Get-RancherKubeConfig -Cluster test-2 -ContextName test-2-readonly
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('infra', 'prod-1', 'prod-2', 'staging-1', 'test-2', 'local')]
        [string]$Cluster,

        [Parameter()]
        [string]$RancherUrl = $env:RANCHER_URL,

        [Parameter()]
        [string]$RancherApiToken = $env:RANCHER_API_TOKEN,

        [Parameter()]
        [string]$ContextName,

        [Parameter()]
        [switch]$SkipTlsVerify,

        [Parameter()]
        [switch]$Json
    )

    if (-not $RancherUrl)      { throw "RANCHER_URL not set (env var or -RancherUrl). It should be defined in octo-tools/modules/profile.ps1." }
    if (-not $RancherApiToken) { throw "RANCHER_API_TOKEN not set. Add it to your private profile: `$env:RANCHER_API_TOKEN = 'token-xxxxx:secret'." }
    if ($RancherApiToken -notmatch '^token-[a-z0-9]+:.+') {
        throw "RANCHER_API_TOKEN does not look like a Rancher token (expected format: 'token-xxxxx:secret')."
    }
    if (-not $ContextName) { $ContextName = $Cluster }

    $RancherUrl = $RancherUrl.TrimEnd('/')

    # Rancher requires CSRF protection (double-submit cookie) even with Bearer
    # auth on state-changing actions. Cookie value and X-Api-CSRF header must
    # match; the value itself is not signed, any random nonce works.
    $csrfNonce = [Guid]::NewGuid().ToString('N')
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $session.Cookies.Add((New-Object System.Net.Cookie('CSRF', $csrfNonce, '/', ([Uri]$RancherUrl).Host)))

    $headers = @{
        Authorization = "Bearer $RancherApiToken"
        Accept        = 'application/json'
        'X-Api-CSRF'  = $csrfNonce
    }
    $restCommon = @{ Headers = $headers; WebSession = $session }
    if ($SkipTlsVerify) { $restCommon.SkipCertificateCheck = $true }

    Write-Host "Resolving cluster '$Cluster' on $RancherUrl"
    try {
        $clusters = Invoke-RestMethod -Uri "$RancherUrl/v3/clusters?name=$Cluster" -Method GET @restCommon -ErrorAction Stop
    }
    catch {
        throw "Failed to query Rancher /v3/clusters: $($_.Exception.Message)"
    }
    $clusterObj = $clusters.data | Where-Object { $_.name -eq $Cluster } | Select-Object -First 1
    if (-not $clusterObj) {
        throw "Cluster '$Cluster' not found via Rancher API. Token user may lack list access on /v3/clusters."
    }
    $clusterId = $clusterObj.id
    Write-Verbose "Resolved $Cluster -> $clusterId"

    Write-Host "Requesting kubeconfig for $Cluster ($clusterId)"
    try {
        $genResp = Invoke-RestMethod -Uri "$RancherUrl/v3/clusters/${clusterId}?action=generateKubeconfig" `
            -Method POST -ContentType 'application/json' -Body '{}' @restCommon -ErrorAction Stop
    }
    catch {
        $body = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $body = $_.ErrorDetails.Message
        }
        elseif ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd()
                }
            } catch { }
        }
        throw @"
Failed to generate kubeconfig for $Cluster ($clusterId).
  Status:       $($_.Exception.Message)
  Response:     $body
Hint: 422 'kubeconfig token generation disabled' = global setting `kubeconfig-generate-token` is false.
      403/401 = token expired or user lacks read access on the cluster.
"@
    }
    $kubeconfigYaml = $genResp.config
    if (-not $kubeconfigYaml) {
        throw "Rancher returned no 'config' payload."
    }

    # Rancher emits the cluster id as the context/cluster/user name. Rewrite
    # those occurrences to the requested ContextName so kubectl --context=<name>
    # matches the cluster name the user types.
    $needles = @($clusterId)
    if ($clusterObj.name -and $clusterObj.name -ne $clusterId) {
        $needles += $clusterObj.name
    }
    foreach ($needle in $needles | Select-Object -Unique) {
        $kubeconfigYaml = [regex]::Replace(
            $kubeconfigYaml,
            "(?<=^|\s|:)" + [regex]::Escape($needle) + "(?=$|\s)",
            $ContextName
        )
    }

    $tmpFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmpFile -Value $kubeconfigYaml -NoNewline -Encoding utf8

    try {
        $kubeFile = if ($IsLinux -or $IsMacOS) { Join-Path $env:HOME ".kube/config" } else { Join-Path $env:USERPROFILE ".kube/config" }

        if (-not (Test-Path $kubeFile)) {
            $kubeDir = Split-Path -Parent $kubeFile
            if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Force -Path $kubeDir | Out-Null }
            Copy-Item $tmpFile $kubeFile
            if ($IsLinux -or $IsMacOS) { chmod 600 $kubeFile 2>$null }
            Write-Host "Created ~/.kube/config with context '$ContextName'"
        }
        else {
            $existingContexts = @(kubectl config get-contexts -o name 2>$null)
            if ($existingContexts -contains $ContextName) {
                Write-Host "Removing existing context: $ContextName"
                Remove-KubeConfig -name $ContextName
            }
            Join-KubeConfigs -externalKubeConfig $tmpFile
        }
    }
    finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    if ($Json) {
        # Emit only non-sensitive metadata — never the kubeconfig payload itself.
        Write-OctoJson -Command 'Get-RancherKubeConfig' -Data ([ordered]@{
            cluster     = $Cluster
            contextName = $ContextName
            clusterId   = $clusterId
            kubeFile    = $kubeFile
            merged      = $true
        })
        return
    }

    Write-Host ""
    Write-Host "Rancher kubeconfig active:"
    Write-Host "  Context : $ContextName"
    Write-Host "  Cluster : $Cluster ($clusterId)"
    Write-Host ""
    Write-Host "Use it:"
    Write-Host "  kubectl --context=$ContextName get ns"
    Write-Host "  kubectl config use-context $ContextName"
    Write-Host ""
    Write-Host "Permissions are whatever your Rancher API-token user has."
    Write-Host "For write access, use Request-BreakGlassKubeConfig."
}

Export-ModuleMember -Function @('Get-RancherKubeConfig')
