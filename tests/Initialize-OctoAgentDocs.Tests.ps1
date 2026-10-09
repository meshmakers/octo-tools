#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Behaviour of Initialize-OctoAgentDocs: the four states, the checklist and the brief.

BeforeAll {
    . (Join-Path $PSScriptRoot 'AgentDocs.TestHelpers.ps1')
    function Get-Init {
        param([string]$Root, [hashtable]$Extra = @{})
        return ((Initialize-OctoAgentDocs -Path $Root -Json @Extra 3>$null 6>$null) | ConvertFrom-Json)
    }
    function Get-Row { param($Init, [string]$Item) $Init.data.checklist | Where-Object { $_.item -eq $Item } }
}
AfterAll { Remove-Fixtures }

Describe 'created: a repository without agent files' {
    It 'writes AGENTS.md with the sections and markers and the shim, fills the table, and nothing else' {
        $r = New-TempDir
        $init = Get-Init $r
        $init.data.state | Should -Be 'created'
        @($init.data.filesWritten) | Should -Be @('AGENTS.md', 'CLAUDE.md')
        $agents = Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw
        foreach ($s in 'Read before you change', 'Build & test', 'Before you commit', 'Rules') { $agents | Should -Match "## $([regex]::Escape($s))" }
        $agents | Should -Match ([regex]::Escape("<!-- >>> generated: routing -->`n| When you change | Read first |`n|---|---|`n<!-- <<< end generated: routing -->"))
        Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw | Should -Be $script:Shim
        @(Get-ChildItem -LiteralPath $r -Force).Name | Sort-Object | Should -Be @('AGENTS.md', 'CLAUDE.md')
        (Get-Result $r).data.findings.Count | Should -Be 0
        (Get-Row $init 'check').fact | Should -Be 'clean'
        ($init.data.nextSteps.what -join "`n") | Should -Match 'Write the AGENTS.md sections'
    }
    It 'is idempotent: the second run is migrated and writes nothing' {
        $r = New-TempDir
        Get-Init $r | Out-Null
        $again = Get-Init $r
        $again.data.state | Should -Be 'migrated'
        $again.data.filesWritten.Count | Should -Be 0
        $again.data.success | Should -BeTrue
    }
    It 'writes nothing with -WhatIf and marks the rows as not yet' {
        $r = New-TempDir
        $init = Get-Init $r @{ WhatIf = $true }
        $init.data.filesWritten.Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $r -Force).Count | Should -Be 0
        (Get-Row $init 'AGENTS.md').fact | Should -Be 'would be written'
        (Get-Row $init 'AGENTS.md').done | Should -BeNullOrEmpty
        (Get-Row $init 'CLAUDE.md').fact | Should -Be 'would be written'
    }
    It 'leaves a thin CLAUDE.md that is not the shim alone and hands it to -Fix' {
        $r = New-TempDir
        Write-File (Join-Path $r 'CLAUDE.md') "<!-- keep -->`n@docs/other.md`n"
        $init = Get-Init $r
        $init.data.state | Should -Be 'created'
        @($init.data.filesWritten) | Should -Be @('AGENTS.md')
        (Get-Row $init 'CLAUDE.md').fact | Should -Be 'no real content, but not the shim'
        (Get-Row $init 'check').fact | Should -Be '2 error(s), 0 warning(s)'   # the check ran read-only: shim and the empty table
        @($init.data.nextSteps | Where-Object { $_.command -like '*-Fix' }).Count | Should -Be 1
        Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw | Should -Be "<!-- keep -->`n@docs/other.md`n"
    }
    It 'describes an empty CLAUDE.md without claiming it imports something' {
        $r = New-TempDir
        Write-File (Join-Path $r 'CLAUDE.md') ''
        (Get-Row (Get-Init $r) 'CLAUDE.md').fact | Should -Be 'no real content, but not the shim'
    }
}

Describe 'migration: a repository with a hand-written CLAUDE.md' {
    It 'writes only the brief, rendered from the ruleset with every placeholder filled' {
        $r = New-TempDir
        Write-File (Join-Path $r 'CLAUDE.md') "# Real`n`nContent.`n"
        $init = Get-Init $r
        $init.data.state | Should -Be 'migration'
        @($init.data.filesWritten) | Should -Be @('AGENTS-MIGRATION.md')
        Test-Path -LiteralPath (Join-Path $r 'AGENTS.md') | Should -BeFalse
        $brief = Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw
        $brief | Should -Not -Match '\{\{'
        $brief | Should -Match '\| AGENTS.md lines \| 200 \| warn \| `entry-point-lines` \|'
        $brief | Should -Match '- `## Read before you change`'
        $brief | Should -Match '@AGENTS.md'
        $brief | Should -Match '\*\*1\. Integrity\*\*'
        $brief | Should -Match 'Never pass `-Force`'
        $brief | Should -Not -Match 'link-hosts'   # off, so not in the list of what the checker will say
    }
    It 'prints the repository name in the brief under ROOTPATH, and a dot otherwise, so the command works from inside the repository' {
        $root = New-TempDir
        $r = Join-Path $root 'octo-thing'
        Write-File (Join-Path $r 'CLAUDE.md') "# Real`n"
        $saved = $Global:ROOTPATH
        try {
            $Global:ROOTPATH = $root
            Get-Init 'octo-thing' | Out-Null
            Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw | Should -Match 'Test-OctoAgentDocs -Path octo-thing`'
            Remove-Item -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md')
            $Global:ROOTPATH = $null
            Get-Init $r | Out-Null
            Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw | Should -Match 'Test-OctoAgentDocs -Path \.`'
        }
        finally { $Global:ROOTPATH = $saved }
    }
    It 'does not rewrite an existing brief, makes the checker warn, and lists the three steps' {
        $r = New-TempDir
        Write-File (Join-Path $r 'CLAUDE.md') "# Real`n"
        Write-File (Join-Path $r 'AGENTS-MIGRATION.md') 'mine'
        $init = Get-Init $r
        $init.data.filesWritten.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw | Should -Be 'mine'
        (Get-Row $init 'AGENTS-MIGRATION.md').fact | Should -Be 'present'
        @($init.data.nextSteps).Count | Should -Be 3
        @($init.data.nextSteps.command | Where-Object { $_ }) | Should -Be @("Test-OctoAgentDocs -Path $r")
        (Get-Rules (Get-Result $r) 'migration-pending').Count | Should -Be 1
    }
}

Describe 'migrating and migrated: a repository with AGENTS.md' {
    It 'is migrating while <case>' -ForEach @(
        @{ case = 'CLAUDE.md still has real content'; setup = { Write-File (Join-Path $r 'CLAUDE.md') "# Real`n" }; row = 'CLAUDE.md'; fact = 'real content'; step = 'Move the remaining content out of CLAUDE.md' }
        @{ case = 'the brief is still present'; setup = { Write-File (Join-Path $r 'AGENTS-MIGRATION.md') 'x' }; row = 'AGENTS-MIGRATION.md'; fact = 'present'; step = 'Finish the steps in AGENTS-MIGRATION.md' }
    ) {
        $r = New-Fixture
        & $setup
        $init = Get-Init $r
        $init.data.state | Should -Be 'migrating'
        $init.data.success | Should -BeFalse
        (Get-Row $init $row).fact | Should -Be $fact
        ($init.data.nextSteps.what -join "`n") | Should -Match $step
    }
    It 'is migrated with no next steps when the repository is clean' {
        $init = Get-Init (New-Fixture)
        $init.data.state | Should -Be 'migrated'
        @($init.data.checklist.done) | Should -Be @($true, $true, $true, $true, $true)
        (Get-Row $init 'docs/').fact | Should -Be '1 routed'
        @($init.data.nextSteps).Count | Should -Be 0
    }
    It 'suggests -Fix once when a generated region is stale, and -Explain for other findings' {
        $r = New-Fixture -NoFix
        Add-Line $r 'AGENTS.md' '[x](docs/nope.md)'
        $init = Get-Init $r
        $cmds = @($init.data.nextSteps.command)
        @($cmds | Where-Object { $_ -like '*-Fix' }).Count | Should -Be 1
        @($cmds | Where-Object { $_ -like '*-Explain' }).Count | Should -Be 1
        (Get-Row $init 'check').fact | Should -Be '2 error(s), 0 warning(s)'
    }
    It 'reports the checklist for a repository in enforce mode instead of throwing' {
        $r = New-Fixture -NoFix
        Set-Override $r '{"schemaVersion":1,"mode":"enforce"}'
        { Get-Init $r } | Should -Not -Throw
        (Get-Row (Get-Init $r) 'check').done | Should -BeFalse
    }
    It 'renders the checklist with marks and the commands on their own line' {
        $r = New-Fixture -NoFix
        $out = Get-Output { Initialize-OctoAgentDocs -Path $r }
        $out[0] | Should -Match '^Agent docs init: .* - migrated$'   # the shim is in place; only the table is stale
        ($out | Where-Object { $_ -match "^  $([char]0x2713) AGENTS.md\s+present$" }).Count | Should -Be 1
        ($out | Where-Object { $_ -match "^  $([char]0x2717) check\s+1 error" }).Count | Should -Be 1
        ($out | Where-Object { $_ -match '^        Test-OctoAgentDocs -Path .* -Fix$' }).Count | Should -Be 1
    }
    It 'rejects a file as the repository' {
        $r = New-Fixture
        { Initialize-OctoAgentDocs -Path (Join-Path $r 'AGENTS.md') 6>$null } | Should -Throw '*is a file, not a repository folder*'
    }
}
