#Requires -Modules Pester
<#
    Pester tests for the base lane layouts of feature environments (OctoEnvironment.psm1, AB#9007):
      - lanes layout: <rootPath>/branches/main holds the repositories (the profile is loaded from the octo-tools next
        to the lanes);
      - flat layout: rootPath itself holds the repositories, nuget/ and .octo/ (e.g. ~/RiderProjects/meshmakers/main
        with the profile loaded from main/octo-tools); environments lie in <rootPath>/wt-<env>, next to the repositories.

    Everything runs in TestDrive (see OctoEnvironment.TestHelpers.ps1); no build runs and no process is started or stopped.

    Run:  Invoke-Pester ./tests/OctoEnvironment.Layouts.Tests.ps1
#>

BeforeAll { . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1') }

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'Base lane detection (Resolve-OctoEnvironmentDefaultBase)' {
    AfterEach { $env:OCTO_ENVIRONMENT_BASE = $null }

    It 'takes branches/main in the lanes layout' {
        New-FakeWorkspace | Out-Null
        InModuleScope OctoEnvironment { Resolve-OctoEnvironmentDefaultBase } | Should -Be 'branches/main'
    }

    It 'takes rootPath itself (.) in the flat layout' {
        New-FakeFlatWorkspace | Out-Null
        InModuleScope OctoEnvironment { Resolve-OctoEnvironmentDefaultBase } | Should -Be '.'
    }

    It 'takes rootPath when branches/main exists but holds no lane' {
        $ws = New-FakeFlatWorkspace
        New-Item -ItemType Directory -Force -Path (Join-Path $ws.Root 'branches/main') | Out-Null
        InModuleScope OctoEnvironment { Resolve-OctoEnvironmentDefaultBase } | Should -Be '.'
    }

    It 'recognises a flat lane by a repository checkout alone, but not by octo-tools alone' {
        $root = Join-Path $TestDrive 'markers'
        if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        $tools = Join-Path $root 'octo-tools'
        New-Item -ItemType Directory -Force -Path $tools | Out-Null
        Invoke-TestGit $tools init -q -b main | Out-Null
        $global:rootPath = $root
        { InModuleScope OctoEnvironment { Resolve-OctoEnvironmentDefaultBase } } | Should -Throw '*No base lane found*'
        $repo = Join-Path $root 'octo-sdk'
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        Invoke-TestGit $repo init -q -b main | Out-Null
        InModuleScope OctoEnvironment { Resolve-OctoEnvironmentDefaultBase } | Should -Be '.'
    }

    It 'fails with a setup hint when neither layout fits' {
        $root = Join-Path $TestDrive 'empty-root'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        $global:rootPath = $root
        $doc = Get-Doc (New-OctoEnvironment -env 'no-base' -repos octo-sdk -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'No base lane found'
        $doc.data.error | Should -Match 'branches/main'
        $doc.data.error | Should -Match '-base <lane>'
        $doc.data.error | Should -Match 'OCTO_ENVIRONMENT_BASE'
        Test-Path (Join-Path $root 'wt-no-base') | Should -BeFalse
    }

    It '$env:OCTO_ENVIRONMENT_BASE overrides the detection and is checked' {
        $ws = New-FakeWorkspace
        $env:OCTO_ENVIRONMENT_BASE = 'branches/other'
        { InModuleScope OctoEnvironment { Resolve-OctoEnvironmentDefaultBase } } | Should -Throw '*OCTO_ENVIRONMENT_BASE*holds no lane*'
        $env:OCTO_ENVIRONMENT_BASE = $ws.Main
        InModuleScope OctoEnvironment { Resolve-OctoEnvironmentDefaultBase } | Should -Be $ws.Main
        $doc = Get-Doc (New-OctoEnvironment -env 'by-setting' -repos octo-sdk -Json)
        $doc.data.success | Should -BeTrue
        (Get-Content (Join-Path $ws.Root 'wt-by-setting/.octo/environment.json') -Raw | ConvertFrom-Json).base | Should -Be 'branches/main'
    }

    It 'an explicit -base wins over the detection' {
        $ws = New-FakeWorkspace
        $doc = Get-Doc (New-OctoEnvironment -env 'explicit' -repos octo-sdk -base 'branches/none' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'Base lane .*branches/none does not exist'
        $doc.data.error | Should -Match 'Supported layouts'
        Test-Path (Join-Path $ws.Root 'wt-explicit') | Should -BeFalse
    }
}

Describe 'Feature environments in the flat layout' {
    BeforeEach { $script:ws = New-FakeFlatWorkspace }

    It 'creates the environment below rootPath with base ".", the base lane''s settings, feed and catalogs' {
        $doc = Get-Doc (New-OctoEnvironment -env ab9007-flat -repos construction-kit-engine -workItem 9007 -Json)
        $doc.data.success | Should -BeTrue

        $envPath = Join-Path $ws.Root 'wt-ab9007-flat'
        $manifest = Get-Content (Join-Path $envPath '.octo/environment.json') -Raw | ConvertFrom-Json
        $manifest.base | Should -Be '.'
        $manifest.repos[0].path | Should -Be (Join-Path $envPath 'octo-construction-kit-engine')
        $manifest.repos[0].baseCommit | Should -Be (Invoke-TestGit (Join-Path $ws.Main 'octo-construction-kit-engine') rev-parse HEAD)
        (Get-OctoLaneBuildSettings -laneRootPath $envPath).isolated | Should -BeTrue
        Get-Content (Join-Path $envPath 'Octo.User.props') -Raw | Should -Match ([regex]::Escape(((Join-Path $ws.Root 'Octo.User.props') -replace '\\', '/')))
        Find-OctoLaneRoot -path (Join-Path $envPath 'octo-construction-kit-engine/src') | Should -Be $envPath
        @(Get-ChildItem (Join-Path $envPath 'nuget') -Filter *.nupkg).Count | Should -Be 3
        Test-Path (Join-Path $envPath '.octo/local-catalog/ck-models/v3/catalog.json') | Should -BeTrue
        # the base lane is never written and its build order does not see the environment
        @(Get-ChildItem (Join-Path $ws.Main 'nuget')).Count | Should -Be 3
        @(Get-OctoBuildOrder -branchRootPath $ws.Main -excludeFrontend $false -excludeAdditional $false | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Name } }) -like 'wt-*' | Should -BeNullOrEmpty
    }

    It 'lists, plans a build of and removes the environment; the base lane''s repositories stay' {
        New-OctoEnvironment -env flat-life -repos octo-sdk -Json | Out-Null
        $envPath = Join-Path $ws.Root 'wt-flat-life'

        $list = Get-Doc (Get-OctoEnvironment -Json)
        @($list.data.environments.name) | Should -Be @('flat-life')   # the octo-tools checkout and the repositories are no environments

        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { throw 'no build in a dry run' }
        $plan = Get-Doc (Invoke-BuildEnvironment -env flat-life -DryRun -Json)
        $plan.command | Should -Be 'Invoke-BuildEnvironment'
        @($plan.data.repositories.repo) | Should -Be @('octo-sdk')
        $plan.data.branchRootPath | Should -Be $envPath
        $plan.data.synced | Should -BeFalse

        $affected = Get-Doc (Get-OctoAffectedRepos -env flat-life -Json)
        $affected.command | Should -Be 'Get-OctoAffectedRepos'
        "$($affected.data.error)" | Should -BeNullOrEmpty

        $removed = Get-Doc (Remove-OctoEnvironment -env flat-life -Json)
        $removed.data.success | Should -BeTrue
        Test-Path $envPath | Should -BeFalse
        Test-Path (Join-Path $ws.Main 'octo-sdk/.git') | Should -BeTrue
        @(Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree list).Count | Should -Be 1
    }

    It 'a missing base lane of an existing environment fails with the manifest value and the setup hint' {
        New-OctoEnvironment -env flat-gone -repos octo-sdk -Json | Out-Null
        $manifestPath = Join-Path $ws.Root 'wt-flat-gone/.octo/environment.json'
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        $manifest['base'] = 'branches/main'
        Set-Content -Path $manifestPath -Value (ConvertTo-Json $manifest -Depth 6)

        $doc = Get-Doc (Sync-OctoEnvironment -env flat-gone -Json)
        $doc.data.success | Should -BeFalse
        "$($doc.data.error)" | Should -Match "manifest base 'branches/main'"
        "$($doc.data.error)" | Should -Match 'Supported layouts'
    }

    It 'the base lane''s kill scope leaves wt-* out; the environment''s scope and -additionalRoots still match' {
        $envRepo = Join-Path $ws.Root 'wt-ab9007-flat/octo-sdk/bin/DebugL/net10.0'
        $laneWorktree = Join-Path $ws.Root 'wt-ab8947-syslock/octo-construction-kit-engine-mongodb/bin'
        $mainRepo = Join-Path $ws.Main 'octo-sdk/bin/DebugL/net10.0'
        InModuleScope Invoke-KillDotnet -Parameters @{ ws = $ws; envRepo = $envRepo; laneWorktree = $laneWorktree; mainRepo = $mainRepo } {
            $candidates = @(
                [pscustomobject]@{ Pid = 1; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $envRepo; Modules = @() },
                [pscustomobject]@{ Pid = 2; Name = 'dotnet'; Command = "dotnet $(Join-Path $envRepo 'Sdk.dll')"; Cwd = $null; Modules = @() },
                [pscustomobject]@{ Pid = 3; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $mainRepo; Modules = @() },
                [pscustomobject]@{ Pid = 4; Name = 'dotnet'; Command = 'dotnet Engine.dll'; Cwd = $laneWorktree; Modules = @() },
                [pscustomobject]@{ Pid = 5; Name = 'dotnet'; Command = 'dotnet x.dll'; Cwd = $null; Modules = @((Join-Path $envRepo 'Sdk.dll')) }
            )
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $ws.Main).pid | Should -Be @(3)
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath (Join-Path $ws.Root 'wt-ab9007-flat')).pid | Should -Be @(1, 2, 5)
            # a further root below wt-* (an in-place worktree) keeps matching
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath @($ws.Main, (Split-Path -Parent $laneWorktree))).pid | Should -Be @(3, 4)
        }
    }
}

Describe 'Feature environments in the lanes layout keep their behaviour' {
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'records base branches/main and creates the environment next to the lanes' {
        $doc = Get-Doc (New-OctoEnvironment -env lanes-env -repos octo-sdk -Json)
        $doc.data.success | Should -BeTrue
        (Get-Content (Join-Path $ws.Root 'wt-lanes-env/.octo/environment.json') -Raw | ConvertFrom-Json).base | Should -Be 'branches/main'
        Test-Path (Join-Path $ws.Main 'wt-lanes-env') | Should -BeFalse
    }

    It 'the main lane''s kill scope leaves its own wt-* folders out' {
        $nested = Join-Path $ws.Main 'wt-8625-octo-construction-kit-engine/bin'
        $mainRepo = Join-Path $ws.Main 'octo-sdk/bin'
        InModuleScope Invoke-KillDotnet -Parameters @{ ws = $ws; nested = $nested; mainRepo = $mainRepo } {
            $candidates = @(
                [pscustomobject]@{ Pid = 1; Name = 'dotnet'; Command = 'dotnet a.dll'; Cwd = $nested; Modules = @() },
                [pscustomobject]@{ Pid = 2; Name = 'dotnet'; Command = 'dotnet b.dll'; Cwd = $mainRepo; Modules = @() }
            )
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $ws.Main).pid | Should -Be @(2)
        }
    }
}

Describe 'Adopting a hand-made environment (flat layout)' {
    BeforeEach { $script:ws = New-FakeFlatWorkspace }

    It 'creates an empty environment and records a hand-made worktree in place; Remove only unregisters it' {
        # A hand-made environment: wt-<lane> with a worktree, its own nuget copy, no manifest.
        $handMade = Join-Path $ws.Root 'wt-ab9006-csharp-optargs'
        New-Item -ItemType Directory -Force -Path (Join-Path $handMade 'nuget') | Out-Null
        $worktree = Join-Path $handMade 'octo-sdk'
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree add -q -b 'gerald/AB#9006_csharp-optargs' $worktree | Out-Null
        Set-Content -Path (Join-Path $worktree 'work.txt') -Value 'in progress'

        # its own name is refused (wt-<name> exists without a manifest)
        (Get-Doc (New-OctoEnvironment -env ab9006-csharp-optargs -Json)).data.error | Should -Match 'no feature environment'

        $created = Get-Doc (New-OctoEnvironment -env ab9006-adopt -workItem 9006 -Json)
        $created.data.success | Should -BeTrue
        @($created.data.manifest.repos).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $ws.Root 'wt-ab9006-adopt/nuget') -Filter *.nupkg).Count | Should -Be 3

        $adopt = Get-Doc (Add-OctoEnvironmentRepo -env ab9006-adopt -path $worktree -inPlace -Json)
        $adopt.data.success | Should -BeTrue
        $manifest = Get-Content (Join-Path $ws.Root 'wt-ab9006-adopt/.octo/environment.json') -Raw | ConvertFrom-Json
        $manifest.repos[0].name | Should -Be 'octo-sdk'
        $manifest.repos[0].branch | Should -Be 'gerald/AB#9006_csharp-optargs'
        (Resolve-Path $manifest.repos[0].path).Path | Should -Be (Resolve-Path $worktree).Path

        $one = (Get-Doc (Get-OctoEnvironment -env ab9006-adopt -Json)).data
        $one.repos[0].dirty | Should -BeTrue

        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { throw 'no build in a dry run' }
        @((Get-Doc (Invoke-BuildEnvironment -env ab9006-adopt -DryRun -Json)).data.repositories.repo) | Should -Be @('octo-sdk')

        # the dirty in-place worktree does not block the removal and stays with its changes
        (Get-Doc (Remove-OctoEnvironment -env ab9006-adopt -Json)).data.success | Should -BeTrue
        Test-Path (Join-Path $ws.Root 'wt-ab9006-adopt') | Should -BeFalse
        Get-Content (Join-Path $worktree 'work.txt') | Should -Be 'in progress'
        Test-Path (Join-Path $handMade 'nuget') | Should -BeTrue
    }

    It '-addAffected without -repos is refused and creates nothing' {
        $doc = Get-Doc (New-OctoEnvironment -env empty-affected -addAffected -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match '-addAffected needs -repos'
        Test-Path (Join-Path $ws.Root 'wt-empty-affected') | Should -BeFalse
    }
}

Describe 'Review round 1 (AB#9007)' {
    BeforeEach { $script:ws = New-FakeFlatWorkspace }

    It 'New-OctoEnvironment refuses -branchName without -repos (an empty environment records no branch)' {
        $doc = Get-Doc (New-OctoEnvironment -env deferred-env -branchName 'feature/custom' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match '-branchName needs -repos'
        Test-Path (Join-Path $ws.Root 'wt-deferred-env') | Should -BeFalse
    }

    It 'Get-OctoProcessesUnderFolder keeps processes below <folder>/wt-* (only lane selection leaves them out)' {
        $folder = Join-Path $ws.Root 'octo-sdk'
        $nested = Join-Path $folder 'wt-fixture'
        InModuleScope Invoke-KillDotnet -Parameters @{ folder = $folder; nested = $nested } {
            $candidates = @([pscustomobject]@{ Pid = 7; Name = 'zsh'; Command = 'zsh'; Cwd = $nested; Modules = @() })
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $folder -includeNestedLanes).pid | Should -Be @(7)
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $folder).pid | Should -BeNullOrEmpty
            Mock Get-Process { [pscustomobject]@{ Id = 7; Name = 'zsh'; CommandLine = 'zsh' } }
            Mock Test-OctoKillDotnetWindows { $false }
            Mock Get-OctoProcessCwdRecords { @('p7', "n$nested") }
            @(Get-OctoProcessesUnderFolder -path $folder).pid | Should -Be @(7)
        }
    }
}

Describe 'Review round 2 (AB#9007)' {
    BeforeEach { $script:ws = New-FakeFlatWorkspace }

    It 'a process of a nested lane is excluded as a whole, also when it loads a module from the base lane' {
        $envRepo = Join-Path $ws.Root 'wt-ab9007-flat/octo-sdk/bin'
        $baseDll = Join-Path $ws.Main 'octo-sdk/runtimes/win-x64/native/sqlite.dll'
        $mainRepo = Join-Path $ws.Main 'octo-sdk/bin'
        InModuleScope Invoke-KillDotnet -Parameters @{ ws = $ws; envRepo = $envRepo; baseDll = $baseDll; mainRepo = $mainRepo } {
            $candidates = @(
                [pscustomobject]@{ Pid = 1; Name = 'dotnet'; Command = "dotnet $(Join-Path $envRepo 'Sdk.dll')"; Cwd = $null; Modules = @($baseDll) },
                [pscustomobject]@{ Pid = 2; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $envRepo; Modules = @($baseDll) },
                [pscustomobject]@{ Pid = 3; Name = 'dotnet'; Command = 'dotnet x.dll'; Cwd = $null; Modules = @($baseDll) },
                [pscustomobject]@{ Pid = 4; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $mainRepo; Modules = @() }
            )
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $ws.Main).pid | Should -Be @(3, 4)
            # an in-place worktree below wt-* passed as a further root still counts
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath @($ws.Main, (Split-Path -Parent $envRepo))).pid | Should -Be @(1, 2, 3, 4)
        }
    }
}
