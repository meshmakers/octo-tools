#Requires -Modules Pester
<#
    Pester tests for feature environments (OctoEnvironment.psm1): a first build without catalog refreshes and package
    downloads (AB#8831) - one read of the remote CK catalogs per build run, and a new environment's package cache
    filled from a local cache.

    Part of the OctoEnvironment tests, split over several files so they can run in parallel
    (tests/Invoke-ParallelPester.ps1). Setup and fixtures: tests/OctoEnvironment.TestHelpers.ps1 - everything runs in
    TestDrive, see OctoEnvironment.Tests.ps1.

    Run:  Invoke-Pester ./tests/OctoEnvironment.FastFirstBuild.Tests.ps1
#>

BeforeAll { . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1') }

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'The remote CK catalogs are read at most once per build run (AB#8831)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        # engine (feature) -> sdk -> asset-repo, cli; asset-repo and cli use a construction kit
        New-OctoEnvironment -env 'env-k' -repos octo-construction-kit-engine -branchName 'feature/k' -addAffected -Json | Out-Null
        $script:envPath = Join-Path $ws.Root 'wt-env-k'
        Set-Content -Path (Join-Path $envPath 'octo-asset-repo-services/src/AssetRepository/ckModel.yaml') -Value "ckLanguage: 1`nmodelId: Test"
        New-Item -ItemType Directory -Force -Path (Join-Path $envPath 'octo-cli/samples/Sample') | Out-Null
        Set-Content -Path (Join-Path $envPath 'octo-cli/samples/Sample/construction-kits.yaml') -Value 'dependencies: []'
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName OctoEnvironment Invoke-KillDotnet { Write-OctoJson -Command 'Invoke-KillDotnet' -Data ([ordered]@{ success = $true; exitCode = 0; killedCount = 0; processes = @() }) }
        Mock -ModuleName Invoke-BuildRange Sync-OctoCkIntermediateVersions { }
        $script:builds = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:builds.Add([pscustomobject]@{ Repo = $entry.Name; Refresh = $msbuildProperties['OctoRefreshRemoteCatalogs'] })
            New-Item -ItemType Directory -Force -Path (Join-Path $entry.Path 'bin/DebugL') | Out-Null
            [pscustomobject]@{ Success = $true; LogFile = $null; RestoreSeconds = 1.5; CompileSeconds = 2.5 }
        }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeTests { [pscustomobject]@{ Success = $true; Skipped = $false; LogFile = $null; RestoreSeconds = 0.5; CompileSeconds = 1.0 } }
        # octo-ckc is there, and the remote caches are two hours old: a refresh is due
        $script:ckcCalls = 0
        Mock -ModuleName OctoCkCatalogRefresh Resolve-OctoCkc { 'fake-octo-ckc' }
        Mock -ModuleName OctoCkCatalogRefresh Invoke-OctoCkcRefresh { $script:ckcCalls++; [pscustomobject]@{ ExitCode = $script:ckcExit; Output = @('All catalog cache refreshed') } }
        $script:ckcExit = 0
        foreach ($file in Get-ChildItem $env:OCTO_CK_CACHE_DIRECTORY -Filter '*.json') { $file.LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2) }
        $script:localCache = Join-Path $envPath '.octo/local-catalog/cache/local-catalog-cache.json'
        function Get-Refresh([string]$repo) { @($script:builds | Where-Object Repo -eq $repo)[-1].Refresh }
    }
    AfterEach {
        foreach ($file in Get-ChildItem $env:OCTO_CK_CACHE_DIRECTORY -Filter '*.json') { $file.LastWriteTimeUtc = [DateTime]::UtcNow }
    }

    It 'reads them once before the first repository that uses a construction kit, then builds those repositories without a refresh' {
        Test-Path $localCache | Should -BeTrue
        $events = Join-Path $TestDrive 'events-k.jsonl'
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -verifyTests -EventsFile $events -Json)
        $doc.data.success | Should -BeTrue
        $script:ckcCalls | Should -Be 1
        $doc.data.catalogs.mode | Should -Be 'refreshed'
        $doc.data.catalogs.usable | Should -BeTrue
        $doc.data.catalogs.repo | Should -Be 'octo-asset-repo-services'
        # only the repositories that use a construction kit get the property
        Get-Refresh 'octo-construction-kit-engine' | Should -BeNullOrEmpty
        Get-Refresh 'octo-sdk' | Should -BeNullOrEmpty
        Get-Refresh 'octo-asset-repo-services' | Should -Be 'false'
        Get-Refresh 'octo-cli' | Should -Be 'false'
        Should -Invoke -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeTests -Times 2 -Exactly -ParameterFilter { $msbuildProperties['OctoRefreshRemoteCatalogs'] -eq 'false' }
        # the local catalog cache is rebuilt by the first compile
        Test-Path $localCache | Should -BeFalse
        # one catalogs phase, for the repository that triggered the read, before its build phase; timings on repoDone and in -Json
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object { $_.event -eq 'phase' -and $_.phase -eq 'catalogs' } | ForEach-Object repo) | Should -Be @('octo-asset-repo-services')
        @($records | Where-Object { $_.event -eq 'phase' -and $_.repo -eq 'octo-asset-repo-services' } | ForEach-Object phase | Select-Object -First 2) | Should -Be @('catalogs', 'build')
        $done = $records | Where-Object { $_.event -eq 'repoDone' -and $_.repo -eq 'octo-asset-repo-services' }
        $done.restoreSeconds | Should -Be 1.5
        $done.compileSeconds | Should -Be 2.5
        $done.testRestoreSeconds | Should -Be 0.5
        $done.catalogSeconds | Should -BeGreaterOrEqual 0
        $row = $doc.data.repositories | Where-Object repo -eq 'octo-cli'
        $row.restoreSeconds | Should -Be 1.5
        $row.compileSeconds | Should -Be 2.5
        $row.testRestoreSeconds | Should -Be 0.5
        $row.catalogSeconds | Should -Be 0

        # the property is not part of the stamp: nothing is built again
        $script:builds.Clear()
        $again = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -verifyTests -Json)
        $again.data.skippedCount | Should -Be 4
        $again.data.catalogs.mode | Should -Be 'notNeeded'
        $script:ckcCalls | Should -Be 1
    }

    It 'reads nothing while the caches are fresh; -refreshCatalogs and a failed read leave every compile refreshing itself' {
        foreach ($file in Get-ChildItem $env:OCTO_CK_CACHE_DIRECTORY -Filter '*.json') { $file.LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5) }
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -Json)
        $doc.data.catalogs.mode | Should -Be 'fresh'
        $script:ckcCalls | Should -Be 0
        Get-Refresh 'octo-cli' | Should -Be 'false'

        $script:builds.Clear()
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -buildUnchanged -refreshCatalogs -Json)
        $doc.data.catalogs.mode | Should -Be 'perCompile'
        Get-Refresh 'octo-cli' | Should -BeNullOrEmpty
        Get-Refresh 'octo-asset-repo-services' | Should -BeNullOrEmpty

        foreach ($file in Get-ChildItem $env:OCTO_CK_CACHE_DIRECTORY -Filter '*.json') { $file.LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2) }
        $script:ckcExit = 3
        $script:builds.Clear()
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -buildUnchanged -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.catalogs.mode | Should -Be 'failed'
        $doc.data.catalogs.usable | Should -BeFalse
        $script:ckcCalls | Should -Be 1                      # asked once, not once per repository
        Get-Refresh 'octo-asset-repo-services' | Should -BeNullOrEmpty
        Get-Refresh 'octo-cli' | Should -BeNullOrEmpty

        Mock -ModuleName OctoCkCatalogRefresh Resolve-OctoCkc { $null }
        (Get-Doc (Invoke-BuildEnvironment -env 'env-k' -buildUnchanged -Json)).data.catalogs.mode | Should -Be 'unavailable'
    }

    It 'a cache that was never written counts as due (first build on a machine); a local cache that cannot be deleted switches nothing off' {
        Remove-Item (Join-Path $env:OCTO_CK_CACHE_DIRECTORY 'private-github-catalog-cache.json')
        try {
            $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -Json)
            $doc.data.catalogs.mode | Should -Be 'refreshed'
            $script:ckcCalls | Should -Be 1
        }
        finally { Set-Content -Path (Join-Path $env:OCTO_CK_CACHE_DIRECTORY 'private-github-catalog-cache.json') -Value '{}' }

        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $localCache) | Out-Null
        Set-Content -Path $localCache -Value '{}'
        Mock -ModuleName OctoCkCatalogRefresh Remove-Item { }
        $script:builds.Clear()
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -buildUnchanged -Json)
        $doc.data.catalogs.usable | Should -BeFalse
        $doc.data.catalogs.detail | Should -Match 'cannot be deleted'
        Get-Refresh 'octo-cli' | Should -BeNullOrEmpty
    }

    It 'two runs that find the caches due at the same time: one reads, the other waits and reads nothing' {
        # Another run holds the lock and finishes its read (fresh cache files) a moment later.
        $directory = $env:OCTO_CK_CACHE_DIRECTORY
        $modules = Join-Path $PSScriptRoot '../modules'
        $ready = Join-Path $TestDrive "lock-held-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        $other = Start-ThreadJob -ArgumentList $modules, $directory, $ready -ScriptBlock {
            param($modules, $directory, $ready)
            Import-Module (Join-Path $modules 'OctoCkCatalogRefresh.psm1') -Force
            $lock = Enter-OctoCatalogRefreshLock -directory $directory
            Set-Content -Path $ready -Value 'held'
            Start-Sleep -Seconds 2
            foreach ($file in Get-ChildItem $directory -Filter '*.json') { $file.LastWriteTimeUtc = [DateTime]::UtcNow }
            $lock.Dispose()
        }
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Test-Path $ready | Should -BeTrue
        # This run finds the caches due, waits for the lock, and then finds them fresh.
        $read = Initialize-OctoRunCatalogs -laneRootPath $envPath
        Receive-Job $other -Wait -AutoRemoveJob | Out-Null
        $script:ckcCalls | Should -Be 0
        $read.usable | Should -BeTrue
        $read.mode | Should -Be 'fresh'
        $read.detail | Should -Match 'another build run read the remote catalogs'
        $read.seconds | Should -BeGreaterThan 1          # it waited for the other run
        # the lock is free again
        $again = Enter-OctoCatalogRefreshLock -directory $directory -timeoutSeconds 2
        $again | Should -Not -BeNullOrEmpty
        $again.Dispose()
    }

    It 'a parallel run reads them once in the parent and hands the property to the child builds' {
        $script:jobs = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Invoke-BuildRange Start-OctoRepoBuildJob {
            $script:jobs.Add([pscustomobject]@{ Repo = $entry.Name; Refresh = $msbuildProperties['OctoRefreshRemoteCatalogs']; CkcCalls = $script:ckcCalls })
            New-Item -ItemType Directory -Force -Path (Join-Path $entry.Path 'bin/DebugL') | Out-Null
            [pscustomobject]@{ Name = $entry.Name }
        }
        $events = Join-Path $TestDrive 'events-k-parallel.jsonl'
        Mock -ModuleName Invoke-BuildRange Get-OctoRepoBuildJobState {
            [pscustomobject]@{ Done = $true; Phase = 'build'; Build = [pscustomobject]@{ Success = $true; LogFile = $null }; Tests = $null; BuildSeconds = 4.0; TestSeconds = 0.0
                Timings = [ordered]@{ catalogSeconds = 0.0; restoreSeconds = 1.25; compileSeconds = 2.75; testRestoreSeconds = 0.0; testCompileSeconds = 0.0 } }
        }
        $doc = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -maxParallel 3 -EventsFile $events -Json)
        $doc.data.success | Should -BeTrue
        $script:ckcCalls | Should -Be 1
        # the read is its own phase and the build phase follows it (not the other way round)
        $records = @(Get-Content $events | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        @($records | Where-Object { $_.event -eq 'phase' -and $_.repo -eq 'octo-asset-repo-services' } | ForEach-Object phase | Select-Object -First 2) | Should -Be @('catalogs', 'build')
        @($records | Where-Object { $_.event -eq 'phase' -and $_.repo -eq 'octo-sdk' } | ForEach-Object phase | Select-Object -First 1) | Should -Be @('build')
        ($script:jobs | Where-Object Repo -eq 'octo-sdk').Refresh | Should -BeNullOrEmpty
        ($script:jobs | Where-Object Repo -eq 'octo-asset-repo-services').Refresh | Should -Be 'false'
        ($script:jobs | Where-Object Repo -eq 'octo-asset-repo-services').CkcCalls | Should -Be 1     # read before the child started
        ($script:jobs | Where-Object Repo -eq 'octo-cli').Refresh | Should -Be 'false'
        ($doc.data.repositories | Where-Object repo -eq 'octo-sdk').restoreSeconds | Should -Be 1.25
        ($doc.data.repositories | Where-Object repo -eq 'octo-sdk').compileSeconds | Should -Be 2.75
        # repositories that use a construction kit do not overlap
        $plan = Get-Doc (Invoke-BuildEnvironment -env 'env-k' -maxParallel 3 -DryRun -Json)
        @($plan.data.repositories | Where-Object usesCk | ForEach-Object repo) | Should -Be @('octo-asset-repo-services', 'octo-cli')
        $plan.data.refreshCatalogs | Should -BeFalse
    }

    It 'a caller''s own OctoRefreshRemoteCatalogs is never overridden, and decides for that repository' {
        Invoke-BuildRange -branch 'wt-env-k' -from octo-asset-repo-services -to octo-cli -msbuildPropertiesPerRepo @{ 'octo-asset-repo-services' = @{ OctoRefreshRemoteCatalogs = 'true' } } -Json | Out-Null
        Get-Refresh 'octo-asset-repo-services' | Should -Be 'true'
        Get-Refresh 'octo-cli' | Should -Be 'false'
        $script:ckcCalls | Should -Be 1
    }

    It 'OctoCkCatalogRefresh: which repositories use a construction kit, and the property helper' {
        Test-OctoRepoUsesCk -path (Join-Path $envPath 'octo-asset-repo-services') | Should -BeTrue
        Test-OctoRepoUsesCk -path (Join-Path $envPath 'octo-cli') | Should -BeTrue                      # construction-kits.yaml outside src/
        Test-OctoRepoUsesCk -path (Join-Path $envPath 'octo-sdk') | Should -BeFalse
        New-Item -ItemType Directory -Force -Path (Join-Path $envPath 'octo-sdk/src/Sdk.Common/bin/DebugL') | Out-Null
        Set-Content -Path (Join-Path $envPath 'octo-sdk/src/Sdk.Common/bin/DebugL/ckModel.yaml') -Value 'build output'
        Test-OctoRepoUsesCk -path (Join-Path $envPath 'octo-sdk') | Should -BeFalse                     # bin/ is never entered
        (Add-OctoCatalogProperty -properties @{ A = '1' })['OctoRefreshRemoteCatalogs'] | Should -Be 'false'
        (Add-OctoCatalogProperty -properties @{ octorefreshremotecatalogs = 'true' }).Count | Should -Be 1
        Get-OctoMsBuildPropertiesHash -properties (Add-OctoCatalogProperty -properties @{ A = '1' }) | Should -Not -Be (Get-OctoMsBuildPropertiesHash -properties @{ A = '1' })
    }
}

Describe 'A new environment''s package cache is filled from a local cache (AB#8831)' {
    BeforeAll {
        # A package cache as NuGet leaves it: <id>/<version>/ with the nupkg, its metadata and a file of the package.
        function New-CachedPackage([string]$cache, [string]$id, [string]$version, [string]$content = 'lib', [switch]$incomplete) {
            $folder = Join-Path $cache "$id/$version"
            New-Item -ItemType Directory -Force -Path (Join-Path $folder 'lib/net10.0') | Out-Null
            Set-Content -Path (Join-Path $folder "lib/net10.0/$id.dll") -Value $content -NoNewline
            Set-Content -Path (Join-Path $folder "$id.$version.nupkg") -Value "nupkg-$content" -NoNewline
            if (-not $incomplete) { Set-Content -Path (Join-Path $folder '.nupkg.metadata') -Value '{}' }
        }
    }
    BeforeEach {
        $script:ws = New-FakeWorkspace
        $script:source = Join-Path $ws.Main '.nuget-packages'
        New-CachedPackage $source 'newtonsoft.json' '13.0.3' 'json'
        New-CachedPackage $source 'newtonsoft.json' '12.0.1' 'json-old'
        New-CachedPackage $source 'questpdf' '2025.1.0' 'pdf'
        New-CachedPackage $source 'meshmakers.octo.sdk.common' '999.0.0' 'another lane''s local build'
        New-CachedPackage $source 'meshmakers.octo.sdk.common' '3.2.100' 'released'
        New-CachedPackage $source 'half.extracted' '1.0.0' 'x' -incomplete
    }

    It 'New-OctoEnvironment copies the third-party packages of the base lane cache, never a local build or a half-extracted package' {
        $doc = Get-Doc (New-OctoEnvironment -env 'env-seed' -repos octo-sdk -branchName 'feature/seed' -Json)
        $doc.data.success | Should -BeTrue
        $cache = Join-Path $ws.Root 'wt-env-seed/.nuget-packages'
        $doc.data.packageCache.source | Should -Be $source
        $doc.data.packageCache.packages | Should -Be 4
        $doc.data.packageCache.skippedLocalBuilds | Should -Be 1
        $doc.data.packageCache.skippedIncomplete | Should -Be 1
        $doc.data.packageCache.sizeBytes | Should -BeGreaterThan 0
        $doc.data.packageCache.seconds | Should -BeGreaterOrEqual 0
        $doc.data.packageCache.method | Should -BeIn @('clone', 'copy')
        @($doc.data.packageCache.errors).Count | Should -Be 0
        Get-Content (Join-Path $cache 'newtonsoft.json/13.0.3/lib/net10.0/newtonsoft.json.dll') -Raw | Should -Be 'json'
        Test-Path (Join-Path $cache 'newtonsoft.json/12.0.1/.nupkg.metadata') | Should -BeTrue
        Test-Path (Join-Path $cache 'questpdf/2025.1.0') | Should -BeTrue
        Test-Path (Join-Path $cache 'meshmakers.octo.sdk.common/3.2.100') | Should -BeTrue            # a released version is third-party
        Test-Path (Join-Path $cache 'meshmakers.octo.sdk.common/999.0.0') | Should -BeFalse           # the local build comes from the environment feed
        Test-Path (Join-Path $cache 'half.extracted') | Should -BeFalse

        # Two caches never share a file: a change in the environment does not reach the source (copy-on-write or a copy).
        Set-Content -Path (Join-Path $cache 'newtonsoft.json/13.0.3/lib/net10.0/newtonsoft.json.dll') -Value 'patched in the environment' -NoNewline
        Remove-Item (Join-Path $cache 'questpdf') -Recurse -Force
        Get-Content (Join-Path $source 'newtonsoft.json/13.0.3/lib/net10.0/newtonsoft.json.dll') -Raw | Should -Be 'json'
        Test-Path (Join-Path $source 'questpdf/2025.1.0/questpdf.2025.1.0.nupkg') | Should -BeTrue
        # ... and the base lane cache was only read
        @(Get-ChildItem $source -Directory).Count | Should -Be 4
    }

    It '-skipPackageCacheSeed leaves the cache empty; Initialize-OctoEnvironmentPackageCache fills and tops it up, -WhatIf copies nothing' {
        $doc = Get-Doc (New-OctoEnvironment -env 'env-later' -repos octo-sdk -branchName 'feature/later' -skipPackageCacheSeed -Json)
        $doc.data.packageCache | Should -BeNullOrEmpty
        $cache = Join-Path $ws.Root 'wt-env-later/.nuget-packages'
        @(Get-ChildItem $cache).Count | Should -Be 0

        $dry = Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-later' -WhatIf -Json)
        $dry.data.dryRun | Should -BeTrue
        $dry.data.packages | Should -Be 4
        @(Get-ChildItem $cache).Count | Should -Be 0

        $doc = Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-later' -Json)
        $doc.command | Should -Be 'Initialize-OctoEnvironmentPackageCache'
        $doc.data.success | Should -BeTrue
        $doc.data.packages | Should -Be 4
        # repeatable: what is there stays, a new package of the source is added, an own package is not replaced
        Set-Content -Path (Join-Path $cache 'questpdf/2025.1.0/lib/net10.0/questpdf.dll') -Value 'mine' -NoNewline
        New-CachedPackage $source 'serilog' '4.0.0' 'log'
        $again = Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-later' -Json)
        $again.data.packages | Should -Be 1
        $again.data.alreadyPresent | Should -Be 4
        Get-Content (Join-Path $cache 'questpdf/2025.1.0/lib/net10.0/questpdf.dll') -Raw | Should -Be 'mine'
        Test-Path (Join-Path $cache 'serilog/4.0.0/.nupkg.metadata') | Should -BeTrue

        # another source on request; an unknown environment and a missing source fail
        $other = Join-Path $TestDrive 'other-cache'
        New-CachedPackage $other 'polly' '8.0.0' 'p'
        (Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-later' -source $other -Json)).data.packages | Should -Be 1
        (Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'nope' -Json)).data.success | Should -BeFalse
        (Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-later' -source (Join-Path $TestDrive 'missing') -Json)).data.error | Should -Match 'does not exist'
    }

    It 'falls back to the user-level cache; where cloning is not available that full copy is only made on request' {
        Remove-Item $source -Recurse -Force
        $userLevel = Join-Path $TestDrive 'user-level-cache'
        New-CachedPackage $userLevel 'newtonsoft.json' '13.0.3' 'json'
        New-CachedPackage $userLevel 'meshmakers.common.shared' '999.0.0' 'local build'
        Mock -ModuleName OctoEnvironment Get-OctoGlobalPackageCachePath { Join-Path $TestDrive 'user-level-cache' }

        Mock -ModuleName OctoEnvironment Get-OctoPackageCopyMethod { 'copy' }
        $doc = Get-Doc (New-OctoEnvironment -env 'env-win' -repos octo-sdk -branchName 'feature/win' -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.packageCache.skipped | Should -Match 'only made on request: Initialize-OctoEnvironmentPackageCache -env env-win'
        @(Get-ChildItem (Join-Path $ws.Root 'wt-env-win/.nuget-packages')).Count | Should -Be 0
        $explicit = Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-win' -Json)
        $explicit.data.success | Should -BeTrue
        $explicit.data.method | Should -Be 'copy'
        $explicit.data.packages | Should -Be 1
        $explicit.data.skippedLocalBuilds | Should -Be 1

        Mock -ModuleName OctoEnvironment Get-OctoPackageCopyMethod { 'clone' }
        Mock -ModuleName OctoEnvironment Copy-OctoPackageFolderRaw { Copy-Item -LiteralPath $source -Destination $target -Recurse }
        $doc = Get-Doc (New-OctoEnvironment -env 'env-mac' -repos octo-sdk -branchName 'feature/mac' -Json)
        $doc.data.packageCache.method | Should -Be 'clone'
        $doc.data.packageCache.packages | Should -Be 1
        Test-Path (Join-Path $ws.Root 'wt-env-mac/.nuget-packages/newtonsoft.json/13.0.3') | Should -BeTrue
    }

    It 'a base lane cache with nothing to copy does not hide the user-level cache' {
        Remove-Item $source -Recurse -Force
        New-CachedPackage $source 'meshmakers.octo.sdk.common' '999.0.0' 'local build only'
        New-CachedPackage $source 'half.extracted' '1.0.0' 'x' -incomplete
        $userLevel = Join-Path $TestDrive 'user-level-fallback'
        New-CachedPackage $userLevel 'newtonsoft.json' '13.0.3' 'json'
        Mock -ModuleName OctoEnvironment Get-OctoGlobalPackageCachePath { Join-Path $TestDrive 'user-level-fallback' }
        Mock -ModuleName OctoEnvironment Get-OctoPackageCopyMethod { 'clone' }
        Mock -ModuleName OctoEnvironment Copy-OctoPackageFolderRaw { Copy-Item -LiteralPath $source -Destination $target -Recurse }
        $doc = Get-Doc (New-OctoEnvironment -env 'env-fb' -repos octo-sdk -branchName 'feature/fb' -Json)
        $doc.data.packageCache.source | Should -Be $userLevel
        $doc.data.packageCache.packages | Should -Be 1
    }

    It 'a copy that breaks off leaves no folder behind, so the next run copies the package completely' {
        New-OctoEnvironment -env 'env-part' -repos octo-sdk -branchName 'feature/part' -skipPackageCacheSeed -Json | Out-Null
        $cache = Join-Path $ws.Root 'wt-env-part/.nuget-packages'
        # the copy writes a part of the package, then fails
        Mock -ModuleName OctoEnvironment Copy-OctoPackageFolderRaw { New-Item -ItemType Directory -Force -Path $target | Out-Null; Set-Content -Path (Join-Path $target 'partial.txt') -Value 'half'; throw 'connection to the disk lost' }
        $doc = Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-part' -Json)
        $doc.data.success | Should -BeFalse
        @($doc.data.errors).Count | Should -BeGreaterThan 0
        @(Get-ChildItem $cache -Force).Count | Should -Be 0            # no package folder, no temporary folder

        Mock -ModuleName OctoEnvironment Copy-OctoPackageFolderRaw { Copy-Item -LiteralPath $source -Destination $target -Recurse }
        $doc = Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-part' -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.packages | Should -Be 4
        $doc.data.alreadyPresent | Should -Be 0
        Test-Path (Join-Path $cache 'questpdf/2025.1.0/.nupkg.metadata') | Should -BeTrue
    }

    It '-Json never waits for a confirmation' {
        New-OctoEnvironment -env 'env-cf' -repos octo-sdk -branchName 'feature/cf' -skipPackageCacheSeed -Json | Out-Null
        $doc = Get-Doc (Initialize-OctoEnvironmentPackageCache -env 'env-cf' -Confirm -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'does not prompt'
        @(Get-ChildItem (Join-Path $ws.Root 'wt-env-cf/.nuget-packages')).Count | Should -Be 0
    }

    It 'no local cache at all: the environment is created, the cache stays empty and the report says why' {
        Remove-Item $source -Recurse -Force
        $doc = Get-Doc (New-OctoEnvironment -env 'env-none' -repos octo-sdk -branchName 'feature/none' -Json)
        $doc.data.success | Should -BeTrue
        $doc.data.packageCache.skipped | Should -Match 'no local package cache'
    }

    It 'a copy that fails is reported and does not fail the creation' {
        Mock -ModuleName OctoEnvironment Copy-OctoPackageFolder { throw 'disk full' }
        $doc = Get-Doc (New-OctoEnvironment -env 'env-err' -repos octo-sdk -branchName 'feature/err' -Json)
        $doc.data.success | Should -BeTrue
        @($doc.data.packageCache.errors).Count | Should -BeGreaterThan 0
        ($doc.data.warnings -join ' ') | Should -Match 'filled with errors'
    }
}
