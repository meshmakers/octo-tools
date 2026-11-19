#Requires -Modules Pester
<#
    Pester tests for the Windows findings of the feature environments (AB#8912, AB#8955): bounded, non-interactive
    network git calls, a JSON document from Invoke-BuildEnvironment when Invoke-BuildRange throws, and the base lane
    as any layout passed with -base (Windows <root>/main, Mac <root>/branches/main).

    Part of the OctoEnvironment tests (tests/Invoke-ParallelPester.ps1). Setup and fixtures:
    tests/OctoEnvironment.TestHelpers.ps1 - everything runs in TestDrive. No test reaches a real remote: the ssh
    command is a local shell script.

    Run:  Invoke-Pester ./tests/OctoEnvironment.Windows.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1')

    # A repository whose origin is an ssh URL that is never contacted: core.sshCommand runs a local script instead.
    function New-SshFakeRepo([string]$name, [string]$sshScriptBody) {
        $repo = Join-Path $TestDrive "ssh/$name"
        if (Test-Path -LiteralPath $repo) { Remove-Item -LiteralPath $repo -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        Invoke-TestGit $repo init -q -b main | Out-Null
        Set-Content -Path (Join-Path $repo 'a.txt') -Value 'a'
        Invoke-TestGit $repo add -A | Out-Null
        Invoke-TestGit $repo commit -q -m 'initial' | Out-Null
        Invoke-TestGit $repo remote add origin 'ssh://git@example.invalid/meshmakers/fake.git' | Out-Null
        # what the checkout "last fetched"
        Invoke-TestGit $repo update-ref refs/remotes/origin/main HEAD | Out-Null
        $script = Join-Path $TestDrive "ssh/$name-ssh.sh"
        [IO.File]::WriteAllText($script, "#!/bin/sh`n$sshScriptBody`n")
        Invoke-TestGit $repo config core.sshCommand "sh '$($script -replace '\\', '/')' --configured-option" | Out-Null
        return $repo
    }
}

AfterAll { Restore-OctoEnvironmentTestState }   # also clears the read-only flag git puts on its objects (TestDrive cleanup)

Describe 'Network git calls are bounded and non-interactive (AB#8955)' {
    BeforeEach {
        $script:previousTimeout = $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS
        $script:previousSshCommand = $env:GIT_SSH_COMMAND
        $env:GIT_SSH_COMMAND = $null
        InModuleScope OctoEnvironment { $script:UnreachableGitHosts.Clear() }
    }
    AfterEach {
        $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = $script:previousTimeout
        $env:GIT_SSH_COMMAND = $script:previousSshCommand
    }

    It 'an ssh that never answers is stopped after the timeout' {
        $repo = New-SshFakeRepo 'hang' 'sleep 600'
        $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = '3'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = InModuleScope OctoEnvironment -Parameters @{ repo = $repo } {
            Invoke-OctoEnvironmentGit -path $repo -arguments @('ls-remote', '--symref', 'origin', 'HEAD') -noPrompt
        }
        $watch.Stop()
        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -Not -Be 0
        "$($result.Output)" | Should -Match 'did not finish within 3 s'
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'the base falls back to the last fetched ref with a warning, without waiting for the fetch as well' {
        $repo = New-SshFakeRepo 'hang-base' 'sleep 600'
        $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = '3'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $base = InModuleScope OctoEnvironment -Parameters @{ repo = $repo } { Resolve-OctoEnvironmentBase -source $repo }
        $watch.Stop()
        $base.Ref | Should -Be 'origin/main'
        $base.Fetched | Should -BeFalse
        $base.Commit | Should -Be (Invoke-TestGit $repo rev-parse HEAD)
        "$($base.Warnings)" | Should -Match 'origin did not answer .*did not finish within 3 s.* origin/main is used as last fetched'
        # one timeout (ls-remote), not two (ls-remote + fetch)
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
    }

    It 'ssh runs with BatchMode and ConnectTimeout and keeps the configured ssh command' {
        $record = Join-Path $TestDrive 'ssh/args.txt'
        $repo = New-SshFakeRepo 'record' "echo `"`$*`" > '$($record -replace '\\', '/')'; exit 255"
        $result = InModuleScope OctoEnvironment -Parameters @{ repo = $repo } {
            Invoke-OctoEnvironmentGit -path $repo -arguments @('ls-remote', 'origin', 'HEAD') -noPrompt
        }
        $result.ExitCode | Should -Not -Be 0
        $result.TimedOut | Should -BeFalse
        $arguments = Get-Content -LiteralPath $record -Raw
        $arguments | Should -Match '--configured-option'
        $arguments | Should -Match '-o BatchMode=yes'
        $arguments | Should -Match '-o ConnectTimeout=\d+'

        # GIT_SSH_COMMAND wins over core.sshCommand, as in git
        $env:GIT_SSH_COMMAND = "sh '$((Join-Path $TestDrive 'ssh/record-ssh.sh') -replace '\\', '/')' --from-environment"
        Remove-Item -LiteralPath $record
        InModuleScope OctoEnvironment -Parameters @{ repo = $repo } {
            Invoke-OctoEnvironmentGit -path $repo -arguments @('ls-remote', 'origin', 'HEAD') -noPrompt | Out-Null
        }
        $arguments = Get-Content -LiteralPath $record -Raw
        $arguments | Should -Match '--from-environment'
        $arguments | Should -Not -Match '--configured-option'
        $arguments | Should -Match '-o BatchMode=yes'
    }

    It 'a host that timed out is skipped at once by the next call' {
        $repo = New-SshFakeRepo 'hang-twice' 'sleep 600'
        $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = '2'
        InModuleScope OctoEnvironment -Parameters @{ repo = $repo } {
            (Invoke-OctoEnvironmentGit -path $repo -arguments @('ls-remote', 'origin', 'HEAD') -noPrompt).TimedOut | Should -BeTrue
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $second = Invoke-OctoEnvironmentGit -path $repo -arguments @('fetch', '--quiet', 'origin', 'main') -noPrompt
            $watch.Stop()
            $second.TimedOut | Should -BeTrue
            "$($second.Output)" | Should -Match 'skipped: example\.invalid did not answer within 2 s'
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 2
        }
    }

    It 'plink gets -batch instead of OpenSSH options; a GIT_SSH program is left alone' {
        InModuleScope OctoEnvironment -Parameters @{ repo = (New-SshFakeRepo 'plink' 'exit 255') } {
            $env:GIT_SSH_COMMAND = '"C:/Program Files/TortoiseGit/bin/TortoisePlink.exe" -ssh'
            Get-OctoNonInteractiveSshCommand -path $repo | Should -Be '"C:/Program Files/TortoiseGit/bin/TortoisePlink.exe" -ssh -batch'
            $env:GIT_SSH_COMMAND = 'C:/Windows/System32/OpenSSH/ssh.exe'
            Get-OctoNonInteractiveSshCommand -path $repo -connectTimeoutSeconds 7 | Should -Be 'C:/Windows/System32/OpenSSH/ssh.exe -o BatchMode=yes -o ConnectTimeout=7'
            # the enforced options come first: OpenSSH takes the first value, a configured BatchMode=no cannot win
            $env:GIT_SSH_COMMAND = 'ssh -o BatchMode=no -o ConnectTimeout=300 -p 2222'
            Get-OctoNonInteractiveSshCommand -path $repo -connectTimeoutSeconds 7 | Should -Be 'ssh -o BatchMode=yes -o ConnectTimeout=7 -o BatchMode=no -o ConnectTimeout=300 -p 2222'
            $env:GIT_SSH_COMMAND = '"C:/Program Files/OpenSSH/ssh.exe" -i key'
            Get-OctoNonInteractiveSshCommand -path $repo -connectTimeoutSeconds 7 | Should -Be '"C:/Program Files/OpenSSH/ssh.exe" -o BatchMode=yes -o ConnectTimeout=7 -i key'
            $env:GIT_SSH_COMMAND = $null
            & git -C $repo config --unset core.sshCommand
            $previous = $env:GIT_SSH
            try {
                $env:GIT_SSH = 'C:/tools/plink.exe'
                Get-OctoNonInteractiveSshCommand -path $repo | Should -BeNullOrEmpty
            }
            finally { $env:GIT_SSH = $previous }
        }
    }

    It 'finds the host of ssh, scp-like and https remotes, none for a local path' {
        $repo = New-SshFakeRepo 'hosts' 'exit 255'
        InModuleScope OctoEnvironment -Parameters @{ repo = $repo } {
            Get-OctoGitRemoteHost -path $repo -arguments @('ls-remote', '--symref', 'origin', 'HEAD') | Should -Be 'example.invalid'
            & git -C $repo remote set-url origin 'git@GitHub.com:meshmakers/x.git' | Out-Null
            Get-OctoGitRemoteHost -path $repo -arguments @('fetch', '--quiet', 'origin', 'main') | Should -Be 'github.com'
            & git -C $repo remote set-url origin 'https://user@dev.example.invalid:8443/x.git' | Out-Null
            Get-OctoGitRemoteHost -path $repo -arguments @('fetch', 'origin') | Should -Be 'dev.example.invalid'
            & git -C $repo remote set-url origin 'C:/origins/x.git' | Out-Null
            Get-OctoGitRemoteHost -path $repo -arguments @('fetch', 'origin') | Should -BeNullOrEmpty
            & git -C $repo remote set-url origin '/srv/origins/x.git' | Out-Null
            Get-OctoGitRemoteHost -path $repo -arguments @('fetch', 'origin') | Should -BeNullOrEmpty
        }
    }

    It 'the timeout is configurable, capped at an hour, and an invalid value falls back to 60 s' {
        InModuleScope OctoEnvironment {
            $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = $null
            Get-OctoGitNetworkTimeoutSeconds | Should -Be 60
            $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = '15'
            Get-OctoGitNetworkTimeoutSeconds | Should -Be 15
            $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = '3000000'
            Get-OctoGitNetworkTimeoutSeconds | Should -Be 3600
            $env:OCTO_GIT_NETWORK_TIMEOUT_SECONDS = 'soon'
            Get-OctoGitNetworkTimeoutSeconds -WarningAction SilentlyContinue | Should -Be 60
        }
    }

    It 'a local call does not change the process environment' {
        $repo = New-SshFakeRepo 'local' 'exit 255'
        $before = $env:GIT_TERMINAL_PROMPT
        InModuleScope OctoEnvironment -Parameters @{ repo = $repo } {
            (Invoke-OctoEnvironmentGit -path $repo -arguments @('ls-remote', 'origin', 'HEAD') -noPrompt).ExitCode | Should -Not -Be 0
        }
        $env:GIT_TERMINAL_PROMPT | Should -Be $before
        $env:GIT_SSH_COMMAND | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-BuildEnvironment -Json when Invoke-BuildRange throws (AB#8912)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'json-error' -repos octo-sdk -branchName 'feature/json-error' -Json | Out-Null
    }

    It 'writes a document that names the error instead of "no JSON document", then throws' {
        Mock -ModuleName OctoEnvironment Invoke-BuildRange { throw "Repository path of octo-sdk is missing: $TestDrive/nowhere" }
        $out = [System.Collections.Generic.List[object]]::new()
        { Invoke-BuildEnvironment -env 'json-error' -DryRun -skipKill -Json | ForEach-Object { $out.Add($_) } } | Should -Throw '*octo-sdk is missing*'
        $doc = Get-Doc $out
        $doc.command | Should -Be 'Invoke-BuildEnvironment'
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'Invoke-BuildRange failed: Repository path of octo-sdk is missing'
        $doc.data.error | Should -Not -Match 'no JSON document'
        $doc.data.environment.name | Should -Be 'json-error'
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'keeps the document Invoke-BuildRange wrote before it threw' {
        Mock -ModuleName OctoEnvironment Invoke-BuildRange {
            Write-OctoJson -Command 'Invoke-BuildRange' -Data ([ordered]@{ success = $false; error = 'octo-sdk failed'; repositories = @() })
            throw 'octo-sdk failed'
        }
        $out = [System.Collections.Generic.List[object]]::new()
        { Invoke-BuildEnvironment -env 'json-error' -DryRun -skipKill -Json | ForEach-Object { $out.Add($_) } } | Should -Throw '*octo-sdk failed*'
        $doc = Get-Doc $out
        @($out | Where-Object { "$_" -match '"command"' }).Count | Should -Be 1
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Be 'octo-sdk failed'
    }

    It 'an empty output is named as such' {
        Mock -ModuleName OctoEnvironment Invoke-BuildRange { }
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'json-error' -DryRun -skipKill -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'no JSON document \(no output\)'
    }

    It 'a running-process scan that cannot read a command line does not fail -DryRun' -Skip:(-not $IsWindows) {
        # Synthetic candidates as the Windows scan delivers them: leading whitespace, empty first token.
        Mock -ModuleName Invoke-BuildRange Get-CimInstance {
            @([pscustomobject]@{ ProcessId = 1; CommandLine = '   x.exe' }, [pscustomobject]@{ ProcessId = 2; CommandLine = ' ' })
        }
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'json-error' -DryRun -skipKill -Json -ErrorAction Stop)
        $doc.data.whatIf | Should -BeTrue
        "$($doc.data.error)" | Should -BeNullOrEmpty
        @($doc.data.repositories.repo) | Should -Be @('octo-sdk')
        @($doc.data.runningProcesses).Count | Should -Be 0
    }
}

Describe 'The base lane is any layout passed with -base (AB#8912)' {
    It 'Windows: <root>/main next to the environments' {
        $fake = New-FakeWorkspace
        $windowsMain = Join-Path $fake.Root 'main'
        Move-Item -LiteralPath $fake.Main -Destination $windowsMain
        $doc = Get-Doc (New-OctoEnvironment -env 'win-layout' -repos octo-sdk -branchName 'feature/win' -base 'main' -Json)
        $doc.data.success | Should -BeTrue
        $envPath = Join-Path $fake.Root 'wt-win-layout'
        (Get-Content (Join-Path $envPath '.octo/environment.json') -Raw | ConvertFrom-Json).base | Should -Be 'main'

        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { throw 'no build in a dry run' }
        $plan = Get-Doc (Invoke-BuildEnvironment -env 'win-layout' -DryRun -skipKill -Json)
        $plan.data.whatIf | Should -BeTrue
        @($plan.data.repositories.repo) | Should -Be @('octo-sdk')
        $plan.data.branchRootPath | Should -Be $envPath
        $plan.data.environment.base | Should -Be $windowsMain
    }

    It 'Mac: <root>/branches/main' {
        $fake = New-FakeWorkspace
        $doc = Get-Doc (New-OctoEnvironment -env 'mac-layout' -repos octo-sdk -branchName 'feature/mac' -base 'branches/main' -Json)
        $doc.data.success | Should -BeTrue
        $envPath = Join-Path $fake.Root 'wt-mac-layout'
        (Get-Content (Join-Path $envPath '.octo/environment.json') -Raw | ConvertFrom-Json).base | Should -Be 'branches/main'

        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { throw 'no build in a dry run' }
        $plan = Get-Doc (Invoke-BuildEnvironment -env 'mac-layout' -DryRun -skipKill -Json)
        @($plan.data.repositories.repo) | Should -Be @('octo-sdk')
        $plan.data.environment.base | Should -Be $fake.Main
    }
}
