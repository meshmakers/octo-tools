#Requires -Modules Pester
<#
    Pester tests for AB#8954: a relative -repositoryPath of Invoke-Build / Invoke-Publish and the lane helpers
    follows the PowerShell location (Set-Location), not the process directory ([Environment]::CurrentDirectory).

    The process directory is set to a fake base lane ("main") and the PowerShell location to a repository of a
    fake feature-environment lane, both in TestDrive. On the old code ([IO.Path]::GetFullPath) every relative
    path resolved into "main". No dotnet process is started (dotnet is mocked); the real lanes, NuGet folders
    and ~/.nuget/packages are never read or written.

    Run:  Invoke-Pester ./tests/RelativeRepositoryPath.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Get-OctoLaneBuildSettings.psm1') -Force
    Import-Module (Join-Path $modules 'OctoBuildOrder.psm1') -Force
    Import-Module (Join-Path $modules 'OctoCkCatalogRefresh.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-Build.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-Publish.psm1') -Force
    Import-Module (Join-Path $modules 'OctoTests.psm1') -Force

    $script:StandardLine = '<RestorePackagesPath>$(MSBuildThisFileDirectory).nuget-packages</RestorePackagesPath>'

    function New-FakeLane([string]$name, [string]$props) {
        $lane = Join-Path $TestDrive $name
        New-Item -ItemType Directory -Force -Path (Join-Path $lane 'nuget'), (Join-Path $lane 'mm-common/src') | Out-Null
        Set-Content -Path (Join-Path $lane 'mm-common/Directory.Build.props') -Value '<Project />'
        Set-Content -Path (Join-Path $lane 'Octo.User.props') -Value $props -NoNewline
        return [IO.Path]::TrimEndingDirectorySeparator((Resolve-Path -LiteralPath $lane).ProviderPath)
    }

    # Base lane without RestorePackagesPath (main today), feature environment with it (New-OctoEnvironment).
    $script:MainLane = New-FakeLane 'main' '<Project><PropertyGroup><OctoSomething>1</OctoSomething></PropertyGroup></Project>'
    $script:EnvLane = New-FakeLane 'wt-ab8954-path' "<Project><PropertyGroup>$StandardLine</PropertyGroup></Project>"
    $script:EnvRepo = Join-Path $EnvLane 'mm-common'
}

Describe 'Relative paths follow the PowerShell location, not the process directory (AB#8954)' {
    BeforeEach {
        $script:SavedProcessDirectory = [Environment]::CurrentDirectory
        # The pwsh process "started" in the base lane, then Set-Location into the feature environment.
        [Environment]::CurrentDirectory = $MainLane
        Push-Location -LiteralPath $EnvRepo
    }

    AfterEach {
        Pop-Location
        [Environment]::CurrentDirectory = $SavedProcessDirectory
    }

    It 'the test setup really separates the two directories' {
        [Environment]::CurrentDirectory | Should -Be $MainLane
        (Get-Location).ProviderPath | Should -Be $EnvRepo
    }

    It 'Invoke-Build -repositoryPath . -DryRun -Json reports the worktree and the environment lane' {
        $json = Invoke-Build -repositoryPath . -configuration DebugL -DryRun -Json | ConvertFrom-Json

        $json.data.repositoryPath | Should -Be $EnvRepo
        $json.data.laneRoot | Should -Be $EnvLane
        $json.data.isolated | Should -BeTrue
        $json.data.environment.NUGET_PACKAGES | Should -Be (Join-Path $EnvLane '.nuget-packages')
        $json.data.environment.RestoreSources | Should -Be "$(Join-Path $EnvLane 'nuget');https://api.nuget.org/v3/index.json"
    }

    It 'Invoke-Build with the default repositoryPath (.\) uses the PowerShell location' {
        $json = Invoke-Build -DryRun -Json | ConvertFrom-Json
        $json.data.repositoryPath | Should -Be $EnvRepo
        $json.data.laneRoot | Should -Be $EnvLane
    }

    It 'Invoke-Build resolves a relative sub path against the PowerShell location' {
        Push-Location -LiteralPath $EnvLane
        try {
            $json = Invoke-Build -repositoryPath ./mm-common -DryRun -Json | ConvertFrom-Json
        }
        finally { Pop-Location }
        $json.data.repositoryPath | Should -Be $EnvRepo
        $json.data.laneRoot | Should -Be $EnvLane
    }

    It 'Invoke-Build builds in the worktree with the environment of the environment lane' {
        Mock -ModuleName Invoke-Build dotnet {
            $script:dotnetCalls += , @{ Verb = $args[0]; Path = $args[1]; Packages = $env:NUGET_PACKAGES }
            $global:LASTEXITCODE = 0
        }
        $script:dotnetCalls = @()

        $json = Invoke-Build -repositoryPath . -configuration DebugL -Json | ConvertFrom-Json

        $json.data.success | Should -BeTrue
        @($dotnetCalls.Verb) | Should -Be @('restore', 'build')
        foreach ($call in $dotnetCalls) {
            $call.Path | Should -Be $EnvRepo
            $call.Packages | Should -Be (Join-Path $EnvLane '.nuget-packages')
        }
        $json.data.logFile | Should -Be (Join-Path $EnvRepo 'Invoke-Build.log')
        Test-Path -LiteralPath (Join-Path $MainLane 'Invoke-Build.log') | Should -BeFalse
    }

    It 'Invoke-Publish -repositoryPath . -DryRun -Json reports the worktree and the environment lane' {
        $json = Invoke-Publish -repositoryPath . -configuration DebugL -DryRun -Json | ConvertFrom-Json
        $json.data.repositoryPath | Should -Be $EnvRepo
        $json.data.laneRoot | Should -Be $EnvLane
    }

    It 'the lane helpers resolve a relative path against the PowerShell location' {
        Find-OctoLaneRoot -path . | Should -Be $EnvLane
        Find-OctoLaneRoot -path ./src | Should -Be $EnvLane
        (Get-OctoRepositoryBuildEnvironment -repositoryPath . -configuration DebugL).laneRoot | Should -Be $EnvLane
        Resolve-OctoLocationPath -path . | Should -Be $EnvRepo
        Resolve-OctoLocationPath -path ../nuget | Should -Be (Join-Path $EnvLane 'nuget')
        Push-Location -LiteralPath $EnvLane
        try {
            (Get-OctoLaneBuildSettings -laneRootPath .).laneRoot | Should -Be $EnvLane
        }
        finally { Pop-Location }
    }

    It 'the test project discovery resolves a relative repository path against the PowerShell location' {
        New-Item -ItemType Directory -Force -Path (Join-Path $EnvRepo 'src/Env.Tests') | Out-Null
        Set-Content -Path (Join-Path $EnvRepo 'src/Env.Tests/Env.Tests.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><IsTestProject>true</IsTestProject></PropertyGroup></Project>'
        try {
            InModuleScope OctoTests -Parameters @{ repo = $EnvRepo } {
                param($repo)
                $projects = @(Get-OctoTestProjects -repositoryPath .)
                @($projects.Name) | Should -Be @('Env.Tests')
                $projects[0].Path | Should -Be (Join-Path $repo 'src/Env.Tests/Env.Tests.csproj')
            }
        }
        finally { Remove-Item -LiteralPath (Join-Path $EnvRepo 'src/Env.Tests') -Recurse -Force }
    }
}

Describe 'Safety net: the build refuses a repository outside the lane root that was found (AB#8954)' {
    BeforeEach {
        Mock -ModuleName Invoke-Build dotnet { $global:LASTEXITCODE = 0 }
        Mock -ModuleName Invoke-Publish dotnet { $global:LASTEXITCODE = 0 }
        # Simulates a lane decision that does not match the repository (the defect of AB#8954).
        Mock -ModuleName Invoke-Build Get-OctoRepositoryBuildEnvironment { [pscustomobject]@{ laneRoot = $MainLane; isolated = $false; reason = 'test'; environment = [ordered]@{} } }
        Mock -ModuleName Invoke-Publish Get-OctoRepositoryBuildEnvironment { [pscustomobject]@{ laneRoot = $MainLane; isolated = $false; reason = 'test'; environment = [ordered]@{} } }
    }

    It 'Invoke-Build refuses before dotnet and names both paths' {
        $output = @(Invoke-Build -repositoryPath $EnvRepo -configuration DebugL -Json 2>&1)
        $failure = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $json = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ConvertFrom-Json

        $json.data.success | Should -BeFalse
        $json.data.repositoryPath | Should -Be $EnvRepo
        $json.data.laneRoot | Should -Be $MainLane
        $failure.Count | Should -Be 1
        foreach ($message in @("$($failure[0])", $json.data.error)) {
            $message | Should -Match ([regex]::Escape($EnvRepo))
            $message | Should -Match ([regex]::Escape($MainLane))
        }
        Should -Invoke -ModuleName Invoke-Build dotnet -Times 0
    }

    It 'Invoke-Build -DryRun refuses as well' {
        $json = Invoke-Build -repositoryPath $EnvRepo -DryRun -Json 2>$null | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        $json.data.dryRun | Should -BeNullOrEmpty
    }

    It 'Invoke-Publish refuses before dotnet' {
        $json = Invoke-Publish -repositoryPath $EnvRepo -configuration DebugL -Json 2>$null | ConvertFrom-Json
        $json.data.success | Should -BeFalse
        Should -Invoke -ModuleName Invoke-Publish dotnet -Times 0
    }

    It 'Test-OctoPathInLane accepts the lane root and paths below it only' {
        Test-OctoPathInLane -path $EnvRepo -laneRoot $EnvLane | Should -BeTrue
        Test-OctoPathInLane -path $EnvLane -laneRoot $EnvLane | Should -BeTrue
        Test-OctoPathInLane -path $EnvRepo -laneRoot $MainLane | Should -BeFalse
        # A sibling whose name starts with the lane name is not inside it.
        Test-OctoPathInLane -path "$MainLane-other/mm-common" -laneRoot $MainLane | Should -BeFalse
    }

    It 'Test-OctoPathInLane handles a lane at the filesystem root' {
        $root = [IO.Path]::GetPathRoot($EnvLane)
        Test-OctoPathInLane -path (Join-Path $root 'mm-common') -laneRoot $root | Should -BeTrue
        Test-OctoPathInLane -path $root -laneRoot $root | Should -BeTrue
        Test-OctoPathInLane -path $root -laneRoot $EnvLane | Should -BeFalse
    }
}
