#Requires -Modules Pester
<#
    Pester tests for Test-OctoBuildChain (modules/Test-OctoBuildChain.psm1, AB#6350): the read-only build doctor.

    Every test runs against a fake lane in TestDrive (small real git repositories, a fake <lane>/nuget feed and a fake
    package cache); the real checkout, the real nuget feed and ~/.nuget/packages are never touched - every call passes
    -LaneRoot and -GlobalPackagesPath. Build logs are the static fixtures tests/fixtures/buildchain/*.buildlog.

    Run:  Invoke-Pester ./tests/BuildChain.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    foreach ($name in 'OctoJsonOutput', 'Get-OctoLaneBuildSettings', 'OctoBuildOrder', 'Invoke-BuildRange', 'Test-OctoBuildChain') {
        Import-Module (Join-Path $modules "$name.psm1") -Force
    }
    $script:ModuleSource = Get-Content -Raw -Path (Join-Path $modules 'Test-OctoBuildChain.psm1')
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/buildchain'

    # Isolated git: no global/system config, fixed identity and a fixed (old) commit date.
    $script:SavedEnv = @{}
    $gitEnv = @{
        GIT_CONFIG_GLOBAL   = (Join-Path $TestDrive 'gitconfig')
        GIT_CONFIG_NOSYSTEM = '1'
        GIT_AUTHOR_NAME     = 'Pester'
        GIT_AUTHOR_EMAIL    = 'pester@example.invalid'
        GIT_COMMITTER_NAME  = 'Pester'
        GIT_COMMITTER_EMAIL = 'pester@example.invalid'
        GIT_AUTHOR_DATE     = '2020-01-01T00:00:00Z'
        GIT_COMMITTER_DATE  = '2020-01-01T00:00:00Z'
    }
    foreach ($key in $gitEnv.Keys) {
        $script:SavedEnv[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $gitEnv[$key])
    }
    Set-Content -Path $gitEnv.GIT_CONFIG_GLOBAL -Value "[init]`n`tdefaultBranch = main`n[advice]`n`tdetachedHead = false"

    function New-FakeRepo([string]$lane, [string]$name, [hashtable]$projects) {
        # $projects: relative csproj path -> csproj text
        $path = Join-Path $lane $name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Set-Content -Path (Join-Path $path "$name.sln") -Value 'Microsoft Visual Studio Solution File, Format Version 12.00'
        foreach ($relative in $projects.Keys) {
            $file = Join-Path $path $relative
            New-Item -ItemType Directory -Path (Split-Path $file) -Force | Out-Null
            Set-Content -Path $file -Value $projects[$relative]
        }
        & git -C $path init -q -b main 2>&1 | Out-Null
        & git -C $path add -A 2>&1 | Out-Null
        & git -C $path commit -q -m 'initial' 2>&1 | Out-Null
    }

    function New-ProducerProject([string]$packageId, [string[]]$references = @()) {
        $refs = ($references | ForEach-Object { "    <PackageReference Include=""$_"" />" }) -join "`n"
        return "<Project Sdk=""Microsoft.NET.Sdk"">`n  <PropertyGroup>`n    <GeneratePackageOnBuild>true</GeneratePackageOnBuild>`n    <PackageId>$packageId</PackageId>`n  </PropertyGroup>`n  <ItemGroup>`n$refs`n  </ItemGroup>`n</Project>"
    }

    # Template lane: mm-common -> octo-sdk -> octo-asset-repo-services (consumer, produces nothing); built once, copied per test.
    $script:Template = Join-Path $TestDrive 'template'
    New-Item -ItemType Directory -Path $script:Template | Out-Null
    New-FakeRepo $script:Template 'mm-common' @{ 'src/Shared/Shared.csproj' = (New-ProducerProject 'Meshmakers.Common.Shared') }
    New-FakeRepo $script:Template 'octo-sdk' @{
        'src/Sdk.Common/Sdk.Common.csproj'    = (New-ProducerProject 'Meshmakers.Octo.Sdk.Common' @('Meshmakers.Common.Shared'))
        'tests/Sdk.Tests/Sdk.Tests.csproj'    = (New-ProducerProject 'Meshmakers.Octo.Sdk.Tests')
    }
    New-FakeRepo $script:Template 'octo-asset-repo-services' @{
        'src/Asset.Service/Asset.Service.csproj' = "<Project Sdk=""Microsoft.NET.Sdk.Web"">`n  <ItemGroup>`n    <PackageReference Include=""Meshmakers.Octo.Sdk.Common"" />`n  </ItemGroup>`n</Project>"
    }

    function New-FakeLane {
        # A copy of the template with a complete, current feed and an empty package cache.
        $lane = Join-Path $TestDrive ("lane-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Copy-Item -Path $script:Template -Destination $lane -Recurse
        $nuget = Join-Path $lane 'nuget'
        New-Item -ItemType Directory -Path $nuget | Out-Null
        foreach ($id in 'Meshmakers.Common.Shared', 'Meshmakers.Octo.Sdk.Common') {
            Set-Content -Path (Join-Path $nuget "$id.999.0.0.nupkg") -Value "package $id"
        }
        $cache = Join-Path $lane '.cache'
        New-Item -ItemType Directory -Path $cache | Out-Null
        return [pscustomobject]@{ Lane = $lane; Nuget = $nuget; Cache = $cache }
    }

    function Invoke-Doctor($fake, [hashtable]$extra = @{}) {
        $parameters = @{ LaneRoot = $fake.Lane; GlobalPackagesPath = @($fake.Cache); Json = $true }
        foreach ($key in $extra.Keys) { $parameters[$key] = $extra[$key] }
        $json = Test-OctoBuildChain @parameters
        return ($json | ConvertFrom-Json).data
    }

    function Get-TreeSnapshot([string]$root) {
        return @(Get-ChildItem -LiteralPath $root -Recurse -Force -File | Sort-Object FullName | ForEach-Object {
                "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
            })
    }
}

AfterAll {
    foreach ($key in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $script:SavedEnv[$key]) }
}

Describe 'Test-OctoBuildChain: clean lane' {
    It 'reports nothing, success and exit code 0' {
        $fake = New-FakeLane
        $data = Invoke-Doctor $fake
        $data.findings | Should -BeNullOrEmpty
        $data.success | Should -BeTrue
        $data.summary.blocking | Should -Be 0
        $global:LASTEXITCODE | Should -Be 0
        @($data.repositories).Count | Should -Be 3
    }
}

Describe 'Test-OctoBuildChain: branches (AC 1)' {
    It 'flags a chain repository on a feature branch with repo and branch' {
        $fake = New-FakeLane
        & git -C (Join-Path $fake.Lane 'octo-sdk') checkout -q -b 'gerald/AB#1_feature' 2>&1 | Out-Null
        $data = Invoke-Doctor $fake
        $finding = @($data.findings | Where-Object check -eq 'branch')
        $finding.Count | Should -Be 1
        $finding[0].repo | Should -Be 'octo-sdk'
        $finding[0].message | Should -Match "gerald/AB#1_feature"
        $finding[0].severity | Should -Be 'blocking'
        $finding[0].fix | Should -Match "switch main"
        $finding[0].fix | Should -Match 'Invoke-BuildRange -from octo-sdk -to octo-sdk'
        $data.success | Should -BeFalse
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'flags a detached HEAD' {
        $fake = New-FakeLane
        & git -C (Join-Path $fake.Lane 'mm-common') checkout -q --detach 2>&1 | Out-Null
        $finding = @((Invoke-Doctor $fake).findings | Where-Object check -eq 'branch')
        $finding.Count | Should -Be 1
        $finding[0].repo | Should -Be 'mm-common'
        $finding[0].reason | Should -Be 'detached'
        $finding[0].message | Should -Match 'detached HEAD'
    }

    It 'flags uncommitted changes as a warning only' {
        $fake = New-FakeLane
        Set-Content -Path (Join-Path $fake.Lane 'octo-sdk/new.txt') -Value 'x'
        $data = Invoke-Doctor $fake
        $finding = @($data.findings | Where-Object check -eq 'dirty')
        $finding.Count | Should -Be 1
        $finding[0].severity | Should -Be 'warning'
        $data.success | Should -BeTrue
        $global:LASTEXITCODE | Should -Be 0
    }

    It 'gives a repository that builds nothing a warning without a range command' {
        $fake = New-FakeLane
        $path = Join-Path $fake.Lane 'octo-pipeline-templates'
        New-Item -ItemType Directory -Path $path | Out-Null
        Set-Content -Path (Join-Path $path 'readme.md') -Value 'x'
        & git -C $path init -q -b main 2>&1 | Out-Null
        & git -C $path add -A 2>&1 | Out-Null
        & git -C $path commit -q -m i 2>&1 | Out-Null
        & git -C $path checkout -q -b other 2>&1 | Out-Null
        $finding = @((Invoke-Doctor $fake).findings | Where-Object { $_.check -eq 'branch' })
        $finding.Count | Should -Be 1
        $finding[0].severity | Should -Be 'warning'
        $finding[0].fix | Should -Not -Match 'Invoke-BuildRange'
    }
}

Describe 'Test-OctoBuildChain: packages in <lane>/nuget (AC 3)' {
    It 'names the producing repository and the smallest range for a missing package (NU1101 case)' {
        $fake = New-FakeLane
        Remove-Item (Join-Path $fake.Nuget 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg')
        $finding = @((Invoke-Doctor $fake).findings | Where-Object check -eq 'missingPackage')
        $finding.Count | Should -Be 1
        $finding[0].repo | Should -Be 'octo-sdk'
        $finding[0].package | Should -Be 'Meshmakers.Octo.Sdk.Common'
        $finding[0].severity | Should -Be 'blocking'
        $finding[0].fix | Should -Be 'Invoke-BuildRange -from octo-sdk -to octo-sdk'
        $finding[0].fixWithConsumers | Should -Be 'Invoke-BuildRange -from octo-sdk -to octo-asset-repo-services'
    }

    It 'does not count a test project as a producer' {
        $fake = New-FakeLane
        (Invoke-Doctor $fake).findings | Where-Object package -like '*Sdk.Tests*' | Should -BeNullOrEmpty
    }

    It 'warns about a package older than the last commit of its repository' {
        $fake = New-FakeLane
        (Get-Item (Join-Path $fake.Nuget 'Meshmakers.Common.Shared.999.0.0.nupkg')).LastWriteTimeUtc = [datetime]'2010-01-01'
        $finding = @((Invoke-Doctor $fake).findings | Where-Object check -eq 'outdatedPackage')
        $finding.Count | Should -Be 1
        $finding[0].repo | Should -Be 'mm-common'
        $finding[0].severity | Should -Be 'warning'
        $finding[0].fix | Should -Be 'Invoke-BuildRange -from mm-common -to mm-common'
        $finding[0].fixWithConsumers | Should -Be 'Invoke-BuildRange -from mm-common -to octo-asset-repo-services'
    }
}

Describe 'Test-OctoBuildChain: stale 999.0.0 cache (AC 2)' {
    BeforeEach {
        $script:fake = New-FakeLane
        $script:cacheDir = Join-Path $script:fake.Cache 'meshmakers.octo.sdk.common/999.0.0'
        New-Item -ItemType Directory -Path $script:cacheDir -Force | Out-Null
        $script:hashFile = Join-Path $script:cacheDir 'meshmakers.octo.sdk.common.999.0.0.nupkg.sha512'
    }

    It 'reports a hash that differs from the feed with -purgeStaleCache for the producing range' {
        Set-Content -Path $script:hashFile -Value 'not-the-hash'
        $finding = @((Invoke-Doctor $script:fake).findings | Where-Object check -eq 'staleCache')
        $finding.Count | Should -Be 1
        $finding[0].reason | Should -Be 'hashMismatch'
        $finding[0].severity | Should -Be 'blocking'
        $finding[0].repo | Should -Be 'octo-sdk'
        $finding[0].fix | Should -Be 'Invoke-BuildRange -from octo-sdk -to octo-sdk -purgeStaleCache'
    }

    It 'reports nothing when the cache hash equals the feed package' {
        $nupkg = Join-Path $script:fake.Nuget 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg'
        $hash = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($nupkg)))
        Set-Content -NoNewline -Path $script:hashFile -Value $hash
        (Invoke-Doctor $script:fake).findings | Where-Object check -eq 'staleCache' | Should -BeNullOrEmpty
    }

    It 'warns about a cache folder without hash file' {
        $finding = @((Invoke-Doctor $script:fake).findings | Where-Object check -eq 'staleCache')
        $finding.Count | Should -Be 1
        $finding[0].reason | Should -Be 'noHashFile'
        $finding[0].severity | Should -Be 'warning'
    }
}

Describe 'Test-OctoBuildChain: -BuildLog (AC 4)' {
    It 'maps NU1102 for a Meshmakers package to the producing repository and ends the range at the failing consumer' {
        $fake = New-FakeLane
        $data = Invoke-Doctor $fake @{ BuildLog = (Join-Path $script:Fixtures 'nu1102.buildlog') }
        $finding = @($data.findings | Where-Object check -eq 'buildLog' | Where-Object package -eq 'Meshmakers.Octo.Sdk.Common')
        $finding.Count | Should -Be 1
        $finding[0].reason | Should -Be 'NU1102'
        $finding[0].repo | Should -Be 'octo-sdk'
        $finding[0].severity | Should -Be 'blocking'
        $finding[0].fix | Should -Be 'Invoke-BuildRange -from octo-sdk -to octo-asset-repo-services'
        $finding[0].message | Should -Match 'octo-asset-repo-services'
        $data.summary.recommendedFix | Should -Be 'Invoke-BuildRange -from octo-sdk -to octo-asset-repo-services'
    }

    It 'handles NU1101 and reports a repeated line once' {
        $fake = New-FakeLane
        $findings = @((Invoke-Doctor $fake @{ BuildLog = (Join-Path $script:Fixtures 'nu1101.buildlog') }).findings | Where-Object check -eq 'buildLog')
        @($findings | Where-Object package -eq 'Meshmakers.Common.Shared').Count | Should -Be 1
        @($findings | Where-Object package -eq 'Meshmakers.Common.Shared')[0].reason | Should -Be 'NU1101'
    }

    It 'reports a package no chain repository produces without a fix' {
        $fake = New-FakeLane
        $findings = @((Invoke-Doctor $fake @{ BuildLog = (Join-Path $script:Fixtures 'nu1102.buildlog') }).findings | Where-Object check -eq 'buildLog')
        $external = @($findings | Where-Object package -eq 'Some.Third.Party')
        $external.Count | Should -Be 1
        $external[0].severity | Should -Be 'warning'
        $external[0].fix | Should -BeNullOrEmpty
    }

    It 'reports a missing log file as a warning' {
        $fake = New-FakeLane
        $finding = @((Invoke-Doctor $fake @{ BuildLog = (Join-Path $fake.Lane 'nope.log') }).findings | Where-Object check -eq 'buildLog')
        $finding.Count | Should -Be 1
        $finding[0].reason | Should -Be 'logNotFound'
    }

    It 'never copies log text into the output' {
        $fake = New-FakeLane
        $json = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) -BuildLog (Join-Path $script:Fixtures 'nu1102.buildlog') -Json
        $json | Should -Not -Match 'LOG-SECRET-MARKER'
    }
}

Describe 'Test-OctoBuildChain: recommendation' {
    It 'combines every affected producer into one range' {
        $fake = New-FakeLane
        Remove-Item (Join-Path $fake.Nuget 'Meshmakers.Common.Shared.999.0.0.nupkg')
        Remove-Item (Join-Path $fake.Nuget 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg')
        (Invoke-Doctor $fake).summary.recommendedFix | Should -Be 'Invoke-BuildRange -from mm-common -to octo-sdk'
    }
}

Describe 'Test-OctoBuildChain: read-only guarantee (AC 5)' {
    It 'changes nothing in the lane, its git repositories, the feed or the cache - text and JSON, with findings' {
        $fake = New-FakeLane
        & git -C (Join-Path $fake.Lane 'octo-sdk') checkout -q -b feature 2>&1 | Out-Null
        Set-Content -Path (Join-Path $fake.Lane 'mm-common/dirty.txt') -Value 'x'
        Remove-Item (Join-Path $fake.Nuget 'Meshmakers.Common.Shared.999.0.0.nupkg')
        $stale = Join-Path $fake.Cache 'meshmakers.octo.sdk.common/999.0.0'
        New-Item -ItemType Directory -Path $stale -Force | Out-Null
        Set-Content -Path (Join-Path $stale 'meshmakers.octo.sdk.common.999.0.0.nupkg.sha512') -Value 'other'
        $before = Get-TreeSnapshot $fake.Lane
        Start-Sleep -Milliseconds 1100   # a rewritten file would get a different mtime

        $null = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) -Json
        $null = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) -BuildLog (Join-Path $script:Fixtures 'nu1102.buildlog') 6>&1

        Get-TreeSnapshot $fake.Lane | Should -Be $before
    }

    It 'does not write anywhere outside the temp lane (the real home and the working directory stay untouched)' {
        $fake = New-FakeLane
        $probe = Join-Path $TestDrive 'cwd'
        New-Item -ItemType Directory -Path $probe | Out-Null
        Push-Location $probe
        try { $null = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) -Json }
        finally { Pop-Location }
        @(Get-ChildItem -LiteralPath $probe -Force) | Should -BeNullOrEmpty
    }

    It 'uses no cmdlet or git command that writes' {
        $code = ($script:ModuleSource -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        $code | Should -Not -Match '\b(Set-Content|Add-Content|Out-File|New-Item|Remove-Item|Move-Item|Copy-Item|Rename-Item|Set-ItemProperty|Clear-Content|Export-Clixml|Start-Process|Invoke-WebRequest|Invoke-RestMethod)\b'
        $code | Should -Not -Match '\[IO\.File\]::(Write|Delete|Move|Copy|Create|Append)'
        # git runs through one call site (Invoke-OctoChainGit, with an allow list), and only read-only subcommands are requested
        @([regex]::Matches($code, '(?m)^\s*(?:\$\w+\s*=\s*)?&\s*git\b')).Count | Should -Be 1
        $requested = @([regex]::Matches($code, "-gitArguments\s+@\('([a-z-]+)'") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $requested | Should -Not -BeNullOrEmpty
        $requested | Where-Object { $_ -notin 'rev-parse', 'symbolic-ref', 'status', 'log', 'ls-files', 'grep' } | Should -BeNullOrEmpty
        $code | Should -Not -Match '\bSet-Octo|\bRemove-Octo|\bInvoke-OctoBuildRange\b'
    }

    It 'refuses a git subcommand that is not read-only' {
        $fake = New-FakeLane
        InModuleScope Test-OctoBuildChain -Parameters @{ path = (Join-Path $fake.Lane 'octo-sdk') } {
            { Invoke-OctoChainGit -path $path -gitArguments @('checkout', '-b', 'x') } | Should -Throw '*not a read-only git command*'
            { Invoke-OctoChainGit -path $path -gitArguments @('fetch') } | Should -Throw '*not a read-only git command*'
        }
    }

    It 'prints no environment variable value (only lane paths)' {
        $fake = New-FakeLane
        [Environment]::SetEnvironmentVariable('OCTO_DOCTOR_SENTINEL', 'sentinel-value-12345')
        [Environment]::SetEnvironmentVariable('NUGET_PACKAGES', (Join-Path $fake.Lane 'env-cache'))
        try {
            $json = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) -Json | Out-String
            $text = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) 6>&1 | Out-String
        }
        finally {
            [Environment]::SetEnvironmentVariable('OCTO_DOCTOR_SENTINEL', $null)
            [Environment]::SetEnvironmentVariable('NUGET_PACKAGES', $null)
        }
        ($json + $text) | Should -Not -Match 'sentinel-value-12345'
    }
}

Describe 'Test-OctoBuildChain: output, runtime and docs (AC 6)' {
    It 'writes one JSON document in the shared envelope' {
        $fake = New-FakeLane
        Remove-Item (Join-Path $fake.Nuget 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg')
        $document = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) -Json | ConvertFrom-Json
        $document.schemaVersion | Should -Be 1
        $document.command | Should -Be 'Test-OctoBuildChain'
        $document.timestamp | Should -Not -BeNullOrEmpty
        $document.data.laneRoot | Should -Be ([IO.Path]::TrimEndingDirectorySeparator($fake.Lane))
        $document.data.laneFeed | Should -Be (Join-Path $fake.Lane 'nuget')
        $document.data.exitCode | Should -Be 1
        $document.data.summary.blocking | Should -Be 1
        @($document.data.findings)[0].id | Should -Be 'F1'
        @($document.data.repositories | ForEach-Object name) | Should -Be @('mm-common', 'octo-sdk', 'octo-asset-repo-services')
    }

    It 'prints a readable text report with the fix and says nothing was changed' {
        $fake = New-FakeLane
        Remove-Item (Join-Path $fake.Nuget 'Meshmakers.Octo.Sdk.Common.999.0.0.nupkg')
        $text = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) 6>&1 | Out-String
        $text | Should -Match '\[blocking\] missingPackage'
        $text | Should -Match 'fix: Invoke-BuildRange -from octo-sdk -to octo-sdk'
        $text | Should -Match 'Nothing was changed'
    }

    It 'runs in well under 30 seconds on a lane' {
        $fake = New-FakeLane
        (Measure-Command { $null = Test-OctoBuildChain -LaneRoot $fake.Lane -GlobalPackagesPath @($fake.Cache) -Json }).TotalSeconds | Should -BeLessThan 30
    }

    It 'documents -Json in the cmdlet help and modules/README.md' {
        $help = Get-Help Test-OctoBuildChain -Full | Out-String
        $help | Should -Match 'recommendedFix'
        $help | Should -Match 'findings\[\]'
        $readme = Get-Content -Raw -Path (Join-Path $PSScriptRoot '../modules/README.md')
        $readme | Should -Match 'Test-OctoBuildChain'
        $readme | Should -Match '-Json'
    }

    It 'is exported by the module and imported by profile.ps1' {
        (Get-Command Test-OctoBuildChain).Source | Should -Be 'Test-OctoBuildChain'
        (Get-Content -Raw -Path (Join-Path $PSScriptRoot '../modules/profile.ps1')) | Should -Match 'Test-OctoBuildChain\.psm1'
        (Get-Command Get-OctoStaleGlobalPackages -ErrorAction Stop).Source | Should -Be 'Invoke-BuildRange'
    }
}
