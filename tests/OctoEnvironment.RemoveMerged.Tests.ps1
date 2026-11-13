#Requires -Modules Pester
<#
    Pester tests for Remove-OctoEnvironment after the environment's pull request was merged (AB#8953): a squash or
    rebase merge leaves the branch's commits on no remote (GitHub deletes the branch), yet nothing would be lost - the
    removal must go through, while real unpushed or unmerged work is still refused with the commits named.

    Part of the OctoEnvironment tests, split over several files so they can run in parallel
    (tests/Invoke-ParallelPester.ps1). Setup and fixtures: tests/OctoEnvironment.TestHelpers.ps1 - everything runs in
    TestDrive, see OctoEnvironment.Tests.ps1.

    Run:  Invoke-Pester ./tests/OctoEnvironment.RemoveMerged.Tests.ps1
#>

BeforeAll {
    . (Join-Path $PSScriptRoot 'OctoEnvironment.TestHelpers.ps1')

    # A commit in the environment's octo-sdk worktree.
    function Add-WorktreeCommit([string]$file, [string]$content, [string]$message) {
        Set-Content -Path (Join-Path $script:wt $file) -Value $content
        Invoke-TestGit $script:wt add -A | Out-Null
        Invoke-TestGit $script:wt commit -q -m $message | Out-Null
        return [string](Invoke-TestGit $script:wt rev-parse HEAD)
    }

    # Changes main on origin from a second clone (the "merge on GitHub"); the base checkout's origin/main stays stale,
    # Remove-OctoEnvironment has to fetch it.
    function Invoke-OnOrigin([scriptblock]$change) {
        $clone = Join-Path $TestDrive "clones/sdk-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
        Invoke-TestGit $TestDrive clone -q (Join-Path $TestDrive 'origins/octo-sdk.git') $clone | Out-Null
        Invoke-TestGit $clone remote add env (Join-Path $script:ws.Main 'octo-sdk') | Out-Null
        Invoke-TestGit $clone fetch -q env 'feature/m' | Out-Null
        & $change $clone
        Invoke-TestGit $clone push -q origin main | Out-Null
    }

    function Get-SdkState($doc) { return @($doc.data.repos | Where-Object name -eq 'octo-sdk')[0] }
}

AfterAll { Restore-OctoEnvironmentTestState }

Describe 'Remove-OctoEnvironment after a merged pull request (AB#8953)' {
    BeforeEach {
        $script:ws = New-FakeWorkspace
        New-OctoEnvironment -env 'env-m' -repos octo-sdk -branchName 'feature/m' -Json | Out-Null
        $script:wt = Join-Path $ws.Root 'wt-env-m/octo-sdk'
    }

    It 'removes the environment after a squash merge (the branch is on no remote)' {
        Add-WorktreeCommit 'a.txt' 'a' 'first change' | Out-Null
        Add-WorktreeCommit 'b.txt' 'b' 'second change' | Out-Null
        Invoke-OnOrigin { param($clone)
            Invoke-TestGit $clone merge -q --squash FETCH_HEAD | Out-Null
            Invoke-TestGit $clone commit -q -m 'feature m (#1)' | Out-Null }

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeTrue
        $state = Get-SdkState $doc
        $state.unpushed | Should -Be 2
        @($state.unpushedCommits) -join ' ' | Should -Match 'first change'
        $state.merged | Should -BeTrue
        $state.mergedVia | Should -Be 'tree'
        $state.mergedInto | Should -Be 'origin/main'
        @($state.unmergedCommits).Count | Should -Be 0
        Test-Path (Join-Path $ws.Root 'wt-env-m') | Should -BeFalse
        # the feature branch is kept
        Invoke-TestGit (Join-Path $ws.Main 'octo-sdk') rev-parse --verify --quiet 'refs/heads/feature/m' | Should -Not -BeNullOrEmpty
    }

    It 'recognises a squash merge whose files main changed again later (patch id of the whole change)' {
        Add-WorktreeCommit 'a.txt' "line 1`nline 2`nline 3`nline 4`nline 5`nline 6`nline 7`nline 8" 'first change' | Out-Null
        Add-WorktreeCommit 'b.txt' 'b' 'second change' | Out-Null
        Invoke-OnOrigin { param($clone)
            Invoke-TestGit $clone merge -q --squash FETCH_HEAD | Out-Null
            Invoke-TestGit $clone commit -q -m 'feature m (#1)' | Out-Null
            Set-Content -Path (Join-Path $clone 'a.txt') -Value "line 1`nline 2`nline 3`nline 4`nline 5`nline 6`nline 7`nline 8 changed later"
            Invoke-TestGit $clone commit -q -am 'later change on main' | Out-Null }

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeTrue
        (Get-SdkState $doc).mergedVia | Should -Be 'squash'
    }

    It 'removes the environment after a rebase merge (patch-equivalent commits on main)' {
        Add-WorktreeCommit 'a.txt' 'a' 'first change' | Out-Null
        Add-WorktreeCommit 'b.txt' 'b' 'second change' | Out-Null
        Invoke-OnOrigin { param($clone)
            # main moved on before the merge, so the rebased commits get new hashes
            Set-Content -Path (Join-Path $clone 'other.txt') -Value 'other'
            Invoke-TestGit $clone add -A | Out-Null
            Invoke-TestGit $clone commit -q -m 'other work on main' | Out-Null
            Invoke-TestGit $clone cherry-pick 'FETCH_HEAD~1' 'FETCH_HEAD' | Out-Null }

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeTrue
        $state = Get-SdkState $doc
        $state.merged | Should -BeTrue
        $state.mergedVia | Should -Be 'patch'
    }

    It 'removes the environment after a fast-forward merge the base checkout has not fetched yet' {
        Add-WorktreeCommit 'a.txt' 'a' 'first change' | Out-Null
        Invoke-OnOrigin { param($clone) Invoke-TestGit $clone merge -q --ff-only FETCH_HEAD | Out-Null }

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeTrue
        (Get-SdkState $doc).mergedVia | Should -Be 'patch'
    }

    It 'refuses unmerged work and names the commits' {
        $sha = Add-WorktreeCommit 'a.txt' 'a' 'work nobody has'
        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match "octo-sdk: 1 unpushed commit\(s\), 1 not on origin/main: $($sha.Substring(0, 7))\w* work nobody has"
        $state = Get-SdkState $doc
        $state.merged | Should -BeFalse
        @($state.unmergedCommits) -join ' ' | Should -Match 'work nobody has'
        Test-Path $wt | Should -BeTrue
    }

    It 'refuses when only part of the branch reached main and names only the missing commit' {
        Add-WorktreeCommit 'a.txt' 'a' 'merged part' | Out-Null
        Add-WorktreeCommit 'b.txt' 'b' 'committed after the merge' | Out-Null
        Invoke-OnOrigin { param($clone)
            Set-Content -Path (Join-Path $clone 'other.txt') -Value 'other'
            Invoke-TestGit $clone add -A | Out-Null
            Invoke-TestGit $clone commit -q -m 'other work on main' | Out-Null
            Invoke-TestGit $clone cherry-pick 'FETCH_HEAD~1' | Out-Null }

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match '2 unpushed commit\(s\), 1 not on origin/main: \w+ committed after the merge'
        $doc.data.error | Should -Not -Match 'merged part'
        Test-Path $wt | Should -BeTrue
    }

    It 'refuses a dirty worktree although its commits were squash-merged' {
        Add-WorktreeCommit 'a.txt' 'a' 'first change' | Out-Null
        Invoke-OnOrigin { param($clone)
            Invoke-TestGit $clone merge -q --squash FETCH_HEAD | Out-Null
            Invoke-TestGit $clone commit -q -m 'feature m (#1)' | Out-Null }
        Set-Content -Path (Join-Path $wt 'untracked.txt') -Value 'x'

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'octo-sdk: uncommitted changes'
        $doc.data.error | Should -Not -Match 'unpushed'
        (Get-SdkState $doc).merged | Should -BeTrue
        Test-Path $wt | Should -BeTrue
    }

    It 'reads the dirty state again right before the removal (edits made during the merge checks are kept)' {
        Add-WorktreeCommit 'a.txt' 'a' 'first change' | Out-Null
        Invoke-OnOrigin { param($clone)
            Invoke-TestGit $clone merge -q --squash FETCH_HEAD | Out-Null
            Invoke-TestGit $clone commit -q -m 'feature m (#1)' | Out-Null }
        # an edit that lands while the merge check runs (the check fetches origin's default branch)
        Mock -ModuleName OctoEnvironment Resolve-OctoEnvironmentDefaultBranch {
            Set-Content -Path (Join-Path $script:wt 'edited-meanwhile.txt') -Value 'x'
            [pscustomobject]@{ Ref = 'origin/main'; Fetched = $true; Note = $null }
        }
        Invoke-TestGit $wt fetch -q origin main | Out-Null

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'octo-sdk: uncommitted changes'
        Test-Path (Join-Path $wt 'edited-meanwhile.txt') | Should -BeTrue
    }

    It 'refuses and names the commits when the base branch cannot be fetched' {
        Add-WorktreeCommit 'a.txt' 'a' 'first change' | Out-Null
        Invoke-TestGit $wt remote set-url origin (Join-Path $TestDrive 'origins/does-not-exist.git') | Out-Null
        Invoke-TestGit $wt update-ref -d 'refs/remotes/origin/main' | Out-Null

        $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
        $doc.data.success | Should -BeFalse
        $doc.data.error | Should -Match 'octo-sdk: 1 unpushed commit\(s\): \w+ first change'
        (Get-SdkState $doc).mergeCheck | Should -Not -BeNullOrEmpty
    }

    Context 'merged pull request (gh)' {
        BeforeEach {
            # origin as a GitHub URL, fetched from the local bare repository (insteadOf).
            Invoke-TestGit $wt config --global "url.$(Join-Path $TestDrive 'origins/octo-sdk.git').insteadOf" 'https://github.com/meshmakers/octo-sdk.git' | Out-Null
            Invoke-TestGit $wt remote set-url origin 'https://github.com/meshmakers/octo-sdk.git' | Out-Null
            # a merge on GitHub that none of the git checks recognises: main also changed the PR's file differently
            $script:head = Add-WorktreeCommit 'a.txt' 'a' 'first change'
            Invoke-OnOrigin { param($clone)
                Set-Content -Path (Join-Path $clone 'a.txt') -Value 'resolved on GitHub'
                Invoke-TestGit $clone add -A | Out-Null
                Invoke-TestGit $clone commit -q -m 'feature m, conflict resolved (#7)' | Out-Null }
        }
        AfterEach { Invoke-TestGit $TestDrive config --global --remove-section "url.$(Join-Path $TestDrive 'origins/octo-sdk.git')" | Out-Null }

        It 'removes the environment when a merged pull request of the branch has HEAD as its head' {
            Mock -ModuleName OctoEnvironment Invoke-OctoEnvironmentGh {
                [pscustomobject]@{ ExitCode = 0; Output = @("[{""number"":7,""url"":""https://github.com/meshmakers/octo-sdk/pull/7"",""headRefOid"":""$script:head""}]") }
            }
            $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
            $doc.data.success | Should -BeTrue
            $state = Get-SdkState $doc
            $state.mergedVia | Should -Be 'pullRequest'
            $state.pullRequest.number | Should -Be 7
            Should -Invoke -ModuleName OctoEnvironment Invoke-OctoEnvironmentGh -Times 1 -ParameterFilter {
                ($arguments -join ' ') -match '^pr list --repo meshmakers/octo-sdk --head feature/m --state merged --base main '
            }
        }

        It 'refuses when the merged pull request''s head is not HEAD (commits after the merge)' {
            Mock -ModuleName OctoEnvironment Invoke-OctoEnvironmentGh {
                [pscustomobject]@{ ExitCode = 0; Output = @('[{"number":7,"url":"https://github.com/meshmakers/octo-sdk/pull/7","headRefOid":"0000000000000000000000000000000000000000"}]') }
            }
            $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
            $doc.data.success | Should -BeFalse
            $doc.data.error | Should -Match '1 not on origin/main: \w+ first change'
        }

        It 'refuses when the merged pull request went into another branch than the default branch' {
            # gh filters by --base: a PR of the branch merged into release/x is not listed for --base main.
            Mock -ModuleName OctoEnvironment Invoke-OctoEnvironmentGh {
                $into = $arguments[[Array]::IndexOf($arguments, '--base') + 1]
                $json = if ($into -eq 'release/x') { "[{""number"":8,""url"":""https://github.com/meshmakers/octo-sdk/pull/8"",""headRefOid"":""$script:head""}]" } else { '[]' }
                [pscustomobject]@{ ExitCode = 0; Output = @($json) }
            }
            $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
            $doc.data.success | Should -BeFalse
            (Get-SdkState $doc).merged | Should -BeFalse
        }

        It 'refuses without gh' {
            $doc = Get-Doc (Remove-OctoEnvironment -env 'env-m' -Json)
            $doc.data.success | Should -BeFalse
            (Get-SdkState $doc).merged | Should -BeFalse
        }
    }
}
