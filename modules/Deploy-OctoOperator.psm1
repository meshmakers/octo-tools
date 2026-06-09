function Get-HostLanIPv4 {
    <#
.SYNOPSIS
Returns the first non-loopback IPv4 address of this machine.

.DESCRIPTION
Resolves the host's own addresses and picks the first one that is an IPv4
(InterNetwork) address and is not a loopback address. The operator running
inside kind connects back to the host's Communication Controller over the
LAN, so the in-cluster pods must reach the host by its routable LAN IP, not
by 127.0.0.1 / localhost.
#>
    try {
        $addresses = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())
        foreach ($address in $addresses) {
            if ($address.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($address)) {
                return $address.IPAddressToString
            }
        }
    }
    catch {
        # Some hosts (e.g. macOS without the bare hostname in /etc/hosts) cannot
        # resolve their own hostname via DNS. Fall back to enumerating the
        # machine's network interfaces directly for an up/operational IPv4.
        Write-Verbose "GetHostAddresses failed ($($_.Exception.Message)); falling back to interface enumeration."
    }

    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        if ($nic.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ip in $nic.GetIPProperties().UnicastAddresses) {
            $address = $ip.Address
            if ($address.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($address)) {
                return $address.IPAddressToString
            }
        }
    }
    return $null
}

function Get-KindHostGatewayIp {
    <#
.SYNOPSIS
Returns the IP the kind node uses for host.docker.internal — the Docker host gateway.

.DESCRIPTION
On Docker Desktop the kind node resolves host.docker.internal to a stable gateway
address (e.g. 192.168.65.254) that does NOT change when the host's LAN / VPN /
Tailscale IP changes. In-cluster pods reach the host's services through it
directly (it is an IP, so no in-cluster DNS entry is needed). Preferred over
Get-HostLanIPv4 for the Communication Controller URI, whose LAN IP otherwise
flaps (e.g. Wi-Fi vs Tailscale).

On Docker CE (Linux), the kind node does NOT get a host.docker.internal entry,
but its default-route gateway is the kind bridge gateway (e.g. 172.18.0.1) which
*is* the host as seen from the node — the Docker CE equivalent of the host
gateway, and equally stable for the cluster's lifetime. We fall back to it so
Linux hosts also get a stable controller address instead of the flappy LAN IP.

.PARAMETER ClusterName
kind cluster name; the node container is "{ClusterName}-control-plane". Defaults to "kind".
#>
    param([Parameter()] [string]$ClusterName = "kind")
    $node = "$ClusterName-control-plane"
    # `getent hosts` may return only the AAAA record on Docker Desktop setups where
    # host.docker.internal has both A and AAAA — but kindnet pods are IPv4-only and
    # cannot reach an IPv6 host. Ask explicitly for IPv4 so the address we return
    # is one a pod can actually connect to.
    $line = & docker exec $node getent ahostsv4 host.docker.internal 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($line)) {
        return (($line -split '\s+') | Where-Object { $_ })[0]
    }
    # Docker CE / Linux: no host.docker.internal entry. The node's default-route
    # gateway is the kind bridge gateway, which routes to the host.
    $route = & docker exec $node ip -4 route show default 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($route)) {
        # e.g. "default via 172.18.0.1 dev eth0"
        $parts = ($route -split '\s+') | Where-Object { $_ }
        $viaIdx = [Array]::IndexOf($parts, 'via')
        if ($viaIdx -ge 0 -and $viaIdx + 1 -lt $parts.Count) {
            return $parts[$viaIdx + 1]
        }
    }
    return $null
}

function Test-OctoNodeResolves {
<#
.SYNOPSIS
Returns $true if the kind node can resolve a DNS name from inside the node.

.DESCRIPTION
Used as a Deploy-OctoOperator pre-flight. The node's kubelet pulls the operator image
from the internal dev registry (image.privateRegistry, e.g. docker.mm.cloud), which
resolves only over Tailscale's split-DNS (mm.cloud -> tailnet). If the node can't
resolve it the pull ImagePullBackOff's and the rollout sits for the full timeout before
erroring — so we check first and fail fast with an actionable message. `getent hosts`
exits 0 only when the name resolves.
#>
    param(
        [Parameter(Mandatory)] [string]$Node,
        [Parameter(Mandatory)] [string]$Name
    )
    $out = (& docker exec $Node getent hosts $Name 2>$null | Out-String)
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($out))
}

function Deploy-OctoOperator {
    <#
.SYNOPSIS
Deploys the OctoMesh Communication Operator (central mode) into the local
kind cluster via the octo-mesh-communication-operator Helm chart.

.DESCRIPTION
Generates self-signed admission-webhook serving certificates with openssl
(CA + server cert with the in-cluster Service DNS as SAN), then installs the
operator chart with those certs and dev values. The operator's validating /
mutating webhooks are served by the operator pod over HTTPS; the chart wires
the CA cert into each webhook's caBundle, so the generated material must be
self-consistent and the server cert SAN must match the operator Service DNS
(communication-operator.<namespace>.svc[.cluster.local]).

.PARAMETER branch
Optional sub-branch under $rootPath. Empty for the current checkout.

.PARAMETER ClusterName
kind cluster name. Defaults to "kind".

.PARAMETER Namespace
Namespace the operator is installed into. Defaults to "octo-operator-system".

.PARAMETER ReleaseName
Helm release name. Defaults to "octo-operator".

.PARAMETER ImageTag
Operator image tag to deploy. Defaults to "main-latest" — the rolling tag CI
publishes to the dev registry (docker.mm.cloud) on every main build. The image
is pulled from the dev registry (image.privateRegistry in operator-dev-values.yaml).

.PARAMETER ControllerHost
Host/IP of the host-side Communication Controller. When empty, resolved from
Get-HostLanIPv4 so in-cluster pods can reach the host over the LAN.
#>
    param(
        [string]$branch = "",
        [string]$ClusterName = "kind",
        [string]$Namespace = "octo-operator-system",
        [string]$ReleaseName = "octo-operator",
        [string]$ImageTag = "main-latest",
        [string]$ControllerHost = "",
        # Skip the pre-flight that verifies the dev registry resolves from the kind
        # node. Use when the operator image is already on the node (kind load) and you
        # deploy offline, so an unreachable registry must not block the deploy.
        [switch]$SkipRegistryCheck
    )

    $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
    $chart = [System.IO.Path]::Combine($branchRootPath, "octo-helm-core/src/octo-mesh-communication-operator")
    $values = [System.IO.Path]::Combine($kubernetesPath, "operator-dev-values.yaml")

    if (-not (Test-Path $chart)) {
        Write-Error "Operator Helm chart not found at '$chart'."
        return
    }
    if (-not (Test-Path $values)) {
        Write-Error "Operator dev values not found at '$values'."
        return
    }

    # === Pre-flight: fail fast if the operator image can't be pulled. ===
    # The node's kubelet pulls the operator image from the internal dev registry
    # (image.privateRegistry in the values), which resolves only over Tailscale's
    # split-DNS. If the node can't resolve it the pull ImagePullBackOff's and the
    # rollout waits out the full --timeout (180s) before failing — so check now and
    # tell the user exactly what to fix. Skipped when privateRegistry is empty
    # (locally-built images) or via -SkipRegistryCheck (image pre-loaded with kind load).
    if (-not $SkipRegistryCheck) {
        $node = "$ClusterName-control-plane"
        $registry = "docker.mm.cloud"
        $m = Select-String -Path $values -Pattern '^\s*privateRegistry:\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { $registry = $m.Matches[0].Groups[1].Value.Trim('"') }
        if (-not [string]::IsNullOrWhiteSpace($registry)) {
            $nodeRunning = (& docker inspect -f '{{.State.Running}}' $node 2>$null)
            if ($nodeRunning -ne 'true') {
                Write-Error "kind node '$node' is not running. Create the cluster first (Install-OctoKubernetes) before deploying the operator."
                return
            }
            if (-not (Test-OctoNodeResolves -Node $node -Name $registry)) {
                $msg = @(
                    "Dev registry '$registry' does not resolve from the kind node '$node'."
                    "The operator image pull would fail (ImagePullBackOff) and the rollout would time out."
                    "This registry is internal and resolves only over Tailscale. Fix and retry:"
                    "  1. Connect Tailscale:            tailscale up    (verify: tailscale ip -4 shows a 100.x address)"
                    "  2. Confirm the node resolves it: docker exec $node getent hosts $registry"
                    "  3. Re-run the operator deploy."
                    "(If the image is already on the node via 'kind load', pass -SkipRegistryCheck.)"
                ) -join [Environment]::NewLine
                Write-Error $msg
                return
            }
            Write-Host "Pre-flight OK: dev registry '$registry' resolves from the kind node." -ForegroundColor DarkGray
        }
    }

    # === Vendor the chart's sub-chart dependencies (e.g. octo-mesh-crds). ===
    # A fresh octo-helm-core checkout has no charts/ dir or Chart.lock, and helm
    # refuses to render/install until the declared dependencies are present in
    # charts/ — even when they are disabled via condition. Build from the lock
    # first; if there is no lock yet, update to generate it and download deps.
    Write-Host "Vendoring operator chart dependencies" -ForegroundColor Green
    & helm dependency build $chart 2>$null
    if ($LASTEXITCODE -ne 0) {
        # No Chart.lock yet (fresh checkout) — generate it + download deps.
        & helm dependency update $chart
        if ($LASTEXITCODE -ne 0) { Write-Error "helm dependency build/update failed with exit code $LASTEXITCODE."; return }
    }

    if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
        # Prefer the kind node's Docker host-gateway (host.docker.internal) — a
        # stable address that survives host LAN / VPN / Tailscale IP changes, so the
        # operator + adapter pods can always reach the host-process controller. Fall
        # back to the host LAN IP for non-Docker-Desktop engines that don't expose it.
        $ControllerHost = Get-KindHostGatewayIp -ClusterName $ClusterName
        if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
            Write-Host "host.docker.internal not resolvable from the kind node; falling back to the host LAN IP." -ForegroundColor Yellow
            $ControllerHost = Get-HostLanIPv4
        }
        if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
            Write-Error "Could not resolve a host address for the Communication Controller. Pass -ControllerHost explicitly."
            return
        }
        Write-Host "Using host address for the Communication Controller: $ControllerHost" -ForegroundColor Cyan
    }

    # === Generate admission-webhook serving certificates with openssl. ===
    # The chart consumes serviceHooks.{caKey,caCrt,svcKey,svcCrt}; caCrt becomes
    # the webhook caBundle and svcCrt/svcKey are mounted into the operator pod.
    # The server cert SAN must match the in-cluster Service DNS so the apiserver
    # trusts the operator's TLS endpoint when invoking the webhook.
    $certDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "octo-operator-certs-$([System.Guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    # Helm --set-file treats backslashes as escape chars, which mangles Windows temp
    # paths (C:\Users\... -> C:Users...). Use forward slashes — accepted by helm,
    # openssl, and Remove-Item on all platforms; a no-op on macOS/Linux paths.
    $certDir = $certDir -replace '\\', '/'
    try {
        $svcSan1 = "communication-operator.$Namespace.svc"
        $svcSan2 = "communication-operator.$Namespace.svc.cluster.local"

        Write-Host "Generating webhook CA + server certificate (SAN: $svcSan1, $svcSan2)" -ForegroundColor Green

        # 1. CA key + self-signed CA cert.
        & openssl req -x509 -newkey rsa:2048 -nodes `
            -keyout "$certDir/ca-key.pem" `
            -out "$certDir/ca.pem" `
            -days 3650 `
            -subj "/CN=octo-operator-ca"
        if ($LASTEXITCODE -ne 0) { Write-Error "openssl CA generation failed with exit code $LASTEXITCODE."; return }

        # 2. Server key + CSR.
        & openssl req -newkey rsa:2048 -nodes `
            -keyout "$certDir/svc-key.pem" `
            -out "$certDir/svc.csr" `
            -subj "/CN=$svcSan1"
        if ($LASTEXITCODE -ne 0) { Write-Error "openssl server CSR generation failed with exit code $LASTEXITCODE."; return }

        # 3. SAN extension file.
        Set-Content -Path "$certDir/san.cnf" -Value "subjectAltName=DNS:$svcSan1,DNS:$svcSan2" -NoNewline

        # 4. Sign the server cert with the CA, including the SAN extension.
        & openssl x509 -req `
            -in "$certDir/svc.csr" `
            -CA "$certDir/ca.pem" `
            -CAkey "$certDir/ca-key.pem" `
            -CAcreateserial `
            -out "$certDir/svc.pem" `
            -days 3650 `
            -extfile "$certDir/san.cnf"
        if ($LASTEXITCODE -ne 0) { Write-Error "openssl server cert signing failed with exit code $LASTEXITCODE."; return }

        # === Deploy the operator chart. ===
        $kubeContext = "kind-$ClusterName"
        # IPv6 literals must be wrapped in brackets in URIs (https://[::1]:5015);
        # otherwise the trailing ":5015" is parsed as part of the address and
        # System.Uri rejects the whole string with "Invalid port specified".
        # Docker Desktop on macOS resolves host.docker.internal to IPv6 only.
        $uriHost = if ($ControllerHost -match ':' -and $ControllerHost -notmatch '^\[') { "[$ControllerHost]" } else { $ControllerHost }
        $controllerUri = "https://${uriHost}:5015"
        Write-Host "Deploying operator release '$ReleaseName' (image tag '$ImageTag', controller '$controllerUri')" -ForegroundColor Green

        & helm upgrade --install $ReleaseName $chart `
            --kube-context $kubeContext `
            --namespace $Namespace `
            --create-namespace `
            --values $values `
            --set "octo-mesh-crds.enabled=false" `
            --set "image.tag=$ImageTag" `
            --set "operator.communicationControllerUri=$controllerUri" `
            --set-file "serviceHooks.caKey=$certDir/ca-key.pem" `
            --set-file "serviceHooks.caCrt=$certDir/ca.pem" `
            --set-file "serviceHooks.svcKey=$certDir/svc-key.pem" `
            --set-file "serviceHooks.svcCrt=$certDir/svc.pem"
        if ($LASTEXITCODE -ne 0) { Write-Error "helm upgrade --install failed with exit code $LASTEXITCODE."; return }

        # The operator reads its controller URI + config from a ConfigMap, and the
        # chart has no config-checksum annotation — so a helm upgrade that only
        # changes config (e.g. a new controller host) won't roll the pod on its own.
        # Force a restart so config changes always take effect.
        & kubectl --context $kubeContext -n $Namespace rollout restart deploy/communication-operator | Out-Null
        Write-Host "Waiting for the operator deployment to roll out..." -ForegroundColor Green
        & kubectl --context $kubeContext -n $Namespace rollout status deploy/communication-operator --timeout=180s
        if ($LASTEXITCODE -ne 0) { Write-Error "Operator rollout did not complete (exit code $LASTEXITCODE)."; return }

        Write-Host "Operator deployed and rolled out successfully." -ForegroundColor Cyan
    }
    finally {
        Remove-Item -Path $certDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @('Deploy-OctoOperator', 'Get-HostLanIPv4', 'Get-KindHostGatewayIp')
