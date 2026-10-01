# Pester tests for Initialize-OctoAgentDocs.
# Run:  Invoke-Pester ./tests/Initialize-OctoAgentDocs.Tests.ps1

BeforeAll {
    $script:ModuleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
    Import-Module (Join-Path $ModuleDir 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'OctoAgentDocs.Common.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'Test-OctoAgentDocs.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'Initialize-OctoAgentDocs.psm1') -Force

    $script:Fixtures = [System.Collections.Generic.List[string]]::new()
    function New-Repo {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("ainit-" + [guid]::NewGuid().ToString('N'))
        $script:Fixtures.Add($root)
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        return $root
    }
    function Get-Init {
        param([string]$Root, [hashtable]$Extra = @{})
        return ((Initialize-OctoAgentDocs -Path $Root -Json @Extra 3>$null 6>$null) | ConvertFrom-Json)
    }
    function Get-Check { param([string]$Root) (Test-OctoAgentDocs -Path $Root -Json 3>$null) | ConvertFrom-Json }
    function Get-Row { param($Result, [string]$Item) @($Result.data.checklist | Where-Object { $_.item -eq $Item })[0] }
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
        (Get-Row $res 'CLAUDE.md').fact | Should -Be 'shim'
        (Get-Row $res 'AGENTS-MIGRATION.md').done | Should -BeTrue
        (Get-Row $res 'check').fact | Should -Be 'clean'
        # A finished repository has nothing open, so there is nothing to suggest.
        @($res.data.nextSteps).Count | Should -Be 0
    }
    It 'always shows the same five rows, in order' {
        foreach ($setup in 'empty', 'legacy', 'migrated') {
            $r = New-Repo
            if ($setup -eq 'legacy') { '# Legacy' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') }
            if ($setup -eq 'migrated') { Get-Init $r | Out-Null }
            $res = Get-Init $r -Extra @{ WhatIf = $true }
            @($res.data.checklist | ForEach-Object { $_.item }) | Should -Be @('AGENTS.md', 'CLAUDE.md', 'docs/', 'AGENTS-MIGRATION.md', 'check') -Because "setup '$setup'"
        }
    }
    It 'marks what -WhatIf would write as not-yet rather than as missing' {
        $r = New-Repo
        $res = Get-Init $r -Extra @{ WhatIf = $true }
        (Get-Row $res 'AGENTS.md').done | Should -BeNullOrEmpty
        (Get-Row $res 'AGENTS.md').fact | Should -Be 'would be written'
        (Get-Row $res 'check').fact | Should -Match 'not run'
    }
    It 'reports migrating while CLAUDE.md still has real content beside AGENTS.md' {
        $r = New-Repo
        Get-Init $r | Out-Null
        '# still the old file' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrating'
        (Get-Row $res 'CLAUDE.md').done | Should -BeFalse
        (Get-Row $res 'CLAUDE.md').fact | Should -Be 'real content'
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
        (Get-Row $res 'AGENTS-MIGRATION.md').done | Should -BeFalse
        (Get-Row $res 'AGENTS-MIGRATION.md').fact | Should -Be 'present'
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
        (Get-Row $res 'AGENTS-MIGRATION.md').done | Should -BeNullOrEmpty   # just written: in progress, not open
        (Get-Row $res 'AGENTS.md').done | Should -BeFalse
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
        $brief.IndexOf('**1. Integrity**') | Should -BeLessThan $brief.IndexOf('**4. Budgets**')
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

Describe 'review pass - never overwrite, never throw, always a step per open row' {
    It 'leaves a thin CLAUDE.md that imports something else alone and hands it to -Fix' {
        $r = New-Repo
        "<!-- keep this note -->`n@docs/other.md`n" | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        $res = Get-Init $r
        $res.data.state | Should -Be 'created'
        @($res.data.filesWritten) | Should -Be @('AGENTS.md')
        Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw | Should -Match 'keep this note'
        ($res.data.nextSteps | Where-Object { $_.what -like 'Replace the existing CLAUDE.md*' }).command | Should -Match '-Fix$'
    }
    It 'reports the checklist for a repository in enforce mode instead of swallowing the gate' {
        $r = New-Repo
        Get-Init $r | Out-Null
        '{"schemaVersion":1,"mode":"enforce","rules":{"required-sections":["error",{"sections":["Deployment"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $global:LASTEXITCODE = 0
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrated'
        (Get-Row $res 'check').done | Should -BeFalse
        (Get-Row $res 'check').fact | Should -Match '1 error'
        ($res.data.nextSteps | ForEach-Object { $_.what }) -join ' ' | Should -Match 'Resolve 1 open finding'
        $global:LASTEXITCODE | Should -Be 0
    }
    It 'names a step for a stale brief even in a freshly created repository' {
        $r = New-Repo
        '# stale' | Set-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md')
        $res = Get-Init $r
        $res.data.state | Should -Be 'created'
        (Get-Row $res 'AGENTS-MIGRATION.md').done | Should -BeFalse
        ($res.data.nextSteps | ForEach-Object { $_.what }) -join ' ' | Should -Match 'delete it'
    }
    It 'renders the brief name and the markers from the shared constants' {
        $r = New-Repo
        '# Legacy' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        Get-Init $r | Out-Null
        $brief = Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw
        $brief | Should -Match ([regex]::Escape((Get-OctoAgentDocsConstant RoutingStart)))
        $brief | Should -Match 'Delete this file.*AGENTS-MIGRATION\.md'
        $brief | Should -Not -Match '\{\{'
    }
}

Describe 'review pass - the checker decides what the shim is' {
    It 'accepts a shim the repository has overridden, as the checker does' {
        $r = New-Repo
        Get-Init $r | Out-Null
        '{"schemaVersion":1,"rules":{"shim-valid":["error",{"content":["@AGENTS.md"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        "@AGENTS.md`n" | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrated'
        (Get-Row $res 'CLAUDE.md').fact | Should -Be 'shim'
        @($res.data.nextSteps).Count | Should -Be 0
    }
    It 'prints one -Fix command, not two, for a thin CLAUDE.md' {
        $r = New-Repo
        "<!-- note -->`n@docs/other.md`n" | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        $res = Get-Init $r
        @($res.data.nextSteps | Where-Object { $_.command -like '*-Fix' }).Count | Should -Be 1
    }
}

Describe 'review pass - the shim verdict does not depend on the rule being on' {
    It 'still reports real content in CLAUDE.md when the repository turned shim-valid off' {
        $r = New-Repo
        Get-Init $r | Out-Null
        "# Real rules`nDo X`n" | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        '{"schemaVersion":1,"rules":{"shim-valid":"off"}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $res = Get-Init $r
        $res.data.state | Should -Be 'migrating'
        (Get-Row $res 'CLAUDE.md').fact | Should -Be 'real content'
        ($res.data.nextSteps | ForEach-Object { $_.what }) -join ' ' | Should -Match 'Move the remaining content'
    }
}

Describe 'review pass - a declined shim stays declined' {
    It 'does not let the nested -Fix write a CLAUDE.md the caller declined' {
        # Simulated by the only observable the cmdlet has: the shim was not written, so the
        # -Fix pass must not run and CLAUDE.md must still be absent afterwards.
        $r = New-Repo
        $res = Initialize-OctoAgentDocs -Path $r -Json -WhatIf 3>$null 6>$null | ConvertFrom-Json
        $res.data.filesWritten.Count | Should -Be 0
        Test-Path (Join-Path $r 'CLAUDE.md') | Should -BeFalse
    }
}

Describe 'review pass - action summary and brief command path' {
    It 'carries the success and exitCode summary like every action command' {
        $r = New-Repo
        $res = Get-Init $r
        $res.data.success | Should -BeTrue
        $res.data.exitCode | Should -Be 0
        '# Legacy' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        (Get-Init $r).data.success | Should -BeFalse
    }
    It 'prints the path the user typed in the brief, not the folder name' {
        $r = New-Repo
        '# Legacy' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        Get-Init $r | Out-Null
        $brief = Get-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md') -Raw
        $brief | Should -Match ("Test-OctoAgentDocs -Path " + [regex]::Escape((Format-OctoAgentDocsArgument -Value $r)) + "``")
    }
}

AfterAll {
    foreach ($p in $script:Fixtures) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
}
