#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Test-OctoAgentDocs -Ci (Azure DevOps logging commands, the gate) and -RepositoryName.
# Fixtures are built under TestDrive by the helpers; ROOTPATH is cleared so the sibling
# root is the folder above each fixture, as in a pipeline checkout.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$Global:ROOTPATH and $global:LASTEXITCODE are the profile contract under test')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test fixtures under TestDrive; -WhatIf has no meaning here')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Get-CiOutput uses its parameters inside the script block Get-Output runs, which the rule does not follow')]
param()

BeforeAll {
    . (Join-Path $PSScriptRoot 'AgentDocs.TestHelpers.ps1')
    $script:SavedRoot = $Global:ROOTPATH
    $Global:ROOTPATH = $null
    $script:SiblingNote = '^Sibling rules skipped: '
    function Get-CiOutput {
        # The -Ci lines and the error the call threw, if any; the exit code is in $global:LASTEXITCODE.
        param([string]$Root, [hashtable]$Extra = @{})
        $result = [pscustomobject]@{ Lines = @(); Issues = @(); Error = $null }
        $lines = Get-Output { try { Test-OctoAgentDocs -Path $Root -Ci @Extra } catch { $result.Error = $_ } }
        $result.Lines = @($lines | Where-Object { $_ })
        $result.Issues = @($lines | Where-Object { $_ -like '##vso*' })
        return $result
    }
    function Get-SourcePattern {
        # The absolute, escaped sourcepath of a repository-relative file, as a regex.
        param([string]$Root, [string]$Relative)
        $full = [System.IO.Path]::GetFullPath((Join-Path $Root $Relative))
        return [regex]::Escape($full.Replace('%', '%AZP25').Replace(';', '%3B').Replace(']', '%5D'))
    }
    function New-WarningFixture {
        # Clean but for one warning-severity finding.
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":1}]}}'
        return $r
    }
}
AfterAll {
    $Global:ROOTPATH = $script:SavedRoot
    Remove-Fixture
}

Describe 'Test-OctoAgentDocs -Ci output' {
    It 'writes one logissue line per finding with type, file, line, rule id and the finding only' {
        $r = New-Fixture
        Write-File (Join-Path $r 'docs/two.md') "---`ndescription: Two.`napplies_to: nowhere/**`n---`n"
        Write-File (Join-Path $r 'docs/three.md') "---`ndescription: Three.`napplies_to: gone/**`n---`n"
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $findings = @((Get-Result $r).data.findings)
        $out = Get-CiOutput $r
        $out.Issues.Count | Should -Be $findings.Count
        @($out.Issues | Where-Object { $_ -like '*code=globs-match*' }).Count | Should -Be 2
        $two = @($out.Issues | Where-Object { $_ -like '*two.md;*' })
        $two.Count | Should -Be 1
        $two[0] | Should -Match "^##vso\[task\.logissue type=error;sourcepath=$(Get-SourcePattern $r 'docs/two.md');linenumber=3;code=globs-match\]globs-match: applies_to glob 'nowhere/\*\*' matches no file"
        @($out.Issues | Where-Object { $_ -match 'Why:|Fix:|why:|fix:' }).Count | Should -Be 0
        $out.Lines[0] | Should -Match '^Agent docs check: .* \(entry point: AGENTS\.md, mode: logOnly\)$'
        $out.Lines[-1] | Should -Be '2 error(s), 0 warning(s) - mode logOnly: the step does not fail'
    }
    It 'explains each fired rule once, after the issues and before the totals' {
        $r = New-Fixture -NoFix
        Write-File (Join-Path $r 'docs/two.md') "---`ndescription: Two.`napplies_to: nowhere/**`n---`n"
        Write-File (Join-Path $r 'docs/three.md') "---`ndescription: Three.`napplies_to: gone/**`n---`n"
        $out = Get-CiOutput $r
        $start = [array]::IndexOf($out.Lines, 'Why and how to fix, per rule:')
        $start | Should -BeGreaterThan ([array]::IndexOf($out.Lines, $out.Issues[-1]))
        # The rule lines follow the heading, indented; the sibling note and the totals come after.
        $block = @($out.Lines[($start + 1)..($out.Lines.Count - 1)] | Where-Object { $_ -like '  *' })
        $codes = @($out.Issues | ForEach-Object { if ($_ -match ';code=([a-z-]+)\]') { $Matches[1] } } | Select-Object -Unique)
        $codes.Count | Should -BeGreaterThan 1
        @($block | ForEach-Object { ($_.Trim() -split ' ')[0] }) | Should -Be $codes
        $out.Lines[$start + $block.Count + 1] | Should -Not -BeLike '  *'
        $block | ForEach-Object { $_ | Should -Match '^  [a-z-]+ - why: \S.* fix: \S' }
        $block | ForEach-Object { $_ | Should -Not -BeLike '##*' }
    }
    It 'writes no rule block for a clean repository' {
        $out = Get-CiOutput (New-Fixture)
        $out.Lines | Should -Not -Contain 'Why and how to fix, per rule:'
        $out.Lines[-1] | Should -Be '0 error(s), 0 warning(s)'
    }
    It 'leaves out the line number when the finding has none, and the file when it has none' {
        $r = New-Fixture -Empty
        $issue = @((Get-CiOutput $r).Issues | Where-Object { $_ -like '*code=required-sections*' })
        $issue[0] | Should -Match '^##vso\[task\.logissue type=error;code=required-sections\]'
        $r = New-Fixture -NoFix
        (Get-CiOutput $r).Issues[0] | Should -Match "^##vso\[task\.logissue type=error;sourcepath=$(Get-SourcePattern $r 'AGENTS.md');code=routing-current\]"
    }
    It 'reports a warning as type=warning' {
        $r = New-WarningFixture
        $out = Get-CiOutput $r
        $out.Issues.Count | Should -Be 1
        $out.Issues[0] | Should -Match "^##vso\[task\.logissue type=warning;sourcepath=$(Get-SourcePattern $r 'AGENTS.md');code=entry-point-lines\]"
        $out.Lines[-1] | Should -Be '0 error(s), 1 warning(s)'
    }
    It 'escapes the logging command syntax in file names and messages' {
        $r = New-Fixture
        Write-File (Join-Path $r 'docs/a;b].md') "---`nbackground: true`n---`n"
        $issue = @((Get-CiOutput $r).Issues | Where-Object { $_ -like '*code=frontmatter-present*' })
        $issue.Count | Should -Be 1
        $issue[0] | Should -Match "^##vso\[task\.logissue type=error;sourcepath=$(Get-SourcePattern $r 'docs/a;b].md');code=frontmatter-present\]"
        $issue[0] | Should -Match 'sourcepath=[^;\]]*[\\/]docs[\\/]a%3Bb%5D\.md;'
        InModuleScope Test-OctoAgentDocs { ConvertTo-AdoLogValue "50% a;b]`r`nc" } | Should -Be '50%AZP25 a;b]%0D%0Ac'
    }
    It 'writes no colour codes, so every logging command starts its line' {
        $out = Get-CiOutput (New-Fixture -NoFix)
        ($out.Lines -join "`n") | Should -Not -Match "$([char]27)"
    }
    It 'refuses -Json together with -Ci' {
        { Test-OctoAgentDocs -Path (New-Fixture) -Ci -Json 6>$null } | Should -Throw '*-Ci and -Json*'
    }
    It 'leaves the output without -Ci as it was' {
        $r = New-Fixture -NoFix
        $plain = Get-Output { Test-OctoAgentDocs -Path $r }
        @($plain | Where-Object { $_ -like '##vso*' -or $_ -match $script:SiblingNote }).Count | Should -Be 0
        $plain[-2] | Should -Match 'add -Explain for why and how to fix'
    }
    It 'still reports a missing link into a sibling without -Ci, also when no sibling is checked out' {
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' '[link](../octo-other/AGENTS.md)'
        (Get-RuleFinding (Get-Result $r) 'reference-resolves').message | Should -Be 'Link target not found: ../octo-other/AGENTS.md'
    }
    It 'names a missing entry point as none in the header' {
        (Get-CiOutput (New-Fixture -Empty)).Lines[0] | Should -Match '\(entry point: none, mode: logOnly\)$'
    }
}

Describe 'Test-OctoAgentDocs -Ci gate' {
    It 'fails with exit code 1 in mode enforce on an error, also with -Explain' -ForEach @(
        @{ extra = @{ Mode = 'enforce' } }
        @{ extra = @{ Mode = 'enforce'; Explain = $true } }
    ) {
        $global:LASTEXITCODE = 0
        $out = Get-CiOutput (New-Fixture -NoFix) $extra
        $out.Error | Should -Not -BeNullOrEmpty
        $global:LASTEXITCODE | Should -Be 1
        "$($out.Error)" | Should -Match '1 error-severity finding\(s\)'
        $out.Lines[-1] | Should -Be '1 error(s), 0 warning(s) - mode enforce: the step fails'
    }
    It 'passes with exit code 0 in mode enforce when there are only warnings' {
        $global:LASTEXITCODE = 7
        $out = Get-CiOutput (New-WarningFixture) @{ Mode = 'enforce' }
        $out.Error | Should -BeNullOrEmpty
        $global:LASTEXITCODE | Should -Be 0
        $out.Issues | Should -Match 'type=warning'
    }
    It 'passes with exit code 0 in mode logOnly with errors, and emits the same issues as enforce' {
        $r = New-Fixture -NoFix
        $global:LASTEXITCODE = 7
        $logOnly = Get-CiOutput $r @{ Mode = 'logOnly' }
        $logOnly.Error | Should -BeNullOrEmpty
        $global:LASTEXITCODE | Should -Be 0
        $enforce = Get-CiOutput $r @{ Mode = 'enforce' }
        $logOnly.Issues | Should -Be $enforce.Issues
    }
    It 'never sets a task result itself' {
        $out = Get-CiOutput (New-Fixture -NoFix) @{ Mode = 'enforce' }
        @($out.Lines | Where-Object { $_ -match '##vso\[task\.(complete|setresult)' }).Count | Should -Be 0
    }
}

Describe 'Test-OctoAgentDocs -RepositoryName' {
    BeforeAll {
        # A pipeline checkout: the repository in a folder named 's', nothing beside it.
        function New-CiCheckout {
            $s = Join-Path (New-TempDir) 's'
            Move-Item -LiteralPath (New-Fixture) -Destination $s
            return $s
        }
    }
    It 'names the repository in findings and messages instead of the folder' {
        $s = New-CiCheckout
        (Get-Result $s @{ RepositoryName = 'octo-common-services' }).data.repository | Should -Be 'octo-common-services'
        (Get-CiOutput $s @{ RepositoryName = 'octo-common-services' }).Lines[0] | Should -Match '^Agent docs check: octo-common-services '
        Set-Override $s '{"schemaVersion":1,"rules":{"entry-point-lines":["error",{"max":1}]}}'
        { Test-OctoAgentDocs -Path $s -Mode enforce -RepositoryName octo-common-services 6>$null } | Should -Throw '*finding(s) in octo-common-services'
        ((Test-OctoAgentDocs -Path $s -Explain -All -Json -RepositoryName octo-common-services 6>$null) | ConvertFrom-Json).data.repository | Should -Be 'octo-common-services'
    }
    It 'keeps the folder name without it' {
        (Get-Result (New-CiCheckout)).data.repository | Should -Be 's'
    }
    It 'treats a mention of its own name as itself, not as a sibling' {
        $root = New-TempDir
        Write-File (Join-Path $root 'octo-done/AGENTS.md') '# D'
        $s = Join-Path $root 's'
        Move-Item -LiteralPath (New-Fixture) -Destination $s
        Add-Line $s 'AGENTS.md' 'See octo-named CLAUDE.md.'
        @((Get-Result $s).data.findings | Where-Object { $_.rule -eq 'reference-resolves' }).Count | Should -Be 1
        @((Get-Result $s @{ RepositoryName = 'octo-named' }).data.findings | Where-Object { $_.rule -like 'reference-*' }).Count | Should -Be 0
    }
    It 'rejects a name with a path in it' {
        { Test-OctoAgentDocs -Path (New-Fixture) -RepositoryName '../x' 6>$null } | Should -Throw '*RepositoryName*'
    }
}

Describe 'Test-OctoAgentDocs -Ci without sibling repositories' {
    It 'says once that the sibling rules were skipped, and reports nothing about siblings' {
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' @('See octo-other CLAUDE.md and `octo-other/docs/x.md`.', '[link](../octo-other/AGENTS.md)')
        $out = Get-CiOutput $r
        @($out.Lines | Where-Object { $_ -match $script:SiblingNote }).Count | Should -Be 1
        $out.Issues.Count | Should -Be 0
        @($out.Lines | Where-Object { $_ -cmatch '^WARNING:' }).Count | Should -Be 0
    }
    It 'still reports a missing link inside the repository, also in a folder whose name starts with two dots' {
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' @('[link](octo-sub/missing.md)', '[dots](..octo-x/missing.md)')
        $issue = @((Get-CiOutput $r).Issues)
        $issue.Count | Should -Be 2
        $issue[0] | Should -Match 'Link target not found: octo-sub/missing\.md'
        $issue[1] | Should -Match 'Link target not found: \.\.octo-x/missing\.md'
    }
    It 'checks the siblings and says nothing about skipping when one is beside the checkout' {
        $root = New-TempDir
        Write-File (Join-Path $root 'octo-done/AGENTS.md') '# D'
        $self = Join-Path $root 'octo-self'
        Move-Item -LiteralPath (New-Fixture) -Destination $self
        Add-Line $self 'AGENTS.md' '[link](../octo-other/AGENTS.md)'
        $out = Get-CiOutput $self
        @($out.Lines | Where-Object { $_ -match $script:SiblingNote }).Count | Should -Be 0
        $out.Issues | Should -Match 'Link target not found: \.\./octo-other/AGENTS\.md'
    }
}

Describe 'the four files the pipeline template downloads' {
    It 'load on their own, without the profile, and gate in a fresh process' {
        $tools = New-TempDir
        foreach ($f in 'Test-OctoAgentDocs.psm1', 'OctoAgentDocs.Common.psm1', 'OctoJsonOutput.psm1', 'agent-docs.rules.json') {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../modules/$f") -Destination $tools
        }
        $r = New-Fixture -NoFix
        $pwsh = [System.Environment]::ProcessPath
        $script = "Import-Module (Join-Path '$tools' 'Test-OctoAgentDocs.psm1'); Test-OctoAgentDocs -Path '$r' -Ci -Mode {0} -RepositoryName octo-standalone"
        $out = & $pwsh -NoProfile -NonInteractive -Command ($script -f 'enforce') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($out -join "`n") | Should -Match "##vso\[task\.logissue type=error;sourcepath=$(Get-SourcePattern $r 'AGENTS.md');code=routing-current\]"
        ($out -join "`n") | Should -Match 'Agent docs check: octo-standalone '
        & $pwsh -NoProfile -NonInteractive -Command ($script -f 'logOnly') *> $null
        $LASTEXITCODE | Should -Be 0
    }
}
