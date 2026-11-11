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
}

Describe 'OctoDevStack module surface' {
    It 'exports only the daemon start and stop' {
        @((Get-Module OctoDevStack).ExportedFunctions.Keys | Sort-Object) | Should -Be @('Start-OctoDevStackDaemon', 'Stop-OctoDevStackDaemon')
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
}

Describe 'Stop-OctoDevStackDaemon' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        Mock -ModuleName OctoDevStack Stop-Process { }
        $script:KillCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Send-OctoDevStackSignal { $script:KillCalls.Add("-$Signal $ProcessId") }
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
        Mock -ModuleName OctoDevStack Get-CimInstance { [pscustomobject]@{ CommandLine = '"C:\Program Files\dotnet\dotnet.exe" C:\dev\octo-devstack\bin\Release\net10.0\octo-devstack.dll' } }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

        $json = Stop-OctoDevStackDaemon -Json | ConvertFrom-Json

        $json.data.stopped | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 1 -ParameterFilter { $Id -eq 1234 }
        $script:KillCalls | Should -HaveCount 0
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
