<#
.SYNOPSIS
    Starts and stops the octo-devstack daemon, the local MCP server that runs the OctoMesh dev stack for
    several Claude Code sessions.

.DESCRIPTION
    Not a replacement for Start-Octo: Start-Octo starts the OctoMesh services in this shell. The octo-devstack
    daemon is a separate process that Claude Code sessions talk to (MCP at http://127.0.0.1:<port>/mcp,
    status page at http://127.0.0.1:<port>/); it starts and stops the OctoMesh services itself.

    Getting it uses the existing cmdlets: `Invoke-CloneMainRepos -devTools` clones meshmakers/octo-devstack
    next to octo-tools, and Start-OctoDevStackDaemon builds it with Invoke-Build when the build is missing.
    Stopping the daemon never stops the stack services it started; the next daemon adopts them.
#>

$script:DllRelativePath = 'bin/Release/net10.0/octo-devstack.dll'

# ---------------------------------------------------------------------------------------------------------
# Small wrappers (one per OS question or external effect) so the tests can mock them.
# ---------------------------------------------------------------------------------------------------------

function Test-OctoDevStackWindows { return [bool]$IsWindows }

function Get-OctoDevStackDefaultPath {
    # <parent of the octo-tools checkout>/octo-devstack - where `Invoke-CloneMainRepos -devTools` clones it. A
    # worktree of octo-tools (<octo-tools>/.claude/worktrees/<name>) resolves to the main checkout first.
    $toolsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $marker = [regex]::Match($toolsRoot, '[\\/]\.claude[\\/]worktrees[\\/]')
    if ($marker.Success) { $toolsRoot = $toolsRoot.Substring(0, $marker.Index) }
    $toolsRoot = [IO.Path]::TrimEndingDirectorySeparator($toolsRoot)
    return Join-Path (Split-Path -Parent $toolsRoot) 'octo-devstack'
}

function Get-OctoDevStackStatePath {
    if ($env:OCTO_DEVSTACK_STATE) { return $env:OCTO_DEVSTACK_STATE }
    $home_ = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return Join-Path $home_ '.local/state/octo-devstack'
}

function Get-OctoDevStackNativeCommand([string]$Name) {
    # The native executable, never a PowerShell alias of the same name (on Windows `kill` and `ps` are
    # aliases of Stop-Process / Get-Process). $null when it is not installed.
    $app = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app) { return $app.Source }
    return $null
}

function Test-OctoDevStackHealth([int]$Port) {
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-OctoDevStackListener([int]$Port) {
    # The processes listening on the TCP port: [{ pid, commandLine }]. Never by process name.
    $result = @()
    if (Test-OctoDevStackWindows) {
        $pids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty OwningProcess -Unique)
        foreach ($processId in $pids) {
            $commandLine = if ([int]$processId -eq 4) {
                # PID 4 (System) owns ports of http.sys: an HttpListener/IIS/WinRM URL reservation of some process.
                'http.sys (System) - the real owner is listed by: netsh http show servicestate'
            }
            else { (Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue).CommandLine }
            $result += [pscustomobject]@{ pid = [int]$processId; commandLine = [string]$commandLine }
        }
        return $result
    }
    foreach ($processId in @(Get-OctoDevStackListeningPids -Port $Port)) {
        $result += [pscustomobject]@{ pid = [int]$processId; commandLine = (Get-OctoDevStackProcessCommandLine -ProcessId $processId) }
    }
    return $result
}

# macOS/Linux seams around lsof, ps and kill: the tests mock these, never the tools, because Pester cannot mock
# a command that does not exist (lsof on Windows) and `ps` / `kill` are aliases there.
function Get-OctoDevStackListeningPids([int]$Port) {
    $lsof = Get-OctoDevStackNativeCommand 'lsof'
    if (-not $lsof) {
        Write-Warning "lsof is not installed: cannot tell which process listens on port $Port."
        return @()
    }
    return @(& $lsof -nP "-iTCP:$Port" -sTCP:LISTEN -t 2>$null | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ } | Select-Object -Unique)
}

function Get-OctoDevStackProcessCommandLine([int]$ProcessId) {
    $ps = Get-OctoDevStackNativeCommand 'ps'
    if (-not $ps) { return '' }
    return (@(& $ps -o command= -p $ProcessId 2>$null) -join ' ').Trim()
}

function Send-OctoDevStackSignal([int]$ProcessId, [string]$Signal = 'TERM') {
    $kill = Get-OctoDevStackNativeCommand 'kill'
    if (-not $kill) { throw 'kill is not installed.' }
    & $kill "-$Signal" $ProcessId
    if ($LASTEXITCODE -ne 0) { throw "kill -$Signal $ProcessId failed (exit code $LASTEXITCODE)." }
}

function Test-OctoDevStackCommandLine([string]$CommandLine) {
    return $CommandLine -match '(^|[\\/\s"''])octo-devstack\.dll(["''\s]|$)'
}

function Start-OctoDevStackDetachedUnix([string]$WorkingDirectory, [string]$LogPath, [string]$Dll, [string]$Url) {
    # `dotnet <dll> --url <url>` in its own process group (`set -m`; a Start-Process child would stay in pwsh's
    # group and die with Ctrl+C in that terminal), surviving the window (`nohup`), output appended to the log.
    $script = 'log="$0"; cd "$1" || exit 1; shift; set -m; nohup "$@" >>"$log" 2>&1 </dev/null & echo $!'
    $output = & /bin/sh -c $script $LogPath $WorkingDirectory dotnet $Dll --url $Url
    $text = (@($output) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $text -notmatch '^\d+$') { return $null }
    return [int]$text
}

function Save-OctoDevStackPreviousLog([string]$LogPath) {
    # Windows: Start-Process cannot append, so the previous run's log is kept as <name>.prev.log.
    if (-not (Test-Path -LiteralPath $LogPath)) { return }
    $previous = [IO.Path]::ChangeExtension($LogPath, '.prev.log')
    try { Move-Item -LiteralPath $LogPath -Destination $previous -Force -ErrorAction Stop }
    catch { Write-Warning "Could not keep $LogPath as $previous ($($_.Exception.Message)); it is overwritten." }
}

function Test-OctoDevStackProcessAlive([int]$ProcessId) {
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Write-OctoDevStackResult([string]$Command, [bool]$Json, [bool]$Success, [hashtable]$Data, [string]$ErrorMessage) {
    $exitCode = [int](-not $Success)
    $global:LASTEXITCODE = $exitCode
    if ($ErrorMessage) { $Data.error = $ErrorMessage }
    if ($Json) { Write-OctoJson -Command $Command -Data (New-OctoActionResult -Success $Success -ExitCode $exitCode -Extra $Data) }
    if (-not $Success) { Write-Error $ErrorMessage }
}

# ---------------------------------------------------------------------------------------------------------

function Start-OctoDevStackDaemon {
    <#
    .SYNOPSIS
        Starts the octo-devstack daemon on http://127.0.0.1:<Port> (in the background by default).

    .DESCRIPTION
        - octo-devstack already answers on the port: nothing is started.
        - Another program holds the port: refused, the process is named.
        - No checkout: `Invoke-CloneMainRepos -devTools` clones it next to octo-tools (or pass -Path).
        - No build: built with Invoke-Build -configuration Release.
        - Background start: macOS/Linux in its own process group (neither Ctrl+C nor closing the window stops
          it), output appended to <state>/daemon.log; Windows: hidden window, the previous log kept as
          daemon.prev.log. Then /health is polled for up to -HealthTimeoutSeconds.
        - -Foreground: runs in this console.
        Claude Code: `claude mcp add --transport http --scope user octo-devstack http://127.0.0.1:<Port>/mcp`.

    .PARAMETER Json
        { success, exitCode, alreadyRunning, started, built, pid, port, mcpUrl, statusPage, logPath[, error] }.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$Port = 5090,
        [switch]$Foreground,
        [int]$HealthTimeoutSeconds = 30,
        [switch]$Json
    )

    $command = 'Start-OctoDevStackDaemon'
    $repoPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-OctoDevStackDefaultPath } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $dll = Join-Path $repoPath $script:DllRelativePath
    $url = "http://127.0.0.1:$Port"
    $statePath = Get-OctoDevStackStatePath
    $logPath = Join-Path $statePath 'daemon.log'
    $data = @{ alreadyRunning = $false; started = $false; built = $false; pid = $null; port = $Port; mcpUrl = "$url/mcp"; statusPage = "$url/"; logPath = $logPath }

    if ($Foreground -and $Json) {
        Write-OctoDevStackResult $command $Json $false $data '-Foreground runs the daemon in this console and cannot be combined with -Json.'
        return
    }

    $listeners = @(Get-OctoDevStackListener -Port $Port)
    $ours = @($listeners | Where-Object { Test-OctoDevStackCommandLine $_.commandLine }) | Select-Object -First 1
    if ($ours -or ($listeners.Count -eq 0 -and (Test-OctoDevStackHealth -Port $Port))) {
        $data.alreadyRunning = $true
        if ($ours) { $data.pid = $ours.pid }
        if (-not $Json) { Write-Host "octo-devstack is already running on $url$(if ($ours) { " (PID $($ours.pid))" }) - MCP $url/mcp" -ForegroundColor Green }
        Write-OctoDevStackResult $command $Json $true $data $null
        return
    }
    if ($listeners.Count -gt 0) {
        $who = ($listeners | ForEach-Object { "PID $($_.pid) ($($_.commandLine))" }) -join ', '
        Write-OctoDevStackResult $command $Json $false $data "Port $Port is in use by $who, which is not octo-devstack. Stop it or pass -Port."
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repoPath 'src'))) {
        Write-OctoDevStackResult $command $Json $false $data "No octo-devstack checkout in $repoPath. Run Invoke-CloneMainRepos -devTools (clones it next to octo-tools) or pass -Path."
        return
    }
    if (-not (Test-Path -LiteralPath $dll)) {
        if ($Json) { Invoke-Build -repositoryPath $repoPath -configuration Release -Json | Out-Null } else { Invoke-Build -repositoryPath $repoPath -configuration Release }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll)) {
            Write-OctoDevStackResult $command $Json $false $data "Invoke-Build -repositoryPath $repoPath -configuration Release failed (see $(Join-Path $repoPath 'Invoke-Build.log'))."
            return
        }
        $data.built = $true
    }

    if ($Foreground) {
        Write-Host "octo-devstack in the foreground on $url (Ctrl+C stops it)" -ForegroundColor Cyan
        Push-Location $repoPath
        try { dotnet $dll --url $url }
        finally { Pop-Location }
        return
    }

    if (-not (Test-Path -LiteralPath $statePath)) { New-Item -ItemType Directory -Force -Path $statePath | Out-Null }
    if (Test-OctoDevStackWindows) {
        $errorLogPath = Join-Path $statePath 'daemon.err.log'
        Save-OctoDevStackPreviousLog -LogPath $logPath
        Save-OctoDevStackPreviousLog -LogPath $errorLogPath
        # Start-Process joins the arguments with spaces and does not quote them: a path with spaces needs quotes.
        $process = Start-Process -FilePath 'dotnet' -ArgumentList @("`"$dll`"", '--url', $url) -WorkingDirectory $repoPath `
            -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $errorLogPath -PassThru
        $processId = if ($process) { [int]$process.Id } else { $null }
    }
    else {
        $processId = Start-OctoDevStackDetachedUnix -WorkingDirectory $repoPath -LogPath $logPath -Dll $dll -Url $url
    }
    if (-not $processId) {
        Write-OctoDevStackResult $command $Json $false $data "Could not start dotnet $dll; see $logPath."
        return
    }
    $data.pid = $processId

    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    while (-not (Test-OctoDevStackHealth -Port $Port)) {
        $alive = Test-OctoDevStackProcessAlive -ProcessId $processId
        if (-not $alive -or (Get-Date) -ge $deadline) {
            $why = if ($alive) { "does not answer after $HealthTimeoutSeconds s" } else { 'exited' }
            Write-OctoDevStackResult $command $Json $false $data "octo-devstack (PID $processId) $why; see $logPath."
            return
        }
        Start-Sleep -Milliseconds 500
    }
    $data.started = $true
    if (-not $Json) {
        Write-Host "octo-devstack is running (PID $processId)" -ForegroundColor Green
        Write-Host "  MCP:         $url/mcp"
        Write-Host "  Status page: $url/"
        Write-Host "  Log:         $logPath"
    }
    Write-OctoDevStackResult $command $Json $true $data $null
}

function Stop-OctoDevStackDaemon {
    <#
    .SYNOPSIS
        Stops the octo-devstack daemon on the port; the stack services it started keep running and are adopted
        by the next start.

    .DESCRIPTION
        Only the process that listens on the port AND whose command line names octo-devstack.dll is stopped
        (lsof/ps on macOS/Linux, Get-NetTCPConnection/Win32_Process on Windows) - never by name. Another
        program on the port is refused. macOS/Linux: SIGTERM, SIGKILL after -TimeoutSeconds; Windows:
        Stop-Process. "stopped" is reported only after the process is gone.

    .PARAMETER Json
        { success, exitCode, stopped, pid, port[, error] }.
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 5090,
        [int]$TimeoutSeconds = 15,
        [switch]$Json
    )

    $command = 'Stop-OctoDevStackDaemon'
    $data = @{ stopped = $false; pid = $null; port = $Port }
    $listeners = @(Get-OctoDevStackListener -Port $Port)
    $target = @($listeners | Where-Object { Test-OctoDevStackCommandLine $_.commandLine }) | Select-Object -First 1
    if (-not $target) {
        if ($listeners.Count -gt 0) {
            $who = ($listeners | ForEach-Object { "PID $($_.pid) ($($_.commandLine))" }) -join ', '
            Write-OctoDevStackResult $command $Json $false $data "Port $Port is used by $who, not by octo-devstack; nothing stopped."
            return
        }
        if (-not $Json) { Write-Host "octo-devstack is not running on port $Port." -ForegroundColor DarkGray }
        Write-OctoDevStackResult $command $Json $true $data $null
        return
    }

    $data.pid = $target.pid
    try {
        if (Test-OctoDevStackWindows) {
            Stop-Process -Id $target.pid -Force -ErrorAction Stop
        }
        else {
            Send-OctoDevStackSignal -ProcessId $target.pid -Signal 'TERM'
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Test-OctoDevStackProcessAlive -ProcessId $target.pid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            if (Test-OctoDevStackProcessAlive -ProcessId $target.pid) { Send-OctoDevStackSignal -ProcessId $target.pid -Signal 'KILL' }
        }
    }
    catch {
        Write-Verbose "Stopping PID $($target.pid): $($_.Exception.Message)"   # reported below if it is still alive
    }
    $deadline = (Get-Date).AddSeconds(5)
    while ((Test-OctoDevStackProcessAlive -ProcessId $target.pid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
    if (Test-OctoDevStackProcessAlive -ProcessId $target.pid) {
        Write-OctoDevStackResult $command $Json $false $data "Could not stop octo-devstack (PID $($target.pid))."
        return
    }
    $data.stopped = $true
    if (-not $Json) { Write-Host "octo-devstack stopped (PID $($target.pid)); the stack services keep running and are adopted by the next start." -ForegroundColor Green }
    Write-OctoDevStackResult $command $Json $true $data $null
}

Export-ModuleMember -Function @('Start-OctoDevStackDaemon', 'Stop-OctoDevStackDaemon')
