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

    # Workspace: <ws>/octo-tools (where the profile lives), <ws>/branches/main (base lane), <ws>/envs (environments).
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
        return [pscustomobject]@{ Root = $ws; Main = $main; Envs = (Join-Path $ws 'envs') }
    }

    function Get-Doc([object[]]$output) { return (($output -join "`n") | ConvertFrom-Json) }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    $env:NUGET_PACKAGES = $script:PreviousNugetPackages
    if ($null -ne $script:PreviousRootPath) { $global:rootPath = $script:PreviousRootPath } else { Remove-Variable -Name rootPath -Scope Global -ErrorAction SilentlyContinue }
}

Describe 'New-OctoEnvironment' {
    BeforeEach { $script:ws = New-FakeWorkspace }

    It 'creates worktrees, an isolated Octo.User.props, the manifest and the seeded feed and catalogs' {
        $doc = Get-Doc (New-OctoEnvironment -env ab8625-enum-null -repos construction-kit-engine -workItem 8625 -owner 'agent-1' -Json)
        $doc.command | Should -Be 'New-OctoEnvironment'
        $doc.data.success | Should -BeTrue

        $envPath = Join-Path $ws.Envs 'ab8625-enum-null'
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
        (Invoke-TestGit (Join-Path $ws.Envs 'feat-x/octo-sdk') rev-parse --abbrev-ref HEAD) | Should -Be 'feature/existing'
        (Invoke-TestGit (Join-Path $ws.Envs 'feat-x/octo-construction-kit-engine') rev-parse --abbrev-ref HEAD) | Should -Be 'feature/existing'
    }

    It 'refuses an invalid name, an existing environment, an unknown repository and a missing base' {
        (Get-Doc (New-OctoEnvironment -env 'Bad_Name' -repos octo-sdk -Json)).data.error | Should -Match 'Invalid environment name'
        (Get-Doc (New-OctoEnvironment -env 'ok-env' -repos octo-nope -Json)).data.error | Should -Match 'not a git checkout'
        (Get-Doc (New-OctoEnvironment -env 'ok-env' -repos octo-sdk -base 'branches/none' -Json)).data.error | Should -Match 'does not exist'
        Test-Path (Join-Path $ws.Envs 'ok-env') | Should -BeFalse
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
        Test-Path (Join-Path $ws.Main 'envs') | Should -BeFalse
    }

    It '-WhatIf creates nothing' {
        $doc = Get-Doc (New-OctoEnvironment -env 'dry' -repos octo-sdk -WhatIf -Json)
        $doc.data.dryRun | Should -BeTrue
        Test-Path (Join-Path $ws.Envs 'dry') | Should -BeFalse
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

        Set-Content -Path (Join-Path $ws.Envs 'env-a/octo-sdk/new.txt') -Value 'x'
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
        $script:wt = Join-Path $ws.Envs 'env-r/octo-sdk'
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
        Test-Path (Join-Path $ws.Envs 'env-r') | Should -BeFalse
        @(Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') worktree list).Count | Should -Be 1
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') rev-parse --verify --quiet 'refs/heads/feature/r' | Should -Not -BeNullOrEmpty
    }

    It 'removes a clean environment without commits; ignored build output does not block it' {
        New-Item -ItemType Directory -Force -Path (Join-Path $wt 'bin/DebugL') | Out-Null
        Set-Content -Path (Join-Path $wt 'bin/DebugL/x.dll') -Value 'x'
        (Get-Doc (Remove-OctoEnvironment -env 'env-r' -Json)).data.success | Should -BeTrue
        Test-Path (Join-Path $ws.Envs 'env-r') | Should -BeFalse
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
        $script:envPath = Join-Path $ws.Envs 'env-s'
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
        New-Csproj (Join-Path $ws.Envs 'env-g/octo-construction-kit-engine') 'Extra' -packageId 'Meshmakers.Octo.Extra'
        New-Csproj (Join-Path $ws.Main 'octo-identity-services') 'UsesExtra' -references 'Meshmakers.Octo.Extra' -notPackable
        @((Get-Doc (Get-OctoAffectedRepos -env 'env-g' -Json)).data.affected.repo) | Should -Contain 'octo-identity-services'
    }
}

Describe 'Add-OctoEnvironmentRepo' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-c' -repos octo-construction-kit-engine -branchName 'feature/c' -Json | Out-Null
        $script:envPath = Join-Path $ws.Envs 'env-c'
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
        $script:envPath = Join-Path $ws.Envs 'env-b'
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
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
        Get-Content (Join-Path $ws.Envs 'env-other/nuget/Meshmakers.Octo.Sdk.Common.999.0.0.nupkg') -Raw | Should -Be 'sdk-v1'
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
        $envRepo = Join-Path $ws.Envs 'env-k/octo-sdk/bin/DebugL/net10.0'
        $mainRepo = Join-Path $ws.Main 'octo-sdk/bin/DebugL/net10.0'
        InModuleScope Invoke-KillDotnet -Parameters @{ ws = $ws; envRepo = $envRepo; mainRepo = $mainRepo } {
            $candidates = @(
                [pscustomobject]@{ Pid = 1; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $envRepo; Modules = @() },
                [pscustomobject]@{ Pid = 2; Name = 'dotnet'; Command = "dotnet $(Join-Path $envRepo 'Sdk.dll')"; Cwd = $null; Modules = @() },
                [pscustomobject]@{ Pid = 3; Name = 'dotnet'; Command = 'dotnet Sdk.dll'; Cwd = $mainRepo; Modules = @() }
            )
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath $ws.Main).pid | Should -Be @(3)
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath (Join-Path $ws.Envs 'env-k')).pid | Should -Be @(1, 2)
            @(Select-OctoLaneProcesses -candidates $candidates -branchRootPath (Join-Path $ws.Envs 'env')).pid | Should -BeNullOrEmpty
        }
    }

    It 'the CK sync of an environment without the engine uses the base lane''s octo-ckc' {
        New-OctoEnvironment -env 'env-ck' -repos octo-sdk -Json | Out-Null
        $envPath = Join-Path $ws.Envs 'env-ck'
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
