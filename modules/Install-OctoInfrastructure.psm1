
function Wait-DockerContainer([string]$containerId)
{
    Write-Host "Waiting for docker container $containerId"
    
    # Loop until the container is running
    while ((docker inspect -f '{{.State.Status}}' $containerId) -ne "running") {
        Start-Sleep -Seconds 2
        Write-Host Waiting more...
    }
}

function Install-OctoInfrastructure
{
    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }

    $PSStyle.Progress.View = "Classic"
    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Initializing infrastructure for octo mesh' -PercentComplete 0
    
    $basedir = $PWD
    Set-Location $infrastructurePath
    
    # create the key file
    if (!(Test-Path -Path "file.key")) {
        Write-Host "Creating key file and setting access";
        $randBytes = New-Object byte[] 741
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
        $randString = [Convert]::ToBase64String($randBytes)
        $randString > file.key
    
        # mongodb only allows readonly files as key
        if ($IsLinux -or $IsMacOS)
        {
            chmod 400 file.key
        }
    }

    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Docker compose up' -PercentComplete 10
    
    # run ...
    docker compose up -d
    
    Write-Progress -Activity 'Install Octo infrastructure' -Status  "Waiting for the containers to be started..." -PercentComplete 20
    Wait-DockerContainer mongo-0.mongo
    Start-Sleep -s 3

    Write-Progress -Activity 'Install Octo infrastructure' -Status 'Setting up mongodb replicaset' -PercentComplete 50
    
    Write-Host "Initializing replica set and waiting for complete initialization";
    while($true)
    {
        &{
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
    Write-Host "For the next start just 'Start-OctoInfrastructure'"
  
    
    Set-Location $basedir
}

Export-ModuleMember -Function @('Install-OctoInfrastructure')
Export-ModuleMember -Function @('Wait-DockerContainer')