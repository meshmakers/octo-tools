#Requires -Modules Pester
<#
    Pester tests for the build event file (-EventsFile) of Invoke-Build, Invoke-BuildRange and
    Invoke-BuildAll, and for its writer Write-OctoBuildEvent (OctoJsonOutput.psm1).

    Everything runs against a fake checkout in TestDrive: no dotnet process is started (dotnet, the
    range build step, Compile-Repo and Invoke-KillDotnet are mocked), the real NuGet folders and the
    real ~/.nuget/packages cache are never touched.

    Run:  Invoke-Pester ./tests/BuildEvents.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Get-OctoLaneBuildSettings.psm1') -Force
    Import-Module (Join-Path $modules 'OctoBuildOrder.psm1') -Force
    Import-Module (Join-Path $modules 'Copy-NuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-KillDotnet.psm1') -Force
    Import-Module (Join-Path $modules 'Remove-GlobalNuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-Build.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-BuildAll.psm1') -Force
    Import-Module (Join-Path $modules 'Stop-Octo.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-Publish.psm1') -Force
    Import-Module (Join-Path $modules 'Sync-OctoCkIntermediateVersions.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-BuildRange.psm1') -Force

    function New-EventsCheckout {
        $root = Join-Path $TestDrive 'meshmakers'
        if (Test-Path $root) { Remove-Item $root -Recurse -Force }
        $checkout = Join-Path $root 'main'
        foreach ($name in @('octo-construction-kit-engine', 'octo-sdk', 'octo-common-services')) {
            $repo = Join-Path $checkout $name
            New-Item -ItemType Directory -Force -Path (Join-Path $repo 'bin/DebugL') | Out-Null
            $lines = @(
                'Microsoft Visual Studio Solution File, Format Version 12.00',
                "Project(""{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}"") = ""$name.Lib"", ""src\$name.Lib\$name.Lib.csproj"", ""{$([guid]::NewGuid().ToString().ToUpper())}""",
                'EndProject'
            )
            Set-Content -Path (Join-Path $repo "$name.sln") -Value $lines
        }
        New-Item -ItemType Directory -Force -Path (Join-Path $checkout 'nuget') | Out-Null
        $cache = Join-Path $TestDrive 'nuget-cache'
        if (Test-Path $cache) { Remove-Item $cache -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $cache 'meshmakers.octo.runtime.engine/999.0.0') | Out-Null
        Set-Content -Path $script:FakeNuGetConfig -Value "<configuration><packageSources><add key=""local-nuget"" value=""$(Join-Path $checkout 'nuget')"" /></packageSources></configuration>"
        $global:rootPath = $root
        $global:GLOBALNUGETPACKAGESPATH = $cache
        return [pscustomobject]@{ Root = $root; Checkout = $checkout; Cache = $cache }
    }

    function Read-Events([string]$path) {
        return @(Get-Content -Path $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    }

    # Drops every duration and timestamp so two runs can be compared.
    function ConvertTo-ComparableJson([string]$json) {
        return ($json -replace '"\w*[Ss]econds":\s*[-0-9.Ee+]+,?', '' -replace '"timestamp":\s*"[^"]*",?', '')
    }

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
}

Describe 'Write-OctoBuildEvent' {
    It 'appends one compact JSON line with the envelope first, UTF-8 without BOM' {
        $file = Join-Path $TestDrive 'writer/sub/events.jsonl'
        Write-OctoBuildEvent -Path $file -Command 'Invoke-BuildRange' -Event 'phase' -Data ([ordered]@{ repo = 'octo-sdk'; phase = 'build' })
        Write-OctoBuildEvent -Path $file -Command 'Invoke-BuildRange' -Event 'done' -Data ([ordered]@{ success = $true })

        $lines = @(Get-Content -Path $file)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '^\{"schemaVersion":1,"ts":"[^"]+","command":"Invoke-BuildRange","event":"phase","repo":"octo-sdk","phase":"build"\}$'
        $bytes = [IO.File]::ReadAllBytes($file)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $lines[0] | Should -Match '"ts":"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+Z"'
    }

    It 'is a no-op without a path and warns instead of throwing on IO errors' {
        { Write-OctoBuildEvent -Path '' -Event 'done' } | Should -Not -Throw
        $folder = Join-Path $TestDrive 'a-folder'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        { Write-OctoBuildEvent -Path $folder -Command 'x' -Event 'done' -WarningVariable warnings -WarningAction SilentlyContinue } | Should -Not -Throw
        Write-OctoBuildEvent -Path $folder -Command 'x' -Event 'done' -WarningVariable warnings -WarningAction SilentlyContinue
        "$warnings" | Should -Match "Could not write build event 'done'"
    }
}

Describe 'Invoke-BuildRange -EventsFile' {
    BeforeEach {
        $script:fake = New-EventsCheckout
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid()).jsonl"
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            if ($entry.Name -eq 'octo-construction-kit-engine') {
                Set-Content (Join-Path $entry.Path 'bin/DebugL/Meshmakers.Octo.Runtime.Engine.999.0.0.nupkg') 'fresh'
            }
            [pscustomobject]@{ Success = $true; LogFile = (Join-Path $entry.Path 'Invoke-Build.log') }
        }
    }

    It 'writes plan, per-repository repoStart/phase/repoDone and done in order' {
        Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -EventsFile $events -Json | Out-Null

        $all = Read-Events $events
        @($all.event) | Should -Be @('plan',
            'repoStart', 'phase', 'phase', 'phase', 'repoDone',
            'repoStart', 'phase', 'phase', 'phase', 'repoDone',
            'done')
        @($all | Where-Object event -eq 'phase' | ForEach-Object { "$($_.repo):$($_.phase)" }) | Should -Be @(
            'octo-construction-kit-engine:build', 'octo-construction-kit-engine:packages', 'octo-construction-kit-engine:purge',
            'octo-sdk:build', 'octo-sdk:packages', 'octo-sdk:purge')
        $all | ForEach-Object { $_.schemaVersion | Should -Be 1; $_.command | Should -Be 'Invoke-BuildRange'; $_.ts | Should -Not -BeNullOrEmpty }

        $plan = $all[0]
        $plan.count | Should -Be 2
        @($plan.repos.repo) | Should -Be @('octo-construction-kit-engine', 'octo-sdk')
        @($plan.repos.mode) | Should -Be @('dotnet', 'dotnet')

        $start = $all[1]
        $start.repo | Should -Be 'octo-construction-kit-engine'
        $start.index | Should -Be 1
        $start.count | Should -Be 2

        $repoDone = @($all | Where-Object event -eq 'repoDone')
        $repoDone[0].repo | Should -Be 'octo-construction-kit-engine'
        $repoDone[0].success | Should -BeTrue
        $repoDone[0].copied | Should -Be 1
        $repoDone[0].purged | Should -Be 1
        $repoDone[0].logFile | Should -Be (Join-Path $fake.Checkout 'octo-construction-kit-engine/Invoke-Build.log')
        foreach ($field in @('seconds', 'buildSeconds', 'testSeconds', 'packageSeconds')) { $repoDone[0].PSObject.Properties.Name | Should -Contain $field }
        $repoDone[1].index | Should -Be 2
        $repoDone[1].copied | Should -Be 0

        $done = $all[-1]
        $done.success | Should -BeTrue
        $done.failedRepo | Should -BeNullOrEmpty
        $done.failedStep | Should -BeNullOrEmpty
        $done.elapsedSeconds | Should -BeGreaterOrEqual 0
    }

    It 'reports the failing repository in repoDone and done' {
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            [pscustomobject]@{ Success = ($entry.Name -ne 'octo-sdk'); LogFile = $null }
        }

        Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services -EventsFile $events -Json -ErrorAction SilentlyContinue | Out-Null

        $all = Read-Events $events
        @($all | Where-Object event -eq 'repoStart').repo | Should -Be @('octo-construction-kit-engine', 'octo-sdk')
        $failedDone = $all | Where-Object { $_.event -eq 'repoDone' -and $_.repo -eq 'octo-sdk' }
        $failedDone.success | Should -BeFalse
        $failedDone.index | Should -Be 2
        $failedDone.count | Should -Be 3
        $all[-1].event | Should -Be 'done'
        $all[-1].success | Should -BeFalse
        $all[-1].failedRepo | Should -Be 'octo-sdk'
        $all[-1].failedStep | Should -Be 'build'
    }

    It 'writes done with success=false on an early refusal' {
        Invoke-BuildRange -branch main -from does-not-exist -EventsFile $events -Json -ErrorAction SilentlyContinue | Out-Null

        $all = Read-Events $events
        @($all.event) | Should -Be @('done')
        $all[0].success | Should -BeFalse
        $all[0].failedStep | Should -Be 'preflight'
    }

    It 'writes repoDone(success=false) and done with the running repository and step when the build throws' {
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { throw 'boom' }

        { Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -EventsFile $events -Json } | Should -Throw '*boom*'

        $all = Read-Events $events
        @($all.event) | Should -Be @('plan', 'repoStart', 'phase', 'repoDone', 'done')
        $all[3].repo | Should -Be 'octo-construction-kit-engine'
        $all[3].success | Should -BeFalse
        $all[3].index | Should -Be 1
        $all[3].count | Should -Be 2
        $all[-1].success | Should -BeFalse
        $all[-1].failedRepo | Should -Be 'octo-construction-kit-engine'
        $all[-1].failedStep | Should -Be 'build'
    }

    It 'a refusal because of running services writes only done (preflight)' {
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses {
            @([pscustomobject]@{ Repo = 'octo-sdk'; Pid = 4711; Command = 'dotnet Meshmakers.Octo.Fake.dll' })
        }

        Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -EventsFile $events -Json -ErrorAction SilentlyContinue | Out-Null

        $all = Read-Events $events
        @($all.event) | Should -Be @('done')
        $all[0].success | Should -BeFalse
        $all[0].failedRepo | Should -BeNullOrEmpty
        $all[0].failedStep | Should -Be 'preflight'
    }

    It 'resolves a relative -EventsFile against the current location' {
        $folder = Join-Path $TestDrive 'relative-events'
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        Push-Location $folder
        try { Invoke-BuildRange -branch main -from octo-sdk -EventsFile 'run.jsonl' -Json | Out-Null }
        finally { Pop-Location }

        $all = Read-Events (Join-Path $folder 'run.jsonl')
        $all[-1].event | Should -Be 'done'
    }

    It 'writes no events under -WhatIf and no file without -EventsFile' {
        Invoke-BuildRange -branch main -from octo-construction-kit-engine -EventsFile $events -WhatIf -Json | Out-Null
        Test-Path $events | Should -BeFalse

        # TestDrive is shared by the tests of this Describe block: compare against the event files already there.
        $before = @(Get-ChildItem -Path $TestDrive -Recurse -File -Filter '*.jsonl').Count
        Push-Location $TestDrive
        try { Invoke-BuildRange -branch main -from octo-construction-kit-engine -Json | Out-Null }
        finally { Pop-Location }
        @(Get-ChildItem -Path $TestDrive -Recurse -File -Filter '*.jsonl').Count | Should -Be $before
    }

    It 'leaves the -Json output unchanged' {
        $without = Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -Json
        $script:fake = New-EventsCheckout
        $with = Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-sdk -EventsFile $events -Json

        @($with).Count | Should -Be 1
        ConvertTo-ComparableJson ($with -join "`n") | Should -Be (ConvertTo-ComparableJson ($without -join "`n"))
    }
}

Describe 'Invoke-Build -EventsFile' {
    BeforeEach {
        $script:fake = New-EventsCheckout
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid()).jsonl"
        $script:repo = Join-Path $fake.Checkout 'octo-sdk'
    }

    It 'writes plan, repoStart, phase restore/build, repoDone and done' {
        Mock -ModuleName Invoke-Build dotnet { $global:LASTEXITCODE = 0 }

        $json = Invoke-Build -repositoryPath $repo -configuration DebugL -EventsFile $events -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        $all = Read-Events $events
        @($all.event) | Should -Be @('plan', 'repoStart', 'phase', 'phase', 'repoDone', 'done')
        @($all | Where-Object event -eq 'phase').phase | Should -Be @('restore', 'build')
        $all | ForEach-Object { $_.command | Should -Be 'Invoke-Build' }
        $all[0].count | Should -Be 1
        $all[0].repos[0].repo | Should -Be 'octo-sdk'
        $all[4].success | Should -BeTrue
        $all[5].success | Should -BeTrue
    }

    It 'reports a failed restore as failedStep restore and does not build' {
        $script:dotnetCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-Build dotnet { $script:dotnetCalls.Add($args[0]); $global:LASTEXITCODE = 3 }

        Invoke-Build -repositoryPath $repo -configuration DebugL -EventsFile $events -Json | Out-Null

        $script:dotnetCalls | Should -Be @('restore')
        $all = Read-Events $events
        @($all | Where-Object event -eq 'phase').phase | Should -Be @('restore')
        $all[-1].success | Should -BeFalse
        $all[-1].failedRepo | Should -Be 'octo-sdk'
        $all[-1].failedStep | Should -Be 'restore'
    }

    It 'writes nothing with -DryRun' {
        Invoke-Build -repositoryPath $repo -configuration DebugL -EventsFile $events -DryRun -Json | Out-Null
        Test-Path $events | Should -BeFalse
    }

    It 'a missing repository folder writes only done with failedStep preflight and starts no dotnet' {
        Mock -ModuleName Invoke-Build dotnet { $global:LASTEXITCODE = 0 }

        $json = Invoke-Build -repositoryPath (Join-Path $fake.Checkout 'octo-missing') -configuration DebugL -EventsFile $events -Json 2>$null | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        Should -Invoke -ModuleName Invoke-Build dotnet -Times 0
        $all = Read-Events $events
        @($all.event) | Should -Be @('done')
        $all[0].success | Should -BeFalse
        $all[0].failedRepo | Should -BeNullOrEmpty
        $all[0].failedStep | Should -Be 'preflight'
    }

    It 'a throw during the build writes repoDone(success=false) and done with the running phase' {
        Mock -ModuleName Invoke-Build dotnet { if ($args[0] -eq 'build') { throw 'boom' }; $global:LASTEXITCODE = 0 }

        { Invoke-Build -repositoryPath $repo -configuration DebugL -EventsFile $events -Json } | Should -Throw '*boom*'

        $all = Read-Events $events
        @($all.event) | Should -Be @('plan', 'repoStart', 'phase', 'phase', 'repoDone', 'done')
        $all[4].success | Should -BeFalse
        $all[5].failedRepo | Should -Be 'octo-sdk'
        $all[5].failedStep | Should -Be 'build'
    }
}

Describe 'Invoke-BuildAll -EventsFile' {
    BeforeEach {
        $script:fake = New-EventsCheckout
        $script:events = Join-Path $TestDrive "events-$([guid]::NewGuid()).jsonl"
        Mock -ModuleName Invoke-BuildAll Invoke-KillDotnet { }
        Mock -ModuleName Invoke-BuildAll Compile-Repo { (Split-Path -Leaf $path) -ne 'octo-sdk' }
        Mock -ModuleName Invoke-BuildAll dotnet { $global:LASTEXITCODE = 0 }
    }

    It 'writes plan, repoStart/phase/repoDone per repository and done with the first failure' {
        $json = Invoke-BuildAll -branch main -configuration Release -EventsFile $events -Json | ConvertFrom-Json

        @($json.data.repositories).Count | Should -Be 3
        $all = Read-Events $events
        $all[0].event | Should -Be 'plan'
        $all[0].count | Should -Be 3
        @($all[0].repos.mode) | Should -Be @('dotnet', 'dotnet', 'dotnet')
        @($all | Where-Object event -eq 'repoStart').Count | Should -Be 3
        @($all | Where-Object event -eq 'repoDone').success | Should -Be @($true, $false, $true)
        $all[-1].event | Should -Be 'done'
        $all[-1].success | Should -BeFalse
        $all[-1].failedRepo | Should -Be 'octo-sdk'
        $all[-1].failedStep | Should -Be 'build'
        $all | ForEach-Object { $_.command | Should -Be 'Invoke-BuildAll' }
    }

    It 'writes done with success=false on an early failure and nothing for -DryRun' {
        Invoke-BuildAll -branch main -configuration DebugL -msbuildProperties @{ 'no good' = 1 } -EventsFile $events 2>&1 | Out-Null
        $all = Read-Events $events
        @($all.event) | Should -Be @('done')
        $all[0].success | Should -BeFalse

        $dry = Join-Path $TestDrive 'dry.jsonl'
        Invoke-BuildAll -branch main -configuration DebugL -DryRun -EventsFile $dry -Json | Out-Null
        Test-Path $dry | Should -BeFalse
    }

    It 'a DebugL purge that left files behind stops before building, failedStep purge' {
        Mock -ModuleName Invoke-BuildAll Compile-Repo { $true }
        Mock -ModuleName Invoke-BuildAll Remove-OctoLaneNuGetPackages { Write-Error 'The process cannot access the file because it is being used by another process.' }

        $json = Invoke-BuildAll -branch main -configuration DebugL -skipKill -EventsFile $events -Json 2>$null | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*package purge failed*nothing was built*'
        Should -Invoke -ModuleName Invoke-BuildAll Compile-Repo -Times 0
        $all = Read-Events $events
        @($all | Where-Object event -eq 'repoDone') | Should -HaveCount 0
        $all[-1].event | Should -Be 'done'
        $all[-1].success | Should -BeFalse
        $all[-1].failedRepo | Should -BeNullOrEmpty
        $all[-1].failedStep | Should -Be 'purge'
    }

    It 'a failed package copy stops the run and reports failedStep packages' {
        Mock -ModuleName Invoke-BuildAll Compile-Repo { if ((Split-Path -Leaf $path) -eq 'octo-sdk') { throw 'Copy-NuGetPackages: 1 package(s) not copied' }; $true }
        Mock -ModuleName Invoke-BuildAll Remove-OctoLaneNuGetPackages { }

        $json = Invoke-BuildAll -branch main -configuration DebugL -skipKill -EventsFile $events -Json 2>$null | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.error | Should -BeLike '*octo-sdk*not copied*'
        $all = Read-Events $events
        @($all | Where-Object event -eq 'repoDone')[-1].repo | Should -Be 'octo-sdk'
        $all[-1].success | Should -BeFalse
        $all[-1].failedRepo | Should -Be 'octo-sdk'
        $all[-1].failedStep | Should -Be 'packages'
    }

    It 'a throw in a repository writes its repoDone(success=false) before done' {
        Mock -ModuleName Invoke-BuildAll Compile-Repo { if ((Split-Path -Leaf $path) -eq 'octo-sdk') { throw 'boom' }; $true }

        { Invoke-BuildAll -branch main -configuration Release -EventsFile $events -Json } | Should -Throw '*boom*'

        $all = Read-Events $events
        @($all.event) | Should -Be @('plan', 'repoStart', 'phase', 'repoDone', 'repoStart', 'phase', 'repoDone', 'done')
        $all[6].repo | Should -Be 'octo-sdk'
        $all[6].success | Should -BeFalse
        $all[6].index | Should -Be 2
        $all[-1].failedRepo | Should -Be 'octo-sdk'
        $all[-1].failedStep | Should -Be 'build'
    }
}
