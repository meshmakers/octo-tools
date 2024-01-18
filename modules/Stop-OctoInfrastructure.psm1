
function Stop-OctoInfrastructure
{
    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }
    
    $basedir = $PWD
    Set-Location $infrastructurePath

    Write-Host "Stopping Octo infrastructure"
    docker compose down

    Set-Location $basedir

    Write-Host "Stop done. Containers are stopped"
    Write-Host "For starting use 'Start-OctoInfrastructure'"
}

Export-ModuleMember -Function @('Stop-OctoInfrastructure')