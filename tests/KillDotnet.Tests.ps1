#Requires -Modules Pester
<#
    Pester tests for Invoke-KillDotnet (legacy: every dotnet process; lane mode: -branchRootPath).

    No process is ever stopped or started: Get-Process, lsof, Stop-Process, `dotnet` and the OS check
    (Test-OctoKillDotnetWindows) are mocked, the "processes" are plain objects.

    Run:  Invoke-Pester ./tests/KillDotnet.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-KillDotnet.psm1') -Force

    $script:Lane = Join-Path $TestDrive 'meshmakers/main'
    # Same prefix without the separator: must NOT count as the lane.
    $script:OtherLane = Join-Path $TestDrive 'meshmakers/main2'
    $script:Daemon = Join-Path $TestDrive 'dev/meshmakers/octo-devstack'
    # Lane mode refuses folders that do not look like a lane: give the fake lane a repository folder.
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Lane 'octo-sdk'), $script:Daemon | Out-Null

    function New-FakeProcess([int]$id, [string]$name = 'dotnet', [string]$command = '', [string[]]$modules = @()) {
        [pscustomobject]@{ Id = $id; Name = $name; CommandLine = $command; Modules = @($modules | ForEach-Object { [pscustomobject]@{ FileName = $_ } }) }
    }
}

Describe 'Invoke-KillDotnet -branchRootPath on macOS/Linux' {
    BeforeEach {
        Mock -ModuleName Invoke-KillDotnet Test-OctoKillDotnetWindows { $false }
        Mock -ModuleName Invoke-KillDotnet Stop-Process { }
        Mock -ModuleName Invoke-KillDotnet dotnet { }
        Mock -ModuleName Invoke-KillDotnet Get-Process {
            @(
                (New-FakeProcess 101 -command 'dotnet Meshmakers.Octo.Sdk.dll'),
                (New-FakeProcess 102 -command 'dotnet octo-devstack.dll'),
                (New-FakeProcess 103 -command 'dotnet Meshmakers.Octo.Sdk.dll'),
                (New-FakeProcess 104 -command "dotnet $(Join-Path $script:Lane 'octo-cli/bin/DebugL/net10.0/octo-cli.dll')"),
                # the daemon only mentions a lane path in an ARGUMENT - not the lane's
                (New-FakeProcess 105 -command "dotnet $(Join-Path $script:Daemon 'octo-devstack.dll') --events $(Join-Path $script:Lane 'x.jsonl')")
            )
        }
        Mock -ModuleName Invoke-KillDotnet lsof {
            @('p101', "n$(Join-Path $script:Lane 'octo-sdk/bin/DebugL/net10.0')",
                'p102', "n$script:Daemon",
                'p103', "n$(Join-Path $script:OtherLane 'octo-sdk/bin/DebugL/net10.0')",
                'p104', 'n/tmp',
                'p105', "n$script:Daemon")
        }
    }

    It 'matches lane processes by working directory and entry assembly, stops nothing, reports them' {
        $json = Invoke-KillDotnet -branchRootPath $script:Lane -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $json.data.scoped | Should -BeTrue
        $json.data.buildServerShutdown | Should -BeFalse
        $json.data.killedCount | Should -Be 0
        @($json.data.processes.pid) | Should -Be @(101, 104)
        @($json.data.processes.reason) | Should -Be @('cwd', 'commandLine')
        @($json.data.processes.name) | Should -Be @('dotnet', 'dotnet')
        Should -Invoke -ModuleName Invoke-KillDotnet Stop-Process -Times 0
        Should -Invoke -ModuleName Invoke-KillDotnet dotnet -Times 0
        Should -Invoke -ModuleName Invoke-KillDotnet lsof -Times 1 -Exactly
    }

    It 'returns the matched processes without -Json' {
        $found = @(Invoke-KillDotnet -branchRootPath $script:Lane 6>$null)
        @($found.pid) | Should -Be @(101, 104)
    }

    It 'resolves a relative -branchRootPath against the current location' {
        Push-Location (Join-Path $TestDrive 'meshmakers')
        try { $json = Invoke-KillDotnet -branchRootPath 'main' -Json | ConvertFrom-Json }
        finally { Pop-Location }
        @($json.data.processes.pid) | Should -Be @(101, 104)

        Push-Location $script:Lane
        try { $json = Invoke-KillDotnet -branchRootPath '.' -Json | ConvertFrom-Json }
        finally { Pop-Location }
        @($json.data.processes.pid) | Should -Be @(101, 104)
    }

    It 'refuses a folder that is no lane or does not exist, without looking at any process' {
        $plain = Join-Path $TestDrive 'plain-folder'
        New-Item -ItemType Directory -Force -Path (Join-Path $plain 'something') | Out-Null
        foreach ($case in @(@{ Path = $plain; Message = '*does not look like a lane*' }, @{ Path = (Join-Path $TestDrive 'missing'); Message = '*does not exist*' })) {
            $json = Invoke-KillDotnet -branchRootPath $case.Path -Json 2>$null | ConvertFrom-Json
            $json.data.success | Should -BeFalse
            $json.data.error | Should -BeLike $case.Message
        }
        Should -Invoke -ModuleName Invoke-KillDotnet Get-Process -Times 0
        Should -Invoke -ModuleName Invoke-KillDotnet Stop-Process -Times 0
    }

    It 'matching is case-insensitive and needs the separator after the lane folder' {
        InModuleScope Invoke-KillDotnet -Parameters @{ lane = $script:Lane; other = $script:OtherLane } {
            $candidates = @(
                [pscustomobject]@{ Pid = 1; Name = 'dotnet'; Command = ''; Cwd = (Join-Path $lane 'octo-sdk').ToUpperInvariant(); Modules = @() },
                [pscustomobject]@{ Pid = 2; Name = 'dotnet'; Command = ''; Cwd = (Join-Path $other 'octo-sdk'); Modules = @() },
                [pscustomobject]@{ Pid = 3; Name = 'dotnet'; Command = 'dotnet Relative.dll'; Cwd = $null; Modules = @() }
            )
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $lane).pid | Should -Be @(1)
        }
    }

    It 'takes the entry assembly, not other arguments, from the command line' {
        InModuleScope Invoke-KillDotnet {
            Get-OctoEntryAssemblyPath -command 'dotnet /a/b/App.dll --events /lane/x.jsonl --plugin /lane/p.dll' | Should -Be '/a/b/App.dll'
            Get-OctoEntryAssemblyPath -command '"C:\Program Files\dotnet\dotnet.exe" exec --depsfile x.json C:\lane\App.dll' | Should -Be 'C:\lane\App.dll'
            Get-OctoEntryAssemblyPath -command '/lane/octo-sdk/bin/Meshmakers.Apphost.exe --x /other/y.dll' | Should -Be '/lane/octo-sdk/bin/Meshmakers.Apphost.exe'
            Get-OctoEntryAssemblyPath -command 'dotnet App.dll' -cwd '/lane/octo-sdk/bin' | Should -Be (Join-Path '/lane/octo-sdk/bin' 'App.dll')
            Get-OctoEntryAssemblyPath -command 'dotnet App.dll' | Should -BeNullOrEmpty
            Get-OctoEntryAssemblyPath -command 'pwsh -c x.dll' | Should -BeNullOrEmpty
        }
    }

    It 'without -branchRootPath it stays the legacy no-op' {
        $json = Invoke-KillDotnet -Json | ConvertFrom-Json
        $json.data.skipped | Should -BeTrue
        $json.data.killedCount | Should -Be 0
        Should -Invoke -ModuleName Invoke-KillDotnet Get-Process -Times 0
        Should -Invoke -ModuleName Invoke-KillDotnet Stop-Process -Times 0
    }
}

Describe 'Invoke-KillDotnet on Windows' {
    BeforeEach {
        Mock -ModuleName Invoke-KillDotnet Test-OctoKillDotnetWindows { $true }
        Mock -ModuleName Invoke-KillDotnet Stop-Process { }
        Mock -ModuleName Invoke-KillDotnet dotnet { }
        Mock -ModuleName Invoke-KillDotnet lsof { }
    }

    It 'lane mode stops only processes with a module or command line under the lane, without build-server shutdown' {
        Mock -ModuleName Invoke-KillDotnet Get-Process {
            @(
                (New-FakeProcess 201 -command 'dotnet Meshmakers.Octo.Sdk.dll' -modules @('C:\Program Files\dotnet\dotnet.exe', (Join-Path $script:Lane 'octo-sdk/bin/DebugL/net10.0/Meshmakers.Octo.Sdk.dll'))),
                (New-FakeProcess 202 -command 'dotnet octo-devstack.dll' -modules @((Join-Path $script:Daemon 'octo-devstack.dll'))),
                (New-FakeProcess 203 -command "dotnet $(Join-Path $script:Lane 'octo-cli/bin/DebugL/net10.0/octo-cli.dll')"),
                (New-FakeProcess 204 -command 'dotnet x.dll' -modules @((Join-Path $script:OtherLane 'octo-sdk/bin/x.dll')))
            )
        }

        $json = Invoke-KillDotnet -branchRootPath $script:Lane -Json | ConvertFrom-Json

        @($json.data.processes | ForEach-Object { "$($_.pid):$($_.reason)" }) | Should -Be @('201:module', '203:commandLine')
        $json.data.killedCount | Should -Be 2
        $json.data.buildServerShutdown | Should -BeFalse
        Should -Invoke -ModuleName Invoke-KillDotnet Stop-Process -Times 2 -Exactly
        Should -Invoke -ModuleName Invoke-KillDotnet Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -contains 201 }
        Should -Invoke -ModuleName Invoke-KillDotnet Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -contains 203 }
        Should -Invoke -ModuleName Invoke-KillDotnet dotnet -Times 0
        Should -Invoke -ModuleName Invoke-KillDotnet lsof -Times 0
    }

    It 'without -branchRootPath it keeps the legacy behaviour: build-server shutdown and every dotnet process' {
        Mock -ModuleName Invoke-KillDotnet Get-Process {
            @((New-FakeProcess 301), (New-FakeProcess 302 -command 'dotnet octo-devstack.dll'), (New-FakeProcess 303 -name 'pwsh'))
        }

        $json = Invoke-KillDotnet -Json | ConvertFrom-Json

        $json.data.killedCount | Should -Be 2
        Should -Invoke -ModuleName Invoke-KillDotnet dotnet -Times 1 -Exactly
        Should -Invoke -ModuleName Invoke-KillDotnet Stop-Process
    }
}
