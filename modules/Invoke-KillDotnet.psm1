<#
.SYNOPSIS
    Kill all dotnet processes

.DESCRIPTION
    Kills all dotnet processes. This is necessary to avoid file locks during build process.
    This commandlet is only executed on Windows. On *nix systems, dotnet does not seem to lock files.
.EXAMPLE
    Invoke-KillDotnet

#>
function Invoke-KillDotnet {
    param(
        [switch]$Json
    )

    #we only do this on windows; linux does not seem to lock files.
    if ($IsWindows -eq $false) {
        if ($Json) {
            Write-OctoJson -Command 'Invoke-KillDotnet' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ killedCount = 0; skipped = $true })
            return
        }
        return
    }

    if (-not $Json) {
        Write-Host "Shutdown the dotnet build server" -ForegroundColor Yellow
    }
    dotnet build-server shutdown

    if (-not $Json) {
        Write-Host "Kill all dotnet processes" -ForegroundColor Yellow
    }
    $dotnetProcesses = @(Get-process | Where-Object { $_.Name -eq "dotnet" })
    $dotnetProcesses | Stop-Process -Force
    $killedCount = $dotnetProcesses.Count

    if ($Json) {
        Write-OctoJson -Command 'Invoke-KillDotnet' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ killedCount = $killedCount })
        return
    }
}

Export-ModuleMember -Function @('Invoke-KillDotnet')