
function Test-OctoKindInfraRunning {
    # Returns $true if a local kind cluster node container is running. The kind dev infra
    # binds the same host ports (27017/5672/15672/5432/4301) as this docker-compose stack
    # (see kubernetes/kind-cluster.yaml extraPortMappings), so the two cannot run together —
    # 'docker compose up' on top of a running cluster fails to bind those ports and leaves a
    # half-started stack.
    $running = docker ps --format '{{.Names}}' 2>$null
    foreach ($n in $running) {
        if ($n -match '-control-plane$') { return $true }
    }
    return $false
}

function Start-OctoInfrastructure
{
    param([switch]$Json)

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }

    if (Test-OctoKindInfraRunning) {
        Write-Error "A local kind cluster is running and binds the same host ports (27017/5672/15672/5432/4301) as the docker-compose infrastructure. Run 'Uninstall-OctoKubernetes' first (or stop the kind cluster) before starting the docker-compose infrastructure."
        return
    }

    $basedir = $PWD
    Set-Location $infrastructurePath

    if (-not $Json) { Write-Host "Starting Octo infrastructure" }
    docker compose up -d
    $exitCode = $LASTEXITCODE

    Set-Location $basedir

    if ($Json) {
        Write-OctoJson -Command 'Start-OctoInfrastructure' -Data (New-OctoActionResult -Success ($exitCode -eq 0) -ExitCode $exitCode -Extra @{ action = 'start' })
        return
    }

    Write-Host "Start done. Containers are running."
    Write-Host "For stopping use 'Stop-OctoInfrastructure'"
}

Export-ModuleMember -Function @('Start-OctoInfrastructure')