<#
.SYNOPSIS
    Install, start, stop and inspect octo-devstack, the local MCP daemon that runs the OctoMesh dev stack
    for several Claude Code sessions.

.DESCRIPTION
    octo-devstack (private repository meshmakers/octo-devstack) is a .NET 10 daemon. It exposes an MCP server
    at http://127.0.0.1:<port>/mcp, a read-only status page at http://127.0.0.1:<port>/ and GET /health.
    Its configuration is ~/.config/octo-devstack/devstack.yaml (OCTO_DEVSTACK_CONFIG), written on the first
    start; its state (service PIDs, lease, build logs) lives in ~/.local/state/octo-devstack
    (OCTO_DEVSTACK_STATE).

    The default checkout path is next to the octo-tools checkout (e.g. ~/dev/meshmakers/octo-devstack); for an
    octo-tools worktree under <octo-tools>/.claude/worktrees/<name> it is still next to the main checkout.

    Stopping the daemon never stops the stack services it started: the next daemon adopts them from its
    state file.
#>

$script:DefaultRepositoryUrl = 'git@github.com:meshmakers/octo-devstack.git'
$script:ProjectRelativePath = 'src/DevStack/DevStack.csproj'
$script:DllRelativePath = 'bin/Release/net10.0/octo-devstack.dll'
$script:LaunchAgentLabel = 'io.meshmakers.octo-devstack'

# ---------------------------------------------------------------------------------------------------------
# Small wrappers (one per OS question or external effect) so the tests can mock them.
# ---------------------------------------------------------------------------------------------------------

function Test-OctoDevStackWindows { return [bool]$IsWindows }

function Test-OctoDevStackMacOS { return [bool]$IsMacOS }

function Get-OctoDevStackDefaultPath {
    <#
    .SYNOPSIS
        <parent of the octo-tools checkout>/octo-devstack. A worktree of octo-tools
        (<octo-tools>/.claude/worktrees/<name>) resolves to the main checkout first.
    #>
    $toolsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $marker = [regex]::Match($toolsRoot, '[\\/]\.claude[\\/]worktrees[\\/]')
    if ($marker.Success) { $toolsRoot = $toolsRoot.Substring(0, $marker.Index) }
    $toolsRoot = [IO.Path]::TrimEndingDirectorySeparator($toolsRoot)
    return Join-Path (Split-Path -Parent $toolsRoot) 'octo-devstack'
}

function Resolve-OctoDevStackPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return Get-OctoDevStackDefaultPath }
    return [IO.Path]::TrimEndingDirectorySeparator($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path))
}

function Get-OctoDevStackStatePath {
    if ($env:OCTO_DEVSTACK_STATE) { return $env:OCTO_DEVSTACK_STATE }
    $home_ = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return Join-Path $home_ '.local/state/octo-devstack'
}

function Get-OctoDevStackConfigPath {
    if ($env:OCTO_DEVSTACK_CONFIG) { return $env:OCTO_DEVSTACK_CONFIG }
    $home_ = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return Join-Path $home_ '.config/octo-devstack/devstack.yaml'
}

function Get-OctoDevStackLaunchAgentPath {
    $home_ = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    return Join-Path $home_ "Library/LaunchAgents/$($script:LaunchAgentLabel).plist"
}

# The daemon is managed by launchd when the LaunchAgent is installed (macOS): start and stop go through launchctl,
# because launchd restarts a killed daemon (KeepAlive) and would race a second, hand-started one.
function Test-OctoDevStackLaunchAgent {
    return (Test-OctoDevStackMacOS) -and (Test-Path -LiteralPath (Get-OctoDevStackLaunchAgentPath))
}

function Get-OctoDevStackNativeCommand([string]$Name) {
    # The native executable, never a PowerShell alias of the same name (on Windows `kill` and `ps` are
    # aliases of Stop-Process / Get-Process). $null when it is not installed.
    $app = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app) { return $app.Source }
    return $null
}

function Get-OctoDevStackLaunchdDomain { return "gui/$(& (Get-OctoDevStackNativeCommand 'id') -u)" }

function Invoke-OctoDevStackLaunchctl {
    param([string[]]$Arguments)
    $output = & (Get-OctoDevStackNativeCommand 'launchctl') @Arguments 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
}

function Get-OctoDevStackUrls([int]$Port) {
    $base = "http://127.0.0.1:$Port"
    return [ordered]@{ url = $base; mcpUrl = "$base/mcp"; statusPage = "$base/"; healthUrl = "$base/health" }
}

function Test-OctoDevStackHealth {
    <#
    .SYNOPSIS
        $true when GET http://127.0.0.1:<port>/health answers with a success status.
    #>
    param([int]$Port)
    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-OctoDevStackListener {
    <#
    .SYNOPSIS
        The processes listening on the TCP port: [{ pid, commandLine }]. Never by process name.
    #>
    param([int]$Port)
    $result = @()
    if (Test-OctoDevStackWindows) {
        $pids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty OwningProcess -Unique)
        foreach ($processId in $pids) {
            $commandLine = (Get-CimInstance Win32_Process -Filter "ProcessId=$processId" -ErrorAction SilentlyContinue).CommandLine
            $result += [pscustomobject]@{ pid = [int]$processId; commandLine = [string]$commandLine }
        }
        return $result
    }
    foreach ($processId in @(Get-OctoDevStackListeningPids -Port $Port)) {
        $commandLine = Get-OctoDevStackProcessCommandLine -ProcessId $processId
        $result += [pscustomobject]@{ pid = [int]$processId; commandLine = $commandLine }
    }
    return $result
}

# macOS/Linux seams around the native tools (lsof, ps, kill): the tests mock these, never the tools, because
# Pester cannot mock a command that does not exist (lsof on Windows) and `ps` / `kill` are aliases there.
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

function Get-OctoDevStackCheckoutFromCommandLine([string]$CommandLine) {
    <#
    .SYNOPSIS
        The checkout a running daemon runs from: its absolute octo-devstack.dll path up to the last bin folder
        (<checkout>/bin/<cfg>/<tfm>/octo-devstack.dll -> <checkout>). $null for a relative or missing dll path.
    #>
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $tokens = @([regex]::Matches($CommandLine, '"([^"]*)"|''([^'']*)''|(\S+)') | ForEach-Object {
            if ($_.Groups[1].Success) { $_.Groups[1].Value } elseif ($_.Groups[2].Success) { $_.Groups[2].Value } else { $_.Groups[3].Value }
        })
    $dll = $tokens | Where-Object { ($_ -split '[\\/]')[-1] -eq 'octo-devstack.dll' } | Select-Object -First 1
    if (-not $dll -or $dll -notmatch '^([A-Za-z]:)?[\\/]') { return $null }
    $match = [regex]::Match($dll, '^(.+)[\\/]bin[\\/]', [Text.RegularExpressions.RegexOptions]::RightToLeft)
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

function Start-OctoDevStackDetachedUnix {
    <#
    .SYNOPSIS
        Starts `dotnet <dll> --url <url>` detached (own process group, SIGHUP ignored, stdin closed, output
        appended to the log) and returns its PID. A process started with Start-Process stays in the process
        group of pwsh, so a Ctrl+C in that terminal would stop the daemon; `set -m` gives the background job
        its own group, `nohup` lets it survive closing the window.
    #>
    param([string]$WorkingDirectory, [string]$LogPath, [string]$Dll, [string]$Url)
    $script = 'log="$0"; cd "$1" || exit 1; shift; set -m; nohup "$@" >>"$log" 2>&1 </dev/null & echo $!'
    $output = & /bin/sh -c $script $LogPath $WorkingDirectory dotnet $Dll --url $Url
    $text = (@($output) -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or $text -notmatch '^\d+$') { return $null }
    return [int]$text
}

function Save-OctoDevStackPreviousLog([string]$LogPath) {
    <#
    .SYNOPSIS
        Windows: moves <name>.log to <name>.prev.log (replacing an older one) before a start, because
        Start-Process -RedirectStandardOutput/-RedirectStandardError cannot append. One previous run is kept.
    #>
    if (-not (Test-Path -LiteralPath $LogPath)) { return }
    $previous = [IO.Path]::ChangeExtension($LogPath, '.prev.log')
    try { Move-Item -LiteralPath $LogPath -Destination $previous -Force -ErrorAction Stop }
    catch { Write-Warning "Could not keep $LogPath as $previous ($($_.Exception.Message)); it is overwritten." }
}

function Test-OctoDevStackProcessAlive([int]$ProcessId) {
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Get-OctoDevStackLogTail([string]$LogPath, [int]$Lines = 20) {
    if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
    return @(Get-Content -LiteralPath $LogPath -Tail $Lines -ErrorAction SilentlyContinue)
}

function Get-OctoDevStackGitInfo {
    <#
    .SYNOPSIS
        { branch, commit, dirty, behind } of a checkout. `behind` comes from the local remote-tracking ref
        (no fetch) and is $null when the branch has no upstream.
    #>
    param([string]$Path)
    $branch = (@(git -C $Path rev-parse --abbrev-ref HEAD 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0) { $branch = $null }
    $commit = (@(git -C $Path rev-parse --short HEAD 2>$null) -join '').Trim()
    if ($LASTEXITCODE -ne 0) { $commit = $null }
    $porcelain = @(git -C $Path status --porcelain 2>$null)
    $dirty = if ($LASTEXITCODE -eq 0) { @($porcelain | Where-Object { $_ }).Count -gt 0 } else { $null }
    $behindText = (@(git -C $Path rev-list --count 'HEAD..@{u}' 2>$null) -join '').Trim()
    $behind = if ($LASTEXITCODE -eq 0 -and $behindText -match '^\d+$') { [int]$behindText } else { $null }
    return [pscustomobject]@{ branch = $branch; commit = $commit; dirty = $dirty; behind = $behind }
}

function Write-OctoDevStackResult {
    param([string]$Command, [bool]$Json, [bool]$Success, [int]$ExitCode, [hashtable]$Extra)
    $global:LASTEXITCODE = $ExitCode
    if ($Json) {
        Write-OctoJson -Command $Command -Data (New-OctoActionResult -Success $Success -ExitCode $ExitCode -Extra $Extra)
    }
}

# ---------------------------------------------------------------------------------------------------------
# Install-OctoDevStack
# ---------------------------------------------------------------------------------------------------------

function Install-OctoDevStack {
    <#
    .SYNOPSIS
        Clones (or updates) and builds octo-devstack.

    .DESCRIPTION
        - Missing checkout: `git clone <RepositoryUrl> <Path>`.
        - -Update: `git fetch`, then `git pull --ff-only` when the checkout is behind its upstream. A dirty
          working tree or a branch other than main is refused (unless it is already up to date); local
          changes are never reset or discarded.
        - Then `dotnet build src/DevStack/DevStack.csproj -c Release` (skip with -NoBuild); a failed build
          fails the command.
        - -LaunchAgent (macOS): runs the repository's scripts/install-launchagent.sh after the build
          (login item, restarted by launchd when it exits). Skipped with a message on other OSes.
        A running daemon keeps running the old build: restart it (Stop-OctoDevStack; Start-OctoDevStack).

    .PARAMETER Path
        Checkout folder. Default: octo-devstack next to the octo-tools checkout.

    .PARAMETER RepositoryUrl
        Clone URL. Default: git@github.com:meshmakers/octo-devstack.git (private; needs your GitHub SSH key).

    .PARAMETER Json
        { success, exitCode, path, commit, cloned, updated, built, dll, launchAgent[, error] }.

    .EXAMPLE
        Install-OctoDevStack

    .EXAMPLE
        Install-OctoDevStack -Update -Json
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$RepositoryUrl = $script:DefaultRepositoryUrl,
        [switch]$Update,
        [switch]$NoBuild,
        [switch]$LaunchAgent,
        [switch]$Json
    )

    $command = 'Install-OctoDevStack'
    $repoPath = Resolve-OctoDevStackPath $Path
    $dll = Join-Path $repoPath $script:DllRelativePath
    $state = [ordered]@{ path = $repoPath; commit = $null; cloned = $false; updated = $false; built = $false; dll = $dll; launchAgent = $null }

    $fail = {
        param([string]$message, [int]$code = 1)
        $state.commit = (Get-OctoDevStackGitInfo -Path $repoPath).commit
        $extra = @{}; foreach ($k in $state.Keys) { $extra[$k] = $state[$k] }
        $extra.error = $message
        Write-OctoDevStackResult -Command $command -Json $Json -Success $false -ExitCode $code -Extra $extra
        Write-Error $message
    }

    if (-not (Test-Path -LiteralPath $repoPath)) {
        $parent = Split-Path -Parent $repoPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        if (-not $Json) { Write-Host "Cloning $RepositoryUrl into $repoPath" -ForegroundColor Cyan }
        if ($Json) { $null = git clone $RepositoryUrl $repoPath 2>&1 } else { git clone $RepositoryUrl $repoPath | Out-Host }
        if ($LASTEXITCODE -ne 0) {
            & $fail "git clone $RepositoryUrl failed (exit code $LASTEXITCODE). The repository is private: check your GitHub SSH key."
            return
        }
        $state.cloned = $true
    }
    elseif (-not (Test-Path -LiteralPath (Join-Path $repoPath '.git'))) {
        & $fail "$repoPath exists but is not a git checkout. Remove it or pass -Path."
        return
    }
    elseif ($Update) {
        $null = git -C $repoPath fetch --quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            & $fail "git fetch in $repoPath failed (exit code $LASTEXITCODE)."
            return
        }
        $info = Get-OctoDevStackGitInfo -Path $repoPath
        if ($info.behind -eq 0) {
            if (-not $Json) { Write-Host "$repoPath is up to date ($($info.branch) $($info.commit))" -ForegroundColor Green }
        }
        elseif ($info.dirty) {
            & $fail "Not updated: $repoPath has local changes. Commit or stash them, then run Install-OctoDevStack -Update again (nothing was reset)."
            return
        }
        elseif ($info.branch -ne 'main') {
            & $fail "Not updated: $repoPath is on branch '$($info.branch)', not main. Switch to main (git -C $repoPath switch main) and run again."
            return
        }
        else {
            if (-not $Json) { Write-Host "Updating $repoPath (git pull --ff-only)" -ForegroundColor Cyan }
            if ($Json) { $null = git -C $repoPath pull --ff-only 2>&1 } else { git -C $repoPath pull --ff-only | Out-Host }
            if ($LASTEXITCODE -ne 0) {
                & $fail "git pull --ff-only in $repoPath failed (exit code $LASTEXITCODE); the branch may have diverged from origin. Nothing was reset."
                return
            }
            $state.updated = $true
        }
    }

    if (-not $NoBuild) {
        $project = Join-Path $repoPath $script:ProjectRelativePath
        if (-not $Json) { Write-Host "Building $project (Release)" -ForegroundColor Cyan }
        if ($Json) {
            # The build output would break the single JSON document on the success stream.
            $null = dotnet build $project -c Release 2>&1
        }
        else {
            dotnet build $project -c Release | Out-Host
        }
        if ($LASTEXITCODE -ne 0) {
            & $fail "dotnet build $project -c Release failed (exit code $LASTEXITCODE)." $LASTEXITCODE
            return
        }
        $state.built = $true
    }

    if ($LaunchAgent) {
        if (-not (Test-OctoDevStackMacOS)) {
            $state.launchAgent = 'skipped'
            if (-not $Json) { Write-Host 'The LaunchAgent is macOS only; skipped. Use Start-OctoDevStack to run the daemon.' -ForegroundColor Yellow }
        }
        elseif (-not (Test-Path -LiteralPath $dll)) {
            & $fail "The LaunchAgent needs the build ($dll); run Install-OctoDevStack without -NoBuild."
            return
        }
        else {
            $script = Join-Path $repoPath 'scripts/install-launchagent.sh'
            if ($Json) { $null = & /bin/sh $script 2>&1 } else { & /bin/sh $script | Out-Host }
            if ($LASTEXITCODE -ne 0) {
                & $fail "$script failed (exit code $LASTEXITCODE)."
                return
            }
            $state.launchAgent = 'installed'
        }
    }

    $state.commit = (Get-OctoDevStackGitInfo -Path $repoPath).commit
    $extra = @{}; foreach ($k in $state.Keys) { $extra[$k] = $state[$k] }
    Write-OctoDevStackResult -Command $command -Json $Json -Success $true -ExitCode 0 -Extra $extra
    if (-not $Json) {
        Write-Host "octo-devstack $($state.commit) in $repoPath" -ForegroundColor Green
        if ($state.built -and (Test-OctoDevStackHealth -Port 5090)) {
            Write-Host 'A daemon is running on port 5090 with the previous build; restart it: Stop-OctoDevStack; Start-OctoDevStack' -ForegroundColor Yellow
        }
        elseif ($state.built) {
            Write-Host 'Start it with: Start-OctoDevStack -RegisterClaude' -ForegroundColor Cyan
        }
    }
}

# ---------------------------------------------------------------------------------------------------------
# Claude Code registration
# ---------------------------------------------------------------------------------------------------------

function Register-OctoDevStackClaude {
    <#
    .SYNOPSIS
        Adds the MCP server to Claude Code (user scope) unless `claude mcp list` already has octo-devstack with
        this URL. Returns added | present | mismatch | notFound | failed; mismatch = registered with another URL
        (nothing is changed, the commands to fix it are printed).
    #>
    param([string]$McpUrl, [bool]$Quiet)
    $addCommand = "claude mcp add --transport http --scope user octo-devstack $McpUrl"
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        if (-not $Quiet) { Write-Host "claude is not on PATH. Register the MCP server yourself: $addCommand" -ForegroundColor Yellow }
        return 'notFound'
    }
    $entries = @(@(claude mcp list 2>&1) | ForEach-Object { "$_" } | Where-Object { $_ -match '^\s*octo-devstack\b' })
    if ($entries.Count -gt 0) {
        if (@($entries | Where-Object { $_.Contains($McpUrl) }).Count -gt 0) {
            if (-not $Quiet) { Write-Host "Claude Code already knows the MCP server octo-devstack ($McpUrl)." -ForegroundColor Green }
            return 'present'
        }
        if (-not $Quiet) {
            Write-Warning "Claude Code has octo-devstack registered with another URL ($($entries[0].Trim())). To point it at $McpUrl run: claude mcp remove --scope user octo-devstack; $addCommand"
        }
        return 'mismatch'
    }
    $null = claude mcp add --transport http --scope user octo-devstack $McpUrl 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not $Quiet) { Write-Warning "Could not register the MCP server (exit code $LASTEXITCODE). Run: $addCommand" }
        return 'failed'
    }
    if (-not $Quiet) { Write-Host "Registered the MCP server octo-devstack ($McpUrl) for Claude Code (user scope)." -ForegroundColor Green }
    return 'added'
}

# ---------------------------------------------------------------------------------------------------------
# Start-OctoDevStack
# ---------------------------------------------------------------------------------------------------------

function Start-OctoDevStack {
    <#
    .SYNOPSIS
        Starts the octo-devstack daemon on http://127.0.0.1:<Port> (default in the background).

    .DESCRIPTION
        - octo-devstack already answers /health on the port: reports "already running" (PID of the listener)
          and starts nothing. Another program answering /health on the port is refused.
        - The macOS LaunchAgent is installed: launchd starts it (`launchctl bootstrap`, `kickstart` when already
          loaded) instead of a second, hand-started daemon.
        - Another process listens on the port without answering /health: refused, the process is named.
        - The build is missing: refused with a hint to run Install-OctoDevStack (or builds with -Build).
        - Default: started detached. macOS/Linux: in its own process group with SIGHUP ignored, so neither
          Ctrl+C nor closing the pwsh window stops it; Windows: Start-Process -WindowStyle Hidden. Output goes
          to <state>/daemon.log. macOS/Linux append to it; on Windows stdout and stderr go to daemon.log and
          daemon.err.log, which Start-Process cannot append to, so the previous run's files are first moved to
          daemon.prev.log / daemon.err.prev.log (one run kept). Then /health is polled for up to
          -HealthTimeoutSeconds.
        - -Foreground: runs in this console (Ctrl+C stops the daemon and, same process group, its services).
          -Json is not supported with -Foreground.
        - -RegisterClaude: adds the MCP server to Claude Code (`claude mcp add --transport http --scope user
          octo-devstack <url>/mcp`) unless `claude mcp list` already has octo-devstack with this URL. Registered
          with another URL: reported as `mismatch` with the commands to fix it, nothing is changed. Without claude
          on PATH the command is printed. No secret is passed.

    .PARAMETER Json
        { success, exitCode, alreadyRunning, started, pid, port, url, mcpUrl, statusPage, logPath, dll,
          claudeRegistration, launchAgent[, error, logTail] }. claudeRegistration: added | present | mismatch |
          notFound | failed | null. launchAgent: true when started through the macOS LaunchAgent.

    .EXAMPLE
        Start-OctoDevStack -RegisterClaude
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$Port = 5090,
        [switch]$Foreground,
        [switch]$Build,
        [switch]$RegisterClaude,
        [int]$HealthTimeoutSeconds = 30,
        [switch]$Json
    )

    $command = 'Start-OctoDevStack'
    if ($Foreground -and $Json) {
        Write-Error '-Json is not supported with -Foreground (the command blocks until the daemon exits).'
        $global:LASTEXITCODE = 1
        return
    }

    $repoPath = Resolve-OctoDevStackPath $Path
    $dll = Join-Path $repoPath $script:DllRelativePath
    $urls = Get-OctoDevStackUrls $Port
    $statePath = Get-OctoDevStackStatePath
    $logPath = Join-Path $statePath 'daemon.log'
    $result = [ordered]@{
        alreadyRunning = $false; started = $false; pid = $null; port = $Port
        url = $urls.url; mcpUrl = $urls.mcpUrl; statusPage = $urls.statusPage
        logPath = $logPath; dll = $dll; claudeRegistration = $null; launchAgent = $false
    }
    $finish = {
        param([bool]$success, [string]$message)
        $extra = @{}; foreach ($k in $result.Keys) { $extra[$k] = $result[$k] }
        if ($message) { $extra.error = $message }
        Write-OctoDevStackResult -Command $command -Json $Json -Success $success -ExitCode ([int](-not $success)) -Extra $extra
        if (-not $success) { Write-Error $message }
    }

    if (Test-OctoDevStackHealth -Port $Port) {
        $listeners = @(Get-OctoDevStackListener -Port $Port)
        $listener = @($listeners | Where-Object { Test-OctoDevStackCommandLine $_.commandLine }) | Select-Object -First 1
        if ($listeners.Count -gt 0 -and -not $listener) {
            # Something answers /health on the port, but it is not octo-devstack.
            $who = ($listeners | ForEach-Object { "PID $($_.pid) ($($_.commandLine))" }) -join ', '
            & $finish $false "Port $Port is in use by $who, which is not octo-devstack. Stop that process or pass -Port."
            return
        }
        $result.alreadyRunning = $true
        $result.pid = if ($listener) { $listener.pid } else { $null }
        if (-not $Json) {
            $pidText = if ($result.pid) { " (PID $($result.pid))" } else { '' }
            Write-Host "octo-devstack is already running on $($urls.url)$pidText - nothing started." -ForegroundColor Green
            Write-Host "  MCP:         $($urls.mcpUrl)"
            Write-Host "  Status page: $($urls.statusPage)"
        }
        if ($RegisterClaude) { $result.claudeRegistration = Register-OctoDevStackClaude -McpUrl $urls.mcpUrl -Quiet $Json }
        & $finish $true $null
        return
    }

    $foreign = @(Get-OctoDevStackListener -Port $Port)
    if ($foreign.Count -gt 0) {
        $who = ($foreign | ForEach-Object { "PID $($_.pid) ($($_.commandLine))" }) -join ', '
        & $finish $false "Port $Port is in use by $who and /health does not answer. Stop that process or pass -Port."
        return
    }

    if (-not (Test-Path -LiteralPath $dll)) {
        if (-not $Build) {
            & $finish $false "octo-devstack is not built ($dll missing). Run Install-OctoDevStack (or Start-OctoDevStack -Build)."
            return
        }
        if (-not (Test-Path -LiteralPath (Join-Path $repoPath $script:ProjectRelativePath))) {
            & $finish $false "No octo-devstack checkout in $repoPath. Run Install-OctoDevStack first."
            return
        }
        $project = Join-Path $repoPath $script:ProjectRelativePath
        if ($Json) { $null = dotnet build $project -c Release 2>&1 } else { dotnet build $project -c Release | Out-Host }
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dll)) {
            & $finish $false "dotnet build $project -c Release failed (exit code $LASTEXITCODE)."
            return
        }
    }

    if ($Foreground) {
        Write-Host "Starting octo-devstack in the foreground on $($urls.url) (Ctrl+C stops it and the services it started)" -ForegroundColor Cyan
        if ($RegisterClaude) { $null = Register-OctoDevStackClaude -McpUrl $urls.mcpUrl -Quiet $false }
        Push-Location $repoPath
        try { dotnet $dll --url $urls.url }
        finally { Pop-Location }
        return
    }

    if (-not (Test-Path -LiteralPath $statePath)) { New-Item -ItemType Directory -Force -Path $statePath | Out-Null }
    if (Test-OctoDevStackLaunchAgent) {
        # Installed as a LaunchAgent: let launchd start it (it logs to <state>/daemon.log as well).
        $result.launchAgent = $true
        $domain = Get-OctoDevStackLaunchdDomain
        $boot = Invoke-OctoDevStackLaunchctl -Arguments @('bootstrap', $domain, (Get-OctoDevStackLaunchAgentPath))
        if ($boot.ExitCode -ne 0) {
            # Already loaded (e.g. exited and throttled): ask launchd to start it now.
            $kick = Invoke-OctoDevStackLaunchctl -Arguments @('kickstart', "$domain/$($script:LaunchAgentLabel)")
            if ($kick.ExitCode -ne 0) {
                & $finish $false "launchctl could not start $($script:LaunchAgentLabel): $($boot.Output) $($kick.Output)".Trim()
                return
            }
        }
        $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
        while (-not (Test-OctoDevStackHealth -Port $Port) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (-not (Test-OctoDevStackHealth -Port $Port)) {
            $result.logTail = @(Get-OctoDevStackLogTail -LogPath $logPath)
            & $finish $false "octo-devstack (LaunchAgent $($script:LaunchAgentLabel)) does not answer $($urls.healthUrl) after $HealthTimeoutSeconds s; see $logPath."
            return
        }
        $listener = @(Get-OctoDevStackListener -Port $Port | Where-Object { Test-OctoDevStackCommandLine $_.commandLine }) | Select-Object -First 1
        $result.pid = if ($listener) { $listener.pid } else { $null }
        $result.started = $true
        if (-not $Json) {
            Write-Host "octo-devstack is running (LaunchAgent$(if ($result.pid) { ", PID $($result.pid)" }))" -ForegroundColor Green
            Write-Host "  MCP:         $($urls.mcpUrl)"
            Write-Host "  Status page: $($urls.statusPage)"
            Write-Host "  Log:         $logPath"
        }
        if ($RegisterClaude) { $result.claudeRegistration = Register-OctoDevStackClaude -McpUrl $urls.mcpUrl -Quiet $Json }
        & $finish $true $null
        return
    }
    if (Test-OctoDevStackWindows) {
        # Start-Process can only overwrite its redirect targets: keep the previous run's output first.
        $errLogPath = Join-Path $statePath 'daemon.err.log'
        Save-OctoDevStackPreviousLog -LogPath $logPath
        Save-OctoDevStackPreviousLog -LogPath $errLogPath
        $process = Start-Process -FilePath 'dotnet' -ArgumentList @($dll, '--url', $urls.url) -WorkingDirectory $repoPath `
            -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $errLogPath -PassThru
        $processId = if ($process) { [int]$process.Id } else { $null }
    }
    else {
        $processId = Start-OctoDevStackDetachedUnix -WorkingDirectory $repoPath -LogPath $logPath -Dll $dll -Url $urls.url
    }
    if (-not $processId) {
        & $finish $false "Could not start dotnet $dll; see $logPath."
        return
    }
    $result.pid = $processId
    if (-not $Json) { Write-Host "Started octo-devstack (PID $processId), waiting for $($urls.healthUrl)" -ForegroundColor Cyan }

    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)
    $healthy = $false
    while ($true) {
        if (Test-OctoDevStackHealth -Port $Port) { $healthy = $true; break }
        if (-not (Test-OctoDevStackProcessAlive -ProcessId $processId)) { break }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $healthy) {
        $alive = Test-OctoDevStackProcessAlive -ProcessId $processId
        $result.logTail = @(Get-OctoDevStackLogTail -LogPath $logPath)
        $why = if ($alive) { "does not answer $($urls.healthUrl) after $HealthTimeoutSeconds s (still running)" } else { 'exited' }
        if (-not $Json -and $result.logTail.Count) { $result.logTail | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray } }
        & $finish $false "octo-devstack (PID $processId) $why; see $logPath."
        return
    }

    $result.started = $true
    if (-not $Json) {
        Write-Host "octo-devstack is running (PID $processId)" -ForegroundColor Green
        Write-Host "  MCP:         $($urls.mcpUrl)"
        Write-Host "  Status page: $($urls.statusPage)"
        Write-Host "  Log:         $logPath"
    }
    if ($RegisterClaude) { $result.claudeRegistration = Register-OctoDevStackClaude -McpUrl $urls.mcpUrl -Quiet $Json }
    & $finish $true $null
}

# ---------------------------------------------------------------------------------------------------------
# Stop-OctoDevStack
# ---------------------------------------------------------------------------------------------------------

function Stop-OctoDevStack {
    <#
    .SYNOPSIS
        Stops the octo-devstack daemon listening on the port; the stack services it started keep running.

    .DESCRIPTION
        Only the process that listens on the port AND whose command line names octo-devstack.dll is stopped
        (lsof + ps on macOS/Linux, Get-NetTCPConnection + Win32_Process on Windows) - never by name pattern.
        Another process on the port is refused. macOS/Linux: SIGTERM, after -TimeoutSeconds SIGKILL;
        Windows: Stop-Process. The services the daemon started keep running and are adopted by the next
        start. With the macOS LaunchAgent installed the daemon is stopped through launchd (`launchctl bootout`),
        so launchd does not start it again; Start-OctoDevStack loads it again (`launchctl bootstrap`). -Port must
        be the port the agent's daemon listens on: a foreign listener is refused and nothing is unloaded.

    .PARAMETER Json
        { success, exitCode, stopped, pid, port, launchAgent, note[, error] }.
    #>
    [CmdletBinding()]
    param(
        [int]$Port = 5090,
        [int]$TimeoutSeconds = 15,
        [switch]$Json
    )

    $command = 'Stop-OctoDevStack'
    $note = 'Stack services the daemon started keep running; the next Start-OctoDevStack adopts them.'
    $launchAgent = Test-OctoDevStackLaunchAgent
    $result = [ordered]@{ stopped = $false; pid = $null; port = $Port; launchAgent = [bool]$launchAgent; note = $note }
    $finish = {
        param([bool]$success, [string]$message)
        $extra = @{}; foreach ($k in $result.Keys) { $extra[$k] = $result[$k] }
        if ($message) { $extra.error = $message }
        Write-OctoDevStackResult -Command $command -Json $Json -Success $success -ExitCode ([int](-not $success)) -Extra $extra
        if (-not $success) { Write-Error $message }
    }

    if ($launchAgent) {
        # Managed by launchd: unload the job, so KeepAlive does not start it again - but only when the listener on
        # -Port (which must be the agent's port) is octo-devstack.
        $agentListeners = @(Get-OctoDevStackListener -Port $Port)
        $target = @($agentListeners | Where-Object { Test-OctoDevStackCommandLine $_.commandLine }) | Select-Object -First 1
        if (-not $target) {
            if ($agentListeners.Count -gt 0) {
                $who = ($agentListeners | ForEach-Object { "PID $($_.pid) ($($_.commandLine))" }) -join ', '
                & $finish $false "Port $Port is used by $who, not by octo-devstack.dll; nothing stopped, the LaunchAgent stays loaded."
                return
            }
            if (-not $Json) { Write-Host "octo-devstack is not running on port $Port; the LaunchAgent was left as it is." -ForegroundColor DarkGray }
            & $finish $true $null
            return
        }
        $result.pid = $target.pid
        $out = Invoke-OctoDevStackLaunchctl -Arguments @('bootout', "$(Get-OctoDevStackLaunchdDomain)/$($script:LaunchAgentLabel)")
        if ($out.ExitCode -ne 0) {
            & $finish $false "launchctl bootout $($script:LaunchAgentLabel) failed: $($out.Output)"
            return
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Test-OctoDevStackProcessAlive -ProcessId $target.pid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-OctoDevStackProcessAlive -ProcessId $target.pid) { Stop-Process -Id $target.pid -Force -ErrorAction SilentlyContinue }
        if (Test-OctoDevStackProcessAlive -ProcessId $target.pid) {
            & $finish $false "octo-devstack (PID $($target.pid)) is still running after launchctl bootout and Stop-Process."
            return
        }
        $result.stopped = $true
        if (-not $Json) { Write-Host "octo-devstack stopped (LaunchAgent unloaded). $note" -ForegroundColor Green }
        & $finish $true $null
        return
    }

    $listeners = @(Get-OctoDevStackListener -Port $Port)
    $targets = @($listeners | Where-Object { Test-OctoDevStackCommandLine $_.commandLine })
    if ($targets.Count -eq 0) {
        if ($listeners.Count -gt 0) {
            $who = ($listeners | ForEach-Object { "PID $($_.pid) ($($_.commandLine))" }) -join ', '
            & $finish $false "Port $Port is used by $who, not by octo-devstack.dll; nothing stopped."
            return
        }
        if (-not $Json) { Write-Host "octo-devstack is not running on port $Port." -ForegroundColor DarkGray }
        & $finish $true $null
        return
    }

    $target = $targets[0]
    $result.pid = $target.pid
    if (-not $Json) { Write-Host "Stopping octo-devstack (PID $($target.pid))" -ForegroundColor Cyan }
    try {
        if (Test-OctoDevStackWindows) {
            Stop-Process -Id $target.pid -Force -ErrorAction Stop
        }
        else {
            Send-OctoDevStackSignal -ProcessId $target.pid -Signal TERM
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Test-OctoDevStackProcessAlive -ProcessId $target.pid) -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 500
            }
            if (Test-OctoDevStackProcessAlive -ProcessId $target.pid) {
                if (-not $Json) { Write-Host "Still running after $TimeoutSeconds s; killing it." -ForegroundColor Yellow }
                Stop-Process -Id $target.pid -Force -ErrorAction Stop
            }
        }
    }
    catch {
        if (Test-OctoDevStackProcessAlive -ProcessId $target.pid) {
            & $finish $false "Could not stop octo-devstack (PID $($target.pid)): $($_.Exception.Message)"
            return
        }
    }
    $result.stopped = $true
    if (-not $Json) {
        Write-Host "octo-devstack stopped. $note" -ForegroundColor Green
    }
    & $finish $true $null
}

# ---------------------------------------------------------------------------------------------------------
# Get-OctoDevStackStatus
# ---------------------------------------------------------------------------------------------------------

function Get-OctoDevStackStatus {
    <#
    .SYNOPSIS
        Read-only: is octo-devstack installed, built, up to date and running?

    .DESCRIPTION
        Without -Path the checkout reported (path, git info, dllBuilt, dll) is the one the running daemon runs
        from, taken from its command line (<checkout>/bin/.../octo-devstack.dll); when no daemon runs, or its
        dll path is relative, it is the default checkout. `pathSource` says which (parameter | daemon |
        default), `defaultPath` is always the default checkout.

        `behind` is the number of commits the checkout is behind its upstream according to the local
        remote-tracking ref (no fetch; run Install-OctoDevStack -Update to fetch and update), $null without an
        upstream.

    .PARAMETER Json
        data: { installed, path, pathSource, defaultPath, branch, commit, dirty, behind, dllBuilt, dll, running, pid, healthy, port,
                url, mcpUrl, statusPage, configPath, logPath, statePath, launchAgent }.
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [int]$Port = 5090,
        [switch]$Json
    )

    $urls = Get-OctoDevStackUrls $Port
    $statePath = Get-OctoDevStackStatePath
    $listeners = @(Get-OctoDevStackListener -Port $Port)
    $listener = @($listeners | Where-Object { Test-OctoDevStackCommandLine $_.commandLine }) | Select-Object -First 1
    $defaultPath = Get-OctoDevStackDefaultPath
    $daemonPath = if ($listener) { Get-OctoDevStackCheckoutFromCommandLine $listener.commandLine } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($Path)) { $repoPath = Resolve-OctoDevStackPath $Path; $pathSource = 'parameter' }
    elseif ($daemonPath) { $repoPath = $daemonPath; $pathSource = 'daemon' }
    else { $repoPath = $defaultPath; $pathSource = 'default' }
    $dll = Join-Path $repoPath $script:DllRelativePath
    $installed = Test-Path -LiteralPath (Join-Path $repoPath '.git')
    $git = if ($installed) { Get-OctoDevStackGitInfo -Path $repoPath } else { [pscustomobject]@{ branch = $null; commit = $null; dirty = $null; behind = $null } }
    # A process that answers /health but is visibly not octo-devstack does not count as running octo-devstack.
    $healthy = (Test-OctoDevStackHealth -Port $Port) -and -not ($listeners.Count -gt 0 -and -not $listener)
    $launchAgent = if (Test-OctoDevStackMacOS) { Test-Path -LiteralPath (Get-OctoDevStackLaunchAgentPath) } else { $null }

    $status = [ordered]@{
        installed  = [bool]$installed
        path       = $repoPath
        pathSource = $pathSource
        defaultPath = $defaultPath
        branch     = $git.branch
        commit     = $git.commit
        dirty      = $git.dirty
        behind     = $git.behind
        dllBuilt   = [bool](Test-Path -LiteralPath $dll)
        dll        = $dll
        running    = [bool]($healthy -or $listener)
        pid        = if ($listener) { $listener.pid } else { $null }
        healthy    = [bool]$healthy
        port       = $Port
        url        = $urls.url
        mcpUrl     = $urls.mcpUrl
        statusPage = $urls.statusPage
        configPath = Get-OctoDevStackConfigPath
        logPath    = Join-Path $statePath 'daemon.log'
        statePath  = $statePath
        launchAgent = $launchAgent
    }

    if ($Json) {
        Write-OctoJson -Command 'Get-OctoDevStackStatus' -Data $status
        return
    }

    $yesNo = { param($v) if ($null -eq $v) { 'n/a' } elseif ($v) { 'yes' } else { 'no' } }
    Write-Host 'octo-devstack' -ForegroundColor Cyan
    Write-Host ("  Installed:   {0}  {1}" -f (& $yesNo $status.installed), $status.path) -ForegroundColor ($(if ($status.installed) { 'Green' } else { 'Yellow' }))
    if ($pathSource -eq 'daemon') {
        Write-Host "               (checkout of the running daemon$(if ($repoPath -ne $defaultPath) { "; default checkout: $defaultPath" }))" -ForegroundColor DarkGray
    }
    if ($status.installed) {
        $behindText = if ($null -eq $status.behind) { 'no upstream' } elseif ($status.behind -eq 0) { 'up to date (last fetch)' } else { "$($status.behind) commit(s) behind - Install-OctoDevStack -Update" }
        Write-Host ("  Checkout:    {0} {1}{2}, {3}" -f $status.branch, $status.commit, $(if ($status.dirty) { ' (local changes)' } else { '' }), $behindText)
    }
    Write-Host ("  Built:       {0}  {1}" -f (& $yesNo $status.dllBuilt), $status.dll) -ForegroundColor ($(if ($status.dllBuilt) { 'Green' } else { 'Yellow' }))
    $runText = if ($status.healthy) { "yes (PID $(if ($status.pid) { $status.pid } else { 'unknown' }), healthy)" } elseif ($status.running) { "process $($status.pid) listens, /health does not answer" } else { 'no - Start-OctoDevStack' }
    Write-Host "  Running:     $runText" -ForegroundColor ($(if ($status.healthy) { 'Green' } else { 'Yellow' }))
    Write-Host "  MCP:         $($status.mcpUrl)"
    Write-Host "  Status page: $($status.statusPage)"
    Write-Host "  Config:      $($status.configPath)"
    Write-Host "  Log:         $($status.logPath)"
    if ($null -ne $status.launchAgent) { Write-Host "  LaunchAgent: $(& $yesNo $status.launchAgent)" }
}

Export-ModuleMember -Function @('Install-OctoDevStack', 'Start-OctoDevStack', 'Stop-OctoDevStack', 'Get-OctoDevStackStatus')
