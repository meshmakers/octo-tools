#Requires -Modules Pester
<#
    Pester tests for the kill scope of Remove-OctoEnvironment (AB#9660): the environment's own dotnet processes are
    stopped before anything is removed, on every OS; in-place worktrees, the base lane, other lanes, the octo-devstack
    daemon and non-dotnet processes never are.

    No real process is read or stopped: the process table is the fake of OctoEnvironment.TestHelpers.ps1
    ($script:FakeDotnet), whose processes are matched by their command line (entry assembly), so the tests behave the
    same on Windows, macOS and Linux.

    Run:  Invoke-Pester ./tests/OctoEnvironment.RemoveKill.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1')

    function Add-FakeDotnet([int]$id, [string]$dll, [switch]$unkillable, [string]$name = 'dotnet') {
        $process = [pscustomobject]@{ Id = $id; Name = $name; CommandLine = "dotnet $dll"; Modules = @() }
        $script:FakeDotnet.Processes.Add([pscustomobject]@{ Process = $process; Cwd = $null; Unkillable = [bool]$unkillable })
    }
}

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'Remove-OctoEnvironment stops the environment''s dotnet processes first (AB#9660)' {
    BeforeEach {
        $script:FakeDotnet.Processes.Clear()
        $script:FakeDotnet.Stopped.Clear()
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-k' -repos octo-sdk -branchName 'feature/k' -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-k'
        $script:wt = Join-Path $envPath 'octo-sdk'
        # an in-place worktree of the environment, outside wt-env-k
        $script:inPlace = Join-Path $ws.Main 'octo-identity-services/.claude/worktrees/feature-k'
        Invoke-TestGit (Join-Path $ws.Main 'octo-identity-services') worktree add -q -b 'reimar/feature-k' $inPlace | Out-Null
        Mock -ModuleName OctoEnvironment Get-OctoProcessesUnderFolder { @() }
        (Get-Doc (Add-OctoEnvironmentRepo -env 'env-k' -path $inPlace -inPlace -Json)).data.success | Should -BeTrue
        # another lane next to it
        $script:otherLane = Join-Path $ws.Root 'wt-env-other/octo-sdk'

        Add-FakeDotnet 501 (Join-Path $wt 'bin/DebugL/net10.0/Meshmakers.Octo.Sdk.Tests.dll')          # in scope: stopped
        Add-FakeDotnet 502 (Join-Path $inPlace 'bin/DebugL/net10.0/IdentityServices.dll')              # in-place worktree
        Add-FakeDotnet 503 (Join-Path $ws.Main 'octo-sdk/bin/DebugL/net10.0/Meshmakers.Octo.Sdk.dll')  # base lane
        Add-FakeDotnet 504 (Join-Path $otherLane 'bin/DebugL/net10.0/Other.dll')                       # another lane
        Add-FakeDotnet 505 (Join-Path $envPath 'octo-devstack/octo-devstack.dll')                      # the daemon, never
        Add-FakeDotnet 506 (Join-Path $wt 'build.dll') -name 'pwsh'                                    # not dotnet: never listed
    }

    It 'stops exactly the processes of the environment folder before git worktree remove and reports them (-Json kill)' {
        # The worktree must still be there when the process is stopped (stop before git worktree remove).
        $script:WorktreeAtStop = [System.Collections.Generic.List[bool]]::new()
        Mock -ModuleName Invoke-KillDotnet Stop-Process {
            $script:WorktreeAtStop.Add((Test-Path -LiteralPath $script:wt))
            foreach ($one in @($Id)) { $script:FakeDotnet.Stopped.Add([int]$one) }
        }

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-k' -Json)

        $doc.data.success | Should -BeTrue
        @($doc.data.kill.processes | ForEach-Object { "$($_.pid):$($_.name):$($_.reason)" }) | Should -Be @('501:dotnet:commandLine')
        $doc.data.kill.killedCount | Should -Be 1
        @($doc.data.kill.roots) | Should -Be @($envPath)
        @($script:FakeDotnet.Stopped) | Should -Be @(501)
        @($script:WorktreeAtStop) | Should -Be @($true)
        Test-Path $envPath | Should -BeFalse
        Test-Path $inPlace | Should -BeTrue
    }

    It 'names the stopped processes in the console' {
        $output = Remove-OctoEnvironment -env 'env-k' 6>&1 | Out-String
        $output | Should -Match 'Stopped dotnet process 501 dotnet of env-k \(commandLine\)'
        @($script:FakeDotnet.Stopped) | Should -Be @(501)
    }

    It 'refuses the removal while a matched process still runs, and removes nothing' {
        $script:FakeDotnet.Processes.Clear()
        Add-FakeDotnet 511 (Join-Path $wt 'bin/DebugL/net10.0/Svc.dll') -unkillable

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-k' -Json)

        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'nothing removed: dotnet process\(es\) of the environment still running: 511'
        Test-Path $wt | Should -BeTrue
        Test-Path (Join-Path $envPath '.octo/environment.json') | Should -BeTrue
    }

    It 'a refused check (dirty worktree) stops no process' {
        Set-Content -Path (Join-Path $wt 'untracked.txt') -Value 'x'
        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-k' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'octo-sdk: uncommitted changes'
        @($script:FakeDotnet.Stopped).Count | Should -Be 0
    }

    It '-WhatIf lists the processes it would stop and stops none' {
        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-k' -WhatIf -Json)
        $doc.data.dryRun | Should -BeTrue
        @($doc.data.kill.processes.pid) | Should -Be @(501)
        $doc.data.kill.killedCount | Should -Be 0
        @($script:FakeDotnet.Stopped).Count | Should -Be 0
        Test-Path $wt | Should -BeTrue
    }
}
