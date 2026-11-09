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
                (New-FakeProcess 104 -command "dotnet $(Join-Path $script:Lane 'octo-cli/bin/DebugL/net10.0/octo-cli.dll')")
            )
        }
        Mock -ModuleName Invoke-KillDotnet lsof {
            @('p101', "n$(Join-Path $script:Lane 'octo-sdk/bin/DebugL/net10.0')",
                'p102', "n$script:Daemon",
                'p103', "n$(Join-Path $script:OtherLane 'octo-sdk/bin/DebugL/net10.0')",
                'p104', 'n/tmp')
        }
    }

    It 'matches lane processes by working directory and command line, stops nothing, reports them' {
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

    It 'returns the matched processes without -Json and matches case-insensitively' {
        $found = @(Invoke-KillDotnet -branchRootPath $script:Lane.ToUpperInvariant() 6>$null)
        @($found.pid) | Should -Be @(101, 104)
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
