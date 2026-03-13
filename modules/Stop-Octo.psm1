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
        [string]$branch = ""
    )

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $stopFile = Join-Path -Path $branchRootPath -ChildPath ".octo-stop"

    Write-Host "Sending stop signal to OctoMesh services..."
    New-Item -ItemType File -Path $stopFile -Force | Out-Null
}

Export-ModuleMember -Function @('Stop-Octo')
