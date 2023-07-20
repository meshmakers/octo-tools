
function Stop-OctoInfrastructure
{
    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }
    
    $basedir = $PWD
    Set-Location $infrastructurePath

    docker-compose down

    Set-Location $basedir
}

Export-ModuleMember -Function @('Stop-OctoInfrastructure')