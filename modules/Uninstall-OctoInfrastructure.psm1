
function Uninstall-OctoInfrastructure
{
    param([switch]$Json)

    Write-OctoComposeDeprecation -Command 'Uninstall-OctoInfrastructure'

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }

    $basedir = $PWD
    Set-Location $infrastructurePath

    if (-not $Json) { Write-Host "Initializing infrastructure for OctoMesh"; }

    if (Test-Path -Path "file.key") {
        if (-not $Json) { Write-Host "Deleting key file"; }
        Remove-Item -Force -Path "file.key"
    }

    if (-not $Json) { Write-Host "Stopping containers and cleaning up volumes"; }
    docker compose down -v
    $exitCode = $LASTEXITCODE
    # The volumes are gone, so is the record of the version that wrote them.
    if ($exitCode -eq 0) { Clear-OctoComposeCrateVersion }

    Set-Location $basedir

    if ($Json) {
        Write-OctoJson -Command 'Uninstall-OctoInfrastructure' -Data (New-OctoActionResult -Success ($exitCode -eq 0) -ExitCode $exitCode -Extra @{ action = 'uninstall' })
        return
    }
}

Export-ModuleMember -Function @('Uninstall-OctoInfrastructure')