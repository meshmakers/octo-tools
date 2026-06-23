# Install-OctoKubernetes — local kind dev cluster (CRDs, in-cluster infra, ingress-nginx +
# cert-manager). Extracted from Install-OctoInfrastructure.psm1; the docker-compose infra
# (Install-OctoInfrastructure) stays there. Test-DockerComposeInfraRunning moved here because
# it is only used to refuse the kind bring-up while the compose stack is up.

function Test-DockerComposeInfraRunning {
    # Returns $true if any of the docker-compose infra containers are running,
    # which would collide on host ports 27017/5672/5432 with the kind infra.
    $names = @("mongo-0.mongo", "rabbitmq", "cratedb01")
    $running = docker ps --format '{{.Names}}' 2>$null
    foreach ($n in $names) {
        if ($running -contains $n) { return $true }
    }
    return $false
}

function Install-OctoKubernetes {
    <#
.SYNOPSIS
Sets up the local Kubernetes prerequisites for OctoMesh: a kind cluster, the
octo-mesh-crds Helm chart, and the default 'octo' pool namespace.

.DESCRIPTION
The Install-OctoKubernetes function ensures that the local Kubernetes
environment expected by the Communication Operator (and the E2E smoke test) is
in place. Each step is idempotent: a missing kind cluster is created, an
existing one is left alone; the CRDs chart is installed via 'helm upgrade
--install'; the 'octo' namespace is created only if absent.

This function does NOT switch the current kubectl context if it already points
elsewhere — it only ensures the target cluster exists and prints the context
in use at the end. Run it once per workstation; re-running is safe.

.PARAMETER branch
Branch sub-folder under `$rootPath` containing the repository checkouts.
Matches the convention of Start-Octo / Invoke-BuildAll. Defaults to "" (the
plain `$rootPath`).

.PARAMETER ClusterName
Name of the kind cluster to create or use. Defaults to "kind".

.PARAMETER CrdReleaseName
Helm release name for the CRDs chart. Defaults to "octo-mesh-crds".

.PARAMETER CrdNamespace
Namespace into which the CRDs Helm release is installed. Defaults to
"octo-operator-system".

.PARAMETER ExposeLan
Bind the infra + ingress host ports on 0.0.0.0 instead of the default 127.0.0.1
(loopback), so other machines on the LAN can reach them. Exposes MongoDB / CrateDB /
RabbitMQ (dev creds, CrateDB auth-less) to the network — only use on a trusted network.
Takes effect only when the cluster is created (recreate to change).

.EXAMPLE
Install-OctoKubernetes

.EXAMPLE
Install-OctoKubernetes -branch dev/feature-x

.NOTES
Requires kind, helm, and kubectl on PATH. The CRDs chart is read from
"$rootPath/<branch>/octo-helm-core/src/octo-mesh-crds".
#>

    param(
        [Parameter()] [string]$branch = "",
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [string]$CrdReleaseName = "octo-mesh-crds",
        [Parameter()] [string]$CrdNamespace = "octo-operator-system",
        [Parameter()] [switch]$SkipInfra,
        # Skip installing ingress-nginx + cert-manager + the mm-cloud-issuer CA ClusterIssuer.
        # By default they are installed so the local cluster exposes web workloads like staging.
        [Parameter()] [switch]$SkipIngress,
        # By default the infra + ingress host ports bind to 127.0.0.1 (loopback only). Pass
        # -ExposeLan to bind them on 0.0.0.0 so other machines on the LAN can reach them —
        # this exposes Mongo/CrateDB/RabbitMQ (dev creds) to the network, so only use it on a
        # trusted network. Only takes effect when the cluster is created (recreate to change).
        [Parameter()] [switch]$ExposeLan,
        # By default the exported local root CA is added to the OS trust store (Add-OctoLocalCaTrust)
        # so browsers/tools accept the mm-cloud-issuer certs without warnings. This prompts for
        # sudo on macOS/Linux. Pass -SkipTrustCa for unattended/CI runs.
        [Parameter()] [switch]$SkipTrustCa,
        # The Communication Operator is deployed by default, pulled from the dev registry
        # (docker.mm.cloud) at the rolling :main-latest tag — same place adapter/app images
        # come from. Pass -SkipOperator to skip it.
        [Parameter()] [switch]$SkipOperator,
        # Skip the upfront check that the dev registry is reachable, and the matching
        # node-level check in Deploy-OctoOperator. Use when images are pre-loaded
        # (kind load) so an unreachable registry must not block the install.
        [Parameter()] [switch]$SkipRegistryCheck,
        # Internal dev container registry the node should be able to pull adapter images
        # from. Its TLS cert is signed by an internal CA the kind node doesn't trust, so we
        # configure containerd to skip verification for it. Pass "" to skip this.
        [Parameter()] [string]$DevRegistry = "docker.mm.cloud",
        [Parameter()] [switch]$Json
    )

    # Namespaces are fixed by the static manifests (namespaces.yaml, the infra YAML which is
    # applied without -n, and operator-dev-values.yaml). They are locals, not parameters,
    # because overriding only some of those would split the install across namespaces and
    # break it — changing a namespace means editing those manifests too.
    $InfraNamespace = "octo-infra"
    $PoolNamespace = "octo"

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
    if (!(Test-Path $branchRootPath)) {
        Write-Error "Branch root path $branchRootPath does not exist"
        return
    }

    foreach ($tool in @("kind", "helm", "kubectl", "docker")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Error "$tool is not on PATH. Install it before running Install-OctoKubernetes."
            return
        }
    }

    if (-not $SkipInfra -and (Test-DockerComposeInfraRunning)) {
        Write-Error "docker-compose infrastructure is running and will collide on host ports 27017/5672/5432. Run 'Stop-OctoInfrastructure' first, or pass '-SkipInfra -SkipOperator' to install only the cluster/CRDs/ingress (the operator needs the in-cluster infra, so -SkipInfra alone leaves it pointed at nothing)."
        return
    }

    $crdChartPath = Join-Path $branchRootPath "octo-helm-core/src/octo-mesh-crds"
    if (!(Test-Path $crdChartPath)) {
        Write-Error "CRDs chart not found at $crdChartPath. Make sure octo-helm-core is checked out next to the other repositories."
        return
    }

    # === Prerequisite: fail fast BEFORE building anything if the dev registry isn't
    # reachable. The operator (and later every adapter/app) image is pulled from it, so
    # otherwise we stand up the whole cluster and only hit ImagePullBackOff at the
    # operator step. A TCP probe works the same whether the registry is reached over the
    # office network or remotely (Tailscale) — we don't care how the name resolves, only
    # that it does. Re-checked from the kind node in Deploy-OctoOperator once it exists. ===
    if (-not $SkipRegistryCheck -and -not $SkipOperator -and -not [string]::IsNullOrWhiteSpace($DevRegistry)) {
        Write-Host "Checking dev registry '$DevRegistry' is reachable..." -ForegroundColor Green
        if (-not (Test-Connection -TargetName $DevRegistry -TcpPort 443 -Quiet -TimeoutSeconds 5)) {
            Write-Error (@(
                "Dev registry '$DevRegistry' is not reachable on port 443, so cluster images can't be pulled."
                "Aborting before building the cluster (the operator step would otherwise fail with ImagePullBackOff)."
                "If you're off the office network, connect Tailscale ('tailscale up') and re-run."
                "(Pass -SkipRegistryCheck to bypass, e.g. images pre-loaded with 'kind load'; or -SkipOperator to set up only the cluster.)"
            ) -join [Environment]::NewLine)
            return
        }
        Write-Host "Prerequisite OK: dev registry '$DevRegistry' is reachable." -ForegroundColor DarkGray
    }

    $existingClusters = (& kind get clusters 2>$null) -split "`n" | Where-Object { $_ -ne "" }
    if ($existingClusters -contains $ClusterName) {
        Write-Host "kind cluster '$ClusterName' already exists, leaving it untouched" -ForegroundColor Yellow
    }
    else {
        $kindConfig = Join-Path $kubernetesPath "kind-cluster.yaml"
        if (!(Test-Path $kindConfig)) {
            Write-Error "kind config not found at $kindConfig"
            return
        }
        # The config binds host ports to 127.0.0.1 (loopback) by default. -ExposeLan rewrites
        # them to 0.0.0.0 (LAN-reachable) into a temp config — kind reads listenAddress from
        # the file, so this is the only place the choice can be made (recreate to change it).
        $configToUse = $kindConfig
        if ($ExposeLan) {
            $configToUse = Join-Path ([System.IO.Path]::GetTempPath()) "octo-kind-cluster-lan.yaml"
            ((Get-Content $kindConfig -Raw) -replace 'listenAddress:\s*"127\.0\.0\.1"', 'listenAddress: "0.0.0.0"') | Set-Content -Path $configToUse -NoNewline
            Write-Host "  -ExposeLan: binding host ports on 0.0.0.0 (LAN-reachable; this exposes the dev infra to the network)" -ForegroundColor Yellow
        }
        Write-Host "Creating kind cluster '$ClusterName' from $configToUse" -ForegroundColor Green
        & kind create cluster --name $ClusterName --config $configToUse
        $createExit = $LASTEXITCODE
        if ($configToUse -ne $kindConfig) { Remove-Item $configToUse -ErrorAction SilentlyContinue }
        if ($createExit -ne 0) {
            Write-Error "kind create cluster failed with exit code $createExit"
            return
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DevRegistry)) {
        Write-Host "Configuring containerd to pull from dev registry '$DevRegistry' (skip TLS verify)" -ForegroundColor Green
        $node = "$ClusterName-control-plane"
        # config_path is normally set by kind-cluster.yaml (containerdConfigPatches). Add it
        # + restart containerd for any pre-existing cluster created before that was added.
        $hasCfg = (& docker exec $node sh -c "grep -q 'config_path' /etc/containerd/config.toml && echo yes" 2>$null)
        if ($hasCfg -ne "yes") {
            & docker exec $node sh -c "printf '\n[plugins.`"io.containerd.grpc.v1.cri`".registry]\n  config_path = `"/etc/containerd/certs.d`"\n' >> /etc/containerd/config.toml"
            & docker exec $node systemctl restart containerd
            Start-Sleep -Seconds 5
        }
        # certs.d hosts.toml: skip TLS verify for the (anonymous, internal-CA) dev registry.
        $tmpToml = Join-Path ([System.IO.Path]::GetTempPath()) "octo-hosts.toml"
        @"
server = "https://$DevRegistry"

[host."https://$DevRegistry"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
"@ | Set-Content -Path $tmpToml -NoNewline
        & docker exec $node mkdir -p "/etc/containerd/certs.d/$DevRegistry"
        & docker cp $tmpToml "${node}:/etc/containerd/certs.d/$DevRegistry/hosts.toml"
        Remove-Item $tmpToml -ErrorAction SilentlyContinue
    }

    Write-Host "Installing/upgrading Helm release '$CrdReleaseName' in namespace '$CrdNamespace' from $crdChartPath" -ForegroundColor Green
    & helm upgrade --install $CrdReleaseName $crdChartPath `
        --kube-context "kind-$ClusterName" `
        --namespace $CrdNamespace `
        --create-namespace
    if ($LASTEXITCODE -ne 0) {
        Write-Error "helm upgrade --install failed with exit code $LASTEXITCODE"
        return
    }

    $k8sDir = $kubernetesPath
    Write-Host "Applying namespaces" -ForegroundColor Green
    & kubectl --context "kind-$ClusterName" apply -f (Join-Path $k8sDir "namespaces.yaml")
    if ($LASTEXITCODE -ne 0) { Write-Error "kubectl apply namespaces failed"; return }

    if (-not $SkipInfra) {
        $ctx = "kind-$ClusterName"
        $infraDir = Join-Path $k8sDir "infra"

        # 1) keyFile secret (generate once; reuse infrastructure/file.key if present)
        $keyFile = Join-Path $infrastructurePath "file.key"
        if (!(Test-Path $keyFile)) {
            Write-Host "Generating Mongo keyFile" -ForegroundColor Green
            $randBytes = New-Object byte[] 741
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
            [Convert]::ToBase64String($randBytes) > $keyFile
        }
        & kubectl --context $ctx -n $InfraNamespace delete secret mongodb-keyfile --ignore-not-found | Out-Null
        & kubectl --context $ctx -n $InfraNamespace create secret generic mongodb-keyfile "--from-file=file.key=$keyFile"
        if ($LASTEXITCODE -ne 0) { Write-Error "create mongodb-keyfile secret failed"; return }

        # 2) Mongo init scripts configmap
        & kubectl --context $ctx -n $InfraNamespace delete configmap mongodb-init --ignore-not-found | Out-Null
        & kubectl --context $ctx -n $InfraNamespace create configmap mongodb-init "--from-file=$(Join-Path $infraDir "mongo-init")"
        if ($LASTEXITCODE -ne 0) { Write-Error "create mongodb-init configmap failed"; return }

        # 3) Apply infra workloads
        foreach ($m in @("rabbitmq.yaml", "cratedb.yaml", "mongodb.yaml")) {
            & kubectl --context $ctx apply -f (Join-Path $infraDir $m)
            if ($LASTEXITCODE -ne 0) { Write-Error "kubectl apply $m failed"; return }
        }

        # 4) Wait for readiness
        Write-Host "Waiting for infra to become ready..." -ForegroundColor Green
        & kubectl --context $ctx -n $InfraNamespace rollout status deploy/rabbitmq --timeout=180s
        if ($LASTEXITCODE -ne 0) { Write-Error "rabbitmq did not become ready within the timeout (rollout status failed). Aborting before host services connect to a half-ready infra."; return }
        & kubectl --context $ctx -n $InfraNamespace rollout status statefulset/cratedb --timeout=300s
        if ($LASTEXITCODE -ne 0) { Write-Error "cratedb did not become ready within the timeout (rollout status failed). Aborting before host services connect to a half-ready infra."; return }
        & kubectl --context $ctx -n $InfraNamespace rollout status statefulset/mongodb --timeout=300s
        if ($LASTEXITCODE -ne 0) { Write-Error "mongodb did not become ready within the timeout (rollout status failed). Aborting before the replica-set init."; return }

        # 5) Initialize the replica set (retry on transient network error), then seed admin user.
        #    The init scripts are idempotent and exit 0 on a re-run; a non-zero exit whose
        #    output is a benign "already initialized / already exists / requires auth" re-run
        #    message is tolerated, but any OTHER failure aborts the install instead of falsely
        #    reporting success (a wrong context, missing pod, or mongosh crash must not pass).
        Write-Host "Initializing Mongo replica set" -ForegroundColor Green
        $benignMongo = "already initialized|already exists|requires authentication|not authorized|Unauthorized"
        $mongoErr = Join-Path ([System.IO.Path]::GetTempPath()) "octo-k8s-mongo-init.stderr.txt"
        try {
            $initExit = 0
            $err = ""
            while ($true) {
                & { & kubectl --context $ctx -n $InfraNamespace exec mongodb-0 -- mongosh admin /scripts/init-replicaset.js } 2>$mongoErr
                $initExit = $LASTEXITCODE
                $err = Get-Content $mongoErr -Raw
                if (-not [string]::IsNullOrWhiteSpace($err)) { Write-Host $err }
                if (($initExit -ne 0) -and ($err -match "MongoNetworkError|not running|ECONNREFUSED")) {
                    Start-Sleep -s 3
                    continue
                }
                break
            }
            if ($initExit -ne 0 -and ($err -notmatch $benignMongo)) {
                Write-Error "Mongo replica-set init failed (exit code $initExit). See the output above."
                return
            }

            & { & kubectl --context $ctx -n $InfraNamespace exec mongodb-0 -- mongosh admin /scripts/create-admin-user.js } 2>$mongoErr
            $userExit = $LASTEXITCODE
            $userErr = Get-Content $mongoErr -Raw
            if (-not [string]::IsNullOrWhiteSpace($userErr)) { Write-Host $userErr }
            if ($userExit -ne 0 -and ($userErr -notmatch $benignMongo)) {
                Write-Error "Mongo admin-user seeding failed (exit code $userExit). See the output above."
                return
            }
        }
        finally {
            Remove-Item $mongoErr -ErrorAction SilentlyContinue
        }
    }

    $caTrustNote = $null
    if (-not $SkipIngress) {
        $ctx = "kind-$ClusterName"
        & helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>$null | Out-Null
        & helm repo add jetstack https://charts.jetstack.io 2>$null | Out-Null
        & helm repo update ingress-nginx jetstack | Out-Null

        Write-Host "Installing ingress-nginx (4.15.1)" -ForegroundColor Green
        & helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
            --kube-context $ctx --namespace ingress-nginx --create-namespace `
            --version 4.15.1 -f (Join-Path $k8sDir "ingress-nginx-values.yaml") --wait --timeout 180s
        if ($LASTEXITCODE -ne 0) { Write-Error "ingress-nginx install failed"; return }

        Write-Host "Installing cert-manager (v1.20.2)" -ForegroundColor Green
        & helm upgrade --install cert-manager jetstack/cert-manager `
            --kube-context $ctx --namespace cert-manager --create-namespace `
            --version v1.20.2 -f (Join-Path $k8sDir "cert-manager-values.yaml") --wait --timeout 180s
        if ($LASTEXITCODE -ne 0) { Write-Error "cert-manager install failed"; return }

        & kubectl --context $ctx -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
        if ($LASTEXITCODE -ne 0) { Write-Error "cert-manager webhook did not become ready (rollout status failed). Aborting before applying the cluster issuer."; return }

        Write-Host "Applying mm-cloud-issuer (local root CA)" -ForegroundColor Green
        & kubectl --context $ctx apply -f (Join-Path $k8sDir "cluster-issuer.yaml")
        if ($LASTEXITCODE -ne 0) { Write-Error "cluster-issuer apply failed"; return }
        & kubectl --context $ctx wait --for=condition=Ready clusterissuer/mm-cloud-issuer --timeout=120s
        if ($LASTEXITCODE -ne 0) { Write-Error "mm-cloud-issuer did not become Ready (kubectl wait failed). Aborting before exporting the local root CA."; return }

        # Export the local root CA so the host/browser can optionally trust it.
        $caPath = Join-Path $infrastructurePath "local-root-ca.crt"
        $caB64 = (& kubectl --context $ctx get secret local-root-ca-tls -n cert-manager -o "jsonpath={.data.ca\.crt}")
        if ($caB64) {
            [IO.File]::WriteAllBytes($caPath, [Convert]::FromBase64String($caB64))
            Write-Host "Local root CA written to $caPath" -ForegroundColor Cyan
            if (-not $SkipTrustCa) {
                # Non-fatal: a declined/failed sudo (or a non-elevated Windows session) must
                # not abort the whole setup. Capture the reason in $caTrustNote so it is
                # surfaced in the final summary, where it is visible instead of buried mid-run.
                try {
                    Add-OctoLocalCaTrust -CaPath $caPath
                } catch {
                    Write-Warning "CA trust skipped: $($_.Exception.Message)"
                    $caTrustNote = "Could not auto-trust the local root CA ($($_.Exception.Message)). Trust it manually with 'Add-OctoLocalCaTrust' (on Windows, from an elevated PowerShell)."
                }
            } else {
                $caTrustNote = "Local root CA not trusted (-SkipTrustCa). Trust it with 'Add-OctoLocalCaTrust'."
            }
        }
    }

    if (-not $SkipOperator) {
        if ($SkipInfra) {
            Write-Warning ("Deploying the operator with -SkipInfra: it expects in-cluster infra at " +
                "mongodb-0.mongodb.$InfraNamespace / rabbitmq.$InfraNamespace. If that infra isn't already " +
                "present from a prior install, the operator's managed pools won't reach the DB/broker. " +
                "Pass -SkipOperator as well if you only want the cluster/CRDs/ingress.")
        }
        if (-not $Json) { Write-Host "Deploying Communication Operator (dev registry, :main-latest)" -ForegroundColor Green }
        # Do NOT pass -Json to the sub-call: it would emit its own JSON object onto
        # stream 1 and corrupt this function's single envelope. Capture its stream-1
        # output (native helm/kubectl stdout) under -Json so only our envelope reaches
        # stream 1; let it stream normally otherwise.
        if ($Json) {
            Deploy-OctoOperator -branch $branch -ClusterName $ClusterName -SkipRegistryCheck:$SkipRegistryCheck 6>&1 | Out-Null
        }
        else {
            Deploy-OctoOperator -branch $branch -ClusterName $ClusterName -SkipRegistryCheck:$SkipRegistryCheck
        }
    }

    $currentContext = (& kubectl config current-context).Trim()

    if ($Json) {
        Write-OctoJson -Command 'Install-OctoKubernetes' -Data (New-OctoActionResult -Success $true -Extra @{ action = 'install' })
        return
    }

    Write-Host ""
    Write-Host "Octo Kubernetes setup complete." -ForegroundColor Green
    Write-Host "  kind cluster:      $ClusterName" -ForegroundColor Cyan
    Write-Host "  CRDs release:      $CrdReleaseName in namespace $CrdNamespace" -ForegroundColor Cyan
    Write-Host "  Pool namespace:    $PoolNamespace" -ForegroundColor Cyan
    if (-not $SkipOperator) {
        Write-Host "  Operator:          deployed (dev registry, :main-latest)" -ForegroundColor Cyan
    }
    if (-not $SkipIngress) {
        Write-Host "  Ingress:           ingress-nginx (class 'nginx'), apps at https://<name>.localhost" -ForegroundColor Cyan
        Write-Host "  TLS issuer:        mm-cloud-issuer (local root CA)" -ForegroundColor Cyan
    }
    Write-Host "  Current context:   $currentContext" -ForegroundColor Cyan
    if ($currentContext -ne "kind-$ClusterName") {
        Write-Host ""
        Write-Host "Note: current kubectl context is not 'kind-$ClusterName'." -ForegroundColor Yellow
        Write-Host "Run 'kubectl config use-context kind-$ClusterName' before running the operator." -ForegroundColor Yellow
    }

    if ($caTrustNote) {
        Write-Host ""
        Write-Host "  CA trust:          $caTrustNote" -ForegroundColor Yellow
    }
}

# Common name of the local root CA — matches `commonName` in kubernetes/cluster-issuer.yaml.
# Used as the identifiable handle for trust/untrust in the OS store, and the on-disk filename.
$Script:OctoLocalCaName = "OctoMesh Local Dev Root CA"
$Script:OctoLocalCaFile = "octo-mesh-local-dev-root-ca.crt"   # Linux trust-store filename

function Add-OctoLocalCaTrust {
<#
.SYNOPSIS
Trust the local kind root CA ("OctoMesh Local Dev Root CA") so browsers and CLI tools accept
the mm-cloud-issuer certificates without warnings.

.DESCRIPTION
Idempotent: any previously trusted "OctoMesh Local Dev Root CA" (e.g. from an earlier cluster)
is removed first, then the current CA is trusted — so re-runs and cluster recreations never pile
up duplicates. macOS uses the System keychain (sudo); Windows uses Cert:\LocalMachine\Root;
Linux uses update-ca-certificates (sudo). Restart the browser afterwards.
#>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$CaPath = (Join-Path $infrastructurePath "local-root-ca.crt")
    )

    if (!(Test-Path $CaPath)) {
        Write-Error "Local root CA not found at $CaPath. Run Install-OctoKubernetes first."
        return
    }

    $name = $Script:OctoLocalCaName
    Write-Host "Trusting '$name' from $CaPath ..." -ForegroundColor Green
    if ($IsMacOS) {
        # Idempotent: drop any prior cert with this name first (sudo caches the credential,
        # so the delete + add are a single prompt), then add the current one.
        & sudo security delete-certificate -c $name /Library/Keychains/System.keychain *> $null
        & sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $CaPath
    }
    elseif ($IsWindows) {
        Get-ChildItem 'Cert:\LocalMachine\Root' | Where-Object { $_.Subject -match [regex]::Escape($name) } |
            Remove-Item -ErrorAction SilentlyContinue
        Import-Certificate -FilePath $CaPath -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
    }
    elseif ($IsLinux) {
        & sudo cp $CaPath "/usr/local/share/ca-certificates/$($Script:OctoLocalCaFile)"
        & sudo update-ca-certificates | Out-Null
    }
    else {
        Write-Warning "Unsupported OS; trust $CaPath manually."
        return
    }
    Write-Host "Trusted '$name'. Restart the browser to pick it up." -ForegroundColor Cyan
}

function Remove-OctoLocalCaTrust {
    [CmdletBinding()]
    param()
    $name = $Script:OctoLocalCaName
    if ($IsMacOS) {
        & sudo security delete-certificate -c $name /Library/Keychains/System.keychain *> $null
    }
    elseif ($IsWindows) {
        Get-ChildItem 'Cert:\LocalMachine\Root' | Where-Object { $_.Subject -match [regex]::Escape($name) } |
            Remove-Item -ErrorAction SilentlyContinue
    }
    elseif ($IsLinux) {
        & sudo rm -f "/usr/local/share/ca-certificates/$($Script:OctoLocalCaFile)"
        & sudo update-ca-certificates | Out-Null
    }
    Write-Host "Untrusted '$name'." -ForegroundColor Cyan
}

Export-ModuleMember -Function @('Install-OctoKubernetes')
Export-ModuleMember -Function @('Add-OctoLocalCaTrust')
Export-ModuleMember -Function @('Remove-OctoLocalCaTrust')
