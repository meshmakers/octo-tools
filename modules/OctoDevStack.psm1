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
    Stopping the daemon never stops the stack services it started; the next daemon adopts them. Builds go on
    too (the next daemon re-attaches to them), but other sessions poll them: Stop-OctoDevStackDaemon and
    Start-OctoDevStackDaemon -Restart ask the daemon first (GET /api/daemon, restart.safe) and refuse while a
    build runs or waits unless -Force is given (AB#8812).
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

function Get-OctoDevStackToolsPath {
    # The octo-tools checkout this module belongs to: the one the daemon asks for the workspace.
    return [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')))
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

function Get-OctoDevStackHealth([int]$Port) {
    # The /health document ({ status, pid, version, commit, development, ... }), $null when nothing answers.
    try { return Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 -ErrorAction Stop }
    catch { return $null }
}

function Get-OctoDevStackDaemonStatus([int]$Port) {
    # GET /api/daemon (read-only): { daemon: { pid, version, commit, development, ... }, restart: { safe, blockers,
    # warnings, builds, leases }, history }. $null when the daemon does not have the endpoint (a version before
    # AB#8812 answers 404) or does not answer in time. The tests mock this seam; they never call a daemon.
    try { return Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/daemon" -TimeoutSec 3 -ErrorAction Stop }
    catch { return $null }
}

function Get-OctoDevStackRestartCheck([int]$Port) {
    # What the daemon says about a restart now, in one shape: available = it has the check; safe = no build runs
    # or waits; blockers / warnings as it words them; version / commit / development of the running binaries.
    $status = Get-OctoDevStackDaemonStatus -Port $Port
    $restart = if ($status) { $status.restart } else { $null }
    if (-not $restart -or $null -eq $restart.safe) {
        return [pscustomobject]@{ available = $false; safe = $null; blockers = @(); warnings = @(); version = $null; commit = $null; development = $null }
    }
    return [pscustomobject]@{
        available   = $true
        safe        = [bool]$restart.safe
        blockers    = @($restart.blockers | Where-Object { $_ } | ForEach-Object { [string]$_ })
        warnings    = @($restart.warnings | Where-Object { $_ } | ForEach-Object { [string]$_ })
        version     = if ($status.daemon) { $status.daemon.version } else { $null }
        commit      = if ($status.daemon) { $status.daemon.commit } else { $null }
        development = if ($status.daemon) { $status.daemon.development } else { $null }
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
        # Without lsof (minimal Linux, WSL; AB#9377) the daemon names its own pid (GET /api/daemon) - no second scan of
        # /proc here, the daemon has that. A daemon that does not answer cannot be found this way.
        $status = Get-OctoDevStackDaemonStatus -Port $Port
        if ($status -and $status.daemon.pid) { return @([int]$status.daemon.pid) }
        Write-Warning "lsof is not installed and nothing on port $Port answers as octo-devstack: cannot tell which process listens there."
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

function Get-OctoDevStackDllFromCommandLine([string]$CommandLine) {
    # The octo-devstack.dll a daemon runs, from its command line (quoted or not); $null when it names none.
    $match = [regex]::Match([string]$CommandLine, '"([^"]*octo-devstack\.dll)"|([^\s"]*octo-devstack\.dll)')
    if (-not $match.Success) { return $null }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Send-OctoDevStackCtrlBreak([int]$ProcessId, [string]$Dll) {
    # Windows (AB#9377): the daemon's own helper sends CTRL_BREAK to the console the daemon has to itself (hidden window
    # of Start-OctoDevStackDaemon) and refuses when anything else is attached to it, e.g. the shell of a daemon in the
    # foreground. $PID is the guard: the helper refuses when this session shares that console. $true = sent.
    & dotnet $Dll '--send-ctrl-break' $ProcessId $PID 'console' *> $null
    return ($LASTEXITCODE -eq 0)
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
        - octo-devstack already answers on the port: nothing is started - unless -Restart is given: then the
          daemon is asked whether a restart is safe (GET /api/daemon); while a build runs or waits it is refused
          and the builds are named, -Force restarts anyway (the builds go on and the next daemon re-attaches to
          them). A daemon without that check (older version) is restarted with a warning.
        - A daemon that the service of Install-OctoDevStackDaemonService runs (launchd, systemd; AB#9377) is restarted by
          its service manager (launchctl kickstart -k, systemctl --user restart; with -Rebuild: stopped through it, built,
          started through it), never by a second daemon of this cmdlet. While that service runs it and nothing answers
          yet, the cmdlet waits for it instead of starting one. -Json service names it. Only the service of -Port counts
          (the --url of its unit or plist): a daemon on another port, such as a test daemon, is started and restarted
          by this cmdlet as without a service.
        - -Rebuild: builds Release again before the start. Only together with -Restart or when no daemon runs
          on the port: the build replaces the binaries the running daemon was loaded from.
        - Another program holds the port: refused, the process is named.
        - No checkout: `Invoke-CloneMainRepos -devTools` clones it next to octo-tools (or pass -Path).
        - No build: built with Invoke-Build -configuration Release.
        - Background start: macOS/Linux in its own process group (neither Ctrl+C nor closing the window stops
          it), output appended to <state>/daemon.log; Windows: hidden window, the previous log kept as
          daemon.prev.log. Then /health is polled for up to -HealthTimeoutSeconds.
        - -Foreground: runs in this console.
        Claude Code: `claude mcp add --transport http --scope user octo-devstack http://127.0.0.1:<Port>/mcp`.

    .PARAMETER Restart
        Stop a running octo-devstack on the port first (see above), then start.

    .PARAMETER Force
        With -Restart: restart although builds run or wait.

    .PARAMETER Rebuild
        Build Release again (Invoke-Build) before the start.

    .PARAMETER Json
        { success, exitCode, alreadyRunning, started, restarted, built, pid, port, mcpUrl, statusPage, logPath,
          version, commit, restartSafe, blockers, warnings[, refused][, error] }. version / commit are those of
        the daemon that answers after the call; restartSafe / blockers / warnings what the daemon that ran
        before said (restartSafe null: nothing ran, or it has no check).
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$Port = 5090,
        [switch]$Foreground,
        [int]$HealthTimeoutSeconds = 30,
        [switch]$Restart,
        [switch]$Force,
        [switch]$Rebuild,
        [switch]$Json
    )

    $command = 'Start-OctoDevStackDaemon'
    $repoPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-OctoDevStackDefaultPath } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $dll = Join-Path $repoPath $script:DllRelativePath
    $url = "http://127.0.0.1:$Port"
    $statePath = Get-OctoDevStackStatePath
    $logPath = Join-Path $statePath 'daemon.log'
    $data = @{
        alreadyRunning = $false; started = $false; restarted = $false; built = $false; pid = $null; port = $Port; mcpUrl = "$url/mcp"; statusPage = "$url/"
        logPath = $logPath; version = $null; commit = $null; restartSafe = $null; blockers = @(); warnings = @()
    }

    if ($Foreground -and $Json) {
        Write-OctoDevStackResult $command $Json $false $data '-Foreground runs the daemon in this console and cannot be combined with -Json.'
        return
    }

    $listeners = @(Get-OctoDevStackListener -Port $Port)
    $ours = @($listeners | Where-Object { Test-OctoDevStackCommandLine $_.commandLine }) | Select-Object -First 1
    $stopped = $false
    if ($ours -and $Restart) {
        # Nothing to start from: leave the running daemon alone (a stop here would take the shared daemon down for good).
        if (-not (Test-Path -LiteralPath (Join-Path $repoPath 'src'))) {
            $data.alreadyRunning = $true
            $data.pid = $ours.pid
            $health = Get-OctoDevStackHealth -Port $Port
            if ($health) { $data.version = $health.version; $data.commit = $health.commit }
            Write-OctoDevStackResult $command $Json $false $data "Not restarted: no octo-devstack checkout in $repoPath - the running daemon (PID $($ours.pid)) was left alone. Run Invoke-CloneMainRepos -devTools (clones it next to octo-tools) or pass -Path."
            return
        }
        # A daemon its service manager runs (launchd, systemd; AB#9377) is restarted by it: a second daemon of our own would
        # race its KeepAlive / Restart for the port.
        $service = Get-OctoDevStackServiceState -Port $Port
        if ($service.supervised) {
            $data.service = $service.kind
            $check = Get-OctoDevStackRestartCheck -Port $Port
            $data.restartSafe = $check.safe
            $data.blockers = @($check.blockers)
            $data.warnings = @($check.warnings)
            $data.version = $check.version
            $data.commit = $check.commit
            if ($check.available -and -not $check.safe -and -not $Force) {
                $data.alreadyRunning = $true
                $data.pid = $ours.pid
                $data.refused = $true
                Write-OctoDevStackResult $command $Json $false $data "Not restarted: octo-devstack (PID $($ours.pid)) is busy: $($check.blockers -join '; '). Wait for the builds (build_list) or pass -Force - they go on and the next daemon re-attaches to them."
                return
            }
            foreach ($warning in $data.warnings) { Write-Warning $warning }
            try {
                if ($Rebuild) {
                    # The build replaces the binaries the daemon runs from: stop it through the service manager first.
                    Stop-OctoDevStackService -Service $service
                    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
                    while ((Test-OctoDevStackProcessAlive -ProcessId $ours.pid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
                    if ($Json) { Invoke-Build -repositoryPath $repoPath -configuration Release -Json | Out-Null } else { Invoke-Build -repositoryPath $repoPath -configuration Release }
                    $buildFailed = ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll))
                    $data.built = -not $buildFailed
                    # Started again also after a failed build (from the binaries there are): the service must not stay off.
                    Start-OctoDevStackService -Service $service
                    if ($buildFailed) { throw "Invoke-Build -repositoryPath $repoPath -configuration Release failed (see $(Join-Path $repoPath 'Invoke-Build.log')); the service was started again from the binaries there are." }
                }
                else {
                    Restart-OctoDevStackService -Service $service
                }
            }
            catch {
                Write-OctoDevStackResult $command $Json $false $data "Not restarted through the $($service.kind): $($_.Exception.Message)"
                return
            }
            $health = Wait-OctoDevStackNewDaemon -Port $Port -PreviousPid $ours.pid -TimeoutSeconds $HealthTimeoutSeconds
            if (-not $health) {
                Write-OctoDevStackResult $command $Json $false $data "The $($service.kind) did not bring a new octo-devstack up on $url within $HealthTimeoutSeconds s; see $logPath."
                return
            }
            $data.pid = [int]$health.pid
            $data.version = $health.version
            $data.commit = $health.commit
            $data.started = $true
            $data.restarted = $true
            if (-not $Json) { Write-Host "octo-devstack restarted by the $($service.kind) (PID $($data.pid), version $($health.version) commit $($health.commit)) - MCP $url/mcp" -ForegroundColor Green }
            Write-OctoDevStackResult $command $Json $true $data $null
            return
        }
        # The stop asks the daemon first and refuses while builds run or wait (unless -Force).
        $stop = Stop-OctoDevStackDaemon -Port $Port -Force:$Force -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $data.restartSafe = $stop.data.restartSafe
        $data.blockers = @($stop.data.blockers)
        $data.warnings = @($stop.data.warnings)
        if (-not $stop.data.success) {
            $data.alreadyRunning = $true
            $data.pid = $ours.pid
            $data.version = $stop.data.version
            $data.commit = $stop.data.commit
            if ($stop.data.refused) { $data.refused = $true }
            Write-OctoDevStackResult $command $Json $false $data "Not restarted: $($stop.data.error)"
            return
        }
        $stopped = $true
        $listeners = @()
        $ours = $null
    }
    if ($ours -or ($listeners.Count -eq 0 -and -not $stopped -and (Test-OctoDevStackHealth -Port $Port))) {
        $data.alreadyRunning = $true
        if ($ours) { $data.pid = $ours.pid }
        $health = Get-OctoDevStackHealth -Port $Port
        if ($health) { $data.version = $health.version; $data.commit = $health.commit }
        if ($Rebuild) {
            Write-OctoDevStackResult $command $Json $false $data "octo-devstack runs on $url from the binaries -Rebuild would replace. Pass -Restart with it (refused while builds run or wait), or stop the daemon first."
            return
        }
        if (-not $Json) { Write-Host "octo-devstack is already running on $url$(if ($ours) { " (PID $($ours.pid))" }) - MCP $url/mcp" -ForegroundColor Green }
        Write-OctoDevStackResult $command $Json $true $data $null
        return
    }
    if ($listeners.Count -gt 0) {
        $who = ($listeners | ForEach-Object { "PID $($_.pid) ($($_.commandLine))" }) -join ', '
        Write-OctoDevStackResult $command $Json $false $data "Port $Port is in use by $who, which is not octo-devstack. Stop it or pass -Port."
        return
    }
    # Nothing listens, but a service manager runs octo-devstack (launchd between two of its starts, systemd while it comes
    # up; AB#9377): its daemon is waited for, a second one is never started next to it.
    $service = if ($stopped) { $null } else { Get-OctoDevStackServiceState -Port $Port }
    if ($service -and $service.supervised) {
        $data.service = $service.kind
        $health = Wait-OctoDevStackNewDaemon -Port $Port -PreviousPid 0 -TimeoutSeconds $HealthTimeoutSeconds
        if (-not $health) {
            Write-OctoDevStackResult $command $Json $false $data "The $($service.kind) runs octo-devstack, but nothing answers on $url within $HealthTimeoutSeconds s; see $logPath. No second daemon was started next to it."
            return
        }
        $data.alreadyRunning = $true
        $data.pid = [int]$health.pid
        $data.version = $health.version
        $data.commit = $health.commit
        if (-not $Json) { Write-Host "octo-devstack is running under the $($service.kind) on $url (PID $($data.pid)) - MCP $url/mcp" -ForegroundColor Green }
        Write-OctoDevStackResult $command $Json $true $data $null
        return
    }
    if (-not (Test-Path -LiteralPath (Join-Path $repoPath 'src'))) {
        Write-OctoDevStackResult $command $Json $false $data "No octo-devstack checkout in $repoPath. Run Invoke-CloneMainRepos -devTools (clones it next to octo-tools) or pass -Path."
        return
    }
    if ($Rebuild -or -not (Test-Path -LiteralPath $dll)) {
        if ($Json) { Invoke-Build -repositoryPath $repoPath -configuration Release -Json | Out-Null } else { Invoke-Build -repositoryPath $repoPath -configuration Release }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll)) {
            Write-OctoDevStackResult $command $Json $false $data "Invoke-Build -repositoryPath $repoPath -configuration Release failed (see $(Join-Path $repoPath 'Invoke-Build.log'))."
            return
        }
        $data.built = $true
    }

    # The daemon asks this octo-tools for the workspace (Get-OctoWorkspace, AB#9377): it inherits OCTO_TOOLS_PATH. Without
    # it, the daemon looks next to its own checkout, which -Path may have put somewhere else.
    $previousToolsPath = $env:OCTO_TOOLS_PATH
    $env:OCTO_TOOLS_PATH = Get-OctoDevStackToolsPath
    try {
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
    }
    finally {
        $env:OCTO_TOOLS_PATH = $previousToolsPath
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
    $data.restarted = $stopped
    $health = Get-OctoDevStackHealth -Port $Port
    if ($health) { $data.version = $health.version; $data.commit = $health.commit }
    if (-not $Json) {
        $what = if ($data.version) { ", version $($data.version)$(if ($data.commit) { " commit $($data.commit)" })" } else { '' }
        Write-Host "octo-devstack is running (PID $processId$what)$(if ($stopped) { ' - restarted' })" -ForegroundColor Green
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
        program on the port is refused. macOS/Linux: SIGTERM, SIGKILL after -TimeoutSeconds; Windows: CTRL_BREAK
        through the daemon's own helper (a clean shutdown with its STOP record), Stop-Process -Force after
        -TimeoutSeconds or when the helper refuses (an older daemon, a daemon that shares its console with a
        shell). "stopped" is reported only after the process is gone; -Json "graceful" says whether it shut down
        by itself.

        Before it stops anything it asks the daemon whether a restart is safe (GET /api/daemon, read-only):
        while a build runs or waits the stop is refused and the builds and their owners are named - other
        sessions poll them. -Force stops anyway (running builds go on, queued ones are restored, the next
        daemon re-attaches to them). Sessions that hold a stack lease are listed as a warning; they do not
        block. A daemon without that check (a version before AB#8812) is stopped with a warning.

        A daemon that the service of Install-OctoDevStackDaemonService runs (AB#9377): macOS refuses the stop - launchd
        (KeepAlive) would start it again at once; restart it with Start-OctoDevStackDaemon -Restart, remove it with
        Uninstall-OctoDevStackDaemonService. Linux stops the systemd unit (systemctl --user stop; it stays enabled for
        the next login). Windows stops it and warns that the logon task starts it again within 15 minutes. Only the
        service of -Port counts: a daemon on another port is stopped by its own signal, the service is left alone.

    .PARAMETER Force
        Stop although builds run or wait.

    .PARAMETER Json
        { success, exitCode, stopped, pid, port, restartSafe, blockers, warnings, version, commit[, refused][, error] }.
        restartSafe is null when nothing ran or the daemon has no check; refused = true when the stop was
        refused because builds run or wait.
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 5090,
        [int]$TimeoutSeconds = 15,
        [switch]$Force,
        [switch]$Json
    )

    $command = 'Stop-OctoDevStackDaemon'
    $data = @{ stopped = $false; graceful = $null; pid = $null; port = $Port; restartSafe = $null; blockers = @(); warnings = @(); version = $null; commit = $null }
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
    $check = Get-OctoDevStackRestartCheck -Port $Port
    if ($check.available) {
        $data.restartSafe = $check.safe
        $data.blockers = @($check.blockers)
        $data.warnings = @($check.warnings)
        $data.version = $check.version
        $data.commit = $check.commit
        if (-not $check.safe -and -not $Force) {
            $data.refused = $true
            $why = if ($check.blockers.Count -gt 0) { $check.blockers -join '; ' } else { 'the daemon reports restart.safe = false' }
            Write-OctoDevStackResult $command $Json $false $data "octo-devstack (PID $($target.pid)) is busy, nothing stopped: $why. Wait for the builds (build_list) or pass -Force - they go on and the next daemon re-attaches to them."
            return
        }
        if (-not $check.safe) { Write-Warning "Stopping octo-devstack although it is busy (-Force): $($check.blockers -join '; ')" }
        foreach ($warning in $check.warnings) { Write-Warning $warning }
    }
    else {
        Write-Warning "octo-devstack on port $Port has no restart check (GET /api/daemon; a version before AB#8812, or it did not answer): it is stopped without knowing whether builds run."
    }

    # A daemon its service manager runs (AB#9377). launchd (KeepAlive) would start it again at once, so a stop is refused
    # there; systemd stops the unit, which stays enabled for the next login.
    $service = Get-OctoDevStackServiceState -Port $Port
    if ($service.supervised) { $data.service = $service.kind }
    if ($service.supervised -and $service.kind -eq 'launchAgent') {
        $data.refused = $true
        Write-OctoDevStackResult $command $Json $false $data ("octo-devstack (PID $($target.pid)) runs under launchd ($($service.path), KeepAlive): launchd would start it again at once, nothing stopped. " +
            'Restart it with Start-OctoDevStackDaemon -Restart; to stop it for good remove the service with Uninstall-OctoDevStackDaemonService.')
        return
    }
    if ($service.supervised -and $service.kind -eq 'systemdUser') {
        try { Stop-OctoDevStackService -Service $service }
        catch { Write-OctoDevStackResult $command $Json $false $data "Could not stop the systemd unit: $($_.Exception.Message)"; return }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 5)
        while ((Test-OctoDevStackProcessAlive -ProcessId $target.pid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-OctoDevStackProcessAlive -ProcessId $target.pid) {
            Write-OctoDevStackResult $command $Json $false $data "systemctl --user stop $script:ServiceName.service did not end octo-devstack (PID $($target.pid))."
            return
        }
        $data.stopped = $true
        $data.graceful = $true
        $data.warnings = @($data.warnings) + "The systemd unit stays enabled and starts octo-devstack again at the next login (Uninstall-OctoDevStackDaemonService removes it)."
        if (-not $Json) { Write-Host "octo-devstack stopped (systemd unit, PID $($target.pid)); the stack services keep running and are adopted by the next start." -ForegroundColor Green }
        Write-OctoDevStackResult $command $Json $true $data $null
        return
    }
    if ($service.installed -and $service.kind -eq 'scheduledTask') {
        $data.warnings = @($data.warnings) + "The logon task $($service.path) starts octo-devstack again within 15 minutes (Uninstall-OctoDevStackDaemonService removes it)."
    }
    try {
        if (Test-OctoDevStackWindows) {
            $dll = Get-OctoDevStackDllFromCommandLine $target.commandLine
            $data.graceful = [bool]($dll -and (Test-Path -LiteralPath $dll -PathType Leaf) -and (Send-OctoDevStackCtrlBreak -ProcessId $target.pid -Dll $dll))
            if ($data.graceful) {
                $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                while ((Test-OctoDevStackProcessAlive -ProcessId $target.pid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            }
            if (-not $data.graceful -or (Test-OctoDevStackProcessAlive -ProcessId $target.pid)) {
                $data.graceful = $false
                Stop-Process -Id $target.pid -Force -ErrorAction Stop
            }
        }
        else {
            Send-OctoDevStackSignal -ProcessId $target.pid -Signal 'TERM'
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Test-OctoDevStackProcessAlive -ProcessId $target.pid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
            $data.graceful = -not (Test-OctoDevStackProcessAlive -ProcessId $target.pid)
            if (-not $data.graceful) { Send-OctoDevStackSignal -ProcessId $target.pid -Signal 'KILL' }
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

# ---------------------------------------------------------------------------------------------------------
# Background service (AB#9377): the daemon starts at login on every OS. One wrapper per external effect, so the
# tests can mock them (the ScheduledTasks cmdlets exist on Windows only).
# ---------------------------------------------------------------------------------------------------------

$script:ServiceName = 'octo-devstack'
$script:WindowsTaskPath = '\OctoMesh\'

function Get-OctoDevStackServicePlatform {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

function Get-OctoDevStackSystemdUnitPath {
    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.config' }
    return Join-Path $configHome "systemd/user/$script:ServiceName.service"
}

function Get-OctoDevStackSystemdUnit([string]$RepoPath, [string]$Dll, [string]$Url, [string]$ToolsPath, [string]$Dotnet, [string]$StatePath) {
    # KillMode=process: a stop or restart of the unit ends the daemon only. The stack services it started are in the
    # unit's cgroup, and systemd's default (control-group) would kill them all; the next daemon adopts them instead,
    # like launchd's AbandonProcessGroup on macOS. Restart=on-failure: a crash restarts it, a stop (SIGTERM, exit 0) not.
    $lines = @(
        '[Unit]'
        'Description=octo-devstack - MCP daemon for the local OctoMesh dev stack'
        ''
        '[Service]'
        'Type=simple'
        "WorkingDirectory=$RepoPath"
        "ExecStart=`"$Dotnet`" `"$Dll`" --url $Url"
        "Environment=`"OCTO_TOOLS_PATH=$ToolsPath`""
        "Environment=`"PATH=$(Get-OctoDevStackServicePathValue)`""
        'Environment=DOTNET_CLI_TELEMETRY_OPTOUT=1'
    )
    if ($env:DOTNET_ROOT) { $lines += "Environment=`"DOTNET_ROOT=$env:DOTNET_ROOT`"" }
    $lines += @(
        'KillMode=process'
        'Restart=on-failure'
        'RestartSec=5'
        "StandardOutput=append:$StatePath/daemon.log"
        "StandardError=append:$StatePath/daemon.log"
        ''
        '[Install]'
        'WantedBy=default.target'
    )
    return ($lines -join "`n") + "`n"
}

function Invoke-OctoDevStackSystemctl([string[]]$Arguments) {
    $systemctl = Get-OctoDevStackNativeCommand 'systemctl'
    if (-not $systemctl) { throw 'systemctl is not installed: start the daemon in a terminal (Start-OctoDevStackDaemon) or with your own service manager.' }
    $output = & $systemctl --user @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "systemctl --user $($Arguments -join ' ') failed: $(($output | Out-String).Trim())" }
}

function Get-OctoDevStackSystemdActive {
    # `systemctl --user is-active` answers with a non-zero exit code for every state but active: not an error here.
    $systemctl = Get-OctoDevStackNativeCommand 'systemctl'
    if (-not $systemctl) { return $false }
    $output = & $systemctl --user is-active "$script:ServiceName.service" 2>$null
    return ((@($output) -join '').Trim() -eq 'active')
}

function Get-OctoDevStackLaunchAgentLabel { return "io.meshmakers.$script:ServiceName" }

function Get-OctoDevStackLaunchAgentPath {
    $home_ = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return Join-Path $home_ "Library/LaunchAgents/$(Get-OctoDevStackLaunchAgentLabel).plist"
}

function Get-OctoDevStackLaunchdDomain {
    # The user's GUI domain (gui/<uid>), where a LaunchAgent of the logged-on user lives.
    $id = Get-OctoDevStackNativeCommand 'id'
    return "gui/$((& $id -u).Trim())"
}

function Invoke-OctoDevStackLaunchctl([string[]]$Arguments, [switch]$AllowFailure) {
    # { exitCode, output }. -AllowFailure: a non-zero exit is an answer (print of a service that is not loaded), not an error.
    $launchctl = Get-OctoDevStackNativeCommand 'launchctl'
    if (-not $launchctl) { throw 'launchctl is not available: a LaunchAgent exists on macOS only.' }
    $output = & $launchctl @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0 -and -not $AllowFailure) { throw "launchctl $($Arguments -join ' ') failed ($exitCode): $text" }
    return [pscustomobject]@{ exitCode = $exitCode; output = $text }
}

function Get-OctoDevStackLaunchAgentPlist([string]$Label, [string]$RepoPath, [string]$Dll, [string]$Url, [string]$ToolsPath, [string]$Dotnet, [string]$StatePath, [string]$PathValue) {
    # KeepAlive: launchd starts the daemon again whenever it exits. AbandonProcessGroup: stopping or restarting it never
    # ends the stack services it started (they are in its process group); the next daemon adopts them. Every value is
    # XML-escaped: a folder may hold '&' or '<'.
    $e = { param([string]$value) [Security.SecurityElement]::Escape($value) }
    $log = & $e (Join-Path $StatePath 'daemon.log')
    $environment = [ordered]@{ PATH = $PathValue; HOME = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile); DOTNET_CLI_TELEMETRY_OPTOUT = '1'; OCTO_TOOLS_PATH = $ToolsPath }
    if ($env:DOTNET_ROOT) { $environment.DOTNET_ROOT = $env:DOTNET_ROOT }
    $variables = ($environment.GetEnumerator() | ForEach-Object { "    <key>$($_.Key)</key><string>$(& $e $_.Value)</string>" }) -join "`n"
    return @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(& $e $Label)</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(& $e $Dotnet)</string>
    <string>$(& $e $Dll)</string>
    <string>--url</string>
    <string>$(& $e $Url)</string>
  </array>
  <key>WorkingDirectory</key><string>$(& $e $RepoPath)</string>
  <key>EnvironmentVariables</key>
  <dict>
$variables
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
"@.Replace("`r`n", "`n") + "`n"
}

function Resolve-OctoDevStackLinkedFolder([string]$Folder) {
    # The folder with every symbolic link on its way resolved (fnm's per-shell folder is a link to a node version).
    $current = $Folder
    $rest = @()
    while ($current -and $current -ne [IO.Path]::GetPathRoot($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkTarget) {
            $target = $item.ResolveLinkTarget($true)
            if (-not $target) { return $Folder }
            $resolved = $target.FullName
            foreach ($part in $rest) { $resolved = Join-Path $resolved $part }
            return $resolved
        }
        $rest = @((Split-Path -Leaf $current)) + $rest
        $current = Split-Path -Parent $current
    }
    return $Folder
}

function Get-OctoDevStackServicePathValue([string]$PathValue = $env:PATH) {
    # PATH for a service the OS starts later (LaunchAgent, systemd unit), from the PATH of the shell that installs it:
    # without duplicates, '~' expanded (launchd and systemd do not), only folders that exist, and a folder of this shell
    # session only (fnm's fnm_multishells/<id>, removed when the shell ends) replaced by the folder it links to.
    $separator = [IO.Path]::PathSeparator
    $home_ = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($PathValue -split [regex]::Escape([string]$separator))) {
        $folder = $entry.Trim()
        if (-not $folder) { continue }
        if ($folder -eq '~') { $folder = $home_ }
        elseif ($folder.StartsWith('~/')) { $folder = Join-Path $home_ $folder.Substring(2) }
        if (-not (Test-Path -LiteralPath $folder -PathType Container -ErrorAction SilentlyContinue)) { continue }   # also a folder this user may not read
        if ($folder -match '[\\/]fnm_multishells[\\/]') { $folder = Resolve-OctoDevStackLinkedFolder $folder }
        $folder = [IO.Path]::TrimEndingDirectorySeparator($folder)
        if (-not $result.Contains($folder)) { $result.Add($folder) }
    }
    return $result -join $separator
}

function Get-OctoDevStackServicePort([string]$Definition) {
    # The port of the daemon a service definition starts: `--url <url>` of a systemd unit, a plist or `launchctl print`,
    # `-Port <n>` of the logon task's command. $null when it names none (a plist of the removed install-launchagent.sh).
    foreach ($pattern in '--url(?:\s*</string>\s*<string>|\s+)\s*https?://[^\s<"'']*?:(\d+)', '-Port\s+(\d+)') {
        $match = [regex]::Match($Definition, $pattern)
        if ($match.Success) { return [int]$match.Groups[1].Value }
    }
    return $null
}

function Get-OctoDevStackServiceState([int]$Port = 5090) {
    # The background service Install-OctoDevStackDaemonService set up on this OS for the daemon on -Port: { platform, kind,
    # path, installed, supervised (the service manager runs the daemon now and starts it again when it exits), pid, port
    # (the port of the service's daemon, $null when its definition names none) }. A service of another port is neither
    # installed nor supervised here: a development or test daemon on its own port is started and stopped like one without
    # a service, and the service's daemon is left alone. A definition without a port counts for every port.
    $platform = Get-OctoDevStackServicePlatform
    $state = [pscustomobject]@{ platform = $platform; kind = $null; path = $null; installed = $false; supervised = $false; pid = $null; port = $null }
    $definition = ''
    switch ($platform) {
        'macos' {
            $state.kind = 'launchAgent'
            $state.path = Get-OctoDevStackLaunchAgentPath
            $state.installed = Test-Path -LiteralPath $state.path
            $print = Invoke-OctoDevStackLaunchctl @('print', "$(Get-OctoDevStackLaunchdDomain)/$(Get-OctoDevStackLaunchAgentLabel)") -AllowFailure
            if ($print.exitCode -eq 0) {
                $state.supervised = $true   # loaded with KeepAlive: launchd restarts it at once
                $match = [regex]::Match($print.output, '(?m)^\s*pid = (\d+)')
                if ($match.Success) { $state.pid = [int]$match.Groups[1].Value }
                $definition = $print.output   # what launchd runs, also when the plist changed since it was loaded
            }
            if ($state.installed) { $definition += "`n" + (Get-Content -LiteralPath $state.path -Raw -ErrorAction SilentlyContinue) }
        }
        'linux' {
            $state.kind = 'systemdUser'
            $state.path = Get-OctoDevStackSystemdUnitPath
            $state.installed = Test-Path -LiteralPath $state.path
            if ($state.installed) {
                $state.supervised = [bool](Get-OctoDevStackSystemdActive)
                $definition = Get-Content -LiteralPath $state.path -Raw -ErrorAction SilentlyContinue
            }
        }
        'windows' {
            # The logon task starts the daemon every 15 minutes when it is gone; it does not run it, so it supervises nothing.
            $state.kind = 'scheduledTask'
            $state.path = "$($script:WindowsTaskPath)$($script:ServiceName)"
            $arguments = Get-OctoDevStackLogonTaskArguments -TaskName $script:ServiceName
            $state.installed = $null -ne $arguments
            $definition = $arguments
        }
    }
    $state.port = Get-OctoDevStackServicePort ([string]$definition)
    if ($null -ne $state.port -and $state.port -ne $Port) {
        $state.installed = $false
        $state.supervised = $false
        $state.pid = $null
    }
    return $state
}

function Restart-OctoDevStackService($Service) {
    # The service manager restarts the daemon (a second daemon of our own would race its KeepAlive/Restart for the port).
    if ($Service.kind -eq 'launchAgent') { Invoke-OctoDevStackLaunchctl @('kickstart', '-k', "$(Get-OctoDevStackLaunchdDomain)/$(Get-OctoDevStackLaunchAgentLabel)") | Out-Null }
    else { Invoke-OctoDevStackSystemctl @('restart', "$script:ServiceName.service") }
}

function Stop-OctoDevStackService($Service) {
    # Ends the daemon through its service manager and keeps it from coming back until Start-OctoDevStackService.
    if ($Service.kind -eq 'launchAgent') { Invoke-OctoDevStackLaunchctl @('bootout', "$(Get-OctoDevStackLaunchdDomain)/$(Get-OctoDevStackLaunchAgentLabel)") -AllowFailure | Out-Null }
    else { Invoke-OctoDevStackSystemctl @('stop', "$script:ServiceName.service") }
}

function Start-OctoDevStackService($Service) {
    if ($Service.kind -eq 'launchAgent') { Invoke-OctoDevStackLaunchctl @('bootstrap', (Get-OctoDevStackLaunchdDomain), $Service.path) | Out-Null }
    else { Invoke-OctoDevStackSystemctl @('start', "$script:ServiceName.service") }
}

function Wait-OctoDevStackNewDaemon([int]$Port, $PreviousPid, [int]$TimeoutSeconds) {
    # The /health of a daemon that is not $PreviousPid, $null after the timeout.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $health = Get-OctoDevStackHealth -Port $Port
        if ($health -and $health.pid -and [int]$health.pid -ne [int]$PreviousPid) { return $health }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-OctoDevStackWindowsTaskCommand([string]$ToolsPath, [string]$RepoPath, [int]$Port) {
    # pwsh with the octo-tools profile running Start-OctoDevStackDaemon: it does nothing while the daemon answers,
    # builds a missing Release build and starts the daemon hidden (it outlives the task's pwsh).
    $profilePath = (Join-Path $ToolsPath 'modules/profile.ps1').Replace("'", "''")
    $repo = $RepoPath.Replace("'", "''")
    $script = ". '$profilePath' *> `$null; Start-OctoDevStackDaemon -Path '$repo' -Port $Port *> `$null"
    return [pscustomobject]@{ Execute = 'pwsh.exe'; Arguments = "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command `"$script`"" }
}

function Register-OctoDevStackLogonTask([string]$TaskName, [string]$Execute, [string]$Arguments, [string]$WorkingDirectory) {
    $user = "$([Environment]::UserDomainName)\$([Environment]::UserName)"
    $action = New-ScheduledTaskAction -Execute $Execute -Argument $Arguments -WorkingDirectory $WorkingDirectory
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    # Again every 15 minutes while the user is logged on: starts the daemon after a crash, does nothing otherwise.
    $trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)).Repetition
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -TaskPath $script:WindowsTaskPath -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Starts the octo-devstack daemon (local OctoMesh dev stack, MCP on 127.0.0.1) at logon and after a crash. Install-OctoDevStackDaemonService (octo-tools).' -Force | Out-Null
}

function Get-OctoDevStackLogonTaskArguments([string]$TaskName) {
    # The arguments of the logon task's action (they name the port), $null when there is no such task.
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return $null }
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $script:WindowsTaskPath -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    return [string](@($task.Actions)[0].Arguments)
}

function Unregister-OctoDevStackLogonTask([string]$TaskName) {
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $script:WindowsTaskPath -ErrorAction SilentlyContinue
    if (-not $task) { return $false }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $script:WindowsTaskPath -Confirm:$false
    return $true
}

function Install-OctoDevStackDaemonService {
    <#
    .SYNOPSIS
        Starts the octo-devstack daemon at login (and after a crash) on Windows, Linux and macOS (AB#9377).

    .DESCRIPTION
        - Windows: a scheduled task (\OctoMesh\octo-devstack) of the current user at logon, repeated every 15 minutes,
          that runs Start-OctoDevStackDaemon with the octo-tools profile (it does nothing while the daemon answers).
        - Linux: a systemd user unit (~/.config/systemd/user/octo-devstack.service, or below $XDG_CONFIG_HOME) with
          KillMode=process - stopping or restarting the unit never ends the stack services - and Restart=on-failure.
          The daemon then runs under systemd: restart it with `systemctl --user restart octo-devstack`. To keep it
          running without a login session: `loginctl enable-linger`.
        - macOS: a LaunchAgent (~/Library/LaunchAgents/io.meshmakers.octo-devstack.plist, loaded with launchctl bootstrap)
          with KeepAlive and AbandonProcessGroup - stopping or restarting it never ends the stack services.
        Every variant passes OCTO_TOOLS_PATH (this octo-tools checkout) to the daemon; systemd and launchd get the PATH of
        this shell without duplicates, missing folders and folders of this shell session (fnm_multishells: the folder they
        link to). A missing Release build is built
        first. A daemon that already runs on the port is left alone: on Linux the unit is only enabled (it takes over at
        the next login), on macOS the install is refused (launchd would start a second one at once) - stop it first.
        Register the MCP server in Claude Code once: `claude mcp add --transport http --scope user octo-devstack http://127.0.0.1:<Port>/mcp`.

    .PARAMETER NoStart
        Register only; start nothing now.

    .PARAMETER Json
        { success, exitCode, platform, kind (scheduledTask|systemdUser|launchAgent), name, path, started, alreadyRunning, mcpUrl, built[, error] }
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$Port = 5090,
        [switch]$NoStart,
        [switch]$Json
    )

    $command = 'Install-OctoDevStackDaemonService'
    $platform = Get-OctoDevStackServicePlatform
    $repoPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-OctoDevStackDefaultPath } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $dll = Join-Path $repoPath $script:DllRelativePath
    $url = "http://127.0.0.1:$Port"
    $toolsPath = Get-OctoDevStackToolsPath
    $statePath = Get-OctoDevStackStatePath
    $data = @{ platform = $platform; kind = $null; name = $script:ServiceName; path = $null; started = $false; alreadyRunning = $false; mcpUrl = "$url/mcp"; built = $false }

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
    $data.alreadyRunning = [bool](Test-OctoDevStackHealth -Port $Port)

    try {
        switch ($platform) {
            'windows' {
                $data.kind = 'scheduledTask'
                $data.path = "$($script:WindowsTaskPath)$($script:ServiceName)"
                $task = Get-OctoDevStackWindowsTaskCommand -ToolsPath $toolsPath -RepoPath $repoPath -Port $Port
                Register-OctoDevStackLogonTask -TaskName $script:ServiceName -Execute $task.Execute -Arguments $task.Arguments -WorkingDirectory $toolsPath
                if (-not $NoStart -and -not $data.alreadyRunning) {
                    $start = Start-OctoDevStackDaemon -Path $repoPath -Port $Port -Json | ConvertFrom-Json
                    if (-not $start.data.success) { throw "the task is registered, but the daemon did not start: $($start.data.error)" }
                    $data.started = $true
                }
            }
            'linux' {
                $data.kind = 'systemdUser'
                $unitPath = Get-OctoDevStackSystemdUnitPath
                $data.path = $unitPath
                $dotnet = Get-OctoDevStackNativeCommand 'dotnet'
                if (-not $dotnet) { throw 'dotnet is not on PATH.' }
                if (-not (Test-Path -LiteralPath $statePath)) { New-Item -ItemType Directory -Force -Path $statePath | Out-Null }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $unitPath) | Out-Null
                Set-Content -LiteralPath $unitPath -Value (Get-OctoDevStackSystemdUnit -RepoPath $repoPath -Dll $dll -Url $url -ToolsPath $toolsPath -Dotnet $dotnet -StatePath $statePath) -NoNewline
                Invoke-OctoDevStackSystemctl @('daemon-reload')
                if ($NoStart -or $data.alreadyRunning) {
                    Invoke-OctoDevStackSystemctl @('enable', "$script:ServiceName.service")
                }
                else {
                    Invoke-OctoDevStackSystemctl @('enable', '--now', "$script:ServiceName.service")
                    $data.started = $true
                }
            }
            'macos' {
                $data.kind = 'launchAgent'
                $data.path = Get-OctoDevStackLaunchAgentPath
                if ($data.alreadyRunning) {
                    $service = Get-OctoDevStackServiceState -Port $Port
                    $how = if ($service.supervised) { 'remove the LaunchAgent that runs it first (Uninstall-OctoDevStackDaemonService)' } else { 'stop it first (Stop-OctoDevStackDaemon)' }
                    throw "octo-devstack already runs on $url and launchd would start a second one at once: $how, then install again."
                }
                if ($NoStart) { throw '-NoStart is not available on macOS: launchd loads the LaunchAgent at once.' }
                $dotnet = Get-OctoDevStackNativeCommand 'dotnet'
                if (-not $dotnet) { throw 'dotnet is not on PATH.' }
                if (-not (Test-Path -LiteralPath $statePath)) { New-Item -ItemType Directory -Force -Path $statePath | Out-Null }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $data.path) | Out-Null
                $plist = Get-OctoDevStackLaunchAgentPlist -Label (Get-OctoDevStackLaunchAgentLabel) -RepoPath $repoPath -Dll $dll -Url $url -ToolsPath $toolsPath `
                    -Dotnet $dotnet -StatePath $statePath -PathValue (Get-OctoDevStackServicePathValue)
                Set-Content -LiteralPath $data.path -Value $plist -NoNewline
                $domain = Get-OctoDevStackLaunchdDomain
                Invoke-OctoDevStackLaunchctl @('bootout', "$domain/$(Get-OctoDevStackLaunchAgentLabel)") -AllowFailure | Out-Null   # an older copy of it
                Invoke-OctoDevStackLaunchctl @('bootstrap', $domain, $data.path) | Out-Null
                $data.started = $true
            }
        }
    }
    catch {
        Write-OctoDevStackResult $command $Json $false $data "Could not install the $platform service: $($_.Exception.Message)"
        return
    }

    if (-not $Json) {
        Write-Host "octo-devstack starts at login ($($data.kind): $($data.path))." -ForegroundColor Green
        if ($data.alreadyRunning) { Write-Host '  A daemon already runs on the port; it was left alone.' }
        Write-Host "  MCP: $url/mcp - register once: claude mcp add --transport http --scope user octo-devstack $url/mcp"
    }
    Write-OctoDevStackResult $command $Json $true $data $null
}

function Uninstall-OctoDevStackDaemonService {
    <#
    .SYNOPSIS
        Removes what Install-OctoDevStackDaemonService set up. The stack services are left alone.

    .DESCRIPTION
        Windows: unregisters the scheduled task (a running daemon keeps running; Stop-OctoDevStackDaemon stops it).
        Linux: `systemctl --user disable --now` and the unit file (the daemon stops, its services keep running).
        macOS: launchctl bootout and the plist (launchd stops the daemon, its services keep running).

    .PARAMETER Json
        { success, exitCode, platform, kind, path, removed[, error] }
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [switch]$Json
    )

    $command = 'Uninstall-OctoDevStackDaemonService'
    $platform = Get-OctoDevStackServicePlatform
    $repoPath = if ([string]::IsNullOrWhiteSpace($Path)) { Get-OctoDevStackDefaultPath } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $data = @{ platform = $platform; kind = $null; path = $null; removed = $false }
    try {
        switch ($platform) {
            'windows' {
                $data.kind = 'scheduledTask'
                $data.path = "$($script:WindowsTaskPath)$($script:ServiceName)"
                $data.removed = [bool](Unregister-OctoDevStackLogonTask -TaskName $script:ServiceName)
            }
            'linux' {
                $data.kind = 'systemdUser'
                $unitPath = Get-OctoDevStackSystemdUnitPath
                $data.path = $unitPath
                if (Test-Path -LiteralPath $unitPath) {
                    Invoke-OctoDevStackSystemctl @('disable', '--now', "$script:ServiceName.service")
                    Remove-Item -LiteralPath $unitPath -Force
                    Invoke-OctoDevStackSystemctl @('daemon-reload')
                    $data.removed = $true
                }
            }
            'macos' {
                $data.kind = 'launchAgent'
                $data.path = Get-OctoDevStackLaunchAgentPath
                $data.removed = Test-Path -LiteralPath $data.path
                # bootout ends the daemon (SIGTERM; AbandonProcessGroup keeps the stack services) and unloads the agent.
                Invoke-OctoDevStackLaunchctl @('bootout', "$(Get-OctoDevStackLaunchdDomain)/$(Get-OctoDevStackLaunchAgentLabel)") -AllowFailure | Out-Null
                if ($data.removed) { Remove-Item -LiteralPath $data.path -Force }
            }
        }
    }
    catch {
        Write-OctoDevStackResult $command $Json $false $data "Could not remove the $platform service: $($_.Exception.Message)"
        return
    }
    if (-not $Json) {
        Write-Host $(if ($data.removed) { "Removed the octo-devstack service ($($data.kind): $($data.path)); the stack services were left alone." } else { "No octo-devstack service was installed ($($data.kind))." }) -ForegroundColor Green
    }
    Write-OctoDevStackResult $command $Json $true $data $null
}

Export-ModuleMember -Function @('Start-OctoDevStackDaemon', 'Stop-OctoDevStackDaemon', 'Install-OctoDevStackDaemonService', 'Uninstall-OctoDevStackDaemonService')
