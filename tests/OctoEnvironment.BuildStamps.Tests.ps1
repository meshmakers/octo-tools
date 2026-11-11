#Requires -Modules Pester
<#
    Pester tests for feature environments (OctoEnvironment.psm1): build stamps: an environment build builds only what changed (AB#8814).

    Part of the OctoEnvironment tests, split over several files so they can run in parallel
    (tests/Invoke-ParallelPester.ps1). Setup and fixtures: tests/OctoEnvironment.TestHelpers.ps1 - everything runs in
    TestDrive, see OctoEnvironment.Tests.ps1.

    Run:  Invoke-Pester ./tests/OctoEnvironment.BuildStamps.Tests.ps1
#>

BeforeAll { . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1') }

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'Invoke-BuildEnvironment builds only what changed (AB#8814)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        # engine (feature) -> sdk -> asset-repo, cli; identity depends on mm-common only
        New-OctoEnvironment -env 'env-n' -repos octo-construction-kit-engine -branchName 'feature/n' -addAffected -Json | Out-Null
        Add-OctoEnvironmentRepo -env 'env-n' -repo octo-identity-services -role consumer -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-n'
        $script:all = @('octo-construction-kit-engine', 'octo-sdk', 'octo-asset-repo-services', 'octo-cli', 'octo-identity-services')
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName OctoEnvironment Invoke-KillDotnet { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $true; exitCode = 0; killedCount = 0; processes = @() }) }
        $script:built = [System.Collections.Generic.List[string]]::new()
        $script:failRepo = ''
        $script:buildNumber = 0
        # The fake build: build output in bin/DebugL (ignored by git) and, for the libraries, a new package each time.
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:built.Add($entry.Name)
            if ($entry.Name -eq $script:failRepo) { return [pscustomobject]@{ Success = $false; LogFile = $null } }
            $script:buildNumber++
            New-Item -ItemType Directory -Force -Path (Join-Path $entry.Path 'bin/DebugL') | Out-Null
            if ($entry.Name -eq 'octo-construction-kit-engine') { New-FakePackage (Join-Path $entry.Path 'src/Runtime.Engine/bin/DebugL') 'Meshmakers.Octo.Runtime.Engine' "engine-$($script:buildNumber)" | Out-Null }
            if ($entry.Name -eq 'octo-sdk') { New-FakePackage (Join-Path $entry.Path 'src/Sdk.Common/bin/DebugL') 'Meshmakers.Octo.Sdk.Common' "sdk-$($script:buildNumber)" | Out-Null }
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
        function Get-Status($doc) { $map = [ordered]@{}; foreach ($row in $doc.data.repositories) { $map[$row.repo] = "$($row.status):$($row.reason)" }; return $map }
    }

    It 'builds everything once, then skips every unchanged repository and says why in -Json and the events file' {
        $first = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -Json)
        $first.data.success | Should -BeTrue
        @($script:built) | Should -Be $all
        @($first.data.repositories.status | Select-Object -Unique) | Should -Be @('built')
        @($first.data.repositories.reason | Select-Object -Unique) | Should -Be @('neverBuilt')
        $first.data.builtCount | Should -Be 5
        foreach ($name in $all) { Test-Path (Join-Path $envPath ".octo/build-stamps/$name.json") | Should -BeTrue }
        $stamp = Get-Content (Join-Path $envPath '.octo/build-stamps/octo-sdk.json') -Raw | ConvertFrom-Json
        $stamp.head | Should -Be (Invoke-TestGit (Join-Path $envPath 'octo-sdk') rev-parse HEAD)
        @($stamp.packages.PSObject.Properties.Name) | Should -Be @('meshmakers.common.shared', 'meshmakers.octo.runtime.engine')   # what sdk consumes, transitively

        $script:built.Clear()
        $events = Join-Path $TestDrive 'events-n.jsonl'
        $second = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -EventsFile $events -Json)
        $second.data.success | Should -BeTrue
        $script:built.Count | Should -Be 0
        $second.data.builtCount | Should -Be 0
        $second.data.skippedCount | Should -Be 5
        @($second.data.repositories | ForEach-Object { "$($_.status):$($_.reason)" } | Select-Object -Unique) | Should -Be @('skipped:unchanged')
        $second.data.hint | Should -BeNullOrEmpty
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        @($records.event) | Should -Be (@('plan') + @('repoSkipped') * 5 + @('done'))
        @($records[0].repos.action | Select-Object -Unique) | Should -Be @('skip')
        $records[1].repo | Should -Be 'octo-construction-kit-engine'
        $records[1].reason | Should -Be 'unchanged'
        $records[-1].success | Should -BeTrue
    }

    It 'an uncommitted edit, an untracked file and a commit each rebuild the repository and its consumers - nothing else' {
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        $sdk = Join-Path $envPath 'octo-sdk'

        $script:built.Clear()
        Add-Content -Path (Join-Path $sdk 'src/Sdk.Common/Sdk.Common.csproj') -Value '<!-- edit -->'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -Json)
        @($script:built) | Should -Be @('octo-sdk', 'octo-asset-repo-services', 'octo-cli')
        $status = Get-Status $doc
        $status['octo-construction-kit-engine'] | Should -Be 'skipped:unchanged'
        $status['octo-sdk'] | Should -Be 'built:sourcesChanged'
        $status['octo-asset-repo-services'] | Should -Be 'built:packagesChanged'
        $status['octo-cli'] | Should -Be 'built:packagesChanged'
        $status['octo-identity-services'] | Should -Be 'skipped:unchanged'
        ($doc.data.repositories | Where-Object repo -eq 'octo-cli').detail | Should -Match 'meshmakers.octo.sdk.common'

        $script:built.Clear()
        Set-Content -Path (Join-Path $sdk 'src/Sdk.Common/New.cs') -Value 'class New {}'
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        @($script:built) | Should -Be @('octo-sdk', 'octo-asset-repo-services', 'octo-cli')

        $script:built.Clear()
        Invoke-TestGit $sdk add -A | Out-Null
        Invoke-TestGit $sdk commit -q -m 'change' | Out-Null
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -Json)
        @($script:built) | Should -Be @('octo-sdk', 'octo-asset-repo-services', 'octo-cli')
        ($doc.data.repositories | Where-Object repo -eq 'octo-sdk').detail | Should -Match '^HEAD \w+ -> \w+$'

        $script:built.Clear()
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        $script:built.Count | Should -Be 0
    }

    It '-repos builds only the named repositories in build order, -skip leaves repositories out, unknown names are refused' {
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -repos 'cli,octo-construction-kit-engine' -Json)
        $doc.data.success | Should -BeTrue
        @($script:built) | Should -Be @('octo-construction-kit-engine', 'octo-cli')
        @($doc.data.selection.repos) | Should -Be @('octo-construction-kit-engine', 'octo-cli')
        $status = Get-Status $doc
        $status['octo-sdk'] | Should -Be 'skipped:notSelected'
        $status['octo-identity-services'] | Should -Be 'skipped:notSelected'
        Test-Path (Join-Path $envPath '.octo/build-stamps/octo-sdk.json') | Should -BeFalse

        $script:built.Clear()
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -skip 'octo-cli', 'identity-services' -buildUnchanged -Json)
        @($script:built) | Should -Be @('octo-construction-kit-engine', 'octo-sdk', 'octo-asset-repo-services')
        (Get-Status $doc)['octo-cli'] | Should -Be 'skipped:excluded'
        $doc.data.selection.skipped.'octo-identity-services'.reason | Should -Be 'excluded'

        $script:built.Clear()
        $events = Join-Path $TestDrive 'events-unknown.jsonl'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -repos 'octo-sdk,octo-nope' -EventsFile $events -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match "-repos: 'octo-nope' is no repository of environment env-n"
        (Get-Doc (Invoke-BuildEnvironment -env 'env-n' -skip 'mm-common' -Json)).data.error | Should -Match "-skip: 'mm-common' is no repository"
        (Get-Doc (Invoke-BuildEnvironment -env 'env-n' -repos octo-sdk -skip octo-sdk -Json)).data.error | Should -Match 'leave no repository'
        $script:built.Count | Should -Be 0
        (Get-Content $events | ConvertFrom-Json).failedStep | Should -Be 'preflight'
    }

    It 'warns when a left-out repository sits between a library that is built and a consumer that is built' {
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        $script:built.Clear()
        Add-Content -Path (Join-Path $envPath 'octo-construction-kit-engine/src/Runtime.Engine/Runtime.Engine.csproj') -Value '<!-- edit -->'

        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -repos 'octo-construction-kit-engine,octo-asset-repo-services' -DryRun -Json)
        @($doc.data.staleWarnings).Count | Should -Be 1
        $doc.data.staleWarnings[0].repo | Should -Be 'octo-sdk'
        $doc.data.staleWarnings[0].skipReason | Should -Be 'notSelected'
        @($doc.data.staleWarnings[0].upstreamBuilt) | Should -Be @('octo-construction-kit-engine')
        @($doc.data.staleWarnings[0].consumers) | Should -Be @('octo-asset-repo-services')
        $doc.data.staleWarnings[0].message | Should -Match 'octo-sdk is not built in this run \(notSelected\) but lies between octo-construction-kit-engine \(built\) and octo-asset-repo-services \(built\)'

        # a leaf that is left out harms nobody; so does a left-out library when nothing above it is built
        @((Get-Doc (Invoke-BuildEnvironment -env 'env-n' -skip octo-cli -DryRun -Json)).data.staleWarnings).Count | Should -Be 0
        Invoke-TestGit (Join-Path $envPath 'octo-construction-kit-engine') checkout -q -- . | Out-Null
        @((Get-Doc (Invoke-BuildEnvironment -env 'env-n' -skip octo-sdk -buildUnchanged:$false -DryRun -Json)).data.staleWarnings).Count | Should -Be 0

        # the left-out repository changed itself, and its consumer is built
        Add-Content -Path (Join-Path $envPath 'octo-sdk/src/Sdk.Common/Sdk.Common.csproj') -Value '<!-- edit -->'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -skip octo-sdk -buildUnchanged -DryRun -Json)
        $warning = @($doc.data.staleWarnings | Where-Object repo -eq 'octo-sdk')[0]
        $warning.changed | Should -BeTrue
        $warning.changeReason | Should -Be 'sourcesChanged'
        @($warning.consumers) | Should -Be @('octo-asset-repo-services', 'octo-cli')
        $script:built.Count | Should -Be 0

        # without -Json it is a warning
        Invoke-BuildEnvironment -env 'env-n' -skip octo-sdk -buildUnchanged -DryRun -WarningVariable warned -WarningAction SilentlyContinue 6>$null | Out-Null
        ($warned -join ' ') | Should -Match 'octo-sdk is not built in this run \(excluded\)'
    }

    It '-DryRun predicts build / skip per repository (upstreamBuilt for consumers) and changes nothing' {
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        $script:built.Clear()
        Add-Content -Path (Join-Path $envPath 'octo-construction-kit-engine/src/Runtime.Engine/Runtime.Engine.csproj') -Value '<!-- edit -->'
        $stampBefore = Get-Content (Join-Path $envPath '.octo/build-stamps/octo-construction-kit-engine.json') -Raw
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -DryRun -Json)
        $doc.data.whatIf | Should -BeTrue
        $doc.data.skipUnchanged | Should -BeTrue
        $plan = [ordered]@{}; foreach ($row in $doc.data.repositories) { $plan[$row.repo] = "$($row.action):$($row.reason)" }
        $plan['octo-construction-kit-engine'] | Should -Be 'build:sourcesChanged'
        $plan['octo-sdk'] | Should -Be 'build:upstreamBuilt'
        $plan['octo-asset-repo-services'] | Should -Be 'build:upstreamBuilt'
        $plan['octo-cli'] | Should -Be 'build:upstreamBuilt'
        $plan['octo-identity-services'] | Should -Be 'skip:unchanged'
        $script:built.Count | Should -Be 0
        Get-Content (Join-Path $envPath '.octo/build-stamps/octo-construction-kit-engine.json') -Raw | Should -Be $stampBefore
    }

    It '-buildUnchanged builds everything; -verifyTests rebuilds what was built without tests; missing output rebuilds' {
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        $script:built.Clear()
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -buildUnchanged -Json)
        @($script:built) | Should -Be $all
        @($doc.data.repositories.reason | Select-Object -Unique) | Should -Be @('always')
        $doc.data.skipUnchanged | Should -BeFalse

        $script:built.Clear()
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -skip octo-construction-kit-engine, octo-sdk -verifyTests -Json)
        @($script:built) | Should -Be @('octo-asset-repo-services', 'octo-cli', 'octo-identity-services')
        (Get-Status $doc)['octo-cli'] | Should -Be 'built:testsNotCompiled'
        $script:built.Clear()
        Invoke-BuildEnvironment -env 'env-n' -skip octo-construction-kit-engine, octo-sdk -Json | Out-Null    # tests compiled covers a plain build
        $script:built.Count | Should -Be 0

        Remove-Item (Join-Path $envPath 'octo-cli/bin') -Recurse -Force
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -skip octo-construction-kit-engine, octo-sdk -Json)
        @($script:built) | Should -Be @('octo-cli')
        (Get-Status $doc)['octo-cli'] | Should -Be 'built:noBuildOutput'
    }

    It 'a failed build leaves no stamp: the repository is built again, what succeeded before it is skipped' {
        $script:failRepo = 'octo-sdk'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-n' -Json -ErrorAction SilentlyContinue)
        $doc.data.success | Should -BeFalse
        $doc.data.failedRepo | Should -Be 'octo-sdk'
        (Get-Status $doc)['octo-sdk'] | Should -Be 'failed:neverBuilt'
        Test-Path (Join-Path $envPath '.octo/build-stamps/octo-sdk.json') | Should -BeFalse

        $script:failRepo = ''
        $script:built.Clear()
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        @($script:built) | Should -Be @('octo-sdk', 'octo-asset-repo-services', 'octo-cli', 'octo-identity-services')

        # a build that fails after an earlier success removes the old stamp too
        $script:failRepo = 'octo-cli'
        Invoke-BuildEnvironment -env 'env-n' -buildUnchanged -Json -ErrorAction SilentlyContinue | Out-Null
        Test-Path (Join-Path $envPath '.octo/build-stamps/octo-cli.json') | Should -BeFalse
        Test-Path (Join-Path $envPath '.octo/build-stamps/octo-asset-repo-services.json') | Should -BeTrue
    }

    It 'Remove-OctoEnvironment deletes the build stamps with the environment' {
        Invoke-BuildEnvironment -env 'env-n' -Json | Out-Null
        (Get-Doc (Remove-OctoEnvironment -env 'env-n' -Json)).data.success | Should -BeTrue
        Test-Path $envPath | Should -BeFalse
    }
}

Describe 'Build stamps (OctoBuildStamp.psm1, AB#8814)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        # These tests build the fake main lane as a legacy lane (-laneIsolation Off), whose package cache is the
        # global one: point it at an empty folder, the developer's ~/.nuget/packages is neither read nor purged.
        $env:NUGET_PACKAGES = Join-Path $TestDrive "empty-cache-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        New-Item -ItemType Directory -Force -Path $env:NUGET_PACKAGES | Out-Null
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        $script:built = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:built.Add($entry.Name)
            New-Item -ItemType Directory -Force -Path (Join-Path $entry.Path 'bin/DebugL') | Out-Null
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
    }

    AfterEach { $env:NUGET_PACKAGES = $null }

    It 'Invoke-BuildRange -skipUnchanged works without a package graph: every other package of the feed counts' {
        $run = { Get-Doc (Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipUnchanged -laneIsolation Off -Json) }
        (& $run).data.repositories[0].status | Should -Be 'built'
        $second = & $run
        $second.data.repositories[0].status | Should -Be 'skipped'
        $second.data.repositories[0].reason | Should -Be 'unchanged'
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Common.Shared' 'common-v2' | Out-Null
        $third = & $run
        $third.data.repositories[0].reason | Should -Be 'packagesChanged'
        @($script:built) | Should -Be @('octo-cli', 'octo-cli')
    }

    It 'a plain Invoke-BuildRange neither writes stamps nor skips; -recordStamps writes them; -skipRepos must name repositories of the range' {
        Invoke-BuildRange -branch 'branches/main' -from octo-cli -laneIsolation Off -Json | Out-Null
        Test-Path (Join-Path $ws.Main '.octo/build-stamps') | Should -BeFalse
        $doc = Get-Doc (Invoke-BuildRange -branch 'branches/main' -from octo-cli -recordStamps -laneIsolation Off -Json)
        $doc.data.repositories[0].status | Should -Be 'built'
        $doc.data.repositories[0].reason | Should -Be 'always'
        Test-Path (Join-Path $ws.Main '.octo/build-stamps/octo-cli.json') | Should -BeTrue
        (Get-Doc (Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipRepos @{ 'octo-sdk' = 'excluded' } -laneIsolation Off -Json -ErrorAction SilentlyContinue)).data.error | Should -Match "-skipRepos: 'octo-sdk' is not a repository of the selected range"
    }

    It 'other MSBuild properties are another build: propertiesChanged, then unchanged again' {
        $run = { param($value) Get-Doc (Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipUnchanged -msbuildProperties @{ DefineConstants = $value } -laneIsolation Off -Json) }
        (& $run 'A').data.repositories[0].reason | Should -Be 'neverBuilt'
        (& $run 'A').data.repositories[0].status | Should -Be 'skipped'
        $changed = & $run 'B'
        $changed.data.repositories[0].status | Should -Be 'built'
        $changed.data.repositories[0].reason | Should -Be 'propertiesChanged'
        (& $run 'B').data.repositories[0].status | Should -Be 'skipped'
        # the temporary credentials file of an environment build has another name in every run: it does not count
        Get-OctoMsBuildPropertiesHash -properties @{ A = '1'; RestoreConfigFile = '/tmp/a/NuGet.Config' } | Should -Be (Get-OctoMsBuildPropertiesHash -properties @{ A = '1'; RestoreConfigFile = '/tmp/b/NuGet.Config' })
        Get-OctoMsBuildPropertiesHash -properties @{ RestoreConfigFile = '/tmp/a/NuGet.Config' } | Should -Be ''
    }

    It 'a run that skips every repository does not refuse because of running services' {
        Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipUnchanged -laneIsolation Off -Json | Out-Null
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @($repos | ForEach-Object { [pscustomobject]@{ Repo = $_.Name; Pid = 4711; Command = 'dotnet Meshmakers.Fake.dll' } }) }
        $doc = Get-Doc (Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipUnchanged -laneIsolation Off -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.repositories[0].status | Should -Be 'skipped'
        # a repository that is going to be built still refuses
        Add-Content -Path (Join-Path $ws.Main 'octo-cli/octo-cli.slnx') -Value '<!-- edit -->'
        (Get-Doc (Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipUnchanged -laneIsolation Off -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'Processes run out of repositories in the range: octo-cli'
    }

    It 'every DebugL build deletes the existing stamp first, also a run without stamp switches; a stamp that cannot be deleted stops the run' {
        Invoke-BuildRange -branch 'branches/main' -from octo-cli -recordStamps -laneIsolation Off -Json | Out-Null
        $stamp = Join-Path $ws.Main '.octo/build-stamps/octo-cli.json'
        Test-Path $stamp | Should -BeTrue
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { [pscustomobject]@{ Success = $false; LogFile = $null } }
        Invoke-BuildRange -branch 'branches/main' -from octo-cli -laneIsolation Off -Json -ErrorAction SilentlyContinue | Out-Null
        Test-Path $stamp | Should -BeFalse        # the failed plain build must not leave the old success record

        Set-Content -Path $stamp -Value '{}'
        Mock -ModuleName OctoBuildStamp Remove-Item { }
        { Remove-OctoBuildStamp -stampRoot (Split-Path -Parent $stamp) -repo 'octo-cli' } | Should -Throw '*cannot be deleted*'
    }

    It 'writes no stamp while the package cache holds another build of a consumed package' {
        $cache = Join-Path $TestDrive 'stale-cache'
        $folder = Join-Path $cache 'meshmakers.octo.sdk.common/999.0.0'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Set-Content -Path (Join-Path $folder 'meshmakers.octo.sdk.common.999.0.0.nupkg.sha512') -Value 'bm90LXRoZS1mZWVkLXBhY2thZ2U=' -NoNewline
        $env:NUGET_PACKAGES = $cache
        & {
            $doc = Get-Doc (Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipUnchanged -laneIsolation Off -Json)
            @($doc.data.staleGlobalCache.packageId) | Should -Contain 'meshmakers.octo.sdk.common'
            Test-Path (Join-Path $ws.Main '.octo/build-stamps/octo-cli.json') | Should -BeFalse
            # purged: the stamp is written
            Invoke-BuildRange -branch 'branches/main' -from octo-cli -skipUnchanged -purgeStaleCache -laneIsolation Off -Json | Out-Null
            Test-Path (Join-Path $ws.Main '.octo/build-stamps/octo-cli.json') | Should -BeTrue
        }
    }

    It 'the source state sees edits, untracked files and commits, ignores bin/ and Invoke-Build.log, and reports a folder without git' {
        $repo = Join-Path $ws.Main 'octo-cli'
        $clean = Get-OctoRepoSourceState -path $repo
        $clean.Dirty | Should -BeFalse
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'bin/DebugL') | Out-Null
        Set-Content -Path (Join-Path $repo 'bin/DebugL/x.dll') -Value 'x'
        Set-Content -Path (Join-Path $repo 'Invoke-Build.log') -Value 'log'
        (Get-OctoRepoSourceState -path $repo).Hash | Should -Be $clean.Hash

        Set-Content -Path (Join-Path $repo 'new.txt') -Value 'a'
        $untracked = Get-OctoRepoSourceState -path $repo
        $untracked.Dirty | Should -BeTrue
        $untracked.Hash | Should -Not -Be $clean.Hash
        Set-Content -Path (Join-Path $repo 'new.txt') -Value 'b'
        (Get-OctoRepoSourceState -path $repo).Hash | Should -Not -Be $untracked.Hash
        Remove-Item (Join-Path $repo 'new.txt')
        (Get-OctoRepoSourceState -path $repo).Hash | Should -Be $clean.Hash

        Add-Content -Path (Join-Path $repo 'octo-cli.slnx') -Value '<!-- edit -->'
        $edited = Get-OctoRepoSourceState -path $repo
        $edited.Hash | Should -Not -Be $clean.Hash
        Remove-Item (Join-Path $repo 'Invoke-Build.log')    # not ignored in the fake repository: keep it out of the commit
        Invoke-TestGit $repo add -A | Out-Null
        (Get-OctoRepoSourceState -path $repo).Hash | Should -Be $edited.Hash     # staged or not: the same content
        Invoke-TestGit $repo commit -q -m edit | Out-Null
        (Get-OctoRepoSourceState -path $repo).Hash | Should -Not -Be $edited.Hash

        $plain = Join-Path $TestDrive 'no-git'
        New-Item -ItemType Directory -Force -Path $plain | Out-Null
        $none = Get-OctoRepoSourceState -path $plain
        $none.Problem | Should -Match 'no git state'
        (Compare-OctoBuildStamp -stamp @{ schemaVersion = 1 } -inputs ([pscustomobject]@{ Source = $none; Packages = [ordered]@{} }) -configuration DebugL -tests none).Reason | Should -Be 'noGitState'
    }
}
