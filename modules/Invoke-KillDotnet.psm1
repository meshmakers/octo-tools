<#
.SYNOPSIS
    Kill dotnet processes to avoid file locks during a build - all of them, or only those of one lane.

.DESCRIPTION
    Without -branchRootPath (legacy behaviour): on Windows `dotnet build-server shutdown` plus
    Stop-Process -Force on EVERY process named dotnet; on macOS/Linux a no-op (dotnet does not lock
    files there).

    With -branchRootPath <lane folder> (lane mode): only dotnet processes that belong to that lane are
    considered. A process belongs to the lane when its working directory (macOS/Linux, via
    `lsof -a -d cwd -p <pids> -Fpn`), its command line, or (Windows) one of its loaded module paths
    lies under the lane folder (case-insensitive full-path prefix with a trailing separator). So a
    local daemon outside the lane (e.g. octo-devstack, `dotnet octo-devstack.dll` from
    ~/dev/meshmakers/octo-devstack) and the processes of other lanes survive.
      - Windows: the matched processes are stopped (Stop-Process -Force). `dotnet build-server shutdown`
        is NOT run: the compiler server is shared by every build of the user.
      - macOS/Linux: nothing is stopped (still no file locks there), the matched processes are only
        reported.
    Returns the matched processes ({ pid, name, reason }, reason = cwd | commandLine | module).

.PARAMETER branchRootPath
    Lane folder (e.g. .../meshmakers/main). Empty = legacy behaviour.

.PARAMETER Json
    Legacy mode: { success, exitCode, killedCount[, skipped] }. Lane mode:
    { success, exitCode, killedCount, processes: [{ pid, name, reason }], scoped: true, buildServerShutdown: false }.

.EXAMPLE
    Invoke-KillDotnet

.EXAMPLE
    Invoke-KillDotnet -branchRootPath (Join-Path $rootPath 'main') -Json
#>
function Invoke-KillDotnet {
    param(
        [string]$branchRootPath = '',
        [switch]$Json
    )

    if (-not [string]::IsNullOrWhiteSpace($branchRootPath)) {
        $processes = @(Get-OctoLaneDotnetProcesses -branchRootPath $branchRootPath)
        $killedCount = 0
        if (Test-OctoKillDotnetWindows) {
            foreach ($process in $processes) {
                if (-not $Json) { Write-Host "Stop dotnet process $($process.pid) of the lane ($($process.reason))" -ForegroundColor Yellow }
                Stop-Process -Id $process.pid -Force -ErrorAction SilentlyContinue
                $killedCount++
            }
        }
        elseif (-not $Json -and $processes.Count -gt 0) {
            Write-Host "$($processes.Count) dotnet process(es) of the lane found; not stopped (no file locks on this OS)" -ForegroundColor DarkGray
        }
        if ($Json) {
            Write-OctoJson -Command 'Invoke-KillDotnet' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra ([ordered]@{
                        killedCount         = $killedCount
                        processes           = @($processes)
                        scoped              = $true
                        buildServerShutdown = $false
                    }))
            return
        }
        return $processes
    }

    #we only do this on windows; linux does not seem to lock files.
    if (-not (Test-OctoKillDotnetWindows)) {
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

function Test-OctoKillDotnetWindows {
    # Separate so tests can take the Windows path on any OS. Windows PowerShell 5.1 has no
    # $IsWindows ($null) and counts as Windows, like the original `$IsWindows -eq $false` check.
    return ($IsWindows -ne $false)
}

function Get-OctoLaneDotnetProcesses {
    # The dotnet processes that belong to the lane (see Invoke-KillDotnet), as { pid, name, reason }.
    param([Parameter(Mandatory = $true)] [string]$branchRootPath)

    $windows = Test-OctoKillDotnetWindows
    $candidates = @()
    foreach ($process in @(Get-Process -Name 'dotnet' -ErrorAction SilentlyContinue)) {
        $modules = @()
        if ($windows) {
            # Access to the modules of another user's / elevated process is denied - skip those.
            try { $modules = @($process.Modules | ForEach-Object { $_.FileName } | Where-Object { $_ }) } catch { $modules = @() }
        }
        $candidates += [pscustomobject]@{ Pid = [int]$process.Id; Name = [string]$process.Name; Command = [string]$process.CommandLine; Cwd = $null; Modules = $modules }
    }

    # macOS/Linux: the services run as `dotnet X.dll` with cwd <lane>/<repo>/bin/<cfg>/<tfm>, so the
    # command line alone does not show the lane - read the working directories.
    if (-not $windows -and $candidates.Count -gt 0) {
        $currentPid = $null
        foreach ($line in @(& lsof -a -d cwd -p (($candidates.Pid) -join ',') -Fpn 2>$null)) {
            if ($line -like 'p*') { $currentPid = [int]$line.Substring(1) }
            elseif ($line -like 'n*' -and $null -ne $currentPid) {
                $candidate = $candidates | Where-Object { $_.Pid -eq $currentPid } | Select-Object -First 1
                if ($candidate) { $candidate.Cwd = $line.Substring(1) }
            }
        }
    }

    return @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $branchRootPath)
}

function Select-OctoLaneProcesses {
    # Pure matching: a candidate { Pid, Name, Command, Cwd, Modules } belongs to the lane when its cwd,
    # its command line or one of its module paths lies under the lane folder.
    param(
        [object[]]$candidates = @(),
        [Parameter(Mandatory = $true)] [string]$branchRootPath
    )
    $laneFull = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($branchRootPath))
    $prefixes = @("$laneFull/", "$laneFull\") | Select-Object -Unique
    $under = {
        param([string]$path)
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        $full = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($path)) + [IO.Path]::DirectorySeparatorChar
        foreach ($prefix in $prefixes) {
            if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    $found = @()
    foreach ($candidate in $candidates) {
        $reason = $null
        if (& $under ([string]$candidate.Cwd)) { $reason = 'cwd' }
        elseif ($candidate.Command) {
            foreach ($prefix in $prefixes) {
                if (([string]$candidate.Command).IndexOf($prefix, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $reason = 'commandLine'; break }
            }
        }
        if (-not $reason) {
            foreach ($module in @($candidate.Modules)) {
                if (& $under ([string]$module)) { $reason = 'module'; break }
            }
        }
        if ($reason) {
            $found += [pscustomobject][ordered]@{ pid = [int]$candidate.Pid; name = [string]$candidate.Name; reason = $reason }
        }
    }
    return $found
}

Export-ModuleMember -Function @('Invoke-KillDotnet')
