#Requires -Modules Pester
<#
    Pester tests for feature environments (OctoEnvironment.psm1, AB#8700).

    Everything runs in TestDrive: a fake workspace with branches/main holding `git init` repositories (each with a
    bare "origin"), a fake nuget/ feed and fake catalogs. The developer's real lanes, ~/.nuget/packages and git config
    are never touched (GIT_CONFIG_GLOBAL points into TestDrive); no build runs (the build step of Invoke-BuildRange
    and its process detection are mocked) and no process is started or stopped.

    Run:  Invoke-Pester ./tests/OctoEnvironment.Tests.ps1
#>

BeforeAll { . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1') }

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'New-OctoEnvironment' {
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'creates worktrees, an isolated Octo.User.props, the manifest and the seeded feed and catalogs' {
        $doc = Get-Doc (New-OctoEnvironment -env ab8625-enum-null -repos construction-kit-engine -workItem 8625 -owner 'agent-1' -Json)
        $doc.command | Should -Be 'New-OctoEnvironment'
        $doc.data.success | Should -BeTrue

        $envPath = Join-Path $ws.Root 'wt-ab8625-enum-null'
        $user = ([Environment]::UserName).ToLowerInvariant() -replace '[^a-z0-9._-]', ''
        $branch = "$user/AB#8625_enum-null"
        (Invoke-TestGit (Join-Path $envPath 'octo-construction-kit-engine') rev-parse --abbrev-ref HEAD) | Should -Be $branch

        $manifest = Get-Content (Join-Path $envPath '.octo/environment.json') -Raw | ConvertFrom-Json
        $manifest.schemaVersion | Should -Be 1
        $manifest.name | Should -Be 'ab8625-enum-null'
        $manifest.workItem | Should -Be 'AB#8625'
        $manifest.base | Should -Be 'branches/main'
        $manifest.owner | Should -Be 'agent-1'
        $manifest.slot | Should -Be 'ab8625-enum-null'
        { [DateTime]$manifest.created } | Should -Not -Throw
        @($manifest.repos).Count | Should -Be 1
        $manifest.repos[0].name | Should -Be 'octo-construction-kit-engine'
        $manifest.repos[0].role | Should -Be 'feature'
        $manifest.repos[0].branch | Should -Be $branch
        $manifest.repos[0].path | Should -Be (Join-Path $envPath 'octo-construction-kit-engine')
        $manifest.repos[0].baseCommit | Should -Be (Invoke-TestGit (Join-Path $ws.Main 'octo-construction-kit-engine') rev-parse HEAD)

        (Get-OctoLaneBuildSettings -laneRootPath $envPath).isolated | Should -BeTrue
        Get-Content (Join-Path $envPath 'Octo.User.props') -Raw | Should -Match '<OctoEnvironment>ab8625-enum-null</OctoEnvironment>'
        Get-Content (Join-Path $envPath 'Octo.User.props') -Raw | Should -Match 'branches/main/Octo.User.props'
        Find-OctoLaneRoot -path (Join-Path $envPath 'octo-construction-kit-engine/src') | Should -Be $envPath
        @(Get-ChildItem (Join-Path $envPath 'nuget') -Filter *.nupkg).Count | Should -Be 3
        Test-Path (Join-Path $envPath '.octo/local-catalog/ck-models/v3/catalog.json') | Should -BeTrue
        Test-Path (Join-Path $envPath '.octo/local-catalog/ck-models/v3/.catalog-index.lock') | Should -BeFalse
        Test-Path (Join-Path $envPath '.octo/local-blueprint-catalog/blueprints/v1/App/1.0.0/blueprint.yaml') | Should -BeTrue
        foreach ($folder in @('.nuget-packages', 'logFiles')) { Test-Path (Join-Path $envPath $folder) -PathType Container | Should -BeTrue }
        # the base lane is never written
        @(Get-ChildItem (Join-Path $ws.Main 'nuget')).Count | Should -Be 3
        Test-Path (Join-Path $ws.Main '.octo/sync') | Should -BeFalse
    }

    It 'takes -branchName and several repositories, and checks out an existing branch instead of creating it' {
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') branch 'feature/existing' | Out-Null
        $doc = Get-Doc (New-OctoEnvironment -env feat-x -repos 'octo-sdk,octo-construction-kit-engine' -branchName 'feature/existing' -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.manifest.repos.name) | Should -Be @('octo-sdk', 'octo-construction-kit-engine')
        (Invoke-TestGit (Join-Path $ws.Root 'wt-feat-x/octo-sdk') rev-parse --abbrev-ref HEAD) | Should -Be 'feature/existing'
        (Invoke-TestGit (Join-Path $ws.Root 'wt-feat-x/octo-construction-kit-engine') rev-parse --abbrev-ref HEAD) | Should -Be 'feature/existing'
    }

    It 'refuses an invalid name, an existing environment, an unknown repository and a missing base' {
        (Get-Doc (New-OctoEnvironment -env 'Bad_Name' -repos octo-sdk -Json)).data.error | Should -Match 'Invalid environment name'
        (Get-Doc (New-OctoEnvironment -env 'ok-env' -repos octo-nope -Json)).data.error | Should -Match 'not a git checkout'
        (Get-Doc (New-OctoEnvironment -env 'ok-env' -repos octo-sdk -base 'branches/none' -Json)).data.error | Should -Match 'does not exist'
        Test-Path (Join-Path $ws.Root 'wt-ok-env') | Should -BeFalse
        (Get-Doc (New-OctoEnvironment -env 'ok-env' -repos octo-sdk -Json)).data.success | Should -BeTrue
        $again = Get-Doc (New-OctoEnvironment -env 'ok-env' -repos octo-sdk -Json)
        $again.data.success | Should -BeFalse
        $again.data.error | Should -Match 'already exists'
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'refuses an environment folder inside the base lane ($rootPath pointing into the lane)' {
        $global:rootPath = $ws.Main
        $doc = Get-Doc (New-OctoEnvironment -env 'inside' -repos octo-sdk -base $ws.Main -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'inside the base lane'
        Test-Path (Join-Path $ws.Main 'wt-inside') | Should -BeFalse
    }

    It '-WhatIf creates nothing' {
        $doc = Get-Doc (New-OctoEnvironment -env 'dry' -repos octo-sdk -WhatIf -Json)
        $doc.data.dryRun | Should -BeTrue
        Test-Path (Join-Path $ws.Root 'wt-dry') | Should -BeFalse
        @(Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree list).Count | Should -Be 1
    }
}

Describe 'Get-OctoEnvironment' {
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'lists environments and shows the git state of one' {
        (Get-Doc (Get-OctoEnvironment -Json)).data.environments.Count | Should -Be 0
        New-OctoEnvironment -env 'env-a' -repos octo-sdk -Json | Out-Null
        New-OctoEnvironment -env 'env-b' -repos mm-common -Json | Out-Null
        @((Get-Doc (Get-OctoEnvironment -Json)).data.environments.name) | Should -Be @('env-a', 'env-b')

        Set-Content -Path (Join-Path $ws.Root 'wt-env-a/octo-sdk/new.txt') -Value 'x'
        $one = (Get-Doc (Get-OctoEnvironment -env 'env-a' -Json)).data
        $one.repos[0].dirty | Should -BeTrue
        $one.repos[0].exists | Should -BeTrue
        (Get-Doc (Get-OctoEnvironment -env 'missing' -Json)).data.success | Should -BeFalse
    }
}

Describe 'Remove-OctoEnvironment' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-r' -repos octo-sdk -branchName 'feature/r' -Json | Out-Null
        $script:wt = Join-Path $ws.Root 'wt-env-r/octo-sdk'
    }

    It 'refuses a dirty worktree and removes nothing' {
        Set-Content -Path (Join-Path $wt 'untracked.txt') -Value 'x'
        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-r' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'octo-sdk: uncommitted changes'
        Test-Path $wt | Should -BeTrue
    }

    It 'refuses unpushed commits, removes after the push and keeps the branch' {
        Set-Content -Path (Join-Path $wt 'change.txt') -Value 'x'
        Invoke-TestGit $wt add -A | Out-Null
        Invoke-TestGit $wt commit -q -m change | Out-Null
        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-r' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match '1 unpushed commit'

        Invoke-TestGit $wt push -q -u origin 'feature/r' | Out-Null
        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-r' -Json)
        $doc.data.success | Should -BeTrue
        Test-Path (Join-Path $ws.Root 'wt-env-r') | Should -BeFalse
        @(Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree list).Count | Should -Be 1
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') rev-parse --verify --quiet 'refs/heads/feature/r' | Should -Not -BeNullOrEmpty
    }

    It 'removes a clean environment without commits; ignored build output does not block it' {
        New-Item -ItemType Directory -Force -Path (Join-Path $wt 'bin/DebugL') | Out-Null
        Set-Content -Path (Join-Path $wt 'bin/DebugL/x.dll') -Value 'x'
        (Get-Doc (Remove-OctoEnvironment -env 'env-r' -Json)).data.success | Should -BeTrue
        Test-Path (Join-Path $ws.Root 'wt-env-r') | Should -BeFalse
    }

    It '-WhatIf removes nothing; an unknown environment fails' {
        (Get-Doc (Remove-OctoEnvironment -env 'env-r' -WhatIf -Json)).data.dryRun | Should -BeTrue
        Test-Path $wt | Should -BeTrue
        (Get-Doc (Remove-OctoEnvironment -env 'nope' -Json)).data.success | Should -BeFalse
    }

    It 'has no -force switch' {
        (Get-Command Remove-OctoEnvironment).Parameters.Keys | Should -Not -Contain 'force'
    }
}

Describe 'Sync-OctoEnvironment (PrivateFeed rules)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-s' -repos octo-sdk -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-s'
        $script:feed = Join-Path $envPath 'nuget'
        $script:cache = Join-Path $envPath '.nuget-packages'
    }

    It 'copies new base packages, refreshes changed mirrored ones, keeps environment-built ones and purges their stale cache' {
        # environment builds sdk; base rebuilds engine and sdk and adds a new package
        Set-Content -Path (Join-Path $feed 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Value 'sdk-env' -NoNewline
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Octo.Runtime.Engine' 'engine-v2' | Out-Null
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Octo.Sdk.Common' 'sdk-v2' | Out-Null
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Octo.New' 'new-v1' | Out-Null
        # extracted copies in the environment cache: engine is stale after the refresh, sdk matches the env build
        New-FakePackage (Join-Path $cache 'meshmakers.octo.runtime.engine/999.0.0') 'meshmakers.octo.runtime.engine' 'engine-v1' | Out-Null
        New-FakePackage (Join-Path $cache 'meshmakers.octo.sdk.common/999.0.0') 'meshmakers.octo.sdk.common' 'sdk-env' | Out-Null

        $doc = Get-Doc (Sync-OctoEnvironment -env 'env-s' -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.nuget.copied) | Should -Be @('Meshmakers.Octo.New.999.0.0.nupkg')
        @($doc.data.nuget.refreshed) | Should -Be @('Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg')
        @($doc.data.nuget.kept) | Should -Be @('Meshmakers.Octo.Sdk.Common.999.0.0.nupkg')
        Get-Content (Join-Path $feed 'Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') -Raw | Should -Be 'engine-v2'
        Get-Content (Join-Path $feed 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-env'
        @($doc.data.purgedFromCache) | Should -Be @('meshmakers.octo.runtime.engine/999.0.0')
        Test-Path (Join-Path $cache 'meshmakers.octo.runtime.engine/999.0.0') | Should -BeFalse
        Test-Path (Join-Path $cache 'meshmakers.octo.sdk.common/999.0.0') | Should -BeTrue

        # the environment's package keeps winning on the next sync, too
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Octo.Sdk.Common' 'sdk-v3' | Out-Null
        $doc = Get-Doc (Sync-OctoEnvironment -env 'env-s' -Json)
        @($doc.data.nuget.kept) | Should -Be @('Meshmakers.Octo.Sdk.Common.999.0.0.nupkg')
        Get-Content (Join-Path $feed 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-env'
        Get-Content (Join-Path $ws.Main 'nuget/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-v3'   # base untouched
    }

    It '-WhatIf reports and writes nothing' {
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Octo.Runtime.Engine' 'engine-v2' | Out-Null
        $doc = Get-Doc (Sync-OctoEnvironment -env 'env-s' -WhatIf -Json)
        $doc.data.dryRun | Should -BeTrue
        @($doc.data.nuget.refreshed) | Should -Be @('Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg')
        Get-Content (Join-Path $feed 'Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') -Raw | Should -Be 'engine-v1'
        (Get-Doc (Sync-OctoEnvironment -env 'env-s' -Json)).data.nuget.refreshed | Should -Be @('Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg')
    }

    It 'merges a catalog index changed on both sides, drops a cache file changed on both sides, refreshes the rest' {
        $index = '.octo/local-catalog/ck-models/v3/catalog.json'
        $cacheFile = '.octo/local-catalog/cache/local-catalog-cache.json'
        New-FakeCatalogIndex (Join-Path $envPath $index) @('Basic', 'System', 'EnvModel')
        Set-Content -Path (Join-Path $envPath $cacheFile) -Value '{"models":{"EnvModel":{}}}'
        New-FakeCatalogIndex (Join-Path $ws.Main $index) @('Basic', 'MainModel', 'System')
        Set-Content -Path (Join-Path $ws.Main $cacheFile) -Value '{"models":{"MainModel":{}}}'
        Set-Content -Path (Join-Path $ws.Main '.octo/local-blueprint-catalog/blueprints/v1/App/1.0.0/blueprint.yaml') -Value 'name: App2'

        $doc = Get-Doc (Sync-OctoEnvironment -env 'env-s' -Json)
        @($doc.data.catalogs.'local-catalog'.merged) | Should -Be @('ck-models/v3/catalog.json')
        @($doc.data.catalogs.'local-catalog'.dropped) | Should -Be @('cache/local-catalog-cache.json')
        @($doc.data.catalogs.'local-blueprint-catalog'.refreshed) | Should -Be @('blueprints/v1/App/1.0.0/blueprint.yaml')
        $merged = Get-Content (Join-Path $envPath $index) -Raw | ConvertFrom-Json
        @($merged.models.modelName) | Should -Be @('Basic', 'EnvModel', 'MainModel', 'System')
        Test-Path (Join-Path $envPath $cacheFile) | Should -BeFalse

        # a dropped cache file is not brought back by the next sync
        (Get-Doc (Sync-OctoEnvironment -env 'env-s' -Json)).data.catalogs.'local-catalog'.copied | Should -BeNullOrEmpty
        Test-Path (Join-Path $envPath $cacheFile) | Should -BeFalse
    }

    It 'merges per-model version indexes by version and recomputes latestVersion' {
        InModuleScope OctoEnvironment {
            $environmentJson = '{"modelId":"Basic","majorVersion":2,"latestVersion":"2.6.0","versions":[{"version":"2.6.0","fileName":"env"},{"version":"2.5.0","fileName":"env-2.5"}]}'
            $baseJson = '{"modelId":"Basic","majorVersion":2,"latestVersion":"2.10.0","versions":[{"version":"2.10.0","fileName":"base"},{"version":"2.5.0","fileName":"base-2.5"}]}'
            $merged = Merge-OctoCatalogIndex -environmentJson $environmentJson -baseJson $baseJson | ConvertFrom-Json
            @($merged.versions.version) | Should -Be @('2.10.0', '2.6.0', '2.5.0')
            ($merged.versions | Where-Object version -eq '2.5.0').fileName | Should -Be 'env-2.5'
            $merged.latestVersion | Should -Be '2.10.0'
        }
    }
}

Describe 'Get-OctoAffectedRepos (package graph)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-g' -repos octo-construction-kit-engine -Json | Out-Null
    }

    It 'returns the transitive consumers of the feature repositories in build order' {
        $doc = Get-Doc (Get-OctoAffectedRepos -env 'env-g' -Json)
        @($doc.data.features) | Should -Be @('octo-construction-kit-engine')
        @($doc.data.affected.repo) | Should -Be @('octo-sdk', 'octo-asset-repo-services', 'octo-cli')
        ($doc.data.affected | Where-Object repo -eq 'octo-sdk').depth | Should -Be 1
        ($doc.data.affected | Where-Object repo -eq 'octo-asset-repo-services').depth | Should -Be 2
        @(($doc.data.affected | Where-Object repo -eq 'octo-sdk').via) | Should -Be @('Meshmakers.Octo.Runtime.Engine (octo-construction-kit-engine)')
        @($doc.data.affected.repo) | Should -Not -Contain 'octo-identity-services'
        @($doc.data.affected.repo) | Should -Not -Contain 'mm-common'
    }

    It '-target keeps only the repositories on the path to the target' {
        $doc = Get-Doc (Get-OctoAffectedRepos -env 'env-g' -target asset-repo-services -Json)
        @($doc.data.affected.repo) | Should -Be @('octo-sdk', 'octo-asset-repo-services')
    }

    It 'reads produced ids and references from csproj files (PackageId, project name, IsPackable=false)' {
        InModuleScope OctoEnvironment -Parameters @{ main = $ws.Main } {
            $engine = Get-OctoRepoPackageInfo -path (Join-Path $main 'octo-construction-kit-engine')
            @($engine.Produces) | Should -Be @('Meshmakers.Octo.Runtime.Engine')        # Engine.Tests is not packable
            @($engine.References) | Should -Be @('Meshmakers.Common.Shared')             # own package and Newtonsoft are not listed
            $service = Get-OctoRepoPackageInfo -path (Join-Path $main 'octo-asset-repo-services')
            @($service.Produces).Count | Should -Be 0
        }
    }

    It 'uses the environment worktree, not the base folder, for a repository in the environment' {
        # the env's engine starts consuming the sdk's package: no cycle into the result, sdk still affected
        New-Csproj (Join-Path $ws.Root 'wt-env-g/octo-construction-kit-engine') 'Extra' -packageId 'Meshmakers.Octo.Extra'
        New-Csproj (Join-Path $ws.Main 'octo-identity-services') 'UsesExtra' -references 'Meshmakers.Octo.Extra' -notPackable
        @((Get-Doc (Get-OctoAffectedRepos -env 'env-g' -Json)).data.affected.repo) | Should -Contain 'octo-identity-services'
    }
}

Describe 'Invoke-BuildEnvironment' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-b' -repos octo-sdk -branchName 'feature/b' -Json | Out-Null
        Add-OctoEnvironmentRepo -env 'env-b' -repo octo-cli -role consumer -Json | Out-Null
        New-OctoEnvironment -env 'env-other' -repos octo-construction-kit-engine -branchName 'feature/o' -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-b'
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName OctoEnvironment Invoke-KillDotnet { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $true; exitCode = 0; killedCount = 0; processes = @() }) }
        $script:built = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:built.Add([pscustomobject]@{ Repo = $entry.Name; Path = $entry.Path; NuGetPackages = $env:NUGET_PACKAGES; VerifyTests = [bool]$verifyTests })
            if ($entry.Name -eq 'octo-sdk') {
                New-FakePackage (Join-Path $entry.Path 'src/Sdk.Common/bin/DebugL') 'Meshmakers.Octo.Sdk.Common' 'sdk-env' | Out-Null
            }
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
    }

    It 'builds exactly the environment''s repositories in build order, into the environment feed and cache' {
        New-FakePackage (Join-Path $envPath '.nuget-packages/meshmakers.octo.sdk.common/999.0.0') 'meshmakers.octo.sdk.common' 'sdk-v1' | Out-Null
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-b' -verifyTests -Json)
        $doc.command | Should -Be 'Invoke-BuildEnvironment'
        $doc.data.success | Should -BeTrue
        $doc.data.environment.name | Should -Be 'env-b'
        @($doc.data.environment.repos) | Should -Be @('octo-sdk', 'octo-cli')
        $doc.data.synced | Should -BeFalse
        @($script:built.Repo) | Should -Be @('octo-sdk', 'octo-cli')
        $script:built[0].Path | Should -Be (Join-Path $envPath 'octo-sdk')
        $script:built[0].NuGetPackages | Should -Be (Join-Path $envPath '.nuget-packages')
        $doc.data.lane.isolated | Should -BeTrue
        @($doc.data.packageCaches) | Should -Be @((Join-Path $envPath '.nuget-packages'))
        Get-Content (Join-Path $envPath 'nuget/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-env'
        Test-Path (Join-Path $envPath '.nuget-packages/meshmakers.octo.sdk.common/999.0.0') | Should -BeFalse    # per-package purge, env cache
        Get-Content (Join-Path $ws.Main 'nuget/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-v1' # main feed untouched
        Get-Content (Join-Path $ws.Root 'wt-env-other/nuget/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-v1'
    }

    It '-syncMain syncs first and keeps the environment-built package' {
        Invoke-BuildEnvironment -env 'env-b' -Json | Out-Null
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Octo.Runtime.Engine' 'engine-v2' | Out-Null
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-b' -syncMain -Json)
        $doc.data.synced | Should -BeTrue
        @($doc.data.sync.nuget.refreshed) | Should -Be @('Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg')
        Get-Content (Join-Path $envPath 'nuget/Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') -Raw | Should -Be 'engine-v2'
        Get-Content (Join-Path $envPath 'nuget/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-env'
    }

    It '-DryRun builds nothing and does not sync' {
        New-FakePackage (Join-Path $ws.Main 'nuget') 'Meshmakers.Octo.Runtime.Engine' 'engine-v2' | Out-Null
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-b' -syncMain -DryRun -Json)
        $doc.command | Should -Be 'Invoke-BuildEnvironment'
        $doc.data.synced | Should -BeFalse
        $script:built.Count | Should -Be 0
        Get-Content (Join-Path $envPath 'nuget/Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') -Raw | Should -Be 'engine-v1'
    }

    It '-EventsFile writes every event with command Invoke-BuildEnvironment' {
        $events = Join-Path $TestDrive 'events-b.jsonl'
        Invoke-BuildEnvironment -env 'env-b' -EventsFile $events -Json | Out-Null
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        $records.Count | Should -BeGreaterThan 2
        @($records.command | Select-Object -Unique) | Should -Be @('Invoke-BuildEnvironment')
        $records[-1].event | Should -Be 'done'
        $records[-1].success | Should -BeTrue
    }

    It 'fails for an unknown environment with success=false, a done event and LASTEXITCODE 1' {
        $events = Join-Path $TestDrive 'events-missing.jsonl'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'missing' -EventsFile $events -Json)
        $doc.data.success | Should -BeFalse
        $global:LASTEXITCODE | Should -Be 1
        (Get-Content $events | ConvertFrom-Json).event | Should -Be 'done'
    }
}

Describe 'Kill scope and CK sync in environments' {
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'the main lane''s kill scope never matches environment processes, the environment''s scope does' {
        $envRepo = Join-Path $ws.Root 'wt-env-k/octo-sdk/bin/DebugL/net10.0'
        $mainRepo = Join-Path $ws.Main 'octo-sdk/bin/DebugL/net10.0'
        InModuleScope Invoke-KillDotnet -Parameters @{ ws = $ws; envRepo = $envRepo; mainRepo = $mainRepo } {
            $candidates = @(
                [pscustomobject]@{ Pid = 1; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $envRepo; Modules = @() },
                [pscustomobject]@{ Pid = 2; Name = 'dotnet'; Command = "dotnet $(Join-Path $envRepo 'Sdk.dll')"; Cwd = $null; Modules = @() },
                [pscustomobject]@{ Pid = 3; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $mainRepo; Modules = @() }
            )
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $ws.Main).pid | Should -Be @(3)
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath (Join-Path $ws.Root 'wt-env-k')).pid | Should -Be @(1, 2)
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath (Join-Path $ws.Root 'wt-env')).pid | Should -BeNullOrEmpty   # wt-env is no prefix of wt-env-k
        }
    }

    It 'the CK sync of an environment without the engine uses the base lane''s octo-ckc' {
        New-OctoEnvironment -env 'env-ck' -repos octo-sdk -Json | Out-Null
        $envPath = Join-Path $ws.Root 'wt-env-ck'
        $ckDir = Join-Path $envPath 'octo-sdk/src/CkModel'
        New-Item -ItemType Directory -Force -Path $ckDir | Out-Null
        Set-Content -Path (Join-Path $ckDir 'ckModel.yaml') -Value "ckLanguage: 2`nmodelId: Test"
        $exe = if ($IsWindows) { 'octo-ckc.exe' } else { 'octo-ckc' }
        $baseCkc = Join-Path $ws.Main "octo-construction-kit-engine/bin/DebugL/net10.0/publish/$exe"
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $baseCkc) | Out-Null
        Set-Content -Path $baseCkc -Value 'fake'
        Mock -ModuleName Sync-OctoCkIntermediateVersions pwsh { $global:LASTEXITCODE = 0; "ckc=$env:OCTO_CKSYNC_CKC" }

        $result = Sync-OctoCkIntermediateVersions -repositoryPath (Join-Path $envPath 'octo-sdk') -localCatalogRoot (Join-Path $envPath '.octo/local-catalog') -Quiet
        $result.LocalCatalogRoot | Should -Be (Join-Path $envPath '.octo/local-catalog')
        $result.Output | Should -Be "ckc=$baseCkc"
    }
}

Describe 'Environments are octo-claude-pm lanes (wt-<env>)' {
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'accepts lane names; Remove deletes only what the environment owns (other files in the folder stay)' {
        $lane = Join-Path $ws.Root 'wt-odysseus-kind'
        $doc = Get-Doc (New-OctoEnvironment -env odysseus-kind -repos octo-sdk -branchName 'reimar/AB#1_x' -Json)
        $doc.data.success | Should -BeTrue
        Test-Path (Join-Path $lane 'octo-sdk/.git') -PathType Leaf | Should -BeTrue
        New-Item -ItemType Directory -Force -Path (Join-Path $lane '.octo/notes') | Out-Null
        Set-Content -Path (Join-Path $lane '.octo/notes/handover.md') -Value 'someone else''s file'

        $removed = Get-Doc (Remove-OctoEnvironment -env odysseus-kind -Json)
        $removed.data.success | Should -BeTrue
        @($removed.data.leftOver) | Should -Be @('.octo')
        Test-Path (Join-Path $lane '.octo/notes/handover.md') | Should -BeTrue
        Test-Path (Join-Path $lane '.octo/claims') | Should -BeFalse     # environments create no claims (they live in the base lane)
        foreach ($item in @('octo-sdk', 'nuget', '.nuget-packages', 'Octo.User.props', '.octo/environment.json', '.octo/local-catalog')) {
            Test-Path (Join-Path $lane $item) | Should -BeFalse
        }
    }

    It 'refuses a name whose wt-<name> is an existing lane folder or flat worktree, and changes nothing there' {
        $lane = Join-Path $ws.Root 'wt-plain-lane'
        New-Item -ItemType Directory -Force -Path (Join-Path $lane '.octo/claims') | Out-Null
        $doc = Get-Doc (New-OctoEnvironment -env plain-lane -repos octo-sdk -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'is no feature environment'
        @(Get-ChildItem $lane -Force).Name | Should -Be @('.octo')

        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree add -q -b 'lane/flat' (Join-Path $ws.Root 'wt-odysseus-kind-octo-sdk') | Out-Null
        (Get-Doc (New-OctoEnvironment -env odysseus-kind-octo-sdk -repos mm-common -Json)).data.error | Should -Match 'is no feature environment'
        Test-Path (Join-Path $ws.Root 'wt-odysseus-kind-octo-sdk/.octo') | Should -BeFalse
    }

    It 'discovers environments by wt-*/.octo/environment.json and ignores flat worktrees and plain lane folders' {
        New-OctoEnvironment -env env-d -repos octo-sdk -Json | Out-Null
        Invoke-TestGit (Join-Path $ws.Main 'mm-common') worktree add -q -b 'lane/x' (Join-Path $ws.Root 'wt-odysseus-kind-mm-common') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $ws.Root 'wt-plain-lane/.octo/claims') | Out-Null
        @((Get-Doc (Get-OctoEnvironment -Json)).data.environments.name) | Should -Be @('env-d')
    }
}

Describe 'Invoke-BuildEnvironment with in-place worktrees' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env env-p -repos octo-construction-kit-engine -branchName 'feature/p' -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-p'
        $script:inPlace = Join-Path $ws.Root 'wt-odysseus-kind-octo-sdk'
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree add -q -b 'reimar/AB#6_p' $inPlace | Out-Null
        Add-OctoEnvironmentRepo -env env-p -path $inPlace -inPlace -Json | Out-Null
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        $script:killCalls = [System.Collections.Generic.List[object]]::new()
        $script:killSucceeds = $true
        Mock -ModuleName OctoEnvironment Invoke-KillDotnet {
            $script:killCalls.Add([pscustomobject]@{ Root = $branchRootPath; Additional = @($additionalRoots) })
            if ($script:killSucceeds) { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $true; exitCode = 0; killedCount = 1; processes = @([ordered]@{ pid = 9; name = 'dotnet'; reason = 'cwd' }) }) }
            else { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $false; exitCode = 1; error = 'access denied'; killedCount = 0; processes = @() }) }
        }
        $script:built = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:built.Add([pscustomobject]@{ Repo = $entry.Name; Path = $entry.Path; Properties = $msbuildProperties })
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
    }

    It 'builds the in-place worktree from its folder at its build-order position with the environment''s feed, cache and catalog' {
        $doc = Get-Doc (Invoke-BuildEnvironment -env env-p -Json)
        $doc.data.success | Should -BeTrue
        @($script:built.Repo) | Should -Be @('octo-construction-kit-engine', 'octo-sdk')
        $script:built[0].Path | Should -Be (Join-Path $envPath 'octo-construction-kit-engine')
        $script:built[0].Properties.Count | Should -Be 0
        $sdk = $script:built[1]
        $sdk.Path | Should -Be $inPlace
        $sdk.Properties.RestoreSources | Should -Be "$(Join-Path $envPath 'nuget');https://api.nuget.org/v3/index.json"
        $sdk.Properties.RestorePackagesPath | Should -Be (Join-Path $envPath '.nuget-packages')
        $sdk.Properties.OctoLocalCatalogRootPath | Should -Be (Join-Path $envPath '.octo/local-catalog')
        $doc.data.environment.inPlace.'octo-sdk' | Should -Be $inPlace
    }

    It 'keeps the own feeds of an in-place repository that declares RestoreSources (Telerik), with the environment feed instead of ../nuget' {
        Set-Content -Path (Join-Path $inPlace 'Directory.Build.props') -Value @'
<Project>
    <PropertyGroup>
        <RestoreSources Condition="'$(RestoreSources)'==''">https://api.nuget.org/v3/index.json;https://nuget.telerik.com/v3/index.json</RestoreSources>
        <RestoreSources Condition="'$(OctoNugetPrivateServer)'!=''">$(OctoNugetPrivateServer);https://nuget.telerik.com/v3/index.json</RestoreSources>
        <RestoreSources Condition="'$(Configuration)'=='DebugL'">$(OctoRepoRootPath)../nuget;$(RestoreSources)</RestoreSources>
    </PropertyGroup>
</Project>
'@
        Invoke-BuildEnvironment -env env-p -Json | Out-Null
        ($script:built | Where-Object Repo -eq 'octo-sdk').Properties.RestoreSources |
            Should -Be "$(Join-Path $envPath 'nuget');https://api.nuget.org/v3/index.json;https://nuget.telerik.com/v3/index.json"
    }

    It 'clears the kill scope of wt-<env> and every in-place worktree before the build; -skipKill and -DryRun do not' {
        $doc = Get-Doc (Invoke-BuildEnvironment -env env-p -Json)
        $script:killCalls.Count | Should -Be 1
        $script:killCalls[0].Root | Should -Be $envPath
        @($script:killCalls[0].Additional) | Should -Be @($inPlace)
        @($doc.data.killDotnet.roots) | Should -Be @($envPath, $inPlace)
        $doc.data.killDotnet.killedCount | Should -Be 1

        Invoke-BuildEnvironment -env env-p -skipKill -Json | Out-Null
        Invoke-BuildEnvironment -env env-p -DryRun -Json | Out-Null
        $script:killCalls.Count | Should -Be 1
    }

    It 'does not build when the kill scope cannot be cleared' {
        $script:killSucceeds = $false
        $doc = Get-Doc (Invoke-BuildEnvironment -env env-p -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'access denied'
        $script:built.Count | Should -Be 0
    }

    It 'fails when the in-place worktree is gone' {
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree remove --force $inPlace | Out-Null
        (Get-Doc (Invoke-BuildEnvironment -env env-p -Json)).data.error | Should -Match 'does not exist'
    }
}

Describe 'Get-OctoBuildOrder -additionalRepos' {
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'orders a repository from another folder like a lane folder of that name; a lane folder wins' {
        $lane = Join-Path $TestDrive 'lane-order'
        if (Test-Path $lane) { Remove-Item $lane -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $lane 'octo-construction-kit-engine'), (Join-Path $lane 'octo-cli') | Out-Null
        $order = @(Get-OctoBuildOrder -branchRootPath $lane -additionalRepos @{ 'octo-sdk' = (Join-Path $ws.Main 'octo-sdk'); 'octo-cli' = (Join-Path $ws.Main 'octo-cli') })
        @($order.Name) | Should -Be @('octo-construction-kit-engine', 'octo-sdk', 'octo-cli')
        ($order | Where-Object Name -eq 'octo-sdk').Path | Should -Be (Join-Path $ws.Main 'octo-sdk')
        ($order | Where-Object Name -eq 'octo-cli').Path | Should -Be (Join-Path $lane 'octo-cli')
        { Get-OctoBuildOrder -branchRootPath $lane -additionalRepos @{ 'something' = $lane } } | Should -Throw '*not an mm-* or octo-*'
    }
}

Describe 'Get-OctoInPlaceRestoreSources' {
    It 'resolves the DebugL sources of a repository: own defaults kept, ../nuget replaced, macros dropped' {
        InModuleScope OctoEnvironment -Parameters @{ root = (Join-Path $TestDrive 'restore-sources') } {
            $feed = '/env/nuget'
            $repo = Join-Path $root 'plain'
            New-Item -ItemType Directory -Force -Path $repo | Out-Null
            Get-OctoInPlaceRestoreSources -repositoryPath $repo -environmentFeed $feed | Should -Be "$feed;https://api.nuget.org/v3/index.json"

            $repo = Join-Path $root 'sdk-like'
            New-Item -ItemType Directory -Force -Path $repo | Out-Null
            Set-Content -Path (Join-Path $repo 'Directory.Build.props') -Value '<Project><PropertyGroup><RestoreSources Condition="''$(OctoNugetPrivateServer)''!=''''">$(OctoNugetPrivateServer)</RestoreSources><RestoreSources Condition="''$(Configuration)''==''DebugL''">$(OctoRepoRootPath)../nuget;$(RestoreSources)</RestoreSources></PropertyGroup></Project>'
            Get-OctoInPlaceRestoreSources -repositoryPath $repo -environmentFeed $feed | Should -Be "$feed;https://api.nuget.org/v3/index.json"

            $repo = Join-Path $root 'feed-last'
            New-Item -ItemType Directory -Force -Path $repo | Out-Null
            Set-Content -Path (Join-Path $repo 'Directory.Build.props') -Value '<Project><PropertyGroup><RestoreSources Condition=" ''$(RestoreSources)'' == '''' ">https://a.example/v3/index.json</RestoreSources><RestoreSources Condition="''$(Configuration)''==''DebugL''">$(RestoreSources);$(OctoRepoRootPath)../nuget</RestoreSources></PropertyGroup></Project>'
            Get-OctoInPlaceRestoreSources -repositoryPath $repo -environmentFeed $feed | Should -Be "https://a.example/v3/index.json;$feed"
        }
    }
}

Describe 'In-place RestoreSources with private feeds (macros from Octo.User.props)' {
    BeforeAll {
        $script:reportProps = @'
<Project>
    <PropertyGroup>
        <RestoreSources Condition="'$(RestoreSources)'==''">https://api.nuget.org/v3/index.json;https://nuget.telerik.com/v3/index.json</RestoreSources>
        <RestoreSources Condition="'$(OctoNugetPrivateServer)'!=''">$(OctoNugetPrivateServer);https://nuget.telerik.com/v3/index.json</RestoreSources>
        <RestoreSources Condition="'$(Configuration)'=='DebugL'">$(OctoRepoRootPath)../nuget;$(RestoreSources)</RestoreSources>
    </PropertyGroup>
</Project>
'@
        $script:privateFeed = 'https://builder:topsecret@nuget.example.invalid/v3/index.json'
    }

    It 'substitutes OctoNugetPrivateServer from the base lane''s Octo.User.props (the environment''s wins) and keeps it' {
        InModuleScope OctoEnvironment -Parameters @{ root = (Join-Path $TestDrive 'private-feed'); props = $reportProps; privateFeed = $privateFeed } {
            $repo = Join-Path $root 'octo-report-services'
            New-Item -ItemType Directory -Force -Path $repo | Out-Null
            Set-Content -Path (Join-Path $repo 'Directory.Build.props') -Value $props
            $base = Join-Path $root 'base.props'
            Set-Content -Path $base -Value "<Project><PropertyGroup><OctoNugetPrivateServer>https://old.example.invalid/v3/index.json</OctoNugetPrivateServer></PropertyGroup></Project>"
            $envProps = Join-Path $root 'env.props'
            Set-Content -Path $envProps -Value "<Project><PropertyGroup><OctoNugetPrivateServer>$privateFeed</OctoNugetPrivateServer></PropertyGroup></Project>"

            Get-OctoInPlaceRestoreSources -repositoryPath $repo -environmentFeed '/env/nuget' -userPropsPaths @($base, $envProps) |
                Should -Be "/env/nuget;$privateFeed;https://nuget.telerik.com/v3/index.json"
            # without a private server the default applies
            Get-OctoInPlaceRestoreSources -repositoryPath $repo -environmentFeed '/env/nuget' -userPropsPaths @() |
                Should -Be '/env/nuget;https://api.nuget.org/v3/index.json;https://nuget.telerik.com/v3/index.json'
        }
    }

    It 'drops a source with an unresolvable macro with a warning that names the macro and shows no credentials' {
        InModuleScope OctoEnvironment -Parameters @{ root = (Join-Path $TestDrive 'unresolved') } {
            $repo = Join-Path $root 'octo-x'
            New-Item -ItemType Directory -Force -Path $repo | Out-Null
            Set-Content -Path (Join-Path $repo 'Directory.Build.props') -Value '<Project><PropertyGroup><RestoreSources Condition="''$(RestoreSources)''==''''">https://api.nuget.org/v3/index.json;https://u:topsecret@feed.example.invalid/$(FeedPath)</RestoreSources><RestoreSources Condition="''$(Configuration)''==''DebugL''">$(OctoRepoRootPath)../nuget;$(RestoreSources)</RestoreSources></PropertyGroup></Project>'
            $result = Get-OctoInPlaceRestoreSources -repositoryPath $repo -environmentFeed '/env/nuget' -WarningVariable warnings -WarningAction SilentlyContinue
            $result | Should -Be '/env/nuget;https://api.nuget.org/v3/index.json'
            "$warnings" | Should -Match '\$\(FeedPath\)'
            "$warnings" | Should -Not -Match 'topsecret'
        }
    }

    It 'Hide-OctoUrlCredentials masks user:password in URLs, also inside -p arguments' {
        Hide-OctoUrlCredentials 'https://builder:topsecret@nuget.example.invalid/v3/index.json' | Should -Be 'https://***@nuget.example.invalid/v3/index.json'
        Hide-OctoUrlCredentials '-p:RestoreSources=/env/nuget%3Bhttps://a:b@x.invalid/v3' | Should -Be '-p:RestoreSources=/env/nuget%3Bhttps://***@x.invalid/v3'
        Hide-OctoUrlCredentials 'https://api.nuget.org/v3/index.json' | Should -Be 'https://api.nuget.org/v3/index.json'
    }
}

Describe 'Invoke-BuildEnvironment keeps private feed credentials off the command line' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env env-c2 -repos octo-construction-kit-engine -branchName 'feature/c2' -Json | Out-Null
        $script:inPlace = Join-Path $ws.Root 'wt-lane-octo-sdk'
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree add -q -b 'reimar/AB#7_c' $inPlace | Out-Null
        Set-Content -Path (Join-Path $inPlace 'Directory.Build.props') -Value @'
<Project><PropertyGroup>
  <RestoreSources Condition="'$(RestoreSources)'==''">https://api.nuget.org/v3/index.json;https://nuget.telerik.com/v3/index.json</RestoreSources>
  <RestoreSources Condition="'$(OctoNugetPrivateServer)'!=''">$(OctoNugetPrivateServer);https://nuget.telerik.com/v3/index.json</RestoreSources>
  <RestoreSources Condition="'$(Configuration)'=='DebugL'">$(OctoRepoRootPath)../nuget;$(RestoreSources)</RestoreSources>
</PropertyGroup></Project>
'@
        Set-Content -Path (Join-Path $ws.Main 'Octo.User.props') -Value '<Project><PropertyGroup><OctoNugetPrivateServer>https://builder:top%40secret@nuget.example.invalid/v3/index.json</OctoNugetPrivateServer></PropertyGroup></Project>'
        # user-level NuGet.Config with the Telerik credentials (never the developer's real one)
        $script:userConfig = Join-Path $TestDrive 'user-NuGet.Config'
        Set-Content -Path $userConfig -Value '<configuration><packageSources><add key="Telerik Feed" value="https://nuget.telerik.com/v3/index.json" /></packageSources><packageSourceCredentials><Telerik_x0020_Feed><add key="Username" value="api-key" /><add key="ClearTextPassword" value="telerik-secret" /></Telerik_x0020_Feed></packageSourceCredentials></configuration>'
        Mock -ModuleName OctoEnvironment Get-OctoUserNuGetConfigFile { $script:userConfig }
        Add-OctoEnvironmentRepo -env env-c2 -path $inPlace -inPlace -Json | Out-Null
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName OctoEnvironment Invoke-KillDotnet { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $true; exitCode = 0; killedCount = 0; processes = @() }) }
        $script:seen = $null
        $script:buildFails = $false
        $script:buildThrows = $false
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            if ($entry.Name -eq 'octo-sdk') {
                $config = [string]$msbuildProperties.RestoreConfigFile
                $script:seen = [pscustomobject]@{
                    Arguments     = (ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties) -join ' '
                    Sources       = $msbuildProperties.RestoreSources
                    Config        = $config
                    ConfigExisted = (Test-Path -LiteralPath $config)
                    ConfigText    = if (Test-Path -LiteralPath $config) { Get-Content -LiteralPath $config -Raw } else { '' }
                    Mode          = if (-not $IsWindows -and (Test-Path -LiteralPath $config)) { [IO.File]::GetUnixFileMode($config) } else { $null }
                    FolderMode    = if (-not $IsWindows -and (Test-Path -LiteralPath $config)) { [IO.File]::GetUnixFileMode((Split-Path -Parent $config)) } else { $null }
                }
                if ($script:buildThrows) { throw 'build crashed' }
                return [pscustomobject]@{ Success = -not $script:buildFails; LogFile = $null }
            }
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
    }

    It 'passes the sources without credentials and the credentials in an owner-only RestoreConfigFile that is gone afterwards' {
        $json = (Invoke-BuildEnvironment -env env-c2 -Json) -join "`n"
        $feed = Join-Path $ws.Root 'wt-env-c2/nuget'
        $seen.Sources | Should -Be "$feed;https://nuget.example.invalid/v3/index.json;https://nuget.telerik.com/v3/index.json"
        $seen.Arguments | Should -Not -Match 'secret'
        $seen.Arguments | Should -Match '-p:RestoreConfigFile='
        $seen.ConfigExisted | Should -BeTrue
        [xml]$config = $seen.ConfigText
        @($config.configuration.packageSources.add.value) | Should -Be @($feed, 'https://nuget.example.invalid/v3/index.json', 'https://nuget.telerik.com/v3/index.json')
        $config.configuration.packageSourceCredentials.'octo-source-2'.add[0].value | Should -Be 'builder'
        $config.configuration.packageSourceCredentials.'octo-source-2'.add[1].value | Should -Be 'top@secret'
        $config.configuration.packageSourceCredentials.'octo-source-3'.add[1].value | Should -Be 'telerik-secret'   # carried over from the user-level config
        if (-not $IsWindows) {
            $seen.Mode | Should -Be ([IO.UnixFileMode]'UserRead, UserWrite')
            $seen.FolderMode | Should -Be ([IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        }
        Test-Path -LiteralPath $seen.Config | Should -BeFalse
        Test-Path -LiteralPath (Split-Path -Parent $seen.Config) | Should -BeFalse
        $json | Should -Not -Match 'secret'
    }

    It 'removes the credentials file after a failing and after a throwing build' {
        $script:buildFails = $true
        (Get-Doc (Invoke-BuildEnvironment -env env-c2 -Json)).data.success | Should -BeFalse
        $seen.ConfigExisted | Should -BeTrue
        Test-Path -LiteralPath $seen.Config | Should -BeFalse

        $script:buildFails = $false
        $script:buildThrows = $true
        { Invoke-BuildEnvironment -env env-c2 -Json } | Should -Throw
        $seen.ConfigExisted | Should -BeTrue
        Test-Path -LiteralPath $seen.Config | Should -BeFalse
    }

    It '-DryRun creates no credentials file and prints no credential' {
        $text = (Invoke-BuildEnvironment -env env-c2 -DryRun -Json) -join "`n"
        $text | Should -Not -Match 'secret'
        $text | Should -Match 'generated at build time'
        (Invoke-BuildEnvironment -env env-c2 -DryRun *>&1 | Out-String) | Should -Not -Match 'secret'
    }

    It 'Split-OctoSourceCredentials unescapes credentials and keeps the order' {
        InModuleScope OctoEnvironment {
            $split = Split-OctoSourceCredentials -restoreSources '/feed;https://u%3Ax:p%40ss@a.invalid/v3;https://b.invalid/v3'
            @($split.Sources) | Should -Be @('/feed', 'https://a.invalid/v3', 'https://b.invalid/v3')
            $split.Credentials['https://a.invalid/v3'].User | Should -Be 'u:x'
            $split.Credentials['https://a.invalid/v3'].Password | Should -Be 'p@ss'
        }
    }
}

Describe 'Package graph scan stays out of node_modules, bin, obj and .git' {
    It 'reads every csproj/props of the repository (also outside src/), pruning heavy and generated folders' {
        InModuleScope OctoEnvironment -Parameters @{ root = (Join-Path $TestDrive 'scan') } {
            if (Test-Path $root) { Remove-Item $root -Recurse -Force }
            $repo = Join-Path $root 'octo-frontend-x'
            foreach ($folder in @('src/Lib', 'src/web/node_modules/pkg', 'src/Lib/bin/DebugL', 'src/Lib/obj', '.git/x', 'node_modules/y', 'tests/Lib.Tests', 'dist/d', 'src/web/.angular/cache', 'artifacts/a')) {
                New-Item -ItemType Directory -Force -Path (Join-Path $repo $folder) | Out-Null
            }
            $csproj = '<Project><PropertyGroup><PackageId>{0}</PackageId></PropertyGroup></Project>'
            Set-Content -Path (Join-Path $repo 'src/Lib/Lib.csproj') -Value ($csproj -f 'Meshmakers.Real')
            Set-Content -Path (Join-Path $repo 'tests/Lib.Tests/Lib.Tests.csproj') -Value '<Project><ItemGroup><PackageReference Include="Meshmakers.Octo.Sdk.Common" Version="1" /></ItemGroup><PropertyGroup><IsPackable>false</IsPackable></PropertyGroup></Project>'
            foreach ($hidden in @('src/web/node_modules/pkg/Hidden.csproj', 'src/Lib/bin/DebugL/Bin.csproj', 'src/Lib/obj/Obj.csproj', '.git/x/Git.csproj', 'node_modules/y/Root.csproj', 'dist/d/Dist.csproj', 'src/web/.angular/cache/Ng.csproj', 'artifacts/a/Art.csproj')) {
                Set-Content -Path (Join-Path $repo $hidden) -Value ($csproj -f "Meshmakers.$([IO.Path]::GetFileNameWithoutExtension($hidden))")
            }
            Set-Content -Path (Join-Path $repo 'Directory.Build.props') -Value '<Project><ItemGroup><PackageReference Include="Meshmakers.Common.Shared" Version="1" /></ItemGroup></Project>'

            $files = @(Get-OctoPackageScanFiles -path $repo | ForEach-Object { [IO.Path]::GetRelativePath($repo, $_) -replace '\\', '/' } | Sort-Object)
            $files | Should -Be @('Directory.Build.props', 'src/Lib/Lib.csproj', 'tests/Lib.Tests/Lib.Tests.csproj')
            $info = Get-OctoRepoPackageInfo -path $repo
            @($info.Produces) | Should -Be @('Meshmakers.Real')
            @($info.References) | Should -Be @('Meshmakers.Common.Shared', 'Meshmakers.Octo.Sdk.Common')   # tests/ outside src/ counts

            # a repository without src/ is scanned the same way
            $flat = Join-Path $root 'octo-flat'
            New-Item -ItemType Directory -Force -Path (Join-Path $flat 'Tool'), (Join-Path $flat 'node_modules/z') | Out-Null
            Set-Content -Path (Join-Path $flat 'Tool/Tool.csproj') -Value ($csproj -f 'Meshmakers.Tool')
            Set-Content -Path (Join-Path $flat 'node_modules/z/Z.csproj') -Value ($csproj -f 'Meshmakers.Z')
            @((Get-OctoRepoPackageInfo -path $flat).Produces) | Should -Be @('Meshmakers.Tool')
        }
    }
}

Describe 'Sync reports stay small' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        $blueprints = Join-Path $ws.Main '.octo/local-blueprint-catalog/blueprints/v1'
        foreach ($i in 1..25) {
            New-Item -ItemType Directory -Force -Path (Join-Path $blueprints "Bp$i/1.0.0") | Out-Null
            Set-Content -Path (Join-Path $blueprints "Bp$i/1.0.0/blueprint.yaml") -Value "name: Bp$i"
        }
    }

    It 'New-OctoEnvironment -Json lists counts and at most 20 names; -Detailed lists all' {
        $doc = Get-Doc (New-OctoEnvironment -env env-small -repos octo-sdk -Json)
        $catalog = $doc.data.sync.catalogs.'local-blueprint-catalog'
        $catalog.counts.copied | Should -Be 26
        @($catalog.copied).Count | Should -Be 20
        $catalog.truncated | Should -BeTrue
        $doc.data.sync.nuget.counts.copied | Should -Be 3
        $doc.data.sync.nuget.truncated | Should -BeFalse

        Remove-Item (Join-Path $ws.Root 'wt-env-small/.octo/sync') -Recurse -Force
        Remove-Item (Join-Path $ws.Root 'wt-env-small/.octo/local-blueprint-catalog') -Recurse -Force
        $full = Get-Doc (Sync-OctoEnvironment -env env-small -Detailed -Json)
        @($full.data.catalogs.'local-blueprint-catalog'.copied).Count | Should -Be 26
        $full.data.catalogs.'local-blueprint-catalog'.truncated | Should -BeFalse
        $full.data.detailed | Should -BeTrue
    }
}
