#Requires -Modules Pester
<#
    Pester tests for the shared build order (OctoBuildOrder.psm1), Invoke-BuildRange and the
    NuGet helpers it relies on. Everything runs against a fake checkout in TestDrive: no dotnet
    build is started, the real <checkout>/nuget folder and the real ~/.nuget/packages cache are
    never touched (the build step and process detection are mocked).

    Run:  Invoke-Pester ./tests
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Get-OctoLaneBuildSettings.psm1') -Force
    Import-Module (Join-Path $modules 'OctoBuildOrder.psm1') -Force
    Import-Module (Join-Path $modules 'Copy-NuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Copy-AllNuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-KillDotnet.psm1') -Force
    Import-Module (Join-Path $modules 'Remove-GlobalNuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-BuildAll.psm1') -Force
    Import-Module (Join-Path $modules 'Stop-Octo.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-BuildRange.psm1') -Force

    function New-FakeSln([string]$repoPath, [string]$name, [string[]]$projects) {
        $lines = @('Microsoft Visual Studio Solution File, Format Version 12.00')
        $lines += 'Project("{2150E333-8FDC-42A3-9474-1A3956D46DE8}") = "src", "src", "{827E0CD3-B72D-47B6-A68D-7590B98EB39B}"'
        $lines += 'EndProject'
        foreach ($project in $projects) {
            $projectName = [IO.Path]::GetFileNameWithoutExtension($project)
            $lines += "Project(""{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}"") = ""$projectName"", ""$project"", ""{$([guid]::NewGuid().ToString().ToUpper())}"""
            $lines += 'EndProject'
        }
        Set-Content -Path (Join-Path $repoPath "$name.sln") -Value $lines
    }

    function New-FakeSlnx([string]$repoPath, [string]$name, [string[]]$projects) {
        $xml = "<Solution>`n" + (($projects | ForEach-Object { "  <Project Path=""$_"" />" }) -join "`n") + "`n</Solution>"
        Set-Content -Path (Join-Path $repoPath "$name.slnx") -Value $xml
    }

    function New-FakePackage([string]$path, [string]$id, [DateTime]$time) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        $file = Join-Path $path "$id.999.0.0.nupkg"
        Set-Content -Path $file -Value $id
        (Get-Item $file).LastWriteTime = $time
        return $file
    }

    $script:Old = [DateTime]'2020-01-01'

    function Set-FakeCacheHash([string]$cache, [string]$id, [string]$nupkg) {
        $lower = $id.ToLowerInvariant()
        $stream = [IO.File]::OpenRead($nupkg)
        try { $hash = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData($stream)) } finally { $stream.Dispose() }
        Set-Content -Path (Join-Path $cache "$lower/999.0.0/$lower.999.0.0.nupkg.sha512") -Value $hash -NoNewline
    }

    function New-FakeCheckout {
        $root = Join-Path $TestDrive 'meshmakers'
        if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        $checkout = Join-Path $root 'main'
        $names = @(
            'mm-common', 'octo-distributedEventHub', 'octo-construction-kit-engine', 'octo-sdk',
            'octo-construction-kit-engine-mongodb', 'octo-common-services', 'octo-communication-sdk',
            'octo-mesh-adapter', 'octo-bot-services', 'octo-communication-controller-services',
            'octo-adapter-eda', 'octo-asset-repo-services', 'octo-cli', 'octo-frontend-libraries',
            'octo-helm-core', 'octo-identity-services', 'octo-plug-dilos', 'octo-adapter-weclapp'
        )
        foreach ($name in $names) {
            $repo = Join-Path $checkout $name
            New-Item -ItemType Directory -Force -Path $repo | Out-Null
            if ($name -in @('octo-helm-core')) { continue }  # no solution
            if ($name -eq 'octo-communication-sdk') {
                New-FakeSlnx $repo 'Comm' @('src/Sdk.Pipeline/Sdk.Pipeline.csproj', 'tests/Sdk.Pipeline.Tests/Sdk.Pipeline.Tests.csproj')
            }
            elseif ($name -eq 'octo-cli') {
                # no src/ folder in the solution -> falls back to the whole solution
                New-FakeSln $repo 'Cli' @('ManagementTool\ManagementTool.csproj', 'tests\Cli.Tests\Cli.Tests.csproj')
            }
            else {
                New-FakeSln $repo $name @("src\$name.Lib\$name.Lib.csproj", "src\$name.Web\$name.Web.csproj", "tests\$name.Tests\$name.Tests.csproj")
            }
        }
        # Previous build output (DebugL packages)
        New-FakePackage (Join-Path $checkout 'octo-construction-kit-engine/bin/DebugL') 'Meshmakers.Octo.Runtime.Engine' $script:Old | Out-Null
        New-FakePackage (Join-Path $checkout 'octo-construction-kit-engine/src/SystemCkModel/bin/DebugL') 'Meshmakers.Octo.ConstructionKit.Models.System' $script:Old | Out-Null
        New-FakePackage (Join-Path $checkout 'octo-sdk/src/Sdk.Common/bin/DebugL') 'Meshmakers.Octo.Sdk.Common' $script:Old | Out-Null
        # stale: project moved to octo-communication-sdk, nupkg is still lying around in octo-sdk
        New-FakePackage (Join-Path $checkout 'octo-sdk/src/Sdk.Common.Web/bin/DebugL') 'Meshmakers.Octo.Sdk.Common.Web' $script:Old | Out-Null
        New-FakePackage (Join-Path $checkout 'octo-communication-sdk/src/Sdk.Common.Web/bin/DebugL') 'Meshmakers.Octo.Sdk.Common.Web' $script:Old | Out-Null

        # <checkout>/nuget with an unrelated package that must survive
        New-FakePackage (Join-Path $checkout 'nuget') 'Meshmakers.Common.Shared' $script:Old | Out-Null

        # global packages cache
        $cache = Join-Path $TestDrive 'nuget-cache'
        if (Test-Path $cache) { Remove-Item $cache -Recurse -Force }
        foreach ($id in @('meshmakers.octo.runtime.engine', 'meshmakers.octo.constructionkit.models.system',
                'meshmakers.octo.sdk.common', 'meshmakers.octo.sdk.common.web', 'meshmakers.common.shared')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $cache "$id/999.0.0") | Out-Null
            New-Item -ItemType Directory -Force -Path (Join-Path $cache "$id/1.0.0") | Out-Null
        }

        # The cache copy of Common.Shared matches <checkout>/nuget (NuGet records the nupkg SHA-512).
        Set-FakeCacheHash $cache 'Meshmakers.Common.Shared' (Join-Path $checkout 'nuget/Meshmakers.Common.Shared.999.0.0.nupkg')

        # User-level NuGet.Config used by the lane isolation (Get-OctoLaneBuildSettings): its local feed is
        # another lane's nuget/ folder, so the fake 'main' checkout counts as an isolated lane unless a
        # test rewrites this file.
        $script:FakeNuGetConfig = Join-Path $TestDrive 'NuGet.Config'
        Set-Content -Path $script:FakeNuGetConfig -Value "<configuration><packageSources><add key=""local-nuget"" value=""$(Join-Path $root 'other-lane/nuget')"" /></packageSources></configuration>"

        $global:rootPath = $root
        $global:GLOBALNUGETPACKAGESPATH = $cache
        return [pscustomobject]@{ Root = $root; Checkout = $checkout; Cache = $cache }
    }

    # The tests point the profile globals at TestDrive; remember and restore them (they are real
    # values when the tests run inside a session that loaded profile.ps1).
    # Never read the developer's real ~/.nuget/NuGet/NuGet.Config from tests (a root BeforeAll mock
    # applies to every test of this file; New-FakeCheckout writes the file).
    $script:FakeNuGetConfig = Join-Path $TestDrive 'NuGet.Config'
    Mock -ModuleName Get-OctoLaneBuildSettings Get-OctoUserNuGetConfigPath { $script:FakeNuGetConfig }

    $script:PreviousNugetPackages = $env:NUGET_PACKAGES
    $script:PreviousRootPath = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $script:PreviousGlobalPackagesPath = Get-Variable -Name GLOBALNUGETPACKAGESPATH -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $script:PreviousLastExitCode = $global:LASTEXITCODE
    $env:NUGET_PACKAGES = $null
}

AfterAll {
    $env:NUGET_PACKAGES = $script:PreviousNugetPackages
    if ($null -ne $script:PreviousRootPath) { $global:rootPath = $script:PreviousRootPath } else { Remove-Variable -Name rootPath -Scope Global -ErrorAction SilentlyContinue }
    if ($null -ne $script:PreviousGlobalPackagesPath) { $global:GLOBALNUGETPACKAGESPATH = $script:PreviousGlobalPackagesPath } else { Remove-Variable -Name GLOBALNUGETPACKAGESPATH -Scope Global -ErrorAction SilentlyContinue }
    $global:LASTEXITCODE = $script:PreviousLastExitCode
    Get-ChildItem -Path (Join-Path ([IO.Path]::GetTempPath()) 'octo-buildrange') -Recurse -Filter 'pester-*.slnf' -ErrorAction SilentlyContinue | Remove-Item -Force
}

Describe 'Get-OctoBuildOrder' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'returns mm-* first, then the pinned repositories, then the rest alphabetically' {
        $order = @(Get-OctoBuildOrder -branchRootPath $fake.Checkout).Name
        $order | Should -Be @(
            'mm-common',
            'octo-distributedEventHub', 'octo-construction-kit-engine', 'octo-sdk',
            'octo-construction-kit-engine-mongodb', 'octo-common-services', 'octo-communication-sdk',
            'octo-mesh-adapter', 'octo-bot-services', 'octo-communication-controller-services',
            'octo-plug-dilos',
            'octo-adapter-eda', 'octo-adapter-weclapp', 'octo-asset-repo-services', 'octo-cli', 'octo-frontend-libraries',
            'octo-helm-core', 'octo-identity-services'
        )
    }

    It 'honours -excludeFrontend and -excludeAdditional' {
        @(Get-OctoBuildOrder -branchRootPath $fake.Checkout -excludeFrontend $true).Name | Should -Not -Contain 'octo-frontend-libraries'
        $core = @(Get-OctoBuildOrder -branchRootPath $fake.Checkout -excludeAdditional $true)
        $core.Name | Should -Not -Contain 'octo-asset-repo-services'
        $core[-1].Name | Should -Be 'octo-communication-controller-services'
        ($core | Where-Object Group -eq 'ordered').Count | Should -Be 9
        $core.Name | Should -Not -Contain 'octo-plug-dilos'
    }

    It 'exposes the pinned order' {
        (Get-OctoPinnedBuildOrder)[0] | Should -Be 'octo-distributedEventHub'
        (Get-OctoPinnedBuildOrder)[-1] | Should -Be 'octo-communication-controller-services'
    }
}

Describe 'Invoke-BuildAll uses the shared build order unchanged' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'compiles the repositories in the legacy order' {
        $script:compiled = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-BuildAll Compile-Repo { $script:compiled.Add((Split-Path -Leaf $path)); return $true }
        Mock -ModuleName Invoke-BuildAll Invoke-KillDotnet { }

        Invoke-BuildAll -branch main -configuration Release -excludeFrontend $true -Json | Out-Null

        $script:compiled | Should -Be @(
            'mm-common',
            'octo-distributedEventHub', 'octo-construction-kit-engine', 'octo-sdk',
            'octo-construction-kit-engine-mongodb', 'octo-common-services', 'octo-communication-sdk',
            'octo-mesh-adapter', 'octo-bot-services', 'octo-communication-controller-services',
            'octo-plug-dilos',
            'octo-adapter-eda', 'octo-adapter-weclapp', 'octo-asset-repo-services', 'octo-cli', 'octo-helm-core', 'octo-identity-services'
        )
    }

    It 'skips the additional repositories with -excludeAdditional' {
        $script:compiled = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-BuildAll Compile-Repo { $script:compiled.Add((Split-Path -Leaf $path)); return $true }
        Mock -ModuleName Invoke-BuildAll Invoke-KillDotnet { }

        Invoke-BuildAll -branch main -configuration Release -excludeAdditional $true -Json | Out-Null

        $script:compiled.Count | Should -Be 10
        $script:compiled[-1] | Should -Be 'octo-communication-controller-services'
    }
}

Describe 'Range selection' {
    BeforeEach {
        $script:fake = New-FakeCheckout
        $script:order = @(Get-OctoBuildOrder -branchRootPath $fake.Checkout -excludeFrontend $true)
    }

    It 'selects the inclusive slice between -from and -to' {
        InModuleScope Invoke-BuildRange -Parameters @{ order = $order } {
            (Get-OctoBuildRangeRepos -order $order -from 'octo-construction-kit-engine' -to 'octo-common-services').Name |
                Should -Be @('octo-construction-kit-engine', 'octo-sdk', 'octo-construction-kit-engine-mongodb', 'octo-common-services')
        }
    }

    It 'defaults -to to -from' {
        InModuleScope Invoke-BuildRange -Parameters @{ order = $order } {
            (Get-OctoBuildRangeRepos -order $order -from 'octo-sdk').Name | Should -Be @('octo-sdk')
        }
    }

    It 'accepts names without the octo- prefix and unique substrings' {
        InModuleScope Invoke-BuildRange -Parameters @{ order = $order } {
            (Get-OctoBuildRangeRepos -order $order -from 'construction-kit-engine' -to 'asset-repo')[-1].Name | Should -Be 'octo-asset-repo-services'
        }
    }

    It 'rejects ambiguous, unknown and reversed ranges' {
        InModuleScope Invoke-BuildRange -Parameters @{ order = $order } {
            { Get-OctoBuildRangeRepos -order $order -from 'engine' } | Should -Throw '*ambiguous*'
            { Get-OctoBuildRangeRepos -order $order -from 'does-not-exist' } | Should -Throw '*not part of the build order*'
            { Get-OctoBuildRangeRepos -order $order -from 'octo-common-services' -to 'octo-sdk' } | Should -Throw '*comes after*'
        }
    }

    It 'adds -include repositories at their build-order position and removes -exclude' {
        InModuleScope Invoke-BuildRange -Parameters @{ order = $order } {
            $repos = Get-OctoBuildRangeRepos -order $order -from 'octo-construction-kit-engine' -to 'octo-common-services' `
                -include 'octo-identity-services', 'octo-asset-repo-services' -exclude 'octo-sdk'
            $repos.Name | Should -Be @('octo-construction-kit-engine', 'octo-construction-kit-engine-mongodb', 'octo-common-services',
                'octo-asset-repo-services', 'octo-identity-services')
        }
    }
}

Describe 'Solution parsing and plan' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'reads .sln and .slnx project paths verbatim and filters src/' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $sln = Join-Path $fake.Checkout 'octo-sdk/octo-sdk.sln'
            $projects = Get-OctoSolutionProjects -solutionPath $sln
            $projects.Count | Should -Be 3
            Get-OctoSrcProjects -projects $projects | Should -Be @('src\octo-sdk.Lib\octo-sdk.Lib.csproj', 'src\octo-sdk.Web\octo-sdk.Web.csproj')

            $slnx = Join-Path $fake.Checkout 'octo-communication-sdk/Comm.slnx'
            Get-OctoSrcProjects -projects (Get-OctoSolutionProjects -solutionPath $slnx) | Should -Be @('src/Sdk.Pipeline/Sdk.Pipeline.csproj')
        }
    }

    It 'plans src-only builds, solution fallbacks, skips and the purge candidates' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $order = @(Get-OctoBuildOrder -branchRootPath $fake.Checkout -excludeFrontend $true)
            $repos = Get-OctoBuildRangeRepos -order $order -from 'octo-construction-kit-engine' -to 'octo-sdk' -include 'octo-cli', 'octo-helm-core'
            $plan = Get-OctoBuildRangePlan -repos $repos -globalPackagesPath $fake.Cache

            $engine = $plan | Where-Object Name -eq 'octo-construction-kit-engine'
            $engine.Target | Should -Be 'slnf'
            $engine.Projects | Should -Not -Match 'tests'
            $engine.PackageIds | Should -Be @('Meshmakers.Octo.ConstructionKit.Models.System', 'Meshmakers.Octo.Runtime.Engine')
            $engine.PurgePaths | Should -Contain (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0')

            ($plan | Where-Object Name -eq 'octo-cli').Target | Should -Be 'solution'
            ($plan | Where-Object Name -eq 'octo-helm-core').Mode | Should -Be 'none'

            $withTests = Get-OctoBuildRangePlan -repos $repos -globalPackagesPath $fake.Cache -includeTests
            ($withTests | Where-Object Name -eq 'octo-sdk').Projects.Count | Should -Be 3
        }
    }

    It 'flags candidates that are older than the repository''s last build' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            Set-Content (Join-Path $fake.Checkout 'octo-sdk/src/Sdk.Common/bin/DebugL/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') 'fresh'
            $repo = [pscustomobject]@{ Name = 'octo-sdk'; Path = (Join-Path $fake.Checkout 'octo-sdk'); Group = 'pinned' }
            $entry = Get-OctoBuildRangePlan -repos @($repo) -globalPackagesPath $fake.Cache
            $entry.OlderPaths | Should -Be @((Join-Path $fake.Cache 'meshmakers.octo.sdk.common.web/999.0.0'))
        }
    }

    It 'writes a solution filter that references the solution by absolute path' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $sln = Join-Path $fake.Checkout 'octo-sdk/octo-sdk.sln'
            $filter = New-OctoSolutionFilter -solutionPath $sln -projects @('src\a\a.csproj') -name 'pester-octo-sdk'
            try {
                $json = Get-Content $filter -Raw | ConvertFrom-Json
                $json.solution.path | Should -Be $sln
                @($json.solution.projects) | Should -Be @('src\a\a.csproj')
            }
            finally { Remove-Item $filter -Force }
        }
    }
}

Describe 'Invoke-BuildRange' {
    BeforeEach {
        $script:fake = New-FakeCheckout
        $script:built = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        # Fake build: engine and sdk "pack" fresh packages, like a real dotnet build would.
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:built.Add($entry.Name)
            if ($entry.Name -eq 'octo-construction-kit-engine') {
                Set-Content (Join-Path $entry.Path 'bin/DebugL/Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') 'fresh'
                Set-Content (Join-Path $entry.Path 'src/SystemCkModel/bin/DebugL/Meshmakers.Octo.ConstructionKit.Models.System.999.0.0.nupkg') 'fresh'
            }
            if ($entry.Name -eq 'octo-sdk') {
                Set-Content (Join-Path $entry.Path 'src/Sdk.Common/bin/DebugL/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') 'fresh'
            }
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
    }

    It '-WhatIf prints the plan and changes nothing' {
        $json = Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -WhatIf -Json | ConvertFrom-Json

        Should -Invoke -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo -Times 0
        $json.data.whatIf | Should -BeTrue
        $json.data.repositories.repo | Should -Be @('octo-construction-kit-engine', 'octo-sdk')
        $json.data.repositories[0].projects | Should -Not -Match 'tests'
        $json.data.repositories[0].purge | Should -Contain (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0')
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0') | Should -BeTrue
        @(Get-ChildItem (Join-Path $fake.Checkout 'nuget')).Count | Should -Be 1
    }

    It 'builds in order, copies and purges only what each repository produced' {
        $json = Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $script:built | Should -Be @('octo-construction-kit-engine', 'octo-sdk')

        $nuget = @(Get-ChildItem (Join-Path $fake.Checkout 'nuget')).Name | Sort-Object
        $nuget | Should -Be @(
            'Meshmakers.Common.Shared.999.0.0.nupkg',                       # untouched, not wiped
            'Meshmakers.Octo.ConstructionKit.Models.System.999.0.0.nupkg',
            'Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg',
            'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg'
        )                                                                     # stale Sdk.Common.Web NOT copied

        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0') | Should -BeFalse
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.constructionkit.models.system/999.0.0') | Should -BeFalse
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.sdk.common/999.0.0') | Should -BeFalse
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.sdk.common.web/999.0.0') | Should -BeTrue    # stale -> kept
        Test-Path (Join-Path $fake.Cache 'meshmakers.common.shared/999.0.0') | Should -BeTrue         # outside range
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/1.0.0') | Should -BeTrue     # other versions kept

        $sdk = $json.data.repositories | Where-Object repo -eq 'octo-sdk'
        $sdk.unchangedOrStale | Should -Contain 'Meshmakers.Octo.Sdk.Common.Web.999.0.0.nupkg'
        $json.data.repositories[0].PSObject.Properties.Name | Should -Contain 'buildSeconds'
    }

    It 'purges each repository right after its own copy, before the next repository builds' {
        $script:cacheStateWhenSdkBuilds = $null
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            if ($entry.Name -eq 'octo-construction-kit-engine') {
                Set-Content (Join-Path $entry.Path 'bin/DebugL/Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') 'fresh'
            }
            if ($entry.Name -eq 'octo-sdk') {
                $script:cacheStateWhenSdkBuilds = Test-Path (Join-Path $global:GLOBALNUGETPACKAGESPATH 'meshmakers.octo.runtime.engine/999.0.0')
            }
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }

        Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -Json | Out-Null

        $script:cacheStateWhenSdkBuilds | Should -BeFalse
    }

    It 'fails fast with the repository name and does not build the rest' {
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:built.Add($entry.Name)
            [pscustomobject]@{ Success = ($entry.Name -ne 'octo-sdk'); LogFile = $null }
        }

        $json = Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services -Json -ErrorVariable buildErrors -ErrorAction SilentlyContinue | ConvertFrom-Json

        $script:built | Should -Be @('octo-construction-kit-engine', 'octo-sdk')
        $json.data.success | Should -BeFalse
        $json.data.failedRepo | Should -Be 'octo-sdk'
        $json.data.notBuilt | Should -Be @('octo-construction-kit-engine-mongodb', 'octo-common-services')
        "$buildErrors" | Should -Match 'octo-sdk'
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'refuses to build while processes run out of a repository in the range' {
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses {
            @([pscustomobject]@{ Repo = 'octo-sdk'; Pid = 4711; Command = 'dotnet Meshmakers.Octo.Fake.dll' })
        }

        Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -ErrorVariable buildErrors -ErrorAction SilentlyContinue

        Should -Invoke -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo -Times 0
        "$buildErrors" | Should -Match 'octo-sdk \(pid 4711\)'
    }

    It 'builds anyway with -ignoreRunningServices' {
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses {
            @([pscustomobject]@{ Repo = 'octo-sdk'; Pid = 4711; Command = 'dotnet Meshmakers.Octo.Fake.dll' })
        }

        Invoke-BuildRange -branch main -from octo-sdk -ignoreRunningServices -Json | Out-Null

        Should -Invoke -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo -Times 1
    }

    It 'does not copy or purge for non-DebugL configurations' {
        Invoke-BuildRange -branch main -from octo-construction-kit-engine -configuration Release -Json | Out-Null

        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0') | Should -BeTrue
        @(Get-ChildItem (Join-Path $fake.Checkout 'nuget')).Count | Should -Be 1
    }
}

Describe 'Copy-NuGetPackages / Copy-AllNuGetPackages' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'Copy-NuGetPackages -modifiedSince copies only newer packages' {
        $since = (Get-Date).AddMinutes(-1)
        Set-Content (Join-Path $fake.Checkout 'octo-sdk/src/Sdk.Common/bin/DebugL/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') 'fresh'

        $json = Copy-NuGetPackages -directory (Join-Path $fake.Checkout 'octo-sdk') -branch main -modifiedSince $since -Json | ConvertFrom-Json

        @($json.data.files) | Should -Be @('Meshmakers.Octo.Sdk.Common.999.0.0.nupkg')
    }

    It 'Copy-NuGetPackages without -modifiedSince keeps copying everything' {
        $json = Copy-NuGetPackages -directory (Join-Path $fake.Checkout 'octo-sdk') -branch main -Json | ConvertFrom-Json
        $json.data.copiedCount | Should -Be 2
    }

    It 'Copy-AllNuGetPackages copies into the checkout nuget folder (was an undefined nugetPath variable)' {
        Copy-AllNuGetPackages -branch main -Json | Out-Null
        Test-Path (Join-Path $fake.Checkout 'nuget/Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') | Should -BeTrue
    }
}

Describe 'MSBuild property pass-through (-msbuildProperties)' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'converts properties to sorted, escaped -p arguments' {
        ConvertTo-OctoMsBuildPropertyArgs @{ OctoPublishCkModel = 'false'; A = 'x;y,z'; B = $true } |
            Should -Be @('-p:A=x%3By%2Cz', '-p:B=true', '-p:OctoPublishCkModel=false')
        ConvertTo-OctoMsBuildPropertyArgs @{} | Should -BeNullOrEmpty
        { ConvertTo-OctoMsBuildPropertyArgs @{ 'bad name' = 1 } } | Should -Throw '*Invalid MSBuild property name*'
    }

    It 'Invoke-Build passes them to restore and build' {
        Import-Module (Join-Path $PSScriptRoot '../modules/Invoke-Build.psm1') -Force
        $script:dotnetCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-Build dotnet { $script:dotnetCalls.Add($args -join ' '); $global:LASTEXITCODE = 0 }

        Invoke-Build -repositoryPath (Join-Path $fake.Checkout 'octo-sdk') -configuration DebugL -msbuildProperties @{ OctoPublishCkModel = 'false' } -Json | Out-Null

        $script:dotnetCalls.Count | Should -Be 2
        $script:dotnetCalls[0] | Should -Match '^restore .* -p:OctoPublishCkModel=false'
        $script:dotnetCalls[1] | Should -Match '^build .* -p:OctoPublishCkModel=false'
    }

    It 'Invoke-BuildAll hands them to every repository build' {
        Mock -ModuleName Invoke-BuildAll Compile-Repo { $true }
        Mock -ModuleName Invoke-BuildAll Invoke-KillDotnet { }

        Invoke-BuildAll -branch main -configuration Release -excludeAdditional $true -msbuildProperties @{ ContinuousIntegrationBuild = 'true' } -Json | Out-Null

        Should -Invoke -ModuleName Invoke-BuildAll Compile-Repo -Times 10 -Exactly -ParameterFilter { $msbuildProperties.ContinuousIntegrationBuild -eq 'true' }
    }

    It 'Invoke-BuildAll rejects invalid property names before doing anything' {
        Mock -ModuleName Invoke-BuildAll Compile-Repo { $true }
        Mock -ModuleName Invoke-BuildAll Invoke-KillDotnet { }

        # Invoke-BuildAll is a simple function (no common parameters) - capture the error stream.
        $buildErrors = Invoke-BuildAll -branch main -configuration DebugL -msbuildProperties @{ 'no good' = 1 } 2>&1

        Should -Invoke -ModuleName Invoke-BuildAll Compile-Repo -Times 0
        Should -Invoke -ModuleName Invoke-BuildAll Invoke-KillDotnet -Times 0
        "$buildErrors" | Should -Match 'Invalid MSBuild property name'
    }

    It 'Invoke-BuildRange hands them to every repository build and lists them in -WhatIf' {
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { [pscustomobject]@{ Success = $true; LogFile = $null } }

        $plan = Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -msbuildProperties @{ ContinuousIntegrationBuild = 'true' } -WhatIf -Json | ConvertFrom-Json
        @($plan.data.msbuildProperties) | Should -Be @('-p:ContinuousIntegrationBuild=true')
        @($plan.data.repositories[0].msbuildProperties) | Should -Be @('-p:ContinuousIntegrationBuild=true')

        Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -msbuildProperties @{ ContinuousIntegrationBuild = 'true' } -Json | Out-Null
        Should -Invoke -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo -Times 2 -Exactly -ParameterFilter { $msbuildProperties.ContinuousIntegrationBuild -eq 'true' }
    }

    It 'the range build step puts them on the dotnet build command line' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $script:dotnetArgs = $null
            Mock dotnet { $script:dotnetArgs = $args -join ' '; $global:LASTEXITCODE = 0 }
            $repo = [pscustomobject]@{ Name = 'pester-octo-sdk'; Path = (Join-Path $fake.Checkout 'octo-sdk'); Group = 'pinned' }
            $entry = (Get-OctoBuildRangePlan -repos @($repo) -globalPackagesPath $fake.Cache)[0]

            $result = Invoke-OctoBuildRangeRepo -entry $entry -configuration DebugL -msbuildProperties @{ OctoPublishCkModel = 'false' } -Json

            $result.Success | Should -BeTrue
            $script:dotnetArgs | Should -Match '^build .*\.slnf -c DebugL -nodeReuse:\s?false -p:OctoPublishCkModel=false'
        }
    }
}

Describe 'Stale global-cache packages (other checkout)' {
    BeforeEach {
        $script:fake = New-FakeCheckout
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { [pscustomobject]@{ Success = $true; LogFile = $null } }
        # nuget/ has a Runtime.Engine package; the cache holds a different build of it (e.g. from dev).
        $script:local = New-FakePackage (Join-Path $fake.Checkout 'nuget') 'Meshmakers.Octo.Runtime.Engine' $script:Old
        Set-Content -Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0/meshmakers.octo.runtime.engine.999.0.0.nupkg.sha512') -Value 'b3RoZXItY2hlY2tvdXQ=' -NoNewline
        # Sdk.Common is in nuget/ but its cache folder has no hash file -> cannot be verified.
        New-FakePackage (Join-Path $fake.Checkout 'nuget') 'Meshmakers.Octo.Sdk.Common' $script:Old | Out-Null
    }

    It 'detects hash mismatches and unverifiable folders, ignores matching ones' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $stale = @(Get-OctoStaleGlobalPackages -nugetPath (Join-Path $fake.Checkout 'nuget') -globalPackagesPath $fake.Cache)
            ($stale | Where-Object PackageId -eq 'meshmakers.octo.runtime.engine').Reason | Should -Be 'hashMismatch'
            ($stale | Where-Object PackageId -eq 'meshmakers.octo.sdk.common').Reason | Should -Be 'noHashFile'
            $stale.PackageId | Should -Not -Contain 'meshmakers.common.shared'
        }
    }

    It 'reports them under -WhatIf without purging' {
        $plan = Invoke-BuildRange -branch main -from octo-asset-repo-services -WhatIf -Json | ConvertFrom-Json
        $plan.data.staleGlobalCache.packageId | Should -Contain 'meshmakers.octo.runtime.engine'
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0') | Should -BeTrue
    }

    It 'only warns without -purgeStaleCache' {
        $result = Invoke-BuildRange -branch main -from octo-asset-repo-services -Json | ConvertFrom-Json
        $result.data.success | Should -BeTrue
        @($result.data.staleGlobalCachePurged).Count | Should -Be 0
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/999.0.0') | Should -BeTrue
    }

    It 'purges them before the first build with -purgeStaleCache' {
        $script:existedAtBuild = $null
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:existedAtBuild = Test-Path (Join-Path $global:GLOBALNUGETPACKAGESPATH 'meshmakers.octo.runtime.engine/999.0.0')
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }

        $result = Invoke-BuildRange -branch main -from octo-asset-repo-services -purgeStaleCache -Json | ConvertFrom-Json

        $script:existedAtBuild | Should -BeFalse
        @($result.data.staleGlobalCachePurged).Count | Should -Be 2
        Test-Path (Join-Path $fake.Cache 'meshmakers.octo.runtime.engine/1.0.0') | Should -BeTrue
        Test-Path (Join-Path $fake.Cache 'meshmakers.common.shared/999.0.0') | Should -BeTrue
    }
}

Describe 'Invoke-BuildRange early exits' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'emits success=false JSON and LASTEXITCODE 1 for an unknown repository' {
        $global:LASTEXITCODE = 0
        $json = Invoke-BuildRange -branch main -from does-not-exist -Json -ErrorAction SilentlyContinue -ErrorVariable buildErrors | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.error | Should -Match 'not part of the build order'
        $global:LASTEXITCODE | Should -Be 1
        "$buildErrors" | Should -Match 'does-not-exist'
    }

    It 'emits success=false JSON when services are running' {
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @([pscustomobject]@{ Repo = 'octo-sdk'; Pid = 1; Command = 'x' }) }
        $json = Invoke-BuildRange -branch main -from octo-sdk -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'writes solution filters into a checkout-specific folder' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $a = New-OctoSolutionFilter -solutionPath (Join-Path $fake.Checkout 'octo-sdk/octo-sdk.sln') -projects @('src\a.csproj') -name 'pester-octo-sdk'
            $otherCheckout = Join-Path $fake.Root 'dev'
            $b = New-OctoSolutionFilter -solutionPath (Join-Path $otherCheckout 'octo-sdk/octo-sdk.sln') -projects @('src\a.csproj') -name 'pester-octo-sdk'
            try { (Split-Path -Parent $a) | Should -Not -Be (Split-Path -Parent $b) }
            finally { Remove-Item $a, $b -Force }
        }
    }
}

Describe 'Copy-AllNuGetPackages with duplicate packages (H7)' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'copies the newest file per package regardless of repository order and reports duplicates' {
        # octo-communication-sdk sorts BEFORE octo-sdk; the stale octo-sdk copy must not win.
        $fresh = Join-Path $fake.Checkout 'octo-communication-sdk/src/Sdk.Common.Web/bin/DebugL/Meshmakers.Octo.Sdk.Common.Web.999.0.0.nupkg'
        Set-Content $fresh 'fresh-from-communication-sdk'
        (Get-Item $fresh).LastWriteTime = [DateTime]'2026-10-07'
        $stale = Join-Path $fake.Checkout 'octo-sdk/src/Sdk.Common.Web/bin/DebugL/Meshmakers.Octo.Sdk.Common.Web.999.0.0.nupkg'
        (Get-Item $stale).LastWriteTime = [DateTime]'2026-06-11'

        $json = Copy-AllNuGetPackages -branch main -Json | ConvertFrom-Json

        Get-Content (Join-Path $fake.Checkout 'nuget/Meshmakers.Octo.Sdk.Common.Web.999.0.0.nupkg') | Should -Be 'fresh-from-communication-sdk'
        $duplicate = $json.data.duplicates | Where-Object package -eq 'Meshmakers.Octo.Sdk.Common.Web.999.0.0.nupkg'
        $duplicate.used | Should -Be $fresh
        @($duplicate.ignored) | Should -Be @($stale)
    }

    It 'warns about duplicates in the human output' {
        $warnings = Copy-AllNuGetPackages -branch main 3>&1 6>$null
        "$warnings" | Should -Match 'Sdk.Common.Web.999.0.0.nupkg is produced by several repositories'
    }

    It 'keeps a newer package that is already in nuget/' {
        $existing = New-FakePackage (Join-Path $fake.Checkout 'nuget') 'Meshmakers.Octo.Sdk.Common' ([DateTime]'2030-01-01')
        Set-Content $existing 'newer-in-nuget'
        (Get-Item $existing).LastWriteTime = [DateTime]'2030-01-01'

        $json = Copy-AllNuGetPackages -branch main -Json | ConvertFrom-Json

        Get-Content $existing | Should -Be 'newer-in-nuget'
        @($json.data.skippedOlder) | Should -HaveCount 1
    }
}

Describe 'Running-process detection' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'matches Start-Octo services by working directory and bin tools by command line, ignores shells and MSBuild' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $repos = @(
                [pscustomobject]@{ Name = 'octo-asset-repo-services'; Path = (Join-Path $fake.Checkout 'octo-asset-repo-services') }
                [pscustomobject]@{ Name = 'octo-construction-kit-engine'; Path = (Join-Path $fake.Checkout 'octo-construction-kit-engine') }
                [pscustomobject]@{ Name = 'octo-common-services'; Path = (Join-Path $fake.Checkout 'octo-common-services') }
            )
            $asset = Join-Path $fake.Checkout 'octo-asset-repo-services'
            $engine = Join-Path $fake.Checkout 'octo-construction-kit-engine'
            $common = Join-Path $fake.Checkout 'octo-common-services'
            $all = @(
                [pscustomobject]@{ Pid = 10; Command = '/usr/libexec/dotnet Meshmakers.Octo.Backend.AssetRepositoryServices.dll --urls=x'; Cwd = $null }
                [pscustomobject]@{ Pid = 11; Command = "/usr/libexec/dotnet $engine/bin/DebugL/net10.0/publish/octo-ckc.dll -c publish"; Cwd = $null }
                [pscustomobject]@{ Pid = 12; Command = "/opt/homebrew/bin/pwsh -s -NoLogo -NoProfile -wd $common"; Cwd = $common }
                [pscustomobject]@{ Pid = 13; Command = "/usr/libexec/dotnet /sdk/MSBuild.dll -nodemode:1 $engine/bin/x"; Cwd = $engine }
                [pscustomobject]@{ Pid = 14; Command = '/usr/libexec/dotnet Meshmakers.Octo.Backend.IdentityServices.dll'; Cwd = $null }
                [pscustomobject]@{ Pid = 99; Command = "/usr/libexec/dotnet Meshmakers.Self.dll"; Cwd = $null }
            )
            $candidates = @(Select-OctoRepoProcessCandidates -candidates $all -repos $repos -ownPid 99)
            $candidates.Pid | Should -Be @(10, 11, 14)

            # cwd as lsof reports it
            ($candidates | Where-Object Pid -eq 10).Cwd = "$asset/bin/DebugL/net10.0"
            ($candidates | Where-Object Pid -eq 14).Cwd = (Join-Path $fake.Root 'dev/octo-identity-services/bin/DebugL/net10.0')

            $found = @(Select-OctoRepoProcesses -candidates $candidates -repos $repos)
            $found | ForEach-Object { "$($_.Repo):$($_.Pid)" } | Should -Be @('octo-asset-repo-services:10', 'octo-construction-kit-engine:11')
        }
    }
}

Describe 'Stale-cache check with empty hash files (N10)' {
    BeforeEach { $script:fake = New-FakeCheckout }

    It 'treats an empty .sha512 file as noHashFile and never reuses the previous package hash' {
        InModuleScope Invoke-BuildRange -Parameters @{ fake = $fake } {
            $nuget = Join-Path $fake.Checkout 'nuget'
            # A sorts before B: A has a real (mismatching) hash, B an empty hash file.
            $a = New-Item -ItemType File -Force -Path (Join-Path $nuget 'Meshmakers.A.999.0.0.nupkg') -Value 'a'
            $b = New-Item -ItemType File -Force -Path (Join-Path $nuget 'Meshmakers.B.999.0.0.nupkg') -Value 'b'
            New-Item -ItemType Directory -Force -Path (Join-Path $fake.Cache 'meshmakers.a/999.0.0'), (Join-Path $fake.Cache 'meshmakers.b/999.0.0') | Out-Null
            Set-Content -Path (Join-Path $fake.Cache 'meshmakers.a/999.0.0/meshmakers.a.999.0.0.nupkg.sha512') -Value 'bWlzbWF0Y2g=' -NoNewline
            New-Item -ItemType File -Force -Path (Join-Path $fake.Cache 'meshmakers.b/999.0.0/meshmakers.b.999.0.0.nupkg.sha512') | Out-Null

            $stale = @(Get-OctoStaleGlobalPackages -nugetPath $nuget -globalPackagesPath $fake.Cache -ErrorAction Stop)

            ($stale | Where-Object PackageId -eq 'meshmakers.a').Reason | Should -Be 'hashMismatch'
            ($stale | Where-Object PackageId -eq 'meshmakers.b').Reason | Should -Be 'noHashFile'
            $stale.PackageId | Should -Not -Contain 'meshmakers.common.shared'
        }
    }
}

Describe 'Per-repository MSBuild properties (N11)' {
    BeforeEach {
        $script:fake = New-FakeCheckout
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        $script:buildProps = @{}
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:buildProps[$entry.Name] = @(ConvertTo-OctoMsBuildPropertyArgs -properties $msbuildProperties)
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
    }

    It 'merges run-wide and per-repository properties, the repository entry wins' {
        $merged = Merge-OctoRepoMsBuildProperties -repoName 'octo-identity-services' -msbuildProperties @{ A = '1'; OctoPublishCkModel = 'true' } `
            -msbuildPropertiesPerRepo @{ 'OCTO-IDENTITY-SERVICES' = @{ OctoPublishCkModel = 'false' }; 'octo-sdk' = @{ B = '2' } }
        $merged.A | Should -Be '1'
        $merged.OctoPublishCkModel | Should -Be 'false'
        $merged.ContainsKey('B') | Should -BeFalse
        Test-OctoCkPublishDisabled -properties $merged | Should -BeTrue
        Test-OctoCkPublishDisabled -properties @{ OctoPublishCkModel = $false } | Should -BeTrue
        Test-OctoCkPublishDisabled -properties @{ OctoPublishCkModel = 'true' } | Should -BeFalse
    }

    It 'Invoke-BuildRange applies a per-repository entry only to that repository (short names allowed)' {
        $json = Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -include octo-identity-services `
            -msbuildPropertiesPerRepo @{ 'identity-services' = @{ OctoPublishCkModel = 'false' } } -Json -WarningVariable warnings | ConvertFrom-Json

        $script:buildProps['octo-identity-services'] | Should -Be @('-p:OctoPublishCkModel=false')
        $script:buildProps['octo-construction-kit-engine'] | Should -BeNullOrEmpty
        $script:buildProps['octo-sdk'] | Should -BeNullOrEmpty
        @(($json.data.repositories | Where-Object repo -eq 'octo-identity-services').msbuildProperties) | Should -Be @('-p:OctoPublishCkModel=false')
        $warnings | Should -BeNullOrEmpty
    }

    It 'Invoke-BuildRange warns when OctoPublishCkModel=false hits more than one repository' {
        Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -msbuildProperties @{ OctoPublishCkModel = 'false' } -WhatIf -Json -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        "$warnings" | Should -Match 'OctoPublishCkModel=false applies to 2 repositories'
    }

    It 'Invoke-BuildRange rejects unknown repositories and non-hashtable values' {
        Invoke-BuildRange -branch main -from octo-sdk -msbuildPropertiesPerRepo @{ 'no-such-repo' = @{ A = '1' } } -Json -ErrorAction SilentlyContinue |
            ConvertFrom-Json | ForEach-Object { $_.data.success | Should -BeFalse }
        $json = Invoke-BuildRange -branch main -from octo-sdk -msbuildPropertiesPerRepo @{ 'octo-sdk' = 'OctoPublishCkModel=false' } -Json -ErrorAction SilentlyContinue | ConvertFrom-Json
        $json.data.error | Should -Match 'must be a hashtable'
        Should -Invoke -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo -Times 0
    }

    It 'Invoke-BuildAll applies per-repository properties and validates keys before doing anything' {
        $script:allProps = @{}
        Mock -ModuleName Invoke-BuildAll Compile-Repo { $script:allProps[(Split-Path -Leaf $path)] = $msbuildProperties; $true }
        Mock -ModuleName Invoke-BuildAll Invoke-KillDotnet { }

        Invoke-BuildAll -branch main -configuration Release -msbuildPropertiesPerRepo @{ 'octo-identity-services' = @{ OctoPublishCkModel = 'false' } } -Json | Out-Null
        $script:allProps['octo-identity-services'].OctoPublishCkModel | Should -Be 'false'
        $script:allProps['octo-construction-kit-engine'].Count | Should -Be 0

        $errors = Invoke-BuildAll -branch main -configuration DebugL -msbuildPropertiesPerRepo @{ 'nope' = @{ A = '1' } } 2>&1
        "$errors" | Should -Match "'nope' is not a repository"
        Should -Invoke -ModuleName Invoke-BuildAll Invoke-KillDotnet -Times 1 -Exactly   # only from the first (valid) call
    }

    It 'Invoke-BuildAll warns when a run-wide OctoPublishCkModel=false hits more than one repository' {
        Mock -ModuleName Invoke-BuildAll Compile-Repo { $true }
        Mock -ModuleName Invoke-BuildAll Invoke-KillDotnet { }
        $warnings = Invoke-BuildAll -branch main -configuration Release -excludeAdditional $true -msbuildProperties @{ OctoPublishCkModel = 'false' } -Json 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        "$warnings" | Should -Match 'OctoPublishCkModel=false applies to 10 repositories'
    }
}
