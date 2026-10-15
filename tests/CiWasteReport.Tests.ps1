#Requires -Modules Pester
<#
    Pester tests for Get-CiWasteReport / Measure-CiWaste (AB#6369).

    The baseline test replays a scrubbed recording of the ADO CI history of 2026-10-09T10:25Z to
    2026-10-10T10:25Z (tests/fixtures/ci-waste-baseline-20261010.json) and checks the numbers of the
    2026-10-10 analysis. No network, no az login, no real token: the REST layer is mocked.

    Run:  Invoke-Pester ./tests/CiWasteReport.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Get-CiWasteReport.psm1') -Force

    $script:FixturePath = Join-Path $PSScriptRoot 'fixtures/ci-waste-baseline-20261010.json'
    $script:Fixture = Get-Content -Raw -Path $script:FixturePath | ConvertFrom-Json
    $script:AsOf = [datetime]::Parse('2026-10-10T10:25:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)

    $script:Pools = @{}
    $script:Requests = @{}
    foreach ($p in $script:Fixture.poolInfo.PSObject.Properties) {
        $script:Pools[[int]$p.Name] = @{ name = $p.Value.name; capacity = $p.Value.capacity }
    }
    foreach ($p in $script:Fixture.jobRequests.PSObject.Properties) { $script:Requests[[int]$p.Name] = @($p.Value) }

    $script:Report = Measure-CiWaste -Builds $script:Fixture.builds -JobRequests $script:Requests -PoolInfo $script:Pools -AsOf $script:AsOf -Hours 24

    function Get-Def([string]$name) { $script:Report.definitions | Where-Object definition -eq $name }
    function New-FakeBuild([int]$id, [string]$def, [string]$sha, [string]$queue, [string]$start, [string]$finish, [string]$result = 'succeeded', [string]$reason = 'batchedCI', [string]$branch = 'refs/heads/main') {
        $b = [ordered]@{
            id = $id; definition = @{ id = ([int][char]$def[0]) * 10 + $def.Length; name = $def }
            sourceBranch = $branch; sourceVersion = $sha; reason = $reason; queueTime = $queue
            status = if ($finish) { 'completed' } else { 'inProgress' }
        }
        if ($start) { $b.startTime = $start }
        if ($finish) { $b.finishTime = $finish }
        if ($finish -and $result) { $b.result = $result }
        [pscustomobject]$b
    }
}

Describe 'Baseline 2026-10-10 (recorded fixture)' {
    It 'covers the 24 h window of the analysis' {
        $script:Report.window.hours | Should -Be 24
        $script:Report.window.to | Should -BeLike '2026-10-10T10:25:00*'
    }

    It 'counts all CI runs and the resource-triggered share (328 runs, 168 triggered, 4,920 / 2,766 min)' {
        $ci = $script:Report.totals.ci
        $ci.runs | Should -Be 328
        $ci.resourceTriggerRuns | Should -Be 168
        $ci.totalMinutes | Should -BeGreaterThan (4920 * 0.98)
        $ci.totalMinutes | Should -BeLessThan (4920 * 1.02)
        $ci.resourceTriggerMinutes | Should -BeGreaterThan (2766 * 0.98)
        $ci.resourceTriggerMinutes | Should -BeLessThan (2766 * 1.02)
    }

    It 'reproduces the strict same-commit duplicates of the chain (284 runs, 170 duplicates, ~2,580 of ~4,277 min)' {
        $chain = $script:Report.totals.chain
        $chain.runs | Should -Be 284
        $chain.resourceTriggerRuns | Should -Be 168
        $chain.duplicateRuns | Should -BeGreaterThan (170 * 0.98)
        $chain.duplicateRuns | Should -BeLessThan (170 * 1.02)
        $chain.duplicateShare | Should -BeGreaterThan 58.8
        $chain.duplicateShare | Should -BeLessThan 60.8
        $chain.wastedMinutes | Should -BeGreaterThan (2580 * 0.98)
        $chain.wastedMinutes | Should -BeLessThan (2580 * 1.02)
        $chain.totalMinutes | Should -BeGreaterThan (4277 * 0.98)
        $chain.totalMinutes | Should -BeLessThan (4277 * 1.02)
    }

    It 'reproduces the per-definition table for the three most expensive leaves' {
        $ai = Get-Def 'octo-ai-services-CI'
        $ai.runs | Should -Be 16
        $ai.resourceTriggerRuns | Should -Be 13
        $ai.duplicateRuns | Should -Be 11
        $ai.wastedMinutes | Should -BeGreaterThan (551 * 0.98)
        $ai.wastedMinutes | Should -BeLessThan (551 * 1.02)

        $identity = Get-Def 'octo-identity-services-CI'
        ($identity.runs, $identity.resourceTriggerRuns, $identity.duplicateRuns) | Should -Be @(16, 10, 10)

        $mongo = Get-Def 'octo-construction-kit-engine-mongodb-CI'
        ($mongo.runs, $mongo.resourceTriggerRuns, $mongo.duplicateRuns) | Should -Be @(22, 11, 13)
        $mongo.upstream | Should -Be 'octo-sdk-CI'
    }

    It 'ranks the definitions by wasted minutes, ai-services first' {
        $script:Report.definitions[0].definition | Should -Be 'octo-ai-services-CI'
    }

    It 'estimates the provably redundant share of the main chain at about 47 % of runs and 40 % of minutes' {
        # The analysis states "103 of 219 runs, about 1,400 of 3,400 min" (47 % / 40 %), reconstructed with
        # slightly different run selection; the cmdlet's documented rule gives 100 of 215 / ~1,345 of ~3,418.
        $chain = $script:Report.totals.chain
        $chain.mainRuns | Should -BeGreaterThan (219 * 0.97)
        $chain.mainRuns | Should -BeLessThan (219 * 1.03)
        $chain.redundantRunShare | Should -BeGreaterThan 45
        $chain.redundantRunShare | Should -BeLessThan 49
        $chain.redundantMinutes | Should -BeGreaterThan (1400 * 0.94)
        $chain.redundantMinutes | Should -BeLessThan (1400 * 1.06)
        $chain.redundantMinuteShare | Should -BeGreaterThan 38
        $chain.redundantMinuteShare | Should -BeLessThan 42
        $chain.redundantMinutes | Should -BeLessThan $chain.wastedMinutes   # realistic saving below the ceiling
    }

    It 'reproduces the CI pool: wait p50 0 / p90 4 / max 24 min, avg concurrency 2.9, sustained peak 6' {
        $ci = $script:Report.pools | Where-Object poolId -eq 45
        $ci.name | Should -Be 'CI'
        $ci.capacity | Should -Be 8
        $ci.queueWaitP50Minutes | Should -Be 0
        $ci.queueWaitP90Minutes | Should -BeGreaterThan 3.8
        $ci.queueWaitP90Minutes | Should -BeLessThan 4.4
        $ci.queueWaitMaxMinutes | Should -BeGreaterThan 23.5
        $ci.queueWaitMaxMinutes | Should -BeLessThan 24.5
        $ci.avgConcurrency | Should -BeGreaterThan (2.9 * 0.98)
        $ci.avgConcurrency | Should -BeLessThan (2.9 * 1.02)
        $ci.sustainedPeak | Should -Be 6
        $ci.maxConcurrency | Should -BeGreaterOrEqual 6
    }

    It 'reproduces the CD pool: p90 about 2 min, max about 28 min, short time at capacity' {
        $cd = $script:Report.pools | Where-Object poolId -eq 46
        $cd.name | Should -Be 'CD'
        $cd.queueWaitP90Minutes | Should -BeGreaterThan 1.5
        $cd.queueWaitP90Minutes | Should -BeLessThan 2.5
        $cd.queueWaitMaxMinutes | Should -BeGreaterThan 27
        $cd.queueWaitMaxMinutes | Should -BeLessThan 29
        $cd.percentTimeAtCapacity | Should -BeGreaterThan 2
        $cd.percentTimeAtCapacity | Should -BeLessThan 5
    }

    It 'keeps the fixture free of tokens, URLs, people and agent names' {
        $raw = Get-Content -Raw -Path $script:FixturePath
        $raw | Should -Not -Match 'https?://'
        $raw | Should -Not -Match '(?i)bearer|password|secret|@[a-z0-9-]+\.'
        $raw | Should -Not -Match '(?i)requestedFor|uniqueName|reservedAgent'
    }
}

Describe 'Measure-CiWaste rules' {
    BeforeAll {
        $script:T0 = '2026-10-10T08:00:00Z'
        $script:SmallAsOf = [datetime]::Parse('2026-10-10T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        $script:Chain = @{ 'up-CI' = $null; 'down-CI' = 'up-CI' }
        function Measure-Small($builds) { Measure-CiWaste -Builds $builds -AsOf $script:SmallAsOf -Hours 24 -ChainMap $script:Chain }
    }

    It 'ignores non-CI definitions and builds outside the window' {
        $r = Measure-Small @(
            (New-FakeBuild 1 'deploy-CD' 'a' '2026-10-10T08:00:00Z' '2026-10-10T08:00:10Z' '2026-10-10T08:10:00Z'),
            (New-FakeBuild 2 'down-CI' 'a' '2026-10-08T08:00:00Z' '2026-10-08T08:00:10Z' '2026-10-08T08:10:00Z'),
            (New-FakeBuild 3 'down-CI' 'b' '2026-10-10T08:00:00Z' '2026-10-10T08:00:30Z' '2026-10-10T08:10:30Z'))
        $r.totals.ci.runs | Should -Be 1
        $r.totals.ci.totalMinutes | Should -Be 10
    }

    It 'treats same definition + commit + branch as duplicates, keeps the last succeeded, never mixes branches' {
        $r = Measure-Small @(
            (New-FakeBuild 1 'down-CI' 'a' '2026-10-10T08:00:00Z' '2026-10-10T08:00:00Z' '2026-10-10T08:10:00Z'),
            (New-FakeBuild 2 'down-CI' 'a' '2026-10-10T08:20:00Z' '2026-10-10T08:20:00Z' '2026-10-10T08:25:00Z' 'failed'),
            (New-FakeBuild 3 'down-CI' 'a' '2026-10-10T08:30:00Z' '2026-10-10T08:30:00Z' '2026-10-10T08:50:00Z'),
            (New-FakeBuild 4 'down-CI' 'a' '2026-10-10T08:31:00Z' '2026-10-10T08:31:00Z' '2026-10-10T08:41:00Z' 'succeeded' 'manual' 'refs/tags/r1'))
        $d = $r.definitions[0]
        $d.runs | Should -Be 4
        $d.duplicateRuns | Should -Be 2          # runs 1 and 2; run 3 is the last succeeded; the tag run is another branch
        $d.wastedMinutes | Should -Be 15         # 10 + 5
    }

    It 'measures in-progress runs up to AsOf and counts a not-started cancel as zero minutes' {
        $r = Measure-Small @(
            (New-FakeBuild 1 'down-CI' 'a' '2026-10-10T09:00:00Z' '2026-10-10T09:00:00Z' $null),
            (New-FakeBuild 2 'down-CI' 'b' '2026-10-10T09:10:00Z' $null '2026-10-10T09:11:00Z' 'canceled'))
        $r.totals.ci.totalMinutes | Should -Be 60
    }

    It 'flags a repeat on unchanged inputs as redundant but not a rerun after a new upstream commit' {
        $r = Measure-Small @(
            (New-FakeBuild 1 'up-CI' 'u1' '2026-10-10T08:00:00Z' '2026-10-10T08:00:00Z' '2026-10-10T08:05:00Z'),
            (New-FakeBuild 2 'down-CI' 'd1' '2026-10-10T08:10:00Z' '2026-10-10T08:10:00Z' '2026-10-10T08:20:00Z' 'succeeded' 'resourceTrigger'),
            (New-FakeBuild 3 'down-CI' 'd1' '2026-10-10T08:30:00Z' '2026-10-10T08:30:00Z' '2026-10-10T08:40:00Z' 'succeeded' 'resourceTrigger'),   # same inputs: redundant
            (New-FakeBuild 4 'up-CI' 'u2' '2026-10-10T08:45:00Z' '2026-10-10T08:45:00Z' '2026-10-10T08:50:00Z'),
            (New-FakeBuild 5 'down-CI' 'd1' '2026-10-10T08:55:00Z' '2026-10-10T08:55:00Z' '2026-10-10T09:05:00Z' 'succeeded' 'resourceTrigger'))  # upstream moved: legitimate
        $down = $r.definitions | Where-Object definition -eq 'down-CI'
        $down.duplicateRuns | Should -Be 2          # strict: three runs of d1
        $down.redundantRuns | Should -Be 1          # realistic: only run 3
        $down.redundantMinutes | Should -Be 10
    }

    It 'does not call a canceled run a prior build of the same inputs' {
        $r = Measure-Small @(
            (New-FakeBuild 1 'down-CI' 'd1' '2026-10-10T08:00:00Z' '2026-10-10T08:00:00Z' '2026-10-10T08:02:00Z' 'canceled'),
            (New-FakeBuild 2 'down-CI' 'd1' '2026-10-10T08:10:00Z' '2026-10-10T08:10:00Z' '2026-10-10T08:20:00Z'))
        ($r.definitions | Where-Object definition -eq 'down-CI').redundantRuns | Should -Be 0
    }

    It 'computes queue wait percentiles per definition' {
        $builds = 0..9 | ForEach-Object {
            New-FakeBuild $_ 'down-CI' "s$_" "2026-10-10T08:0$($_):00Z" "2026-10-10T08:0$($_):0$($_)Z" "2026-10-10T08:5$($_):00Z"
        }
        $d = (Measure-Small $builds).definitions[0]
        $d.queueWaitP50Minutes | Should -Be 0.1     # waits are 0..9 seconds
        $d.queueWaitMaxMinutes | Should -Be 0.2
    }

    It 'computes concurrency and time at capacity of a pool' {
        $jr = @{ 45 = @(
                @{ queueTime = '2026-10-10T08:00:00Z'; assignTime = '2026-10-10T08:00:00Z'; finishTime = '2026-10-10T09:00:00Z' },
                @{ queueTime = '2026-10-10T08:00:00Z'; assignTime = '2026-10-10T08:30:00Z'; finishTime = '2026-10-10T09:30:00Z' }) }
        $r = Measure-CiWaste -Builds @() -JobRequests $jr -PoolInfo @{ 45 = @{ name = 'CI'; capacity = 2 } } -AsOf $script:SmallAsOf -Hours 2
        $p = $r.pools[0]
        $p.maxConcurrency | Should -Be 2
        $p.sustainedPeak | Should -Be 2
        $p.avgConcurrency | Should -Be 1.0          # 120 job-minutes over 120 minutes
        $p.percentTimeAtCapacity | Should -Be 25    # 30 of 120 minutes
        $p.queueWaitMaxMinutes | Should -Be 30
    }
}

Describe 'Get-CiWasteReport (REST layer mocked)' {
    BeforeAll {
        $script:SecretToken = 'SECRET-TOKEN-6369-DO-NOT-PRINT'
        $script:Builds = @($script:Fixture.builds)
        $script:Calls = [System.Collections.Generic.List[string]]::new()
    }

    BeforeEach {
        $script:Calls.Clear()
        Mock -ModuleName Get-CiWasteReport Get-CiWasteAdoToken { 'SECRET-TOKEN-6369-DO-NOT-PRINT' }
        Mock -ModuleName Get-CiWasteReport Invoke-CiWasteAdoGet {
            $script:Calls.Add($Uri)
            if ($Token -ne 'SECRET-TOKEN-6369-DO-NOT-PRINT') { throw 'wrong token' }
            if ($Uri -match '/_apis/build/builds') {
                if ($Uri -notmatch 'continuationToken') {
                    return @{ Body = [pscustomobject]@{ value = @($script:Builds | Select-Object -First 300) }; ContinuationToken = 'next-page' }
                }
                return @{ Body = [pscustomobject]@{ value = @($script:Builds | Select-Object -Skip 300) }; ContinuationToken = $null }
            }
            if ($Uri -match 'pools/(\d+)/jobrequests') { return @{ Body = [pscustomobject]@{ value = @($script:Fixture.jobRequests."$($Matches[1])") }; ContinuationToken = $null } }
            if ($Uri -match 'pools/(\d+)/agents') { return @{ Body = [pscustomobject]@{ value = @(1..$script:Fixture.poolInfo."$($Matches[1])".capacity | ForEach-Object { [pscustomobject]@{ enabled = $true } }) }; ContinuationToken = $null } }
            throw "unexpected uri $Uri"
        }
    }

    It 'emits the standard schemaVersion envelope with -Json and the baseline numbers' {
        $doc = Get-CiWasteReport -AsOf $script:AsOf -Json | ConvertFrom-Json
        $doc.schemaVersion | Should -Be 1
        $doc.command | Should -Be 'Get-CiWasteReport'
        $doc.timestamp | Should -Not -BeNullOrEmpty
        $doc.data.totals.chain.runs | Should -Be 284
        $doc.data.totals.chain.duplicateRuns | Should -BeGreaterThan 166
        @($doc.data.definitions).Count | Should -BeGreaterThan 19
        @($doc.data.pools).Count | Should -Be 2
        ($doc.data.pools | Where-Object poolId -eq 45).capacity | Should -Be 8
    }

    It 'follows the continuation token of the builds API' {
        $null = Get-CiWasteReport -AsOf $script:AsOf -Json
        @($script:Calls | Where-Object { $_ -match '_apis/build/builds' }).Count | Should -Be 2
    }

    It 'never prints the token in text or JSON mode' {
        $text = Get-CiWasteReport -AsOf $script:AsOf *>&1 | Out-String
        $json = Get-CiWasteReport -AsOf $script:AsOf -Json *>&1 | Out-String
        $text | Should -Not -BeLike "*$script:SecretToken*"
        $json | Should -Not -BeLike "*$script:SecretToken*"
        $text | Should -BeLike '*CI waste report*'
    }

    It 'queries only read endpoints below dev.azure.com' {
        $null = Get-CiWasteReport -AsOf $script:AsOf -Json
        $script:Calls.Count | Should -BeGreaterThan 4
        foreach ($u in $script:Calls) {
            $u | Should -Match '^https://dev\.azure\.com/meshmakers/'
            $u | Should -Match '_apis/(build/builds|distributedtask/pools/\d+/(jobrequests|agents))'
        }
    }
}

Describe 'Get-CiWasteReport HTTP layer' {
    It 'only sends GET requests and passes the token as a bearer credential, not in the URL' {
        Mock -ModuleName Get-CiWasteReport Get-CiWasteAdoToken { 'SECRET-TOKEN-6369-DO-NOT-PRINT' }
        Mock -ModuleName Get-CiWasteReport Invoke-RestMethod { [pscustomobject]@{ value = @() } }
        $null = Get-CiWasteReport -AsOf $script:AsOf -Json
        Should -Invoke -ModuleName Get-CiWasteReport Invoke-RestMethod -ParameterFilter { $Method -ne 'Get' } -Times 0 -Exactly
        Should -Invoke -ModuleName Get-CiWasteReport Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' -and $Authentication -eq 'Bearer' -and $Uri -notmatch 'SECRET' } -Times 1
    }

    It 'reports an HTTP failure without leaking headers or the token' {
        Mock -ModuleName Get-CiWasteReport Get-CiWasteAdoToken { 'SECRET-TOKEN-6369-DO-NOT-PRINT' }
        Mock -ModuleName Get-CiWasteReport Invoke-RestMethod { throw 'Response status code does not indicate success: 401. Authorization: Bearer SECRET-TOKEN-6369-DO-NOT-PRINT' }
        $err = $null
        try { Get-CiWasteReport -AsOf $script:AsOf -Json } catch { $err = $_.Exception.Message }
        $err | Should -BeLike 'Azure DevOps GET failed*'
        $err | Should -Not -BeLike '*SECRET*'
    }
}
