
function Install-OctoInfrastructure
{
    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }
    
    $basedir = $PWD
    
    Write-Host "Initializing infrastructure for octo mesh";
    
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
    
    # run ...
    docker compose up -d
    
    Write-Host "Waiting for 5s for the containers to be started...";
    Start-Sleep -s 5
    
    Write-Host "Initializing replica set...";
    docker exec mongo-0.mongo sh -c "mongosh /scripts/init-database.js"
    
    Write-Host "Waiting for 10s until replicaset is initialized...";
    Start-Sleep -s 10
    
    # init replica, set users.
    Write-Host "create admin user...";
    docker exec mongo-0.mongo sh -c "mongosh /scripts/create-admin-user.js"
    
    Write-Host "Initialization done. Containers are running."
    Write-Host "For the next start just 'run docker-compose up'"
    
     Set-Location $basedir
}

Export-ModuleMember -Function @('Install-OctoInfrastructure')