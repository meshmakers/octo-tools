#Requires -Modules Pester
<#
    Pester tests for feature environments (OctoEnvironment.psm1): parallel environment builds (AB#8814).

    Part of the OctoEnvironment tests, split over several files so they can run in parallel
    (tests/Invoke-ParallelPester.ps1). Setup and fixtures: tests/OctoEnvironment.TestHelpers.ps1 - everything runs in
    TestDrive, see OctoEnvironment.Tests.ps1.

    Run:  Invoke-Pester ./tests/OctoEnvironment.ParallelBuilds.Tests.ps1
#>

BeforeAll { . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1') }

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'Parallel environment builds (AB#8814)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        # engine (feature) -> sdk -> asset-repo, cli; identity depends on mm-common only (not in the environment)
        New-OctoEnvironment -env 'env-p' -repos octo-construction-kit-engine -branchName 'feature/p' -addAffected -Json | Out-Null
        Add-OctoEnvironmentRepo -env 'env-p' -repo octo-identity-services -role consumer -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-p'
        $script:all = @('octo-construction-kit-engine', 'octo-sdk', 'octo-asset-repo-services', 'octo-cli', 'octo-identity-services')
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName OctoEnvironment Invoke-KillDotnet { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $true; exitCode = 0; killedCount = 0; processes = @() }) }

        # Fake jobs in place of the child processes: a job is "running" for three polls.
        $script:active = [System.Collections.Generic.List[string]]::new()
        $script:starts = [System.Collections.Generic.List[object]]::new()
        $script:maxActive = 0
        $script:failRepo = ''
        $script:throwOnStart = ''
        $script:stopped = [System.Collections.Generic.List[string]]::new()
        $script:buildNumber = 0
        $script:inProcess = [System.Collections.Generic.List[string]]::new()
        $script:fakeBuild = {
            param($entry)
            $script:buildNumber++
            New-Item -ItemType Directory -Force -Path (Join-Path $entry.Path 'bin/DebugL') | Out-Null
            if ($entry.Name -eq 'octo-construction-kit-engine') { New-FakePackage (Join-Path $entry.Path 'src/Runtime.Engine/bin/DebugL') 'Meshmakers.Octo.Runtime.Engine' "engine-$($script:buildNumber)" | Out-Null }
            if ($entry.Name -eq 'octo-sdk') { New-FakePackage (Join-Path $entry.Path 'src/Sdk.Common/bin/DebugL') 'Meshmakers.Octo.Sdk.Common' "sdk-$($script:buildNumber)" | Out-Null }
        }
        Mock -ModuleName Invoke-BuildRange Start-OctoRepoBuildJob {
            if ($entry.Name -eq $script:throwOnStart) { throw "cannot start $($entry.Name)" }
            $feed = Join-Path (Split-Path -Parent $entry.Path) 'nuget'
            $script:starts.Add([pscustomobject]@{
                    Name = $entry.Name; Active = @($script:active); Environment = $environment
                    EngineInFeed = [string](Get-Content (Join-Path $feed 'Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') -Raw -ErrorAction SilentlyContinue)
                    Stamps = @(Get-ChildItem (Join-Path (Split-Path -Parent $entry.Path) '.octo/build-stamps') -Filter *.json -ErrorAction SilentlyContinue | ForEach-Object BaseName)
                })
            $script:active.Add($entry.Name)
            $script:maxActive = [Math]::Max($script:maxActive, $script:active.Count)
            & $script:fakeBuild $entry
            [pscustomobject]@{ Name = $entry.Name; Polls = 3 }
        }
        Mock -ModuleName Invoke-BuildRange Get-OctoRepoBuildJobState {
            $job.Polls--
            if ($job.Polls -gt 0) { return [pscustomobject]@{ Done = $false; Phase = 'build'; Build = $null; Tests = $null; BuildSeconds = 0.0; TestSeconds = 0.0 } }
            [void]$script:active.Remove($job.Name)
            [pscustomobject]@{ Done = $true; Phase = 'build'; Build = [pscustomobject]@{ Success = ($job.Name -ne $script:failRepo); LogFile = $null }; Tests = $null; BuildSeconds = 1.5; TestSeconds = 0.0 }
        }
        Mock -ModuleName Invoke-BuildRange Stop-OctoRepoBuildJob { $script:stopped.Add($job.Name) }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { $script:inProcess.Add($entry.Name); & $script:fakeBuild $entry; [pscustomobject]@{ Success = $true; LogFile = $null } }
        function Get-Start([string]$name) { $script:starts | Where-Object Name -eq $name }
    }

    It 'starts a repository when everything it depends on is finished - packages in the feed, stamp written - and never more than -maxParallel' {
        $events = Join-Path $TestDrive 'events-p.jsonl'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 2 -EventsFile $events -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.parallel | Should -BeTrue
        $doc.data.maxParallel | Should -Be 2
        $script:maxActive | Should -Be 2
        $script:inProcess.Count | Should -Be 0

        # engine and identity do not depend on each other: they run together
        @($script:starts[0..1].Name) | Should -Be @('octo-construction-kit-engine', 'octo-identity-services')
        @((Get-Start 'octo-identity-services').Active) | Should -Be @('octo-construction-kit-engine')
        # sdk waits for engine: engine is not running any more, its new package is in the feed, its stamp is written
        $sdk = Get-Start 'octo-sdk'
        $sdk.Active | Should -Not -Contain 'octo-construction-kit-engine'
        $sdk.EngineInFeed | Should -Match '^engine-\d+$'
        $sdk.Stamps | Should -Contain 'octo-construction-kit-engine'
        # asset-repo and cli wait for sdk and run together
        foreach ($name in @('octo-asset-repo-services', 'octo-cli')) {
            (Get-Start $name).Active | Should -Not -Contain 'octo-sdk'
            (Get-Start $name).Stamps | Should -Contain 'octo-sdk'
        }
        @((Get-Start 'octo-cli').Active) | Should -Contain 'octo-asset-repo-services'

        # report: build order, whatever finished first; every stamp written
        @($doc.data.repositories.repo) | Should -Be $all
        @($doc.data.repositories.status | Select-Object -Unique) | Should -Be @('built')
        @($doc.data.notBuilt).Count | Should -Be 0
        foreach ($name in $all) { Test-Path (Join-Path $envPath ".octo/build-stamps/$name.json") | Should -BeTrue }
        Get-Content (Join-Path $envPath 'nuget/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Match '^sdk-'
        @(Get-ChildItem (Join-Path $envPath 'nuget') -Force | Where-Object Name -notlike '*.nupkg').Count | Should -Be 0   # no temporary file left

        # events: plan says parallel, every repoStart has its repoDone with the same index, indexes are 1..count, done is last
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $records[0].event | Should -Be 'plan'
        $records[0].parallel | Should -BeTrue
        $records[0].maxParallel | Should -Be 2
        @(($records[0].repos | Where-Object repo -eq 'octo-cli').dependsOn) | Should -Be @('octo-construction-kit-engine', 'octo-sdk')
        @(($records[0].repos | Where-Object repo -eq 'octo-identity-services').dependsOn).Count | Should -Be 0
        $startRecords = @($records | Where-Object event -eq 'repoStart')
        @($startRecords.index | Sort-Object) | Should -Be @(1, 2, 3, 4, 5)
        @($startRecords.count | Select-Object -Unique) | Should -Be @(5)
        foreach ($start in $startRecords) {
            $done = @($records | Where-Object { $_.event -eq 'repoDone' -and $_.repo -eq $start.repo })
            $done.Count | Should -Be 1
            $done[0].index | Should -Be $start.index
            $done[0].success | Should -BeTrue
            [Array]::IndexOf($records, $done[0]) | Should -BeGreaterThan ([Array]::IndexOf($records, $start))
        }
        $records[-1].event | Should -Be 'done'
        $records[-1].success | Should -BeTrue
        @($records | Where-Object event -eq 'done').Count | Should -Be 1

        # the second run skips everything, also in parallel mode
        $script:starts.Clear()
        $again = Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 2 -Json)
        $again.data.skippedCount | Should -Be 5
        $script:starts.Count | Should -Be 0
    }

    It '-maxParallel bounds the number of running repositories; the default of Invoke-BuildEnvironment is 2, of Invoke-BuildRange 1' {
        (Get-Command Invoke-BuildEnvironment).Parameters['maxParallel'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateRangeAttribute] }).Count | Should -Be 1
        InModuleScope OctoEnvironment { (Get-Command Invoke-BuildEnvironment).ScriptBlock.Ast.Body.ParamBlock.Parameters.Where({ $_.Name.VariablePath.UserPath -eq 'maxParallel' })[0].DefaultValue.Value } | Should -Be 2
        InModuleScope Invoke-BuildRange { (Get-Command Invoke-BuildRange).ScriptBlock.Ast.Body.ParamBlock.Parameters.Where({ $_.Name.VariablePath.UserPath -eq 'maxParallel' })[0].DefaultValue.Value } | Should -Be 1
        # five repositories without a dependency on each other
        New-OctoEnvironment -env 'env-w' -repos 'octo-asset-repo-services,octo-cli,octo-identity-services' -branchName 'feature/w' -Json | Out-Null
        Invoke-BuildEnvironment -env 'env-w' -maxParallel 2 -Json | Out-Null
        $script:maxActive | Should -Be 2
        $script:maxActive = 0
        Invoke-BuildEnvironment -env 'env-w' -maxParallel 3 -buildUnchanged -Json | Out-Null
        $script:maxActive | Should -Be 3
    }

    It '-maxParallel 1 is the sequential run: no job is started, the build step runs in this process, events as before' {
        $events = Join-Path $TestDrive 'events-seq.jsonl'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 1 -EventsFile $events -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.parallel | Should -BeFalse
        $doc.data.maxParallel | Should -Be 1
        $script:starts.Count | Should -Be 0
        @($script:inProcess) | Should -Be $all
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        # strictly one after the other, index = position in the build order
        @($records | Where-Object { $_.event -in 'repoStart', 'repoDone' } | ForEach-Object { "$($_.event):$($_.repo):$($_.index)" }) | Should -Be @($all | ForEach-Object { $i = [Array]::IndexOf($all, $_) + 1; "repoStart:${_}:$i"; "repoDone:${_}:$i" })
        $records[0].parallel | Should -BeFalse
    }

    It 'after a failure nothing new starts, a running repository finishes, the rest is reported as not built' {
        $script:failRepo = 'octo-construction-kit-engine'
        $events = Join-Path $TestDrive 'events-fail.jsonl'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 2 -EventsFile $events -Json -ErrorAction SilentlyContinue)
        $doc.data.success | Should -BeFalse
        $doc.data.failedRepo | Should -Be 'octo-construction-kit-engine'
        $doc.data.failedStep | Should -Be 'build'
        @($doc.data.failedRepos) | Should -Be @('octo-construction-kit-engine')
        $global:LASTEXITCODE | Should -Be 1
        @($script:starts.Name) | Should -Be @('octo-construction-kit-engine', 'octo-identity-services')
        $status = [ordered]@{}; foreach ($row in $doc.data.repositories) { $status[$row.repo] = $row.status }
        $status['octo-construction-kit-engine'] | Should -Be 'failed'
        $status['octo-identity-services'] | Should -Be 'built'            # it was running: it finished, with its stamp
        Test-Path (Join-Path $envPath '.octo/build-stamps/octo-identity-services.json') | Should -BeTrue
        Test-Path (Join-Path $envPath '.octo/build-stamps/octo-construction-kit-engine.json') | Should -BeFalse
        @($doc.data.notBuilt) | Should -Be @('octo-sdk', 'octo-asset-repo-services', 'octo-cli')
        $script:stopped.Count | Should -Be 0
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        ($records | Where-Object { $_.event -eq 'repoDone' -and $_.repo -eq 'octo-identity-services' }).success | Should -BeTrue
        ($records | Where-Object { $_.event -eq 'repoDone' -and $_.repo -eq 'octo-construction-kit-engine' }).success | Should -BeFalse
        $records[-1].event | Should -Be 'done'
        $records[-1].success | Should -BeFalse
        $records[-1].failedRepo | Should -Be 'octo-construction-kit-engine'

        # a failure in the middle: its dependents never start
        $script:failRepo = 'octo-sdk'
        $script:starts.Clear()
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 2 -Json -ErrorAction SilentlyContinue)
        @($script:starts.Name) | Should -Be @('octo-construction-kit-engine', 'octo-sdk')
        @($doc.data.notBuilt) | Should -Be @('octo-asset-repo-services', 'octo-cli')
    }

    It 'a throw while repositories run stops them, writes their repoDone and one done event' {
        $script:throwOnStart = 'octo-identity-services'
        $events = Join-Path $TestDrive 'events-throw.jsonl'
        { Invoke-BuildEnvironment -env 'env-p' -maxParallel 2 -EventsFile $events -Json } | Should -Throw '*cannot start octo-identity-services*'
        @($script:stopped) | Should -Be @('octo-construction-kit-engine')
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $engineDone = @($records | Where-Object { $_.event -eq 'repoDone' -and $_.repo -eq 'octo-construction-kit-engine' })
        $engineDone.Count | Should -Be 1
        $engineDone[0].success | Should -BeFalse
        @($records | Where-Object event -eq 'done').Count | Should -Be 1
        $records[-1].event | Should -Be 'done'
        $records[-1].success | Should -BeFalse
        $records[-1].failedRepo | Should -Not -BeNullOrEmpty
    }

    It 'a throw while the packages of a finished repository are copied still writes its repoDone, once' {
        Mock -ModuleName Invoke-BuildRange Copy-NuGetPackages { throw 'feed folder is gone' }
        $events = Join-Path $TestDrive 'events-copy-throw.jsonl'
        { Invoke-BuildEnvironment -env 'env-p' -maxParallel 2 -EventsFile $events -Json } | Should -Throw '*feed folder is gone*'
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $started = @($records | Where-Object event -eq 'repoStart' | ForEach-Object repo)
        $started.Count | Should -BeGreaterThan 0
        foreach ($name in $started) {
            $done = @($records | Where-Object { $_.event -eq 'repoDone' -and $_.repo -eq $name })
            $done.Count | Should -Be 1
            $done[0].success | Should -BeFalse
        }
        @($records | Where-Object event -eq 'done').Count | Should -Be 1
        $records[-1].success | Should -BeFalse
    }

    It 'repositories with a CK model never build at the same time and keep their order' {
        foreach ($name in @('octo-asset-repo-services', 'octo-cli')) {
            $folder = (Get-ChildItem (Join-Path $envPath "$name/src") -Directory | Select-Object -First 1).FullName
            Set-Content -Path (Join-Path $folder 'ckModel.yaml') -Value "ckLanguage: 1`nmodelId: Test"
        }
        Mock -ModuleName Invoke-BuildRange Sync-OctoCkIntermediateVersions { }
        (Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 3 -Json)).data.success | Should -BeTrue
        (Get-Start 'octo-cli').Active | Should -Not -Contain 'octo-asset-repo-services'
        [Array]::IndexOf(@($script:starts.Name), 'octo-asset-repo-services') | Should -BeLessThan ([Array]::IndexOf(@($script:starts.Name), 'octo-cli'))
        InModuleScope Invoke-BuildRange -Parameters @{ envPath = $envPath } {
            Test-OctoRepoHasCkModel -path (Join-Path $envPath 'octo-cli') | Should -BeTrue
            Test-OctoRepoHasCkModel -path (Join-Path $envPath 'octo-sdk') | Should -BeFalse
        }
    }

    It 'a build.ps1 repository builds alone and in this process' {
        Set-Content -Path (Join-Path $envPath 'octo-construction-kit-engine/build.ps1') -Value 'param($configuration) exit 0'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 3 -Json)
        $doc.data.success | Should -BeTrue
        @($script:inProcess) | Should -Be @('octo-construction-kit-engine')
        # nothing ran next to it: every job started after it
        $script:starts.Name | Should -Not -Contain 'octo-construction-kit-engine'
        foreach ($start in $script:starts) { $start.Stamps | Should -Contain 'octo-construction-kit-engine' }
        $plan = Get-Doc (Invoke-BuildEnvironment -env 'env-p' -maxParallel 3 -DryRun -Json)
        ($plan.data.repositories | Where-Object repo -eq 'octo-construction-kit-engine').exclusive | Should -BeTrue
        $plan.data.parallel | Should -BeTrue
    }

    It 'the per-repository RestoreSources goes to the job, never into this process' {
        $before = $env:RestoreSources
        Invoke-BuildEnvironment -env 'env-p' -maxParallel 2 -Json | Out-Null
        $env:RestoreSources | Should -Be $before
        foreach ($start in $script:starts) {
            $start.Environment['NUGET_PACKAGES'] | Should -Be (Join-Path $envPath '.nuget-packages')
            $start.Environment['MSBUILDDISABLENODEREUSE'] | Should -Be '1'
            $start.Environment['RestoreSources'] | Should -Match ([regex]::Escape((Join-Path $envPath 'nuget')))
        }
    }

    It 'Invoke-BuildRange -maxParallel without -repoInputs has no dependency information and builds one after the other' {
        $env:NUGET_PACKAGES = Join-Path $TestDrive 'empty-cache-parallel'     # not the developer's global package cache
        New-Item -ItemType Directory -Force -Path $env:NUGET_PACKAGES | Out-Null
        try { Invoke-BuildRange -branch 'branches/main' -from octo-asset-repo-services -to octo-identity-services -maxParallel 4 -laneIsolation Off -Json | Out-Null }
        finally { $env:NUGET_PACKAGES = $null }
        $script:starts.Count | Should -Be 3
        $script:maxActive | Should -Be 1
    }
}

Describe 'Child process of a parallel build and the atomic package copy (AB#8814)' {
    It 'each job runs in its own pwsh with its own environment; nothing reaches this process or the other job' {
        $root = Join-Path $TestDrive 'jobs with a space'      # paths with spaces must survive the child's command line
        $work = Join-Path $root 'work dir'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        $entries = foreach ($name in @('octo-one', 'octo-two')) {
            $repo = Join-Path $root $name
            New-Item -ItemType Directory -Force -Path $repo | Out-Null
            # a build.ps1 repository: the worker runs the script, no dotnet involved
            Set-Content -Path (Join-Path $repo 'build.ps1') -Value 'param($configuration) Start-Sleep -Milliseconds 300; Set-Content (Join-Path $PSScriptRoot "seen.txt") "$env:RestoreSources|$env:NUGET_PACKAGES|$configuration"; exit 0'
            [pscustomobject]@{ Name = $name; Path = $repo; Mode = 'script'; Target = 'build.ps1'; Solution = $null; Projects = @(); TestProjects = @() }
        }
        $before = "$env:RestoreSources|$env:NUGET_PACKAGES"
        InModuleScope Invoke-BuildRange -Parameters @{ entries = $entries; work = $work } {
            $jobs = foreach ($entry in $entries) {
                Start-OctoRepoBuildJob -entry $entry -configuration 'DebugL' -environment @{ RestoreSources = "feed-of-$($entry.Name)"; NUGET_PACKAGES = "cache-of-$($entry.Name)" } -workDirectory $work
            }
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            do { Start-Sleep -Milliseconds 200; $states = @($jobs | ForEach-Object { Get-OctoRepoBuildJobState -job $_ }) } while (@($states | Where-Object { -not $_.Done }).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)
            foreach ($state in $states) { $state.Done | Should -BeTrue; $state.Build.Success | Should -BeTrue }
        }
        Get-Content (Join-Path $root 'octo-one/seen.txt') | Should -Be 'feed-of-octo-one|cache-of-octo-one|DebugL'
        Get-Content (Join-Path $root 'octo-two/seen.txt') | Should -Be 'feed-of-octo-two|cache-of-octo-two|DebugL'
        "$env:RestoreSources|$env:NUGET_PACKAGES" | Should -Be $before
    }

    It 'a child that dies without a result is a failed build; Stop-OctoRepoBuildJob ends a running child' {
        $work = Join-Path $TestDrive 'jobs fail'
        $repo = Join-Path $work 'octo-crash'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        Set-Content -Path (Join-Path $repo 'build.ps1') -Value 'param($configuration) [Environment]::Exit(7)'
        $slow = Join-Path $work 'octo-slow'
        New-Item -ItemType Directory -Force -Path $slow | Out-Null
        Set-Content -Path (Join-Path $slow 'build.ps1') -Value 'param($configuration) Start-Sleep -Seconds 120; exit 0'
        InModuleScope Invoke-BuildRange -Parameters @{ repo = $repo; slow = $slow; work = $work } {
            $job = Start-OctoRepoBuildJob -entry ([pscustomobject]@{ Name = 'octo-crash'; Path = $repo; Mode = 'script'; Target = 'build.ps1'; Solution = $null; Projects = @(); TestProjects = @() }) -configuration 'DebugL' -workDirectory $work
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            do { Start-Sleep -Milliseconds 200; $state = Get-OctoRepoBuildJobState -job $job } while (-not $state.Done -and [DateTime]::UtcNow -lt $deadline)
            $state.Done | Should -BeTrue
            $state.Build.Success | Should -BeFalse
            # the diagnostic outlives the run's temporary folder: it is in the repository's build log
            $state.Build.LogFile | Should -Be (Join-Path $repo 'Invoke-Build.log')
            Get-Content $state.Build.LogFile -Raw | Should -Match 'ended without a result \(exit code 7\)'

            $running = Start-OctoRepoBuildJob -entry ([pscustomobject]@{ Name = 'octo-slow'; Path = $slow; Mode = 'script'; Target = 'build.ps1'; Solution = $null; Projects = @(); TestProjects = @() }) -configuration 'DebugL' -workDirectory $work
            Start-Sleep -Milliseconds 500
            (Get-OctoRepoBuildJobState -job $running).Done | Should -BeFalse
            Stop-OctoRepoBuildJob -job $running
            [void]$running.Process.WaitForExit(10000)
            $running.Process.HasExited | Should -BeTrue
            (Get-OctoRepoBuildJobState -job $running).Build.Success | Should -BeFalse
        }
    }

    It 'a throw in the build or in the test verification fails the repository in that phase' {
        $work = Join-Path $TestDrive 'step'
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        InModuleScope Invoke-BuildRange -Parameters @{ work = $work } {
            $request = { param($name) [ordered]@{ rootPath = ''; configuration = 'DebugL'; verifyTests = $true; environment = @{}; msbuildProperties = @{}
                    resultFile = (Join-Path $work "$name.result.json"); phaseFile = (Join-Path $work "$name.phase")
                    entry = @{ Name = $name; Path = $work; Mode = 'dotnet'; Target = 'slnf'; Solution = 'x.slnx'; Projects = @('src/a.csproj'); TestProjects = @('tests/t.csproj') } } }
            $run = { param($name)
                $file = Join-Path $work "$name.request.json"
                Set-Content -Path $file -Value (ConvertTo-Json -InputObject (& $request $name) -Depth 5)
                Invoke-OctoBuildRangeRepoStep -requestFile $file
                Get-Content (Join-Path $work "$name.result.json") -Raw | ConvertFrom-Json }

            Mock Invoke-OctoBuildRangeRepo { [pscustomobject]@{ Success = $true; LogFile = 'build.log' } }
            Mock Invoke-OctoBuildRangeTests { throw 'cannot write the solution filter' }
            $result = & $run 'tests-throw'
            $result.success | Should -BeTrue            # the build itself was fine
            $result.tests.success | Should -BeFalse     # the verification was not: the parent reports failedStep tests, copies nothing, writes no stamp
            $result.tests.skipped | Should -BeFalse
            $result.error | Should -Match 'solution filter'

            Mock Invoke-OctoBuildRangeRepo { throw 'dotnet not found' }
            $result = & $run 'build-throw'
            $result.success | Should -BeFalse
            $result.tests | Should -BeNullOrEmpty
        }
    }

    It 'a reader never sees half a package while Copy-NuGetPackages replaces it' {
        $lane = Join-Path $TestDrive 'atomic'
        $bin = Join-Path $lane 'octo-x/src/P/bin/DebugL'
        $feed = Join-Path $lane 'feed'
        New-Item -ItemType Directory -Force -Path $bin, $feed | Out-Null
        $size = 4MB
        $name = 'Meshmakers.Atomic.999.0.0.nupkg'
        $target = Join-Path $feed $name
        [IO.File]::WriteAllBytes($target, [byte[]]::new($size))
        $modules = Join-Path $PSScriptRoot '../modules'
        # Writer and reader are tied together, so the result does not depend on how the scheduler runs them: the writer
        # starts when the reader says so and replaces the package (a new repeated byte value each time) until the reader
        # has seen enough versions - or a bound is reached.
        $go = Join-Path $lane 'go'
        $stop = Join-Path $lane 'stop'
        $writer = Start-ThreadJob -ArgumentList $modules, $lane, $bin, $feed, $name, $size, $go, $stop -ScriptBlock {
            param($modules, $lane, $bin, $feed, $name, $size, $go, $stop)
            Import-Module (Join-Path $modules 'OctoJsonOutput.psm1'), (Join-Path $modules 'OctoBuildOrder.psm1'), (Join-Path $modules 'Copy-NuGetPackages.psm1') -Force
            $deadline = [DateTime]::UtcNow.AddSeconds(60)
            while (-not (Test-Path $go) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            $round = 0
            while (-not (Test-Path $stop) -and $round -lt 250 -and [DateTime]::UtcNow -lt $deadline) {
                $round++
                $bytes = [byte[]]::new($size)
                [Array]::Fill($bytes, [byte]$round)
                [IO.File]::WriteAllBytes((Join-Path $bin $name), $bytes)
                Copy-NuGetPackages -directory (Join-Path $lane 'octo-x') -nugetPath $feed -Json | Out-Null
            }
            $round
        }
        $reads = 0
        $torn = 0
        $values = [System.Collections.Generic.HashSet[int]]::new()
        Set-Content -Path $go -Value 'go'
        $deadline = [DateTime]::UtcNow.AddSeconds(60)
        while ($values.Count -lt 5 -and $writer.State -in 'NotStarted', 'Running' -and [DateTime]::UtcNow -lt $deadline) {
            $bytes = [IO.File]::ReadAllBytes($target)
            $reads++
            if ($bytes.Length -ne $size -or $bytes[0] -ne $bytes[$size - 1] -or $bytes[0] -ne $bytes[$size / 2]) { $torn++ }
            [void]$values.Add([int]$bytes[0])
        }
        Set-Content -Path $stop -Value 'stop'
        $rounds = [int](Receive-Job $writer -Wait -AutoRemoveJob | Select-Object -Last 1)
        $torn | Should -Be 0
        $values.Count | Should -BeGreaterOrEqual 5              # the reader did see the package being replaced
        ([IO.File]::ReadAllBytes($target))[0] | Should -Be ([byte]$rounds)
        @(Get-ChildItem $feed -Force).Count | Should -Be 1       # no temporary file left
    }
}
