#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Behaviour of Test-OctoAgentDocs, grouped by feature. Fixtures are built under the temp
# folder by the helpers and removed in AfterAll.

BeforeAll { . (Join-Path $PSScriptRoot 'AgentDocs.TestHelpers.ps1') }
AfterAll { Remove-Fixtures }

Describe 'clean repository' {
    It 'is clean once the routing table is generated, and -Fix is idempotent' {
        $r = New-Fixture
        $res = Get-Result $r
        $res.data.findings.Count | Should -Be 0
        $res.data.summary.success | Should -BeTrue
        @($res.data.routes).Count | Should -Be 1
        (Get-Result $r @{ Fix = $true }).data.filesWritten.Count | Should -Be 0
    }
    It 'writes the routing table from the frontmatter, in ordinal order, with backticked globs' {
        $r = New-Fixture -NoFix
        Write-File (Join-Path $r 'docs/Zeta.md') "---`ndescription: Z.`napplies_to: z/**`n---`n"
        Write-File (Join-Path $r 'docs/alpha.md') "---`ndescription: A.`napplies_to: a/**/*.{cs,csproj}, tests/**`n---`n"
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $text = Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw
        $text | Should -Match ([regex]::Escape("| When you change | Read first |`n|---|---|`n| ``z/**`` | ``docs/Zeta.md`` |`n| ``a/**/*.{cs,csproj}``, ``tests/**`` | ``docs/alpha.md`` |`n| ``src/**`` | ``docs/one.md`` |"))
    }
    It 'returns the JSON envelope with the documented keys' {
        $res = Get-Result (New-Fixture)
        @($res.PSObject.Properties.Name) | Should -Be @('schemaVersion', 'command', 'timestamp', 'data')
        @($res.data.PSObject.Properties.Name) | Should -Be @('repository', 'entryPoint', 'canonical', 'shim', 'mode', 'filesWritten', 'routes', 'findings', 'startHere', 'explanations', 'ruleSet', 'summary')
    }
    It 'resets LASTEXITCODE to 0 on a clean enforce run and on the rule reference' {
        $r = New-Fixture
        $global:LASTEXITCODE = 7
        Test-OctoAgentDocs -Path $r -Mode enforce 6>$null | Out-Null
        $global:LASTEXITCODE | Should -Be 0
        $global:LASTEXITCODE = 7
        Test-OctoAgentDocs -Explain -All 6>$null | Out-Null
        $global:LASTEXITCODE | Should -Be 0
        (Get-Output { Test-OctoAgentDocs -Path $r })[1] | Should -Match '^\s+clean - 1 routed doc$'
    }
}

Describe 'path resolution' {
    It 'resolves a bare repository name under $Global:ROOTPATH' {
        $r = New-Fixture
        $saved = $Global:ROOTPATH
        try {
            $Global:ROOTPATH = Split-Path -Parent $r
            (Get-Result (Split-Path -Leaf $r)).data.repository | Should -Be (Split-Path -Leaf $r)
        }
        finally { $Global:ROOTPATH = $saved }
    }
    It 'rejects <kind>' -ForEach @(
        @{ kind = 'a missing path, naming what it tried'; path = { Join-Path $r 'nowhere' }; message = "does not exist (resolved to '*nowhere')" }
        @{ kind = 'a file instead of the repository folder'; path = { Join-Path $r 'AGENTS.md' }; message = 'is a file, not a repository folder' }
        @{ kind = 'an empty path'; path = { '' }; message = 'Path is empty' }
    ) {
        $r = New-Fixture
        { Test-OctoAgentDocs -Path (& $path) 6>$null } | Should -Throw -ExpectedMessage "*$message*" -Because 'the message must say what was tried'
    }
    It 'refuses a -ConfigPath that does not exist' {
        $r = New-Fixture
        { Test-OctoAgentDocs -Path $r -ConfigPath (Join-Path $r 'no.json') 6>$null } | Should -Throw '*-ConfigPath*does not exist*'
    }
}

Describe 'configuration cascade' {
    It 'reads .agent-docs.json and merges options per key' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["error",{"max":3}]}}'
        $res = Get-Result $r
        $f = Get-Rules $res 'entry-point-lines'
        $f.Count | Should -Be 1
        $f[0].severity | Should -Be 'error'
        $f[0].message | Should -Match 'budget of 3'
        # Other rules keep every built-in option.
        $res.data.ruleSet.'line-length'[1].max | Should -Be 120
    }
    It 'falls back to the built-in value when a repository sets an option to null' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":null}]}}'
        (Get-Rules (Get-Result $r) 'entry-point-lines').Count | Should -Be 0
    }
    It 'accepts the bare-string rule form' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":"off"}}'
        (Get-Result $r).data.ruleSet.'entry-point-lines'[0] | Should -Be 'off'
    }
    It 'warns and carries on for <kind>' -ForEach @(
        @{ kind = 'an unknown rule id'; json = '{"schemaVersion":1,"rules":{"no-such-rule":["warn"]}}'; warning = "Unknown rule 'no-such-rule'" }
        @{ kind = 'an invalid severity'; json = '{"schemaVersion":1,"rules":{"entry-point-lines":["loud",{"max":1}]}}'; warning = "Invalid severity 'loud'" }
        @{ kind = 'an invalid mode'; json = '{"schemaVersion":1,"mode":"strict"}'; warning = "Invalid mode 'strict'" }
        @{ kind = 'a file that is not JSON'; json = 'not json'; warning = 'is not a JSON object' }
        @{ kind = 'valid JSON that is not an object'; json = '[1,2]'; warning = 'is not a JSON object' }
    ) {
        $r = New-Fixture
        Set-Override $r $json
        $text = (Get-Output { Test-OctoAgentDocs -Path $r }) -join "`n"
        $text | Should -Match "WARNING: .*$([regex]::Escape($warning))"
        $text | Should -Match 'Agent docs check:'
    }
    It 'keeps the built-in severity when the repository severity is invalid' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["loud",{"max":1}]}}'
        (Get-Result $r).data.ruleSet.'entry-point-lines'[0] | Should -Be 'warn'
    }
    It 'lets -Mode and -ConfigPath override the repository file' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"mode":"enforce","rules":{"entry-point-lines":["error",{"max":3}]}}'
        $cfg = Join-Path $r 'ci.json'
        Write-File $cfg '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":3}]}}'
        $res = Get-Result $r @{ Mode = 'logOnly'; ConfigPath = $cfg }
        $res.data.mode | Should -Be 'logOnly'
        (Get-Rules $res 'entry-point-lines')[0].severity | Should -Be 'warn'
    }
}

Describe 'non-relaxable floor' {
    It 'ignores a repository opt-out for a floor rule and says so' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"no-invisible-characters":["off"]}}'
        Add-Line $r 'AGENTS.md' "hidden$([char]0x200B)text"
        $out = Get-Output { Test-OctoAgentDocs -Path $r }
        ($out -join "`n") | Should -Match "'no-invisible-characters' is non-relaxable"
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'does not let a repository lower the mode, but lets it raise it' {
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' '[x](docs/missing.md)'
        Set-Override $r '{"schemaVersion":1,"mode":"enforce"}'
        { Test-OctoAgentDocs -Path $r 6>$null } | Should -Throw '*error-severity finding*'
        $cfg = Join-Path $r 'org.json'
        Write-File $cfg '{"schemaVersion":1,"mode":"enforce"}'
        Set-Override $r '{"schemaVersion":1,"mode":"logOnly"}'
        # The repository file is read before -ConfigPath, so its logOnly cannot undo the trusted enforce.
        { Test-OctoAgentDocs -Path $r -ConfigPath $cfg 6>$null 3>$null } | Should -Throw '*error-severity finding*'
        { Test-OctoAgentDocs -Path $r -ConfigPath $cfg -Mode logOnly 6>$null 3>$null } | Should -Not -Throw
    }
    It 'does not let a repository change the scan surface' {
        $r = New-Fixture
        Write-File (Join-Path $r 'notes/hidden.md') "a$([char]0x200B)b"
        Set-Override $r '{"schemaVersion":1,"scan":{"ignore":["notes"]}}'
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
}

Describe 'entry point' {
    It 'names the file by exact case: agents.md is not AGENTS.md' {
        $r = New-Fixture -Legacy
        Write-File (Join-Path $r 'agents.md') $script:Entry
        $res = Get-Result $r
        $res.data.entryPoint | Should -Be 'CLAUDE.md'
        $res.data.canonical | Should -Be 'CLAUDE.md'
    }
    It 'reports a repository without any entry point and points at Initialize' {
        $r = New-Fixture -Empty
        $res = Get-Result $r
        (Get-Rules $res 'required-sections')[0].message | Should -Match 'Neither AGENTS.md nor CLAUDE.md'
        $res.data.startHere | Should -Match 'Initialize-OctoAgentDocs'
    }
    It 'reports missing sections <case>' -ForEach @(
        @{ case = 'as one finding naming all of them'; remove = @('## Build & test', '## Rules'); expect = "Missing sections '## Build & test', '## Rules'" }
        @{ case = 'in the singular for one'; remove = @('## Rules'); expect = "Missing section '## Rules'" }
    ) {
        $r = New-Fixture
        $p = Join-Path $r 'AGENTS.md'
        $text = Get-Content -LiteralPath $p -Raw
        foreach ($h in $remove) { $text = $text.Replace($h, "### $($h.TrimStart('# '))") }   # a level-3 heading does not count
        Write-File $p $text
        $f = Get-Rules (Get-Result $r) 'required-sections'
        $f.Count | Should -Be 1
        $f[0].message | Should -BeLike "$expect*"
    }
    It 'does not count a heading inside a fenced block as a section' {
        $r = New-Fixture
        $p = Join-Path $r 'AGENTS.md'
        Write-File $p ((Get-Content -LiteralPath $p -Raw).Replace("## Rules`n", "``````markdown`n## Rules`n```````n"))
        (Get-Rules (Get-Result $r) 'required-sections')[0].message | Should -Match "'## Rules'"
    }
    It 'applies the line and character budgets' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":5}],"entry-point-characters":["error",{"max":100000,"warnAt":50}]}}'
        $res = Get-Result $r
        (Get-Rules $res 'entry-point-lines')[0].message | Should -Match 'lines over the budget of 5'
        $c = Get-Rules $res 'entry-point-characters'
        $c[0].severity | Should -Be 'warn'
        $c[0].message | Should -Match 'past the 50 target'
    }
    It 'counts lines as wc -l does: an empty file is zero lines, a trailing newline adds none' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":0}],"required-sections":["off"],"routing-current":["off"]}}'
        Write-File (Join-Path $r 'AGENTS.md') ''
        (Get-Rules (Get-Result $r) 'entry-point-lines').Count | Should -Be 0
        Write-File (Join-Path $r 'AGENTS.md') "one`ntwo`n"
        (Get-Rules (Get-Result $r) 'entry-point-lines')[0].message | Should -Match '^2 lines'
    }
    It 'limits line length with the table allowance, exempts code and unbreakable lines, and caps the list' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"line-length":["warn",{"max":40,"tables":60,"maxReported":2}]}}'
        Add-Line $r 'AGENTS.md' @(
            ('word ' * 12), ('| ' + ('cell ' * 14) + '|'), ('x' * 80), '```', ('code ' * 20), '```', ('more words ' * 6), ('and more ' * 8)
        )
        $f = Get-Rules (Get-Result $r) 'line-length'
        $f.Count | Should -Be 3
        $f[0].message | Should -Match '^line is 60 characters, limit 40'
        $f[1].message | Should -Match '^table row is \d+ characters, limit 60'
        $f[2].message | Should -Match '2 further over-length lines not listed'
    }
}

Describe 'docs and frontmatter' {
    It 'reports <case>' -ForEach @(
        @{ case = 'a missing description'; doc = "---`napplies_to: src/**`n---`n"; rule = 'frontmatter-present'; expect = "No 'description'" }
        @{ case = 'a description over the limit'; doc = "---`ndescription: $('d' * 200)`napplies_to: src/**`n---`n"; rule = 'frontmatter-present'; expect = 'description is 200 characters, limit 160' }
        @{ case = 'a doc that is both routed and background'; doc = "---`ndescription: D.`napplies_to: src/**`nbackground: true`n---`n"; rule = 'doc-reachable'; expect = 'not both and not neither' }
        @{ case = 'a doc that is neither'; doc = "---`ndescription: D.`n---`n"; rule = 'doc-reachable'; expect = 'not both and not neither' }
        @{ case = 'a body without a closing fence as having no frontmatter'; doc = "---`ndescription: D.`napplies_to: src/**`n# Body"; rule = 'frontmatter-present'; expect = "No 'description'" }
        @{ case = 'a doc over its character budget'; doc = "---`ndescription: D.`napplies_to: src/**`n---`n$('y' * 30000)"; rule = 'doc-size'; expect = '300\d\d characters \(limit 25000\)' }
    ) {
        $r = New-Fixture
        Write-File (Join-Path $r 'docs/two.md') $doc
        $f = @(Get-Rules (Get-Result $r) $rule | Where-Object { $_.file -eq 'docs/two.md' })
        $f.Count | Should -Be 1
        $f[0].message | Should -Match $expect
    }
    It 'reads <shape> in applies_to' -ForEach @(
        @{ shape = 'a quoted value'; value = "'*.cs, tests/**'"; globs = @('*.cs', 'tests/**') }
        @{ shape = 'a flow sequence'; value = '[src/**, "tests/**"]'; globs = @('src/**', '"tests/**"') }
        @{ shape = 'a brace expansion without splitting it'; value = 'src/**/*.{cs,csproj}, tests/**'; globs = @('src/**/*.{cs,csproj}', 'tests/**') }
    ) {
        $r = New-Fixture -NoFix
        Write-File (Join-Path $r 'docs/one.md') "---`ndescription: D.`napplies_to: $value`n---`n"
        @((Get-Result $r).data.routes[0].globs) | Should -Be $globs
    }
    It 'flags too many routed docs' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"docs-count":["warn",{"max":1}]}}'
        Write-File (Join-Path $r 'docs/two.md') "---`ndescription: D.`napplies_to: src/**`n---`n"
        (Get-Rules (Get-Result $r) 'docs-count')[0].message | Should -Match '2 routed docs \(limit 1\)'
    }
    It 'does not demand frontmatter from a docs subfolder, but still scans it for integrity' {
        $r = New-Fixture
        Write-File (Join-Path $r 'docs/adr/0001.md') "# ADR a$([char]0x200B)b"
        $res = Get-Result $r
        (Get-Rules $res 'frontmatter-present').Count | Should -Be 0
        (Get-Rules $res 'no-invisible-characters')[0].file | Should -Be 'docs/adr/0001.md:1'
    }
    It 'adds a description column and escapes a pipe when includeDescriptions is on' {
        $r = New-Fixture -NoFix
        Set-Override $r '{"schemaVersion":1,"rules":{"routing-current":["error",{"includeDescriptions":true}]}}'
        Write-File (Join-Path $r 'docs/one.md') "---`ndescription: A | B.`napplies_to: src/**`n---`n"
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw | Should -Match ([regex]::Escape('| `src/**` | `docs/one.md` | A \| B. |'))
    }
}

Describe 'routing table and -Fix' {
    It 'reports a stale table, and -Fix -WhatIf names the rewrite without writing' {
        $r = New-Fixture -NoFix
        (Get-Rules (Get-Result $r) 'routing-current')[0].message | Should -Match 'out of date \(run with -Fix\)'
        $before = Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw
        $res = Get-Result $r @{ Fix = $true; WhatIf = $true }
        (Get-Rules $res 'routing-current')[0].message | Should -Match 'would be rewritten'
        $res.data.filesWritten.Count | Should -Be 0
        Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw | Should -Be $before
    }
    It 'reports missing markers instead of guessing where the table goes' {
        $r = New-Fixture -NoFix
        Write-File (Join-Path $r 'AGENTS.md') ($script:Entry -replace '<!--.*-->\n', '')
        (Get-Rules (Get-Result $r) 'routing-current')[0].message | Should -Match '^Add <!-- >>> generated'
    }
    It 'ignores a marker pair quoted in a fenced example' {
        $r = New-Fixture -NoFix
        $p = Join-Path $r 'AGENTS.md'
        Write-File $p ("``````markdown`n<!-- >>> generated: routing -->`n<!-- <<< end generated: routing -->`n```````n`n" + (Get-Content -LiteralPath $p -Raw))
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $text = Get-Content -LiteralPath $p -Raw
        $text | Should -Match "``````markdown`n<!-- >>> generated: routing -->`n<!-- <<< end generated: routing -->`n``````"
        (Get-Result $r).data.findings.Count | Should -Be 0
    }
    It 'keeps CRLF line endings when it rewrites a CRLF entry point, and accepts a CRLF shim' {
        $r = New-Fixture -NoFix -Crlf
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $raw = [System.IO.File]::ReadAllText((Join-Path $r 'AGENTS.md'))
        $raw | Should -Not -Match "(?<!`r)`n"
        $raw | Should -Match "\| ``src/\*\*`` \| ``docs/one.md`` \|`r`n"
        (Get-Result $r).data.findings.Count | Should -Be 0
    }
    It 'does not report a stale row of the generated table as a broken reference' {
        $r = New-Fixture
        Rename-Item -LiteralPath (Join-Path $r 'docs/one.md') -NewName 'two.md'
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
        { Test-OctoAgentDocs -Path $r -Fix -Mode enforce 6>$null } | Should -Not -Throw
        (Get-Result $r).data.findings.Count | Should -Be 0
    }
    It 'reports a table that differs only in case as stale' {
        $r = New-Fixture
        $p = Join-Path $r 'AGENTS.md'
        Write-File $p ((Get-Content -LiteralPath $p -Raw).Replace('`docs/one.md`', '`docs/One.md`'))
        (Get-Rules (Get-Result $r) 'routing-current').Count | Should -Be 1
    }
}

Describe 'CLAUDE.md shim' {
    It 'has the verdict <verdict> in JSON when CLAUDE.md is <case>' -ForEach @(
        @{ case = 'the shim'; verdict = 'ok'; setup = { } }
        @{ case = 'absent'; verdict = 'absent'; setup = { Remove-Item -LiteralPath (Join-Path $r 'CLAUDE.md') } }
        @{ case = 'something else'; verdict = 'differs'; setup = { Write-File (Join-Path $r 'CLAUDE.md') '# real' } }
        @{ case = 'an import that differs in case'; verdict = 'differs'; setup = { Write-File (Join-Path $r 'CLAUDE.md') ($script:Shim -replace '@AGENTS.md', '@agents.md') } }
    ) {
        $r = New-Fixture
        & $setup
        Set-Override $r '{"schemaVersion":1,"rules":{"shim-valid":["off"]}}'   # the verdict does not depend on the rule
        (Get-Result $r).data.shim | Should -Be $verdict
    }
    It 'is n/a while CLAUDE.md is the entry point' { (Get-Result (New-Fixture -Legacy)).data.shim | Should -Be 'n/a' }
    It 'writes the shim when CLAUDE.md is <case>' -ForEach @(
        @{ case = 'absent'; text = $null; message = 'shim is absent \(run with -Fix\)' }
        @{ case = 'only a comment and an import'; text = "<!-- note -->`n@docs/other.md`n"; message = 'must contain exactly the shim' }
    ) {
        $r = New-Fixture
        $p = Join-Path $r 'CLAUDE.md'
        if ($null -eq $text) { Remove-Item -LiteralPath $p } else { Write-File $p $text }
        (Get-Rules (Get-Result $r) 'shim-valid')[0].message | Should -Match $message
        (Get-Result $r @{ Fix = $true }).data.filesWritten | Should -Contain 'CLAUDE.md'
        Get-Content -LiteralPath $p -Raw | Should -Be $script:Shim
    }
    It 'refuses to replace real content without -Force, and gives the same advice with and without -Fix' {
        $r = New-Fixture
        $p = Join-Path $r 'CLAUDE.md'
        Write-File $p "# Real`n"
        $plain = (Get-Rules (Get-Result $r) 'shim-valid')[0].message
        $fix = (Get-Rules (Get-Result $r @{ Fix = $true }) 'shim-valid')[0].message
        $plain | Should -Match 'migrate it by hand, or run -Fix -Force'
        $fix | Should -Be $plain
        Get-Content -LiteralPath $p -Raw | Should -Be "# Real`n"
        Test-OctoAgentDocs -Path $r -Fix -Force 6>$null | Out-Null
        Get-Content -LiteralPath $p -Raw | Should -Be $script:Shim
    }
    It 'never writes over a claude.md whose name differs only in case' {
        $r = New-Fixture
        Remove-Item -LiteralPath (Join-Path $r 'CLAUDE.md')
        Write-File (Join-Path $r 'claude.md') "# Real`n"
        $f = Get-Rules (Get-Result $r @{ Fix = $true }) 'shim-valid'
        $f[0].file | Should -Be 'claude.md'
        $f[0].message | Should -Match 'rename it'
        @(Get-ChildItem -LiteralPath $r -File).Name | Should -Contain 'claude.md'
        Get-Content -LiteralPath (Join-Path $r 'claude.md') -Raw | Should -Be "# Real`n"
    }
    It 'never writes through a symbolic link' {
        $r = New-Fixture
        $outside = New-TempDir
        Write-File (Join-Path $outside 'CLAUDE.md') "<!-- shared -->`n@../x/AGENTS.md`n"
        Remove-Item -LiteralPath (Join-Path $r 'CLAUDE.md')
        $link = New-Item -ItemType SymbolicLink -Path (Join-Path $r 'CLAUDE.md') -Target (Join-Path $outside 'CLAUDE.md') -ErrorAction SilentlyContinue
        if (-not $link) { Set-ItResult -Skipped -Because 'this platform will not create symlinks unprivileged'; return }
        { Test-OctoAgentDocs -Path $r -Fix 6>$null } | Should -Throw '*symbolic link*'
        Get-Content -LiteralPath (Join-Path $outside 'CLAUDE.md') -Raw | Should -Be "<!-- shared -->`n@../x/AGENTS.md`n"
    }
}

Describe 'references' {
    It 'reports <case>' -ForEach @(
        @{ case = 'a link to a missing file'; text = '[x](docs/missing.md)'; expect = 'Link target not found: docs/missing.md' }
        @{ case = 'a link to a missing anchor'; text = '[x](docs/one.md#nowhere)'; expect = 'Anchor not found: docs/one.md#nowhere' }
        @{ case = 'a link whose case differs from the file on disk'; text = '[x](docs/One.md)'; expect = 'differs in case from the file on disk: docs/One.md' }
        @{ case = 'a backticked path to a missing file'; text = 'See `docs/nope.md`.'; expect = 'Referenced file not found: docs/nope.md' }
        @{ case = 'a backticked path whose case differs'; text = 'See `docs/One.md`.'; expect = 'differs in case from the file on disk: docs/One.md' }
    ) {
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' $text
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match ([regex]::Escape($expect))
    }
    It 'accepts <case>' -ForEach @(
        @{ case = 'a URL'; text = '[x](https://example.invalid/a.md) and <https://example.invalid/b.md>' }
        @{ case = 'a protocol-relative URL'; text = '[x](//example.invalid/a.md)' }
        @{ case = 'a root-relative link'; text = '[x](/docs/one.md)' }
        @{ case = 'a link with a title'; text = '[x](docs/one.md "The doc")' }
        @{ case = 'a percent-encoded path'; text = '[x](docs/my%20file.md)'; file = 'docs/my file.md' }
        @{ case = 'an anchor with an umlaut, in any case'; text = "[x](docs/one.md#Gr$([char]0xFC)$([char]0xDF)E)"; heading = "## Gr$([char]0xFC)$([char]0xDF)e" }
        @{ case = 'the second of two identical headings'; text = '[x](docs/one.md#same-1)'; heading = "## Same`n## Same" }
        @{ case = 'a heading that contains a link'; text = '[x](docs/one.md#see-docs)'; heading = '## See [docs](one.md)' }
        @{ case = 'a link quoted in an inline code span'; text = 'Use `[label](path.md)` syntax.' }
        @{ case = 'a link inside a fenced block'; text = "``````markdown`n[x](docs/nope.md)`n``````" }
        @{ case = 'a backticked phrase without a slash'; text = 'Read `README.md` and `the-guide.md`.' }
        @{ case = 'a backticked pattern or placeholder'; text = 'Add `docs/*.md` or `docs/<topic>.md`.' }
        @{ case = 'a backticked path outside the repository'; text = 'Edit `~/.claude/CLAUDE.md` or `../other/x.md`.' }
        @{ case = 'a sibling repository that is not checked out'; text = 'See `octo-nowhere/docs/x.md`.' }
    ) {
        $r = New-Fixture
        if ($file) { Write-File (Join-Path $r $file) '# F' }
        if ($heading) { Add-Line $r 'docs/one.md' $heading }
        Add-Line $r 'AGENTS.md' $text
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'checks the README under its real name and the docs too' {
        $r = New-Fixture
        Write-File (Join-Path $r 'readme.md') '[x](docs/nope.md)'
        Add-Line $r 'docs/one.md' '[y](#nowhere)'
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        ($f | Where-Object { $_.file -eq 'readme.md' }).message | Should -Match 'docs/nope.md'
        ($f | Where-Object { $_.file -eq 'docs/one.md' }).message | Should -Match '#nowhere'
    }
}

Describe 'reference-to-shim' {
    It 'warns on a reference to a CLAUDE.md that has become a shim, without failing enforce' {
        $r = New-Fixture
        Write-File (Join-Path $r 'sub/AGENTS.md') '# Sub'
        Write-File (Join-Path $r 'sub/CLAUDE.md') $script:Shim
        Add-Line $r 'docs/one.md' 'See [sub](../sub/CLAUDE.md) and `CLAUDE.md`.'
        $res = Get-Result $r
        $f = Get-Rules $res 'reference-to-shim'
        $f.Count | Should -Be 2
        $f.severity | Should -Be @('warn', 'warn')
        $f[0].message | Should -Match "reference '../sub/AGENTS.md' instead"
        { Test-OctoAgentDocs -Path $r -Mode enforce 6>$null } | Should -Not -Throw
    }
    It 'stays quiet while CLAUDE.md is still the real entry point' {
        $r = New-Fixture -Legacy
        Add-Line $r 'docs/one.md' 'See `CLAUDE.md`.'
        (Get-Rules (Get-Result $r) 'reference-to-shim').Count | Should -Be 0
    }
    It 'warns on a sibling repository that has migrated' {
        $root = New-TempDir
        $sibling = Join-Path $root 'octo-sibling'
        Write-File (Join-Path $sibling 'AGENTS.md') '# S'
        Write-File (Join-Path $sibling 'CLAUDE.md') $script:Shim
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' 'See `octo-sibling/CLAUDE.md`.'
        $saved = $Global:ROOTPATH
        try { $Global:ROOTPATH = $root; (Get-Rules (Get-Result $r) 'reference-to-shim')[0].message | Should -Match "'octo-sibling/AGENTS.md'" }
        finally { $Global:ROOTPATH = $saved }
    }
}

Describe 'invisible characters' {
    It 'catches <kind>' -ForEach @(
        @{ kind = 'a Unicode Tag character'; text = "a$([char]0xDB40)$([char]0xDC41)b"; expect = 'Unicode Tag character' }
        @{ kind = 'a zero-width space'; text = "a$([char]0x200B)b"; expect = 'invisible character' }
        @{ kind = 'a soft hyphen or word joiner'; text = "a$([char]0x00AD)b$([char]0x2060)c"; expect = '2 invisible character' }
        @{ kind = 'a bidirectional override'; text = "a$([char]0x202E)b"; expect = 'bidirectional override' }
        @{ kind = 'a zero-width joiner in prose'; text = "a$([char]0x200D)b"; expect = 'stray zero-width joiner' }
    ) {
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' $text
        $f = Get-Rules (Get-Result $r) 'no-invisible-characters'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match $expect
        $f[0].file | Should -Match '^AGENTS\.md:\d+$'
    }
    It 'does not fire on <kind>' -ForEach @(
        @{ kind = 'ordinary German text'; text = "Gr$([char]0xFC)$([char]0xDF)e aus M$([char]0xFC)nchen $([char]0x2013) sch$([char]0xF6)n!" }
        @{ kind = 'an emoji joined with a zero-width joiner'; text = "## Team $([char]::ConvertFromUtf32(0x1F469))$([char]0x200D)$([char]::ConvertFromUtf32(0x1F4BB))" }
    ) {
        $r = New-Fixture
        Add-Line $r 'AGENTS.md' $text
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 0
    }
    It 'scans every Markdown file, dotfolders included, except build and vendor output' {
        $r = New-Fixture
        foreach ($f in 'src/AGENTS.md', '.claude/rules.md', 'node_modules/pkg/readme.md', 'src/bin/out.md') { Write-File (Join-Path $r $f) "a$([char]0x200B)b" }
        @((Get-Rules (Get-Result $r) 'no-invisible-characters').file | Sort-Object) | Should -Be @('.claude/rules.md:1', 'src/AGENTS.md:1')
    }
}

Describe 'link-hosts' {
    BeforeEach { $script:on = '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' }
    It 'is off by default' {
        $r = New-Fixture
        Add-Line $r 'docs/one.md' 'see https://evil.example/pwn'
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 0
    }
    It 'flags <case> when enabled' -ForEach @(
        @{ case = 'a host outside the allowlist, once per file'; text = '[a](https://evil.example/a) <https://evil.example/b> https://evil.example/c'; hosts = @('evil.example') }
        @{ case = 'the real host behind userinfo and a port'; text = 'https://user:pw@evil.example:8443/x'; hosts = @('evil.example') }
        @{ case = 'a lookalike that merely ends like an allowed host'; text = 'https://docs.claude.com.evil.example/x'; hosts = @('docs.claude.com.evil.example') }
    ) {
        $r = New-Fixture
        Set-Override $r $script:on
        Add-Line $r 'docs/one.md' $text
        @((Get-Rules (Get-Result $r) 'link-hosts').message | ForEach-Object { ($_ -split "'")[1] }) | Should -Be $hosts
    }
    It 'accepts <case>' -ForEach @(
        @{ case = 'an allowed host and its subdomains, in any case'; text = 'https://Docs.Claude.com/a https://sub.docs.claude.com/b' }
        @{ case = 'local and private hosts'; text = 'http://localhost:5000 http://10.1.2.3/x http://build.internal/y http://devbox/z' }
    ) {
        $r = New-Fixture
        Set-Override $r $script:on
        Add-Line $r 'docs/one.md' $text
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 0
    }
    It 'flags local hosts when ignoreLocal is off' {
        $r = New-Fixture
        Set-Override $r '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"],"ignoreLocal":false}]}}'
        Add-Line $r 'docs/one.md' 'http://localhost:5000'
        (Get-Rules (Get-Result $r) 'link-hosts')[0].message | Should -Match "'localhost'"
    }
}

Describe 'report, tiers and start here' {
    It 'groups findings by tier, errors first, and leads each line with severity and rule name' {
        $r = New-Fixture -NoFix
        Add-Line $r 'AGENTS.md' @("hidden$([char]0x200B)", ('word ' * 30))
        $out = Get-Output { Test-OctoAgentDocs -Path $r }
        $out[1] | Should -Match '^\s+2 error\(s\), 1 warning\(s\) in 1 file\(s\)$'
        $out[2] | Should -Match '^\s+Start here: a file carries characters a reviewer cannot see'
        $tiers = @($out | Where-Object { $_ -match '^\s+\d\. ' })
        $tiers[0] | Should -Match '^\s+1\. Integrity'
        $tiers[1] | Should -Match '^\s+2\. Entry point'
        $tiers[2] | Should -Match '^\s+4\. Budgets'
        ($out | Where-Object { $_ -match 'no-invisible' }) | Should -Match '^\s+\[error\]\s+no-invisible-characters\s+AGENTS\.md:\d+: '
        ($out | Where-Object { $_ -match 'line-length' }) | Should -Match '^\s+\[warn\]\s+line-length\s+AGENTS\.md:\d+: '
        $out[-2] | Should -Match 'add -Explain for why and how to fix'
    }
    It 'says where to start: <case>' -ForEach @(
        @{ case = 'an unmigrated repository is pointed at Initialize'; fixture = { New-Fixture -Legacy -NoFix }; setup = { Write-File (Join-Path $r 'CLAUDE.md') "# Legacy`n" }; expect = 'has not migrated to AGENTS.md.*Initialize-OctoAgentDocs -Path' }
        @{ case = 'a present brief beats Initialize'; fixture = { New-Fixture -Legacy -NoFix }; setup = { Write-File (Join-Path $r 'CLAUDE.md') "# Legacy`n"; Write-File (Join-Path $r 'AGENTS-MIGRATION.md') '# brief' }; expect = '^the migration brief is still present' }
        @{ case = 'only budgets left'; fixture = { New-Fixture }; setup = { Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":1}]}}' }; expect = '^only budgets are left' }
        @{ case = 'nothing on a clean repository'; fixture = { New-Fixture }; setup = { }; expect = $null }
    ) {
        $r = & $fixture
        & $setup
        $res = Get-Result $r
        if ($null -eq $expect) { $res.data.startHere | Should -BeNullOrEmpty } else { $res.data.startHere | Should -Match $expect }
    }
    It 'names the second cause after the first when both apply' {
        $r = New-Fixture -Legacy -NoFix
        Write-File (Join-Path $r 'CLAUDE.md') "# Legacy a$([char]0x200B)b`n"
        (Get-Result $r).data.startHere | Should -Match 'cannot see.*After that: this repository has not migrated'
    }
    It 'tags every finding with its tier and lists the ruleset in JSON' {
        $r = New-Fixture -NoFix
        $res = Get-Result $r
        (Get-Rules $res 'routing-current')[0].tier | Should -Be 2
        $res.data.ruleSet.'routing-current'[0] | Should -Be 'error'
    }
    It 'quotes a repository path with spaces in the command it prints' {
        $root = New-TempDir
        $r = Join-Path $root 'my repo'
        New-Item -ItemType Directory -Path $r | Out-Null
        (Get-Result $r).data.startHere | Should -Match "Initialize-OctoAgentDocs -Path '.*my repo'"
    }
}

Describe 'explain' {
    It 'explains only the rules that fired, with their options, under their tier' {
        $r = New-Fixture -NoFix
        $out = Get-Output { Test-OctoAgentDocs -Path $r -Explain }
        $rows = @($out | Where-Object { $_ -match '^\s+rule ' })
        $rows.Count | Should -Be 1
        $rows[0] | Should -Match '^\s+rule routing-current  \[error\]  includeDescriptions=False$'
        ($out | Where-Object { $_ -match '^\s+why: ' }).Count | Should -Be 1
        ($out | Where-Object { $_ -match '^\s+fix: Run Test-OctoAgentDocs -Fix' }).Count | Should -Be 1
        $json = Get-Result $r @{ Explain = $true }
        @($json.data.explanations.rule) | Should -Be @('routing-current')
    }
    It 'orders JSON explanations by tier, then rule' {
        $r = New-Fixture -NoFix
        Set-Override $r '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":1}]}}'
        Add-Line $r 'AGENTS.md' "a$([char]0x200B)b"
        @((Get-Result $r @{ Explain = $true }).data.explanations.rule) | Should -Be @('no-invisible-characters', 'routing-current', 'entry-point-lines')
    }
    It 'points a clean repository at the full reference' {
        (Get-Output { Test-OctoAgentDocs -Path (New-Fixture) -Explain })[-2] | Should -Match 'nothing to explain - full rule reference: Test-OctoAgentDocs -Explain -All'
    }
    It 'lists every rule with its effective severity under -All, scanning nothing' {
        $r = New-Fixture -NoFix
        Set-Override $r '{"schemaVersion":1,"rules":{"doc-size":["error"]}}'
        $json = Get-Result $r @{ Explain = $true; All = $true }
        @($json.data.rules).Count | Should -Be (Get-OctoAgentDocsRuleIdList).Count
        ($json.data.rules | Where-Object rule -eq 'doc-size').severity | Should -Be 'error'
        ($json.data.rules | Where-Object rule -eq 'no-invisible-characters').nonRelaxable | Should -BeTrue
        $json.data.PSObject.Properties.Name | Should -Not -Contain 'findings'
        $out = Get-Output { Test-OctoAgentDocs -Path $r -Explain -All }
        $out[0] | Should -Match '^Agent docs rules for .* - effective severity, in the order to fix them'
        ($out | Where-Object { $_ -match '\(non-relaxable\)' }).Count | Should -Be 1
    }
    It 'takes rule ids <how>' -ForEach @(
        @{ how = 'positionally after -Explain'; params = @{ Explain = $true }; positional = 'line-length' }
        @{ how = 'as a list through -Rule'; params = @{ Explain = $true; Rule = @('doc-size', 'line-length') }; positional = $null }
    ) {
        $json = if ($positional) { (Test-OctoAgentDocs -Explain $positional -Json 6>$null) | ConvertFrom-Json } else { (Test-OctoAgentDocs -Json @params 6>$null) | ConvertFrom-Json }
        @($json.data.rules.rule) | Should -Contain 'line-length'
    }
    It 'still treats a real path after -Explain as the path' {
        $r = New-Fixture -NoFix
        (Get-Output { Test-OctoAgentDocs -Explain $r })[0] | Should -Match '^Agent docs check:'
    }
    It 'rejects <what>' -ForEach @(
        @{ what = 'an unknown rule id'; command = { Test-OctoAgentDocs -Explain -Rule no-such-rule 6>$null }; message = '*Unknown rule(s): no-such-rule*' }
        @{ what = 'a word that is neither a path nor a rule'; command = { Test-OctoAgentDocs -Explain no-such-thing 6>$null }; message = '*neither a repository path nor a rule id*' }
    ) {
        $command | Should -Throw $message
    }
    It 'warns about <what>' -ForEach @(
        @{ what = '-Rule or -All without -Explain'; command = { Test-OctoAgentDocs -Path $r -All }; warning = 'ignored without -Explain' }
        @{ what = '-Fix in reference mode'; command = { Test-OctoAgentDocs -Path $r -Explain -All -Fix }; warning = '-Fix is ignored with -Explain -All' }
    ) {
        $r = New-Fixture
        (Get-Output $command) -join "`n" | Should -Match "WARNING: .*$([regex]::Escape($warning))"
    }
    It 'never throws, even in enforce mode' {
        $r = New-Fixture -NoFix
        { Test-OctoAgentDocs -Path $r -Mode enforce -Explain 6>$null } | Should -Not -Throw
    }
}

Describe 'enforce mode' {
    It 'throws and sets the exit code on an error-severity finding, but not on warnings' {
        $r = New-Fixture -NoFix
        { Test-OctoAgentDocs -Path $r -Mode enforce 6>$null } | Should -Throw '*1 error-severity finding(s)*'
        $global:LASTEXITCODE | Should -Be 1
        $w = New-Fixture
        Set-Override $w '{"schemaVersion":1,"rules":{"entry-point-lines":["warn",{"max":1}]}}'
        { Test-OctoAgentDocs -Path $w -Mode enforce 6>$null } | Should -Not -Throw
    }
    It 'warns while the migration brief is present' {
        $r = New-Fixture
        Write-File (Join-Path $r 'AGENTS-MIGRATION.md') '# brief'
        $f = Get-Rules (Get-Result $r) 'migration-pending'
        $f[0].severity | Should -Be 'warn'
        $f[0].file | Should -Be 'AGENTS-MIGRATION.md'
    }
}

Describe 'the shipped ruleset' {
    It 'documents every rule the module implements with a tier, a why and a fix, and the schema agrees' {
        $rules = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../modules/agent-docs.rules.json') -Raw | ConvertFrom-Json -AsHashtable
        $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../modules/agent-docs.rules.schema.json') -Raw | ConvertFrom-Json -AsHashtable
        $ids = @(Get-OctoAgentDocsRuleIdList | Sort-Object)
        @($rules.rules.Keys | Sort-Object) | Should -Be $ids
        @($rules.ruleDocs.Keys | Sort-Object) | Should -Be $ids
        @($schema.properties.rules.propertyNames.enum | Sort-Object) | Should -Be $ids
        foreach ($id in $ids) {
            $rules.ruleDocs[$id].tier | Should -BeIn 1, 2, 3, 4
            $rules.ruleDocs[$id].why | Should -Not -BeNullOrEmpty
            $rules.ruleDocs[$id].fix | Should -Not -BeNullOrEmpty
        }
    }
}
