# Pester tests for Test-OctoAgentDocs.
# Run:  Invoke-Pester ./tests/Test-OctoAgentDocs.Tests.ps1
#
# Each case here corresponds to a defect found in code review; the comment names it.

BeforeAll {
    $script:ModuleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
    Import-Module (Join-Path $ModuleDir 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'Test-OctoAgentDocs.psm1') -Force

    # A minimal, clean repository: entry point with markers, one routed doc.
    function New-Fixture {
        param([switch]$Agents)
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'docs') -Force | Out-Null
        $entry = if ($Agents) { 'AGENTS.md' } else { 'CLAUDE.md' }
        @(
            '# Entry'
            ''
            '## Read before you change'
            ''
            '<!-- >>> generated: routing -->'
            '<!-- <<< end generated: routing -->'
            ''
            '## Build & test'
            ''
            '## Before you commit'
            ''
            '## Rules'
            ''
        ) -join "`n" | Set-Content -LiteralPath (Join-Path $root $entry) -NoNewline
        @(
            '---'
            'description: One routed document.'
            'applies_to: src/**'
            '---'
            ''
            '# Doc'
            ''
        ) -join "`n" | Set-Content -LiteralPath (Join-Path $root 'docs/one.md') -NoNewline
        return $root
    }

    function Get-Result {
        param([string]$Root, [hashtable]$Extra = @{})
        $json = Test-OctoAgentDocs -Path $Root -Json @Extra 3>$null
        return ($json | ConvertFrom-Json)
    }
    function Get-Rules {
        param($Result, [string]$Rule)
        @($Result.data.findings | Where-Object { $_.rule -eq $Rule })
    }

    # A copy of the module beside a patched ORG ruleset. Some guards only bite when the
    # org defaults differ from the shipped ones, and the shipped file must not be edited
    # in place by a test.
    function New-OrgFixture {
        param([string]$Mode, [string[]]$NonRelaxable)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-org-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Copy-Item -Path (Join-Path $ModuleDir '*') -Destination $dir -Force
        $rulesPath = Join-Path $dir 'agent-docs.rules.json'
        $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json -AsHashtable
        if ($Mode) { $rules.mode = $Mode }
        if ($PSBoundParameters.ContainsKey('NonRelaxable')) { $rules.nonRelaxable = @($NonRelaxable) }
        $rules | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rulesPath
        return $dir
    }

    # Run in a CHILD process: re-importing the module under test in-process would leave
    # every later test running against the patched org ruleset.
    function Invoke-InOrgFixture {
        param([string]$ModuleDir, [string]$Repo, [string]$ExtraArgs = '')
        $script = Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-run-" + [guid]::NewGuid().ToString('N') + '.ps1')
        @(
            "Import-Module '$(Join-Path $ModuleDir 'OctoJsonOutput.psm1')' -Force"
            "Import-Module '$(Join-Path $ModuleDir 'Test-OctoAgentDocs.psm1')' -Force"
            "Test-OctoAgentDocs -Path '$Repo' -Json $ExtraArgs 3>`$null 6>`$null"
        ) -join "`n" | Set-Content -LiteralPath $script
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script 2>$null
        Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue
        return (($out -join '') | ConvertFrom-Json)
    }
}

Describe 'clean repository' {
    It 'reports no errors once the routing block is generated' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = Get-Result $r
        $res.data.summary.errors | Should -Be 0
        $res.data.routes.Count | Should -Be 1
    }
    It 'is idempotent' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $first = Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw) | Should -BeExactly $first
    }
}

Describe 'issue 1 - shim must not destroy a real CLAUDE.md' {
    It 'refuses to overwrite a CLAUDE.md that has real content' {
        $r = New-Fixture -Agents
        '# Real content' + "`n`nlots of it`n" | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw) | Should -Match 'Real content'
        (Get-Rules (Get-Result $r) 'shim-valid').Count | Should -BeGreaterThan 0
    }
    It 'overwrites when -Force is given' {
        $r = New-Fixture -Agents
        '# Real content' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix -Force 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw) | Should -Match '@AGENTS\.md'
    }
    It 'writes the shim when CLAUDE.md is absent' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw) | Should -Match '@AGENTS\.md'
    }
}

Describe 'issue 2 - an invalid severity must not disable a gate' {
    It 'keeps the built-in severity and still fails under enforce' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`n[broken](docs/nope.md)"
        '{"schemaVersion":1,"rules":{"reference-resolves":["eror",{}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        { Test-OctoAgentDocs -Path $r -Mode enforce 3>$null 6>$null } | Should -Throw
        $res = Get-Result $r
        @($res.data.findings | Where-Object { $_.severity -notin @('off','warn','error') }).Count | Should -Be 0
    }
}

Describe 'issue 3 - override file name' {
    It 'reads .agent-docs.json' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"doc-size":["off"]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Result $r).data.ruleSet.'doc-size'[0] | Should -Be 'off'
    }
}

Describe 'issue 4 - brace expansion in globs' {
    It 'does not split a comma inside braces' {
        $r = New-Fixture
        (Get-Content -LiteralPath (Join-Path $r 'docs/one.md') -Raw).Replace('applies_to: src/**', 'applies_to: src/**/*.{cs,csproj}, tests/**') |
            Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        $globs = (Get-Result $r).data.routes[0].globs
        $globs.Count | Should -Be 2
        $globs[0] | Should -Be 'src/**/*.{cs,csproj}'
    }
}

Describe 'issue 5 - non-ASCII anchors' {
    It 'resolves an anchor to a heading with an umlaut' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "`n## Groesse und Groessen`n"
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("`n## Gr" + [char]0xF6 + "sse und Grenzen`n")
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("`nsee [x](#gr" + [char]0xF6 + "sse-und-grenzen)`n")
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
}

Describe 'issue 6 - malformed override JSON' {
    It 'warns and carries on rather than aborting' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        '{ not json' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        { Get-Result $r } | Should -Not -Throw
        (Get-Result $r).data.summary.errors | Should -Be 0
    }
}

Describe 'issue 7 - invalid mode' {
    It 'rejects an unknown mode and keeps the previous one' {
        $r = New-Fixture
        '{"schemaVersion":1,"mode":"sometimes"}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Result $r).data.mode | Should -Be 'logOnly'
    }
}

Describe 'issue 9 - honest reporting of writes' {
    It 'reports no files written when there is nothing to do' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = Test-OctoAgentDocs -Path $r -Fix -Json 3>$null 6>$null | ConvertFrom-Json
        $res.data.filesWritten.Count | Should -Be 0
    }
}

Describe 'issue 10 - line counting matches wc -l' {
    It 'does not count the trailing newline as a line' {
        $r = New-Fixture
        "a`nb`nc`n" | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        '{"schemaVersion":1,"rules":{"entry-point-lines":["error",{"max":3}],"routing-current":["off"]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'entry-point-lines').Count | Should -Be 0
    }
}

Describe 'issue 11 - sibling repo pattern is configurable' {
    It 'honours a custom pattern' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nsee ``partner-repo/CLAUDE.md`` for details"
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 1
        '{"schemaVersion":1,"rules":{"reference-resolves":["error",{"siblingRepoPattern":"^partner-"}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
}

Describe 'cascade' {
    It 'merges per option rather than replacing the whole rule' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"doc-size":["warn",{"maxCharacters":999999}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $rs = (Get-Result $r).data.ruleSet.'doc-size'[1]
        $rs.maxCharacters | Should -Be 999999
        $rs.charactersPerToken | Should -Be 4.0
    }
    It 'ignores an unknown rule id' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"nope":["error",{}]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        { Get-Result $r } | Should -Not -Throw
    }
}

Describe 'second review pass' {
    It 'counts an empty entry point as zero lines, not two' {
        # $a[0..($a.Count-2)] on a one-element array returns two elements.
        $r = New-Fixture
        '' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        '{"schemaVersion":1,"rules":{"entry-point-lines":["error",{"max":0}],"routing-current":["off"]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'entry-point-lines').Count | Should -Be 0
    }
    It 'does not read a backticked phrase as a file reference' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nsee ``the notes in docs/one.md`` for context"
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
}

Describe 'path resolution' {
    It 'resolves a bare repository name under $Global:ROOTPATH' {
        $r = New-Fixture
        $Global:ROOTPATH = Split-Path -Parent $r
        try {
            $repoName = Split-Path -Leaf $r
            (Get-Result $repoName).data.repository | Should -Be $repoName
        }
        finally { Remove-Variable -Name ROOTPATH -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'names the resolved path when it cannot find the repository' {
        $msg = ''
        try { Test-OctoAgentDocs -Path './definitely-not-here' 3>$null 6>$null }
        catch { $msg = $_.Exception.Message }
        $msg | Should -Match 'resolved to'
    }
}

Describe 'finding messages' {
    It 'raises one doc-size finding per file, not one per dimension' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value (('x' * 200 + "`n") * 60)
        '{"schemaVersion":1,"rules":{"doc-size":["warn",{"maxLines":10,"maxCharacters":100}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'doc-size'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'lines \(limit 10\)'
        $f[0].message | Should -Match 'characters \(limit 100\)'
    }
    It 'tells the reader what to do about it' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value (('y' * 200 + "`n") * 60)
        '{"schemaVersion":1,"rules":{"doc-size":["warn",{"maxLines":10,"maxCharacters":100}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $m = (Get-Rules (Get-Result $r) 'doc-size')[0].message
        $m | Should -Match 'Trim it'
        $m | Should -Match 'about .* tokens \(varies by model\), loaded whole'
    }
}

Describe 'required-sections' {
    It 'flags a missing mandatory section' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"required-sections":["error",{"sections":["Deployment"]}],"routing-current":["off"]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'required-sections'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'Deployment'
    }
    It 'passes once the section is present' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`n## Deployment`n"
        '{"schemaVersion":1,"rules":{"required-sections":["error",{"sections":["Deployment"]}],"routing-current":["off"]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'required-sections').Count | Should -Be 0
    }
    It 'supplies no default text for a missing section' {
        # The rule must never write prose into the entry point.
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"required-sections":["error",{"sections":["Deployment"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        Test-OctoAgentDocs -Path $r -Fix 3>$null 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw) | Should -Not -Match 'Deployment'
    }
}

Describe 'descriptions in the routing table' {
    It 'is off by default' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw) | Should -Not -Match 'What it covers'
    }
    It 'adds a third column carrying the frontmatter description when enabled' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"routing-current":["error",{"includeDescriptions":true}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $t = Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw
        $t | Should -Match 'What it covers'
        $t | Should -Match 'One routed document\.'
    }
}

Describe 'locale independence' {
    It 'formats the token figure the same under a comma-decimal culture' {
        # de-DE renders 5.4 as "5,4"; tool output must not depend on the machine's locale.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value (('z' * 200 + "`n") * 60)
        '{"schemaVersion":1,"rules":{"doc-size":["warn",{"maxLines":10,"maxCharacters":100}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $before = [System.Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::new('de-DE')
            $m = (Get-Rules (Get-Result $r) 'doc-size')[0].message
            $m | Should -Match 'about \d+\.\d k?|about \d+\.\dk'
            $m | Should -Not -Match 'about \d+,\d'
        }
        finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $before }
    }
}

Describe 'third review pass' {
    It 'escapes a pipe in a description so the table keeps its column count' {
        $r = New-Fixture
        (Get-Content -LiteralPath (Join-Path $r 'docs/one.md') -Raw).Replace(
            'description: One routed document.', 'description: values a | b are both fine') |
            Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        '{"schemaVersion":1,"rules":{"routing-current":["error",{"includeDescriptions":true}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $rows = @(Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') | Where-Object { $_.StartsWith('|') })
        # header, separator and one data row must all declare the same number of columns
        ($rows | ForEach-Object { ($_ -split '(?<!\\)\|').Count } | Sort-Object -Unique).Count | Should -Be 1
    }
    It 'does not divide by zero when charactersPerToken is 0' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value (('q' * 200 + "`n") * 60)
        '{"schemaVersion":1,"rules":{"doc-size":["warn",{"maxCharacters":100,"charactersPerToken":0}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        { Get-Result $r } | Should -Not -Throw
        (Get-Rules (Get-Result $r) 'doc-size')[0].message | Should -Not -Match 'tokens'
    }
    It 'does not accept a level-3 heading for a required level-2 section' {
        $r = New-Fixture
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw).Replace('## Rules', '### Rules') |
            Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        '{"schemaVersion":1,"rules":{"required-sections":["error",{"sections":["Rules"]}],"routing-current":["off"]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'required-sections').Count | Should -Be 1
    }
}

Describe 'no-invisible-characters' {
    It 'catches a Unicode Tag character carrying hidden text' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $tag = [char]::ConvertFromUtf32(0xE0041)   # TAG LATIN CAPITAL LETTER A
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("visible text" + $tag)
        $f = Get-Rules (Get-Result $r) 'no-invisible-characters'
        $f.Count | Should -Be 1
        $f[0].severity | Should -Be 'error'
    }
    It 'catches a zero-width character' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("a" + [char]0x200B + "b")
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'catches a bidirectional override' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value ("x" + [char]0x202E + "y")
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'does not fire on ordinary German text' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("Gr" + [char]0xF6 + "sse, Pr" + [char]0xFC + "fung, wei" + [char]0xDF)
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 0
    }
}

Describe 'link-hosts' {
    It 'is off by default' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "see [x](https://evil.example/pwn)"
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 0
    }
    It 'flags a host that is not on the allowlist when enabled' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "see [x](https://evil.example/pwn) and [y](https://docs.claude.com/a)"
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'evil.example'
    }
    It 'also sees a bare URL, a reference definition and an autolink' {
        # Only the []() form was matched before, so three of the five spellings an
        # author can use went unchecked by a rule whose whole job is to check them.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value @(
            'bare https://bare.example/x'
            '[ref]: https://refdef.example/y'
            '<https://autolink.example/z>'
        )
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $hosts = (Get-Rules (Get-Result $r) 'link-hosts').message -join ' '
        $hosts | Should -Match 'bare\.example'
        $hosts | Should -Match 'refdef\.example'
        $hosts | Should -Match 'autolink\.example'
    }
    It 'ignores hosts nobody outside the machine or the LAN can answer for' {
        # http://localhost:5000 in a run command is not the threat, and flagging it
        # every time is how an off-by-default rule stays off.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value @(
            'http://localhost:5000/health'
            'http://192.168.1.10:8080/x'
            'http://host.docker.internal:5000/y'
        )
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 0
    }
    It 'still flags a local host when ignoreLocal is turned off' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'http://localhost:5000/health'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"],"ignoreLocal":false}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 1
    }
    It 'strips userinfo and port so the real host is checked' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see [x](https://docs.claude.com@evil.example:8443/pwn)'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'evil\.example'"
    }
}

Describe 'fourth review pass' {
    It 'resolves an anchor to the second of two identical headings' {
        # GitHub renders repeated headings as #x, #x-1, #x-2. Reporting #x-1 as broken
        # failed a build over a link that works.
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value @(
            '', '## Configuration', 'first', '', '## Configuration', 'second', ''
            'see [the second](#configuration-1)', ''
        )
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'takes only the label from a link inside a heading' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value @(
            '', '## See [the doc](one.md)', '', 'jump to [it](#see-the-doc)', ''
        )
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'does not treat a shell comment in a code fence as a heading' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value @(
            '', '```bash', '# Build the thing', 'dotnet build', '```', ''
            'see [x](#build-the-thing)', ''
        )
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 1
    }
    It 'accepts the bare-string rule form the schema allows' {
        # "doc-size": "off" is legal per the schema; indexing [0] into a string
        # yields 'o', which is not a severity.
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"doc-size":"off"}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Result $r).data.ruleSet.'doc-size'[0] | Should -Be 'off'
    }
}

Describe 'non-relaxable rules' {
    # .agent-docs.json is in the branch under review, so the pull request carrying a
    # payload can carry the opt-out with it. Before the floor, this passed -Mode enforce
    # clean.
    It 'ignores a repository opt-out for a floor rule' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("looks ordinary" + [char]::ConvertFromUtf32(0xE0041))
        '{"schemaVersion":1,"rules":{"no-invisible-characters":"off"}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $res = Get-Result $r
        $res.data.ruleSet.'no-invisible-characters'[0] | Should -Be 'error'
        (Get-Rules $res 'no-invisible-characters').Count | Should -Be 1
    }
    It 'leaves rules outside the floor fully overridable' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"docs-count":"off","doc-size":["error",{}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $rs = (Get-Result $r).data.ruleSet
        $rs.'docs-count'[0] | Should -Be 'off'
        $rs.'doc-size'[0] | Should -Be 'error'
    }
    It 'does not let a repository shrink the floor itself' {
        # Otherwise the opt-out is two lines instead of one.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("looks ordinary" + [char]::ConvertFromUtf32(0xE0041))
        '{"schemaVersion":1,"nonRelaxable":[],"rules":{"no-invisible-characters":"off"}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'does not let a repository lower the mode either' {
        # Same hole one level up: with the org default at enforce, "mode": "logOnly" in the
        # branch would pass the build. Migration goes the other way - a repo opts UP.
        # The org default is logOnly today, so this needs a copy of the module whose org
        # ruleset says enforce; passing -Mode enforce here would prove nothing, because
        # -Mode wins over the repository whether or not the guard exists.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        '{"schemaVersion":1,"mode":"logOnly"}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Result $r).data.mode | Should -Be 'logOnly'      # baseline: org default

        $org = New-OrgFixture -Mode enforce
        (Invoke-InOrgFixture -ModuleDir $org -Repo $r).data.mode | Should -Be 'enforce'
    }
    It 'keeps -Mode logOnly working once the org default is enforce' {
        # The escape hatch a rollout needs, moved off the branch and into the pipeline
        # definition: -Mode comes from whoever runs the command, so it may relax freely.
        # Without this, a repo added after the flip could never get a passing build.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`n[broken](docs/nope.md)"
        $org = New-OrgFixture -Mode enforce
        $res = Invoke-InOrgFixture -ModuleDir $org -Repo $r -ExtraArgs '-Mode logOnly'
        $res.data.mode | Should -Be 'logOnly'
        $res.data.summary.errors | Should -BeGreaterThan 0   # still reported, just not fatal
    }
    It 'lets a repository raise the mode' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        '{"schemaVersion":1,"mode":"enforce"}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Result $r).data.mode | Should -Be 'enforce'
    }
    It 'treats an unreadable severity on a floor rule as an attempt to relax' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("looks ordinary" + [char]::ConvertFromUtf32(0xE0041))
        '{"schemaVersion":1,"rules":{"no-invisible-characters":"eror"}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'still honours -ConfigPath, which does not come from the branch' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("looks ordinary" + [char]::ConvertFromUtf32(0xE0041))
        $cfg = Join-Path ([System.IO.Path]::GetTempPath()) ("cfg-" + [guid]::NewGuid().ToString('N') + '.json')
        '{"schemaVersion":1,"rules":{"no-invisible-characters":"off"}}' | Set-Content -LiteralPath $cfg
        $res = Test-OctoAgentDocs -Path $r -ConfigPath $cfg -Json 3>$null | ConvertFrom-Json
        @($res.data.findings | Where-Object { $_.rule -eq 'no-invisible-characters' }).Count | Should -Be 0
    }
}

Describe 'integrity scan surface' {
    It 'finds a payload in a nested AGENTS.md that no routing table mentions' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $r 'src/Foo') -Force | Out-Null
        ("nested guidance" + [char]0x202E + "x") | Set-Content -LiteralPath (Join-Path $r 'src/Foo/AGENTS.md') -NoNewline
        $f = Get-Rules (Get-Result $r) 'no-invisible-characters'
        $f.Count | Should -Be 1
        $f[0].file | Should -Match 'src/Foo/AGENTS\.md'
    }
    It 'looks inside dotfolders such as .claude' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $r '.claude/rules') -Force | Out-Null
        ("a" + [char]0x200B + "b") | Set-Content -LiteralPath (Join-Path $r '.claude/rules/x.md') -NoNewline
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'finds a payload in a docs subfolder' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $r 'docs/adr') -Force | Out-Null
        ("decision" + [char]0x200B) | Set-Content -LiteralPath (Join-Path $r 'docs/adr/0001.md') -NoNewline
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'does not demand frontmatter or a route from a docs subfolder' {
        # Integrity recurses; structural must not, or every archived ADR owes a route.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $r 'docs/adr') -Force | Out-Null
        '# Decision' | Set-Content -LiteralPath (Join-Path $r 'docs/adr/0001.md') -NoNewline
        $res = Get-Result $r
        (Get-Rules $res 'frontmatter-present').Count | Should -Be 0
        (Get-Rules $res 'doc-reachable').Count | Should -Be 0
        $res.data.routes.Count | Should -Be 1
    }
    It 'does not let a repository add its own docs to the ignore list' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("looks ordinary" + [char]0x200B)
        '{"schemaVersion":1,"scan":{"ignore":["docs"]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
    It 'does not follow a symlinked directory back up the tree' {
        # Without the guard the walk does not hang - it spins until scan.maxFiles and
        # warns - so "does not throw" proves nothing. The file count does.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $link = New-Item -ItemType SymbolicLink -Path (Join-Path $r 'docs/loop') -Target $r -ErrorAction SilentlyContinue
        if (-not $link) { Set-ItResult -Skipped -Because 'this platform will not create symlinks unprivileged'; return }
        (Get-Result $r).data.filesScanned.integrity | Should -Be 2
    }
    It 'skips build and vendor output' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $r 'node_modules/pkg') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $r 'src/bin') -Force | Out-Null
        ("vendor" + [char]0x200B) | Set-Content -LiteralPath (Join-Path $r 'node_modules/pkg/readme.md') -NoNewline
        ("built" + [char]0x200B) | Set-Content -LiteralPath (Join-Path $r 'src/bin/notes.md') -NoNewline
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 0
    }
}

Describe 'zero-width joiner in context' {
    It 'does not flag an emoji sequence in a heading' {
        # U+200D is load-bearing between pictographs; flagging it at error severity is
        # how the whole rule gets switched off.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $woman = [char]::ConvertFromUtf32(0x1F469)
        $laptop = [char]::ConvertFromUtf32(0x1F4BB)
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("## For developers " + $woman + [char]0x200D + $laptop)
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 0
    }
    It 'still flags a joiner sitting in ordinary prose' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("ordinary" + [char]0x200D + "prose")
        (Get-Rules (Get-Result $r) 'no-invisible-characters').Count | Should -Be 1
    }
}

Describe 'references to a shim' {
    # A CLAUDE.md that became the shim still resolves, so a pointer to it passes every
    # other check - but an agent that Reads it gets '@AGENTS.md' and nothing else.
    BeforeAll {
        function New-Sibling {
            param([string]$Parent, [switch]$Migrated)
            $name = 'octo-sib-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $dir = Join-Path $Parent $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if ($Migrated) {
                '# Real content' | Set-Content -LiteralPath (Join-Path $dir 'AGENTS.md')
                "<!-- shim -->`n@AGENTS.md`n" | Set-Content -LiteralPath (Join-Path $dir 'CLAUDE.md') -NoNewline
            }
            else { "# Still the real file`n`nlots of it`n" | Set-Content -LiteralPath (Join-Path $dir 'CLAUDE.md') -NoNewline }
            return $name
        }
    }
    It 'warns when a sibling reference points at a migrated repo''s shim' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $sib = New-Sibling -Parent (Split-Path -Parent $r) -Migrated
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nThe contract lives in ``$sib/CLAUDE.md``."
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].severity | Should -Be 'warn'
        $f[0].message | Should -Match "$sib/AGENTS\.md"
    }
    It 'stays quiet while the sibling has not migrated yet' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $sib = New-Sibling -Parent (Split-Path -Parent $r)
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nThe contract lives in ``$sib/CLAUDE.md``."
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'does not advise AGENTS.md for a thin CLAUDE.md that has no AGENTS.md beside it' {
        # "@README.md" alone looks shim-like, but pointing the reader at a non-existent
        # AGENTS.md would be wrong advice.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $name = 'octo-sib-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $dir = Join-Path (Split-Path -Parent $r) $name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        '@README.md' | Set-Content -LiteralPath (Join-Path $dir 'CLAUDE.md')
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nSee ``$name/CLAUDE.md``."
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'skips a sibling that is not checked out, as before' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nSee ``octo-not-checked-out/CLAUDE.md``."
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'warns on a markdown link to a shim inside the repo' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null          # writes the shim
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "`nsee [the guide](../CLAUDE.md)"
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'AGENTS\.md'
    }
    It 'warns on a bare `CLAUDE.md` in a doc once the repo has migrated' {
        # Docs extracted from an old CLAUDE.md say "see `CLAUDE.md`"; after migration that
        # is the shim. Found three of these in the first real migration.
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null          # writes the shim
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'Keep in sync (see "Rules" in `CLAUDE.md`).'
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'AGENTS\.md'"
    }
    It 'stays quiet on a bare `CLAUDE.md` while CLAUDE.md is still the real file' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'See `CLAUDE.md`.'
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'does not fail an enforce run - a degraded pointer is not a broken one' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $sib = New-Sibling -Parent (Split-Path -Parent $r) -Migrated
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nThe contract lives in ``$sib/CLAUDE.md``."
        { Test-OctoAgentDocs -Path $r -Mode enforce 3>$null 6>$null } | Should -Not -Throw
    }
}

Describe 'the shipped ruleset' {
    It 'validates against its own schema' {
        $dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
        $json = Get-Content -LiteralPath (Join-Path $dir 'agent-docs.rules.json') -Raw
        Test-Json -Json $json -SchemaFile (Join-Path $dir 'agent-docs.rules.schema.json') | Should -Be $true
    }
    It 'declares every rule the module implements, and no others' {
        $dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
        $schema = Get-Content -LiteralPath (Join-Path $dir 'agent-docs.rules.schema.json') -Raw | ConvertFrom-Json
        $rules = Get-Content -LiteralPath (Join-Path $dir 'agent-docs.rules.json') -Raw | ConvertFrom-Json
        $declared = @($schema.properties.rules.propertyNames.enum | Sort-Object)
        $configured = @($rules.rules.PSObject.Properties.Name | Sort-Object)
        ($declared -join ',') | Should -Be ($configured -join ',')
    }
}

Describe 'fifth review pass' {
    It 'keeps an underscore inside a heading word in the anchor' {
        # GitHub renders '## applies_to' as #applies_to; stripping every underscore
        # produced #appliesto and reported a working link as broken.
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "`n## applies_to`n`nsee [x](#applies_to)`n"
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'still strips emphasis underscores from a heading' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "`n## _Italic_ heading`n`nsee [x](#italic-heading)`n"
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'accepts a current routing table written with CRLF line endings' {
        # AppendLine emits CRLF on Windows while the template is LF, so a Windows
        # checkout reported its own freshly generated table as stale.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $entryPath = Join-Path $r 'CLAUDE.md'
        $crlf = ([System.IO.File]::ReadAllText($entryPath) -replace "`r?`n", "`r`n")
        [System.IO.File]::WriteAllText($entryPath, $crlf, [System.Text.UTF8Encoding]::new($false))
        (Get-Rules (Get-Result $r) 'routing-current').Count | Should -Be 0
    }
    It 'reports a truncated integrity scan as a finding, not just a warning' {
        # Otherwise decoy Markdown files ahead of a payload push it past the cap and
        # enforce mode passes with the payload unread.
        $org = New-OrgFixture
        $rulesPath = Join-Path $org 'agent-docs.rules.json'
        $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json -AsHashtable
        $rules.scan.maxFiles = 3
        $rules | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rulesPath
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        foreach ($n in 'a', 'b', 'c', 'd', 'e') { "# $n" | Set-Content -LiteralPath (Join-Path $r "docs/$n.md") -NoNewline }
        $res = Invoke-InOrgFixture -ModuleDir $org -Repo $r
        $res.data.filesScanned.truncated | Should -BeTrue
        $res.data.filesScanned.integrity | Should -Be 3
        $f = Get-Rules $res 'no-invisible-characters'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'maxFiles'
        $res.data.summary.success | Should -BeFalse
    }
    It 'does not call a scan of exactly maxFiles files truncated' {
        $org = New-OrgFixture
        $rulesPath = Join-Path $org 'agent-docs.rules.json'
        $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json -AsHashtable
        $rules.scan.maxFiles = 2
        $rules | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rulesPath
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = Invoke-InOrgFixture -ModuleDir $org -Repo $r
        $res.data.filesScanned.truncated | Should -BeFalse
        $res.data.filesScanned.integrity | Should -Be 2
        (Get-Rules $res 'no-invisible-characters').Count | Should -Be 0
    }
    It 'flags a public domain that merely starts with a private-range prefix' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see http://10.attacker.example/x and http://192.168.evil.example/y'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $hosts = (Get-Rules (Get-Result $r) 'link-hosts').message -join ' '
        $hosts | Should -Match '10\.attacker\.example'
        $hosts | Should -Match '192\.168\.evil\.example'
    }
    It 'reads the host a browser would use when a backslash precedes the userinfo' {
        # Browsers treat '\' as '/' in http(s), so the userinfo trick with a backslash
        # in front actually sends the reader to evil.example.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see https://evil.example\@docs.claude.com/pwn'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'evil\.example'"
    }
}
