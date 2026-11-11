#Requires -Modules Pester
<#
    Pester tests for steerable test runs (OctoTests.psm1, AB#8813).

    Everything runs in TestDrive: a fake workspace with a lane (branches/main), a feature environment (wt-feat-a, its
    manifest written by hand) and an in-place worktree, each holding one fake repository with a unit test project, a
    Testcontainers project and a non-test project. `dotnet test` never starts: Invoke-OctoDotnetTest is mocked and
    drops canned TRX files (tests/fixtures/trx) into the results folder. No Docker, no real lane, no ~/.nuget, and
    never the real machine-wide lock: OCTO_TEST_LOCK_PATH points into TestDrive and every call passes -lockPath.

    Run:  Invoke-Pester ./tests/OctoTests.Tests.ps1
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
    Import-Module (Join-Path $modules 'OctoTests.psm1') -Force

    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/trx'
    $script:PreviousRootPath = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $script:SavedEnv = @{}
    foreach ($name in @('OCTO_TEST_LOCK_PATH', 'NUGET_PACKAGES', 'MSBUILDDISABLENODEREUSE', 'RestoreSources')) {
        $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    # Safety net: a call that forgets -lockPath still never reaches the real lock.
    $env:OCTO_TEST_LOCK_PATH = Join-Path $TestDrive 'locks/default.lock'
    $script:LockPath = Join-Path $TestDrive 'locks/docker-tests.lock'

    function Get-Doc([object[]]$output) { return (($output -join "`n") | ConvertFrom-Json) }

    function New-TestCsproj([string]$folder, [string]$name, [string[]]$packages = @(), [string[]]$projectReferences = @(), [string]$assemblyName = '', [switch]$isTestProject) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $lines = @('<Project Sdk="Microsoft.NET.Sdk">', '  <PropertyGroup>')
        if ($assemblyName) { $lines += "    <AssemblyName>$assemblyName</AssemblyName>" }
        if ($isTestProject) { $lines += '    <IsTestProject>true</IsTestProject>' }
        $lines += '  </PropertyGroup>', '  <ItemGroup>'
        foreach ($package in $packages) { $lines += "    <PackageReference Include=""$package"" Version=""1.0.0"" />" }
        foreach ($reference in $projectReferences) { $lines += "    <ProjectReference Include=""$reference"" />" }
        $lines += '  </ItemGroup>', '</Project>'
        Set-Content -Path (Join-Path $folder "$name.csproj") -Value $lines
    }

    # A repository with src/Sample, a unit test project, a Testcontainers project (via IsTestProject and a custom
    # assembly name) and a project below tests/ that is no test project.
    function New-TestRepo([string]$path) {
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        New-TestCsproj (Join-Path $path 'src/Sample') 'Sample'
        Set-Content -Path (Join-Path $path 'src/Sample/Order.cs') -Value 'namespace Sample; public class Order { }'
        New-TestCsproj (Join-Path $path 'tests/Sample.UnitTests') 'Sample.UnitTests' -packages 'Microsoft.NET.Test.Sdk', 'xunit.v3' -projectReferences '..\..\src\Sample\Sample.csproj'
        New-TestCsproj (Join-Path $path 'tests/Sample.IntegrationTests') 'Sample.IntegrationTests' -packages 'Testcontainers.MongoDb' -projectReferences '..\..\src\Sample\Sample.csproj' -assemblyName 'Meshmakers.Sample.IntegrationTests' -isTestProject
        New-TestCsproj (Join-Path $path 'tests/Sample.TestModel') 'Sample.TestModel' -packages 'Newtonsoft.Json'
        # never entered by the project scan
        New-TestCsproj (Join-Path $path 'node_modules/pkg') 'Hidden.Tests' -packages 'Microsoft.NET.Test.Sdk'
        return $path
    }

    # Marks a test project as built: its assembly below bin/DebugL, newer than every source file.
    function Set-TestBuildOutput([string]$repo, [string]$project, [string]$assembly, [DateTime]$time) {
        $bin = Join-Path $repo "tests/$project/bin/DebugL/net10.0"
        New-Item -ItemType Directory -Force -Path $bin | Out-Null
        $file = Join-Path $bin "$assembly.dll"
        Set-Content -Path $file -Value 'fixture'
        [IO.File]::SetLastWriteTimeUtc($file, $time)
    }

    function Set-TestSourceTimes([string]$repo, [DateTime]$time) {
        foreach ($file in @(Get-ChildItem -Path $repo -Recurse -File | Where-Object { $_.FullName -notmatch '[/\\](bin|obj)[/\\]' })) {
            [IO.File]::SetLastWriteTimeUtc($file.FullName, $time)
        }
    }

    function New-TestWorkspace {
        $ws = Join-Path $TestDrive 'ws'
        if (Test-Path $ws) { Remove-Item $ws -Recurse -Force }
        if (Test-Path (Join-Path $TestDrive 'locks')) { Remove-Item (Join-Path $TestDrive 'locks') -Recurse -Force }
        $main = Join-Path $ws 'branches/main'
        New-Item -ItemType Directory -Force -Path $main | Out-Null
        Set-Content -Path (Join-Path $main 'Octo.User.props') -Value '<Project><PropertyGroup><OctoSomething>1</OctoSomething></PropertyGroup></Project>'
        $repo = New-TestRepo (Join-Path $main 'octo-sample-services')

        # Feature environment wt-feat-a: an isolated lane with the repository as a worktree folder and one in-place
        # repository outside of it.
        $envPath = Join-Path $ws 'wt-feat-a'
        New-Item -ItemType Directory -Force -Path (Join-Path $envPath '.octo') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $envPath 'nuget') | Out-Null
        Set-Content -Path (Join-Path $envPath 'Octo.User.props') -Value '<Project><PropertyGroup><RestorePackagesPath>$(MSBuildThisFileDirectory).nuget-packages</RestorePackagesPath></PropertyGroup></Project>'
        $envRepo = New-TestRepo (Join-Path $envPath 'octo-sample-services')
        $inPlace = New-TestRepo (Join-Path $ws 'elsewhere/octo-other-services')
        Set-Content -Path (Join-Path $inPlace 'Directory.Build.props') -Value @(
            '<Project><PropertyGroup>',
            '  <RestoreSources>$(OctoRepoRootPath)../nuget;https://feeduser:feedsecret@feed.example.invalid/v3/index.json</RestoreSources>',
            '</PropertyGroup></Project>')
        $manifest = [ordered]@{
            schemaVersion = 1; name = 'feat-a'; workItem = 'AB#8813'; base = 'branches/main'; created = '2026-11-11T08:00:00Z'; owner = 'pester'
            repos = @(
                [ordered]@{ name = 'octo-sample-services'; role = 'feature'; path = $envRepo; branch = 'pester/AB#8813_x'; baseCommit = 'abc' },
                [ordered]@{ name = 'octo-other-services'; role = 'feature'; path = $inPlace; branch = 'pester/AB#8813_y'; baseCommit = 'def' })
            slot = 'feat-a'
        }
        Set-Content -Path (Join-Path $envPath '.octo/environment.json') -Value (ConvertTo-Json -InputObject $manifest -Depth 6)

        $global:rootPath = $ws
        return [pscustomobject]@{ Root = $ws; Main = $main; Repo = $repo; EnvPath = $envPath; EnvRepo = $envRepo; InPlace = $inPlace }
    }

    # What the mocked `dotnet test` does per test project (key = csproj name): the TRX fixture it writes and its exit
    # code. $script:Calls records every call with the environment and the lock state at that moment.
    function Reset-TestDotnet {
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Behaviour = @{
            'Sample.UnitTests'        = @{ Trx = 'passed.trx'; ExitCode = 0 }
            'Sample.IntegrationTests' = @{ Trx = 'mixed.trx'; ExitCode = 1 }
        }
    }
}

AfterAll {
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    if ($null -ne $script:PreviousRootPath) { $global:rootPath = $script:PreviousRootPath } else { Remove-Variable -Name rootPath -Scope Global -ErrorAction SilentlyContinue }
}

Describe 'Machine-wide test lock' {
    BeforeEach {
        if (Test-Path (Join-Path $TestDrive 'locks')) { Remove-Item (Join-Path $TestDrive 'locks') -Recurse -Force }
    }

    It 'is taken by one owner at a time and names its owner' {
        $first = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0 -Run @{ command = 'Invoke-OctoTestRun'; lane = '/lane'; environment = 'feat-a'; repo = 'octo-x'; projects = @('X.IntegrationTests') }
        $first.Acquired | Should -BeTrue
        $first.Path | Should -Be $script:LockPath
        $owner = Get-Content $script:LockPath -Raw | ConvertFrom-Json
        $owner.pid | Should -Be $PID
        $owner.id | Should -Be $first.Id
        $owner.repo | Should -Be 'octo-x'
        $owner.environment | Should -Be 'feat-a'
        @($owner.projects) | Should -Be @('X.IntegrationTests')

        $second = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0
        $second.Acquired | Should -BeFalse
        $second.Owner['pid'] | Should -Be $PID
        $second.Owner['repo'] | Should -Be 'octo-x'
        # no leftover of the failed attempt
        @(Get-ChildItem (Split-Path -Parent $script:LockPath)).Count | Should -Be 1

        Exit-OctoTestLock -Id 'not-the-owner' -LockPath $script:LockPath | Should -BeFalse
        Test-Path $script:LockPath | Should -BeTrue
        Exit-OctoTestLock -Id $first.Id -LockPath $script:LockPath | Should -BeTrue
        Test-Path $script:LockPath | Should -BeFalse
    }

    It 'waits for the owner, announces it once and takes the lock when it is released' {
        $first = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0 -Run @{ repo = 'octo-first' }
        $script:Announced = [System.Collections.Generic.List[object]]::new()
        $second = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 30 -PollMilliseconds 10 -Run @{ repo = 'octo-second' } -OnWait {
            param($owner)
            $script:Announced.Add($owner['repo'])
            Exit-OctoTestLock -Id $first.Id -LockPath $script:LockPath | Out-Null
        }
        $second.Acquired | Should -BeTrue
        @($script:Announced) | Should -Be @('octo-first')
        (Get-Content $script:LockPath -Raw | ConvertFrom-Json).repo | Should -Be 'octo-second'
    }

    It 'gives up after the timeout and reports the owner' {
        $first = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0 -Run @{ repo = 'octo-first' }
        $second = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 1 -PollMilliseconds 50
        $second.Acquired | Should -BeFalse
        $second.WaitedSeconds | Should -BeGreaterOrEqual 1
        $second.Owner['id'] | Should -Be $first.Id
        (Get-Content $script:LockPath -Raw | ConvertFrom-Json).id | Should -Be $first.Id
    }

    It 'replaces a lock whose owner process is gone' {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:LockPath) | Out-Null
        Set-Content -Path $script:LockPath -Value (ConvertTo-Json @{ id = 'dead'; pid = 424242; processStartTime = '2026-11-11T07:00:00.0000000Z'; since = '2026-11-11T07:05:00.0000000Z'; repo = 'octo-dead'; command = 'Invoke-OctoTestRun' })
        Mock -ModuleName OctoTests Get-OctoTestProcessStartTime { if ($processId -eq 424242) { $null } else { [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime() } }
        $lock = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0 -Run @{ repo = 'octo-new' }
        $lock.Acquired | Should -BeTrue
        @($lock.StaleRemoved).Count | Should -Be 1
        $lock.StaleRemoved[0].repo | Should -Be 'octo-dead'
        (Get-Content $script:LockPath -Raw | ConvertFrom-Json).repo | Should -Be 'octo-new'
        @(Get-ChildItem (Split-Path -Parent $script:LockPath)).Count | Should -Be 1
    }

    It 'treats a recycled pid (other process start time) as gone, the same pid and start time as alive' {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:LockPath) | Out-Null
        Set-Content -Path $script:LockPath -Value (ConvertTo-Json @{ id = 'recycled'; pid = 424242; processStartTime = '2026-11-11T07:00:00.0000000Z'; since = '2026-11-11T07:05:00.0000000Z'; repo = 'octo-old' })
        # pid 424242 runs; every other pid (this process) keeps its real start time
        $script:OtherStart = [DateTime]::new(2026, 11, 11, 7, 0, 0, [DateTimeKind]::Utc)
        Mock -ModuleName OctoTests Get-OctoTestProcessStartTime { if ($processId -eq 424242) { $script:OtherStart } else { [System.Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime() } }
        (Get-Doc (Get-OctoTestLock -LockPath $script:LockPath -Json)).data.ownerAlive | Should -BeTrue
        (Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0).Acquired | Should -BeFalse

        $script:OtherStart = [DateTime]::new(2026, 11, 11, 9, 30, 0, [DateTimeKind]::Utc)
        (Get-Doc (Get-OctoTestLock -LockPath $script:LockPath -Json)).data.stale | Should -BeTrue
        (Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0).Acquired | Should -BeTrue
    }

    It 'keeps an unreadable lock file for 30 seconds, then replaces it' {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:LockPath) | Out-Null
        Set-Content -Path $script:LockPath -Value 'not json'
        (Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0).Acquired | Should -BeFalse
        Mock -ModuleName OctoTests Get-OctoTestUtcNow { [DateTime]::UtcNow.AddSeconds(60) }
        (Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0).Acquired | Should -BeTrue
    }

    It 'Get-OctoTestLock shows a free, a held and a stale lock' {
        $free = Get-Doc (Get-OctoTestLock -LockPath $script:LockPath -Json)
        $free.command | Should -Be 'Get-OctoTestLock'
        $free.data.locked | Should -BeFalse
        $free.data.owner | Should -BeNullOrEmpty
        $free.data.path | Should -Be $script:LockPath

        $lock = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0 -Run @{ command = 'Invoke-OctoTestRun'; lane = '/lane'; repo = 'octo-x'; projects = @('A', 'B') }
        $held = Get-Doc (Get-OctoTestLock -LockPath $script:LockPath -Json)
        $held.data.locked | Should -BeTrue
        $held.data.ownerAlive | Should -BeTrue
        $held.data.stale | Should -BeFalse
        $held.data.owner.pid | Should -Be $PID
        $held.data.owner.command | Should -Be 'Invoke-OctoTestRun'
        $held.data.owner.repo | Should -Be 'octo-x'
        @($held.data.owner.projects) | Should -Be @('A', 'B')
        $held.data.owner.heldSeconds | Should -BeGreaterOrEqual 0
        $held.data.owner.PSObject.Properties.Name | Should -Not -Contain 'id'
        { [DateTimeOffset]::Parse($held.data.owner.since) } | Should -Not -Throw

        Mock -ModuleName OctoTests Get-OctoTestProcessStartTime { $null }
        $stale = Get-Doc (Get-OctoTestLock -LockPath $script:LockPath -Json)
        $stale.data.locked | Should -BeTrue
        $stale.data.stale | Should -BeTrue
        $stale.data.ownerAlive | Should -BeFalse
    }

    It 'Remove-OctoTestLock refuses a live owner and removes a stale lock' {
        $lock = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0 -Run @{ repo = 'octo-x' }
        $refused = Get-Doc (Remove-OctoTestLock -LockPath $script:LockPath -Json)
        $refused.data.success | Should -BeFalse
        $refused.data.removed | Should -BeFalse
        $refused.data.ownerAlive | Should -BeTrue
        $refused.data.message | Should -Match 'is running'
        $global:LASTEXITCODE | Should -Be 1
        Test-Path $script:LockPath | Should -BeTrue

        Mock -ModuleName OctoTests Get-OctoTestProcessStartTime { $null }
        $whatIf = Get-Doc (Remove-OctoTestLock -LockPath $script:LockPath -WhatIf -Json)
        $whatIf.data.removed | Should -BeFalse
        Test-Path $script:LockPath | Should -BeTrue

        $removed = Get-Doc (Remove-OctoTestLock -LockPath $script:LockPath -Json)
        $removed.data.success | Should -BeTrue
        $removed.data.removed | Should -BeTrue
        $removed.data.owner.repo | Should -Be 'octo-x'
        $global:LASTEXITCODE | Should -Be 0
        Test-Path $script:LockPath | Should -BeFalse

        $nothing = Get-Doc (Remove-OctoTestLock -LockPath $script:LockPath -Json)
        $nothing.data.success | Should -BeTrue
        $nothing.data.removed | Should -BeFalse
    }

    It 'resolves the default lock path below the state folder, or from OCTO_TEST_LOCK_PATH' {
        InModuleScope OctoTests {
            $saved = $env:OCTO_TEST_LOCK_PATH
            try {
                $env:OCTO_TEST_LOCK_PATH = $null
                (Get-OctoTestLockPath) -replace '\\', '/' | Should -Match '/octo-tools/locks/docker-tests\.lock$'
                $env:OCTO_TEST_LOCK_PATH = '/somewhere/else.lock'
                Get-OctoTestLockPath | Should -Be '/somewhere/else.lock'
            }
            finally { $env:OCTO_TEST_LOCK_PATH = $saved }
        }
    }
}

Describe 'Docker capacity and limits (AB#8835)' {
    It 'reads sizes the way docker prints and takes them' {
        InModuleScope OctoTests {
            ConvertTo-OctoByteCount '6.154GiB' | Should -Be ([long](6.154 * 1GB))
            ConvertTo-OctoByteCount '572KiB' | Should -Be (572 * 1KB)
            ConvertTo-OctoByteCount '1.5GB' | Should -Be 1500000000
            ConvertTo-OctoByteCount '4g' | Should -Be (4 * 1GB)
            ConvertTo-OctoByteCount '2048m' | Should -Be (2048 * 1MB)
            ConvertTo-OctoByteCount '1024' | Should -Be 1024
            ConvertTo-OctoByteCount 'lots' | Should -BeNullOrEmpty
        }
    }

    It 'adds up what the running containers use and what is left' {
        InModuleScope OctoTests {
            Mock Invoke-OctoDocker {
                if ($arguments[0] -eq 'info') { return [pscustomobject]@{ ExitCode = 0; Output = @('WARNING: fixture warning', '16745033728 16') } }
                return [pscustomobject]@{ ExitCode = 0; Output = @('kind-control-plane|6.154GiB / 15.6GiB', 'relay|572KiB / 15.6GiB', 'not a row') }
            }
            $capacity = Get-OctoDockerCapacity
            $capacity.Available | Should -BeTrue
            $capacity.MemoryBytes | Should -Be 16745033728
            $capacity.Cpus | Should -Be 16
            @($capacity.Containers.Name) | Should -Be @('kind-control-plane', 'relay')
            $capacity.UsedBytes | Should -Be ([long](6.154 * 1GB) + 572 * 1KB)
            $capacity.FreeBytes | Should -Be (16745033728 - $capacity.UsedBytes)

            Mock Invoke-OctoDocker { [pscustomobject]@{ ExitCode = 1; Output = @('Cannot connect to the Docker daemon') } }
            $down = Get-OctoDockerCapacity
            $down.Available | Should -BeFalse
            $down.Error | Should -Match 'Cannot connect'
        }
    }

    It 'limits each new Testcontainers container once with docker update and leaves the resource reaper alone' {
        InModuleScope OctoTests {
            $script:Updates = [System.Collections.Generic.List[string]]::new()
            $script:Running = @(
                'aaaaaaaaaaaa1111111111111111111111111111111111111111111111111111|testcontainers/ryuk:0.14.0|testcontainers-ryuk-1',
                'bbbbbbbbbbbb2222222222222222222222222222222222222222222222222222|mongo:8.0.15|fixture-mongo')
            Mock Invoke-OctoDocker {
                if ($arguments[0] -eq 'ps') {
                    ($arguments -join ' ') | Should -Match '--filter label=org\.testcontainers=true --filter status=running'
                    return [pscustomobject]@{ ExitCode = 0; Output = $script:Running }
                }
                $script:Updates.Add($arguments -join ' ')
                $failed = $arguments[-1] -like 'cccc*'
                return [pscustomobject]@{ ExitCode = $(if ($failed) { 1 } else { 0 }); Output = @($(if ($failed) { 'fixture: cannot update' })) }
            }
            $state = @{ Seen = [System.Collections.Generic.HashSet[string]]::new(); Limited = [System.Collections.ArrayList]::new() }
            Invoke-OctoDockerLimitPass -State $state -Cpus 2.5 -Memory '4g'
            Invoke-OctoDockerLimitPass -State $state -Cpus 2.5 -Memory '4g'
            @($script:Updates) | Should -Be @('update --cpus 2.5 --memory 4g --memory-swap 4g bbbbbbbbbbbb2222222222222222222222222222222222222222222222222222')
            $state.Limited.Count | Should -Be 1
            $state.Limited[0].id | Should -Be 'bbbbbbbbbbbb'
            $state.Limited[0].name | Should -Be 'fixture-mongo'
            $state.Limited[0].success | Should -BeTrue

            # a container that starts later is limited too; a failed update is reported, not thrown
            $script:Running += 'cccccccccccc3333333333333333333333333333333333333333333333333333|rabbitmq:3|fixture-rabbit'
            Invoke-OctoDockerLimitPass -State $state -Cpus 2.5
            $script:Updates[-1] | Should -Be 'update --cpus 2.5 cccccccccccc3333333333333333333333333333333333333333333333333333'
            $state.Limited[1].success | Should -BeFalse
            $state.Limited[1].error | Should -Be 'fixture: cannot update'

            # no limit set: docker is not asked
            $script:Updates.Clear()
            Invoke-OctoDockerLimitPass -State @{ Seen = [System.Collections.Generic.HashSet[string]]::new(); Limited = [System.Collections.ArrayList]::new() }
            Should -Invoke Invoke-OctoDocker -Times 0 -ParameterFilter { $arguments[0] -eq 'update' -and $arguments.Count -eq 1 }
            $script:Updates.Count | Should -Be 0
        }
    }
}

Describe 'TRX parsing' {
    It 'reads totals, duration and the failed tests with message and first stack frame' {
        InModuleScope OctoTests -Parameters @{ file = (Join-Path $script:Fixtures 'mixed.trx') } {
            param($file)
            $trx = Read-OctoTrxFile -path $file
            $trx.Total | Should -Be 5
            $trx.Passed | Should -Be 2
            $trx.Failed | Should -Be 2
            $trx.Skipped | Should -Be 1
            $trx.DurationSeconds | Should -Be 12.5
            @($trx.FailedTests).Count | Should -Be 2
            $trx.FailedTests[0].Name | Should -Be 'Sample.Tests.OrderTests.Rejects_empty_order'
            $trx.FailedTests[0].Message | Should -Match '^Expected order\.State to be Rejected'
            $trx.FailedTests[0].StackFrame | Should -Be 'at Sample.Tests.OrderTests.Rejects_empty_order() in /src/tests/Sample.Tests/OrderTests.cs:line 42'
            $trx.FailedTests[0].DurationSeconds | Should -Be 1.5
            # a theory row: the filter name has no arguments, the display name keeps them
            $trx.FailedTests[1].Name | Should -Be 'Sample.Tests.PriceTests.Rounds'
            $trx.FailedTests[1].DisplayName | Should -Be 'Sample.Tests.PriceTests.Rounds(value: 1.005, expected: 1.01)'
            # xunit's run-level "[FAIL]" echo of a failed test is no run error
            @($trx.RunErrors).Count | Should -Be 0
        }
    }

    It 'falls back to the summary counters and reports run-level errors' {
        InModuleScope OctoTests -Parameters @{ file = (Join-Path $script:Fixtures 'aborted.trx') } {
            param($file)
            $trx = Read-OctoTrxFile -path $file
            $trx.Total | Should -Be 3
            $trx.Passed | Should -Be 1
            $trx.Failed | Should -Be 2
            @($trx.FailedTests).Count | Should -Be 0
            @($trx.RunErrors) | Should -Be @('The fixture test host process exited before the run finished.')
        }
    }
}

Describe 'Filters for a rerun' {
    It 'escapes operators and joins the names' {
        InModuleScope OctoTests {
            $chunks = @(Get-OctoTestFilterChunks -names @('B.C.Two', 'A.B.One(x)', 'B.C.Two'))
            $chunks.Count | Should -Be 1
            $chunks[0] | Should -Be 'FullyQualifiedName=A.B.One\(x\)|FullyQualifiedName=B.C.Two'
        }
    }

    It 'splits at the length limit and combines every chunk with the caller filter' {
        InModuleScope OctoTests {
            $names = 1..10 | ForEach-Object { 'Sample.Tests.Class{0:D2}.Method' -f $_ }
            $chunks = @(Get-OctoTestFilterChunks -names $names -filter 'Category=Fast' -maxLength 150)
            $chunks.Count | Should -BeGreaterThan 1
            foreach ($chunk in $chunks) {
                $chunk.Length | Should -BeLessOrEqual 150
                $chunk | Should -Match '^\(Category=Fast\)&\(FullyQualifiedName=.+\)$'
            }
            # every name exactly once
            $found = @($chunks | ForEach-Object { [regex]::Matches($_, 'Class\d\d') | ForEach-Object Value })
            ($found | Sort-Object) | Should -Be (1..10 | ForEach-Object { 'Class{0:D2}' -f $_ })
        }
    }

    It 'gives a name that is longer than the limit its own filter' {
        InModuleScope OctoTests {
            $chunks = @(Get-OctoTestFilterChunks -names @('A.Short', ('B.' + ('x' * 200))) -maxLength 50)
            $chunks.Count | Should -Be 2
        }
    }
}

Describe 'Filter calls per runner (AB#8832)' {
    It 'passes -filter in the filter language of the runner and reports a filter the runner cannot take' {
        InModuleScope OctoTests {
            $vstest = [pscustomobject]@{ Name = 'A.Tests'; Runner = 'vstest'; Framework = 'other' }
            $tunit = [pscustomobject]@{ Name = 'B.Tests'; Runner = 'mtp'; Framework = 'tunit' }
            $xunit = [pscustomobject]@{ Name = 'C.Tests'; Runner = 'mtp'; Framework = 'xunit3' }
            $mstest = [pscustomobject]@{ Name = 'D.Tests'; Runner = 'mtp'; Framework = 'other' }

            (Get-OctoTestFilterCalls -project $vstest).Calls[0].Arguments | Should -BeNullOrEmpty
            (Get-OctoTestFilterCalls -project $vstest -filter 'FullyQualifiedName~Order').Calls[0].Arguments | Should -Be @('--filter', 'FullyQualifiedName~Order')
            (Get-OctoTestFilterCalls -project $mstest -filter 'FullyQualifiedName~Order').Calls[0].Arguments | Should -Be @('--filter', 'FullyQualifiedName~Order')
            (Get-OctoTestFilterCalls -project $tunit -filter '/*/*/OrderTests/*').Calls[0].Arguments | Should -Be @('--treenode-filter', '/*/*/OrderTests/*')
            (Get-OctoTestFilterCalls -project $xunit -filter '/*/*/OrderTests/*').Calls[0].Arguments | Should -Be @('--filter-query', '/*/*/OrderTests/*')

            $wrong = Get-OctoTestFilterCalls -project $tunit -filter 'FullyQualifiedName~Order'
            @($wrong.Calls).Count | Should -Be 0
            $wrong.Mismatch | Should -Match 'tree-node filter such as /\*/\*/ClassName/\*'
            (Get-OctoTestFilterCalls -project $xunit -filter 'FullyQualifiedName~Order').Mismatch | Should -Match 'query filter'
            (Get-OctoTestFilterCalls -project $vstest -filter '/*/*/OrderTests/*').Mismatch | Should -Match 'FullyQualifiedName~ClassName'
        }
    }

    It 'reruns failed tests: clauses for VSTest, one tree-node filter per class for TUnit, --filter-method for xunit.v3' {
        InModuleScope OctoTests {
            $names = @('Ns.Orders.OrderTests.Fails', 'Ns.Orders.OrderTests.Rounds', 'Ns.Orders.PriceTests.Also_fails', 'Ns.Orders.OrderTests.Fails')
            $vstest = Get-OctoTestFilterCalls -project ([pscustomobject]@{ Name = 'A'; Runner = 'vstest'; Framework = 'other' }) -failedNames $names -filter 'Category=Fast'
            @($vstest.Calls).Count | Should -Be 1
            $vstest.Calls[0].Arguments[1] | Should -Be '(Category=Fast)&(FullyQualifiedName=Ns.Orders.OrderTests.Fails|FullyQualifiedName=Ns.Orders.OrderTests.Rounds|FullyQualifiedName=Ns.Orders.PriceTests.Also_fails)'

            $tunit = Get-OctoTestFilterCalls -project ([pscustomobject]@{ Name = 'B'; Runner = 'mtp'; Framework = 'tunit' }) -failedNames $names -filter 'FullyQualifiedName~Ignored'
            @($tunit.Calls | ForEach-Object { $_.Arguments -join ' ' }) | Should -Be @(
                '--treenode-filter /*/Ns.Orders/OrderTests/(Fails|Rounds)',
                '--treenode-filter /*/Ns.Orders/PriceTests/(Also_fails)')
            # split at the length limit
            @((Get-OctoTestFilterCalls -project ([pscustomobject]@{ Name = 'B'; Runner = 'mtp'; Framework = 'tunit' }) -failedNames $names -maxLength 30).Calls).Count | Should -Be 3
            # a VSTest rerun is combined with -filter: a tree filter matches nothing there, so nothing is run
            $mismatched = Get-OctoTestFilterCalls -project ([pscustomobject]@{ Name = 'A'; Runner = 'vstest'; Framework = 'other' }) -failedNames $names -filter '/*/*/OrderTests/*'
            @($mismatched.Calls).Count | Should -Be 0
            $mismatched.Mismatch | Should -Match 'FullyQualifiedName~ClassName'

            $xunit = Get-OctoTestFilterCalls -project ([pscustomobject]@{ Name = 'C'; Runner = 'mtp'; Framework = 'xunit3' }) -failedNames $names
            @($xunit.Calls).Count | Should -Be 1
            $xunit.Calls[0].Arguments | Should -Be @('--filter-method', 'Ns.Orders.OrderTests.Fails', '--filter-method', 'Ns.Orders.OrderTests.Rounds', '--filter-method', 'Ns.Orders.PriceTests.Also_fails')
            @((Get-OctoTestFilterCalls -project ([pscustomobject]@{ Name = 'C'; Runner = 'mtp'; Framework = 'xunit3' }) -failedNames $names -maxLength 60).Calls).Count | Should -Be 3
        }
    }
}

Describe 'Test projects of a repository' {
    BeforeEach { $script:ws = New-TestWorkspace }

    It 'finds test projects, the assembly name and the Docker marker' {
        InModuleScope OctoTests -Parameters @{ repo = $ws.Repo } {
            param($repo)
            $projects = @(Get-OctoTestProjects -repositoryPath $repo)
            @($projects.Name) | Should -Be @('Sample.IntegrationTests', 'Sample.UnitTests')
            $integration = $projects | Where-Object Name -eq 'Sample.IntegrationTests'
            $integration.Docker | Should -BeTrue
            $integration.DockerReason | Should -Be 'PackageReference Testcontainers.MongoDb in Sample.IntegrationTests.csproj'
            $integration.AssemblyName | Should -Be 'Meshmakers.Sample.IntegrationTests'
            $integration.RelativePath | Should -Be 'tests/Sample.IntegrationTests/Sample.IntegrationTests.csproj'
            $unit = $projects | Where-Object Name -eq 'Sample.UnitTests'
            $unit.Docker | Should -BeFalse
            $unit.AssemblyName | Should -Be 'Sample.UnitTests'
            @($unit.ProjectReferences.AssemblyName) | Should -Be @('Sample')
        }
    }

    It 'takes the markers from a referenced project and an unconditional Directory.Build.props' {
        New-TestCsproj (Join-Path $ws.Repo 'tests/Sample.TestHelpers') 'Sample.TestHelpers' -packages 'Testcontainers'
        New-TestCsproj (Join-Path $ws.Repo 'tests/suite/Sample.SystemTests') 'Sample.SystemTests' -projectReferences '../../Sample.TestHelpers/Sample.TestHelpers.csproj'
        New-TestCsproj (Join-Path $ws.Repo 'tests/suite/Sample.NotATest') 'Sample.NotATest'
        Set-Content -Path (Join-Path $ws.Repo 'tests/suite/Sample.NotATest/Sample.NotATest.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>false</IsTestProject></PropertyGroup></Project>'
        Set-Content -Path (Join-Path $ws.Repo 'tests/suite/Directory.Build.props') -Value '<Project><ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" Version="1.0.0" /></ItemGroup></Project>'
        # a conditional rule in a props file marks nothing
        Set-Content -Path (Join-Path $ws.Repo 'Directory.Build.props') -Value '<Project><PropertyGroup Condition="$(MSBuildProjectName.EndsWith(''Tests''))"><IsTestProject>true</IsTestProject></PropertyGroup></Project>'
        InModuleScope OctoTests -Parameters @{ repo = $ws.Repo } {
            param($repo)
            $projects = @(Get-OctoTestProjects -repositoryPath $repo)
            @($projects.Name | Sort-Object) | Should -Be @('Sample.IntegrationTests', 'Sample.SystemTests', 'Sample.UnitTests')
            $system = $projects | Where-Object Name -eq 'Sample.SystemTests'
            $system.Docker | Should -BeTrue
            $system.DockerReason | Should -Be 'PackageReference Testcontainers in Sample.TestHelpers.csproj'
        }
    }

    It 'finds test projects of frameworks that bring their own runner, and tells how dotnet test runs them (AB#8832)' {
        # octo-communication-operator: the test project references only TUnit - no Test.Sdk, no IsTestProject -
        # and the repository's global.json selects Microsoft.Testing.Platform.
        $repo = Join-Path $ws.Main 'octo-operator'
        New-TestCsproj (Join-Path $repo 'src/Operator') 'Operator'
        New-TestCsproj (Join-Path $repo 'tests/Operator.Tests') 'Operator.Tests' -packages 'Microsoft.Testing.Extensions.TrxReport', 'NSubstitute', 'TUnit' -projectReferences '..\..\src\Operator\Operator.csproj'
        New-TestCsproj (Join-Path $repo 'tests/Operator.IntegrationTests') 'Operator.IntegrationTests' -packages 'Microsoft.NET.Test.Sdk', 'xunit.v3', 'Testcontainers.MongoDb' -isTestProject
        # xunit.v3 in an executable is a test project, in a library (shared helpers) it is not
        New-TestCsproj (Join-Path $repo 'tests/Operator.X3Tests') 'Operator.X3Tests' -packages 'xunit.v3'
        (Get-Content (Join-Path $repo 'tests/Operator.X3Tests/Operator.X3Tests.csproj') -Raw).Replace('<PropertyGroup>', '<PropertyGroup><OutputType>Exe</OutputType>') | Set-Content (Join-Path $repo 'tests/Operator.X3Tests/Operator.X3Tests.csproj')
        New-TestCsproj (Join-Path $repo 'tests/Operator.TestHelpers') 'Operator.TestHelpers' -packages 'xunit.v3.extensibility.core'
        Set-Content -Path (Join-Path $repo 'global.json') -Value '{ "sdk": { "rollForward": "latestMinor" }, "test": { "runner": "Microsoft.Testing.Platform" } }'
        InModuleScope OctoTests -Parameters @{ repo = $repo; vstestRepo = $ws.Repo } {
            param($repo, $vstestRepo)
            $projects = @(Get-OctoTestProjects -repositoryPath $repo)
            @($projects.Name) | Should -Be @('Operator.IntegrationTests', 'Operator.Tests', 'Operator.X3Tests')
            @($projects.Runner | Sort-Object -Unique) | Should -Be @('mtp')
            @($projects.RunnerDirectory | Sort-Object -Unique) | Should -Be @($repo)
            # TUnit.Engine alone brings no TRX report: no runnable test project
            New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tests/Operator.EngineOnly') | Out-Null
            Set-Content -Path (Join-Path $repo 'tests/Operator.EngineOnly/Operator.EngineOnly.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="TUnit.Engine" Version="1.0.0" /></ItemGroup></Project>'
            @(Get-OctoTestProjects -repositoryPath $repo).Name | Should -Not -Contain 'Operator.EngineOnly'
            # a global.json below the repository root decides for the projects below it, and dotnet starts there
            Set-Content -Path (Join-Path $repo 'tests/Operator.X3Tests/global.json') -Value '{ "sdk": { "version": "10.0.100" } }'
            $nested = Get-OctoTestProjects -repositoryPath $repo | Where-Object Name -eq 'Operator.X3Tests'
            $nested.Runner | Should -Be 'vstest'
            $nested.RunnerDirectory | Should -Be (Join-Path $repo 'tests/Operator.X3Tests')
            ($projects | Where-Object Name -eq 'Operator.Tests').Framework | Should -Be 'tunit'
            ($projects | Where-Object Name -eq 'Operator.IntegrationTests').Framework | Should -Be 'xunit3'
            ($projects | Where-Object Name -eq 'Operator.IntegrationTests').Docker | Should -BeTrue
            # a repository without that global.json setting runs on VSTest
            @(Get-OctoTestProjects -repositoryPath $vstestRepo | ForEach-Object Runner | Sort-Object -Unique) | Should -Be @('vstest')
            Set-Content -Path (Join-Path $vstestRepo 'global.json') -Value '{ "sdk": { "version": "10.0.100" } }'
            @(Get-OctoTestProjects -repositoryPath $vstestRepo | ForEach-Object Runner | Sort-Object -Unique) | Should -Be @('vstest')
        }
    }

    It 'resolves -project by name, relative path and unique part, and refuses an ambiguous one' {
        InModuleScope OctoTests -Parameters @{ repo = $ws.Repo } {
            param($repo)
            $projects = @(Get-OctoTestProjects -repositoryPath $repo)
            (Resolve-OctoTestProject -name 'sample.unittests' -projects $projects).Name | Should -Be 'Sample.UnitTests'
            (Resolve-OctoTestProject -name 'tests/Sample.UnitTests/Sample.UnitTests.csproj' -projects $projects).Name | Should -Be 'Sample.UnitTests'
            (Resolve-OctoTestProject -name 'Integration' -projects $projects).Name | Should -Be 'Sample.IntegrationTests'
            { Resolve-OctoTestProject -name 'Sample' -projects $projects } | Should -Throw '*ambiguous*'
            { Resolve-OctoTestProject -name 'Nope' -projects $projects } | Should -Throw '*not found*'
        }
    }
}

Describe 'Build state of a test project' {
    BeforeEach {
        $script:ws = New-TestWorkspace
        $script:built = [DateTime]::new(2026, 11, 11, 8, 0, 0, [DateTimeKind]::Utc)
        Set-TestSourceTimes $ws.Repo $built.AddHours(-1)
        Set-TestBuildOutput $ws.Repo 'Sample.UnitTests' 'Sample.UnitTests' $built
    }

    It 'is current when the output is newer than sources, references and lane packages' {
        InModuleScope OctoTests -Parameters @{ repo = $ws.Repo; feed = (Join-Path $ws.Main 'nuget') } {
            param($repo, $feed)
            $project = Get-OctoTestProjects -repositoryPath $repo | Where-Object Name -eq 'Sample.UnitTests'
            $state = Get-OctoTestBuildState -project $project -repositoryPath $repo -configuration DebugL -laneFeed $feed -newestSource (Get-OctoTestNewestSource -repositoryPath $repo)
            $state.Current | Should -BeTrue
        }
    }

    It 'is stale without a build output, after a source change, after a referenced project was rebuilt and after a newer lane package' {
        InModuleScope OctoTests -Parameters @{ repo = $ws.Repo; feed = (Join-Path $ws.Main 'nuget'); built = $built } {
            param($repo, $feed, $built)
            $projects = @(Get-OctoTestProjects -repositoryPath $repo)
            $unit = $projects | Where-Object Name -eq 'Sample.UnitTests'
            $check = { Get-OctoTestBuildState -project $unit -repositoryPath $repo -configuration DebugL -laneFeed $feed -newestSource (Get-OctoTestNewestSource -repositoryPath $repo) }

            # no output: the integration project was never built; a Release run of the unit project neither
            $integration = $projects | Where-Object Name -eq 'Sample.IntegrationTests'
            (Get-OctoTestBuildState -project $integration -repositoryPath $repo -configuration DebugL).Reason | Should -Be 'no DebugL build output of Sample.IntegrationTests'
            (Get-OctoTestBuildState -project $unit -repositoryPath $repo -configuration Release).Current | Should -BeFalse

            # an output of a target framework that is no longer built does not make it stale
            $old = Join-Path $repo 'tests/Sample.UnitTests/bin/DebugL/net9.0'
            New-Item -ItemType Directory -Force -Path $old | Out-Null
            Set-Content -Path (Join-Path $old 'Sample.UnitTests.dll') -Value 'old'
            [IO.File]::SetLastWriteTimeUtc((Join-Path $old 'Sample.UnitTests.dll'), $built.AddDays(-30))
            (& $check).Current | Should -BeTrue

            # a lane package the project restored, rebuilt after the test build
            New-Item -ItemType Directory -Force -Path $feed, (Join-Path $repo 'tests/Sample.UnitTests/obj') | Out-Null
            Set-Content -Path (Join-Path $repo 'tests/Sample.UnitTests/obj/project.assets.json') -Value '{ "libraries": { "Meshmakers.Octo.Sdk/999.0.0": {}, "Newtonsoft.Json/13.0.3": {} } }'
            Set-Content -Path (Join-Path $feed 'Meshmakers.Octo.Sdk.999.0.0.nupkg') -Value 'sdk'
            Set-Content -Path (Join-Path $feed 'Meshmakers.Unrelated.999.0.0.nupkg') -Value 'unrelated'
            [IO.File]::SetLastWriteTimeUtc((Join-Path $feed 'Meshmakers.Octo.Sdk.999.0.0.nupkg'), $built.AddMinutes(-5))
            [IO.File]::SetLastWriteTimeUtc((Join-Path $feed 'Meshmakers.Unrelated.999.0.0.nupkg'), $built.AddMinutes(5))
            (& $check).Current | Should -BeTrue   # only packages the project uses count
            [IO.File]::SetLastWriteTimeUtc((Join-Path $feed 'Meshmakers.Octo.Sdk.999.0.0.nupkg'), $built.AddMinutes(5))
            (& $check).Reason | Should -Be 'the lane feed holds a newer Meshmakers.Octo.Sdk.999.0.0.nupkg'
            [IO.File]::SetLastWriteTimeUtc((Join-Path $feed 'Meshmakers.Octo.Sdk.999.0.0.nupkg'), $built.AddMinutes(-5))

            # the referenced src project was rebuilt after the tests (a src-only range build)
            $srcBin = Join-Path $repo 'src/Sample/bin/DebugL/net10.0'
            New-Item -ItemType Directory -Force -Path $srcBin | Out-Null
            Set-Content -Path (Join-Path $srcBin 'Sample.dll') -Value 'src'
            [IO.File]::SetLastWriteTimeUtc((Join-Path $srcBin 'Sample.dll'), $built.AddMinutes(-1))
            (& $check).Current | Should -BeTrue
            [IO.File]::SetLastWriteTimeUtc((Join-Path $srcBin 'Sample.dll'), $built.AddMinutes(1))
            (& $check).Reason | Should -Be 'Sample was built after Sample.UnitTests'
            [IO.File]::SetLastWriteTimeUtc((Join-Path $srcBin 'Sample.dll'), $built.AddMinutes(-1))

            # a source file changed
            [IO.File]::SetLastWriteTimeUtc((Join-Path $repo 'src/Sample/Order.cs'), $built.AddMinutes(2))
            (& $check).Reason | Should -Be 'source changed after the last build (src/Sample/Order.cs)'
        }
    }
}

Describe 'Invoke-OctoTestRun' {
    BeforeEach {
        $script:ws = New-TestWorkspace
        Reset-TestDotnet
        $script:built = [DateTime]::new(2026, 11, 11, 8, 0, 0, [DateTimeKind]::Utc)
        foreach ($repo in @($ws.Repo, $ws.EnvRepo, $ws.InPlace)) {
            Set-TestSourceTimes $repo $built.AddHours(-1)
            Set-TestBuildOutput $repo 'Sample.UnitTests' 'Sample.UnitTests' $built
            Set-TestBuildOutput $repo 'Sample.IntegrationTests' 'Meshmakers.Sample.IntegrationTests' $built
        }
        # Never the developer's NuGet.Config.
        Mock -ModuleName OctoEnvironment Get-OctoUserNuGetConfigFile { Join-Path $TestDrive 'no-user-nuget.config' }
        # Never the real Docker engine: a canned engine with 16 GiB and a kind node that uses 6 GiB, and no limiter
        # thread (it would call the real docker CLI from another runspace).
        $script:DockerCalls = [System.Collections.Generic.List[string]]::new()
        $script:DockerUsed = '6GiB'
        Mock -ModuleName OctoTests Invoke-OctoDocker {
            $script:DockerCalls.Add($arguments -join ' ')
            if ($arguments[0] -eq 'info') { return [pscustomobject]@{ ExitCode = 0; Output = @('17179869184 16') } }
            if ($arguments[0] -eq 'stats') { return [pscustomobject]@{ ExitCode = 0; Output = @("kind-control-plane|$($script:DockerUsed) / 16GiB", 'octo-kind-s3-relay|572KiB / 16GiB') } }
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        $script:LimiterStarts = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName OctoTests Start-OctoDockerLimiter { $script:LimiterStarts.Add([pscustomobject]@{ Cpus = $Cpus; Memory = $Memory }); return [pscustomobject]@{ Fixture = $true } }
        Mock -ModuleName OctoTests Stop-OctoDockerLimiter { if ($Limiter) { return @([ordered]@{ id = 'abcdef012345'; name = 'fixture-mongo'; image = 'mongo:8'; success = $true; error = $null }) }; return @() }
        Mock -ModuleName OctoTests Invoke-OctoDotnetTest {
            $projectName = [IO.Path]::GetFileNameWithoutExtension($(if ($arguments[1] -eq '--project') { $arguments[2] } else { $arguments[1] }))
            $resultsDirectory = $arguments[[Array]::IndexOf($arguments, '--results-directory') + 1]
            $loggerIndex = [Array]::IndexOf($arguments, '--logger')
            $logger = if ($loggerIndex -ge 0) { $arguments[$loggerIndex + 1] } else { $null }
            # the TRX file name: VSTest logger, or the report option of a Microsoft.Testing.Platform application
            $trxName = if ($logger) { $logger -replace '^trx;LogFileName=', '' } else { $arguments[[Math]::Max([Array]::IndexOf($arguments, '--report-trx-filename'), [Array]::IndexOf($arguments, '--report-xunit-trx-filename')) + 1] }
            $filterIndex = [Array]::IndexOf($arguments, '--filter')
            $configIndex = [Array]::IndexOf($arguments, '-p:RestoreConfigFile')
            $restoreConfig = @($arguments | Where-Object { $_ -like '-p:RestoreConfigFile=*' }) | Select-Object -First 1
            $script:Calls.Add([pscustomobject]@{
                    Project           = $projectName
                    Arguments         = @($arguments)
                    NoBuild           = $arguments -contains '--no-build'
                    Filter            = if ($filterIndex -ge 0) { $arguments[$filterIndex + 1] } else { $null }
                    Logger            = $logger
                    LogFile           = $logFile
                    WorkingDirectory  = $workingDirectory
                    ContainerCpus     = $env:OCTO_TEST_CONTAINER_CPUS
                    ContainerMemory   = $env:OCTO_TEST_CONTAINER_MEMORY_BYTES
                    NugetPackages     = $env:NUGET_PACKAGES
                    RestoreSources    = $env:RestoreSources
                    LockOwner         = if (Test-Path $script:LockPath) { (Get-Content $script:LockPath -Raw | ConvertFrom-Json) } else { $null }
                    RestoreConfigFile = if ($restoreConfig) { $restoreConfig.Substring('-p:RestoreConfigFile='.Length) } else { $null }
                    RestoreConfigText = if ($restoreConfig) { Get-Content -LiteralPath $restoreConfig.Substring('-p:RestoreConfigFile='.Length) -Raw } else { $null }
                })
            $behaviour = $script:Behaviour[$projectName]
            if ($behaviour.Trx) {
                Copy-Item -Path (Join-Path $script:Fixtures $behaviour.Trx) -Destination (Join-Path $resultsDirectory $trxName)
            }
            if ($behaviour.Log) { Add-Content -LiteralPath $logFile -Value $behaviour.Log }
            return [int]$behaviour.ExitCode
        }
    }

    Context 'in a lane' {
        It 'runs every test project, the Docker-heavy one last and under the lock, and reports the failed tests' {
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo sample-services -lockPath $script:LockPath -Json)
            $doc.schemaVersion | Should -Be 1
            $doc.command | Should -Be 'Invoke-OctoTestRun'
            $doc.data.success | Should -BeFalse
            $doc.data.exitCode | Should -Be 1
            $global:LASTEXITCODE | Should -Be 1
            $doc.data.failedStep | Should -Be 'tests'
            $doc.data.failedProject | Should -Be 'Sample.IntegrationTests'
            $doc.data.repo | Should -Be 'octo-sample-services'
            $doc.data.environment | Should -BeNullOrEmpty
            $doc.data.lanePath | Should -Be $ws.Main
            $doc.data.totals.total | Should -Be 7
            $doc.data.totals.passed | Should -Be 4
            $doc.data.totals.failed | Should -Be 2
            $doc.data.totals.skipped | Should -Be 1

            @($script:Calls.Project) | Should -Be @('Sample.UnitTests', 'Sample.IntegrationTests')
            $script:Calls[0].LockOwner | Should -BeNullOrEmpty
            $script:Calls[1].LockOwner.pid | Should -Be $PID
            $script:Calls[1].LockOwner.repo | Should -Be 'octo-sample-services'
            @($script:Calls[1].LockOwner.projects) | Should -Be @('Sample.IntegrationTests')
            Test-Path $script:LockPath | Should -BeFalse
            $doc.data.lock.required | Should -BeTrue
            $doc.data.lock.acquired | Should -BeTrue
            $doc.data.lock.path | Should -Be $script:LockPath

            # dotnet test <csproj> -c DebugL --no-build --results-directory <run> --logger trx -nodeReuse:false
            $script:Calls[0].Arguments[0] | Should -Be 'test'
            $script:Calls[0].Arguments[1] | Should -Be (Join-Path $ws.Repo 'tests/Sample.UnitTests/Sample.UnitTests.csproj')
            ($script:Calls[0].Arguments -join ' ') | Should -Match '-c DebugL --no-build --results-directory .+ --logger trx;LogFileName=results\.trx -nodeReuse:false$'
            $script:Calls[0].Filter | Should -BeNullOrEmpty
            # a legacy lane: no lane environment
            $script:Calls[0].NugetPackages | Should -BeNullOrEmpty

            $unit = $doc.data.projects[0]
            $unit.project | Should -Be 'Sample.UnitTests'
            $unit.state | Should -Be 'passed'
            $unit.success | Should -BeTrue
            $unit.docker | Should -BeFalse
            $unit.noBuild | Should -BeTrue
            $unit.total | Should -Be 2
            @($unit.failedTests).Count | Should -Be 0

            $integration = $doc.data.projects[1]
            $integration.project | Should -Be 'Sample.IntegrationTests'
            $integration.state | Should -Be 'failed'
            $integration.success | Should -BeFalse
            $integration.exitCode | Should -Be 1
            $integration.docker | Should -BeTrue
            $integration.dockerReason | Should -Match 'Testcontainers\.MongoDb'
            $integration.total | Should -Be 5
            $integration.failed | Should -Be 2
            $integration.skipped | Should -Be 1
            $integration.truncated | Should -BeFalse
            @($integration.failedTests.name) | Should -Be @('Sample.Tests.OrderTests.Rejects_empty_order', 'Sample.Tests.PriceTests.Rounds')
            $integration.failedTests[0].message | Should -Match 'Expected order\.State to be Rejected'
            $integration.failedTests[0].stackFrame | Should -Match 'OrderTests\.cs:line 42'
            $integration.failedTests[1].displayName | Should -Be 'Sample.Tests.PriceTests.Rounds(value: 1.005, expected: 1.01)'

            # results below the lane's logFiles
            $resultsRoot = Join-Path $ws.Main 'logFiles/test-results/octo-sample-services'
            $doc.data.resultsPath | Should -Be $resultsRoot
            @($integration.trx).Count | Should -Be 1
            $integration.trx[0] | Should -BeLike (Join-Path $resultsRoot 'Sample.IntegrationTests/*/results.trx')
            Test-Path $integration.trx[0] | Should -BeTrue
            $integration.logFile | Should -BeLike (Join-Path $resultsRoot 'Sample.IntegrationTests/*/dotnet-test.log')
            Get-Content $integration.logFile -Raw | Should -Match 'Invoke-OctoTestRun: dotnet test '

            $last = Get-Content (Join-Path $resultsRoot 'Sample.IntegrationTests/last-result.json') -Raw | ConvertFrom-Json
            $last.schemaVersion | Should -Be 1
            $last.state | Should -Be 'failed'
            @($last.failedTests) | Should -Be @('Sample.Tests.OrderTests.Rejects_empty_order', 'Sample.Tests.PriceTests.Rounds')
            (Get-Content (Join-Path $resultsRoot 'Sample.UnitTests/last-result.json') -Raw | ConvertFrom-Json).state | Should -Be 'passed'
        }

        It 'runs one project with a filter and is green' {
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project UnitTests -filter 'FullyQualifiedName~OrderTests' -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeTrue
            $doc.data.exitCode | Should -Be 0
            $global:LASTEXITCODE | Should -Be 0
            $doc.data.failedStep | Should -BeNullOrEmpty
            $doc.data.filter | Should -Be 'FullyQualifiedName~OrderTests'
            $script:Calls.Count | Should -Be 1
            $script:Calls[0].Project | Should -Be 'Sample.UnitTests'
            $script:Calls[0].Filter | Should -Be 'FullyQualifiedName~OrderTests'
            $doc.data.lock.required | Should -BeFalse
            $doc.data.lock.acquired | Should -BeFalse
            @($doc.data.projects).Count | Should -Be 1
        }

        It 'builds when the build is not current and says why; -build overrides' {
            [IO.File]::SetLastWriteTimeUtc((Join-Path $ws.Repo 'src/Sample/Order.cs'), $built.AddMinutes(10))
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json)
            $script:Calls[0].NoBuild | Should -BeFalse
            $doc.data.projects[0].noBuild | Should -BeFalse
            $doc.data.projects[0].buildReason | Should -Be 'source changed after the last build (src/Sample/Order.cs)'

            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -build Never -lockPath $script:LockPath -Json)
            $script:Calls[0].NoBuild | Should -BeTrue
            $doc.data.projects[0].buildReason | Should -Be '-build Never'

            [IO.File]::SetLastWriteTimeUtc((Join-Path $ws.Repo 'src/Sample/Order.cs'), $built.AddHours(-1))
            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -build Always -lockPath $script:LockPath -Json)
            $script:Calls[0].NoBuild | Should -BeFalse
            $doc.data.projects[0].buildReason | Should -Be '-build Always'
        }

        It 'reruns only the failed tests of the last result, in several calls when the filter gets long' {
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -lockPath $script:LockPath -Json | Out-Null
            Reset-TestDotnet
            $script:Behaviour['Sample.IntegrationTests'] = @{ Trx = 'passed.trx'; ExitCode = 0 }

            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -rerunFailed -maxFilterLength 70 -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeTrue
            $doc.data.rerunFailed | Should -BeTrue
            # the unit project had no failed test: not run
            @($script:Calls.Project) | Should -Be @('Sample.IntegrationTests', 'Sample.IntegrationTests')
            $script:Calls[0].Filter | Should -Be 'FullyQualifiedName=Sample.Tests.OrderTests.Rejects_empty_order'
            $script:Calls[1].Filter | Should -Be 'FullyQualifiedName=Sample.Tests.PriceTests.Rounds'
            $script:Calls[0].Logger | Should -Be 'trx;LogFileName=results-1.trx'
            $script:Calls[1].Logger | Should -Be 'trx;LogFileName=results-2.trx'
            $unit = $doc.data.projects | Where-Object project -eq 'Sample.UnitTests'
            $unit.state | Should -Be 'skipped'
            $unit.note | Should -Be 'no failed test in the last result'
            $integration = $doc.data.projects | Where-Object project -eq 'Sample.IntegrationTests'
            $integration.rerunCount | Should -Be 2
            @($integration.filters).Count | Should -Be 2
            @($integration.trx).Count | Should -Be 2
            $integration.total | Should -Be 4
            $integration.state | Should -Be 'passed'

            # the rerun is the new last result: nothing is left to rerun
            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -rerunFailed -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeTrue
            $script:Calls.Count | Should -Be 0
            @($doc.data.projects.state | Sort-Object -Unique) | Should -Be @('skipped')
        }

        It 'combines -rerunFailed with -filter and only the first call of a chunked rerun may build' {
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -lockPath $script:LockPath -Json | Out-Null
            Reset-TestDotnet
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -rerunFailed -filter 'Category=Fast' -maxFilterLength 90 -build Always -lockPath $script:LockPath -Json | Out-Null
            $script:Calls.Count | Should -Be 2
            $script:Calls[0].Filter | Should -Be '(Category=Fast)&(FullyQualifiedName=Sample.Tests.OrderTests.Rejects_empty_order)'
            $script:Calls[0].NoBuild | Should -BeFalse
            $script:Calls[1].NoBuild | Should -BeTrue
        }

        It 'does not rerun with a filter the project cannot take, and keeps the last result' {
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -lockPath $script:LockPath -Json | Out-Null
            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -rerunFailed -filter '/*/*/OrderTests/*' -lockPath $script:LockPath -Json)
            $script:Calls.Count | Should -Be 0
            $doc.data.success | Should -BeFalse
            $doc.data.projects[0].state | Should -Be 'noMatch'
            $doc.data.projects[0].note | Should -Match 'FullyQualifiedName~ClassName'
            @((Get-Content (Join-Path $ws.Main 'logFiles/test-results/octo-sample-services/Sample.IntegrationTests/last-result.json') -Raw | ConvertFrom-Json).failedTests).Count | Should -Be 2
        }

        It 'refuses -rerunFailed without a previous result' {
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -rerunFailed -lockPath $script:LockPath -Json -ErrorAction SilentlyContinue)
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'preflight'
            $doc.data.error | Should -Match 'no previous result'
            $script:Calls.Count | Should -Be 0
        }

        It 'fails when a filter matches no test at all' {
            $script:Behaviour['Sample.UnitTests'] = @{ Trx = $null; ExitCode = 0 }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -filter 'FullyQualifiedName~Nope' -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'tests'
            $doc.data.error | Should -Match "the filter 'FullyQualifiedName~Nope' matches no test"
            $doc.data.projects[0].state | Should -Be 'noMatch'
            $doc.data.projects[0].success | Should -BeTrue
            $doc.data.projects[0].note | Should -Be 'no test matched the filter'
        }

        It 'reports a run without a TRX (broken build, crashed host) as an error with the log lines' {
            [IO.File]::SetLastWriteTimeUtc((Join-Path $ws.Repo 'src/Sample/Order.cs'), $built.AddMinutes(10))
            $script:Behaviour['Sample.UnitTests'] = @{ Trx = $null; ExitCode = 1; Log = 'fixture: error FIXTURE001: the fixture build broke' }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'build'
            $doc.data.projects[0].state | Should -Be 'error'
            @($doc.data.projects[0].errors) | Should -Contain 'fixture: error FIXTURE001: the fixture build broke'
            (Get-Content (Join-Path $ws.Main 'logFiles/test-results/octo-sample-services/Sample.UnitTests/last-result.json') -Raw | ConvertFrom-Json).state | Should -Be 'error'

            # -rerunFailed after such a run: nothing to rerun, and it says so
            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -rerunFailed -lockPath $script:LockPath -Json)
            $doc.data.projects[0].note | Should -Match 'produced no test result'
            $script:Calls.Count | Should -Be 0
        }

        It 'counts a run-level error (aborted test host) and lists at most -maxFailures failed tests' {
            $script:Behaviour['Sample.UnitTests'] = @{ Trx = 'aborted.trx'; ExitCode = 1 }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json)
            $doc.data.projects[0].state | Should -Be 'failed'
            $doc.data.projects[0].failed | Should -Be 2
            @($doc.data.projects[0].errors) | Should -Contain 'The fixture test host process exited before the run finished.'

            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -maxFailures 1 -lockPath $script:LockPath -Json)
            @($doc.data.projects[0].failedTests).Count | Should -Be 1
            $doc.data.projects[0].truncated | Should -BeTrue
            $doc.data.projects[0].failed | Should -Be 2
            # last-result.json still holds every failed test
            @((Get-Content (Join-Path $ws.Main 'logFiles/test-results/octo-sample-services/Sample.IntegrationTests/last-result.json') -Raw | ConvertFrom-Json).failedTests).Count | Should -Be 2
        }

        It 'keeps the newest 10 runs of a project' {
            $projectResults = Join-Path $ws.Main 'logFiles/test-results/octo-sample-services/Sample.UnitTests'
            1..12 | ForEach-Object { New-Item -ItemType Directory -Force -Path (Join-Path $projectResults ('20260101-0000{0:D2}-000-1' -f $_)) | Out-Null }
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json | Out-Null
            $runs = @(Get-ChildItem $projectResults -Directory | Sort-Object Name)
            $runs.Count | Should -Be 10
            $runs[0].Name | Should -Be '20260101-000004-000-1'
            Test-Path (Join-Path $projectResults 'last-result.json') | Should -BeTrue
        }

        It 'prints the failed tests first in the human output' {
            $lines = @(Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -lockPath $script:LockPath -ErrorAction SilentlyContinue 6>&1 | ForEach-Object { "$_" })
            $failedAt = [Array]::IndexOf($lines, 'Failed tests:')
            $summaryAt = [Array]::IndexOf($lines, ($lines | Where-Object { $_ -like 'Summary (Invoke-OctoTestRun*' } | Select-Object -First 1))
            $failedAt | Should -BeGreaterThan 0
            $summaryAt | Should -BeGreaterThan $failedAt
            ($lines -join "`n") | Should -Match 'x Sample\.Tests\.OrderTests\.Rejects_empty_order'
            ($lines -join "`n") | Should -Match 'Expected order\.State to be Rejected'
            ($lines -join "`n") | Should -Match 'Total: 7 test\(s\), 4 passed, 2 failed, 1 skipped'
            $global:LASTEXITCODE | Should -Be 1
        }
    }

    Context 'machine-wide lock' {
        It 'fails with failedStep lock when another run holds it, after the projects that need no Docker ran' {
            $other = Enter-OctoTestLock -LockPath $script:LockPath -TimeoutSeconds 0 -Run @{ command = 'Invoke-OctoTestRun'; environment = 'other-env'; repo = 'octo-other'; projects = @('Other.IntegrationTests') }
            $events = Join-Path $TestDrive 'events/lock.jsonl'
            if (Test-Path $events) { Remove-Item $events }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -lockPath $script:LockPath -lockTimeoutSeconds 1 -lockPollMilliseconds 50 -EventsFile $events -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'lock'
            $doc.data.error | Should -Match 'held by pid'
            $doc.data.error | Should -Match 'octo-other'
            $doc.data.lock.acquired | Should -BeFalse
            $doc.data.lock.blockedBy.pid | Should -Be $PID
            $doc.data.lock.blockedBy.environment | Should -Be 'other-env'
            @($script:Calls.Project) | Should -Be @('Sample.UnitTests')
            ($doc.data.projects | Where-Object project -eq 'Sample.UnitTests').state | Should -Be 'passed'
            ($doc.data.projects | Where-Object project -eq 'Sample.IntegrationTests').state | Should -Be 'notRun'
            # the other owner's lock is untouched
            (Get-Content $script:LockPath -Raw | ConvertFrom-Json).id | Should -Be $other.Id

            $names = @(Get-Content $events | ForEach-Object { ($_ | ConvertFrom-Json).event })
            $names | Should -Be @('plan', 'testProjectStart', 'testProjectDone', 'lockWait', 'done')
            $wait = Get-Content $events | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq 'lockWait'
            $wait.owner.repo | Should -Be 'octo-other'
            $wait.timeoutSeconds | Should -Be 1
            (Get-Content $events | Select-Object -Last 1 | ConvertFrom-Json).failedStep | Should -Be 'lock'
        }

        It 'takes no lock with -dockerLock Never and locks every project with -dockerLock Always' {
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -dockerLock Never -lockPath $script:LockPath -Json | Out-Null
            @($script:Calls | Where-Object { $null -ne $_.LockOwner }).Count | Should -Be 0

            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -dockerLock Always -lockPath $script:LockPath -Json)
            $script:Calls[0].LockOwner.pid | Should -Be $PID
            $doc.data.projects[0].docker | Should -BeTrue
            $doc.data.projects[0].dockerReason | Should -Be '-dockerLock Always'
            Test-Path $script:LockPath | Should -BeFalse
        }

        It 'releases the lock when the run throws' {
            Mock -ModuleName OctoTests Invoke-OctoDotnetTest { throw 'fixture failure' }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.error | Should -Match 'fixture failure'
            Test-Path $script:LockPath | Should -BeFalse
        }
    }

    Context 'Docker engine shared with the local stack (AB#8835)' {
        It 'checks the free memory of the engine with the lock held, limits the test containers and reports both' {
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -lockPath $script:LockPath -Json)
            $docker = $doc.data.docker
            $docker.required | Should -BeTrue
            $docker.checked | Should -BeTrue
            $docker.check | Should -Be 'ok'
            $docker.memoryGiB | Should -Be 16
            $docker.cpus | Should -Be 16
            $docker.usedGiB | Should -Be 6
            $docker.freeGiB | Should -Be 10
            $docker.minFreeGiB | Should -Be 3
            $docker.containers[0].name | Should -Be 'kind-control-plane'
            $docker.limits.cpus | Should -Be 4
            $docker.limits.memory | Should -Be '4g'
            @($docker.limited.name) | Should -Be @('fixture-mongo')
            $script:LimiterStarts.Count | Should -Be 1
            $script:LimiterStarts[0].Cpus | Should -Be 4
            $script:LimiterStarts[0].Memory | Should -Be '4g'
            # the limits are also handed to the test process, for fixtures that set them at creation
            $integration = $script:Calls | Where-Object Project -eq 'Sample.IntegrationTests'
            $integration.ContainerCpus | Should -Be '4'
            $integration.ContainerMemory | Should -Be '4294967296'
            $env:OCTO_TEST_CONTAINER_CPUS | Should -BeNullOrEmpty
        }

        It 'refuses the Docker-heavy projects when the engine has too little free memory; the others still run' {
            $script:DockerUsed = '14.2GiB'
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'docker'
            $doc.data.error | Should -Match '1[.,]8 GiB of 16 GiB free'
            $doc.data.error | Should -Match 'kind-control-plane 14[.,]2 GiB'
            $doc.data.error | Should -Match '-dockerCheck Warn'
            $doc.data.docker.check | Should -Be 'refused'
            @($script:Calls.Project) | Should -Be @('Sample.UnitTests')
            ($doc.data.projects | Where-Object project -eq 'Sample.IntegrationTests').state | Should -Be 'notRun'
            ($doc.data.projects | Where-Object project -eq 'Sample.IntegrationTests').note | Should -Match 'too little free memory'
            $script:LimiterStarts.Count | Should -Be 0
            Test-Path $script:LockPath | Should -BeFalse
        }

        It 'only warns with -dockerCheck Warn, takes -minDockerFreeMemoryGiB, and asks nothing with -dockerCheck Off' {
            $script:DockerUsed = '14.2GiB'
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -dockerCheck Warn -lockPath $script:LockPath -Json)
            $doc.data.docker.check | Should -Be 'warned'
            $doc.data.docker.message | Should -Match 'starve the local stack'
            @($script:Calls.Project) | Should -Be @('Sample.UnitTests', 'Sample.IntegrationTests')

            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -minDockerFreeMemoryGiB 1 -lockPath $script:LockPath -Json)
            $doc.data.docker.check | Should -Be 'ok'

            Reset-TestDotnet
            $script:DockerCalls.Clear()
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -dockerCheck Off -dockerCpus 0 -dockerMemory '' -lockPath $script:LockPath -Json)
            $doc.data.docker.check | Should -Be 'off'
            $doc.data.docker.checked | Should -BeFalse
            $doc.data.docker.limits.cpus | Should -BeNullOrEmpty
            $script:DockerCalls.Count | Should -Be 0
            @($script:Calls.Project) | Should -Be @('Sample.UnitTests', 'Sample.IntegrationTests')
            ($script:Calls | Where-Object Project -eq 'Sample.IntegrationTests').ContainerCpus | Should -BeNullOrEmpty
        }

        It 'runs when docker cannot be asked, and never asks for a run without Docker-heavy projects' {
            Mock -ModuleName OctoTests Invoke-OctoDocker { [pscustomobject]@{ ExitCode = 127; Output = @('the docker command is not on PATH') } }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -lockPath $script:LockPath -Json)
            $doc.data.docker.check | Should -Be 'unavailable'
            $doc.data.docker.message | Should -Match 'not on PATH'
            @($script:Calls.Project) | Should -Be @('Sample.UnitTests', 'Sample.IntegrationTests')

            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json)
            $doc.data.docker.required | Should -BeFalse
            $doc.data.docker.checked | Should -BeFalse
            Should -Invoke -ModuleName OctoTests Invoke-OctoDocker -Times 1 -Exactly   # only the first run asked (docker info)
        }

        It 'refuses a -dockerMemory that is no size' {
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -dockerMemory 'lots' -lockPath $script:LockPath -Json -ErrorAction SilentlyContinue)
            $doc.data.failedStep | Should -Be 'preflight'
            $doc.data.error | Should -Match "-dockerMemory 'lots' is no size"
        }
    }

    Context 'in a feature environment' {
        It 'runs with the environment isolation and writes the results below the environment' {
            $doc = Get-Doc (Invoke-OctoTestRun -env feat-a -repo sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeTrue
            $doc.data.environment | Should -Be 'feat-a'
            $doc.data.lanePath | Should -Be $ws.EnvPath
            $doc.data.repoPath | Should -Be $ws.EnvRepo
            $doc.data.inPlace | Should -BeFalse
            $doc.data.lane.isolated | Should -BeTrue
            $script:Calls[0].Arguments[1] | Should -Be (Join-Path $ws.EnvRepo 'tests/Sample.UnitTests/Sample.UnitTests.csproj')
            $script:Calls[0].NugetPackages | Should -Be (Join-Path $ws.EnvPath '.nuget-packages')
            $script:Calls[0].RestoreSources | Should -Be "$(Join-Path $ws.EnvPath 'nuget');https://api.nuget.org/v3/index.json"
            # the session's environment is restored
            $env:NUGET_PACKAGES | Should -BeNullOrEmpty
            $env:RestoreSources | Should -BeNullOrEmpty
            $doc.data.projects[0].trx[0] | Should -BeLike (Join-Path $ws.EnvPath 'logFiles/test-results/octo-sample-services/Sample.UnitTests/*/results.trx')
            # nothing in the base lane
            Test-Path (Join-Path $ws.Main 'logFiles') | Should -BeFalse
        }

        It 'passes the global properties of an in-place worktree and keeps credentials off the command line' {
            [IO.File]::SetLastWriteTimeUtc((Join-Path $ws.InPlace 'Directory.Build.props'), $built.AddHours(-1))
            $doc = Get-Doc (Invoke-OctoTestRun -env feat-a -repo octo-other-services -project Sample.UnitTests -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeTrue
            $doc.data.inPlace | Should -BeTrue
            $doc.data.repoPath | Should -Be $ws.InPlace
            $call = $script:Calls[0]
            $feed = Join-Path $ws.EnvPath 'nuget'
            $call.Arguments | Should -Contain "-p:RestorePackagesPath=$(Join-Path $ws.EnvPath '.nuget-packages')"
            $call.Arguments | Should -Contain "-p:OctoLocalCatalogRootPath=$(Join-Path $ws.EnvPath '.octo/local-catalog')"
            $call.Arguments | Should -Contain "-p:RestoreSources=$feed%3Bhttps://feed.example.invalid/v3/index.json"
            ($call.Arguments -join ' ') | Should -Not -Match 'feedsecret'
            # credentials only in the owner-only config, which is gone after the run
            $call.RestoreConfigText | Should -Match 'feedsecret'
            Test-Path $call.RestoreConfigFile | Should -BeFalse
            Test-Path (Split-Path -Parent $call.RestoreConfigFile) | Should -BeFalse
            # neither the JSON document nor the log shows them
            ($doc | ConvertTo-Json -Depth 12) | Should -Not -Match 'feedsecret'
            Get-Content $doc.data.projects[0].logFile -Raw | Should -Not -Match 'feedsecret'
            # results below the environment, not next to the in-place worktree
            $doc.data.projects[0].trx[0] | Should -BeLike (Join-Path $ws.EnvPath 'logFiles/test-results/octo-other-services/*')
        }

        It 'refuses a repository that is not part of the environment and an unknown environment' {
            $doc = Get-Doc (Invoke-OctoTestRun -env feat-a -repo octo-nope -lockPath $script:LockPath -Json -ErrorAction SilentlyContinue)
            $doc.data.success | Should -BeFalse
            $doc.data.error | Should -Match 'not part of environment feat-a'
            $doc.data.error | Should -Match '-branch branches/main'
            (Get-Doc (Invoke-OctoTestRun -env nope-env -repo octo-sample-services -lockPath $script:LockPath -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'Environment nope-env does not exist'
        }
    }

    Context 'Microsoft.Testing.Platform, filters across projects and passed tests (AB#8832)' {
        BeforeEach {
            # A repository like octo-bot-services: global.json selects Microsoft.Testing.Platform, a TUnit unit test
            # project and a TUnit project with Testcontainers.
            $script:mtpRepo = Join-Path $ws.Main 'octo-mtp-services'
            New-TestCsproj (Join-Path $mtpRepo 'src/Jobs') 'Jobs'
            New-TestCsproj (Join-Path $mtpRepo 'tests/Jobs.Tests') 'Jobs.Tests' -packages 'TUnit'
            New-TestCsproj (Join-Path $mtpRepo 'tests/Jobs.IntegrationTests') 'Jobs.IntegrationTests' -packages 'TUnit', 'Testcontainers.MongoDb' -isTestProject
            Set-Content -Path (Join-Path $mtpRepo 'global.json') -Value '{ "test": { "runner": "Microsoft.Testing.Platform" } }'
            Set-TestSourceTimes $mtpRepo $built.AddHours(-1)
            Set-TestBuildOutput $mtpRepo 'Jobs.Tests' 'Jobs.Tests' $built
            Set-TestBuildOutput $mtpRepo 'Jobs.IntegrationTests' 'Jobs.IntegrationTests' $built
            $script:Behaviour['Jobs.Tests'] = @{ Trx = 'tunit-mixed.trx'; ExitCode = 2 }
            $script:Behaviour['Jobs.IntegrationTests'] = @{ Trx = 'passed.trx'; ExitCode = 0 }
        }

        It 'runs a Microsoft.Testing.Platform project with dotnet test --project from the repository folder and reads its TRX' {
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -project Jobs.Tests -lockPath $script:LockPath -Json)
            $call = $script:Calls[0]
            $call.Arguments[0..2] | Should -Be @('test', '--project', (Join-Path $mtpRepo 'tests/Jobs.Tests/Jobs.Tests.csproj'))
            ($call.Arguments -join ' ') | Should -Match ' -c DebugL --no-build --results-directory \S+ -- --report-trx --report-trx-filename results\.trx$'
            $call.Arguments | Should -Not -Contain '-nodeReuse:false'
            $call.Arguments | Should -Not -Contain '--logger'
            # global.json decides the runner: dotnet must start in the repository
            $call.WorkingDirectory | Should -Be $mtpRepo

            $project = $doc.data.projects[0]
            $project.runner | Should -Be 'mtp'
            $project.state | Should -Be 'failed'
            $project.total | Should -Be 6
            $project.failed | Should -Be 3
            @($project.failedTests.name) | Should -Be @('Mtp.Tests.Orders.OrderTests.Fails', 'Mtp.Tests.Orders.OrderTests.Rounds', 'Mtp.Tests.Orders.PriceTests.Also_fails')
            $project.failedTests[1].displayName | Should -Be 'Rounds(1, 3)'
            $project.failedTests[0].message | Should -Be 'AssertionException: Expected to be 2'
            $project.failedTests[0].stackFrame | Should -Match 'Tests\.cs:line 5'
            # the platform's echo of its exit code is no run error
            @($project.errors).Count | Should -Be 0
            # VSTest projects of another repository still get the VSTest call, also from their repository folder
            Reset-TestDotnet
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json | Out-Null
            $script:Calls[0].Arguments[1] | Should -BeLike '*Sample.UnitTests.csproj'
            $script:Calls[0].Arguments | Should -Contain '--logger'
            $script:Calls[0].WorkingDirectory | Should -Be $ws.Repo
        }

        It 'reruns the failed tests of a TUnit project with one tree-node filter per class' {
            Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -project Jobs.Tests -lockPath $script:LockPath -Json | Out-Null
            Reset-TestDotnet
            $script:Behaviour['Jobs.Tests'] = @{ Trx = 'passed.trx'; ExitCode = 0 }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -project Jobs.Tests -rerunFailed -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeTrue
            $script:Calls.Count | Should -Be 2
            ($script:Calls[0].Arguments -join ' ') | Should -Match ' -- --report-trx --report-trx-filename results-1\.trx --treenode-filter /\*/Mtp\.Tests\.Orders/OrderTests/\(Fails\|Rounds\)$'
            ($script:Calls[1].Arguments -join ' ') | Should -Match ' --report-trx-filename results-2\.trx --treenode-filter /\*/Mtp\.Tests\.Orders/PriceTests/\(Also_fails\)$'
            $doc.data.projects[0].rerunCount | Should -Be 3
            @($doc.data.projects[0].filters) | Should -Be @('/*/Mtp.Tests.Orders/OrderTests/(Fails|Rounds)', '/*/Mtp.Tests.Orders/PriceTests/(Also_fails)')
        }

        It 'never reports a project green that ran no test without a filter (exit code 8 of the platform, or an empty report)' {
            $script:Behaviour['Jobs.Tests'] = @{ Trx = 'empty.trx'; ExitCode = 8; Log = 'fixture: Zero tests ran' }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -project Jobs.Tests -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'tests'
            $doc.data.failedProject | Should -Be 'Jobs.Tests'
            $doc.data.projects[0].state | Should -Be 'noTests'
            $doc.data.projects[0].success | Should -BeFalse
            $doc.data.projects[0].note | Should -Be 'the project ran no test although no filter was given'
            $global:LASTEXITCODE | Should -Be 1

            # the same for a VSTest project whose run wrote no result at all
            Reset-TestDotnet
            $script:Behaviour['Sample.UnitTests'] = @{ Trx = $null; ExitCode = 0 }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.UnitTests -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.projects[0].state | Should -Be 'noTests'
        }

        It 'with a filter, a project without a match is noMatch, not a failure - the run is green when another project matched' {
            $script:Behaviour['Jobs.Tests'] = @{ Trx = 'empty.trx'; ExitCode = 8 }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -filter '/*/*/OrderTests/*' -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeTrue
            $doc.data.failedStep | Should -BeNullOrEmpty
            $unit = $doc.data.projects | Where-Object project -eq 'Jobs.Tests'
            $unit.state | Should -Be 'noMatch'
            $unit.success | Should -BeTrue
            $unit.note | Should -Be 'no test matched the filter'
            ($doc.data.projects | Where-Object project -eq 'Jobs.IntegrationTests').state | Should -Be 'passed'
            ($script:Calls[0].Arguments -join ' ') | Should -Match ' --treenode-filter /\*/\*/OrderTests/\*$'

            # nothing matched anywhere: the run fails and names the projects
            Reset-TestDotnet
            $script:Behaviour['Jobs.Tests'] = @{ Trx = 'empty.trx'; ExitCode = 8 }
            $script:Behaviour['Jobs.IntegrationTests'] = @{ Trx = 'empty.trx'; ExitCode = 8 }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -filter '/*/*/Nope/*' -lockPath $script:LockPath -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.error | Should -Match "the filter '/\*/\*/Nope/\*' matches no test in Jobs\.Tests, Jobs\.IntegrationTests"
            @($doc.data.projects.state | Sort-Object -Unique) | Should -Be @('noMatch')
        }

        It 'does not start a project whose runner cannot take the form of the filter, and says which form it takes' {
            $events = Join-Path $TestDrive 'events/mismatch.jsonl'
            if (Test-Path $events) { Remove-Item $events }
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -filter 'FullyQualifiedName~Order' -lockPath $script:LockPath -EventsFile $events -Json)
            $script:Calls.Count | Should -Be 0
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'tests'
            $doc.data.error | Should -Match 'tree-node filter such as /\*/\*/ClassName/\*'
            @($doc.data.projects.state | Sort-Object -Unique) | Should -Be @('noMatch')
            $doc.data.projects[0].note | Should -Match 'TUnit on Microsoft\.Testing\.Platform'
            # no lock for a Docker project that is not run
            $doc.data.lock.required | Should -BeFalse
            @(Get-Content $events | ForEach-Object { ($_ | ConvertFrom-Json).event }) | Should -Be @('plan', 'done')

            $plan = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-mtp-services -filter 'FullyQualifiedName~Order' -lockPath $script:LockPath -WhatIf -Json)
            $plan.data.projects[0].runner | Should -Be 'mtp'
            $plan.data.projects[0].noMatch | Should -Match 'tree-node filter'
        }

        It 'lists the passed tests on request, bounded by -maxPassed' {
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -includePassed -lockPath $script:LockPath -Json)
            $project = $doc.data.projects[0]
            @($project.passedTests) | Should -Be @('Sample.Tests.OrderTests.Creates_order', 'Sample.Tests.PriceTests.Rounds')
            $project.passedTruncated | Should -BeFalse

            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -includePassed -maxPassed 1 -lockPath $script:LockPath -Json)
            @($doc.data.projects[0].passedTests) | Should -Be @('Sample.Tests.OrderTests.Creates_order')
            $doc.data.projects[0].passedTruncated | Should -BeTrue
            $doc.data.projects[0].passed | Should -Be 2

            # not asked for: no names
            Reset-TestDotnet
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Sample.IntegrationTests -lockPath $script:LockPath -Json)
            @($doc.data.projects[0].passedTests).Count | Should -Be 0
            $doc.data.projects[0].passedTruncated | Should -BeFalse
        }
    }

    Context 'preflight, plan and events' {
        It 'refuses -env together with -branch, neither of them, an unknown repository, an unknown project and a repository without tests' {
            (Get-Doc (Invoke-OctoTestRun -env feat-a -branch branches/main -repo octo-sample-services -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'either -env or -branch'
            (Get-Doc (Invoke-OctoTestRun -repo octo-sample-services -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'Pass -env'
            (Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-nope -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'not part of the build order'
            (Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -project Nope -Json -ErrorAction SilentlyContinue)).data.error | Should -Match "Test project 'Nope' not found"
            New-TestCsproj (Join-Path $ws.Main 'octo-plain/src/Plain') 'Plain'
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-plain -Json -ErrorAction SilentlyContinue)
            $doc.data.error | Should -Match 'has no test project'
            $doc.data.failedStep | Should -Be 'preflight'
            $global:LASTEXITCODE | Should -Be 1
            $script:Calls.Count | Should -Be 0
        }

        It 'reports a lane without repositories, a folder outside the build order and a broken manifest as clear preflight errors' {
            $events = Join-Path $TestDrive 'events/preflight-order.jsonl'
            if (Test-Path $events) { Remove-Item $events }
            # a lane whose only folder is not named octo-* / mm-*: the build order is empty
            New-TestRepo (Join-Path $ws.Root 'branches/tools/sample-tools') | Out-Null
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/tools -repo sample-tools -EventsFile $events -Json -ErrorAction SilentlyContinue)
            $doc.data.success | Should -BeFalse
            $doc.data.failedStep | Should -Be 'preflight'
            $doc.data.error | Should -Match 'holds no repository \(no folder named octo-\* or mm-\*\)'
            $doc.data.error | Should -Match 'sample-tools exists, but only folders named octo-\* or mm-\*'
            $doc.data.error | Should -Not -Match 'Cannot bind'
            $global:LASTEXITCODE | Should -Be 1
            $records = @(Get-Content $events | ForEach-Object { $_ | ConvertFrom-Json })
            @($records.event) | Should -Be @('done')
            $records[0].failedStep | Should -Be 'preflight'

            # the same folder next to real repositories
            New-TestRepo (Join-Path $ws.Main 'sample-tools') | Out-Null
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo sample-tools -Json -ErrorAction SilentlyContinue)
            $doc.data.failedStep | Should -Be 'preflight'
            $doc.data.error | Should -Match 'not part of the build order of'
            $doc.data.error | Should -Match 'only folders named octo-\* or mm-\*'

            # a lane that does not exist, an environment without repositories or with an entry without path
            (Get-Doc (Invoke-OctoTestRun -branch branches/nope -repo octo-sample-services -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'does not exist'
            $manifestPath = Join-Path $ws.EnvPath '.octo/environment.json'
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
            $manifest['repos'][0]['path'] = $null
            Set-Content -Path $manifestPath -Value (ConvertTo-Json -InputObject $manifest -Depth 6)
            $doc = Get-Doc (Invoke-OctoTestRun -env feat-a -repo octo-sample-services -Json -ErrorAction SilentlyContinue)
            $doc.data.error | Should -Match 'lists a repository without name or path'
            $doc.data.error | Should -Not -Match 'Cannot bind'
            $manifest['repos'] = @()
            Set-Content -Path $manifestPath -Value (ConvertTo-Json -InputObject $manifest -Depth 6)
            (Get-Doc (Invoke-OctoTestRun -env feat-a -repo octo-sample-services -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'holds no repository'

            $script:Calls.Count | Should -Be 0
        }

        It 'reports a missing $rootPath as a preflight error' {
            $saved = $global:rootPath
            try {
                Remove-Variable -Name rootPath -Scope Global
                (Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'rootPath is not set'
                (Get-Doc (Invoke-OctoTestRun -env feat-a -repo octo-sample-services -Json -ErrorAction SilentlyContinue)).data.error | Should -Match 'rootPath is not set'
            }
            finally { $global:rootPath = $saved }
        }

        It '-WhatIf plans without running, locking or writing events' {
            $events = Join-Path $TestDrive 'events/whatif.jsonl'
            [IO.File]::SetLastWriteTimeUtc((Join-Path $ws.Repo 'src/Sample/Order.cs'), $built.AddMinutes(10))
            $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -filter 'Category=Fast' -lockPath $script:LockPath -EventsFile $events -WhatIf -Json)
            $doc.data.whatIf | Should -BeTrue
            $doc.data.repo | Should -Be 'octo-sample-services'
            $doc.data.lock.required | Should -BeTrue
            $doc.data.lock.path | Should -Be $script:LockPath
            @($doc.data.projects.project) | Should -Be @('Sample.UnitTests', 'Sample.IntegrationTests')
            $doc.data.projects[0].noBuild | Should -BeFalse
            $doc.data.projects[0].buildReason | Should -Match 'source changed'
            $doc.data.projects[1].docker | Should -BeTrue
            @($doc.data.projects[0].filters) | Should -Be @('Category=Fast')
            $script:Calls.Count | Should -Be 0
            Test-Path $events | Should -BeFalse
            Test-Path $script:LockPath | Should -BeFalse
            Test-Path (Join-Path $ws.Main 'logFiles') | Should -BeFalse
        }

        It 'writes the progress events of a run' {
            $events = Join-Path $TestDrive 'events/run.jsonl'
            if (Test-Path $events) { Remove-Item $events }
            Invoke-OctoTestRun -branch branches/main -repo octo-sample-services -lockPath $script:LockPath -EventsFile $events -Json | Out-Null
            $records = @(Get-Content $events | ForEach-Object { $_ | ConvertFrom-Json })
            @($records.event) | Should -Be @('plan', 'testProjectStart', 'testProjectDone', 'lockAcquired', 'testProjectStart', 'testProjectDone', 'lockReleased', 'done')
            @($records.command | Sort-Object -Unique) | Should -Be @('Invoke-OctoTestRun')
            @($records.schemaVersion | Sort-Object -Unique) | Should -Be @(1)

            $plan = $records[0]
            $plan.repo | Should -Be 'octo-sample-services'
            $plan.count | Should -Be 2
            @($plan.projects.project) | Should -Be @('Sample.UnitTests', 'Sample.IntegrationTests')
            $plan.projects[1].docker | Should -BeTrue

            $start = $records[4]
            $start.project | Should -Be 'Sample.IntegrationTests'
            $start.index | Should -Be 2
            $start.count | Should -Be 2
            $start.docker | Should -BeTrue
            $start.noBuild | Should -BeTrue

            $projectDone = $records[5]
            $projectDone.success | Should -BeFalse
            $projectDone.state | Should -Be 'failed'
            $projectDone.total | Should -Be 5
            $projectDone.failed | Should -Be 2
            $projectDone.seconds | Should -BeGreaterOrEqual 0
            @($projectDone.trx).Count | Should -Be 1
            $projectDone.logFile | Should -BeLike '*dotnet-test.log'

            $done = $records[-1]
            $done.success | Should -BeFalse
            $done.failedRepo | Should -Be 'octo-sample-services'
            $done.failedProject | Should -Be 'Sample.IntegrationTests'
            $done.failedStep | Should -Be 'tests'
            $done.total | Should -Be 7
            $done.failed | Should -Be 2
            $done.elapsedSeconds | Should -BeGreaterOrEqual 0
        }

        It 'writes only done for a run that stops in the preflight' {
            $events = Join-Path $TestDrive 'events/preflight.jsonl'
            if (Test-Path $events) { Remove-Item $events }
            Invoke-OctoTestRun -branch branches/main -repo octo-nope -EventsFile $events -Json -ErrorAction SilentlyContinue | Out-Null
            $records = @(Get-Content $events | ForEach-Object { $_ | ConvertFrom-Json })
            @($records.event) | Should -Be @('done')
            $records[0].success | Should -BeFalse
            $records[0].failedStep | Should -Be 'preflight'
        }
    }
}
