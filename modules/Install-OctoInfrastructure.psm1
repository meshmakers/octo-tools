
function Wait-DockerContainer([string]$containerId) {
    Write-Host "Waiting for docker container $containerId"
    
    # Loop until the container is running
    $containerState = docker inspect -f '{{.State.Status}}' $containerId;
    while (-not ($containerState -like "running")) {
        Start-Sleep -Seconds 2
        Write-Host "Waiting another 2 section for $containerId to get from '$containerState' to 'running'"
        $containerState = docker inspect -f '{{.State.Status}}' $containerId;
    }
}

function Install-OctoInfrastructure {
    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }

    $PSStyle.Progress.View = "Classic"
    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Initializing infrastructure for OctoMesh' -PercentComplete 0
    
    $basedir = $PWD
    Set-Location $infrastructurePath
    
    # create the key file
    if (!(Test-Path -Path "file.key")) {
        Write-Host "Creating key file and setting access";
        $randBytes = New-Object byte[] 741
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
        $randString = [Convert]::ToBase64String($randBytes)
        $randString > file.key
    }

    if ($IsWindows) {
        Write-Progress -Activity 'Install Octo infrastructure' -Status 'Configuring WSL...' -PercentComplete 10
        Set-WSLConfig
    }

    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Docker compose up' -PercentComplete 30
    
    # run ...
    docker compose up -d
    
    Write-Progress -Activity 'Install Octo infrastructure' -Status  "Waiting for the containers to be started..." -PercentComplete 40
    Wait-DockerContainer mongo-0.mongo
    Start-Sleep -s 3

    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Setting up mongodb replicaset' -PercentComplete 50
    
    Write-Host "Initializing replica set and waiting for complete initialization";
    while ($true) {
        & {
            docker exec mongo-0.mongo sh -c "mongosh admin /scripts/init-database.js"
        } 2>stderr.txt
        $err = get-content stderr.txt
        Write-Host $err
        if ((-not ([string]::IsNullOrWhiteSpace($err))) -And $err.Contains("MongoNetworkError")) {
            Write-Progress -Activity 'Install Octo infrastructure' -Status  "Retrying to init replica set..." -PercentComplete 60
            Start-Sleep -s 3
            continue;
        }
        Remove-Item stderr.txt
        break;
    }

    # init user.
    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Creating admin user' -PercentComplete 80
    docker exec mongo-0.mongo sh -c "mongosh admin /scripts/create-admin-user.js"

    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Complete' -PercentComplete 100
    
    Clear-Host
    Write-Host "Initialization done. Containers are running."
    Write-Host "To stop the containers use 'Stop-OctoInfrastructure'"
    Write-Host "For the next start just 'Start-OctoInfrastructure'"
    
    Set-Location $basedir
}

function Set-WSLConfig {
    if (!$IsWindows) {
        return;
    }


    # Determine the path to the .wslconfig file
    $wslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"

    # VM Max Map Count value
    $vmMaxMapCount = 262144

    # Start with an empty config
    $config = New-Object System.Collections.ArrayList

    if (Test-Path $wslConfigPath) {
        # Load the existing config
        $existingConfig = (Get-Content -Raw $wslConfigPath) -split "`r`n"
        if ($null -ne $existingConfig) {
            $config.AddRange($existingConfig)
        }
    }

    # Track the current section
    $section = ""

    # Whether we have found the wsl2 section
    $wsl2Found = $false

    # Whether we have added or found the setting
    $added = $false

    # Whether the config was modified
    $modified = $false

    # Iterate over the config and modify it in-place
    for ($i = 0; $i -lt $config.Count; $i++) {
        if ($config[$i] -match '^\[(.+)\]') {
            if ($section -eq "wsl2" -and !$added) {
                $config.Insert($i, "kernelCommandLine = ""sysctl.vm.max_map_count=$vmMaxMapCount""")
                $added = $true
                $modified = $true
            }
            $section = $matches[1]
            if ($section -eq "wsl2") { $wsl2Found = $true }
        }
        elseif ($section -eq "wsl2" -and $config[$i] -match '(.+?)\s*=\s*(.+)') {
            $key = $matches[1].Trim()
            $value = $matches[2].Trim()

            # Update the setting if it exists
            if ($key -eq "kernelCommandLine") {
                if ($value -notmatch "sysctl\.vm\.max_map_count\s*=\s*($vmMaxMapCount)" -or [int]$matches[1] -lt $vmMaxMapCount) {
                    $config[$i] = "kernelCommandLine = ""sysctl.vm.max_map_count=$vmMaxMapCount"""
                    $modified = $true
                }
                $added = $true
            }
        }
    }

    # If the setting wasn't added, add the section and setting at the end
    if (!$added) {
        if (!$wsl2Found) {
            $config.Add("[wsl2]") | Out-Null
        }
        $config.Add("kernelCommandLine = ""sysctl.vm.max_map_count=$vmMaxMapCount""") | Out-Null
        $modified = $true
    }

    # Write the updated config to the file
    $config | Out-File $wslConfigPath -Encoding ascii

    # If the config was modified, restart WSL2 and Docker
    if ($modified) {
        # Restart WSL2
        Write-Host "Stoppwing WSL"
        wsl --shutdown

        Write-Host "Killing all Docker Processes"
        # kill all docker processes
        Get-Process *docker* | Stop-Process


        Write-Host "Starting Docker Desktop"
        # start docker destkop
        Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe"

        # wait until docker desktop is responsive again
        do {
            Write-Host "Waiting for Docker Desktop to be responsive..."
            Start-Sleep -Seconds 5
            try {
                docker ps | Out-Null
                $dockerIsResponsive = $true
            } 
            catch {
                $dockerIsResponsive = $false
            }
        } while (!$dockerIsResponsive)
    }
}

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

    Write-Progress -Activity 'Install Octo Kubernetes' -Status 'Complete' -PercentComplete 100

    $currentContext = (& kubectl config current-context).Trim()
    Write-Host ""
    Write-Host "Octo Kubernetes setup complete." -ForegroundColor Green
    Write-Host "  kind cluster:      $ClusterName" -ForegroundColor Cyan
    Write-Host "  CRDs release:      $CrdReleaseName in namespace $CrdNamespace" -ForegroundColor Cyan
    Write-Host "  Pool namespace:    $PoolNamespace" -ForegroundColor Cyan
    Write-Host "  Current context:   $currentContext" -ForegroundColor Cyan
    if ($currentContext -ne "kind-$ClusterName") {
        Write-Host ""
        Write-Host "Note: current kubectl context is not 'kind-$ClusterName'." -ForegroundColor Yellow
        Write-Host "Run 'kubectl config use-context kind-$ClusterName' before running the operator." -ForegroundColor Yellow
    }
}

Export-ModuleMember -Function @('Install-OctoInfrastructure')
Export-ModuleMember -Function @('Install-OctoKubernetes')
Export-ModuleMember -Function @('Wait-DockerContainer')