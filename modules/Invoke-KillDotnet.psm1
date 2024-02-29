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
    #we only do this on windows; linux does not seem to lock files.
    if ($IsWindows -eq $false) {
        return
    }

    Write-Host "Shutdown the dotnet build server" -ForegroundColor Yellow
    dotnet build-server shutdown

    Write-Host "Kill all dotnet processes" -ForegroundColor Yellow
    Get-process | Where-Object { $_.Name -eq "dotnet" } | Stop-Process -Force
}

Export-ModuleMember -Function @('Invoke-KillDotnet')