#Requires -Modules Pester
<#
    Pester tests for Start-OctoDevStackDaemon / Stop-OctoDevStackDaemon.

    Nothing real is built, started or stopped: Invoke-Build, the lsof/ps/kill seams
    (Get-OctoDevStackListeningPids, Get-OctoDevStackProcessCommandLine, Send-OctoDevStackSignal), Start-Process,
    Stop-Process, the /health probe, the daemon's restart check (Get-OctoDevStackDaemonStatus, the seam around
    GET /api/daemon - no test ever calls a daemon) and the detached launcher are mocked. The native tools are never mocked by
    name: Pester cannot mock a command that does not exist (lsof on Windows), and `kill` / `ps` are aliases of
    Stop-Process / Get-Process there. The checkout is a fake folder in TestDrive and the state folder is
    redirected there (OCTO_DEVSTACK_STATE).

    Run:  Invoke-Pester ./tests/OctoDevStack.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'OctoDevStack.psm1') -Force

    $script:SavedState = $env:OCTO_DEVSTACK_STATE
    $env:OCTO_DEVSTACK_STATE = Join-Path $TestDrive 'state'
    $script:Dll = 'bin/Release/net10.0/octo-devstack.dll'

    # Windows-only cmdlets do not exist on macOS/Linux, Invoke-Build is not loaded here (profile.ps1 does it);
    # stubs make them mockable.
    $script:Stubs = @()
    foreach ($name in 'Get-NetTCPConnection', 'Get-CimInstance', 'Invoke-Build') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            # Invoke-Build's stub declares the parameters the mocks and their filters read.
            $stub = if ($name -eq 'Invoke-Build') { { param([string]$repositoryPath, [string]$configuration, [switch]$Json) } } else { { } }
            New-Item -Path "function:global:$name" -Value $stub | Out-Null
            $script:Stubs += $name
        }
    }

    # Never the real service managers (this machine may run the shared daemon under launchd or systemd). By default no
    # service runs the daemon: launchctl answers "not loaded" to print and refuses everything else, systemd is inactive,
    # no logon task and no unit file exist.
    Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl {
        if ($Arguments[0] -eq 'print') { return [pscustomobject]@{ exitCode = 113; output = 'Could not find service' } }
        throw "test called launchctl $($Arguments -join ' ') without a mock"
    }
    Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdActive { $false }
    Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdShow { $null }
    Mock -ModuleName OctoDevStack Test-OctoDevStackSystemdUserManager { $false }
    Mock -ModuleName OctoDevStack Get-OctoDevStackLogonTaskArguments { $null }
    Mock -ModuleName OctoDevStack Get-OctoDevStackLaunchAgentPath { Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist' }
    Mock -ModuleName OctoDevStack Get-OctoDevStackLaunchdDomain { 'gui/501' }
    $script:SavedXdgRoot = $env:XDG_CONFIG_HOME
    $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg-root'

    # A supervised LaunchAgent names its job's pid: by default 902, the listener of the tests that stop or restart it.
    function script:New-ServiceState([string]$Kind, [switch]$Supervised, [switch]$Installed, $ProcessId = $null, [string]$RepoPath = $null) {
        $platform = @{ launchAgent = 'macos'; systemdUser = 'linux'; scheduledTask = 'windows' }[$Kind]
        if ($Supervised -and $Kind -eq 'launchAgent' -and $null -eq $ProcessId) { $ProcessId = 902 }
        return [pscustomobject]@{ platform = $platform; kind = $Kind; path = (Join-Path $TestDrive "service-$Kind"); installed = [bool]($Installed -or $Supervised); supervised = [bool]$Supervised; pid = $ProcessId; port = 5090; repoPath = $RepoPath }
    }

    # What GET /api/daemon answers: idle, or busy with one running and one queued build.
    function script:New-DaemonStatus([switch]$Busy, [string[]]$Warnings = @()) {
        $blockers = if ($Busy) {
            @('build b3-104847 of reimar/AB#8797_x (env ab8797) is running (pid 22029); it would go on and be re-attached, but its owner polls it now',
                'build b4-104900 of agent-2 (repo octo-a) is queued; the next start restores it in its place')
        }
        else { @() }
        return [pscustomobject]@{
            daemon  = [pscustomobject]@{ pid = 902; version = '1.0.0'; commit = 'c343ff279dc8'; development = $false }
            restart = [pscustomobject]@{ safe = (-not $Busy); blockers = $blockers; warnings = $Warnings; builds = @(); leases = @() }
            history = @()
        }
    }

    function script:New-FakeCheckout([string]$name, [switch]$Built) {
        $path = Join-Path $TestDrive $name
        New-Item -ItemType Directory -Force -Path (Join-Path $path 'src/DevStack') | Out-Null
        if ($Built) {
            New-Item -ItemType Directory -Force -Path (Join-Path $path 'bin/Release/net10.0') | Out-Null
            Set-Content -Path (Join-Path $path $script:Dll) -Value 'fake'
        }
        return $path
    }
}

AfterAll {
    foreach ($name in $script:Stubs) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    $env:OCTO_DEVSTACK_STATE = $script:SavedState
    $env:XDG_CONFIG_HOME = $script:SavedXdgRoot
}

Describe 'OctoDevStack module surface' {
    It 'exports the daemon start and stop and the service install' {
        @((Get-Module OctoDevStack).ExportedFunctions.Keys | Sort-Object) |
            Should -Be @('Install-OctoDevStackDaemonService', 'Start-OctoDevStackDaemon', 'Stop-OctoDevStackDaemon', 'Uninstall-OctoDevStackDaemonService')
    }

    It 'defaults to a folder next to the octo-tools checkout (outside .claude/worktrees)' {
        InModuleScope OctoDevStack {
            $path = Get-OctoDevStackDefaultPath
            Split-Path -Leaf $path | Should -Be 'octo-devstack'
            $path | Should -Not -BeLike '*.claude*worktrees*'
        }
    }

    It 'resolves only executables, never a PowerShell alias of the same name' {
        InModuleScope OctoDevStack {
            # gci is an alias on every OS and no executable: on Windows `kill` / `ps` are aliases the same way.
            Get-OctoDevStackNativeCommand 'gci' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Start-OctoDevStackDaemon' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        Mock -ModuleName OctoDevStack Start-Process { [pscustomobject]@{ Id = 4242 } }
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix { 4242 }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $true }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { }
        Mock -ModuleName OctoDevStack Invoke-Build { $global:LASTEXITCODE = 0 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus }
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth { [pscustomobject]@{ status = 'ok'; pid = 4242; version = '1.0.0'; commit = 'c343ff279dc8' } }
        Mock -ModuleName OctoDevStack Stop-Process { }
        $script:KillCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Send-OctoDevStackSignal { $script:KillCalls.Add("-$Signal $ProcessId") }
    }

    Context '-Restart' {
        BeforeEach {
            Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 902 }
            Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet /x/octo-devstack/bin/Release/net10.0/octo-devstack.dll --url http://127.0.0.1:5090' }
            # 902 is the running daemon (gone after its SIGTERM), 4242 the new one.
            Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $ProcessId -ne 902 -or $script:KillCalls.Count -eq 0 }
            Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $true }
        }

        It 'stops an idle daemon, starts it again and reports the version that answers' {
            $path = New-FakeCheckout 'restart-idle' -Built

            $json = Start-OctoDevStackDaemon -Path $path -Restart -Json | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $json.data.restarted | Should -BeTrue
            $json.data.started | Should -BeTrue
            $json.data.alreadyRunning | Should -BeFalse
            $json.data.pid | Should -Be 4242
            $json.data.restartSafe | Should -BeTrue
            $json.data.version | Should -Be '1.0.0'
            $json.data.commit | Should -Be 'c343ff279dc8'
            $script:KillCalls | Should -Be @('-TERM 902')
            Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 1
            Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
        }

        It 'leaves the running daemon alone when -Path holds no checkout' {
            $path = Join-Path $TestDrive 'restart-no-checkout'

            $json = Start-OctoDevStackDaemon -Path $path -Restart -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeFalse
            $json.data.error | Should -BeLike '*no octo-devstack checkout*left alone*'
            $json.data.alreadyRunning | Should -BeTrue
            $json.data.restarted | Should -BeFalse
            $json.data.pid | Should -Be 902
            $script:KillCalls.Count | Should -Be 0
            Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
        }

        It 'refuses while builds run or wait: nothing stopped, nothing started, the builds are named' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus -Busy }
            $path = New-FakeCheckout 'restart-busy' -Built

            $json = Start-OctoDevStackDaemon -Path $path -Restart -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeFalse
            $json.data.refused | Should -BeTrue
            $json.data.restarted | Should -BeFalse
            $json.data.alreadyRunning | Should -BeTrue
            $json.data.restartSafe | Should -BeFalse
            $json.data.blockers | Should -HaveCount 2
            $json.data.error | Should -BeLike 'Not restarted:*b3-104847*-Force*'
            $script:KillCalls | Should -HaveCount 0
            Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
        }

        It 'restarts a busy daemon with -Force and still reports what was running' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus -Busy }
            $path = New-FakeCheckout 'restart-force' -Built

            $json = Start-OctoDevStackDaemon -Path $path -Restart -Force -Json -WarningAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $json.data.restarted | Should -BeTrue
            $json.data.restartSafe | Should -BeFalse
            $json.data.blockers | Should -HaveCount 2
            $script:KillCalls | Should -Be @('-TERM 902')
        }

        It 'builds Release again with -Rebuild after the stop, never under the running daemon' {
            $path = New-FakeCheckout 'restart-rebuild' -Built
            $script:BuiltWhileRunning = $null
            Mock -ModuleName OctoDevStack Invoke-Build { $script:BuiltWhileRunning = ($script:KillCalls.Count -eq 0); $global:LASTEXITCODE = 0 }

            $json = Start-OctoDevStackDaemon -Path $path -Restart -Rebuild -Json | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $json.data.built | Should -BeTrue
            $script:BuiltWhileRunning | Should -BeFalse
            Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 1 -ParameterFilter { $configuration -eq 'Release' }
        }

        It 'refuses -Rebuild without -Restart while the daemon runs from those binaries' {
            $path = New-FakeCheckout 'rebuild-running' -Built

            $json = Start-OctoDevStackDaemon -Path $path -Rebuild -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeFalse
            $json.data.alreadyRunning | Should -BeTrue
            $json.data.error | Should -BeLike '*-Rebuild would replace*-Restart*'
            $script:KillCalls | Should -HaveCount 0
            Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
        }

        It 'starts normally when nothing runs' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
            $script:HealthCalls = 0
            Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -ge 2 }
            $path = New-FakeCheckout 'restart-nothing' -Built

            $json = Start-OctoDevStackDaemon -Path $path -Restart -Json | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $json.data.started | Should -BeTrue
            $json.data.restarted | Should -BeFalse
            $json.data.restartSafe | Should -BeNullOrEmpty
            $script:KillCalls | Should -HaveCount 0
        }
    }

    It 'does nothing when octo-devstack already listens on the port' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 777 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet /x/octo-devstack/bin/Release/net10.0/octo-devstack.dll' }
        $path = New-FakeCheckout 'running' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.alreadyRunning | Should -BeTrue
        $json.data.started | Should -BeFalse
        $json.data.pid | Should -Be 777
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
    }

    It 'refuses when another program holds the port, even when it answers /health' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $true }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 555 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'node server.js' }
        $path = New-FakeCheckout 'foreign' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.alreadyRunning | Should -BeFalse
        $json.data.error | Should -BeLike '*PID 555 (node server.js)*not octo-devstack*'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'points to Invoke-CloneMainRepos -devTools when there is no checkout' {
        $json = Start-OctoDevStackDaemon -Path (Join-Path $TestDrive 'nothing-here') -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*Invoke-CloneMainRepos -devTools*'
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
    }

    It 'builds a missing dll with Invoke-Build Release, then starts' {
        $path = New-FakeCheckout 'notbuilt'
        Mock -ModuleName OctoDevStack Invoke-Build {
            New-Item -ItemType Directory -Force -Path (Join-Path $repositoryPath 'bin/Release/net10.0') | Out-Null
            Set-Content -Path (Join-Path $repositoryPath 'bin/Release/net10.0/octo-devstack.dll') -Value 'fake'
            $global:LASTEXITCODE = 0
        }
        $script:HealthCalls = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -gt 1 }

        $json = Start-OctoDevStackDaemon -Path $path -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.built | Should -BeTrue
        $json.data.started | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 1 -ParameterFilter { $repositoryPath -eq $path -and $configuration -eq 'Release' }
    }

    It 'reports a failed build and starts nothing' {
        $path = New-FakeCheckout 'brokenbuild'
        Mock -ModuleName OctoDevStack Invoke-Build { $global:LASTEXITCODE = 1 }

        $json = Start-OctoDevStackDaemon -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*Invoke-Build*failed*'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'starts detached on macOS/Linux with the dll and --url, waits for /health and reports' {
        $script:HealthCalls = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -ge 3 }
        $path = New-FakeCheckout 'startunix' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Port 5099 -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.started | Should -BeTrue
        $json.data.pid | Should -Be 4242
        $json.data.mcpUrl | Should -Be 'http://127.0.0.1:5099/mcp'
        $json.data.statusPage | Should -Be 'http://127.0.0.1:5099/'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 1 -ParameterFilter {
            $Dll -eq (Join-Path $path 'bin/Release/net10.0/octo-devstack.dll') -and $Url -eq 'http://127.0.0.1:5099' -and
            $WorkingDirectory -eq $path -and $LogPath -eq (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.log')
        }
        $script:HealthCalls | Should -Be 3
    }

    It 'tells the daemon which octo-tools describes the workspace (OCTO_TOOLS_PATH, AB#9377) and restores the variable' {
        $script:HealthCalls = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -ge 2 }
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix { $script:SeenToolsPath = $env:OCTO_TOOLS_PATH; 4242 }
        $path = New-FakeCheckout 'starttools' -Built
        $before = $env:OCTO_TOOLS_PATH
        $env:OCTO_TOOLS_PATH = 'somewhere-else'
        try {
            $json = Start-OctoDevStackDaemon -Path $path -Port 5098 -Json | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $script:SeenToolsPath | Should -Be ([IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))))
            $env:OCTO_TOOLS_PATH | Should -Be 'somewhere-else'
        }
        finally {
            $env:OCTO_TOOLS_PATH = $before
        }
    }

    It 'starts with Start-Process (hidden, redirected) on Windows and keeps the previous logs' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $true }
        Mock -ModuleName OctoDevStack Get-NetTCPConnection { }
        $script:HealthCalls = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -ge 2 }
        # not $path: inside the filter it is Start-Process's -Path alias of -FilePath
        $checkout = New-FakeCheckout 'startwin' -Built
        New-Item -ItemType Directory -Force -Path $env:OCTO_DEVSTACK_STATE | Out-Null
        Set-Content -Path (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.log') -Value 'previous stdout'
        Set-Content -Path (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.err.log') -Value 'previous stderr'

        $json = Start-OctoDevStackDaemon -Path $checkout -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.pid | Should -Be 4242
        Should -Invoke -ModuleName OctoDevStack Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'dotnet' -and $ArgumentList[0] -eq ('"' + (Join-Path $checkout 'bin/Release/net10.0/octo-devstack.dll') + '"') -and
            $ArgumentList[1] -eq '--url' -and $ArgumentList[2] -eq 'http://127.0.0.1:5090' -and
            $WindowStyle -eq 'Hidden' -and $RedirectStandardOutput -like '*daemon.log' -and $RedirectStandardError -like '*daemon.err.log'
        }
        Get-Content (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.prev.log') | Should -Be 'previous stdout'
        Get-Content (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.err.prev.log') | Should -Be 'previous stderr'
    }

    It 'refuses -Foreground with -Json before building or starting anything' {
        $path = New-FakeCheckout 'foregroundjson'

        $json = Start-OctoDevStackDaemon -Path $path -Foreground -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*-Foreground*-Json*'
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
    }

    It 'fails when the daemon exits before it is healthy' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }
        $path = New-FakeCheckout 'crash' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.started | Should -BeFalse
        $json.data.error | Should -BeLike '*exited*daemon.log*'
    }

    It 'names what a daemon that exited said last, e.g. the daemon that holds the state folder' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }
        $state = $env:OCTO_DEVSTACK_STATE
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        # macOS/Linux: stdout and stderr go into daemon.log (the start is mocked, so the test writes what the daemon would).
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix {
            Add-Content -LiteralPath (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.log') -Value @('Debug output', 'Another octo-devstack runs with the state folder /s (daemon.lock is held): nothing was adopted or recorded.', '')
            4243
        }
        $path = New-FakeCheckout 'held' -Built

        try { $json = Start-OctoDevStackDaemon -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json }
        finally { Remove-Item -LiteralPath (Join-Path $state 'daemon.log') -ErrorAction SilentlyContinue }

        $json.data.error | Should -BeLike 'octo-devstack (PID 4243) exited: Another octo-devstack runs with the state folder /s (daemon.lock is held): nothing was adopted or recorded; see *daemon.log.'
    }

    It 'sees the daemon.lock of a daemon that holds the state folder, as the daemon takes it' {
        $state = Join-Path $TestDrive 'locked-state'
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        InModuleScope OctoDevStack -Parameters @{ s = $state } { param($s) Test-OctoDevStackStateLocked -StatePath $s } | Should -BeFalse -Because 'no daemon ever ran there'

        $held = [IO.File]::Open((Join-Path $state 'daemon.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try { InModuleScope OctoDevStack -Parameters @{ s = $state } { param($s) Test-OctoDevStackStateLocked -StatePath $s } | Should -BeTrue }
        finally { $held.Dispose() }

        InModuleScope OctoDevStack -Parameters @{ s = $state } { param($s) Test-OctoDevStackStateLocked -StatePath $s } | Should -BeFalse -Because 'the daemon ended'
    }

    It 'does not take a daemon.lock this user cannot write for one another daemon holds' {
        $state = Join-Path $TestDrive 'readonly-lock-state'
        New-Item -ItemType Directory -Force -Path $state | Out-Null
        $lock = Join-Path $state 'daemon.lock'
        Set-Content -Path $lock -Value ''
        if ($IsWindows) { [IO.File]::SetAttributes($lock, [IO.FileAttributes]::ReadOnly) } else { [IO.File]::SetUnixFileMode($lock, [IO.UnixFileMode]::UserRead) }
        try {
            # root opens it anyway, and then no daemon holds it either
            InModuleScope OctoDevStack -Parameters @{ s = $state } { param($s) Test-OctoDevStackStateLocked -StatePath $s } | Should -BeFalse
        }
        finally {
            if ($IsWindows) { [IO.File]::SetAttributes($lock, [IO.FileAttributes]::Normal) } else { [IO.File]::SetUnixFileMode($lock, [IO.UnixFileMode]'UserRead, UserWrite') }
        }
    }

    It 'starts and builds nothing while another daemon holds the state folder (another port, or still starting)' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackStateLocked { $true }
        $path = New-FakeCheckout 'state-locked'

        $json = Start-OctoDevStackDaemon -Path $path -Port 5196 -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.stateLocked | Should -BeTrue
        $json.data.error | Should -BeLike 'Another octo-devstack holds the state folder*daemon.lock*Nothing was started or built*OCTO_DEVSTACK_STATE*'
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
        Should -Invoke -ModuleName OctoDevStack Start-Process -Times 0
    }
}

Describe 'Stop-OctoDevStackDaemon' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        Mock -ModuleName OctoDevStack Stop-Process { }
        $script:KillCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Send-OctoDevStackSignal { $script:KillCalls.Add("-$Signal $ProcessId") }
        Mock -ModuleName OctoDevStack Send-OctoDevStackCtrlBreak { $false }
        Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus }
    }

    Context 'restart check (GET /api/daemon)' {
        BeforeEach {
            Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 902 }
            Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet /x/octo-devstack/bin/Release/net10.0/octo-devstack.dll' }
            Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }
        }

        It 'refuses while builds run or wait and names them; nothing is signalled' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus -Busy }

            $json = Stop-OctoDevStackDaemon -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeFalse
            $json.data.exitCode | Should -Be 1
            $json.data.stopped | Should -BeFalse
            $json.data.refused | Should -BeTrue
            $json.data.restartSafe | Should -BeFalse
            $json.data.blockers | Should -HaveCount 2
            $json.data.blockers[0] | Should -BeLike 'build b3-104847 of reimar/AB#8797_x*'
            $json.data.error | Should -BeLike '*PID 902*busy, nothing stopped*b4-104900*-Force*'
            $json.data.version | Should -Be '1.0.0'
            $json.data.commit | Should -Be 'c343ff279dc8'
            $script:KillCalls | Should -HaveCount 0
            Should -Invoke -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus -Times 1 -ParameterFilter { $Port -eq 5090 }
        }

        It 'stops a busy daemon with -Force, with a warning that names the builds' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus -Busy }

            $json = Stop-OctoDevStackDaemon -Force -Json -WarningVariable warnings -WarningAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $json.data.stopped | Should -BeTrue
            $json.data.restartSafe | Should -BeFalse
            $json.data.blockers | Should -HaveCount 2
            $json.data.PSObject.Properties.Name | Should -Not -Contain 'refused'
            "$warnings" | Should -BeLike '*although it is busy (-Force)*b3-104847*'
            $script:KillCalls | Should -Be @('-TERM 902')
        }

        It 'stops an idle daemon; held leases are a warning, not a refusal' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus -Warnings "slot 'ab8797' is leased to env:ab8797 until 14:00; the lease and the running services are kept" }

            $json = Stop-OctoDevStackDaemon -Port 5099 -Json -WarningVariable warnings -WarningAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $json.data.stopped | Should -BeTrue
            $json.data.restartSafe | Should -BeTrue
            $json.data.blockers | Should -HaveCount 0
            $json.data.warnings | Should -HaveCount 1
            "$warnings" | Should -BeLike '*leased to env:ab8797*'
            Should -Invoke -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus -Times 1 -ParameterFilter { $Port -eq 5099 }
        }

        It 'stops a daemon that has no restart check, with a warning (older version, or no answer)' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { }

            $json = Stop-OctoDevStackDaemon -Json -WarningVariable warnings -WarningAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeTrue
            $json.data.stopped | Should -BeTrue
            $json.data.restartSafe | Should -BeNullOrEmpty
            "$warnings" | Should -BeLike '*has no restart check*'
            $script:KillCalls | Should -Be @('-TERM 902')
        }

        It 'does not ask a program that is not octo-devstack' {
            Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'node server.js' }

            $null = Stop-OctoDevStackDaemon -Json -ErrorAction SilentlyContinue

            Should -Invoke -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus -Times 0
        }
    }

    It 'sends SIGTERM only to the octo-devstack listener on the port' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 901; 902 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine {
            if ($ProcessId -eq 901) { 'node /tmp/other.js' } else { 'dotnet /Users/x/octo-devstack/bin/Release/net10.0/octo-devstack.dll --url http://127.0.0.1:5090' }
        }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

        $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeTrue
        $json.data.pid | Should -Be 902
        $script:KillCalls | Should -Be @('-TERM 902')
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 0
    }

    It 'sends SIGKILL after the timeout when SIGTERM is ignored' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 902 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet octo-devstack.dll' }
        $script:AliveChecks = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $script:AliveChecks++; $script:AliveChecks -le 2 }   # still alive at the loop and the check after it

        $json = Stop-OctoDevStackDaemon -TimeoutSeconds 0 -Json | ConvertFrom-Json

        $json.data.stopped | Should -BeTrue
        $script:KillCalls | Should -Be @('-TERM 902', '-KILL 902')
    }

    It 'reports a failure and not "stopped" when the process survives' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 902 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet octo-devstack.dll' }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $true }
        # A clock that moves 10 s per call, so every wait loop ends at once.
        $script:Clock = [datetime]::new(2026, 1, 1)
        Mock -ModuleName OctoDevStack Get-Date { $script:Clock = $script:Clock.AddSeconds(10); $script:Clock }

        $json = Stop-OctoDevStackDaemon -TimeoutSeconds 0 -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.stopped | Should -BeFalse
        $json.data.error | Should -BeLike '*Could not stop*902*'
    }

    It 'refuses when the port belongs to another program, stops nothing' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 901 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet Meshmakers.Octo.Identity.dll' }

        $json = Stop-OctoDevStackDaemon -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.stopped | Should -BeFalse
        $script:KillCalls | Should -HaveCount 0
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 0
    }

    It 'does not match a process that only mentions octo-devstack.dll inside another file name' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 903 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet /x/not-octo-devstack.dll.bak' }

        $json = Stop-OctoDevStackDaemon -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $script:KillCalls | Should -HaveCount 0
    }

    It 'is a successful no-op when nothing listens' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }

        $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeFalse
        $script:KillCalls | Should -HaveCount 0
    }

    It 'names http.sys for a port owned by PID 4 on Windows, stops nothing' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $true }
        Mock -ModuleName OctoDevStack Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 4 } }
        Mock -ModuleName OctoDevStack Get-CimInstance { }

        $json = Stop-OctoDevStackDaemon -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*PID 4 (http.sys*netsh http show servicestate*'
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 0
    }

    It 'stops by PID with Stop-Process on Windows' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $true }
        Mock -ModuleName OctoDevStack Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 1234 } }
        $script:MissingDll = Join-Path $TestDrive 'gone/octo-devstack/bin/Release/net10.0/octo-devstack.dll'   # never created
        Mock -ModuleName OctoDevStack Get-CimInstance { [pscustomobject]@{ CommandLine = "`"C:\Program Files\dotnet\dotnet.exe`" $script:MissingDll" } }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

        $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

        $json.data.stopped | Should -BeTrue
        $json.data.graceful | Should -BeFalse
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 1 -ParameterFilter { $Id -eq 1234 }
        Should -Invoke -ModuleName OctoDevStack Send-OctoDevStackCtrlBreak -Times 0 -Because 'the dll of the command line does not exist here'
        $script:KillCalls | Should -HaveCount 0
    }

    Context 'graceful stop on Windows (AB#9377)' {
        BeforeEach {
            $script:StopDll = Join-Path $TestDrive 'octo-devstack/bin/Release/net10.0/octo-devstack.dll'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:StopDll) | Out-Null
            Set-Content -Path $script:StopDll -Value ''
            # The checkout this octo-tools resolves: the helper only runs a dll from there.
            Mock -ModuleName OctoDevStack Get-OctoDevStackDefaultPath { Join-Path $TestDrive 'octo-devstack' }
            Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $true }
            Mock -ModuleName OctoDevStack Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 1234 } }
            Mock -ModuleName OctoDevStack Get-CimInstance { [pscustomobject]@{ CommandLine = "dotnet `"$script:StopDll`" --url http://127.0.0.1:5090" } }
        }

        It 'sends CTRL_BREAK through the daemon''s helper and waits for it to shut down by itself' {
            Mock -ModuleName OctoDevStack Send-OctoDevStackCtrlBreak { $true }
            $script:AliveChecks = 0
            Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $script:AliveChecks++; $script:AliveChecks -lt 3 }

            $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

            $json.data.stopped | Should -BeTrue
            $json.data.graceful | Should -BeTrue
            Should -Invoke -ModuleName OctoDevStack Send-OctoDevStackCtrlBreak -Times 1 -ParameterFilter { $ProcessId -eq 1234 -and $Dll -eq $script:StopDll }
            Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 0
        }

        It 'kills when the helper refuses (an older daemon, a console shared with a shell)' {
            Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

            $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

            $json.data.stopped | Should -BeTrue
            $json.data.graceful | Should -BeFalse
            Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 1 -ParameterFilter { $Id -eq 1234 }
        }

        It 'kills when the daemon has not shut down within -TimeoutSeconds' {
            Mock -ModuleName OctoDevStack Send-OctoDevStackCtrlBreak { $true }
            $script:Killed = $false
            Mock -ModuleName OctoDevStack Stop-Process { $script:Killed = $true }
            Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { -not $script:Killed }

            $json = Stop-OctoDevStackDaemon -TimeoutSeconds 0 -Json | ConvertFrom-Json

            $json.data.stopped | Should -BeTrue
            $json.data.graceful | Should -BeFalse
            Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 1
        }

        It 'never runs a dll outside the octo-devstack checkout of this octo-tools: Stop-Process instead' {
            # Another account, or a copy of that name elsewhere: the stop must not run its code.
            $foreign = Join-Path $TestDrive 'elsewhere/octo-devstack.dll'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $foreign) | Out-Null
            Set-Content -Path $foreign -Value ''
            Mock -ModuleName OctoDevStack Get-CimInstance { [pscustomobject]@{ CommandLine = "dotnet `"$foreign`" --url http://127.0.0.1:5090" } }
            Mock -ModuleName OctoDevStack Send-OctoDevStackCtrlBreak { $true }
            Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

            $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

            $json.data.stopped | Should -BeTrue
            $json.data.graceful | Should -BeFalse
            Should -Invoke -ModuleName OctoDevStack Send-OctoDevStackCtrlBreak -Times 0
            Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 1 -ParameterFilter { $Id -eq 1234 }
        }
    }


    It 'reads the dll from quoted and plain command lines' {
        InModuleScope OctoDevStack {
            Get-OctoDevStackDllFromCommandLine '"C:\Program Files\dotnet\dotnet.exe" "C:\dev\x y\octo-devstack.dll" --url u' | Should -Be 'C:\dev\x y\octo-devstack.dll'
            Get-OctoDevStackDllFromCommandLine 'dotnet /home/me/octo-devstack/bin/Release/net10.0/octo-devstack.dll --url u' | Should -Be '/home/me/octo-devstack/bin/Release/net10.0/octo-devstack.dll'
            Get-OctoDevStackDllFromCommandLine 'dotnet other.dll' | Should -BeNullOrEmpty
        }
    }
}

Describe 'The CTRL_BREAK helper process (AB#9377)' {
    BeforeAll {
        # pwsh stands in for dotnet and a script for the dll: the helper's arguments follow it like the dll's would.
        $script:Pwsh = (Get-Process -Id $PID).Path
        $script:Sleeper = Join-Path $TestDrive 'helper-sleeps.ps1'
        Set-Content -Path $script:Sleeper -Value 'Start-Sleep -Seconds 30'
        $script:Sender = Join-Path $TestDrive 'helper-sends.ps1'
        Set-Content -Path $script:Sender -Value 'exit 0'
    }

    It 'kills a helper that does not return within the timeout and reports it as not sent' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackNativeCommand { $script:Pwsh } -ParameterFilter { $Name -eq 'dotnet' }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()

        $sent = InModuleScope OctoDevStack -Parameters @{ dll = $script:Sleeper } { param($dll) Send-OctoDevStackCtrlBreak -ProcessId 4711 -Dll $dll -TimeoutSeconds 2 }

        $sent | Should -BeFalse
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 15
    }

    It 'reports a helper that ends with 0 as sent, and never throws when dotnet is missing' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackNativeCommand { $script:Pwsh } -ParameterFilter { $Name -eq 'dotnet' }
        InModuleScope OctoDevStack -Parameters @{ dll = $script:Sender } { param($dll) Send-OctoDevStackCtrlBreak -ProcessId 4711 -Dll $dll -TimeoutSeconds 30 } | Should -BeTrue

        Mock -ModuleName OctoDevStack Get-OctoDevStackNativeCommand { $null } -ParameterFilter { $Name -eq 'dotnet' }
        InModuleScope OctoDevStack { Send-OctoDevStackCtrlBreak -ProcessId 4711 -Dll 'x.dll' } | Should -BeFalse
    }
}

Describe 'Invoke-CloneMainRepos -devTools' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../modules/Invoke-CloneMainRepos.psm1') -Force
        $script:SavedRootPath = $global:rootPath
        $global:rootPath = $TestDrive
    }

    AfterAll {
        $global:rootPath = $script:SavedRootPath
    }

    It 'clones only octo-devstack, into the folder that holds the octo-tools main checkout (where the daemon looks)' {
        Mock -ModuleName Invoke-CloneMainRepos Clone-Repo { $global:LASTEXITCODE = 0 }

        $json = Invoke-CloneMainRepos -devTools -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.repositories.repo | Should -Be @('octo-devstack')
        $json.data.repositories[0].PSObject.Properties.Name | Should -Contain 'alreadyExists'
        $expected = InModuleScope OctoDevStack { Split-Path -Parent (Get-OctoDevStackDefaultPath) }
        Should -Invoke -ModuleName Invoke-CloneMainRepos Clone-Repo -Times 1 -Exactly -ParameterFilter {
            $repositoryName -eq 'octo-devstack' -and $basePath -eq $expected
        }
    }

    It 'refuses -devTools together with -branch, also as a -Json result' {
        Mock -ModuleName Invoke-CloneMainRepos Clone-Repo { }

        $json = Invoke-CloneMainRepos -devTools -branch main -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*-devTools*-branch*'
        Should -Invoke -ModuleName Invoke-CloneMainRepos Clone-Repo -Times 0
    }
}

Describe 'Install-OctoDevStackDaemonService (AB#9377)' {
    BeforeEach {
        $script:SavedXdg = $env:XDG_CONFIG_HOME
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg'
        $script:Checkout = New-FakeCheckout 'service' -Built
        $script:Systemctl = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackSystemctl { $script:Systemctl.Add($Arguments -join ' ') }
        Mock -ModuleName OctoDevStack Get-OctoDevStackNativeCommand { '/usr/bin/dotnet' } -ParameterFilter { $Name -eq 'dotnet' }
        Mock -ModuleName OctoDevStack Register-OctoDevStackLogonTask { }
        Mock -ModuleName OctoDevStack Unregister-OctoDevStackLogonTask { $true }
        $script:Launchctl = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl {
            if ($Arguments[0] -eq 'print') { return [pscustomobject]@{ exitCode = 113; output = 'Could not find service' } }
            $script:Launchctl.Add($Arguments -join ' '); [pscustomobject]@{ exitCode = 0; output = '' }
        }
        Mock -ModuleName OctoDevStack Start-OctoDevStackDaemon { '{"data":{"success":true}}' }
        # The daemon the service starts answers (never a real one: a shared daemon may run on this machine).
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth { [pscustomobject]@{ status = 'ok'; pid = 4711; version = '1.0.0'; commit = 'd774abca14f7' } }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        $script:Tools = InModuleScope OctoDevStack { Get-OctoDevStackToolsPath }
    }

    AfterEach { $env:XDG_CONFIG_HOME = $script:SavedXdg }

    It 'reports the service as started only when its daemon answers (systemd and launchd report a start before it is up)' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth { $null }
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { $script:Platform }
        foreach ($script:Platform in 'linux', 'macos') {
            $json = Install-OctoDevStackDaemonService -Path $script:Checkout -HealthTimeoutSeconds 1 -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

            $json.data.success | Should -BeFalse -Because $script:Platform
            $json.data.started | Should -BeFalse
            $json.data.error | Should -BeLike '*does not answer on http://127.0.0.1:5090 within 1 s*daemon.log*'
        }
    }

    It 'writes a systemd user unit that never ends the stack services and starts it on Linux' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'linux' }

        $json = Install-OctoDevStackDaemonService -Path $script:Checkout -Json | ConvertFrom-Json

        $json.data.error | Should -BeNullOrEmpty
        $json.data.success | Should -BeTrue
        $json.data.kind | Should -Be 'systemdUser'
        $json.data.started | Should -BeTrue
        $unit = Get-Content -Raw (Join-Path $env:XDG_CONFIG_HOME 'systemd/user/octo-devstack.service')
        $unit | Should -Match '(?m)^KillMode=process$'
        $unit | Should -Match '(?m)^Restart=on-failure$'
        $unit | Should -Match '(?m)^SuccessExitStatus=75$' -Because 'a daemon refused by the daemon.lock of another one exits with 75 and is not started again and again'
        $unit | Should -Match '(?m)^Environment=OCTO_DEVSTACK_SERVICE=systemd$'
        $unit | Should -Match ([regex]::Escape('"/usr/bin/dotnet" "' + (Join-Path $script:Checkout $script:Dll) + '" --url http://127.0.0.1:5090'))
        $unit | Should -Match ([regex]::Escape("OCTO_TOOLS_PATH=$script:Tools"))
        $script:Systemctl | Should -Be @('daemon-reload', 'enable --now octo-devstack.service')
    }

    It 'only enables the unit on Linux while a daemon already runs on the port (no second one)' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'linux' }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $true }

        $json = Install-OctoDevStackDaemonService -Path $script:Checkout -Json | ConvertFrom-Json

        $json.data.alreadyRunning | Should -BeTrue
        $json.data.started | Should -BeFalse
        $script:Systemctl | Should -Be @('daemon-reload', 'enable octo-devstack.service')
    }

    It 'registers a logon task that runs Start-OctoDevStackDaemon with the octo-tools profile on Windows, and starts the daemon' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'windows' }

        $json = Install-OctoDevStackDaemonService -Path $script:Checkout -Port 5097 -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.kind | Should -Be 'scheduledTask'
        $json.data.started | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack Register-OctoDevStackLogonTask -Times 1 -ParameterFilter {
            $TaskName -eq 'octo-devstack' -and $Execute -eq 'pwsh.exe' -and $Arguments -like '*-WindowStyle Hidden*' -and
            $Arguments -like "*$(Join-Path $script:Tools 'modules/profile.ps1')*" -and $Arguments -like "*Start-OctoDevStackDaemon -Path '$script:Checkout' -Port 5097*"
        }
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDaemon -Times 1 -ParameterFilter { $Port -eq 5097 }
    }

    It 'writes the LaunchAgent with OCTO_TOOLS_PATH on macOS and loads it with launchctl bootstrap' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }

        $json = Install-OctoDevStackDaemonService -Path $script:Checkout -Port 5097 -Json | ConvertFrom-Json

        $json.data.error | Should -BeNullOrEmpty
        $json.data.success | Should -BeTrue
        $json.data.kind | Should -Be 'launchAgent'
        $json.data.started | Should -BeTrue
        $plistPath = Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist'
        $json.data.path | Should -Be $plistPath
        $plist = [xml](Get-Content -Raw $plistPath)
        $values = @($plist.plist.dict.dict.ChildNodes | ForEach-Object { $_.InnerText })
        $values[([array]::IndexOf($values, 'OCTO_TOOLS_PATH')) + 1] | Should -Be $script:Tools
        @($plist.plist.dict.array.string) | Should -Be @('/usr/bin/dotnet', (Join-Path $script:Checkout $script:Dll), '--url', 'http://127.0.0.1:5097')
        $script:Launchctl | Should -Be @('bootout gui/501/io.meshmakers.octo-devstack', "bootstrap gui/501 $plistPath")
    }

    It 'refuses on macOS while a daemon runs, and names Uninstall when the LaunchAgent runs it' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $true }

        $json = Install-OctoDevStackDaemonService -Path $script:Checkout -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*already runs*stop it first (Stop-OctoDevStackDaemon)*'

        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised }
        $json = Install-OctoDevStackDaemonService -Path $script:Checkout -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.error | Should -BeLike '*Uninstall-OctoDevStackDaemonService*'
        $script:Launchctl | Should -HaveCount 0
    }

    It 'unloads the LaunchAgent and removes its file on macOS' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Install-OctoDevStackDaemonService -Path $script:Checkout -Json | Out-Null
        $script:Launchctl.Clear()

        $json = Uninstall-OctoDevStackDaemonService -Path $script:Checkout -Json | ConvertFrom-Json

        $json.data.removed | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist') | Should -BeFalse
        $script:Launchctl | Should -Be @('bootout gui/501/io.meshmakers.octo-devstack')
    }

    It 'keeps the plist on macOS when the job stays loaded after the bootout, and says so' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Install-OctoDevStackDaemonService -Path $script:Checkout -Json | Out-Null
        $plistPath = Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist'
        # bootout fails, print still finds the job
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl {
            if ($Arguments[0] -eq 'print') { return [pscustomobject]@{ exitCode = 0; output = 'state = running' } }
            [pscustomobject]@{ exitCode = 5; output = 'Boot-out failed: 5: Input/output error' }
        }

        $json = Uninstall-OctoDevStackDaemonService -Path $script:Checkout -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.removed | Should -BeFalse
        $json.data.error | Should -BeLike '*bootout*still loaded*'
        Test-Path $plistPath | Should -BeTrue
    }

    It 'removes the plist when the job was not loaded any more (bootout fails, print finds nothing)' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Install-OctoDevStackDaemonService -Path $script:Checkout -Json | Out-Null
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl {
            if ($Arguments[0] -eq 'print') { return [pscustomobject]@{ exitCode = 113; output = 'Could not find service' } }
            [pscustomobject]@{ exitCode = 3; output = 'Boot-out failed: 3: No such process' }
        }

        $json = Uninstall-OctoDevStackDaemonService -Path $script:Checkout -Json | ConvertFrom-Json

        $json.data.removed | Should -BeTrue
        Test-Path (Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist') | Should -BeFalse
    }

    It 'removes the unit on Linux and the task on Windows' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'linux' }
        Install-OctoDevStackDaemonService -Path $script:Checkout -NoStart -Json | Out-Null
        $script:Systemctl.Clear()

        $json = Uninstall-OctoDevStackDaemonService -Path $script:Checkout -Json | ConvertFrom-Json

        $json.data.removed | Should -BeTrue
        Test-Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user/octo-devstack.service') | Should -BeFalse
        $script:Systemctl | Should -Be @('disable --now octo-devstack.service', 'daemon-reload')

        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'windows' }
        (Uninstall-OctoDevStackDaemonService -Json | ConvertFrom-Json).data.removed | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack Unregister-OctoDevStackLogonTask -Times 1
    }
}

Describe 'Listening pids without lsof (AB#9377)' {
    It 'asks the daemon for its own pid instead of scanning the system a second time' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackNativeCommand { $null } -ParameterFilter { $Name -eq 'lsof' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus }

        $pids = InModuleScope OctoDevStack { Get-OctoDevStackListeningPids -Port 5090 }

        @($pids) | Should -Be @(902)
    }

    It 'warns and finds nothing when nothing answers as octo-devstack' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackNativeCommand { $null } -ParameterFilter { $Name -eq 'lsof' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { $null }

        $pids = InModuleScope OctoDevStack { Get-OctoDevStackListeningPids -Port 5090 3>$null }

        @($pids) | Should -HaveCount 0
    }
}

Describe 'Daemon service files (AB#9377)' {
    It 'writes a LaunchAgent plist that keeps the stack services and escapes every value' {
        $text = InModuleScope OctoDevStack {
            Get-OctoDevStackLaunchAgentPlist -Label 'io.meshmakers.octo-devstack' -RepoPath '/x/R&D <dev>/octo-devstack' -Dll '/x/R&D <dev>/octo-devstack/bin/Release/net10.0/octo-devstack.dll' `
                -Url 'http://127.0.0.1:5090' -ToolsPath '/x/R&D <dev>/octo-tools' -Dotnet '/usr/local/share/dotnet/dotnet' -StatePath '/s' -PathValue '/a&b:/usr/bin'
        }

        $plist = [xml]$text   # escaped, so it is well-formed
        $dict = $plist.plist.dict
        $keys = @($dict.key)
        $keys | Should -Contain 'KeepAlive'
        $keys | Should -Contain 'AbandonProcessGroup'
        @($dict.array.string) | Should -Be @('/usr/local/share/dotnet/dotnet', '/x/R&D <dev>/octo-devstack/bin/Release/net10.0/octo-devstack.dll', '--url', 'http://127.0.0.1:5090')
        $environment = @{}
        $nodes = @($dict.dict.ChildNodes)
        for ($i = 0; $i -lt $nodes.Count; $i += 2) { $environment[$nodes[$i].InnerText] = $nodes[$i + 1].InnerText }
        $environment.OCTO_TOOLS_PATH | Should -Be '/x/R&D <dev>/octo-tools'
        $environment.PATH | Should -Be '/a&b:/usr/bin'
        $environment.OCTO_DEVSTACK_SERVICE | Should -Be 'launchd' -Because 'a daemon of launchd waits for a held daemon.lock instead of exiting (KeepAlive would start it again every 10 s)'
        $text | Should -Match '<key>KeepAlive</key><true/>'
        $text | Should -Match '<key>AbandonProcessGroup</key><true/>'
        $text | Should -Not -Match "`r"
    }

    It 'gives a service the PATH of this shell without duplicates, missing folders and folders of the shell session' {
        $root = Join-Path $TestDrive 'pathvalue'
        $bin = New-Item -ItemType Directory -Force -Path (Join-Path $root 'bin')
        $installation = New-Item -ItemType Directory -Force -Path (Join-Path $root 'fnm/node-versions/v22/installation/bin')
        $sessions = New-Item -ItemType Directory -Force -Path (Join-Path $root 'state/fnm_multishells')
        # fnm's per-shell folder is a link to the node version (a junction on Windows: no symlink privilege needed).
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path (Join-Path $sessions '4711_1795') -Target (Split-Path -Parent $installation) | Out-Null
        $separator = [IO.Path]::PathSeparator
        $session = Join-Path $sessions '4711_1795/bin'
        $missing = Join-Path $root 'gone'

        $value = InModuleScope OctoDevStack -Parameters @{ v = (@($bin.FullName, $session, $missing, '', $bin.FullName) -join $separator) } {
            param($v) Get-OctoDevStackServicePathValue -PathValue $v
        }

        @($value -split [regex]::Escape([string]$separator)) | Should -Be @($bin.FullName, $installation.FullName)
    }

    It 'expands ~ in PATH (launchd and systemd do not)' {
        $home_ = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)

        $value = InModuleScope OctoDevStack { Get-OctoDevStackServicePathValue -PathValue '~' }

        $value | Should -Be ([IO.Path]::TrimEndingDirectorySeparator($home_))
    }
}

Describe 'Get-OctoDevStackServiceState (AB#9377)' {
    BeforeEach {
        $script:SavedXdg = $env:XDG_CONFIG_HOME
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg-state'
        Mock -ModuleName OctoDevStack Get-OctoDevStackLaunchdDomain { 'gui/501' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackLaunchAgentPath { Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist' }
    }

    AfterEach { $env:XDG_CONFIG_HOME = $script:SavedXdg }

    It 'reads launchd: a loaded LaunchAgent supervises the daemon and names its pid' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl { [pscustomobject]@{ exitCode = 0; output = "gui/501/io.meshmakers.octo-devstack = {`n`tstate = running`n`tpid = 4711`n`t`tpid = 1`n}" } } -ParameterFilter { $Arguments[0] -eq 'print' }

        $state = InModuleScope OctoDevStack { Get-OctoDevStackServiceState }

        $state.kind | Should -Be 'launchAgent'
        $state.supervised | Should -BeTrue
        $state.pid | Should -Be 4711
        Should -Invoke -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl -Times 1 -ParameterFilter { ($Arguments -join ' ') -eq 'print gui/501/io.meshmakers.octo-devstack' -and $AllowFailure }
    }

    It 'reads launchd: an agent that is not loaded supervises nothing' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl { [pscustomobject]@{ exitCode = 113; output = 'Could not find service' } } -ParameterFilter { $Arguments[0] -eq 'print' }

        $state = InModuleScope OctoDevStack { Get-OctoDevStackServiceState }

        $state.supervised | Should -BeFalse
        $state.pid | Should -BeNullOrEmpty
    }

    It 'reads systemd: an installed unit supervises only while it is active' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'linux' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdActive { $true }

        (InModuleScope OctoDevStack { Get-OctoDevStackServiceState }).supervised | Should -BeFalse -Because 'no unit file, systemctl is not asked'
        Should -Invoke -ModuleName OctoDevStack Get-OctoDevStackSystemdActive -Times 0

        New-Item -ItemType Directory -Force -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user') | Out-Null
        Set-Content -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user/octo-devstack.service') -Value '[Unit]'
        $state = InModuleScope OctoDevStack { Get-OctoDevStackServiceState }
        $state.kind | Should -Be 'systemdUser'
        $state.installed | Should -BeTrue
        $state.supervised | Should -BeTrue
    }

    It 'reads Windows: the logon task is installed but supervises nothing' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'windows' }
        $script:TaskArguments = (InModuleScope OctoDevStack { Get-OctoDevStackWindowsTaskCommand -ToolsPath '/tools' -RepoPath '/devstack' -Port 5090 }).Arguments
        Mock -ModuleName OctoDevStack Get-OctoDevStackLogonTaskArguments { $script:TaskArguments }

        $state = InModuleScope OctoDevStack { Get-OctoDevStackServiceState }

        $state.kind | Should -Be 'scheduledTask'
        $state.installed | Should -BeTrue
        $state.supervised | Should -BeFalse
        $state.port | Should -Be 5090
        (InModuleScope OctoDevStack { Get-OctoDevStackServiceState -Port 5192 }).installed | Should -BeFalse -Because 'the task starts the daemon on 5090, not one on 5192'
    }

    It 'reads the port from every service definition the module writes, and none from one without --url' {
        InModuleScope OctoDevStack {
            $plist = Get-OctoDevStackLaunchAgentPlist -Label 'io.meshmakers.octo-devstack' -RepoPath '/r' -Dll '/r/x.dll' -Url 'http://127.0.0.1:5090' -ToolsPath '/t' -Dotnet '/d/dotnet' -StatePath '/s' -PathValue '/bin'
            Get-OctoDevStackServicePort $plist | Should -Be 5090
            Get-OctoDevStackServicePort (Get-OctoDevStackSystemdUnit -RepoPath '/r' -Dll '/r/x.dll' -Url 'http://127.0.0.1:5192' -ToolsPath '/t' -Dotnet '/d/dotnet' -StatePath '/s') | Should -Be 5192
            Get-OctoDevStackServicePort (Get-OctoDevStackWindowsTaskCommand -ToolsPath '/tools' -RepoPath '/devstack' -Port 5191).Arguments | Should -Be 5191
            Get-OctoDevStackServicePort "gui/501/io.meshmakers.octo-devstack = {`n`targuments = {`n`t`t/d/dotnet`n`t`t/r/x.dll`n`t`t--url`n`t`thttp://127.0.0.1:5090`n`t}`n}" | Should -Be 5090
            Get-OctoDevStackServicePort '<key>ProgramArguments</key><array><string>/d/dotnet</string><string>/r/x.dll</string></array>' | Should -BeNullOrEmpty
            Get-OctoDevStackServicePort '' | Should -BeNullOrEmpty
        }
    }

    It 'a service of another port is neither installed nor supervised for this one (systemd)' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'linux' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdActive { $true }
        New-Item -ItemType Directory -Force -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user') | Out-Null
        Set-Content -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user/octo-devstack.service') -Value 'ExecStart="/d/dotnet" "/r/x.dll" --url http://127.0.0.1:5090'

        $own = InModuleScope OctoDevStack { Get-OctoDevStackServiceState -Port 5090 }
        $other = InModuleScope OctoDevStack { Get-OctoDevStackServiceState -Port 5193 }

        $own.supervised | Should -BeTrue
        $other.supervised | Should -BeFalse
        $other.installed | Should -BeFalse
        $other.port | Should -Be 5090
    }

    It 'a service of another port is not supervised for this one (launchd, port from the plist when print names none)' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl { [pscustomobject]@{ exitCode = 0; output = "gui/501/io.meshmakers.octo-devstack = {`n`tpid = 4711`n}" } } -ParameterFilter { $Arguments[0] -eq 'print' }
        $plistPath = Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $plistPath) | Out-Null
        Set-Content -Path $plistPath -Value (InModuleScope OctoDevStack { Get-OctoDevStackLaunchAgentPlist -Label 'l' -RepoPath '/r' -Dll '/r/x.dll' -Url 'http://127.0.0.1:5090' -ToolsPath '/t' -Dotnet '/d/dotnet' -StatePath '/s' -PathValue '/bin' })
        try {
            (InModuleScope OctoDevStack { Get-OctoDevStackServiceState -Port 5090 }).supervised | Should -BeTrue
            $other = InModuleScope OctoDevStack { Get-OctoDevStackServiceState -Port 5191 }
            $other.supervised | Should -BeFalse
            $other.pid | Should -BeNullOrEmpty -Because 'the pid is that of the service''s daemon on 5090'
        }
        finally { Remove-Item -LiteralPath $plistPath -Force }
    }

    It 'reads systemd''s MainPID and the checkout the unit launches' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'linux' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdActive { $true }
        Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdShow { '4711' } -ParameterFilter { $Property -eq 'MainPID' }
        New-Item -ItemType Directory -Force -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user') | Out-Null
        $unit = InModuleScope OctoDevStack { Get-OctoDevStackSystemdUnit -RepoPath '/home/me/octo-devstack' -Dll '/home/me/octo-devstack/x.dll' -Url 'http://127.0.0.1:5090' -ToolsPath '/t' -Dotnet '/d/dotnet' -StatePath '/s' }
        Set-Content -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user/octo-devstack.service') -Value $unit

        $state = InModuleScope OctoDevStack { Get-OctoDevStackServiceState }

        $state.pid | Should -Be 4711
        $state.repoPath | Should -Be '/home/me/octo-devstack'
    }

    It 'reads the checkout from a plist and from the logon task''s command' {
        InModuleScope OctoDevStack {
            $plist = Get-OctoDevStackLaunchAgentPlist -Label 'l' -RepoPath '/x/R&D/octo-devstack' -Dll '/x/R&D/octo-devstack/x.dll' -Url 'http://127.0.0.1:5090' -ToolsPath '/t' -Dotnet '/d/dotnet' -StatePath '/s' -PathValue '/bin'
            Get-OctoDevStackServiceRepoPath $plist | Should -Be '/x/R&D/octo-devstack'
            Get-OctoDevStackServiceRepoPath (Get-OctoDevStackWindowsTaskCommand -ToolsPath '/tools' -RepoPath "/o'neil/octo-devstack" -Port 5090).Arguments | Should -Be "/o'neil/octo-devstack"
            Get-OctoDevStackServiceRepoPath 'ExecStart=dotnet x.dll' | Should -BeNullOrEmpty
        }
    }

    It 'counts a listener as the service''s daemon only when the pid the manager names is the listener''s' {
        InModuleScope OctoDevStack {
            $launchd = [pscustomobject]@{ kind = 'launchAgent'; supervised = $true; pid = 902 }
            Test-OctoDevStackServiceRuns -Service $launchd -ProcessId 902 | Should -BeTrue
            Test-OctoDevStackServiceRuns -Service $launchd -ProcessId 903 | Should -BeFalse
            # launchd between two starts of its job (KeepAlive throttle): no pid, so a listener on the port is not its daemon
            Test-OctoDevStackServiceRuns -Service ([pscustomobject]@{ kind = 'launchAgent'; supervised = $true; pid = $null }) -ProcessId 902 | Should -BeFalse
            Test-OctoDevStackServiceRuns -Service ([pscustomobject]@{ kind = 'systemdUser'; supervised = $true; pid = 4711 }) -ProcessId 902 | Should -BeFalse
            # an active unit whose MainPID systemd does not say is the daemon of its state folder
            Test-OctoDevStackServiceRuns -Service ([pscustomobject]@{ kind = 'systemdUser'; supervised = $true; pid = $null }) -ProcessId 902 | Should -BeTrue
            Test-OctoDevStackServiceRuns -Service ([pscustomobject]@{ kind = 'systemdUser'; supervised = $false; pid = $null }) -ProcessId 902 | Should -BeFalse
        }
    }
}

Describe 'Stop and restart of a daemon its service runs (AB#9377)' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        Mock -ModuleName OctoDevStack Stop-Process { }
        $script:KillCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Send-OctoDevStackSignal { $script:KillCalls.Add("-$Signal $ProcessId") }
        Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { 902 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackProcessCommandLine { 'dotnet /x/octo-devstack/bin/Release/net10.0/octo-devstack.dll --url http://127.0.0.1:5090' }
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix { 4242 }
        Mock -ModuleName OctoDevStack Invoke-Build { $global:LASTEXITCODE = 0 }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $true }
        Mock -ModuleName OctoDevStack Get-OctoDevStackLaunchdDomain { 'gui/501' }
        $script:ServiceCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl { $script:ServiceCalls.Add("launchctl $($Arguments -join ' ')"); [pscustomobject]@{ exitCode = 0; output = '' } }
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackSystemctl { $script:ServiceCalls.Add("systemctl $($Arguments -join ' ')") }
        # The service manager's call ends 902; the daemon it starts answers as 5151.
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $ProcessId -ne 902 -or $script:ServiceCalls.Count -eq 0 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth {
            $processId = if ($script:ServiceCalls.Count -gt 0) { 5151 } else { 902 }
            [pscustomobject]@{ status = 'ok'; pid = $processId; version = '1.0.0'; commit = '623b174b6a17' }
        }
    }

    It 'refuses to stop a daemon launchd runs with KeepAlive: nothing is signalled' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised -ProcessId 902 }

        $json = Stop-OctoDevStackDaemon -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.stopped | Should -BeFalse
        $json.data.refused | Should -BeTrue
        $json.data.service | Should -Be 'launchAgent'
        $json.data.error | Should -BeLike '*runs under launchd*Start-OctoDevStackDaemon -Restart*Uninstall-OctoDevStackDaemonService*'
        $script:KillCalls | Should -HaveCount 0
        $script:ServiceCalls | Should -HaveCount 0
    }

    It 'still refuses a busy daemon first, also under launchd' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised }
        Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus -Busy }

        $json = Stop-OctoDevStackDaemon -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.error | Should -BeLike '*busy, nothing stopped*'
    }

    It 'stops a daemon systemd runs through systemctl, never by a signal of its own' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState systemdUser -Supervised }

        $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeTrue
        $json.data.service | Should -Be 'systemdUser'
        $json.data.warnings | Should -Contain 'The systemd unit stays enabled and starts octo-devstack again at the next login (Uninstall-OctoDevStackDaemonService removes it).'
        $script:ServiceCalls | Should -Be @('systemctl stop octo-devstack.service')
        $script:KillCalls | Should -HaveCount 0
    }

    It 'stops a daemon on Windows with the logon task installed and says the task starts it again' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState scheduledTask -Installed }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

        $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

        $json.data.stopped | Should -BeTrue
        @($json.data.warnings) -join ' ' | Should -BeLike '*logon task*15 minutes*'
        $script:KillCalls | Should -Be @('-TERM 902')
    }

    It 'restarts a daemon launchd runs with launchctl kickstart -k and reports the new daemon, no second one is started' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised -ProcessId 902 }
        $path = New-FakeCheckout 'service-restart' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Json -WarningAction SilentlyContinue | ConvertFrom-Json

        $json.data.error | Should -BeNullOrEmpty
        $json.data.success | Should -BeTrue
        $json.data.restarted | Should -BeTrue
        $json.data.service | Should -Be 'launchAgent'
        $json.data.pid | Should -Be 5151
        $json.data.commit | Should -Be '623b174b6a17'
        $script:ServiceCalls | Should -Be @('launchctl kickstart -k gui/501/io.meshmakers.octo-devstack')
        $script:KillCalls | Should -HaveCount 0
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'restarts a daemon systemd runs with systemctl --user restart' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState systemdUser -Supervised }
        $path = New-FakeCheckout 'service-restart-linux' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Json -WarningAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $script:ServiceCalls | Should -Be @('systemctl restart octo-devstack.service')
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'refuses the restart under launchd while builds run or wait, unless -Force' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised }
        Mock -ModuleName OctoDevStack Get-OctoDevStackDaemonStatus { New-DaemonStatus -Busy }
        $path = New-FakeCheckout 'service-restart-busy' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.refused | Should -BeTrue
        $json.data.error | Should -BeLike 'Not restarted:*busy*b3-104847*-Force*'
        $script:ServiceCalls | Should -HaveCount 0

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Force -Json -WarningAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeTrue
        $script:ServiceCalls | Should -Be @('launchctl kickstart -k gui/501/io.meshmakers.octo-devstack')
    }

    It 'with -Rebuild stops the daemon through launchd, builds, then loads the agent again' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised }
        Mock -ModuleName OctoDevStack Invoke-Build { $script:ServiceCalls.Add('build'); $global:LASTEXITCODE = 0 }
        $path = New-FakeCheckout 'service-rebuild' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Rebuild -Json -WarningAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.built | Should -BeTrue
        $script:ServiceCalls | Should -Be @('launchctl bootout gui/501/io.meshmakers.octo-devstack', 'build', "launchctl bootstrap gui/501 $(Join-Path $TestDrive 'service-launchAgent')")
    }

    It 'loads the agent again after a failed -Rebuild and reports the failure' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised }
        Mock -ModuleName OctoDevStack Invoke-Build { $script:ServiceCalls.Add('build'); $global:LASTEXITCODE = 1 }
        $path = New-FakeCheckout 'service-rebuild-fails' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Rebuild -Json -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*Invoke-Build*failed*started again*'
        $script:ServiceCalls[-1] | Should -BeLike 'launchctl bootstrap *'
    }

    It 'waits for the daemon of a service while nothing answers yet, and never starts a second one' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
        $script:HealthCalls = 0
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth { $script:HealthCalls++; if ($script:HealthCalls -ge 3) { [pscustomobject]@{ status = 'ok'; pid = 6060; version = '1.0.0'; commit = '623b174b6a17' } } }
        $path = New-FakeCheckout 'service-waits' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.alreadyRunning | Should -BeTrue
        $json.data.pid | Should -Be 6060
        $json.data.service | Should -Be 'launchAgent'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'fails, without a second daemon, when the service''s daemon does not come up' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth { $null }
        $script:Clock = Get-Date
        Mock -ModuleName OctoDevStack Get-Date { $script:Clock = $script:Clock.AddSeconds(10); $script:Clock }
        $path = New-FakeCheckout 'service-down' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*launchAgent runs octo-devstack, but nothing answers*No second daemon*'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'starts an installed systemd unit that does not run (after a stop), never a daemon of its own next to it' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState systemdUser -Installed }
        Mock -ModuleName OctoDevStack Test-OctoDevStackSystemdUserManager { $true }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
        $path = New-FakeCheckout 'unit-stopped' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Json | ConvertFrom-Json

        $json.data.error | Should -BeNullOrEmpty
        $json.data.started | Should -BeTrue
        $json.data.service | Should -Be 'systemdUser'
        $json.data.pid | Should -Be 5151
        $script:ServiceCalls | Should -Be @('systemctl start octo-devstack.service')
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'loads an installed LaunchAgent that is not loaded, after building a missing dll first' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Installed }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
        Mock -ModuleName OctoDevStack Invoke-Build { $script:ServiceCalls.Add('build'); New-Item -ItemType File -Force -Path (Join-Path $repositoryPath 'bin/Release/net10.0/octo-devstack.dll') | Out-Null; $global:LASTEXITCODE = 0 }
        $path = New-FakeCheckout 'agent-unloaded'

        $json = Start-OctoDevStackDaemon -Path $path -Json | ConvertFrom-Json

        $json.data.started | Should -BeTrue
        $json.data.built | Should -BeTrue
        $script:ServiceCalls | Should -Be @('build', "launchctl bootstrap gui/501 $(Join-Path $TestDrive 'service-launchAgent')")
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'starts a daemon of its own when a unit file exists but no user manager answers (WSL without systemd, a container)' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState systemdUser -Installed }
        Mock -ModuleName OctoDevStack Test-OctoDevStackSystemdUserManager { $false }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
        $script:Started = $false
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix { $script:Started = $true; 4242 }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:Started }
        $path = New-FakeCheckout 'unit-without-systemctl' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Json | ConvertFrom-Json

        $json.data.started | Should -BeTrue
        $json.data.pid | Should -Be 4242
        $script:ServiceCalls | Should -HaveCount 0
    }

    It 'stops a daemon started by hand next to launchd''s waiting one by its own signal; launchd''s takes over' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised -ProcessId 4711 }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $ProcessId -ne 902 -or $script:KillCalls.Count -eq 0 }

        $json = Stop-OctoDevStackDaemon -Json -WarningAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeTrue
        $json.data.refused | Should -BeNullOrEmpty
        $json.data.service | Should -BeNullOrEmpty -Because 'launchd does not run the daemon that was stopped'
        @($json.data.warnings) -join ' ' | Should -BeLike '*launchAgent runs octo-devstack PID 4711, which waits for this one (PID 902*takes over*'
        $script:KillCalls | Should -Be @('-TERM 902')
        $script:ServiceCalls | Should -HaveCount 0
    }

    It 'restarts a daemon started by hand next to launchd''s: stops it and reports launchd''s daemon that takes over' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised -ProcessId 4711 }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $ProcessId -ne 902 -or $script:KillCalls.Count -eq 0 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth {
            $processId = if ($script:KillCalls.Count -gt 0) { 4711 } else { 902 }
            [pscustomobject]@{ status = 'ok'; pid = $processId; version = '1.0.0'; commit = 'd774abca14f7' }
        }
        $path = New-FakeCheckout 'hand-next-to-launchd' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Json -WarningAction SilentlyContinue | ConvertFrom-Json

        $json.data.error | Should -BeNullOrEmpty
        $json.data.restarted | Should -BeTrue
        $json.data.pid | Should -Be 4711
        $json.data.service | Should -Be 'launchAgent'
        $script:KillCalls | Should -Be @('-TERM 902')
        $script:ServiceCalls | Should -HaveCount 0 -Because 'no kickstart: it would restart launchd''s waiting daemon, not the one on the port'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'stops a test daemon on another port by its own signal and leaves the systemd unit of 5090 alone' {
        # Found on Linux: Stop-OctoDevStackDaemon -Port 5193 ran systemctl --user stop, which ended the unit's daemon on
        # 5090, and then failed because the daemon on 5193 still ran.
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'linux' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdActive { $true }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }
        $saved = $env:XDG_CONFIG_HOME
        $env:XDG_CONFIG_HOME = Join-Path $TestDrive 'xdg-other-port'
        New-Item -ItemType Directory -Force -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user') | Out-Null
        Set-Content -Path (Join-Path $env:XDG_CONFIG_HOME 'systemd/user/octo-devstack.service') -Value 'ExecStart="/d/dotnet" "/r/x.dll" --url http://127.0.0.1:5090'
        try { $json = Stop-OctoDevStackDaemon -Port 5193 -Json -WarningAction SilentlyContinue | ConvertFrom-Json }
        finally { $env:XDG_CONFIG_HOME = $saved }

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeTrue
        $json.data.service | Should -BeNullOrEmpty
        $script:ServiceCalls | Should -HaveCount 0
        $script:KillCalls | Should -Be @('-TERM 902')
    }

    It 'starts a daemon of its own on another port while launchd runs the one on 5090' {
        # Found on Linux (same path on macOS): Start-OctoDevStackDaemon -Port 5194 waited for the service's daemon there.
        Mock -ModuleName OctoDevStack Get-OctoDevStackServicePlatform { 'macos' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListeningPids { }
        $script:Started = $false
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix { $script:Started = $true; 4242 }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:Started }
        Mock -ModuleName OctoDevStack Get-OctoDevStackHealth { if ($script:Started) { [pscustomobject]@{ status = 'ok'; pid = 4242; version = '1.0.0'; commit = 'd774abca14f7' } } }
        $plistPath = Join-Path $TestDrive 'LaunchAgents/io.meshmakers.octo-devstack.plist'
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $plistPath) | Out-Null
        Set-Content -Path $plistPath -Value (InModuleScope OctoDevStack { Get-OctoDevStackLaunchAgentPlist -Label 'l' -RepoPath '/r' -Dll '/r/x.dll' -Url 'http://127.0.0.1:5090' -ToolsPath '/t' -Dotnet '/d/dotnet' -StatePath '/s' -PathValue '/bin' })
        $path = New-FakeCheckout 'other-port-start' -Built

        try { $json = Start-OctoDevStackDaemon -Path $path -Port 5191 -Json | ConvertFrom-Json }
        finally { Remove-Item -LiteralPath $plistPath -Force }

        $json.data.error | Should -BeNullOrEmpty
        $json.data.started | Should -BeTrue
        $json.data.pid | Should -Be 4242
        $json.data.service | Should -BeNullOrEmpty
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 1 -ParameterFilter { $Url -eq 'http://127.0.0.1:5191' }
        @($script:ServiceCalls | Where-Object { $_ -notlike 'launchctl print *' }) | Should -HaveCount 0
    }

    It 'says whether a systemd stop was graceful from the unit''s Result, and leaves it open when systemd does not say' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState systemdUser -Supervised }
        Mock -ModuleName OctoDevStack Get-OctoDevStackSystemdShow { $script:Result } -ParameterFilter { $Property -eq 'Result' }
        $expected = @{ 'success' = $true; 'timeout' = $false }

        foreach ($script:Result in 'success', 'timeout') {
            (Stop-OctoDevStackDaemon -Json -WarningAction SilentlyContinue | ConvertFrom-Json).data.graceful | Should -Be $expected[$script:Result] -Because "Result=$script:Result"
        }
        $script:Result = $null
        (Stop-OctoDevStackDaemon -Json -WarningAction SilentlyContinue | ConvertFrom-Json).data.graceful | Should -BeNullOrEmpty
    }

    It 'refuses -Restart -Rebuild while a daemon started by hand runs next to launchd''s: nothing is stopped or built' {
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState launchAgent -Supervised -ProcessId 4711 }
        $path = New-FakeCheckout 'rebuild-next-to-launchd' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Rebuild -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*(PID 902) was started by hand next to the daemon of the launchAgent (PID 4711)*nothing was stopped or built*Stop-OctoDevStackDaemon*'
        $script:KillCalls | Should -HaveCount 0
        $script:ServiceCalls | Should -HaveCount 0
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
    }

    It 'builds nothing when the daemon survives the stop through launchd, and loads the agent again' {
        $script:StateCalls = 0
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState {
            $script:StateCalls++
            if ($script:StateCalls -eq 1) { New-ServiceState launchAgent -Supervised } else { New-ServiceState launchAgent -Installed }
        }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $true }
        $path = New-FakeCheckout 'rebuild-survives' -Built

        $json = Start-OctoDevStackDaemon -Path $path -Restart -Rebuild -HealthTimeoutSeconds 0 -Json -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*(PID 902) did not end within 0 s of the stop; nothing was built*'
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
        $script:ServiceCalls | Should -Be @('launchctl bootout gui/501/io.meshmakers.octo-devstack', "launchctl bootstrap gui/501 $(Join-Path $TestDrive 'service-launchAgent')")
    }

    It 'builds and starts the checkout the service launches, and refuses a -Path that names another one' {
        $script:ServiceCheckout = New-FakeCheckout 'service-checkout' -Built
        $script:OtherCheckout = New-FakeCheckout 'other-checkout' -Built
        Mock -ModuleName OctoDevStack Get-OctoDevStackServiceState { New-ServiceState systemdUser -Supervised -RepoPath $script:ServiceCheckout }

        $json = Start-OctoDevStackDaemon -Path $script:OtherCheckout -Restart -Rebuild -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike "*runs octo-devstack from $($script:ServiceCheckout), not from $($script:OtherCheckout)*Install-OctoDevStackDaemonService -Path '$($script:OtherCheckout)'*"
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 0
        $script:ServiceCalls | Should -HaveCount 0

        # Without -Path the default checkout would be another one: the service's is built and started.
        Mock -ModuleName OctoDevStack Get-OctoDevStackDefaultPath { $script:OtherCheckout }
        $json = Start-OctoDevStackDaemon -Restart -Rebuild -Json -WarningAction SilentlyContinue | ConvertFrom-Json
        $json.data.error | Should -BeNullOrEmpty
        $json.data.success | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack Invoke-Build -Times 1 -ParameterFilter { $repositoryPath -eq $script:ServiceCheckout }
        $script:ServiceCalls | Should -Be @('systemctl stop octo-devstack.service', 'systemctl start octo-devstack.service')
    }
}
