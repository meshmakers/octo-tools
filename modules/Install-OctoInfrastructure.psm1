
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

.NOTES
Requires kind, helm, and kubectl on PATH. The CRDs chart is read from
"$rootPath/octo-helm-core/src/octo-mesh-crds".
#>

    param(
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [string]$CrdReleaseName = "octo-mesh-crds",
        [Parameter()] [string]$CrdNamespace = "octo-operator-system",
        [Parameter()] [string]$PoolNamespace = "octo"
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    foreach ($tool in @("kind", "helm", "kubectl")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Error "$tool is not on PATH. Install it before running Install-OctoKubernetes."
            return
        }
    }

    $crdChartPath = Join-Path $rootPath "octo-helm-core/src/octo-mesh-crds"
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
        Write-Host "Creating kind cluster '$ClusterName'" -ForegroundColor Green
        & kind create cluster --name $ClusterName
        if ($LASTEXITCODE -ne 0) {
            Write-Error "kind create cluster failed with exit code $LASTEXITCODE"
            return
        }
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

    Write-Progress -Activity 'Install Octo Kubernetes' -Status "Ensuring '$PoolNamespace' namespace exists" -PercentComplete 85
    & kubectl --context "kind-$ClusterName" get namespace $PoolNamespace 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Creating namespace '$PoolNamespace' for auto-managed CommunicationPool resources" -ForegroundColor Green
        & kubectl --context "kind-$ClusterName" create namespace $PoolNamespace
        if ($LASTEXITCODE -ne 0) {
            Write-Error "kubectl create namespace failed with exit code $LASTEXITCODE"
            return
        }
    }
    else {
        Write-Host "Namespace '$PoolNamespace' already exists, leaving it untouched" -ForegroundColor Yellow
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