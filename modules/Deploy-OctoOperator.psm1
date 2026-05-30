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
Operator image tag to deploy. Defaults to the newest published tag
"3.3.108.0" (there is no "latest" tag). Overridden to "dev" when -BuildLocal.

.PARAMETER ControllerHost
Host/IP of the host-side Communication Controller. When empty, resolved from
Get-HostLanIPv4 so in-cluster pods can reach the host over the LAN.

.PARAMETER BuildLocal
Build the operator image locally from source and import it into kind instead
of pulling the published image. Sets the image tag to "dev".
#>
    param(
        [string]$branch = "",
        [string]$ClusterName = "kind",
        [string]$Namespace = "octo-operator-system",
        [string]$ReleaseName = "octo-operator",
        [string]$ImageTag = "3.3.108.0",
        [string]$ControllerHost = "",
        [switch]$BuildLocal
    )

    $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
    $chart = [System.IO.Path]::Combine($branchRootPath, "octo-helm-core/src/octo-mesh-communication-operator")
    $values = [System.IO.Path]::Combine($branchRootPath, "octo-tools/kubernetes/operator-dev-values.yaml")

    if (-not (Test-Path $chart)) {
        Write-Error "Operator Helm chart not found at '$chart'."
        return
    }
    if (-not (Test-Path $values)) {
        Write-Error "Operator dev values not found at '$values'."
        return
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
        $ControllerHost = Get-HostLanIPv4
        if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
            Write-Error "Could not resolve a non-loopback IPv4 address for this host. Pass -ControllerHost explicitly."
            return
        }
        Write-Host "Resolved host LAN IPv4 for the Communication Controller: $ControllerHost" -ForegroundColor Cyan
    }

    # === Optional: build the operator image locally and load it into kind. ===
    if ($BuildLocal) {
        $dockerfile = [System.IO.Path]::Combine($branchRootPath, "octo-communication-operator/src/CommunicationOperator/Dockerfile")
        if (-not (Test-Path $dockerfile)) {
            Write-Error "Local build requested but Dockerfile not found at '$dockerfile'."
            return
        }
        $localImage = "meshmakers/octo-communication-operator:dev"
        $buildContext = [System.IO.Path]::Combine($branchRootPath, "octo-communication-operator")
        Write-Host "Building operator image '$localImage' from '$dockerfile'" -ForegroundColor Green
        & docker build -t $localImage -f $dockerfile $buildContext
        if ($LASTEXITCODE -ne 0) { Write-Error "docker build failed with exit code $LASTEXITCODE."; return }
        Import-OctoImageToKind -Image $localImage -ClusterName $ClusterName
        $ImageTag = "dev"
    }

    # === Generate admission-webhook serving certificates with openssl. ===
    # The chart consumes serviceHooks.{caKey,caCrt,svcKey,svcCrt}; caCrt becomes
    # the webhook caBundle and svcCrt/svcKey are mounted into the operator pod.
    # The server cert SAN must match the in-cluster Service DNS so the apiserver
    # trusts the operator's TLS endpoint when invoking the webhook.
    $certDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "octo-operator-certs-$([System.Guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Path $certDir -Force | Out-Null
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
        $controllerUri = "https://${ControllerHost}:5015"
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

        Write-Host "Waiting for the operator deployment to roll out..." -ForegroundColor Green
        & kubectl --context $kubeContext -n $Namespace rollout status deploy/communication-operator --timeout=180s
        if ($LASTEXITCODE -ne 0) { Write-Error "Operator rollout did not complete (exit code $LASTEXITCODE)."; return }

        Write-Host "Operator deployed and rolled out successfully." -ForegroundColor Cyan
    }
    finally {
        Remove-Item -Path $certDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @('Deploy-OctoOperator', 'Get-HostLanIPv4')
