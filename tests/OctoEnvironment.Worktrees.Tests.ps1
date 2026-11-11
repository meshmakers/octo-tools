#Requires -Modules Pester
<#
    Pester tests for feature environments (OctoEnvironment.psm1): adding and adopting worktrees, the origin base, developer tools and the atomic create (AB#8815).

    Part of the OctoEnvironment tests, split over several files so they can run in parallel
    (tests/Invoke-ParallelPester.ps1). Setup and fixtures: tests/OctoEnvironment.TestHelpers.ps1 - everything runs in
    TestDrive, see OctoEnvironment.Tests.ps1.

    Run:  Invoke-Pester ./tests/OctoEnvironment.Worktrees.Tests.ps1
#>

BeforeAll { . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1') }

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'Add-OctoEnvironmentRepo' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-c' -repos octo-construction-kit-engine -branchName 'feature/c' -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-c'
    }

    It 'adds a consumer detached at the base checkout''s commit' {
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-c' -repo octo-identity-services -role consumer -Json)
        $doc.data.success | Should -BeTrue
        $wt = Join-Path $envPath 'octo-identity-services'
        (Invoke-TestGit $wt rev-parse --abbrev-ref HEAD) | Should -Be 'HEAD'
        (Invoke-TestGit $wt rev-parse HEAD) | Should -Be (Invoke-TestGit (Join-Path $ws.Main 'octo-identity-services') rev-parse HEAD)
        $manifest = Get-Content (Join-Path $envPath '.octo/environment.json') -Raw | ConvertFrom-Json
        ($manifest.repos | Where-Object name -eq 'octo-identity-services').role | Should -Be 'consumer'
        ($manifest.repos | Where-Object name -eq 'octo-identity-services').branch | Should -BeNullOrEmpty
    }

    It '-addAffected also adds the libraries between the feature repositories and the consumer' {
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-c' -repo asset-repo-services -role consumer -addAffected -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.added.name) | Should -Be @('octo-asset-repo-services', 'octo-sdk')
        @($doc.data.added.role) | Should -Be @('consumer', 'consumer')
        Test-Path (Join-Path $envPath 'octo-sdk') | Should -BeTrue
        @((Get-Doc (Get-OctoAffectedRepos -env 'env-c' -Json)).data.affected | Where-Object { -not $_.inEnvironment } | ForEach-Object repo) | Should -Be @('octo-cli')
    }

    It 'adds a feature repository on the environment''s branch and is a no-op for a repository already present' {
        (Get-Doc (Add-OctoEnvironmentRepo -env 'env-c' -repo octo-sdk -Json)).data.success | Should -BeTrue
        (Invoke-TestGit (Join-Path $envPath 'octo-sdk') rev-parse --abbrev-ref HEAD) | Should -Be 'feature/c'
        (Get-Doc (Add-OctoEnvironmentRepo -env 'env-c' -repo octo-sdk -Json)).data.added.Count | Should -Be 0
    }

    It 'a consumer worktree does not block Remove-OctoEnvironment, a commit in it does' {
        Add-OctoEnvironmentRepo -env 'env-c' -repo octo-identity-services -role consumer -Json | Out-Null
        $wt = Join-Path $envPath 'octo-identity-services'
        Set-Content -Path (Join-Path $wt 'x.txt') -Value 'x'
        Invoke-TestGit $wt add -A | Out-Null
        Invoke-TestGit $wt commit -q -m x | Out-Null
        (Get-Doc (Remove-OctoEnvironment -env 'env-c' -Json)).data.error | Should -Match 'octo-identity-services: 1 unpushed commit'
        Invoke-TestGit $wt reset -q --hard HEAD~1 | Out-Null
        (Get-Doc (Remove-OctoEnvironment -env 'env-c' -Json)).data.success | Should -BeTrue
    }
}

Describe 'Add-OctoEnvironmentRepo -path (adopting existing worktrees)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env env-a -repos mm-common -branchName 'feature/a' -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-a'
        # octo-claude-pm flat worktree next to the checkouts, with uncommitted work
        $script:flat = Join-Path $ws.Root 'wt-odysseus-kind-octo-sdk'
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree add -q -b 'reimar/AB#5_flat' $flat | Out-Null
        Set-Content -Path (Join-Path $flat 'wip.txt') -Value 'work in progress'
        # Claude Code worktree inside a repository
        $script:claude = Join-Path $ws.Main 'octo-identity-services/.claude/worktrees/feature-x'
        Invoke-TestGit (Join-Path $ws.Main 'octo-identity-services') worktree add -q -b 'reimar/feature-x' $claude | Out-Null
        Mock -ModuleName OctoEnvironment Get-OctoProcessesUnderFolder { @() }
    }

    It 'moves a flat octo-claude-pm worktree into the environment, uncommitted work included, and reports both paths' {
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env env-a -path $flat -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.repo | Should -Be 'octo-sdk'
        $doc.data.oldPath | Should -Be $flat
        $doc.data.newPath | Should -Be (Join-Path $envPath 'octo-sdk')
        $doc.data.inPlace | Should -BeFalse
        Test-Path $flat | Should -BeFalse
        Get-Content (Join-Path $envPath 'octo-sdk/wip.txt') -Raw | Should -Match 'work in progress'
        (Invoke-TestGit (Join-Path $envPath 'octo-sdk') rev-parse --abbrev-ref HEAD) | Should -Be 'reimar/AB#5_flat'
        $manifest = Get-Content (Join-Path $envPath '.octo/environment.json') -Raw | ConvertFrom-Json
        $entry = $manifest.repos | Where-Object name -eq 'octo-sdk'
        $entry.path | Should -Be (Join-Path $envPath 'octo-sdk')
        $entry.branch | Should -Be 'reimar/AB#5_flat'
        $entry.baseCommit | Should -Be (Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') rev-parse HEAD)
    }

    It 'moves a Claude Code worktree from <repo>/.claude/worktrees' {
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env env-a -path $claude -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.repo | Should -Be 'octo-identity-services'
        Test-Path $claude | Should -BeFalse
        (Invoke-TestGit (Join-Path $envPath 'octo-identity-services') rev-parse --abbrev-ref HEAD) | Should -Be 'reimar/feature-x'
    }

    It 'refuses to move a locked worktree or one a process runs from; -WhatIf moves nothing' {
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree lock $flat | Out-Null
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env env-a -path $flat -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'locked'
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree unlock $flat | Out-Null

        $script:running = @([pscustomobject]@{ pid = 4711; name = 'zsh'; reason = 'cwd' })
        Mock -ModuleName OctoEnvironment Get-OctoProcessesUnderFolder { if ($path -eq $flat) { $script:running } else { @() } }
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env env-a -path $flat -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'pid 4711 zsh \(cwd\)'
        Test-Path $flat | Should -BeTrue

        $script:running = @()
        (Get-Doc (Add-OctoEnvironmentRepo -env env-a -path $flat -WhatIf -Json)).data.dryRun | Should -BeTrue
        Test-Path $flat | Should -BeTrue
    }

    It 'refuses a main checkout, a repository already in the environment and -inPlace without -path' {
        (Get-Doc (Add-OctoEnvironmentRepo -env env-a -path (Join-Path $ws.Main 'octo-sdk') -Json)).data.error | Should -Match 'no linked git worktree'
        $other = Join-Path $ws.Root 'wt-other-mm-common'
        Invoke-TestGit (Join-Path $ws.Main 'mm-common') worktree add -q -b 'other' $other | Out-Null
        (Get-Doc (Add-OctoEnvironmentRepo -env env-a -path $other -Json)).data.error | Should -Match 'already in env-a'
        (Get-Doc (Add-OctoEnvironmentRepo -env env-a -repo octo-sdk -inPlace -Json)).data.error | Should -Match '-inPlace needs -path'
    }

    It '-inPlace records the worktree where it is; Remove keeps it' {
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env env-a -path $claude -inPlace -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.newPath | Should -Be $claude
        Test-Path $claude | Should -BeTrue
        $one = (Get-Doc (Get-OctoEnvironment -env env-a -Json)).data
        ($one.repos | Where-Object name -eq 'octo-identity-services').inPlace | Should -BeTrue
        ($one.repos | Where-Object name -eq 'mm-common').inPlace | Should -BeFalse

        Set-Content -Path (Join-Path $claude 'dirty.txt') -Value 'x'    # not the environment's: no refusal
        $removed = Get-Doc (Remove-OctoEnvironment -env env-a -Json)
        $removed.data.success | Should -BeTrue
        @($removed.data.keptInPlace) | Should -Be @($claude)
        Test-Path (Join-Path $claude 'dirty.txt') | Should -BeTrue
        Test-Path $envPath | Should -BeFalse
    }
}

Describe 'Credentials file and adoption base commit (CodeRabbit on 7328531)' {
    It 'New-OctoRestoreConfigFile removes its folder and rethrows when writing the credentials fails' {
        InModuleScope OctoEnvironment {
            $before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'octo-restore-*' -ErrorAction SilentlyContinue).FullName
            Mock Write-OctoRestoreConfigText { if ($text) { throw 'disk full' } else { [IO.File]::WriteAllText($path, '') } }
            { New-OctoRestoreConfigFile -sources @('https://a.invalid/v3') -credentials @{ 'https://a.invalid/v3' = @{ User = 'u'; Password = 'secret' } } -userConfigPath '' } | Should -Throw '*disk full*'
            $after = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'octo-restore-*' -ErrorAction SilentlyContinue).FullName
            @($after | Where-Object { $before -notcontains $_ }) | Should -BeNullOrEmpty
        }
    }

    It 'baseCommit: merge base, else the main checkout''s HEAD, else origin''s default branch, else none - never the adopted HEAD' {
        InModuleScope OctoEnvironment {
            $info = [pscustomobject]@{ Repo = 'octo-sdk'; MainCheckout = '/main/octo-sdk'; Branch = 'b'; Head = 'adoptedhead' }
            $script:gitCase = 'merge-base'
            Mock Invoke-OctoEnvironmentGit {
                $joined = $arguments -join ' '
                $ok = { param($out) [pscustomobject]@{ ExitCode = 0; Output = @($out) } }
                $bad = [pscustomobject]@{ ExitCode = 128; Output = @('fatal') }
                if ($joined -eq 'rev-parse HEAD') { if ($script:gitCase -eq 'no-main-head' -or $script:gitCase -eq 'nothing') { return $bad }; return & $ok 'mainhead' }
                if ($joined -like 'merge-base*') { if ($script:gitCase -eq 'merge-base') { return & $ok 'mergebase' }; return $bad }
                if ($joined -like '*refs/remotes/origin/HEAD*') { if ($script:gitCase -eq 'nothing') { return $bad }; return & $ok 'originhead' }
                return $bad
            }
            (Get-OctoAdoptedWorktreeEntry -info $info -path '/wt' -role feature).baseCommit | Should -Be 'mergebase'
            $script:gitCase = 'no-merge-base'
            (Get-OctoAdoptedWorktreeEntry -info $info -path '/wt' -role feature).baseCommit | Should -Be 'mainhead'
            $script:gitCase = 'no-main-head'
            (Get-OctoAdoptedWorktreeEntry -info $info -path '/wt' -role feature).baseCommit | Should -Be 'originhead'
            $script:gitCase = 'nothing'
            (Get-OctoAdoptedWorktreeEntry -info $info -path '/wt' -role feature).baseCommit | Should -BeNullOrEmpty
        }
    }

    It 'without a base commit every commit no remote has counts as unpushed, so Remove refuses' {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env env-nb -repos octo-sdk -branchName 'feature/nb' -Json | Out-Null
        $wt = Join-Path $ws.Root 'wt-env-nb/octo-sdk'
        Set-Content -Path (Join-Path $wt 'adopted.txt') -Value 'x'
        Invoke-TestGit $wt add -A | Out-Null
        Invoke-TestGit $wt commit -q -m 'adopted work' | Out-Null
        $manifestPath = Join-Path $ws.Root 'wt-env-nb/.octo/environment.json'
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
        $manifest.repos[0].baseCommit = $null
        Set-Content -Path $manifestPath -Value ($manifest | ConvertTo-Json -Depth 6)
        $doc = Get-Doc (Remove-OctoEnvironment -env env-nb -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'octo-sdk: 1 unpushed commit'
    }
}

Describe 'Environment base: origin instead of the local checkout (AB#8815)' {
    BeforeAll {
        # A commit that only origin has: pushed from a second clone, so the base checkout's remote ref is stale too.
        function Add-OriginCommit([string]$name, [string]$file = 'upstream.txt') {
            $clone = Join-Path $TestDrive "clones/$name-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
            Invoke-TestGit $TestDrive clone -q (Join-Path $TestDrive "origins/$name.git") $clone | Out-Null
            Set-Content -Path (Join-Path $clone $file) -Value 'upstream'
            Invoke-TestGit $clone add -A | Out-Null
            Invoke-TestGit $clone commit -q -m "upstream $name" | Out-Null
            Invoke-TestGit $clone push -q origin main | Out-Null
            return [string](Invoke-TestGit $clone rev-parse HEAD)
        }
    }
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'a consumer starts from the fetched origin/main, and the drift of the stale local checkout is reported' {
        New-OctoEnvironment -env 'env-o' -repos octo-sdk -branchName 'feature/o' -Json | Out-Null
        $identity = Join-Path $ws.Main 'octo-identity-services'
        $local = [string](Invoke-TestGit $identity rev-parse HEAD)
        $upstream = Add-OriginCommit 'octo-identity-services'

        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-o' -repo octo-identity-services -role consumer -Json -WarningAction SilentlyContinue)
        $doc.data.success | Should -BeTrue
        $wt = Join-Path $ws.Root 'wt-env-o/octo-identity-services'
        (Invoke-TestGit $wt rev-parse HEAD) | Should -Be $upstream
        (Invoke-TestGit $identity rev-parse HEAD) | Should -Be $local          # the base checkout itself is not moved
        @($doc.data.baseDrift).Count | Should -Be 1
        $doc.data.baseDrift[0].repo | Should -Be 'octo-identity-services'
        $doc.data.baseDrift[0].baseRef | Should -Be 'origin/main'
        $doc.data.baseDrift[0].behind | Should -Be 1
        $doc.data.baseDrift[0].ahead | Should -Be 0
        $doc.data.baseDrift[0].localCommit | Should -Be $local
        ($doc.data.warnings -join ' ') | Should -Match 'octo-identity-services: the local checkout .* is 1 commit\(s\) behind and 0 ahead of origin/main'
        $entry = (Get-Content (Join-Path $ws.Root 'wt-env-o/.octo/environment.json') -Raw | ConvertFrom-Json).repos | Where-Object name -eq 'octo-identity-services'
        $entry.baseCommit | Should -Be $upstream
        $entry.baseRef | Should -Be 'origin/main'
        # a consumer at origin's commit has no unpushed work: Remove is not blocked
        (Get-Doc (Get-OctoEnvironment -env 'env-o' -Json)).data.repos | Where-Object name -eq 'octo-identity-services' | ForEach-Object unpushed | Should -Be 0
    }

    It '-localBase keeps the local checkout''s commit (also when it is ahead of origin)' {
        New-OctoEnvironment -env 'env-l' -repos octo-sdk -branchName 'feature/l' -Json | Out-Null
        $identity = Join-Path $ws.Main 'octo-identity-services'
        Add-OriginCommit 'octo-identity-services' | Out-Null
        Set-Content -Path (Join-Path $identity 'local.txt') -Value 'local'
        Invoke-TestGit $identity add -A | Out-Null
        Invoke-TestGit $identity commit -q -m 'local only' | Out-Null
        $local = [string](Invoke-TestGit $identity rev-parse HEAD)

        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-l' -repo octo-identity-services -role consumer -localBase -Json)
        $doc.data.localBase | Should -BeTrue
        @($doc.data.baseDrift).Count | Should -Be 0
        (Invoke-TestGit (Join-Path $ws.Root 'wt-env-l/octo-identity-services') rev-parse HEAD) | Should -Be $local
        $doc.data.added[0].baseRef | Should -Be 'HEAD'

        # without the switch: 1 behind, 1 ahead
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-l' -repo octo-cli -role consumer -Json)
        @($doc.data.baseDrift).Count | Should -Be 0     # octo-cli is in step with origin
    }

    It 'a new feature branch starts from origin/main without tracking it; an existing branch is not rebased' {
        $upstream = Add-OriginCommit 'octo-sdk'
        Invoke-TestGit (Join-Path $ws.Main 'mm-common') branch 'feature/n' | Out-Null
        Add-OriginCommit 'mm-common' | Out-Null
        $doc = Get-Doc (New-OctoEnvironment -env 'env-n' -repos 'octo-sdk,mm-common' -branchName 'feature/n' -Json -WarningAction SilentlyContinue)
        $doc.data.success | Should -BeTrue
        $sdk = Join-Path $ws.Root 'wt-env-n/octo-sdk'
        (Invoke-TestGit $sdk rev-parse HEAD) | Should -Be $upstream
        (& git -C $sdk config --get 'branch.feature/n.merge') | Should -BeNullOrEmpty
        @($doc.data.baseDrift.repo) | Should -Be @('octo-sdk')
        # mm-common: the existing branch decides - still at the old commit, baseCommit = merge base, no drift row
        $common = $doc.data.manifest.repos | Where-Object name -eq 'mm-common'
        (Invoke-TestGit (Join-Path $ws.Root 'wt-env-n/mm-common') rev-parse HEAD) | Should -Be (Invoke-TestGit (Join-Path $ws.Main 'mm-common') rev-parse HEAD)
        $common.baseCommit | Should -Be (Invoke-TestGit (Join-Path $ws.Main 'mm-common') rev-parse HEAD)
        $common.baseRef | Should -Be 'feature/n'
    }

    It 'an existing branch that forked before the base checkout''s HEAD gives no drift row' {
        $cli = Join-Path $ws.Main 'octo-cli'
        Invoke-TestGit $cli branch 'feature/old' | Out-Null
        Set-Content -Path (Join-Path $cli 'later.txt') -Value 'later'
        Invoke-TestGit $cli add -A | Out-Null
        Invoke-TestGit $cli commit -q -m 'main moved on' | Out-Null
        Invoke-TestGit $cli push -q origin main | Out-Null
        $doc = Get-Doc (New-OctoEnvironment -env 'env-old' -repos octo-cli -branchName 'feature/old' -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.baseDrift).Count | Should -Be 0
        $doc.data.manifest.repos[0].baseCommit | Should -Be (Invoke-TestGit $cli rev-parse 'feature/old')
    }

    It 'network calls never ask for credentials on the terminal, and the setting does not stay behind' {
        $before = $env:GIT_TERMINAL_PROMPT
        InModuleScope OctoEnvironment -Parameters @{ repo = (Join-Path $ws.Main 'octo-cli') } {
            (Invoke-OctoEnvironmentGit -path $repo -arguments @('config', '--get', 'user.name') -noPrompt).ExitCode | Should -BeIn @(0, 1)
            # with an upstream: fetch; without: ls-remote, then fetch
            foreach ($upstreamExit in @(0, 1)) {
                $script:seen = @()
                $script:upstreamExit = $upstreamExit
                Mock Invoke-OctoEnvironmentGit {
                    $script:seen += , @{ Arguments = $arguments; NoPrompt = [bool]$noPrompt }
                    if ($arguments -contains '@{upstream}') { return [pscustomobject]@{ ExitCode = $script:upstreamExit; Output = @('origin/main') } }
                    if ($arguments[0] -eq 'ls-remote') { return [pscustomobject]@{ ExitCode = 0; Output = @("ref: refs/heads/main`tHEAD") } }
                    [pscustomobject]@{ ExitCode = 0; Output = @('0123456789abcdef') }
                }
                Resolve-OctoEnvironmentBase -source $repo | Out-Null
                $network = @($script:seen | Where-Object { $_.Arguments[0] -in 'fetch', 'ls-remote' })
                $network.Count | Should -Be (1 + $upstreamExit)
                foreach ($call in $network) { $call.NoPrompt | Should -BeTrue }
                ($network | Where-Object { $_.Arguments[0] -eq 'fetch' }).Arguments[-1] | Should -Be '+refs/heads/main:refs/remotes/origin/main'
            }
        }
        $env:GIT_TERMINAL_PROMPT | Should -Be $before
    }

    It 'a base checkout without an upstream uses origin''s default branch; an unreachable origin falls back to the last fetched ref with a warning' {
        $cli = Join-Path $ws.Main 'octo-cli'
        $upstream = Add-OriginCommit 'octo-cli'
        Invoke-TestGit $cli checkout -q --detach | Out-Null
        New-OctoEnvironment -env 'env-d' -repos octo-sdk -branchName 'feature/d' -Json | Out-Null
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-d' -repo octo-cli -role consumer -Json -WarningAction SilentlyContinue)
        (Invoke-TestGit (Join-Path $ws.Root 'wt-env-d/octo-cli') rev-parse HEAD) | Should -Be $upstream

        # origin renamed its default branch: the stale local origin/HEAD (main) must not decide
        $common = Join-Path $ws.Main 'mm-common'
        $bare = Join-Path $TestDrive 'origins/mm-common.git'
        Invoke-TestGit $common push -q origin 'main:trunk' | Out-Null
        Invoke-TestGit $bare symbolic-ref HEAD refs/heads/trunk | Out-Null
        $clone = Join-Path $TestDrive 'clones/mm-common-trunk'
        Invoke-TestGit $TestDrive clone -q $bare $clone | Out-Null
        Set-Content -Path (Join-Path $clone 'trunk.txt') -Value 'trunk'
        Invoke-TestGit $clone add -A | Out-Null
        Invoke-TestGit $clone commit -q -m 'on trunk' | Out-Null
        Invoke-TestGit $clone push -q origin trunk | Out-Null
        Invoke-TestGit $common remote set-head origin main | Out-Null
        Invoke-TestGit $common checkout -q --detach | Out-Null
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-d' -repo mm-common -role consumer -Json -WarningAction SilentlyContinue)
        $doc.data.added[0].baseRef | Should -Be 'origin/trunk'
        (Invoke-TestGit (Join-Path $ws.Root 'wt-env-d/mm-common') rev-parse HEAD) | Should -Be (Invoke-TestGit $clone rev-parse HEAD)

        $identity = Join-Path $ws.Main 'octo-identity-services'
        Invoke-TestGit $identity remote set-url origin (Join-Path $TestDrive 'origins/gone.git') | Out-Null
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-d' -repo octo-identity-services -role consumer -Json -WarningAction SilentlyContinue)
        $doc.data.success | Should -BeTrue
        ($doc.data.warnings -join ' ') | Should -Match 'git fetch origin main failed'
        (Invoke-TestGit (Join-Path $ws.Root 'wt-env-d/octo-identity-services') rev-parse HEAD) | Should -Be (Invoke-TestGit $identity rev-parse HEAD)
    }

    It 'says which environment repositories are newer than the seeded packages and which libraries outside are behind' {
        Add-OriginCommit 'octo-sdk' | Out-Null
        Add-OriginCommit 'octo-construction-kit-engine' | Out-Null
        $doc = Get-Doc (New-OctoEnvironment -env 'env-f' -repos octo-sdk -branchName 'feature/f' -Json -WarningAction SilentlyContinue)
        $doc.data.success | Should -BeTrue
        @($doc.data.feedSnapshot.rebuildInEnvironment) | Should -Be @('octo-sdk')
        @($doc.data.feedSnapshot.staleProducers).Count | Should -Be 1
        $doc.data.feedSnapshot.staleProducers[0].repo | Should -Be 'octo-construction-kit-engine'
        $doc.data.feedSnapshot.staleProducers[0].behind | Should -Be 1
        @($doc.data.feedSnapshot.staleProducers[0].consumedBy) | Should -Be @('octo-sdk')
        ($doc.data.feedSnapshot.hints -join ' ') | Should -Match 'Invoke-BuildEnvironment -env env-f rebuilds them'
        ($doc.data.feedSnapshot.hints -join ' ') | Should -Match 'Add-OctoEnvironmentRepo -env env-f -repo octo-construction-kit-engine -role consumer'

        # a later Add-OctoEnvironmentRepo of a repository in step with origin still reports the earlier one
        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-f' -repo octo-identity-services -role consumer -Json)
        @($doc.data.baseDrift).Count | Should -Be 0
        @($doc.data.feedSnapshot.rebuildInEnvironment) | Should -Be @('octo-sdk')
        @($doc.data.feedSnapshot.staleProducers.repo) | Should -Be @('octo-construction-kit-engine')

        # in step with origin, or -localBase: nothing to say
        $doc = Get-Doc (New-OctoEnvironment -env 'env-g' -repos octo-cli -branchName 'feature/g' -Json)
        @($doc.data.feedSnapshot.rebuildInEnvironment).Count | Should -Be 0
        @($doc.data.feedSnapshot.hints).Count | Should -Be 0
        $doc = Get-Doc (New-OctoEnvironment -env 'env-h' -repos octo-sdk -branchName 'feature/h' -localBase -Json)
        @($doc.data.feedSnapshot.staleProducers).Count | Should -Be 0
    }
}

Describe 'Developer tools next to the lanes in an environment (AB#8815)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        foreach ($tool in @('octo-tools', 'octo-devstack')) {
            New-FakeRepo $ws.Root $tool { param($r) New-Item -ItemType Directory -Force -Path (Join-Path $r 'src') | Out-Null; Set-Content -Path (Join-Path $r 'src/readme.txt') -Value 'tool' } | Out-Null
        }
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName OctoEnvironment Invoke-KillDotnet { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $true; exitCode = 0; killedCount = 0; processes = @() }) }
        $script:built = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { $script:built.Add($entry.Name); [pscustomobject]@{ Success = $true; LogFile = $null } }
    }

    It 'New-OctoEnvironment and Add-OctoEnvironmentRepo take octo-tools / octo-devstack from <rootPath>; the build skips them' {
        $doc = Get-Doc (New-OctoEnvironment -env 'env-t' -repos 'octo-sdk,tools' -branchName 'feature/t' -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.toolRepos) | Should -Be @('octo-tools')
        $envPath = Join-Path $ws.Root 'wt-env-t'
        (Invoke-TestGit (Join-Path $envPath 'octo-tools') rev-parse --abbrev-ref HEAD) | Should -Be 'feature/t'
        @(Invoke-TestGit (Join-Path $ws.Root 'octo-tools') worktree list).Count | Should -Be 2

        $doc = Get-Doc (Add-OctoEnvironmentRepo -env 'env-t' -repo octo-devstack -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.toolRepos) | Should -Be @('octo-devstack')

        $plan = Get-Doc (Invoke-BuildEnvironment -env 'env-t' -DryRun -Json)
        $plan.data.whatIf | Should -BeTrue
        @($plan.data.repositories.repo) | Should -Be @('octo-sdk')
        @($plan.data.environment.toolRepos) | Should -Be @('octo-tools', 'octo-devstack')

        $run = Get-Doc (Invoke-BuildEnvironment -env 'env-t' -Json)
        $run.data.success | Should -BeTrue
        @($script:built) | Should -Be @('octo-sdk')

        (Get-Doc (Remove-OctoEnvironment -env 'env-t' -Json)).data.success | Should -BeTrue
        Test-Path $envPath | Should -BeFalse
        @(Invoke-TestGit (Join-Path $ws.Root 'octo-tools') worktree list).Count | Should -Be 1
    }

    It 'an environment that holds only tools has nothing to build: success, a plan, a done event' {
        (Get-Doc (New-OctoEnvironment -env 'env-u' -repos octo-tools -branchName 'feature/u' -Json)).data.success | Should -BeTrue
        $plan = Get-Doc (Invoke-BuildEnvironment -env 'env-u' -DryRun -Json)
        $plan.data.success | Should -BeTrue
        $plan.data.whatIf | Should -BeTrue
        @($plan.data.repositories).Count | Should -Be 0
        $plan.data.note | Should -Match 'only developer tools \(octo-tools\)'
        $events = Join-Path $TestDrive 'events-tools.jsonl'
        $run = Get-Doc (Invoke-BuildEnvironment -env 'env-u' -EventsFile $events -Json)
        $run.data.success | Should -BeTrue
        $global:LASTEXITCODE | Should -Be 0
        @(Get-Content $events | ForEach-Object { ($_ | ConvertFrom-Json).event }) | Should -Be @('plan', 'done')
        $script:built.Count | Should -Be 0
    }

    It 'an in-place tool worktree in the manifest does not break the build plan' {
        New-OctoEnvironment -env 'env-v' -repos octo-sdk -branchName 'feature/v' -Json | Out-Null
        $toolWorktree = Join-Path $ws.Root 'octo-tools/.claude/worktrees/x'
        Invoke-TestGit (Join-Path $ws.Root 'octo-tools') worktree add -q -b 'feature/tool' $toolWorktree | Out-Null
        (Get-Doc (Add-OctoEnvironmentRepo -env 'env-v' -path $toolWorktree -inPlace -Json -WarningAction SilentlyContinue)).data.success | Should -BeTrue
        $plan = Get-Doc (Invoke-BuildEnvironment -env 'env-v' -DryRun -Json)
        @($plan.data.repositories.repo) | Should -Be @('octo-sdk')
        @($plan.data.environment.toolRepos) | Should -Be @('octo-tools')
        $plan.data.environment.inPlace.PSObject.Properties.Name | Should -Not -Contain 'octo-tools'
        (Get-Doc (Invoke-BuildEnvironment -env 'env-v' -Json)).data.success | Should -BeTrue
        @($script:built) | Should -Be @('octo-sdk')
    }

    It 'a missing worktree of a real repository is a failure, not "only developer tools"' {
        (Get-Doc (New-OctoEnvironment -env 'env-m' -repos 'octo-sdk,octo-tools' -branchName 'feature/m' -Json)).data.success | Should -BeTrue
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree remove --force (Join-Path $ws.Root 'wt-env-m/octo-sdk') | Out-Null
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-m' -DryRun -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'worktree\(s\) of octo-sdk are missing'
    }

    It 'a tool name is refused when it is no checkout next to the lanes' {
        Remove-Item (Join-Path $ws.Root 'octo-devstack') -Recurse -Force
        (Get-Doc (New-OctoEnvironment -env 'env-w' -repos octo-devstack -Json)).data.error | Should -Match "not a git checkout in .* or "
    }
}

Describe 'New-OctoEnvironment is atomic (AB#8815)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        $script:common = Join-Path $ws.Main 'mm-common'
        $script:engine = Join-Path $ws.Main 'octo-construction-kit-engine'
        $script:sdk = Join-Path $ws.Main 'octo-sdk'
        $script:envPath = Join-Path $ws.Root 'wt-env-x'
    }

    It 'rolls back worktrees, folder and the branches it created - never a branch that existed - and the same call succeeds after the fix' {
        Invoke-TestGit $common branch 'feature/x' | Out-Null          # existed before: must survive the rollback
        Invoke-TestGit $sdk checkout -q -b 'feature/x' | Out-Null     # checked out in the base lane: worktree add fails
        $doc = Get-Doc (New-OctoEnvironment -env 'env-x' -repos 'mm-common,octo-construction-kit-engine,octo-sdk' -branchName 'feature/x' -Json)
        $doc.data.success | Should -BeFalse
        $global:LASTEXITCODE | Should -Be 1
        $doc.data.error | Should -Match 'rolled back'
        $doc.data.error | Should -Match 'git worktree add failed for octo-sdk'
        @($doc.data.rolledBack.worktrees).Count | Should -Be 2
        @($doc.data.rolledBack.branches) | Should -Be @('octo-construction-kit-engine: feature/x')
        $doc.data.rolledBack.folder | Should -BeTrue
        @($doc.data.rolledBack.errors).Count | Should -Be 0

        Test-Path $envPath | Should -BeFalse
        foreach ($repo in @($common, $engine, $sdk)) { @(Invoke-TestGit $repo worktree list).Count | Should -Be 1 }
        (& git -C $engine rev-parse --verify --quiet 'refs/heads/feature/x') | Should -BeNullOrEmpty
        (& git -C $common rev-parse --verify --quiet 'refs/heads/feature/x') | Should -Not -BeNullOrEmpty
        (Get-Doc (Get-OctoEnvironment -Json)).data.environments.Count | Should -Be 0

        Invoke-TestGit $sdk checkout -q main | Out-Null
        $doc = Get-Doc (New-OctoEnvironment -env 'env-x' -repos 'mm-common,octo-construction-kit-engine,octo-sdk' -branchName 'feature/x' -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.manifest.repos.name) | Should -Be @('mm-common', 'octo-construction-kit-engine', 'octo-sdk')
        foreach ($name in @('mm-common', 'octo-construction-kit-engine', 'octo-sdk')) { (Invoke-TestGit (Join-Path $envPath $name) rev-parse --abbrev-ref HEAD) | Should -Be 'feature/x' }
    }

    It 'rolls back when the feed snapshot report fails (it is part of the transaction)' {
        Mock -ModuleName OctoEnvironment Get-OctoEnvironmentFeedSnapshotReport { throw 'project file unreadable' }
        $doc = Get-Doc (New-OctoEnvironment -env 'env-x' -repos octo-sdk -branchName 'feature/z' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'project file unreadable'
        $doc.data.rolledBack.folder | Should -BeTrue
        Test-Path $envPath | Should -BeFalse
        (& git -C $sdk rev-parse --verify --quiet 'refs/heads/feature/z') | Should -BeNullOrEmpty
    }

    It 'rolls back when seeding the feed fails, and when a consumer of -addAffected fails' {
        Mock -ModuleName OctoEnvironment Invoke-OctoEnvironmentSync { throw 'disk full' }
        $doc = Get-Doc (New-OctoEnvironment -env 'env-x' -repos octo-sdk -branchName 'feature/y' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'disk full'
        Test-Path $envPath | Should -BeFalse
        (& git -C $sdk rev-parse --verify --quiet 'refs/heads/feature/y') | Should -BeNullOrEmpty

        Mock -ModuleName OctoEnvironment Invoke-OctoEnvironmentSync { [pscustomobject]@{ Nuget = $null; Catalogs = @(); PurgedFromCache = @() } }
        Mock -ModuleName OctoEnvironment Get-OctoEnvironmentAffected { [pscustomobject]@{ Features = @('octo-construction-kit-engine'); Graph = [pscustomobject]@{ Affected = @([pscustomobject]@{ repo = 'octo-sdk' }, [pscustomobject]@{ repo = 'octo-gone' }); Consumers = @{} } } }
        $doc = Get-Doc (New-OctoEnvironment -env 'env-x' -repos octo-construction-kit-engine -branchName 'feature/y' -addAffected -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match "octo-gone"
        @($doc.data.rolledBack.worktrees).Count | Should -Be 2
        Test-Path $envPath | Should -BeFalse
        foreach ($repo in @($engine, $sdk)) { @(Invoke-TestGit $repo worktree list).Count | Should -Be 1 }
        (& git -C $engine rev-parse --verify --quiet 'refs/heads/feature/y') | Should -BeNullOrEmpty
    }

    It 'without -Json a failure ends with an error that says it was rolled back' {
        Invoke-TestGit $sdk checkout -q -b 'feature/x' | Out-Null
        New-OctoEnvironment -env 'env-x' -repos octo-sdk -branchName 'feature/x' -ErrorVariable problems -ErrorAction SilentlyContinue
        # (git's own stderr lines are recorded too; the cmdlet's error is the last one)
        "$($problems[-1])" | Should -Match 'rolled back .* run the same call again'
        Test-Path $envPath | Should -BeFalse
    }
}
