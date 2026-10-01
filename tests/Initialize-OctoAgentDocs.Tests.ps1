# Pester tests for Initialize-OctoAgentDocs (AB#5457).
# Run:  Invoke-Pester ./tests/Initialize-OctoAgentDocs.Tests.ps1

BeforeAll {
    $script:ModuleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
    Import-Module (Join-Path $ModuleDir 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'Test-OctoAgentDocs.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'Initialize-OctoAgentDocs.psm1') -Force

    function New-Repo {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("ainit-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
    function Get-Init {
        param([string]$Root, [hashtable]$Extra = @{})
        return ((Initialize-OctoAgentDocs -Path $Root -Json @Extra 3>$null 6>$null) | ConvertFrom-Json)
    }
    function Get-Check { param([string]$Root) (Test-OctoAgentDocs -Path $Root -Json 3>$null) | ConvertFrom-Json }
    $script:Rules = Get-Content -LiteralPath (Join-Path $ModuleDir 'agent-docs.rules.json') -Raw | ConvertFrom-Json -AsHashtable
}

Describe 'greenfield repository' {
    It 'writes AGENTS.md with the required sections and the routing markers, and the shim' {
        $r = New-Repo
        $res = Get-Init $r
        $res.data.state | Should -Be 'created'
        @($res.data.filesWritten) | Should -Be @('AGENTS.md', 'CLAUDE.md')
        $agents = Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw
        foreach ($sec in $Rules.rules.'required-sections'[1].sections) { $agents | Should -Match "(?m)^## $([regex]::Escape($sec))$" }
        $agents | Should -Match '<!-- >>> generated: routing -->'
        $agents | Should -Match '<!-- <<< end generated: routing -->'
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw).Trim() | Should -Be (($Rules.rules.'shim-valid'[1].content) -join "`n")
    }
    It 'creates nothing else - no docs folder, no override file' {
        $r = New-Repo
        Get-Init $r | Out-Null
        Test-Path (Join-Path $r 'docs') | Should -BeFalse
        Test-Path (Join-Path $r '.agent-docs.json') | Should -BeFalse
        Test-Path (Join-Path $r 'AGENTS-MIGRATION.md') | Should -BeFalse
    }
    It 'leaves the repository clean for the checker on the first run' {
        # The sections are empty, which is allowed: the checker checks shape, not prose.
        $r = New-Repo
        Get-Init $r | Out-Null
        $check = Get-Check $r
        $check.data.summary.errors | Should -Be 0
        $check.data.summary.warnings | Should -Be 0
    }
    It 'is idempotent and says so' {
        $r = New-Repo
        Get-Init $r | Out-Null
        $agents = Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrated'
        $res.data.filesWritten.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw | Should -Be $agents
        $res.data.status.claudeMd | Should -Be 'shim'
        $res.data.status.brief | Should -Be 'absent'
        $res.data.status.check | Should -Be 'clean'
        # A current repository must not be told to -Fix anything.
        ($res.data.nextSteps | ForEach-Object { $_.what }) -join ' ' | Should -Match 'Migration complete'
        ($res.data.nextSteps | ForEach-Object { $_.command }) -join ' ' | Should -Not -Match '-Fix'
    }
    It 'reports migrating while CLAUDE.md still has real content beside AGENTS.md' {
        $r = New-Repo
        Get-Init $r | Out-Null
        '# still the old file' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrating'
        $res.data.status.claudeMd | Should -Be 'real content'
        $res.data.filesWritten.Count | Should -Be 0
        ($res.data.nextSteps | ForEach-Object { $_.what }) -join ' ' | Should -Match 'remaining content out of CLAUDE.md'
        ($res.data.nextSteps | ForEach-Object { $_.what }) -join ' ' | Should -Not -Match 'Migration complete'
    }
    It 'reports migrating while the brief is still present' {
        $r = New-Repo
        Get-Init $r | Out-Null
        '# brief' | Set-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md')
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrating'
        $res.data.status.brief | Should -Be 'present'
        ($res.data.nextSteps | ForEach-Object { $_.what }) -join ' ' | Should -Match 'delete it'
    }
    It 'suggests -Fix for an initialised repository only when a generated region is stale' {
        $r = New-Repo
        Get-Init $r | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $r 'docs') -Force | Out-Null
        "---`ndescription: A doc.`napplies_to: src/**`n---`n# Doc`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrated'
        $steps = @($res.data.nextSteps)
        ($steps | Where-Object { $_.command -like '*-Fix' }).Count | Should -Be 1
        ($steps | Where-Object { $_.command -like '*-Fix' })[0].what | Should -Match 'routing table'
    }
    It 'keeps the command apart from the explanation in the output' {
        $r = New-Repo
        $out = Initialize-OctoAgentDocs -Path $r 6>&1 3>$null | Out-String
        $out | Should -Match '(?m)^\s+next: Add docs/<topic>\.md'
        $out | Should -Match '(?m)^\s+Test-OctoAgentDocs -Path .* -Fix\s*$'
        $out | Should -Not -Match '#'
    }
    It 'writes nothing with -WhatIf' {
        $r = New-Repo
        $res = Get-Init $r -Extra @{ WhatIf = $true }
        $res.data.filesWritten.Count | Should -Be 0
        Test-Path (Join-Path $r 'AGENTS.md') | Should -BeFalse
        Test-Path (Join-Path $r 'CLAUDE.md') | Should -BeFalse
    }
}

Describe 'repository with a hand-written CLAUDE.md' {
    BeforeEach {
        $script:r = New-Repo
        @('# Legacy', '', '## Build', '', 'dotnet build', '', '## Rules', '', 'Never force-push.') -join "`n" |
            Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
    }
    It 'writes only the migration brief and touches nothing else' {
        $before = Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw
        $res = Get-Init $r
        $res.data.state | Should -Be 'migration'
        @($res.data.filesWritten) | Should -Be @('AGENTS-MIGRATION.md')
        Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw | Should -Be $before
        Test-Path (Join-Path $r 'AGENTS.md') | Should -BeFalse
    }
    It 'renders the brief from the ruleset, with every placeholder filled' {
        Get-Init $r | Out-Null
        $brief = Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw
        $brief | Should -Not -Match '\{\{[A-Z]+\}\}'
        $brief | Should -Match "\| Characters per docs/\*\.md \| $($Rules.rules.'doc-size'[1].maxCharacters) \|"
        $brief | Should -Match "\| Routed docs \| $($Rules.rules.'docs-count'[1].max) \|"
        foreach ($sec in $Rules.rules.'required-sections'[1].sections) { $brief | Should -Match "- ``## $([regex]::Escape($sec))``" }
        foreach ($line in $Rules.rules.'shim-valid'[1].content) { $brief | Should -Match ([regex]::Escape($line)) }
        $brief | Should -Match ([regex]::Escape($Rules.ruleDocs.'doc-size'.why))
        $brief | Should -Not -Match '`link-hosts`'   # off rules are not part of the brief
    }
    It 'tells the agent it may run -Fix, and never -Force' {
        Get-Init $r | Out-Null
        $brief = Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw
        $brief | Should -Match '-Fix. is yours to run'
        $brief | Should -Match 'Never pass `-Force`'
    }
    It 'makes the checker warn until the brief is deleted' {
        Get-Init $r | Out-Null
        $check = Get-Check $r
        @($check.data.findings | Where-Object { $_.rule -eq 'migration-pending' }).Count | Should -Be 1
        Remove-Item -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md')
        $check = Get-Check $r
        @($check.data.findings | Where-Object { $_.rule -eq 'migration-pending' }).Count | Should -Be 0
    }
    It 'does not rewrite an existing brief' {
        Get-Init $r | Out-Null
        'edited by hand' | Set-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md')
        $res = Get-Init $r
        $res.data.filesWritten.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw | Should -Match 'edited by hand'
    }
}

Describe 'repository with only a shim-like CLAUDE.md' {
    It 'treats it as greenfield and completes the shape' {
        $r = New-Repo
        '@AGENTS.md' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        $res = Get-Init $r
        $res.data.state | Should -Be 'created'
        Test-Path (Join-Path $r 'AGENTS.md') | Should -BeTrue
    }
}

Describe 'path resolution' {
    It 'names the resolved path when the repository does not exist' {
        { Initialize-OctoAgentDocs -Path 'no-such-repo-xyz' 3>$null } | Should -Throw '*does not exist*'
    }
}
