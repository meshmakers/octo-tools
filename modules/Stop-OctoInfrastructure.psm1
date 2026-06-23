
function Stop-OctoInfrastructure
{
    param([switch]$Json)

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }

    $basedir = $PWD
    Set-Location $infrastructurePath

    if (-not $Json) { Write-Host "Stopping Octo infrastructure" }
    docker compose down
    $exitCode = $LASTEXITCODE

    Set-Location $basedir

    if ($Json) {
        Write-OctoJson -Command 'Stop-OctoInfrastructure' -Data (New-OctoActionResult -Success ($exitCode -eq 0) -ExitCode $exitCode -Extra @{ action = 'stop' })
        return
    }

    Write-Host "Stop done. Containers are stopped"
    Write-Host "For starting use 'Start-OctoInfrastructure'"
}

Export-ModuleMember -Function @('Stop-OctoInfrastructure')