
function Get-OctoInfrastructureStatus
{
    param([switch]$Json)

    if (!(Test-Path $infrastructurePath)) {
        Write-Error "Infrastructure path $infrastructurePath does not exist"
        return;
    }

    $basedir = $PWD
    Set-Location $infrastructurePath

    if ($Json) {
        try {
            $raw = docker compose ps --format json
            if ($LASTEXITCODE -ne 0) {
                Write-OctoJson -Command 'Get-OctoInfrastructureStatus' -Data (New-OctoActionResult -Success $false -ExitCode $LASTEXITCODE -Extra @{ error = 'docker compose ps failed' })
                return
            }

            $services = @()
            foreach ($line in ($raw -split "`n")) {
                $trimmed = $line.Trim()
                if ($trimmed) {
                    $services += ($trimmed | ConvertFrom-Json)
                }
            }

            Write-OctoJson -Command 'Get-OctoInfrastructureStatus' -Data $services
        }
        finally {
            Set-Location $basedir
        }
        return
    }

    docker compose ps

    Set-Location $basedir
}

Export-ModuleMember -Function @('Get-OctoInfrastructureStatus')