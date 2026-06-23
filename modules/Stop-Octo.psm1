function Stop-Octo() {
    <#
.SYNOPSIS
Stops OctoMesh services started in non-interactive mode.

.DESCRIPTION
Creates a stop signal file that Start-Octo monitors when running in non-interactive mode.
This triggers a graceful shutdown of all services.

.EXAMPLE
Stop-Octo

Stops services started with Start-Octo -nonInteractive $true.
#>
    param(
        [string]$branch = "",
        [switch]$Json
    )

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $stopFile = Join-Path -Path $branchRootPath -ChildPath ".octo-stop"

    if (-not $Json) {
        Write-Host "Sending stop signal to OctoMesh services..."
    }
    New-Item -ItemType File -Path $stopFile -Force | Out-Null

    if ($Json) {
        Write-OctoJson -Command 'Stop-Octo' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ signalFile = $stopFile })
        return
    }
}

Export-ModuleMember -Function @('Stop-Octo')
