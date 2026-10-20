#Requires -Modules Pester
<#
    Pester tests for the deprecated docker-compose infrastructure (OctoComposeInfra.psm1, AB#7141):
    the deprecation warning of every compose cmdlet and the guard that never changes the CrateDB image of
    existing volumes. docker is mocked; no container, volume or compose file is touched.

    Run:  Invoke-Pester ./tests/OctoComposeInfra.Tests.ps1
#>

BeforeAll {
    # A stub so that Mock works on machines without docker.
    if (-not (Get-Command docker -ErrorAction Ignore)) { function global:docker { } }
    $modules = Join-Path $PSScriptRoot '../modules'
    foreach ($m in 'OctoJsonOutput', 'OctoComposeInfra', 'Install-OctoInfrastructure', 'Start-OctoInfrastructure', 'Stop-OctoInfrastructure',
        'Uninstall-OctoInfrastructure', 'Get-OctoInfrastructureStatus', 'Manage-OctoInfrastructureBackup') {
        Import-Module (Join-Path $modules "$m.psm1") -Force -Global
    }
    $global:infrastructurePath = (Resolve-Path (Join-Path $PSScriptRoot '../infrastructure')).Path
    $script:composeFile = Join-Path $global:infrastructurePath 'docker-compose.yml'
}

Describe 'Get-OctoComposeCrateDecision' {
    It 'stored <stored>, volumes <volumes>, compose 5.10.10 -> allowed <allowed>' -ForEach @(
        @{ stored = @();           volumes = $false; allowed = $true }
        @{ stored = @('5.10.10');  volumes = $true;  allowed = $true }
        @{ stored = @('6.4.6');    volumes = $true;  allowed = $false }
        @{ stored = @('5.9.10');   volumes = $true;  allowed = $false }
        @{ stored = @('5.10.10', '6.4.6'); volumes = $true; allowed = $false }
        @{ stored = @();           volumes = $true;  allowed = $false }
    ) {
        $d = Get-OctoComposeCrateDecision -ComposeVersion ([version]'5.10.10') -StoredVersions ([version[]]$stored) -VolumesExist $volumes
        $d.Allowed | Should -Be $allowed
    }

    It 'says "cannot be downgraded" and points to kind when the data is newer' {
        $d = Get-OctoComposeCrateDecision -ComposeVersion ([version]'5.10.10') -StoredVersions ([version[]]@('6.4.6')) -VolumesExist $true
        $d.Reason | Should -BeLike '*cannot be downgraded*Install-OctoKubernetes*'
    }

    It 'never changes the image of existing volumes, not even to a newer one' {
        $d = Get-OctoComposeCrateDecision -ComposeVersion ([version]'6.4.6') -StoredVersions ([version[]]@('5.10.10')) -VolumesExist $true
        $d.Allowed | Should -BeFalse
        $d.Reason | Should -BeLike '*never changes the CrateDB image of existing volumes*'
    }

    It 'allows unknown volumes only with the explicit switch' {
        (Get-OctoComposeCrateDecision -ComposeVersion ([version]'5.10.10') -VolumesExist $true -AcceptUnknownCrateVolumes).Allowed | Should -BeTrue
    }
}

Describe 'Get-OctoComposeCrateVersion' {
    It 'reads the version the shipped compose file pins' {
        (Get-OctoComposeCrateVersion -ComposeFile $script:composeFile).ToString() | Should -Match '^\d+\.\d+\.\d+$'
    }
    It 'fails without a crate image line' {
        $f = Join-Path $TestDrive 'c.yml'; Set-Content $f 'image: busybox'
        { Get-OctoComposeCrateVersion -ComposeFile $f } | Should -Throw "*No 'image: crate*"
    }
}

Describe 'Start-OctoInfrastructure guard' {
    BeforeEach {
        $script:marker = Join-Path $TestDrive 'marker.txt'
        Remove-Item $script:marker -ErrorAction Ignore
        $script:compose = (Get-OctoComposeCrateVersion -ComposeFile $script:composeFile).ToString()
        $script:containerImages = @()
        $script:volumes = @()
        $script:composeUp = 0
        $script:fake = {
            $a = $args -join ' '
            $global:LASTEXITCODE = 0
            if ($a -match '^ps -a') { return $script:containerImages }
            if ($a -match '^volume ls') { return $script:volumes }
            if ($a -match '^compose up') { $script:composeUp++; return }
        }
        Mock Get-OctoComposeCrateMarkerPath { $script:marker } -ModuleName OctoComposeInfra
        Mock Test-OctoKindInfraRunning { $false } -ModuleName Start-OctoInfrastructure
        Mock docker $script:fake -ModuleName OctoComposeInfra
        Mock docker $script:fake -ModuleName Start-OctoInfrastructure
    }

    It 'starts on a fresh machine and records the version' {
        $null = Start-OctoInfrastructure *>&1
        $script:composeUp | Should -Be 1
        (Get-Content $script:marker -Raw) | Should -Be $script:compose
    }

    It 'refuses an older image over newer data and does not run compose' {
        $script:containerImages = @('crate:6.4.6'); $script:volumes = @('infrastructure_crate-data1')
        $out = Start-OctoInfrastructure *>&1 | Out-String
        $script:composeUp | Should -Be 0
        $out | Should -BeLike '*cannot be downgraded*'
    }

    It 'refuses when only the record (no container) says the data is newer' {
        Set-Content $script:marker '6.4.6' -NoNewline; $script:volumes = @('infrastructure_crate-data1')
        $null = Start-OctoInfrastructure *>&1
        $script:composeUp | Should -Be 0
    }

    It 'refuses existing volumes of unknown version, accepts them with the switch' {
        $script:volumes = @('infrastructure_crate-data1')
        $null = Start-OctoInfrastructure *>&1
        $script:composeUp | Should -Be 0
        $null = Start-OctoInfrastructure -AcceptUnknownCrateVolumes *>&1
        $script:composeUp | Should -Be 1
    }

    It 'starts when the existing containers already run the pinned version' {
        $script:containerImages = @("crate:$script:compose"); $script:volumes = @('infrastructure_crate-data1')
        $null = Start-OctoInfrastructure *>&1
        $script:composeUp | Should -Be 1
    }
}

Describe 'Stop and Uninstall keep the version record in step with the data' {
    BeforeEach {
        # An empty folder: Uninstall deletes file.key there, never the one of a real checkout.
        $global:infrastructurePath = (New-Item -ItemType Directory -Path (Join-Path $TestDrive 'infra2') -Force).FullName
        $script:marker = Join-Path $TestDrive 'marker2.txt'
        Remove-Item $script:marker -ErrorAction Ignore
        $script:fake = {
            $a = $args -join ' '
            $global:LASTEXITCODE = 0
            if ($a -match '^ps -a') { return @('crate:5.10.10', 'crate:5.10.10') }
        }
        Mock Get-OctoComposeCrateMarkerPath { $script:marker } -ModuleName OctoComposeInfra
        Mock docker $script:fake -ModuleName OctoComposeInfra
        Mock docker $script:fake -ModuleName Stop-OctoInfrastructure
        Mock docker $script:fake -ModuleName Uninstall-OctoInfrastructure
    }

    It 'Stop records the version of the containers before they are removed' {
        $null = Stop-OctoInfrastructure *>&1
        (Get-Content $script:marker -Raw) | Should -Be '5.10.10'
    }

    It 'Uninstall removes the record together with the volumes' {
        Set-Content $script:marker '5.10.10' -NoNewline
        $null = Uninstall-OctoInfrastructure *>&1
        Test-Path $script:marker | Should -BeFalse
    }
}

Describe 'Deprecation warning' {
    BeforeAll {
        $global:infrastructurePath = Join-Path $TestDrive 'does-not-exist'   # stops each cmdlet right after the warning
    }
    AfterAll {
        $global:infrastructurePath = (Resolve-Path (Join-Path $PSScriptRoot '../infrastructure')).Path
    }

    It '<cmd> warns, names the removal date and the kind path' -ForEach @(
        @{ cmd = 'Install-OctoInfrastructure' }, @{ cmd = 'Start-OctoInfrastructure' }, @{ cmd = 'Stop-OctoInfrastructure' },
        @{ cmd = 'Uninstall-OctoInfrastructure' }, @{ cmd = 'Get-OctoInfrastructureStatus' },
        @{ cmd = 'Backup-OctoInfrastructure' }, @{ cmd = 'Restore-OctoInfrastructure' },
        @{ cmd = 'Get-OctoInfrastructureBackup' }, @{ cmd = 'Remove-OctoInfrastructureBackup' }
    ) {
        $out = & $cmd *>&1 | Out-String
        $out | Should -BeLike "*DEPRECATED: $cmd*2026-12-31*Install-OctoKubernetes*Migrating from docker-compose*"
    }
}
