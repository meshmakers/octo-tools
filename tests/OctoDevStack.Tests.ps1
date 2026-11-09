#Requires -Modules Pester
<#
    Pester tests for the octo-devstack cmdlets (Install-/Start-/Stop-OctoDevStack, Get-OctoDevStackStatus).

    Nothing real is cloned, built, started or stopped: git, dotnet, claude, lsof, ps, kill, Start-Process,
    Stop-Process, Invoke-RestMethod and the detached launcher are mocked; the checkout is a fake folder in
    TestDrive and the state folder is redirected there (OCTO_DEVSTACK_STATE).

    Run:  Invoke-Pester ./tests/OctoDevStack.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'OctoDevStack.psm1') -Force

    $script:SavedState = $env:OCTO_DEVSTACK_STATE
    $script:SavedConfig = $env:OCTO_DEVSTACK_CONFIG
    $env:OCTO_DEVSTACK_STATE = Join-Path $TestDrive 'state'
    $env:OCTO_DEVSTACK_CONFIG = Join-Path $TestDrive 'config/devstack.yaml'

    $script:Dll = 'bin/Release/net10.0/octo-devstack.dll'

    # Windows-only cmdlets do not exist on macOS/Linux; stubs make them mockable there.
    $script:Stubs = @()
    foreach ($name in 'Get-NetTCPConnection', 'Get-CimInstance') {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            New-Item -Path "function:global:$name" -Value { } | Out-Null
            $script:Stubs += $name
        }
    }

    function script:New-FakeCheckout([string]$name, [switch]$Built) {
        $path = Join-Path $TestDrive $name
        New-Item -ItemType Directory -Force -Path (Join-Path $path '.git'), (Join-Path $path 'src/DevStack') | Out-Null
        Set-Content -Path (Join-Path $path 'src/DevStack/DevStack.csproj') -Value '<Project />'
        if ($Built) {
            New-Item -ItemType Directory -Force -Path (Join-Path $path 'bin/Release/net10.0') | Out-Null
            Set-Content -Path (Join-Path $path $script:Dll) -Value 'fake'
        }
        return $path
    }

    # git mock: answers from $script:Git (branch, commit, porcelain, behind, exit codes) and records every call.
    function script:Set-GitMock {
        param([string]$Branch = 'main', [string]$Commit = 'abc1234', [string[]]$Porcelain = @(), $Behind = 0,
            [int]$CloneExit = 0, [int]$PullExit = 0)
        $script:Git = @{ Branch = $Branch; Commit = $Commit; Porcelain = $Porcelain; Behind = $Behind; CloneExit = $CloneExit; PullExit = $PullExit }
        $script:GitCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack git {
            $line = $args -join ' '
            $script:GitCalls.Add($line)
            $global:LASTEXITCODE = 0
            switch -Regex ($line) {
                '^clone ' { $global:LASTEXITCODE = $script:Git.CloneExit; return }
                ' fetch' { return }
                ' pull --ff-only' { $global:LASTEXITCODE = $script:Git.PullExit; return 'Updating abc..def' }
                'rev-parse --abbrev-ref HEAD' { return $script:Git.Branch }
                'rev-parse --short HEAD' { return $script:Git.Commit }
                'status --porcelain' { return $script:Git.Porcelain }
                'rev-list --count' {
                    if ($null -eq $script:Git.Behind) { $global:LASTEXITCODE = 128; return }
                    return [string]$script:Git.Behind
                }
            }
        }
    }

    function script:Set-DotnetMock([int]$ExitCode = 0) {
        $script:DotnetExit = $ExitCode
        $script:DotnetCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack dotnet {
            $script:DotnetCalls.Add($args -join ' ')
            $global:LASTEXITCODE = $script:DotnetExit
            'Build output line'
        }
    }
}

AfterAll {
    foreach ($name in $script:Stubs) { Remove-Item -Path "function:global:$name" -ErrorAction SilentlyContinue }
    $env:OCTO_DEVSTACK_STATE = $script:SavedState
    $env:OCTO_DEVSTACK_CONFIG = $script:SavedConfig
}

Describe 'Install-OctoDevStack' {
    BeforeEach {
        Set-DotnetMock
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
    }

    It 'clones when the checkout is missing, then builds Release' {
        Set-GitMock
        $path = Join-Path $TestDrive 'missing/octo-devstack'

        $json = Install-OctoDevStack -Path $path -Json | ConvertFrom-Json

        $json.command | Should -Be 'Install-OctoDevStack'
        $json.data.success | Should -BeTrue
        $json.data.cloned | Should -BeTrue
        $json.data.updated | Should -BeFalse
        $json.data.built | Should -BeTrue
        $json.data.path | Should -Be $path
        $json.data.dll | Should -Be (Join-Path $path $script:Dll)
        $json.data.commit | Should -Be 'abc1234'
        $script:GitCalls[0] | Should -Be "clone git@github.com:meshmakers/octo-devstack.git $path"
        $script:DotnetCalls | Should -HaveCount 1
        $script:DotnetCalls[0] | Should -Be "build $(Join-Path $path 'src/DevStack/DevStack.csproj') -c Release"
    }

    It 'reports a failed clone and builds nothing' {
        Set-GitMock -CloneExit 128
        $json = Install-OctoDevStack -Path (Join-Path $TestDrive 'clonefail') -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*git clone*failed*'
        $script:DotnetCalls | Should -HaveCount 0
    }

    It 'does not clone an existing checkout and does not pull without -Update' {
        Set-GitMock
        $path = New-FakeCheckout 'existing'
        $json = Install-OctoDevStack -Path $path -Json | ConvertFrom-Json
        $json.data.cloned | Should -BeFalse
        $json.data.updated | Should -BeFalse
        @($script:GitCalls | Where-Object { $_ -match 'clone|pull|fetch' }) | Should -HaveCount 0
    }

    It 'pulls with --ff-only on -Update when behind' {
        Set-GitMock -Behind 3
        $path = New-FakeCheckout 'update'
        $json = Install-OctoDevStack -Path $path -Update -Json | ConvertFrom-Json
        $json.data.success | Should -BeTrue
        $json.data.updated | Should -BeTrue
        $script:GitCalls | Should -Contain "-C $path fetch --quiet"
        $script:GitCalls | Should -Contain "-C $path pull --ff-only"
        @($script:GitCalls | Where-Object { $_ -match 'reset|checkout|stash|clean' }) | Should -HaveCount 0
    }

    It 'refuses -Update on a dirty working tree and never resets' {
        Set-GitMock -Behind 2 -Porcelain @(' M src/DevStack/Program.cs')
        $path = New-FakeCheckout 'dirty'
        $json = Install-OctoDevStack -Path $path -Update -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.exitCode | Should -Be 1
        $json.data.error | Should -BeLike '*local changes*'
        @($script:GitCalls | Where-Object { $_ -match 'pull|reset|checkout|stash|clean' }) | Should -HaveCount 0
        $script:DotnetCalls | Should -HaveCount 0
    }

    It 'refuses -Update on a branch other than main' {
        Set-GitMock -Behind 1 -Branch 'reimar/feature'
        $path = New-FakeCheckout 'branch'
        $json = Install-OctoDevStack -Path $path -Update -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike "*branch 'reimar/feature'*"
        @($script:GitCalls | Where-Object { $_ -match 'pull' }) | Should -HaveCount 0
    }

    It 'accepts a dirty tree on -Update when it is already up to date' {
        Set-GitMock -Behind 0 -Porcelain @('?? notes.txt') -Branch 'reimar/feature'
        $path = New-FakeCheckout 'uptodate'
        $json = Install-OctoDevStack -Path $path -Update -Json | ConvertFrom-Json
        $json.data.success | Should -BeTrue
        $json.data.updated | Should -BeFalse
        @($script:GitCalls | Where-Object { $_ -match 'pull' }) | Should -HaveCount 0
    }

    It 'reports a failed build with its exit code' {
        Set-GitMock
        Set-DotnetMock -ExitCode 1
        $path = New-FakeCheckout 'buildfail'
        $json = Install-OctoDevStack -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.built | Should -BeFalse
        $json.data.exitCode | Should -Be 1
        $json.data.error | Should -BeLike '*dotnet build*failed*'
        $LASTEXITCODE | Should -Be 1
    }

    It 'skips the build with -NoBuild' {
        Set-GitMock
        $path = New-FakeCheckout 'nobuild'
        $json = Install-OctoDevStack -Path $path -NoBuild -Json | ConvertFrom-Json
        $json.data.built | Should -BeFalse
        $script:DotnetCalls | Should -HaveCount 0
    }

    It 'skips -LaunchAgent outside macOS' {
        Set-GitMock
        Mock -ModuleName OctoDevStack Test-OctoDevStackMacOS { $false }
        $path = New-FakeCheckout 'agent' -Built
        $json = Install-OctoDevStack -Path $path -LaunchAgent -Json | ConvertFrom-Json
        $json.data.success | Should -BeTrue
        $json.data.launchAgent | Should -Be 'skipped'
    }

    It 'defaults to a folder next to the octo-tools checkout (outside .claude/worktrees)' {
        $default = & (Get-Module OctoDevStack) { Get-OctoDevStackDefaultPath }
        Split-Path -Leaf $default | Should -Be 'octo-devstack'
        $default | Should -Not -BeLike '*.claude*'
        $toolsRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $marker = $toolsRoot.IndexOf("$([IO.Path]::DirectorySeparatorChar).claude$([IO.Path]::DirectorySeparatorChar)worktrees")
        if ($marker -ge 0) { $toolsRoot = $toolsRoot.Substring(0, $marker) }
        Split-Path -Parent $default | Should -Be (Split-Path -Parent ([IO.Path]::TrimEndingDirectorySeparator($toolsRoot)))
    }
}

Describe 'Start-OctoDevStack' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackLaunchAgent { $false }
        Set-DotnetMock
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        Mock -ModuleName OctoDevStack Start-Process { [pscustomobject]@{ Id = 4242 } }
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix { 4242 }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $true }
        Mock -ModuleName OctoDevStack lsof { }
        Mock -ModuleName OctoDevStack ps { }
        Mock -ModuleName OctoDevStack Get-Command { $null } -ParameterFilter { $Name -eq 'claude' }
    }

    It 'refuses when something else answers /health on the port' {
        Mock -ModuleName OctoDevStack Invoke-RestMethod { @{ status = 'ok' } }
        Mock -ModuleName OctoDevStack lsof { '555' }
        Mock -ModuleName OctoDevStack ps { 'node /tmp/other-health-server.js' }
        $path = New-FakeCheckout 'foreignhealth' -Built

        $json = Start-OctoDevStack -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.alreadyRunning | Should -BeFalse
        $json.data.error | Should -BeLike '*PID 555*not octo-devstack*'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0

        $status = Get-OctoDevStackStatus -Path $path -Json | ConvertFrom-Json
        $status.data.healthy | Should -BeFalse
        $status.data.running | Should -BeFalse
    }

    It 'does nothing when /health already answers' {
        Mock -ModuleName OctoDevStack Invoke-RestMethod { @{ status = 'ok' } }
        Mock -ModuleName OctoDevStack lsof { '777' }
        Mock -ModuleName OctoDevStack ps { 'dotnet /x/octo-devstack/bin/Release/net10.0/octo-devstack.dll' }
        $path = New-FakeCheckout 'running' -Built

        $json = Start-OctoDevStack -Path $path -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.alreadyRunning | Should -BeTrue
        $json.data.started | Should -BeFalse
        $json.data.pid | Should -Be 777
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
        Should -Invoke -ModuleName OctoDevStack Start-Process -Times 0
        $script:DotnetCalls | Should -HaveCount 0
    }

    It 'tells the user to run Install-OctoDevStack when the dll is missing' {
        Mock -ModuleName OctoDevStack Invoke-RestMethod { throw 'connection refused' }
        $path = New-FakeCheckout 'notbuilt'
        $json = Start-OctoDevStack -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*Install-OctoDevStack*'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'builds first with -Build when the dll is missing' {
        Mock -ModuleName OctoDevStack Invoke-RestMethod { throw 'connection refused' }
        $path = New-FakeCheckout 'buildonstart'
        Mock -ModuleName OctoDevStack dotnet {
            $global:LASTEXITCODE = 0
            New-Item -ItemType Directory -Force -Path (Join-Path $path 'bin/Release/net10.0') | Out-Null
            Set-Content -Path (Join-Path $path 'bin/Release/net10.0/octo-devstack.dll') -Value 'fake'
        }
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -gt 1 }
        $script:HealthCalls = 0
        $json = Start-OctoDevStack -Path $path -Build -Json | ConvertFrom-Json
        $json.data.success | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack dotnet -Times 1
    }

    It 'refuses when another process holds the port without answering /health' {
        Mock -ModuleName OctoDevStack Invoke-RestMethod { throw 'connection refused' }
        Mock -ModuleName OctoDevStack lsof { '555' }
        Mock -ModuleName OctoDevStack ps { 'node server.js' }
        $path = New-FakeCheckout 'foreignport' -Built
        $json = Start-OctoDevStack -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*PID 555 (node server.js)*'
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }

    It 'starts detached on macOS/Linux with the dll and --url, waits for /health and reports' {
        $script:HealthCalls = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -ge 3 }
        $path = New-FakeCheckout 'startunix' -Built

        $json = Start-OctoDevStack -Path $path -Port 5099 -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.started | Should -BeTrue
        $json.data.pid | Should -Be 4242
        $json.data.url | Should -Be 'http://127.0.0.1:5099'
        $json.data.mcpUrl | Should -Be 'http://127.0.0.1:5099/mcp'
        $json.data.statusPage | Should -Be 'http://127.0.0.1:5099/'
        $json.data.logPath | Should -Be (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.log')
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 1 -ParameterFilter {
            $Dll -eq (Join-Path $path 'bin/Release/net10.0/octo-devstack.dll') -and $Url -eq 'http://127.0.0.1:5099' -and
            $WorkingDirectory -eq $path -and $LogPath -eq (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.log')
        }
        $script:HealthCalls | Should -Be 3
    }

    It 'starts with Start-Process (hidden, redirected) on Windows' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $true }
        Mock -ModuleName OctoDevStack Get-NetTCPConnection { }
        $script:HealthCalls = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:HealthCalls++; $script:HealthCalls -ge 2 }
        # not $path: inside the filter it is Start-Process's -Path alias of -FilePath
        $checkout = New-FakeCheckout 'startwin' -Built

        $json = Start-OctoDevStack -Path $checkout -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.pid | Should -Be 4242
        Should -Invoke -ModuleName OctoDevStack Start-Process -Times 1 -ParameterFilter {
            $FilePath -eq 'dotnet' -and $ArgumentList[0] -eq (Join-Path $checkout 'bin/Release/net10.0/octo-devstack.dll') -and
            $ArgumentList[1] -eq '--url' -and $ArgumentList[2] -eq 'http://127.0.0.1:5090' -and
            $WindowStyle -eq 'Hidden' -and $RedirectStandardOutput -like '*daemon.log' -and $RedirectStandardError -like '*daemon.err.log'
        }
    }

    It 'fails with the log tail when the daemon exits before it is healthy' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $false }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }
        New-Item -ItemType Directory -Force -Path $env:OCTO_DEVSTACK_STATE | Out-Null
        Set-Content -Path (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.log') -Value 'Unhandled exception: address in use'
        $path = New-FakeCheckout 'crash' -Built

        $json = Start-OctoDevStack -Path $path -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.started | Should -BeFalse
        $json.data.error | Should -BeLike '*exited*'
        $json.data.logTail | Should -Contain 'Unhandled exception: address in use'
    }

    It 'refuses -Json with -Foreground' {
        { Start-OctoDevStack -Foreground -Json -ErrorAction Stop } | Should -Throw '*-Json is not supported with -Foreground*'
    }

    Context '-RegisterClaude' {
        BeforeEach {
            Mock -ModuleName OctoDevStack Invoke-RestMethod { @{ status = 'ok' } }
            Mock -ModuleName OctoDevStack Get-Command { [pscustomobject]@{ Name = 'claude' } } -ParameterFilter { $Name -eq 'claude' }
            $script:ClaudeCalls = [System.Collections.Generic.List[string]]::new()
        }

        It 'adds the MCP server when claude does not know it' {
            Mock -ModuleName OctoDevStack claude {
                $script:ClaudeCalls.Add($args -join ' ')
                $global:LASTEXITCODE = 0
                if ($args[1] -eq 'list') { 'octomesh-local: https://localhost:5014/mcp (HTTP) - Connected' }
            }
            $json = Start-OctoDevStack -Path (New-FakeCheckout 'claudeadd' -Built) -RegisterClaude -Json | ConvertFrom-Json
            $json.data.claudeRegistration | Should -Be 'added'
            $script:ClaudeCalls | Should -Contain 'mcp add --transport http --scope user octo-devstack http://127.0.0.1:5090/mcp'
        }

        It 'does not add it again when claude already lists octo-devstack' {
            Mock -ModuleName OctoDevStack claude {
                $script:ClaudeCalls.Add($args -join ' ')
                $global:LASTEXITCODE = 0
                if ($args[1] -eq 'list') { 'octo-devstack: http://127.0.0.1:5090/mcp (HTTP) - Connected' }
            }
            $json = Start-OctoDevStack -Path (New-FakeCheckout 'claudepresent' -Built) -RegisterClaude -Json | ConvertFrom-Json
            $json.data.claudeRegistration | Should -Be 'present'
            @($script:ClaudeCalls | Where-Object { $_ -like 'mcp add*' }) | Should -HaveCount 0
        }

        It 'reports a mismatch and changes nothing when octo-devstack is registered with another URL' {
            Mock -ModuleName OctoDevStack claude {
                $script:ClaudeCalls.Add($args -join ' ')
                $global:LASTEXITCODE = 0
                if ($args[1] -eq 'list') { 'octo-devstack: http://127.0.0.1:5199/mcp (HTTP) - Connected' }
            }
            $json = Start-OctoDevStack -Path (New-FakeCheckout 'claudemismatch' -Built) -RegisterClaude -Json 3>$null | ConvertFrom-Json
            $json.data.claudeRegistration | Should -Be 'mismatch'
            @($script:ClaudeCalls | Where-Object { $_ -like 'mcp add*' -or $_ -like 'mcp remove*' }) | Should -HaveCount 0
        }

        It 'only reports the command when claude is not on PATH' {
            Mock -ModuleName OctoDevStack Get-Command { $null } -ParameterFilter { $Name -eq 'claude' }
            Mock -ModuleName OctoDevStack claude { $script:ClaudeCalls.Add($args -join ' ') }
            $json = Start-OctoDevStack -Path (New-FakeCheckout 'claudemissing' -Built) -RegisterClaude -Json | ConvertFrom-Json
            $json.data.claudeRegistration | Should -Be 'notFound'
            $script:ClaudeCalls | Should -HaveCount 0
        }
    }
}

Describe 'Stop-OctoDevStack' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackLaunchAgent { $false }
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Test-OctoDevStackMacOS { $false }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        Mock -ModuleName OctoDevStack Stop-Process { }
        $script:KillCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack kill { $script:KillCalls.Add($args -join ' ') }
    }

    It 'sends SIGTERM only to the octo-devstack listener on the port' {
        Mock -ModuleName OctoDevStack lsof { '901'; '902' }
        Mock -ModuleName OctoDevStack ps {
            if ($args -contains 901) { 'node /tmp/other.js' } else { 'dotnet /Users/x/octo-devstack/bin/Release/net10.0/octo-devstack.dll --url http://127.0.0.1:5090' }
        }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

        $json = Stop-OctoDevStack -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeTrue
        $json.data.pid | Should -Be 902
        $json.data.note | Should -BeLike '*keep running*adopts*'
        $script:KillCalls | Should -Be @('-TERM 902')
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 0
    }

    It 'kills it after the timeout when SIGTERM is ignored' {
        Mock -ModuleName OctoDevStack lsof { '902' }
        Mock -ModuleName OctoDevStack ps { 'dotnet octo-devstack.dll' }
        $script:AliveChecks = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $script:AliveChecks++; $script:AliveChecks -le 3 }

        $json = Stop-OctoDevStack -TimeoutSeconds 0 -Json | ConvertFrom-Json

        $json.data.stopped | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 1 -ParameterFilter { $Id -eq 902 }
    }

    It 'refuses when the port belongs to another program, stops nothing' {
        Mock -ModuleName OctoDevStack lsof { '901' }
        Mock -ModuleName OctoDevStack ps { 'dotnet Meshmakers.Octo.Identity.dll' }
        $json = Stop-OctoDevStack -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.stopped | Should -BeFalse
        $script:KillCalls | Should -HaveCount 0
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 0
    }

    It 'does not match a process that only mentions octo-devstack.dll inside another file name' {
        Mock -ModuleName OctoDevStack lsof { '903' }
        Mock -ModuleName OctoDevStack ps { 'dotnet /x/not-octo-devstack.dll.bak' }
        $json = Stop-OctoDevStack -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $script:KillCalls | Should -HaveCount 0
    }

    It 'is a successful no-op when nothing listens' {
        Mock -ModuleName OctoDevStack lsof { }
        Mock -ModuleName OctoDevStack ps { }
        $json = Stop-OctoDevStack -Json | ConvertFrom-Json
        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeFalse
        $script:KillCalls | Should -HaveCount 0
    }

    It 'stops by PID with Stop-Process on Windows' {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $true }
        Mock -ModuleName OctoDevStack Get-NetTCPConnection { [pscustomobject]@{ OwningProcess = 1234 } }
        Mock -ModuleName OctoDevStack Get-CimInstance { [pscustomobject]@{ CommandLine = '"C:\Program Files\dotnet\dotnet.exe" C:\dev\octo-devstack\bin\Release\net10.0\octo-devstack.dll' } }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }
        $json = Stop-OctoDevStack -Json | ConvertFrom-Json
        $json.data.stopped | Should -BeTrue
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 1 -ParameterFilter { $Id -eq 1234 }
        $script:KillCalls | Should -HaveCount 0
    }
}

Describe 'OctoDevStack with the macOS LaunchAgent' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackLaunchAgent { $true }
        Mock -ModuleName OctoDevStack Get-OctoDevStackLaunchAgentPath { '/Users/x/Library/LaunchAgents/io.meshmakers.octo-devstack.plist' }
        Mock -ModuleName OctoDevStack Get-OctoDevStackLaunchdDomain { 'gui/501' }
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Start-Sleep { }
        Mock -ModuleName OctoDevStack Stop-Process { }
        Mock -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix { 1 }
        $script:Launchctl = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName OctoDevStack Invoke-OctoDevStackLaunchctl { $script:Launchctl.Add($Arguments -join ' '); [pscustomobject]@{ ExitCode = 0; Output = '' } }
        Mock -ModuleName OctoDevStack kill { throw 'kill must not be used with the LaunchAgent' }
    }

    It 'Stop unloads the LaunchAgent instead of killing the daemon' {
        Mock -ModuleName OctoDevStack lsof { '902' }
        Mock -ModuleName OctoDevStack ps { 'dotnet /x/octo-devstack/bin/Release/net10.0/octo-devstack.dll' }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $false }

        $json = Stop-OctoDevStack -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeTrue
        $json.data.launchAgent | Should -BeTrue
        $script:Launchctl | Should -Be @('bootout gui/501/io.meshmakers.octo-devstack')
        Should -Invoke -ModuleName OctoDevStack Stop-Process -Times 0
    }

    It 'Stop leaves the LaunchAgent loaded when a foreign program holds the port' {
        Mock -ModuleName OctoDevStack lsof { '555' }
        Mock -ModuleName OctoDevStack ps { 'node /tmp/other.js' }

        $json = Stop-OctoDevStack -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.stopped | Should -BeFalse
        $script:Launchctl | Should -HaveCount 0
    }

    It 'Stop leaves the LaunchAgent loaded when nothing listens on the port' {
        Mock -ModuleName OctoDevStack lsof { }

        $json = Stop-OctoDevStack -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.stopped | Should -BeFalse
        $script:Launchctl | Should -HaveCount 0
    }

    It 'Stop reports a failure when the daemon survives bootout and Stop-Process' {
        Mock -ModuleName OctoDevStack lsof { '902' }
        Mock -ModuleName OctoDevStack ps { 'dotnet /x/octo-devstack/bin/Release/net10.0/octo-devstack.dll' }
        Mock -ModuleName OctoDevStack Test-OctoDevStackProcessAlive { $true }

        $json = Stop-OctoDevStack -TimeoutSeconds 0 -Json -ErrorAction SilentlyContinue | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.stopped | Should -BeFalse
        $json.data.error | Should -BeLike '*still running*'
    }

    It 'Start loads the LaunchAgent instead of starting a second daemon' {
        $script:Health = 0
        Mock -ModuleName OctoDevStack Test-OctoDevStackHealth { $script:Health++; $script:Health -gt 2 }
        Mock -ModuleName OctoDevStack Get-OctoDevStackListener { @() }
        $dir = Join-Path $TestDrive 'devstack'
        New-Item -ItemType Directory -Force -Path (Join-Path $dir 'bin/Release/net10.0') | Out-Null
        Set-Content (Join-Path $dir 'bin/Release/net10.0/octo-devstack.dll') 'x'

        $json = Start-OctoDevStack -Path $dir -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.started | Should -BeTrue
        $json.data.launchAgent | Should -BeTrue
        $script:Launchctl | Should -Be @('bootstrap gui/501 /Users/x/Library/LaunchAgents/io.meshmakers.octo-devstack.plist')
        Should -Invoke -ModuleName OctoDevStack Start-OctoDevStackDetachedUnix -Times 0
    }
}

Describe 'Get-OctoDevStackStatus' {
    BeforeEach {
        Mock -ModuleName OctoDevStack Test-OctoDevStackWindows { $false }
        Mock -ModuleName OctoDevStack Test-OctoDevStackMacOS { $false }
    }

    It 'reports an installed, built and running daemon' {
        Set-GitMock -Branch 'main' -Commit 'def5678' -Behind 2
        Mock -ModuleName OctoDevStack Invoke-RestMethod { @{ status = 'ok' } }
        Mock -ModuleName OctoDevStack lsof { '321' }
        Mock -ModuleName OctoDevStack ps { 'dotnet octo-devstack.dll --url http://127.0.0.1:5090' }
        $path = New-FakeCheckout 'status' -Built

        $json = Get-OctoDevStackStatus -Path $path -Json | ConvertFrom-Json

        $json.schemaVersion | Should -Be 1
        $json.command | Should -Be 'Get-OctoDevStackStatus'
        $expected = @('installed', 'path', 'branch', 'commit', 'dirty', 'behind', 'dllBuilt', 'dll', 'running', 'pid', 'healthy',
            'port', 'url', 'mcpUrl', 'statusPage', 'configPath', 'logPath', 'statePath', 'launchAgent')
        @($json.data.PSObject.Properties.Name) | Should -Be $expected
        $json.data.installed | Should -BeTrue
        $json.data.branch | Should -Be 'main'
        $json.data.commit | Should -Be 'def5678'
        $json.data.dirty | Should -BeFalse
        $json.data.behind | Should -Be 2
        $json.data.dllBuilt | Should -BeTrue
        $json.data.running | Should -BeTrue
        $json.data.healthy | Should -BeTrue
        $json.data.pid | Should -Be 321
        $json.data.mcpUrl | Should -Be 'http://127.0.0.1:5090/mcp'
        $json.data.configPath | Should -Be $env:OCTO_DEVSTACK_CONFIG
        $json.data.logPath | Should -Be (Join-Path $env:OCTO_DEVSTACK_STATE 'daemon.log')
        $json.data.launchAgent | Should -BeNullOrEmpty
        Should -Invoke -ModuleName OctoDevStack git -Times 0 -ParameterFilter { ($args -join ' ') -match 'fetch|pull' }
    }

    It 'reports a missing checkout without calling git' {
        Set-GitMock
        Mock -ModuleName OctoDevStack Invoke-RestMethod { throw 'connection refused' }
        Mock -ModuleName OctoDevStack lsof { }
        Mock -ModuleName OctoDevStack ps { }

        $json = Get-OctoDevStackStatus -Path (Join-Path $TestDrive 'nothing-here') -Json | ConvertFrom-Json

        $json.data.installed | Should -BeFalse
        $json.data.dllBuilt | Should -BeFalse
        $json.data.running | Should -BeFalse
        $json.data.pid | Should -BeNullOrEmpty
        $json.data.behind | Should -BeNullOrEmpty
        $script:GitCalls | Should -HaveCount 0
    }
}
