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
from the dev registry (registry.url in the octo-tools config, overridable via
image.privateRegistry in operator-dev-values.yaml). If that
registry resolves only over a VPN/split-DNS and the node can't resolve it the pull
ImagePullBackOff's and the rollout sits for the full timeout before erroring — so we
check first and fail fast with an actionable message. `getent hosts` exits 0 only when
the name resolves.
#>
    param(
        [Parameter(Mandatory)] [string]$Node,
        [Parameter(Mandatory)] [string]$Name
    )
    $out = (& docker exec $Node getent hosts $Name 2>$null | Out-String)
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($out))
}

function Test-OctoNodeHasImage {
    <#
.SYNOPSIS
True when the kind node already holds an image under exactly this reference.

.DESCRIPTION
Kubelet matches a pre-loaded image by its full reference, registry prefix
included. `docker.mm.cloud/meshmakers/x:tag` and `meshmakers/x:tag` are two
different references to it even when they name the same layers, so guessing
wrong yields ErrImageNeverPull rather than a fallback. Ask the node instead of
assuming.
#>
    param(
        [Parameter(Mandatory)] [string]$Node,
        [Parameter(Mandatory)] [string]$Reference
    )
    $listed = & docker exec $Node crictl images 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $listed) { return $false }
    $repo, $tag = $Reference -split ':', 2
    return [bool]($listed | Where-Object { $_ -match "^\s*$([regex]::Escape($repo))\s+$([regex]::Escape($tag))\s" })
}

function Get-OctoControllerTlsProfile {
    <#
.SYNOPSIS
Works out how an in-cluster pod can reach a host-run Communication Controller
over HTTPS: which hostname to use, whether an /etc/hosts alias is needed, and
which certificate has to be trusted.

.DESCRIPTION
The operator validates the controller's TLS certificate like any other client —
there is no bypass for its own SignalR hub connection (the chart's
`adapterIgnoreCertificateValidation` only reaches adapter pods). Locally that
breaks twice over:

  * the controller presents a self-signed ASP.NET development certificate, which
    nothing in the cluster trusts, and
  * the only address a pod can actually reach the host on (the Docker host
    gateway, e.g. host.docker.internal / 192.168.65.254) is normally NOT one of
    that certificate's subject alternative names, so even a trusted certificate
    fails hostname validation.

This reads the certificate straight off the running controller — that is by
definition the one it will present — and picks a SAN hostname to connect by. If
that hostname does not already resolve to the reachable address, the caller maps
it with a pod hostAlias. The certificate itself is self-signed, so it is its own
trust anchor and can be handed to the chart as `secrets.rootCa`.

Returns $null when the controller cannot be reached or presents no usable name;
the caller then falls back to connecting by address.

.PARAMETER Address
Address the CLUSTER can reach the host on (IP or hostname) — the alias target.

.PARAMETER ProbeAddress
Address THIS machine reads the certificate on. Defaults to 127.0.0.1, and that
default matters: the cluster-facing address is typically the Docker host gateway
(192.168.65.254), which pods can reach but the host itself cannot — probing it
would fail and silently skip the trust wiring. Same listener either way, so the
certificate is identical.

.PARAMETER Port
Controller HTTPS port. Defaults to 5015.

.PARAMETER OutFile
Path the certificate PEM is written to, for `helm --set-file`.
#>
    param(
        [Parameter(Mandatory)] [string]$Address,
        [Parameter()] [string]$ProbeAddress = "127.0.0.1",
        [Parameter()] [int]$Port = 5015,
        [Parameter(Mandatory)] [string]$OutFile
    )

    # -servername is deliberately omitted: we want whatever the controller serves
    # by default, which is what the operator will be handed too.
    $handshake = "" | & openssl s_client -connect "${ProbeAddress}:${Port}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($handshake)) { return $null }

    $pem = $handshake | & openssl x509 -outform PEM 2>$null
    if ([string]::IsNullOrWhiteSpace($pem)) { return $null }
    Set-Content -Path $OutFile -Value $pem -Encoding ascii

    return Resolve-OctoTlsProfileFromPem -CertPath $OutFile -Address $Address
}

function Resolve-OctoTlsProfileFromPem {
    <#
.SYNOPSIS
Picks the hostname an in-cluster pod should connect to a host-run service by,
from a certificate PEM already on disk.

.DESCRIPTION
Shared SAN-selection logic behind Get-OctoControllerTlsProfile (certificate read
off the live listener) and Get-OctoAspNetDevCertProfile (certificate exported
from the dev-cert store). If the reachable address is one of the certificate's
IP SANs, pods connect by address and need no alias; otherwise the first concrete
non-localhost DNS SAN is chosen and the caller maps it to the address (pod
hostAlias + cluster DNS). Returns $null when the certificate names nothing a pod
could use.

.PARAMETER CertPath
Path to the certificate PEM. Doubles as the returned CertPath (trust anchor).

.PARAMETER Address
Address the CLUSTER can reach the host on (IP or hostname) — the alias target.
#>
    param(
        [Parameter(Mandatory)] [string]$CertPath,
        [Parameter(Mandatory)] [string]$Address
    )

    $text = & openssl x509 -in $CertPath -noout -text 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $text) { return $null }
    $sanMatch = $text | Select-String -Pattern 'DNS:|IP Address:' | Select-Object -First 1
    if (-not $sanMatch) { return $null }
    $sanLine = $sanMatch.ToString()
    $dnsNames = [regex]::Matches($sanLine, 'DNS:([^,\s]+)') | ForEach-Object { $_.Groups[1].Value }
    $ipNames  = [regex]::Matches($sanLine, 'IP Address:([^,\s]+)') | ForEach-Object { $_.Groups[1].Value }

    # Already covered by an IP SAN? Then connect by address and skip the alias.
    if ($ipNames -contains $Address) {
        return [pscustomobject]@{ Hostname = $Address; NeedsAlias = $false; CertPath = $CertPath }
    }

    # Prefer a concrete name; a wildcard SAN (*.foo) is usable too, but only with a
    # label substituted in — "*.foo" is not a hostname a client may connect to.
    $name = $dnsNames | Where-Object { $_ -notmatch '^\*' -and $_ -ne 'localhost' } | Select-Object -First 1
    if (-not $name) {
        $wildcard = $dnsNames | Where-Object { $_ -match '^\*\.' } | Select-Object -First 1
        if ($wildcard) { $name = $wildcard -replace '^\*', 'octo-controller' }
    }
    # 'localhost' is a SAN on every dev certificate but resolves to the pod itself,
    # so it is only usable as a last resort with an alias overriding it — which
    # would also break the pod's own loopback. Refuse instead.
    if (-not $name) { return $null }

    return [pscustomobject]@{ Hostname = $name; NeedsAlias = $true; CertPath = $CertPath }
}

function Get-OctoAspNetDevCertProfile {
    <#
.SYNOPSIS
Builds the controller TLS profile from the ASP.NET dev certificate in the local
dev-cert store, for when the controller is not running to be probed.

.DESCRIPTION
Install-OctoKubernetes deploys the operator while the host services are, by
definition, not running yet — so Get-OctoControllerTlsProfile has no listener to
read a certificate from, and the deploy used to fall back to connecting by the
raw host-gateway IP with no trust wiring (AB#5232: every workload then got
authUri/controllerUri = https://<gateway-ip>:5003/5015, an address the dev
certificate does not name and nothing in the cluster trusts). Start-Octo
services serve exactly the certificate `dotnet dev-certs https` manages, so
exporting it from the store is equivalent to reading it off the listener.
`--format PEM` without a password flag exports ONLY the public certificate — no
private-key sidecar is written (a stray `.key` is removed defensively anyway).
Returns $null when the .NET SDK is unavailable or the export fails; the caller
then keeps the legacy address-based fallback.

.PARAMETER Address
Address the CLUSTER can reach the host on — the alias target.

.PARAMETER OutFile
Path the certificate PEM is written to, for `helm --set-file`.
#>
    param(
        [Parameter(Mandatory)] [string]$Address,
        [Parameter(Mandatory)] [string]$OutFile
    )

    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { return $null }
    & dotnet dev-certs https --export-path $OutFile --format PEM 2>$null | Out-Null
    Remove-Item ([System.IO.Path]::ChangeExtension($OutFile, '.key')) -Force -ErrorAction SilentlyContinue
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $OutFile)) { return $null }

    return Resolve-OctoTlsProfileFromPem -CertPath $OutFile -Address $Address
}

function Set-OctoControllerDnsAlias {
    <#
.SYNOPSIS
Makes a hostname resolve cluster-wide to a given address by adding a `hosts`
block to CoreDNS. Idempotent.

.DESCRIPTION
A pod hostAlias fixes name resolution for ONE pod. That is not enough here: the
operator publishes its own `CommunicationControllerUri` into the Helm values of
every workload it deploys (`WorkloadContextValuesBuilder`), so the name the
operator connects by is also the name every adapter connects by — and adapters
get no hostAlias. Left to normal DNS, `mac.local` resolves through the host's
mDNS to whatever interface answers first (a Parallels/VPN address, in practice),
which pods cannot reach; the adapters then sit at Unregistered forever while the
operator itself is happily connected.

Putting the mapping in CoreDNS instead fixes the name for the whole cluster at
once, which is what the shared setting actually needs. `fallthrough` keeps every
other name on the normal resolution path.

.PARAMETER Hostname
Name to map — the hostname taken from the controller certificate.

.PARAMETER Address
Address it should resolve to, reachable from inside the cluster.

.PARAMETER KubeContext
kubectl context of the cluster to patch.
#>
    param(
        [Parameter(Mandatory)] [string]$Hostname,
        [Parameter(Mandatory)] [string]$Address,
        [Parameter(Mandatory)] [string]$KubeContext,
        [switch]$Quiet
    )

    # Join explicitly: PowerShell hands back multi-line native output as a string
    # ARRAY, and every regex/Insert below silently misbehaves on one of those.
    $corefile = (& kubectl --context $KubeContext -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>$null) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($corefile)) {
        if (-not $Quiet) { Write-Host "Could not read the CoreDNS config; skipping the cluster-wide DNS alias. Workloads may not resolve '$Hostname'." -ForegroundColor Yellow }
        return $false
    }

    $marker = "# octo-tools: controller alias"
    $block = @"
    $marker
    hosts {
       $Address $Hostname
       fallthrough
    }
"@

    # Replace our own previous block if present, else insert before the kubernetes
    # plugin. Matching on the marker keeps us from touching a hosts block someone
    # else added.
    $pattern = [regex]::Escape($marker) + '\s*\r?\n\s*hosts\s*\{[^}]*\}'
    if ([regex]::IsMatch($corefile, $pattern)) {
        $updated = [regex]::Replace($corefile, $pattern, $block.TrimStart())
    } else {
        $anchor = [regex]::Match($corefile, '(?m)^\s*kubernetes\s')
        if (-not $anchor.Success) {
            if (-not $Quiet) { Write-Host "Unexpected CoreDNS config (no kubernetes plugin); skipping the DNS alias." -ForegroundColor Yellow }
            return $false
        }
        $updated = $corefile.Insert($anchor.Index, $block + [Environment]::NewLine)
    }

    if ($updated -eq $corefile) {
        if (-not $Quiet) { Write-Host "Cluster DNS already maps '$Hostname' to $Address." -ForegroundColor DarkGray }
        return $true
    }

    $patchFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "coredns-patch-$([System.Guid]::NewGuid().ToString('N')).json")
    try {
        (@{ data = @{ Corefile = $updated } } | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $patchFile -Encoding utf8
        & kubectl --context $KubeContext -n kube-system patch configmap coredns --type merge --patch-file $patchFile | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if (-not $Quiet) { Write-Host "Patching CoreDNS failed; workloads may not resolve '$Hostname'." -ForegroundColor Yellow }
            return $false
        }
        # CoreDNS reloads the Corefile on its own within ~30s; restarting makes the
        # change effective now so the deploy that follows does not race it. Both
        # calls are best effort — the config is already patched, and a slow rollout
        # only means the alias takes the reload interval to appear, so a timeout
        # here must not read as a failure.
        & kubectl --context $KubeContext -n kube-system rollout restart deploy/coredns 2>&1 | Out-Null
        & kubectl --context $KubeContext -n kube-system rollout status deploy/coredns --timeout=120s 2>&1 | Out-Null
        if (-not $Quiet) { Write-Host "Cluster DNS: '$Hostname' now resolves to $Address for every pod." -ForegroundColor Cyan }
        return $true
    }
    finally {
        Remove-Item -Path $patchFile -Force -ErrorAction SilentlyContinue
    }
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
publishes to the dev registry on every main build. The image is pulled from the
dev registry resolved from `registry.url` in the octo-tools config
(~/.config/octo-tools/installations.json); a non-empty `image.privateRegistry`
in operator-dev-values.yaml overrides it.

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
        # deploy offline, so an unreachable registry must not block the deploy. Also
        # skips the config-registry injection so the image reference stays
        # registry-less and matches the pre-loaded image.
        [switch]$SkipRegistryCheck,
        # Skip reading the controller's TLS certificate and trusting it in the
        # operator pod. Use when the controller serves a certificate the pod
        # already trusts (a real cluster) — locally it is required, because the
        # operator validates that certificate and has no bypass for its own hub
        # connection.
        [switch]$SkipControllerTlsTrust,
        [switch]$Json
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

    # === Resolve the dev registry. ===
    # The registry host is environment-specific config (registry.url in
    # ~/.config/octo-tools/installations.json), not a repo value — the tracked
    # operator-dev-values.yaml deliberately ships without one. A non-empty
    # privateRegistry in the values file still wins so a deliberate local
    # override keeps working; the retired your-dev-registry.example.com
    # placeholder is ignored so stale checkouts don't deploy a dead host.
    # When resolved non-empty the value is injected into the helm deploy
    # (image.privateRegistry + operator.imageRegistry) below; empty means the
    # images come from Docker Hub and the resolve pre-flight is skipped.
    $registry = $(try { (Get-OctoToolsConfig).registry.url } catch { "" })
    $registryFromValues = $false
    $m = Select-String -Path $values -Pattern '^\s*privateRegistry:\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($m) {
        $valuesRegistry = $m.Matches[0].Groups[1].Value.Trim('"').Trim("'")
        if (-not [string]::IsNullOrWhiteSpace($valuesRegistry) -and $valuesRegistry -ne 'your-dev-registry.example.com') {
            $registry = $valuesRegistry
            $registryFromValues = $true
        }
    }

    # === Pre-flight: fail fast if the operator image can't be pulled. ===
    # The node's kubelet pulls the operator image from the dev registry. If the
    # registry resolves only over VPN/split-DNS and the node can't resolve it the
    # pull ImagePullBackOff's and the rollout waits out the full --timeout (180s)
    # before failing — so check now and tell the user exactly what to fix. Skipped
    # when the resolved registry is empty (locally-built / Docker Hub images) or
    # via -SkipRegistryCheck (image pre-loaded with kind load).
    if (-not $SkipRegistryCheck) {
        $node = "$ClusterName-control-plane"
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
            if (-not $Json) { Write-Host "Pre-flight OK: dev registry '$registry' resolves from the kind node." -ForegroundColor DarkGray }
        }
    }

    # === Vendor the chart's sub-chart dependencies (e.g. octo-mesh-crds). ===
    # A fresh octo-helm-core checkout has no charts/ dir or Chart.lock, and helm
    # refuses to render/install until the declared dependencies are present in
    # charts/ — even when they are disabled via condition. Build from the lock
    # first; if there is no lock yet, update to generate it and download deps.
    if (-not $Json) { Write-Host "Vendoring operator chart dependencies" -ForegroundColor Green }
    & helm dependency build $chart 2>$null
    if ($LASTEXITCODE -ne 0) {
        # No Chart.lock yet (fresh checkout) — generate it + download deps.
        $depOut = & helm dependency update $chart 2>&1
        if (-not $Json) { $depOut | ForEach-Object { Write-Host $_ } }
        if ($LASTEXITCODE -ne 0) {
            if ($Json) { Write-OctoJson -Command 'Deploy-OctoOperator' -Data (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = "helm dependency build/update failed" }); return }
            Write-Error "helm dependency build/update failed with exit code $LASTEXITCODE."; return
        }
    }

    if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
        # Prefer the kind node's Docker host-gateway (host.docker.internal) — a
        # stable address that survives host LAN / VPN / Tailscale IP changes, so the
        # operator + adapter pods can always reach the host-process controller. Fall
        # back to the host LAN IP for non-Docker-Desktop engines that don't expose it.
        $ControllerHost = Get-KindHostGatewayIp -ClusterName $ClusterName
        if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
            if (-not $Json) { Write-Host "host.docker.internal not resolvable from the kind node; falling back to the host LAN IP." -ForegroundColor Yellow }
            $ControllerHost = Get-HostLanIPv4
        }
        if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
            Write-Error "Could not resolve a host address for the Communication Controller. Pass -ControllerHost explicitly."
            return
        }
        if (-not $Json) { Write-Host "Using host address for the Communication Controller: $ControllerHost" -ForegroundColor Cyan }
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

        if (-not $Json) { Write-Host "Generating webhook CA + server certificate (SAN: $svcSan1, $svcSan2)" -ForegroundColor Green }

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
        # Identity runs beside the controller as a host process. The operator projects this
        # into every workload it deploys; an adapter without it disables JWT authentication
        # and refuses every caller of a secured FromHttpRequest@2 route.
        $authUri = "https://${uriHost}:5003"

        # === Make the controller's TLS reachable from inside the cluster. ===
        # Two problems at once locally: the certificate is self-signed (nothing in
        # the pod trusts it) and the address the pod can reach is not one of its
        # SANs. Get-OctoControllerTlsProfile solves both — it hands back the
        # certificate to trust and a hostname the certificate actually names, which
        # we then point at the reachable address with a pod hostAlias.
        $tlsArgs = @()
        if (-not $SkipControllerTlsTrust) {
            $tlsSource = "certificate read off the running controller"
            $tls = Get-OctoControllerTlsProfile -Address $ControllerHost -Port 5015 -OutFile "$certDir/controller-ca.pem"
            if (-not $tls) {
                # The controller is not up — the normal case during Install-OctoKubernetes,
                # which creates the cluster before Start-Octo runs. Fall back to the ASP.NET
                # dev certificate from the local dev-cert store: Start-Octo services serve
                # exactly that certificate, so trusting it is equivalent to reading it off
                # the listener. Without this fallback the deploy pinned the raw gateway IP
                # into authUri/controllerUri of EVERY workload (AB#5232: adapters failed
                # TLS + issuer validation on secured FromHttpRequest routes).
                $tls = Get-OctoAspNetDevCertProfile -Address $ControllerHost -OutFile "$certDir/controller-ca.pem"
                $tlsSource = "ASP.NET dev certificate from the local store (controller not running)"
            }
            if ($tls) {
                $tlsArgs += @("--set-file", "secrets.rootCa=$($tls.CertPath)")
                if ($tls.NeedsAlias) {
                    # Connect by the certificate's own name; the alias makes that name
                    # resolve to the address the pod can actually reach.
                    $controllerUri = "https://$($tls.Hostname):5015"
                    $authUri = "https://$($tls.Hostname):5003"
                    $tlsArgs += @(
                        "--set", "hostAliases[0].ip=$ControllerHost",
                        "--set", "hostAliases[0].hostnames[0]=$($tls.Hostname)"
                    )
                    if (-not $Json) { Write-Host "Controller TLS: trusting the $tlsSource and reaching the host as '$($tls.Hostname)' -> $ControllerHost (certificate does not name the address)" -ForegroundColor Cyan }
                    # The pod alias alone is not enough. This URI is also projected into
                    # every workload the operator deploys, and adapter pods get no alias
                    # — so the name has to resolve for the whole cluster or the adapters
                    # sit at Unregistered while the operator itself is connected.
                    Set-OctoControllerDnsAlias -Hostname $tls.Hostname -Address $ControllerHost -KubeContext $kubeContext -Quiet:$Json | Out-Null
                } else {
                    if (-not $Json) { Write-Host "Controller TLS: trusting the $tlsSource; the address is covered by a SAN" -ForegroundColor Cyan }
                }
            } elseif (-not $Json) {
                # Not fatal: no listener AND no dev certificate (e.g. .NET SDK absent), or
                # a controller behind a publicly trusted certificate. Say so rather than
                # failing — but the operator will not connect if the certificate is
                # untrusted, and workloads inherit the raw-address URIs.
                Write-Host "Could not obtain a controller TLS certificate (listener at ${ControllerHost}:5015 unreachable and no ASP.NET dev certificate) — deploying without trust wiring. If the operator cannot connect, start the controller ('Start-Octo') and re-run Deploy-OctoOperator." -ForegroundColor Yellow
            }
        }
        # The operator runs the rolling :main-latest tag, so the image content changes
        # under a fixed tag. Force a fresh pull on every deploy (Always) for the normal
        # registry path; for an offline/pre-loaded deploy (-SkipRegistryCheck, image
        # already on the node via 'kind load') keep IfNotPresent so kubelet uses the
        # cached image instead of trying to pull. Overrides image.pullPolicy in the values.
        $pullPolicy = if ($SkipRegistryCheck) { "IfNotPresent" } else { "Always" }
        # Inject the resolved config registry into the deploy unless the values
        # file pins its own — then the file rules (it may deliberately differ,
        # e.g. a local registry mirror). operator.imageRegistry gets the same
        # host so deployed adapter/app workloads pull from the same place.
        $registryArgs = @()
        if (-not $registryFromValues -and -not [string]::IsNullOrWhiteSpace($registry)) {
            # For a normal (pulling) deploy the registry always applies. For an
            # offline deploy the reference has to match what is actually on the node
            # byte for byte, and both shapes occur in practice: an image pulled from
            # the dev registry and loaded keeps its `docker.mm.cloud/...` prefix,
            # while a locally built one has none. Ask the node rather than guessing
            # — a wrong guess is ErrImageNeverPull, not a fallback.
            $injectRegistry = $true
            if ($SkipRegistryCheck) {
                $repository = "meshmakers/octo-communication-operator"
                $m2 = Select-String -Path $values -Pattern '^\s*repository:\s*(\S+)' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($m2) { $repository = $m2.Matches[0].Groups[1].Value.Trim('"').Trim("'") }
                $node = "$ClusterName-control-plane"
                if (Test-OctoNodeHasImage -Node $node -Reference "$registry/${repository}:$ImageTag") {
                    if (-not $Json) { Write-Host "Offline deploy: node holds '$registry/${repository}:$ImageTag' — keeping the registry prefix." -ForegroundColor DarkGray }
                } elseif (Test-OctoNodeHasImage -Node $node -Reference "${repository}:$ImageTag") {
                    $injectRegistry = $false
                    if (-not $Json) { Write-Host "Offline deploy: node holds '${repository}:$ImageTag' without a registry prefix — omitting it." -ForegroundColor DarkGray }
                } else {
                    if (-not $Json) { Write-Host "Offline deploy: neither '$registry/${repository}:$ImageTag' nor '${repository}:$ImageTag' is on node '$node'. Load it first (Import-OctoImageToKind); deploying with the registry prefix." -ForegroundColor Yellow }
                }
            }
            if ($injectRegistry) {
                $registryArgs = @(
                    "--set", "image.privateRegistry=$registry",
                    "--set", "operator.imageRegistry=$registry"
                )
            }
        }
        if (-not $Json) { Write-Host "Deploying operator release '$ReleaseName' (image tag '$ImageTag', registry '$registry', pullPolicy '$pullPolicy', controller '$controllerUri', identity '$authUri')" -ForegroundColor Green }

        $helmOut = & helm upgrade --install $ReleaseName $chart `
            --kube-context $kubeContext `
            --namespace $Namespace `
            --create-namespace `
            --values $values `
            @registryArgs `
            @tlsArgs `
            --set "octo-mesh-crds.enabled=false" `
            --set "image.tag=$ImageTag" `
            --set "image.pullPolicy=$pullPolicy" `
            --set "operator.communicationControllerUri=$controllerUri" `
            --set "operator.authUri=$authUri" `
            --set-file "serviceHooks.caKey=$certDir/ca-key.pem" `
            --set-file "serviceHooks.caCrt=$certDir/ca.pem" `
            --set-file "serviceHooks.svcKey=$certDir/svc-key.pem" `
            --set-file "serviceHooks.svcCrt=$certDir/svc.pem" 2>&1
        if (-not $Json) { $helmOut | ForEach-Object { Write-Host $_ } }
        if ($LASTEXITCODE -ne 0) {
            if ($Json) { Write-OctoJson -Command 'Deploy-OctoOperator' -Data (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = "helm upgrade --install failed" }); return }
            Write-Error "helm upgrade --install failed with exit code $LASTEXITCODE."; return
        }

        # The operator reads its controller URI + config from a ConfigMap, and the
        # chart has no config-checksum annotation — so a helm upgrade that only
        # changes config (e.g. a new controller host) won't roll the pod on its own.
        # Force a restart so config changes always take effect.
        & kubectl --context $kubeContext -n $Namespace rollout restart deploy/communication-operator | Out-Null
        if (-not $Json) { Write-Host "Waiting for the operator deployment to roll out..." -ForegroundColor Green }
        if ($Json) {
            & kubectl --context $kubeContext -n $Namespace rollout status deploy/communication-operator --timeout=180s | Out-Null
        } else {
            & kubectl --context $kubeContext -n $Namespace rollout status deploy/communication-operator --timeout=180s
        }
        if ($LASTEXITCODE -ne 0) {
            if ($Json) { Write-OctoJson -Command 'Deploy-OctoOperator' -Data (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = "operator rollout did not complete" }); return }
            Write-Error "Operator rollout did not complete (exit code $LASTEXITCODE)."; return
        }

        if ($Json) {
            Write-OctoJson -Command 'Deploy-OctoOperator' -Data (New-OctoActionResult -Success $true)
            return
        }
        Write-Host "Operator deployed and rolled out successfully." -ForegroundColor Cyan
    }
    finally {
        Remove-Item -Path $certDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @('Deploy-OctoOperator', 'Get-HostLanIPv4', 'Get-KindHostGatewayIp', 'Get-OctoControllerTlsProfile', 'Get-OctoAspNetDevCertProfile', 'Resolve-OctoTlsProfileFromPem', 'Test-OctoNodeHasImage', 'Set-OctoControllerDnsAlias')
