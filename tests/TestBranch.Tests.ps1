#Requires -Modules Pester
<#
    Pester tests for New-/Sync-/Remove-TestBranch and OctoTestBranch.psm1 (AB#9259): checkout directory of a
    pre-release line, fresh origin/main as the base, dirty repositories reported, the repository set shared with
    Invoke-CloneMainRepos, explicit -branch. Everything runs against local bare "origin" repositories in
    TestDrive (no network, no real checkout).

    Run:  Invoke-Pester ./tests/TestBranch.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'OctoTestBranch.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-CloneMainRepos.psm1') -Force
    Import-Module (Join-Path $modules 'New-TestBranch.psm1') -Force
    Import-Module (Join-Path $modules 'Sync-TestBranch.psm1') -Force
    Import-Module (Join-Path $modules 'Remove-TestBranch.psm1') -Force

    $script:SavedGit = @{}
    foreach ($name in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') {
        $script:SavedGit[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, 'test')
    }
    $script:SavedRootPath = $global:rootPath

    # Repositories of the fixture: three from the shared list plus one that is not in it.
    $script:Repos = @('mm-common', 'octo-sdk', 'octo-cli')
    $script:Other = 'octo-unlisted'

    function script:Invoke-TestGit([string]$path, [string[]]$gitArgs) {
        $out = & (Get-Command git -CommandType Application | Select-Object -First 1) -C $path @gitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($gitArgs -join ' ') failed in ${path}: $out" }
        $out
    }

    # <ws>/remotes/<name>.git (bare origin), <ws>/seed/<name> (pushes new commits to origin),
    # <ws>/main = rootPath, <ws>/<lineDir>/<name> = checkouts of the given repos.
    function script:New-Workspace([string]$ws, [string]$lineDir, [string[]]$names) {
        New-Item -ItemType Directory -Path (Join-Path $ws 'main') -Force | Out-Null
        foreach ($name in $names) {
            $bare = Join-Path $ws "remotes/$name.git"
            $seed = Join-Path $ws "seed/$name"
            New-Item -ItemType Directory -Path $bare, $seed -Force | Out-Null
            Invoke-TestGit $bare @('init', '--bare', '-b', 'main') | Out-Null
            Invoke-TestGit $seed @('init', '-b', 'main') | Out-Null
            Set-Content -Path (Join-Path $seed 'file.txt') -Value 'one'
            Invoke-TestGit $seed @('add', '.') | Out-Null
            Invoke-TestGit $seed @('commit', '-m', 'one') | Out-Null
            Invoke-TestGit $seed @('remote', 'add', 'origin', $bare) | Out-Null
            Invoke-TestGit $seed @('push', '-u', 'origin', 'main') | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $ws $lineDir) -Force | Out-Null
            & git clone -q $bare (Join-Path $ws "$lineDir/$name") 2>&1 | Out-Null
        }
    }

    function script:Add-OriginCommit([string]$ws, [string]$name, [string]$text) {
        $seed = Join-Path $ws "seed/$name"
        Set-Content -Path (Join-Path $seed 'file.txt') -Value $text
        Invoke-TestGit $seed @('commit', '-am', $text) | Out-Null
        Invoke-TestGit $seed @('push', 'origin', 'main') | Out-Null
        (Invoke-TestGit $seed @('rev-parse', 'HEAD')) | Select-Object -First 1
    }
}

AfterAll {
    foreach ($name in $script:SavedGit.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedGit[$name]) }
    $global:rootPath = $script:SavedRootPath
}

Describe 'Resolve-OctoTestBranchRoot' {
    It 'uses the parent of rootPath plus 0.n-description without -branch' {
        $root = Join-Path $TestDrive 'meshmakers/main'
        $dir = Resolve-OctoTestBranchRoot -MinorVersion 3 -Description 'demo' -RootPath $root
        $dir | Should -Be (Join-Path $TestDrive 'meshmakers/0.3-demo')
    }

    It 'keeps an explicit -branch relative to rootPath' {
        $root = Join-Path $TestDrive 'meshmakers/main'
        $dir = Resolve-OctoTestBranchRoot -MinorVersion 3 -Description 'demo' -Branch '../demo' -RootPath $root
        $dir | Should -Be (Join-Path $root '../demo')
    }
}

Describe 'repository set' {
    It 'is the list of Invoke-CloneMainRepos, including mm-common' {
        $global:rootPath = Join-Path $TestDrive 'clone/main'
        New-Item -ItemType Directory -Path $global:rootPath -Force | Out-Null
        Mock Clone-Repo { } -ModuleName Invoke-CloneMainRepos
        $json = Invoke-CloneMainRepos -branch '../line' -Json | ConvertFrom-Json
        @($json.data.repositories.repo) | Should -Be @(Get-OctoMainRepoNames)
        Get-OctoMainRepoNames | Should -Contain 'mm-common'
        Get-OctoMainRepoNames | Should -Contain 'octo-frontend-refinery-studio'
    }

    It 'lists only the checkouts a directory holds (older lines such as dev keep working)' {
        $ws = Join-Path $TestDrive 'set'
        New-Workspace $ws 'dev' @('octo-sdk', $script:Other)
        @(Get-OctoTestBranchRepoDirectories -Root (Join-Path $ws 'dev')).Name | Should -Be @('octo-sdk')
    }
}

Describe 'New-TestBranch' {
    BeforeEach {
        $script:Ws = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Workspace $script:Ws '0.3-demo' ($script:Repos + $script:Other)
        $global:rootPath = Join-Path $script:Ws 'main'
        $script:Line = Join-Path $script:Ws '0.3-demo'
    }

    It 'branches every listed repository from a freshly fetched origin/main, not from what is checked out' {
        # octo-sdk sits on a stale feature branch, origin/main has moved on
        Invoke-TestGit (Join-Path $script:Line 'octo-sdk') @('checkout', '-b', 'feature') | Out-Null
        Set-Content -Path (Join-Path $script:Line 'octo-sdk/feature.txt') -Value 'x'
        Invoke-TestGit (Join-Path $script:Line 'octo-sdk') @('add', '.') | Out-Null
        Invoke-TestGit (Join-Path $script:Line 'octo-sdk') @('commit', '-m', 'feature') | Out-Null
        $heads = @{}
        foreach ($name in $script:Repos) { $heads[$name] = Add-OriginCommit $script:Ws $name 'two' }

        New-TestBranch -MinorVersion 3 -Description 'demo' -NoPush | Out-Null

        $LASTEXITCODE | Should -Be 0
        foreach ($name in $script:Repos) {
            $path = Join-Path $script:Line $name
            (Invoke-TestGit $path @('branch', '--show-current')) | Should -Be 'test/0.3-demo'
            (Invoke-TestGit $path @('rev-parse', 'HEAD')) | Select-Object -First 1 | Should -Be $heads[$name]
        }
        # a repository that is not in the shared list is left alone
        (Invoke-TestGit (Join-Path $script:Line $script:Other) @('branch', '--show-current')) | Should -Be 'main'
    }

    It 'pushes the new branch unless -NoPush' {
        New-TestBranch -MinorVersion 3 -Description 'demo' | Out-Null
        foreach ($name in $script:Repos) {
            (Invoke-TestGit (Join-Path $script:Ws "remotes/$name.git") @('branch', '--list', 'test/0.3-demo')) | Should -Not -BeNullOrEmpty
        }
    }

    It 'reports a dirty repository instead of branching it and exits non-zero' {
        Set-Content -Path (Join-Path $script:Line 'octo-cli/file.txt') -Value 'local edit'

        $out = [System.Collections.Generic.List[object]]::new()
        { New-TestBranch -MinorVersion 3 -Description 'demo' -NoPush -Json 2>$null | ForEach-Object { $out.Add($_) } } | Should -Throw '*not branched*'
        $json = $out | ConvertFrom-Json

        $LASTEXITCODE | Should -Be 1
        $json.data.success | Should -BeFalse
        $json.data.exitCode | Should -Be 1
        $cli = $json.data.repositories | Where-Object repo -eq 'octo-cli'
        $cli.status | Should -Be 'Dirty'
        $cli.Success | Should -BeFalse
        $cli.reason | Should -Match 'uncommitted'
        $json.data.summary.dirty | Should -Be 1
        $json.data.summary.created | Should -Be 2
        (Invoke-TestGit (Join-Path $script:Line 'octo-cli') @('branch', '--list', 'test/0.3-demo')) | Should -BeNullOrEmpty
        (Invoke-TestGit (Join-Path $script:Line 'octo-cli') @('branch', '--show-current')) | Should -Be 'main'
    }

    It 'ends a pwsh -Command run with exit code 1 when a repository is dirty' {
        Set-Content -Path (Join-Path $script:Line 'octo-cli/file.txt') -Value 'local edit'
        $modules = (Resolve-Path (Join-Path $PSScriptRoot '../modules')).Path
        $cmd = "`$global:rootPath = '$($global:rootPath)'; " +
            "foreach (`$m in 'OctoJsonOutput','OctoTestBranch','New-TestBranch') { Import-Module '$modules/'+`$m+'.psm1' }; " +
            "New-TestBranch -MinorVersion 3 -Description demo -NoPush -Json"
        & (Get-Command pwsh -CommandType Application | Select-Object -First 1) -NoProfile -Command $cmd *> $null
        $LASTEXITCODE | Should -Be 1
    }

    It 'does not create or push anything under -WhatIf' {
        New-TestBranch -MinorVersion 3 -Description 'demo' -NoPush | Out-Null
        New-TestBranch -MinorVersion 3 -Description 'demo' -WhatIf | Out-Null
        foreach ($name in $script:Repos) {
            (Invoke-TestGit (Join-Path $script:Ws "remotes/$name.git") @('branch', '--list', 'test/0.3-demo')) | Should -BeNullOrEmpty
        }
    }

    It 'switches to a branch that already exists instead of recreating it' {
        New-TestBranch -MinorVersion 3 -Description 'demo' -NoPush | Out-Null
        foreach ($name in $script:Repos) { Invoke-TestGit (Join-Path $script:Line $name) @('checkout', 'main') | Out-Null }

        $json = New-TestBranch -MinorVersion 3 -Description 'demo' -NoPush -Json | ConvertFrom-Json

        $json.data.summary.switched | Should -Be 3
        $json.data.summary.created | Should -Be 0
        $LASTEXITCODE | Should -Be 0
    }

    It 'publishes a branch made earlier with -NoPush when run again without it' {
        New-TestBranch -MinorVersion 3 -Description 'demo' -NoPush | Out-Null
        New-TestBranch -MinorVersion 3 -Description 'demo' | Out-Null
        foreach ($name in $script:Repos) {
            (Invoke-TestGit (Join-Path $script:Ws "remotes/$name.git") @('branch', '--list', 'test/0.3-demo')) | Should -Not -BeNullOrEmpty
        }
    }

    It 'switches to a branch that exists only on origin (created by another clone)' {
        New-TestBranch -MinorVersion 3 -Description 'demo' | Out-Null
        foreach ($name in $script:Repos) {
            $p = Join-Path $script:Line $name
            Invoke-TestGit $p @('checkout', 'main') | Out-Null
            Invoke-TestGit $p @('branch', '-D', 'test/0.3-demo') | Out-Null
        }
        $json = New-TestBranch -MinorVersion 3 -Description 'demo' -Json | ConvertFrom-Json
        $json.data.summary.switched | Should -Be 3
        (Invoke-TestGit (Join-Path $script:Line 'octo-sdk') @('branch', '--show-current')) | Should -Be 'test/0.3-demo'
    }

    It 'resolves a relative rootPath against the PowerShell location' {
        Push-Location $script:Ws
        try {
            Resolve-OctoTestBranchRoot -MinorVersion 3 -Description 'demo' -RootPath './main' | Should -Be (Join-Path (Resolve-Path .).Path '0.3-demo')
        } finally { Pop-Location }
    }

    It 'keeps an explicit -branch working (existing dev/demo checkouts)' {
        $ws = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Workspace $ws 'dev' @('octo-sdk')
        $global:rootPath = Join-Path $ws 'main'
        New-TestBranch -MinorVersion 2 -Description 'dev' -branch '../dev' -NoPush | Out-Null
        (Invoke-TestGit (Join-Path $ws 'dev/octo-sdk') @('branch', '--show-current')) | Should -Be 'test/0.2-dev'
        # the default directory of that line was not created
        Test-Path (Join-Path $ws '0.2-dev') | Should -BeFalse
    }

    It 'errors when the line directory does not exist' {
        { New-TestBranch -MinorVersion 9 -Description 'none' -NoPush -ErrorAction Stop } | Should -Throw '*does not exist*'
    }
}

Describe 'Sync-TestBranch and Remove-TestBranch' {
    BeforeEach {
        $script:Ws = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Workspace $script:Ws '0.3-demo' $script:Repos
        $global:rootPath = Join-Path $script:Ws 'main'
        $script:Line = Join-Path $script:Ws '0.3-demo'
        New-TestBranch -MinorVersion 3 -Description 'demo' | Out-Null
    }

    It 'Sync merges origin/main in the default directory, mm-common included' {
        $heads = @{}
        foreach ($name in $script:Repos) { $heads[$name] = Add-OriginCommit $script:Ws $name 'two' }

        $result = Sync-TestBranch -MinorVersion 3 -Description 'demo' -NoPush 6>$null

        $result.Summary.Synced | Should -Be 3
        foreach ($name in $script:Repos) {
            (Invoke-TestGit (Join-Path $script:Line $name) @('merge-base', '--is-ancestor', $heads[$name], 'HEAD')) | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
        ($result.Status.Repository | Sort-Object) | Should -Be ($script:Repos | Sort-Object)
    }

    It 'Remove deletes the branch in the default directory, mm-common included' {
        Remove-TestBranch -MinorVersion 3 -Description 'demo' -Confirm:$false 6>$null | Out-Null

        foreach ($name in $script:Repos) {
            (Invoke-TestGit (Join-Path $script:Line $name) @('branch', '--list', 'test/0.3-demo')) | Should -BeNullOrEmpty
            (Invoke-TestGit (Join-Path $script:Ws "remotes/$name.git") @('branch', '--list', 'test/0.3-demo')) | Should -BeNullOrEmpty
        }
    }
}
