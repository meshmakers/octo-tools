
function Start-OctoInfrastructure
{
    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }
    
    $basedir = $PWD
    Set-Location $infrastructurePath

    Write-Host "Starting Octo infrastructure"
    docker compose up -d

    Set-Location $basedir


    Write-Host "Start done. Containers are running."
    Write-Host "For stopping use 'Stop-OctoInfrastructure'"
}

Export-ModuleMember -Function @('Start-OctoInfrastructure')