<#
.SYNOPSIS
    Kill dotnet processes to avoid file locks during a build - all of them, or only those of one lane.

.DESCRIPTION
    Without -branchRootPath (legacy behaviour): on Windows `dotnet build-server shutdown` plus
    Stop-Process -Force on EVERY process named dotnet; on macOS/Linux a no-op (dotnet does not lock
    files there).

    With -branchRootPath <lane folder> (lane mode): only dotnet processes that belong to that lane are
    considered. A process belongs to the lane when its working directory (macOS/Linux, via
    `lsof -a -d cwd -p <pids> -Fpn`), its entry assembly (the first .dll/.exe argument of the command
    line after the dotnet host, resolved against the cwd when relative - other arguments do not count),
    or (Windows) one of its loaded module paths lies under the lane folder (case-insensitive full-path
    prefix with a trailing separator). -branchRootPath is resolved against $PWD and must look like a
    lane (exist and hold Octo.User.props or an octo-*/mm-* folder), otherwise the call is refused. So a
    local daemon outside the lane (e.g. octo-devstack, `dotnet octo-devstack.dll` from
    ~/dev/meshmakers/octo-devstack) and the processes of other lanes survive.
      - Windows: the matched processes are stopped (Stop-Process -Force). `dotnet build-server shutdown`
        is NOT run: the compiler server is shared by every build of the user.
      - macOS/Linux: nothing is stopped (still no file locks there), the matched processes are only
        reported.
    Returns the matched processes ({ pid, name, reason }, reason = cwd | commandLine | module).

.PARAMETER branchRootPath
    Lane folder (e.g. .../meshmakers/main). Empty = legacy behaviour. Relative paths resolve against $PWD.

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
        # Relative to $PWD - [IO.Path]::GetFullPath would resolve against the process start directory
        # (e.g. C:\Users\<user>) and match far more than one lane.
        $laneRoot = [IO.Path]::TrimEndingDirectorySeparator($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($branchRootPath))
        $refusal = Test-OctoLaneFolder -path $laneRoot
        if ($refusal) {
            $global:LASTEXITCODE = 1
            if ($Json) {
                Write-OctoJson -Command 'Invoke-KillDotnet' -Data (New-OctoActionResult -Success $false -ExitCode 1 -Extra @{
                        error = $refusal; killedCount = 0; processes = @(); scoped = $true; buildServerShutdown = $false
                    })
            }
            Write-Error $refusal
            return
        }
        $processes = @(Get-OctoLaneDotnetProcesses -branchRootPath $laneRoot)
        $killedCount = 0
        $failed = @()
        if (Test-OctoKillDotnetWindows) {
            foreach ($process in $processes) {
                if (-not $Json) { Write-Host "Stop dotnet process $($process.pid) of the lane ($($process.reason))" -ForegroundColor Yellow }
                try {
                    Stop-Process -Id $process.pid -Force -ErrorAction Stop
                    $killedCount++
                }
                catch {
                    # A process that exited in the meantime is fine; one that is still there (e.g. access denied)
                    # is reported, because it may keep files of the lane locked.
                    if (Get-Process -Id $process.pid -ErrorAction SilentlyContinue) {
                        $failed += [ordered]@{ pid = $process.pid; reason = $process.reason; error = $_.Exception.Message }
                        Write-Warning "Could not stop dotnet process $($process.pid) of the lane: $($_.Exception.Message)"
                    }
                }
            }
        }
        elseif (-not $Json -and $processes.Count -gt 0) {
            Write-Host "$($processes.Count) dotnet process(es) of the lane found; not stopped (no file locks on this OS)" -ForegroundColor DarkGray
        }
        $exitCode = if ($failed.Count -gt 0) { 1 } else { 0 }
        $global:LASTEXITCODE = $exitCode
        if ($Json) {
            Write-OctoJson -Command 'Invoke-KillDotnet' -Data (New-OctoActionResult -Success ($failed.Count -eq 0) -ExitCode $exitCode -Extra @{
                    killedCount         = $killedCount
                    processes           = @($processes)
                    failed              = @($failed)
                    scoped              = $true
                    buildServerShutdown = $false
                })
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
        foreach ($line in @(Get-OctoProcessCwdRecords -processIds $candidates.Pid)) {
            if ($line -like 'p*') { $currentPid = [int]$line.Substring(1) }
            elseif ($line -like 'n*' -and $null -ne $currentPid) {
                $candidate = $candidates | Where-Object { $_.Pid -eq $currentPid } | Select-Object -First 1
                if ($candidate) { $candidate.Cwd = $line.Substring(1) }
            }
        }
    }

    return @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $branchRootPath)
}

function Get-OctoProcessCwdRecords {
    # The lsof field output (`p<pid>` / `n<cwd>` lines) for the working directories of the given processes
    # (macOS/Linux only). Separate so tests can mock it: lsof does not exist on Windows, and Pester can
    # only mock commands that exist.
    param([int[]]$processIds)
    $records = @(& lsof -a -d cwd -p ($processIds -join ',') -Fpn 2>$null)
    if ($LASTEXITCODE -ne 0 -and -not ($records | Where-Object { $_ -like 'n*' })) {
        # lsof also exits non-zero when a process ended in the meantime; only report processes that still live.
        $alive = @($processIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($alive.Count -gt 0) {
            Write-Warning "Invoke-KillDotnet: lsof could not read the working directory of $($alive.Count) process(es) (exit code $LASTEXITCODE); they are matched by command line and modules only."
        }
    }
    return $records
}

function Test-OctoLaneFolder {
    # $null when $path looks like a lane checkout (exists and holds Octo.User.props or an octo-* / mm-*
    # folder), otherwise the refusal message. Guards lane mode against `-branchRootPath .` or a home folder.
    param([Parameter(Mandatory = $true)] [string]$path)
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return "Invoke-KillDotnet: lane folder $path does not exist."
    }
    if (Test-Path -LiteralPath (Join-Path $path 'Octo.User.props') -PathType Leaf) { return $null }
    $repos = @(Get-ChildItem -LiteralPath $path -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'octo-*' -or $_.Name -like 'mm-*' })
    if ($repos.Count -gt 0) { return $null }
    return "Invoke-KillDotnet: $path does not look like a lane checkout (no Octo.User.props and no octo-*/mm-* folder) - refusing to stop processes under it."
}

function Get-OctoEntryAssemblyPath {
    # The entry assembly of a dotnet command line: the first argument ending in .dll or .exe after the
    # host (`dotnet` / `dotnet.exe`); an apphost (`.../Meshmakers.X.exe ...`) is its own entry. Relative
    # paths are resolved against the working directory; $null when it cannot be determined.
    param(
        [string]$command,
        [string]$cwd
    )
    if ([string]::IsNullOrWhiteSpace($command)) { return $null }
    $tokens = @([regex]::Matches($command, '"([^"]*)"|(\S+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } })
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        $leaf = ($token -split '[\\/]')[-1]
        if ($i -eq 0 -and $leaf -match '^dotnet(\.exe)?$') { continue }   # the host
        if ($token -notmatch '\.(dll|exe)$') {
            if ($i -eq 0) { return $null }   # first token is neither the host nor an apphost
            continue
        }
        if ([IO.Path]::IsPathRooted($token) -or $token -match '^[A-Za-z]:[\\/]') { return $token }
        if ([string]::IsNullOrWhiteSpace($cwd)) { return $null }
        return (Join-Path $cwd $token)
    }
    return $null
}

function Select-OctoLaneProcesses {
    # Pure matching: a candidate { Pid, Name, Command, Cwd, Modules } belongs to the lane when its cwd, its
    # entry assembly (Get-OctoEntryAssemblyPath - not any argument: a daemon started with
    # `--events <lane>/x.jsonl` is not the lane's) or one of its module paths lies under the lane folder.
    # $branchRootPath must be absolute (Invoke-KillDotnet resolves it against $PWD).
    param(
        [object[]]$candidates = @(),
        [Parameter(Mandatory = $true)] [string]$branchRootPath
    )
    $laneFull = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($branchRootPath))
    $prefixes = @("$laneFull/", "$laneFull\") | Select-Object -Unique
    $under = {
        param([string]$path)
        # Only absolute paths: GetFullPath would resolve a relative one against the process start directory.
        if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) { return $false }
        $full = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($path)) + [IO.Path]::DirectorySeparatorChar
        $full = $full -replace '\\', '/'
        foreach ($prefix in $prefixes) {
            if ($full.StartsWith(($prefix -replace '\\', '/'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    }

    $found = @()
    foreach ($candidate in $candidates) {
        # The octo-devstack daemon is never a lane process, also when its checkout lies in the folder used as the
        # lane (Invoke-BuildAll without -branch): it manages the stack and stops its services itself.
        $entry = Get-OctoEntryAssemblyPath -command ([string]$candidate.Command) -cwd ([string]$candidate.Cwd)
        if ($entry -and (($entry -split '[\\/]')[-1] -eq 'octo-devstack.dll')) { continue }
        $reason = $null
        if (& $under ([string]$candidate.Cwd)) { $reason = 'cwd' }
        elseif (& $under (Get-OctoEntryAssemblyPath -command ([string]$candidate.Command) -cwd ([string]$candidate.Cwd))) { $reason = 'commandLine' }
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

function Get-OctoProcessesUnderFolder {
    <#
    .SYNOPSIS
        List-only: the processes that run from a folder, with the lane matching of Invoke-KillDotnet.
    .DESCRIPTION
        Same rule as Invoke-KillDotnet's lane mode (Select-OctoLaneProcesses): a process belongs to the folder when its
        working directory (macOS/Linux, lsof), its entry assembly or (Windows, dotnet processes) one of its module paths
        lies under it - prefix with a trailing separator, case-insensitive; the octo-devstack daemon never counts. Unlike
        the lane mode it looks at EVERY process (a shell, an IDE or a Claude Code session in the folder counts, not only
        dotnet), accepts any folder (no lane check) and never stops anything. Used before a worktree is moved
        (Add-OctoEnvironmentRepo -path). Returns { pid, name, reason }.
    #>
    param([Parameter(Mandatory = $true)] [string]$path)
    $folder = [IO.Path]::TrimEndingDirectorySeparator($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path))
    $windows = Test-OctoKillDotnetWindows
    $candidates = @()
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        $modules = @()
        if ($windows -and $process.Name -eq 'dotnet') {
            try { $modules = @($process.Modules | ForEach-Object { $_.FileName } | Where-Object { $_ }) } catch { $modules = @() }
        }
        $candidates += [pscustomobject]@{ Pid = [int]$process.Id; Name = [string]$process.Name; Command = [string]$process.CommandLine; Cwd = $null; Modules = $modules }
    }
    if (-not $windows -and $candidates.Count -gt 0) {
        $currentPid = $null
        # Processes of other users are not readable; that is expected here, so no warning.
        foreach ($line in @(Get-OctoProcessCwdRecords -processIds $candidates.Pid -WarningAction SilentlyContinue)) {
            if ($line -like 'p*') { $currentPid = [int]$line.Substring(1) }
            elseif ($line -like 'n*' -and $null -ne $currentPid) {
                $candidate = $candidates | Where-Object { $_.Pid -eq $currentPid } | Select-Object -First 1
                if ($candidate) { $candidate.Cwd = $line.Substring(1) }
            }
        }
    }
    return @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $folder)
}

Export-ModuleMember -Function @('Invoke-KillDotnet', 'Get-OctoProcessesUnderFolder')
