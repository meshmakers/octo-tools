
function Uninstall-OctoInfrastructure
{
    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }
    
    $basedir = $PWD
    Set-Location $infrastructurePath
    
    Write-Host "Initializing infrastructure for octo mesh";

    if (Test-Path -Path "file.key") {
        Write-Host "Deleting key file";
        Remove-Item -Force -Path "file.key"
    }

    Write-Host "Stopping containers and cleaning up volumes";
    docker compose down -v
    
     Set-Location $basedir
}

Export-ModuleMember -Function @('Uninstall-OctoInfrastructure')