
function Wait-DockerContainer([string]$containerId) {
    Write-Host "Waiting for docker container $containerId"
    
    # Loop until the container is running
    while ((docker inspect -f '{{.State.Status}}' $containerId) -ne "running") {
        Start-Sleep -Seconds 2
        Write-Host Waiting more...
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

Export-ModuleMember -Function @('Install-OctoInfrastructure')
Export-ModuleMember -Function @('Wait-DockerContainer')