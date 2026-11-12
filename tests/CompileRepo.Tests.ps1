<#
.SYNOPSIS
    Pester tests for Compile-Repo (Invoke-BuildAll.psm1): it returns exactly one [bool] per repository,
    whatever the builder writes to the pipeline (AB#8831).
.DESCRIPTION
    Octo-frontend-refinery-studio's build.ps1 writes its npm output to the pipeline. Compile-Repo returned
    that output together with the result, Invoke-BuildAll's [Boolean] cast of the array threw and the run
    stopped although the build had succeeded. The fake build scripts and mocked builders below write to the
    pipeline on purpose. Configuration Debug keeps Copy-NuGetPackages out of the way (it runs for DebugL only).
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '..' 'modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Get-OctoLaneBuildSettings.psm1') -Force
    Import-Module (Join-Path $modules 'OctoBuildOrder.psm1') -Force
    Import-Module (Join-Path $modules 'Copy-NuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-KillDotnet.psm1') -Force
    Import-Module (Join-Path $modules 'Remove-GlobalNuGetPackages.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-Build.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-Publish.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-BuildAll.psm1') -Force

    function New-FakeRepo {
        param([string]$name, [string]$buildScript = $null, [switch]$solution)
        $path = Join-Path $TestDrive $name
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        if ($buildScript) { Set-Content -Path (Join-Path $path 'build.ps1') -Value $buildScript }
        if ($solution) { Set-Content -Path (Join-Path $path "$name.sln") -Value '' }
        return $path
    }
}

Describe 'Compile-Repo returns one [bool]' {
    It 'returns $true for a build.ps1 that writes to the pipeline and exits 0' {
        $path = New-FakeRepo -name 'fake-script-ok' -buildScript @'
param([string]$configuration)
'npm output line 1'
Write-Output 'npm output line 2'
1..3
exit 0
'@
        $result = InModuleScope Invoke-BuildAll -Parameters @{ path = $path } {
            param($path)
            , (Compile-Repo -path $path -configuration 'Debug')
        }
        $result | Should -BeOfType [bool]
        @($result).Count | Should -Be 1
        $result | Should -BeTrue
    }

    It 'returns $false for a build.ps1 that writes to the pipeline and exits 1' {
        $path = New-FakeRepo -name 'fake-script-fail' -buildScript @'
param([string]$configuration)
'npm ERR! something failed'
exit 1
'@
        $result = InModuleScope Invoke-BuildAll -Parameters @{ path = $path } {
            param($path)
            , (Compile-Repo -path $path -configuration 'Debug')
        }
        $result | Should -BeOfType [bool]
        @($result).Count | Should -Be 1
        $result | Should -BeFalse
    }

    It 'returns one [bool] when Invoke-Build writes to the pipeline (exit code <exitCode>)' -ForEach @(
        @{ exitCode = 0; expected = $true }
        @{ exitCode = 2; expected = $false }
    ) {
        $path = New-FakeRepo -name "fake-dotnet-$exitCode" -solution
        Mock -ModuleName Invoke-BuildAll Invoke-Build { 'dotnet output'; 42; $global:LASTEXITCODE = $exitCode }
        $result = InModuleScope Invoke-BuildAll -Parameters @{ path = $path } {
            param($path)
            , (Compile-Repo -path $path -configuration 'Debug')
        }
        $result | Should -BeOfType [bool]
        @($result).Count | Should -Be 1
        $result | Should -Be $expected
    }

    It 'returns one [bool] when Invoke-Publish writes to the pipeline' {
        $path = New-FakeRepo -name 'octo-frontend-fake' -solution
        Mock -ModuleName Invoke-BuildAll Invoke-Publish { 'publish output'; $global:LASTEXITCODE = 0 }
        $result = InModuleScope Invoke-BuildAll -Parameters @{ path = $path } {
            param($path)
            , (Compile-Repo -path $path -configuration 'Debug')
        }
        $result | Should -BeOfType [bool]
        @($result).Count | Should -Be 1
        $result | Should -BeTrue
    }
}
