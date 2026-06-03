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

.PARAMETER PoolNamespace
Namespace into which the operator places auto-created CommunicationPool CRs
and broker secrets. Defaults to "octo".

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
        [Parameter()] [string]$PoolNamespace = "octo",
        [Parameter()] [string]$InfraNamespace = "octo-infra",
        [Parameter()] [switch]$SkipInfra,
        # Skip installing ingress-nginx + cert-manager + the mm-cloud-issuer CA ClusterIssuer.
        # By default they are installed so the local cluster exposes web workloads like staging.
        [Parameter()] [switch]$SkipIngress,
        # By default the exported local root CA is added to the OS trust store (Add-OctoLocalCaTrust)
        # so browsers/tools accept the mm-cloud-issuer certs without warnings. This prompts for
        # sudo on macOS/Linux. Pass -SkipTrustCa for unattended/CI runs.
        [Parameter()] [switch]$SkipTrustCa,
        # The Communication Operator is deployed by default. With -Configuration DebugL it is
        # BUILT from the octo-communication-operator source and loaded into kind (matches your
        # locally-built DebugL services); any other value installs the latest published operator
        # image. Pass -SkipOperator to not deploy it at all.
        [Parameter()] [string]$Configuration = "Release",
        [Parameter()] [switch]$SkipOperator,
        # Internal dev container registry the node should be able to pull adapter images
        # from. Its TLS cert is signed by an internal CA the kind node doesn't trust, so we
        # configure containerd to skip verification for it. Pass "" to skip this.
        [Parameter()] [string]$DevRegistry = "docker.mm.cloud"
    )

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
        Write-Error "docker-compose infrastructure is running and will collide on host ports 27017/5672/5432. Run 'Stop-OctoInfrastructure' first, or pass -SkipInfra to install only the k8s control plane."
        return
    }

    $crdChartPath = Join-Path $branchRootPath "octo-helm-core/src/octo-mesh-crds"
    if (!(Test-Path $crdChartPath)) {
        Write-Error "CRDs chart not found at $crdChartPath. Make sure octo-helm-core is checked out next to the other repositories."
        return
    }

    $PSStyle.Progress.View = "Classic"
    Write-Progress -Activity 'Install Octo Kubernetes' -Status 'Checking kind cluster' -PercentComplete 0

    $existingClusters = (& kind get clusters 2>$null) -split "`n" | Where-Object { $_ -ne "" }
    if ($existingClusters -contains $ClusterName) {
        Write-Host "kind cluster '$ClusterName' already exists, leaving it untouched" -ForegroundColor Yellow
    }
    else {
        Write-Progress -Activity 'Install Octo Kubernetes' -Status "Creating kind cluster '$ClusterName'" -PercentComplete 25
        $kindConfig = Join-Path $branchRootPath "octo-tools/kubernetes/kind-cluster.yaml"
        if (!(Test-Path $kindConfig)) {
            Write-Error "kind config not found at $kindConfig"
            return
        }
        Write-Host "Creating kind cluster '$ClusterName' from $kindConfig" -ForegroundColor Green
        & kind create cluster --name $ClusterName --config $kindConfig
        if ($LASTEXITCODE -ne 0) {
            Write-Error "kind create cluster failed with exit code $LASTEXITCODE"
            return
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DevRegistry)) {
        Write-Progress -Activity 'Install Octo Kubernetes' -Status "Configuring dev registry '$DevRegistry'" -PercentComplete 45
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

    Write-Progress -Activity 'Install Octo Kubernetes' -Status "Installing $CrdReleaseName Helm chart" -PercentComplete 60
    Write-Host "Installing/upgrading Helm release '$CrdReleaseName' in namespace '$CrdNamespace' from $crdChartPath" -ForegroundColor Green
    & helm upgrade --install $CrdReleaseName $crdChartPath `
        --kube-context "kind-$ClusterName" `
        --namespace $CrdNamespace `
        --create-namespace
    if ($LASTEXITCODE -ne 0) {
        Write-Error "helm upgrade --install failed with exit code $LASTEXITCODE"
        return
    }

    Write-Progress -Activity 'Install Octo Kubernetes' -Status "Applying namespaces" -PercentComplete 85
    $k8sDir = Join-Path $branchRootPath "octo-tools/kubernetes"
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
        & kubectl --context $ctx -n $InfraNamespace rollout status statefulset/cratedb --timeout=300s
        & kubectl --context $ctx -n $InfraNamespace rollout status statefulset/mongodb --timeout=300s

        # 5) Initialize the replica set (retry on transient network error), then seed admin user
        Write-Host "Initializing Mongo replica set" -ForegroundColor Green
        while ($true) {
            & { & kubectl --context $ctx -n $InfraNamespace exec mongodb-0 -- mongosh admin /scripts/init-replicaset.js } 2>k8s-stderr.txt
            $err = Get-Content k8s-stderr.txt -Raw
            Write-Host $err
            if ((-not [string]::IsNullOrWhiteSpace($err)) -and ($err -match "MongoNetworkError|not running|ECONNREFUSED")) {
                Start-Sleep -s 3
                continue
            }
            Remove-Item k8s-stderr.txt -ErrorAction SilentlyContinue
            break
        }
        & kubectl --context $ctx -n $InfraNamespace exec mongodb-0 -- mongosh admin /scripts/create-admin-user.js
    }

    if (-not $SkipIngress) {
        $ctx = "kind-$ClusterName"
        Write-Progress -Activity 'Install Octo Kubernetes' -Status 'Installing ingress-nginx + cert-manager' -PercentComplete 92

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

        Write-Host "Applying mm-cloud-issuer (local root CA)" -ForegroundColor Green
        & kubectl --context $ctx apply -f (Join-Path $k8sDir "cluster-issuer.yaml")
        if ($LASTEXITCODE -ne 0) { Write-Error "cluster-issuer apply failed"; return }
        & kubectl --context $ctx wait --for=condition=Ready clusterissuer/mm-cloud-issuer --timeout=120s

        # Export the local root CA so the host/browser can optionally trust it.
        $caPath = Join-Path $infrastructurePath "local-root-ca.crt"
        $caB64 = (& kubectl --context $ctx get secret local-root-ca-tls -n cert-manager -o "jsonpath={.data.ca\.crt}")
        if ($caB64) {
            [IO.File]::WriteAllBytes($caPath, [Convert]::FromBase64String($caB64))
            Write-Host "Local root CA written to $caPath" -ForegroundColor Cyan
            if (-not $SkipTrustCa) {
                # Non-fatal: a declined/failed sudo must not abort the whole setup.
                try { Add-OctoLocalCaTrust -CaPath $caPath } catch { Write-Warning "CA trust skipped: $($_.Exception.Message)" }
            } else {
                Write-Host "  CA not trusted (-SkipTrustCa). Run 'Add-OctoLocalCaTrust' to trust it." -ForegroundColor Yellow
            }
        }
    }

    if (-not $SkipOperator) {
        Write-Progress -Activity 'Install Octo Kubernetes' -Status 'Deploying Communication Operator' -PercentComplete 96
        if ($Configuration -eq "DebugL") {
            Write-Host "Deploying Communication Operator (DebugL: build from source + load into kind)" -ForegroundColor Green
            Deploy-OctoOperator -branch $branch -ClusterName $ClusterName -BuildLocal
        }
        else {
            Write-Host "Deploying Communication Operator (latest published image)" -ForegroundColor Green
            Deploy-OctoOperator -branch $branch -ClusterName $ClusterName
        }
    }

    Write-Progress -Activity 'Install Octo Kubernetes' -Status 'Complete' -PercentComplete 100

    $currentContext = (& kubectl config current-context).Trim()
    Write-Host ""
    Write-Host "Octo Kubernetes setup complete." -ForegroundColor Green
    Write-Host "  kind cluster:      $ClusterName" -ForegroundColor Cyan
    Write-Host "  CRDs release:      $CrdReleaseName in namespace $CrdNamespace" -ForegroundColor Cyan
    Write-Host "  Pool namespace:    $PoolNamespace" -ForegroundColor Cyan
    if (-not $SkipOperator) {
        $opMode = if ($Configuration -eq "DebugL") { "built from source (DebugL)" } else { "latest published image" }
        Write-Host "  Operator:          deployed ($opMode)" -ForegroundColor Cyan
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
        Import-Certificate -FilePath $CaPath -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
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
