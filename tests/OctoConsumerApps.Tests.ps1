#Requires -Modules Pester
<#
    Pester tests for consumer apps (AB#8819): repositories that are neither mm-* nor octo-* (energy-community,
    voest-app) in the build order of a feature environment, and their frontend tests in Invoke-OctoTestRun.

    Nothing real runs: the lane and the environment are folders in TestDrive, `ng test` is the mocked seam
    Invoke-OctoFrontendTest (it copies a canned JUnit report from tests/fixtures/junit), no npm, no node.

    Run:  Invoke-Pester ./tests/OctoConsumerApps.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    foreach ($module in 'OctoJsonOutput', 'Get-OctoLaneBuildSettings', 'OctoBuildOrder', 'Copy-NuGetPackages', 'Invoke-KillDotnet', 'Stop-Octo', 'Invoke-Publish',
        'Invoke-BuildAll', 'Sync-OctoCkIntermediateVersions', 'OctoBuildStamp', 'OctoCkCatalogRefresh', 'Invoke-BuildRange', 'OctoEnvironment', 'OctoTests') {
        Import-Module (Join-Path $modules "$module.psm1") -Force
    }

    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/junit'
    $script:PreviousRootPath = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    $script:SavedLockPath = $env:OCTO_TEST_LOCK_PATH
    # A run never reaches the real machine-wide lock.
    $env:OCTO_TEST_LOCK_PATH = Join-Path $TestDrive 'locks/default.lock'

    function Get-Doc([object[]]$output) { return (($output -join "`n") | ConvertFrom-Json) }

    # An app repository: build.ps1 and an Angular workspace with a "test" script below src/<name>.
    function New-TestApp([string]$path, [string]$workspace = 'web', [switch]$noTestScript) {
        $app = Join-Path $path "src/$workspace"
        New-Item -ItemType Directory -Force -Path $app, (Join-Path $path '.git'), (Join-Path $app 'node_modules/some-package') | Out-Null
        Set-Content -Path (Join-Path $path 'build.ps1') -Value '# builds ../octo-frontend-libraries, then the app'
        Set-Content -Path (Join-Path $app 'angular.json') -Value '{ "projects": {} }'
        $scripts = if ($noTestScript) { '{ "start": "ng serve" }' } else { '{ "start": "ng serve", "test": "ng test" }' }
        Set-Content -Path (Join-Path $app 'package.json') -Value "{ ""name"": ""$workspace"", ""scripts"": $scripts }"
        # A package below node_modules with its own workspace files: never a test project.
        Set-Content -Path (Join-Path $app 'node_modules/some-package/angular.json') -Value '{}'
        Set-Content -Path (Join-Path $app 'node_modules/some-package/package.json') -Value '{ "scripts": { "test": "x" } }'
        return $app
    }

    function New-TestLane {
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $main = Join-Path $root 'branches/main'
        foreach ($repo in 'mm-common', 'octo-sdk', 'octo-frontend-libraries', 'octo-zebra') { New-Item -ItemType Directory -Force -Path (Join-Path $main $repo) | Out-Null }
        Set-Content -Path (Join-Path $main 'Octo.User.props') -Value '<Project />'
        $app = New-TestApp (Join-Path $main 'my-app')
        # A folder that is neither a repository of the build order nor an app.
        New-Item -ItemType Directory -Force -Path (Join-Path $main 'notes') | Out-Null
        $global:rootPath = $root
        return [pscustomobject]@{ Root = $root; Main = $main; AppRepo = (Join-Path $main 'my-app'); App = $app }
    }

    # An environment folder with a manifest that names its repositories.
    function New-TestEnvironment([string]$root, [string]$name, [string[]]$repos) {
        $path = Join-Path $root "wt-$name"
        New-Item -ItemType Directory -Force -Path (Join-Path $path '.octo') | Out-Null
        Set-Content -Path (Join-Path $path 'Octo.User.props') -Value '<Project />'
        $entries = foreach ($repo in $repos) {
            if ($repo -like 'octo-*' -or $repo -like 'mm-*') { New-Item -ItemType Directory -Force -Path (Join-Path $path $repo) | Out-Null }
            else { [void](New-TestApp (Join-Path $path $repo)) }
            [ordered]@{ name = $repo; role = 'feature'; path = (Join-Path $path $repo); branch = 'x'; baseCommit = 'abc' }
        }
        $manifest = [ordered]@{ schemaVersion = 1; name = $name; base = 'branches/main'; repos = @($entries) }
        Set-Content -Path (Join-Path $path '.octo/environment.json') -Value (ConvertTo-Json -InputObject $manifest -Depth 5)
        return $path
    }
}

AfterAll {
    $env:OCTO_TEST_LOCK_PATH = $script:SavedLockPath
    if ($null -ne $script:PreviousRootPath) { $global:rootPath = $script:PreviousRootPath } else { Remove-Variable -Name rootPath -Scope Global -ErrorAction SilentlyContinue }
}

Describe 'Get-OctoBuildOrder with consumer apps' {
    It 'never builds an app of a lane (branches/main holds the app repositories too)' {
        $lane = New-TestLane

        $names = @(Get-OctoBuildOrder -branchRootPath $lane.Main).Name

        $names | Should -Be @('mm-common', 'octo-sdk', 'octo-frontend-libraries', 'octo-zebra')
    }

    It 'builds the apps of an environment manifest last, in manifest order' {
        $lane = New-TestLane
        $environment = New-TestEnvironment $lane.Root 'ab1-apps' @('voest-app', 'octo-zebra', 'energy-community', 'octo-frontend-libraries')

        $order = @(Get-OctoBuildOrder -branchRootPath $environment)

        @($order.Name) | Should -Be @('octo-frontend-libraries', 'octo-zebra', 'voest-app', 'energy-community')
        @($order | Where-Object { $_.Group -eq 'app' } | ForEach-Object Name) | Should -Be @('voest-app', 'energy-community')
        ($order | Where-Object Name -eq 'voest-app').Path | Should -Be (Join-Path $environment 'voest-app')
        @(Get-OctoBuildOrder -branchRootPath $environment -excludeAdditional $true).Name | Should -Not -Contain 'voest-app'
    }

    It 'keeps the manifest order when an app is an in-place worktree (-additionalRepos)' {
        $lane = New-TestLane
        $elsewhere = Join-Path $lane.Root 'elsewhere/zz-inplace-app'
        [void](New-TestApp $elsewhere)
        # The manifest names the in-place app first, then two apps of the environment folder.
        $environment = New-TestEnvironment $lane.Root 'ab5-apps' @('voest-app', 'energy-community')
        $manifestPath = Join-Path $environment '.octo/environment.json'
        $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        $manifest['repos'] = @([ordered]@{ name = 'zz-inplace-app'; role = 'feature'; path = $elsewhere; branch = 'x'; baseCommit = 'abc' }) + @($manifest['repos'])
        Set-Content -Path $manifestPath -Value (ConvertTo-Json -InputObject $manifest -Depth 5)

        $order = @(Get-OctoBuildOrder -branchRootPath $environment -additionalRepos @{ 'zz-inplace-app' = $elsewhere; 'aa-unlisted-app' = $elsewhere })

        @($order | Where-Object { $_.Group -eq 'app' } | ForEach-Object Name) | Should -Be @('zz-inplace-app', 'voest-app', 'energy-community', 'aa-unlisted-app')
    }

    It 'leaves out a manifest repository without build.ps1 and a folder the manifest does not name' {
        $lane = New-TestLane
        $environment = New-TestEnvironment $lane.Root 'ab2-apps' @('my-app', 'docs-only')
        Remove-Item (Join-Path $environment 'docs-only/build.ps1')
        [void](New-TestApp (Join-Path $environment 'not-in-manifest'))

        @(Get-OctoBuildOrder -branchRootPath $environment).Name | Should -Be @('my-app')
    }

    It 'takes an app from -additionalRepos (in-place worktree) and refuses a folder without build.ps1' {
        $lane = New-TestLane
        $elsewhere = Join-Path $lane.Root 'elsewhere/my-app'
        [void](New-TestApp $elsewhere)
        $plain = Join-Path $lane.Root 'elsewhere/plain'
        New-Item -ItemType Directory -Force -Path $plain | Out-Null

        $order = @(Get-OctoBuildOrder -branchRootPath $lane.Main -additionalRepos @{ 'other-app' = $elsewhere })
        $order[-1].Name | Should -Be 'other-app'
        $order[-1].Group | Should -Be 'app'
        $order[-1].Path | Should -Be $elsewhere

        { Get-OctoBuildOrder -branchRootPath $lane.Main -additionalRepos @{ 'plain' = $plain } } | Should -Throw '*no build.ps1*'
    }
}

Describe 'Frontend test projects' {
    It 'finds the Angular workspace with a test script, not node_modules and not a workspace without one' {
        $lane = New-TestLane
        [void](New-TestApp $lane.AppRepo 'tools' -noTestScript)

        InModuleScope OctoTests -Parameters @{ repo = $lane.AppRepo } {
            $projects = @(Get-OctoFrontendTestProjects -repositoryPath $repo)
            @($projects.Name) | Should -Be @('web')
            $projects[0].Kind | Should -Be 'frontend'
            $projects[0].Path | Should -Be (Join-Path $repo 'src/web/package.json')
            $projects[0].RelativePath | Should -Be 'src/web/package.json'
            $projects[0].Docker | Should -BeFalse
            Test-OctoFrontendTestProject $projects[0] | Should -BeTrue
            Test-OctoFrontendTestProject ([pscustomobject]@{ Name = 'Sample.UnitTests' }) | Should -BeFalse
        }
    }

    It 'reads a JUnit report: counts, and each failed test with its spec file, message and place' {
        InModuleScope OctoTests -Parameters @{ file = (Join-Path $script:Fixtures 'mixed.junit.xml') } {
            $report = Read-OctoJUnitFile -path $file
            $report.Total | Should -Be 4
            $report.Passed | Should -Be 1
            $report.Failed | Should -Be 2
            $report.Skipped | Should -Be 1
            $report.DurationSeconds | Should -BeGreaterThan 0.29
            @($report.FailedTests.Name) | Should -Be @('src/app/orders/order.service.spec.ts :: OrderService > rejects an empty order', 'src/app/config/mail.spec.ts')
            $report.FailedTests[0].Message | Should -Be 'expected 4 to be 5 // Object.is equality'
            $report.FailedTests[0].StackFrame | Should -Be 'src/app/orders/order.service.spec.ts:42:18'
            $report.FailedTests[1].Message | Should -BeLike "ENOENT*'../../data/template.yaml'"
        }
    }
}

Describe 'Frontend test projects in unusual layouts' {
    It 'gives two workspaces in folders of the same name distinct names, and looks below a workspace without a test script' {
        $lane = New-TestLane
        $repo = Join-Path $lane.Main 'multi-app'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo '.git') | Out-Null
        foreach ($folder in 'apps/web', 'tools/web', 'shell', 'shell/projects/inner') {
            New-Item -ItemType Directory -Force -Path (Join-Path $repo $folder) | Out-Null
            Set-Content -Path (Join-Path $repo "$folder/angular.json") -Value '{}'
            $scripts = if ($folder -eq 'shell') { '{ "start": "ng serve" }' } else { '{ "test": "ng test" }' }
            Set-Content -Path (Join-Path $repo "$folder/package.json") -Value "{ ""scripts"": $scripts }"
        }

        InModuleScope OctoTests -Parameters @{ repo = $repo } {
            $projects = @(Get-OctoFrontendTestProjects -repositoryPath $repo)
            @($projects.Name | Sort-Object) | Should -Be @('apps.web', 'inner', 'tools.web')
            ($projects | Where-Object Name -eq 'tools.web').Directory | Should -Be (Join-Path $repo 'tools/web')
            (Resolve-OctoTestProject -name 'apps.web' -projects $projects).Directory | Should -Be (Join-Path $repo 'apps/web')
        }

        # Each one keeps its own results folder and last-result.json.
        Mock -ModuleName OctoTests Invoke-OctoFrontendTest {
            $output = @($arguments | Where-Object { $_ -like '--output-file=*' }) | Select-Object -First 1
            Copy-Item -Path (Join-Path $script:Fixtures 'mixed.junit.xml') -Destination $output.Substring('--output-file='.Length)
            return 1
        }
        $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo multi-app -Json)
        @($doc.data.projects.project | Sort-Object) | Should -Be @('apps.web', 'inner', 'tools.web')
        foreach ($name in 'apps.web', 'tools.web') {
            Test-Path (Join-Path $lane.Main "logFiles/test-results/multi-app/$name/last-result.json") | Should -BeTrue
        }
    }
}

Describe 'A consumer app and the frontend libraries it builds against' {
    BeforeAll {
        $script:SavedGit = @{}
        $gitEnv = @{
            GIT_CONFIG_GLOBAL = (Join-Path $TestDrive 'gitconfig'); GIT_CONFIG_NOSYSTEM = '1'
            GIT_AUTHOR_NAME = 'Pester'; GIT_AUTHOR_EMAIL = 'pester@example.invalid'; GIT_COMMITTER_NAME = 'Pester'; GIT_COMMITTER_EMAIL = 'pester@example.invalid'
        }
        foreach ($name in $gitEnv.Keys) { $script:SavedGit[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $gitEnv[$name]) }
        Set-Content -Path $gitEnv.GIT_CONFIG_GLOBAL -Value "[init]`n`tdefaultBranch = main"
        function Initialize-TestGitRepo([string]$path) {
            if (Test-Path (Join-Path $path '.git')) { Remove-Item (Join-Path $path '.git') -Recurse -Force }
            Set-Content -Path (Join-Path $path '.gitignore') -Value "node_modules/`nbin/`ndist/"
            foreach ($arguments in @(@('init', '-q'), @('add', '-A'), @('commit', '-q', '-m', 'initial'))) {
                $output = & git -C $path @arguments 2>&1
                if ($LASTEXITCODE -ne 0) { throw "git $($arguments -join ' ') failed in ${path}: $output" }
            }
        }
    }
    AfterAll {
        foreach ($name in $script:SavedGit.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedGit[$name]) }
    }

    It 'builds the unchanged app again when octo-frontend-libraries was built after it' {
        $lane = New-TestLane
        $environment = New-TestEnvironment $lane.Root 'ab6-apps' @('octo-frontend-libraries', 'my-app')
        Set-Content -Path (Join-Path $environment 'octo-frontend-libraries/build.ps1') -Value '# builds the libraries'
        Set-Content -Path (Join-Path $environment 'octo-frontend-libraries/index.ts') -Value 'export const a = 1;'
        Initialize-TestGitRepo (Join-Path $environment 'octo-frontend-libraries')
        Initialize-TestGitRepo (Join-Path $environment 'my-app')
        $script:built = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo { $script:built.Add($entry.Name); [pscustomobject]@{ Success = $true; LogFile = $null } }
        $run = { param([string]$from = 'octo-frontend-libraries') Get-Doc (Invoke-BuildRange -branch 'wt-ab6-apps' -from $from -to my-app -excludeFrontend $false -skipUnchanged -Json) }

        @((& $run).data.repositories.status) | Should -Be @('built', 'built')
        @((& $run).data.repositories.status) | Should -Be @('skipped', 'skipped')

        # The libraries change (no NuGet package involved) and are built alone; the app was left out of that run.
        Set-Content -Path (Join-Path $environment 'octo-frontend-libraries/index.ts') -Value 'export const a = 2;'
        $only = Get-Doc (Invoke-BuildRange -branch 'wt-ab6-apps' -from octo-frontend-libraries -excludeFrontend $false -skipUnchanged -Json)
        $only.data.repositories[0].status | Should -Be 'built'

        $after = & $run
        $app = $after.data.repositories | Where-Object repo -eq 'my-app'
        $app.status | Should -Be 'built'
        $app.reason | Should -Be 'librariesBuilt'
        ($after.data.repositories | Where-Object repo -eq 'octo-frontend-libraries').status | Should -Be 'skipped'
        # and it is quiet again afterwards
        @((& $run).data.repositories.status) | Should -Be @('skipped', 'skipped')
        @($script:built) | Should -Be @('octo-frontend-libraries', 'my-app', 'octo-frontend-libraries', 'my-app')
    }
    It 'a parallel run (-maxParallel) treats apps like the sequential run: alone, in this process, after the libraries, librariesBuilt included' {
        $lane = New-TestLane
        $environment = New-TestEnvironment $lane.Root 'ab7-apps' @('octo-frontend-libraries', 'my-app', 'other-app')
        Set-Content -Path (Join-Path $environment 'octo-frontend-libraries/build.ps1') -Value '# builds the libraries'
        Set-Content -Path (Join-Path $environment 'octo-frontend-libraries/index.ts') -Value 'export const a = 1;'
        foreach ($repo in 'octo-frontend-libraries', 'my-app', 'other-app') { Initialize-TestGitRepo (Join-Path $environment $repo) }
        $script:built = [System.Collections.Generic.List[string]]::new()
        $script:overlap = 0
        $script:inBuild = 0
        Mock -ModuleName Invoke-BuildRange Get-OctoRunningRepoProcesses { @() }
        Mock -ModuleName Invoke-BuildRange Invoke-OctoBuildRangeRepo {
            $script:inBuild++; $script:overlap = [Math]::Max($script:overlap, $script:inBuild)
            $script:built.Add($entry.Name)
            $script:inBuild--
            [pscustomobject]@{ Success = $true; LogFile = $null }
        }
        # No child process may be started for a build.ps1 repository.
        Mock -ModuleName Invoke-BuildRange Start-OctoRepoBuildJob { throw "a child process was started for $($entry.Name)" }
        # The dependency information Invoke-BuildEnvironment passes: no package dependencies between these repositories.
        $inputs = @{ 'octo-frontend-libraries' = @{ packages = @(); dependsOn = @() }; 'my-app' = @{ packages = @(); dependsOn = @() }; 'other-app' = @{ packages = @(); dependsOn = @() } }
        $run = { param([int]$maxParallel) Get-Doc (Invoke-BuildRange -branch 'wt-ab7-apps' -from octo-frontend-libraries -to other-app -excludeFrontend $false -skipUnchanged -repoInputs $inputs -maxParallel $maxParallel -Json) }
        $summary = { param($doc) @($doc.data.repositories | ForEach-Object { "$($_.repo):$($_.status):$($_.reason)" }) }

        $first = & $run 3
        $first.data.parallel | Should -BeTrue
        @($first.data.repositories.status) | Should -Be @('built', 'built', 'built')
        @($script:built) | Should -Be @('octo-frontend-libraries', 'my-app', 'other-app')     # the libraries first, the apps in manifest order
        $script:overlap | Should -Be 1
        @((& $run 3).data.repositories.status) | Should -Be @('skipped', 'skipped', 'skipped')

        # The libraries change: in the same run both unchanged apps are built again, because the libraries were built before them.
        Set-Content -Path (Join-Path $environment 'octo-frontend-libraries/index.ts') -Value 'export const a = 2;'
        $script:built.Clear()
        $parallel = & $summary (& $run 3)
        $parallel | Should -Be @('octo-frontend-libraries:built:sourcesChanged', 'my-app:built:librariesBuilt', 'other-app:built:librariesBuilt')
        @($script:built) | Should -Be @('octo-frontend-libraries', 'my-app', 'other-app')

        # Exactly what the sequential run does with the same change.
        Set-Content -Path (Join-Path $environment 'octo-frontend-libraries/index.ts') -Value 'export const a = 3;'
        $script:built.Clear()
        $sequential = & $summary (& $run 1)
        $sequential | Should -Be $parallel
        @($script:built) | Should -Be @('octo-frontend-libraries', 'my-app', 'other-app')

        # The plan marks them as building alone.
        $plan = Get-Doc (Invoke-BuildRange -branch 'wt-ab7-apps' -from octo-frontend-libraries -to other-app -excludeFrontend $false -skipUnchanged -repoInputs $inputs -maxParallel 3 -WhatIf -Json)
        @($plan.data.repositories.exclusive | Select-Object -Unique) | Should -Be @($true)
        Should -Invoke -ModuleName Invoke-BuildRange Start-OctoRepoBuildJob -Times 0
    }
}


Describe 'Invoke-OctoTestRun for an app' {
    BeforeEach {
        $script:lane = New-TestLane
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        $script:Report = 'mixed.junit.xml'
        $script:ExitCode = 1
        Mock -ModuleName OctoTests Invoke-OctoFrontendTest {
            $script:Calls.Add([pscustomobject]@{ Directory = $directory; Arguments = @($arguments); LogFile = $logFile })
            $output = @($arguments | Where-Object { $_ -like '--output-file=*' }) | Select-Object -First 1
            if ($script:Report) { Copy-Item -Path (Join-Path $script:Fixtures $script:Report) -Destination $output.Substring('--output-file='.Length) }
            return [int]$script:ExitCode
        }
        Mock -ModuleName OctoTests Invoke-OctoDotnetTest { throw 'dotnet test must not run for a frontend project' }
    }

    It 'runs ng test headless with a JUnit report in the app folder of a lane and reports the failed tests' {
        $events = Join-Path $TestDrive "events-$([Guid]::NewGuid().ToString('N')).jsonl"

        $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo my-app -EventsFile $events -Json)

        $doc.data.success | Should -BeFalse
        $doc.data.failedStep | Should -Be 'tests'
        $doc.data.failedProject | Should -Be 'web'
        $doc.data.repo | Should -Be 'my-app'
        $doc.data.repoPath | Should -Be $lane.AppRepo
        $doc.data.totals.total | Should -Be 4
        $doc.data.totals.failed | Should -Be 2
        $doc.data.lock.required | Should -BeFalse

        $script:Calls | Should -HaveCount 1
        $script:Calls[0].Directory | Should -Be $lane.App
        ($script:Calls[0].Arguments -join ' ') | Should -Match '^ng test --watch=false --reporters=junit --output-file=.+results\.junit\.xml --reporters=default$'

        $project = $doc.data.projects[0]
        $project.project | Should -Be 'web'
        $project.state | Should -Be 'failed'
        $project.noBuild | Should -BeFalse
        $project.buildReason | Should -BeLike 'frontend tests*'
        $project.docker | Should -BeFalse
        @($project.failedTests.name) | Should -Be @('src/app/orders/order.service.spec.ts :: OrderService > rejects an empty order', 'src/app/config/mail.spec.ts')
        $project.failedTests[0].stackFrame | Should -Be 'src/app/orders/order.service.spec.ts:42:18'
        $project.logFile | Should -BeLike '*ng-test.log'
        @($project.trx)[0] | Should -BeLike '*results.junit.xml'

        $lines = @(Get-Content $events | ForEach-Object { $_ | ConvertFrom-Json })
        @($lines.event) | Should -Be @('plan', 'testProjectStart', 'testProjectDone', 'done')
        $lines[2].failed | Should -Be 2
        $lines[2].logFile | Should -BeLike '*ng-test.log'
    }

    It 'passes -filter on and reruns only the spec files that failed' {
        $null = Invoke-OctoTestRun -branch branches/main -repo my-app -filter 'OrderService' -Json
        ($script:Calls[0].Arguments -join ' ') | Should -Match ' --filter OrderService$'

        $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo my-app -rerunFailed -Json)

        $doc.data.projects[0].rerunCount | Should -Be 2
        ($script:Calls[1].Arguments -join ' ') | Should -Match ' --include src/app/config/mail\.spec\.ts --include src/app/orders/order\.service\.spec\.ts$'

        # -WhatIf names the spec files a rerun would run, and runs nothing
        $plan = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo my-app -rerunFailed -WhatIf -Json)
        @($plan.data.projects[0].rerunFiles) | Should -Be @('src/app/config/mail.spec.ts', 'src/app/orders/order.service.spec.ts')
        $text = @(Invoke-OctoTestRun -branch branches/main -repo my-app -rerunFailed -WhatIf 6>&1 | ForEach-Object { "$_" }) -join "`n"
        $text | Should -Match 'npx ng test with --include for 2 spec file\(s\)'
        $text | Should -Match '--include src/app/config/mail\.spec\.ts'
        $text | Should -Not -Match 'dotnet test call'
        $script:Calls | Should -HaveCount 2
    }

    It 'runs the app of an environment from its worktree' {
        $environment = New-TestEnvironment $lane.Root 'ab3-app' @('my-app', 'octo-frontend-libraries')

        $doc = Get-Doc (Invoke-OctoTestRun -env ab3-app -repo my-app -Json)

        $doc.data.environment | Should -Be 'ab3-app'
        $doc.data.repoPath | Should -Be (Join-Path $environment 'my-app')
        $script:Calls[0].Directory | Should -Be (Join-Path $environment 'my-app/src/web')
    }

    It 'reports a run without a report as an error with the lines of the log' {
        $script:Report = $null
        Mock -ModuleName OctoTests Invoke-OctoFrontendTest { Add-Content -LiteralPath $logFile -Value 'error TS2304: Cannot find name foo.'; return 1 }

        $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo my-app -Json)

        $doc.data.projects[0].state | Should -Be 'error'
        $doc.data.projects[0].errors | Should -Contain 'error TS2304: Cannot find name foo.'
    }

    It 'still refuses a lane folder that is no repository' {
        $doc = Get-Doc (Invoke-OctoTestRun -branch branches/main -repo notes -Json -ErrorAction SilentlyContinue)

        $doc.data.success | Should -BeFalse
        $doc.data.failedStep | Should -Be 'preflight'
        $doc.data.error | Should -BeLike '*notes*'
    }
}
