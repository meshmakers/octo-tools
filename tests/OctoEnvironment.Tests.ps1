#Requires -Modules Pester
<#
    Pester tests for feature environments (OctoEnvironment.psm1, AB#8700).

    Everything runs in TestDrive: a fake workspace with branches/main holding `git init` repositories (each with a
    bare "origin"), a fake nuget/ feed and fake catalogs. The developer's real lanes, ~/.nuget/packages and git config
    are never touched (GIT_CONFIG_GLOBAL points into TestDrive); no build runs (the build step of Invoke-BuildRange
    and its process detection are mocked) and no process is started or stopped.

    Run:  Invoke-Pester ./tests/OctoEnvironment.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Get-OctoLaneBuildSettings.psm1') -Force
    Import-Module (Join-Path $modules 'OctoBuildOrder.psm1') -Force
    Import-Module (Join-Path $modules 'Copy-NuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-KillDotnet.psm1') -Force
    Import-Module (Join-Path $modules 'Stop-Octo.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-Publish.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-BuildAll.psm1') -Force
    Import-Module (Join-Path $modules 'Sync-OctoCkIntermediateVersions.psm1') -Force
    Import-Module (Join-Path $modules 'OctoBuildStamp.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-BuildRange.psm1') -Force
    Import-Module (Join-Path $modules 'OctoEnvironment.psm1') -Force

    # Isolated git: no global/system config, fixed identity.
    $script:SavedEnv = @{}
    $gitEnv = @{
        GIT_CONFIG_GLOBAL   = (Join-Path $TestDrive 'gitconfig')
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_AUTHOR_NAME     = 'Pester'
        GIT_AUTHOR_EMAIL    = 'pester@example.invalid'
        GIT_COMMITTER_NAME  = 'Pester'
        GIT_COMMITTER_EMAIL = 'pester@example.invalid'
    }
    foreach ($name in $gitEnv.Keys) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $gitEnv[$name])
    }
    Set-Content -Path $gitEnv.GIT_CONFIG_GLOBAL -Value "[init]`n`tdefaultBranch = main`n[advice]`n`tdetachedHead = false"

    # The tests of this file mock the in-process build step (Invoke-OctoBuildRangeRepo). A parallel run builds in child
    # processes, where a mock does not reach: every Invoke-BuildEnvironment here is sequential unless a test asks for
    # more - those tests mock the job functions (Start-OctoRepoBuildJob / Get-OctoRepoBuildJobState) instead.
    $script:PreviousMaxParallelDefault = $global:PSDefaultParameterValues['Invoke-BuildEnvironment:maxParallel']
    $global:PSDefaultParameterValues['Invoke-BuildEnvironment:maxParallel'] = 1

    $script:PreviousRootPath = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $script:PreviousNugetPackages = $env:NUGET_PACKAGES
    $env:NUGET_PACKAGES = $null

    function Invoke-TestGit([string]$path) {
        $output = & git -C $path @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed in ${path}: $output" }
        return $output
    }

    function New-Csproj([string]$repo, [string]$project, [string]$packageId = '', [string[]]$references = @(), [switch]$notPackable) {
        $folder = Join-Path $repo "src/$project"
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $lines = @('<Project Sdk="Microsoft.NET.Sdk">', '  <PropertyGroup>')
        if ($packageId) { $lines += "    <PackageId>$packageId</PackageId>" }
        if ($notPackable) { $lines += '    <IsPackable>false</IsPackable>' }
        $lines += '  </PropertyGroup>', '  <ItemGroup>'
        foreach ($reference in $references) { $lines += "    <PackageReference Include=""$reference"" Version=""`$(OctoCoreLibVersion)"" />" }
        $lines += '    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />', '  </ItemGroup>', '</Project>'
        Set-Content -Path (Join-Path $folder "$project.csproj") -Value $lines
    }

    function New-FakeRepo([string]$lane, [string]$name, [scriptblock]$content) {
        $repo = Join-Path $lane $name
        New-Item -ItemType Directory -Force -Path $repo | Out-Null
        & $content $repo
        # a solution with the src/ projects, so Invoke-BuildRange plans a build
        $projects = @(Get-ChildItem -Path (Join-Path $repo 'src') -Recurse -Filter '*.csproj' | ForEach-Object { "  <Project Path=""src/$($_.Directory.Name)/$($_.Name)"" />" })
        Set-Content -Path (Join-Path $repo "$name.slnx") -Value (@('<Solution>') + $projects + @('</Solution>'))
        Set-Content -Path (Join-Path $repo '.gitignore') -Value "bin/`nobj/"
        Invoke-TestGit $repo init -q -b main | Out-Null
        Invoke-TestGit $repo add -A | Out-Null
        Invoke-TestGit $repo commit -q -m "initial $name" | Out-Null
        $origin = Join-Path $TestDrive "origins/$name.git"
        if (Test-Path $origin) { Remove-Item $origin -Recurse -Force }
        Invoke-TestGit $TestDrive init -q --bare $origin | Out-Null
        Invoke-TestGit $repo remote add origin $origin | Out-Null
        Invoke-TestGit $repo push -q -u origin main | Out-Null
        return $repo
    }

    function New-FakePackage([string]$folder, [string]$id, [string]$content) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $file = Join-Path $folder "$id.999.0.0.nupkg"
        Set-Content -Path $file -Value $content -NoNewline
        return $file
    }

    function New-FakeCatalogIndex([string]$path, [string[]]$models) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        $doc = [ordered]@{ version = '1.0'; updatedAt = '2026-01-01T00:00:00Z'; models = @($models | ForEach-Object { [ordered]@{ modelName = $_; catalogPath = "ck-models/v3/x/$_/catalog.json" } }) }
        Set-Content -Path $path -Value (ConvertTo-Json -InputObject $doc -Depth 5)
    }

    # Workspace: <ws>/branches/main (base lane), environments in <ws>/wt-<env> (octo-claude-pm lane folders).
    function New-FakeWorkspace {
        $ws = Join-Path $TestDrive 'ws'
        foreach ($folder in @($ws, (Join-Path $TestDrive 'origins'))) { if (Test-Path $folder) { Remove-Item $folder -Recurse -Force } }
        $main = Join-Path $ws 'branches/main'
        New-Item -ItemType Directory -Force -Path $main | Out-Null
        Set-Content -Path (Join-Path $main 'Octo.User.props') -Value '<Project><PropertyGroup><OctoSomething>1</OctoSomething></PropertyGroup></Project>'

        # Package chain: engine -> sdk -> asset-repo (service); identity consumes only mm-common; cli consumes sdk.
        New-FakeRepo $main 'mm-common' { param($r) New-Csproj $r 'Common.Shared' -packageId 'Meshmakers.Common.Shared' } | Out-Null
        New-FakeRepo $main 'octo-construction-kit-engine' { param($r)
            New-Csproj $r 'Runtime.Engine' -packageId 'Meshmakers.Octo.Runtime.Engine' -references 'Meshmakers.Common.Shared'
            New-Csproj $r 'Engine.Tests' -references 'Meshmakers.Octo.Runtime.Engine' -notPackable } | Out-Null
        New-FakeRepo $main 'octo-sdk' { param($r) New-Csproj $r 'Sdk.Common' -packageId 'Meshmakers.Octo.Sdk.Common' -references 'Meshmakers.Octo.Runtime.Engine' } | Out-Null
        New-FakeRepo $main 'octo-asset-repo-services' { param($r) New-Csproj $r 'AssetRepository' -references 'Meshmakers.Octo.Sdk.Common' -notPackable } | Out-Null
        New-FakeRepo $main 'octo-identity-services' { param($r) New-Csproj $r 'Identity' -references 'Meshmakers.Common.Shared' -notPackable } | Out-Null
        New-FakeRepo $main 'octo-cli' { param($r) New-Csproj $r 'ManagementTool' -references 'Meshmakers.Octo.Sdk.Common' -notPackable } | Out-Null

        New-FakePackage (Join-Path $main 'nuget') 'Meshmakers.Common.Shared' 'common-v1' | Out-Null
        New-FakePackage (Join-Path $main 'nuget') 'Meshmakers.Octo.Runtime.Engine' 'engine-v1' | Out-Null
        New-FakePackage (Join-Path $main 'nuget') 'Meshmakers.Octo.Sdk.Common' 'sdk-v1' | Out-Null
        New-FakeCatalogIndex (Join-Path $main '.octo/local-catalog/ck-models/v3/catalog.json') @('Basic', 'System')
        New-Item -ItemType Directory -Force -Path (Join-Path $main '.octo/local-catalog/cache') | Out-Null
        Set-Content -Path (Join-Path $main '.octo/local-catalog/cache/local-catalog-cache.json') -Value '{"models":{"Basic":{}}}'
        Set-Content -Path (Join-Path $main '.octo/local-catalog/ck-models/v3/.catalog-index.lock') -Value ''
        New-Item -ItemType Directory -Force -Path (Join-Path $main '.octo/local-blueprint-catalog/blueprints/v1/App/1.0.0') | Out-Null
        Set-Content -Path (Join-Path $main '.octo/local-blueprint-catalog/blueprints/v1/App/1.0.0/blueprint.yaml') -Value 'name: App'

        $global:rootPath = $ws
        return [pscustomobject]@{ Root = $ws; Main = $main }
    }

    function Get-Doc([object[]]$output) { return (($output -join "`n") | ConvertFrom-Json) }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    if ($null -ne $script:PreviousMaxParallelDefault) { $global:PSDefaultParameterValues['Invoke-BuildEnvironment:maxParallel'] = $script:PreviousMaxParallelDefault }
    else { $global:PSDefaultParameterValues.Remove('Invoke-BuildEnvironment:maxParallel') }
    $env:NUGET_PACKAGES = $script:PreviousNugetPackages
    if ($null -ne $script:PreviousRootPath) { $global:rootPath = $script:PreviousRootPath } else { Remove-Variable -Name rootPath -Scope Global -ErrorAction SilentlyContinue }
}

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
        { [DateTime]::Parse($manifest.created) } | Should -Not -Throw
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
