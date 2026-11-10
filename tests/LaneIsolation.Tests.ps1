#Requires -Modules Pester
<#
    Pester tests for the lane isolation decision (Get-OctoLaneBuildSettings) and
    Initialize-OctoLaneUserProps -AddRestorePackagesPath. Fake lanes in TestDrive only; the real
    branches/main/Octo.User.props and ~/.nuget are never read or written.

    Run:  Invoke-Pester ./tests/LaneIsolation.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Get-OctoLaneBuildSettings.psm1') -Force

    $script:StandardLine = '<RestorePackagesPath>$(MSBuildThisFileDirectory).nuget-packages</RestorePackagesPath>'

    function New-FakeLane([string]$name, [AllowNull()][object]$props) {
        $lane = Join-Path $TestDrive "meshmakers/$name"
        if (Test-Path $lane) { Remove-Item $lane -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $lane 'nuget'), (Join-Path $lane 'mm-common'), (Join-Path $lane 'octo-sdk') | Out-Null
        Set-Content -Path (Join-Path $lane 'octo-sdk/Directory.Build.props') -Value '<Project><PropertyGroup><RestoreSources>x</RestoreSources></PropertyGroup></Project>'
        Set-Content -Path (Join-Path $lane 'mm-common/Directory.Build.props') -Value '<Project />'
        if ($null -ne $props) {
            Set-Content -Path (Join-Path $lane 'Octo.User.props') -Value $props -NoNewline
        }
        return $lane
    }

    $script:PreviousRootPath = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $global:rootPath = Join-Path $TestDrive 'meshmakers'
}

AfterAll {
    if ($null -ne $script:PreviousRootPath) { $global:rootPath = $script:PreviousRootPath } else { Remove-Variable -Name rootPath -Scope Global -ErrorAction SilentlyContinue }
}

Describe 'Get-OctoLaneBuildSettings decides isolation from Octo.User.props' {
    It 'isolates a lane whose Octo.User.props declares RestorePackagesPath' {
        $lane = New-FakeLane 'env-a' "<Project><PropertyGroup>$StandardLine</PropertyGroup></Project>"
        $settings = Get-OctoLaneBuildSettings -laneRootPath $lane
        $settings.isolated | Should -BeTrue
        $settings.declaresRestorePackagesPath | Should -BeTrue
        $settings.environment.NUGET_PACKAGES | Should -Be (Join-Path $lane '.nuget-packages')
        $settings.environment.MSBUILDDISABLENODEREUSE | Should -Be '1'
        $settings.restoreSourcesOverride | Should -Be "$(Join-Path $lane 'nuget');https://api.nuget.org/v3/index.json"
    }

    It 'keeps the legacy behaviour for a lane whose Octo.User.props has no RestorePackagesPath (main today)' {
        $lane = New-FakeLane 'main' '<Project><PropertyGroup><OctoSomething>1</OctoSomething></PropertyGroup></Project>'
        $settings = Get-OctoLaneBuildSettings -laneRootPath $lane
        $settings.isolated | Should -BeFalse
        $settings.environment.Count | Should -Be 0
        $settings.restoreSourcesOverride | Should -BeNullOrEmpty
        $settings.reason | Should -Match 'AddRestorePackagesPath'
    }

    It 'keeps the legacy behaviour without Octo.User.props, and for a line that is only commented out' {
        (Get-OctoLaneBuildSettings -laneRootPath (New-FakeLane 'none' $null)).isolated | Should -BeFalse
        (Get-OctoLaneBuildSettings -laneRootPath (New-FakeLane 'empty' '')).isolated | Should -BeFalse
        $commented = New-FakeLane 'commented' "<Project><!-- $StandardLine --></Project>"
        (Get-OctoLaneBuildSettings -laneRootPath $commented).isolated | Should -BeFalse
    }

    It 'ignores the user-level NuGet.Config entirely' {
        Get-Command -Module Get-OctoLaneBuildSettings | ForEach-Object Name | Should -Not -Contain 'Get-OctoConfiguredLocalNuGetFeeds'
        (Get-Command Get-OctoLaneBuildSettings).Parameters.Keys | Should -Not -Contain 'nugetConfigPath'
    }

    It '-laneIsolation On and Off override the props' {
        $isolatedLane = New-FakeLane 'iso' "<Project><PropertyGroup>$StandardLine</PropertyGroup></Project>"
        $legacyLane = New-FakeLane 'leg' $null
        (Get-OctoLaneBuildSettings -laneRootPath $isolatedLane -laneIsolation Off).isolated | Should -BeFalse
        (Get-OctoLaneBuildSettings -laneRootPath $legacyLane -laneIsolation On).isolated | Should -BeTrue
    }

    It 'gives RestoreSources only to DebugL repos without their own <RestoreSources>' {
        $lane = New-FakeLane 'env-b' "<Project><PropertyGroup>$StandardLine</PropertyGroup></Project>"
        $mm = Get-OctoRepositoryBuildEnvironment -repositoryPath (Join-Path $lane 'mm-common') -configuration DebugL
        $mm.isolated | Should -BeTrue
        $mm.environment.RestoreSources | Should -Match 'nuget;https://api.nuget.org'
        $sdk = Get-OctoRepositoryBuildEnvironment -repositoryPath (Join-Path $lane 'octo-sdk') -configuration DebugL
        $sdk.environment.Contains('RestoreSources') | Should -BeFalse
        $sdk.environment.NUGET_PACKAGES | Should -Be (Join-Path $lane '.nuget-packages')
        $release = Get-OctoRepositoryBuildEnvironment -repositoryPath (Join-Path $lane 'mm-common') -configuration Release
        $release.environment.Contains('RestoreSources') | Should -BeFalse
    }

    It 'Get-OctoRangePackageCaches: isolated -> lane cache only; -laneIsolation Off with the line -> lane and global cache' {
        $lane = New-FakeLane 'env-c' "<Project><PropertyGroup>$StandardLine</PropertyGroup></Project>"
        $global = Join-Path $TestDrive 'global-cache'
        $previous = $env:NUGET_PACKAGES
        $env:NUGET_PACKAGES = $global
        try {
            Get-OctoRangePackageCaches -laneSettings (Get-OctoLaneBuildSettings -laneRootPath $lane) | Should -Be @((Join-Path $lane '.nuget-packages'))
            Get-OctoRangePackageCaches -laneSettings (Get-OctoLaneBuildSettings -laneRootPath $lane -laneIsolation Off) | Should -Be @((Join-Path $lane '.nuget-packages'), $global)
        }
        finally { $env:NUGET_PACKAGES = $previous }
    }
}

Describe 'Initialize-OctoLaneUserProps' {
    It 'creates a missing Octo.User.props with the lane cache' {
        $lane = New-FakeLane 'fresh' $null
        $doc = Initialize-OctoLaneUserProps -branch 'fresh' -Json | ConvertFrom-Json
        $doc.data.status | Should -Be 'created'
        (Get-OctoLaneBuildSettings -laneRootPath $lane).isolated | Should -BeTrue
    }

    It 'without -AddRestorePackagesPath leaves an existing file without the line unchanged' {
        $original = "<Project>`n  <PropertyGroup><OctoDevCert>abc</OctoDevCert></PropertyGroup>`n</Project>`n"
        $lane = New-FakeLane 'main-a' $original
        $doc = Initialize-OctoLaneUserProps -branch 'main-a' -Json | ConvertFrom-Json
        $doc.data.status | Should -Be 'missing-restore-packages-path'
        $doc.data.success | Should -BeFalse
        Get-Content (Join-Path $lane 'Octo.User.props') -Raw | Should -Be $original
    }

    It '-AddRestorePackagesPath adds the line, keeps every other byte, writes a .bak and is idempotent' {
        $original = "<Project>`n  <!-- main settings -->`n  <PropertyGroup><OctoDevCert>abc</OctoDevCert></PropertyGroup>`n</Project>`n"
        $lane = New-FakeLane 'main-b' $original
        $props = Join-Path $lane 'Octo.User.props'

        $doc = Initialize-OctoLaneUserProps -branch 'main-b' -AddRestorePackagesPath -Json | ConvertFrom-Json
        $doc.data.status | Should -Be 'added'
        $doc.data.backupPath | Should -Be "$props.bak"
        Get-Content "$props.bak" -Raw | Should -Be $original
        $updated = Get-Content $props -Raw
        $updated | Should -BeLike "<Project>`n  <!-- main settings -->`n  <PropertyGroup><OctoDevCert>abc</OctoDevCert></PropertyGroup>`n*$StandardLine*</Project>`n"
        { [xml]$updated } | Should -Not -Throw
        (Get-OctoLaneBuildSettings -laneRootPath $lane).isolated | Should -BeTrue

        $again = Initialize-OctoLaneUserProps -branch 'main-b' -AddRestorePackagesPath -Json | ConvertFrom-Json
        $again.data.status | Should -Be 'ok'
        Get-Content $props -Raw | Should -Be $updated
        @(Get-ChildItem $lane -Filter 'Octo.User.props*.bak').Count | Should -Be 1
    }

    It '-AddRestorePackagesPath keeps an existing .bak and writes a timestamped one' {
        $lane = New-FakeLane 'main-c' '<Project></Project>'
        Set-Content -Path (Join-Path $lane 'Octo.User.props.bak') -Value 'older backup'
        $doc = Initialize-OctoLaneUserProps -branch 'main-c' -AddRestorePackagesPath -Json | ConvertFrom-Json
        $doc.data.status | Should -Be 'added'
        $doc.data.backupPath | Should -BeLike '*Octo.User.props.*.bak'
        Get-Content (Join-Path $lane 'Octo.User.props.bak') -Raw | Should -Match 'older backup'
    }

    It '-AddRestorePackagesPath -WhatIf changes nothing' {
        $original = '<Project></Project>'
        $lane = New-FakeLane 'main-d' $original
        $doc = Initialize-OctoLaneUserProps -branch 'main-d' -AddRestorePackagesPath -WhatIf -Json | ConvertFrom-Json
        $doc.data.status | Should -Be 'would-add'
        Get-Content (Join-Path $lane 'Octo.User.props') -Raw | Should -Be $original
        Test-Path (Join-Path $lane 'Octo.User.props.bak') | Should -BeFalse
    }

    It 'a commented-out standard line is no setting: reported as missing, -AddRestorePackagesPath adds a real one' {
        $original = "<Project>`n  <!-- $StandardLine -->`n</Project>`n"
        $lane = New-FakeLane 'main-f' $original
        (Initialize-OctoLaneUserProps -branch 'main-f' -Json | ConvertFrom-Json).data.status | Should -Be 'missing-restore-packages-path'
        (Initialize-OctoLaneUserProps -branch 'main-f' -AddRestorePackagesPath -Json | ConvertFrom-Json).data.status | Should -Be 'added'
        (Get-OctoLaneBuildSettings -laneRootPath $lane).isolated | Should -BeTrue
        (Initialize-OctoLaneUserProps -branch 'main-f' -Json | ConvertFrom-Json).data.status | Should -Be 'ok'
    }

    It 'never rewrites a RestorePackagesPath with another value' {
        $original = '<Project><PropertyGroup><RestorePackagesPath>/somewhere/else</RestorePackagesPath></PropertyGroup></Project>'
        $lane = New-FakeLane 'main-e' $original
        $doc = Initialize-OctoLaneUserProps -branch 'main-e' -AddRestorePackagesPath -Json | ConvertFrom-Json
        $doc.data.status | Should -Be 'custom-restore-packages-path'
        Get-Content (Join-Path $lane 'Octo.User.props') -Raw | Should -Be $original
    }
}
