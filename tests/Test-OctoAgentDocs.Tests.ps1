# Pester tests for Test-OctoAgentDocs.
# Run:  Invoke-Pester ./tests/Test-OctoAgentDocs.Tests.ps1
#
# Each case here corresponds to a defect found in code review; the comment names it.

BeforeAll {
    $script:ModuleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
    Import-Module (Join-Path $ModuleDir 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'OctoAgentDocs.Common.psm1') -Force
    Import-Module (Join-Path $ModuleDir 'Test-OctoAgentDocs.psm1') -Force

    # Every fixture root is remembered and removed in AfterAll, so a run leaves nothing
    # behind in the temp directory.
    $script:Fixtures = [System.Collections.Generic.List[string]]::new()
    function Register-Fixture { param([string]$P) $script:Fixtures.Add($P); return $P }

    # A minimal, clean repository: entry point with markers, one routed doc.
    function New-Fixture {
        param([switch]$Agents)
        $root = Register-Fixture (Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-" + [guid]::NewGuid().ToString('N')))
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
        $dir = Register-Fixture (Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-org-" + [guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # Only what the checker needs beside itself, not every module in the folder.
        foreach ($n in 'OctoJsonOutput.psm1', 'OctoAgentDocs.Common.psm1', 'Test-OctoAgentDocs.psm1', 'agent-docs.rules.json', 'agent-docs.rules.schema.json') {
            Copy-Item -Path (Join-Path $ModuleDir $n) -Destination $dir -Force
        }
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
        $f = Get-Rules (Get-Result $r) 'reference-to-shim'
        $f.Count | Should -Be 1
        $f[0].severity | Should -Be 'warn'
        $f[0].message | Should -Match "$sib/AGENTS\.md"
    }
    It 'stays quiet while the sibling has not migrated yet' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $sib = New-Sibling -Parent (Split-Path -Parent $r)
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nThe contract lives in ``$sib/CLAUDE.md``."
        (Get-Rules (Get-Result $r) 'reference-to-shim').Count | Should -Be 0
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
        (Get-Rules (Get-Result $r) 'reference-to-shim').Count | Should -Be 0
    }
    It 'skips a sibling that is not checked out, as before' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value "`nSee ``octo-not-checked-out/CLAUDE.md``."
        (Get-Rules (Get-Result $r) 'reference-to-shim').Count | Should -Be 0
    }
    It 'warns on a markdown link to a shim inside the repo' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null          # writes the shim
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "`nsee [the guide](../CLAUDE.md)"
        $f = Get-Rules (Get-Result $r) 'reference-to-shim'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'AGENTS\.md'
    }
    It 'warns on a bare `CLAUDE.md` in a doc once the repo has migrated' {
        # Docs extracted from an old CLAUDE.md say "see `CLAUDE.md`"; after migration that
        # is the shim. Found three of these in the first real migration.
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null          # writes the shim
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'Keep in sync (see "Rules" in `CLAUDE.md`).'
        $f = Get-Rules (Get-Result $r) 'reference-to-shim'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'AGENTS\.md'"
    }
    It 'stays quiet on a bare `CLAUDE.md` while CLAUDE.md is still the real file' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'See `CLAUDE.md`.'
        (Get-Rules (Get-Result $r) 'reference-to-shim').Count | Should -Be 0
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

Describe 'sixth review pass' {
    It 'accepts the two-line shim written with CRLF line endings' {
        # core.autocrlf=true reads the shim back as CRLF; the template is LF, and Trim()
        # removes only the trailing pair, so every migrated repo failed shim-valid on
        # Windows and -Fix rewrote CLAUDE.md on every run.
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $shim = Join-Path $r 'CLAUDE.md'
        $crlf = ([System.IO.File]::ReadAllText($shim) -replace "`r?`n", "`r`n")
        [System.IO.File]::WriteAllText($shim, $crlf, [System.Text.UTF8Encoding]::new($false))
        $res = Get-Result $r -Extra @{ Fix = $true }
        (Get-Rules $res 'shim-valid').Count | Should -Be 0
        $res.data.filesWritten.Count | Should -Be 0
    }
    It 'sees the slash spellings a browser accepts after the scheme' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value @(
            'a https:\\back.example/x'
            'b https:/single.example/y'
            'c https:bare.example/z'
        )
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $hosts = (Get-Rules (Get-Result $r) 'link-hosts').message -join ' '
        $hosts | Should -Match "'back\.example'"
        $hosts | Should -Match "'single\.example'"
        $hosts | Should -Match "'bare\.example'"
    }
}

Describe 'seventh review pass' {
    It 'accepts and does not rewrite a shim separated by lone CR characters' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $shim = Join-Path $r 'CLAUDE.md'
        $cr = ([System.IO.File]::ReadAllText($shim) -replace "`r?`n", "`r")
        [System.IO.File]::WriteAllText($shim, $cr, [System.Text.UTF8Encoding]::new($false))
        $res = Get-Result $r -Extra @{ Fix = $true }
        (Get-Rules $res 'shim-valid').Count | Should -Be 0
        $res.data.filesWritten.Count | Should -Be 0
    }
    It 'reads the host past a literal tab inside an href' {
        # The WHATWG parser strips tab and CR from a URL before it looks for the host,
        # so the tab hides the real host from a check that stops at whitespace.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ('<a href="https://docs.claude.com' + "`t" + '@evil.example/x">x</a>')
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'evil\.example'"
    }
    It 'does not glue the next line onto a URL that ends a line' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "see https://docs.claude.com`nfoo bar"
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 0
    }
}

Describe 'eighth review pass' {
    It 'decodes HTML character references before looking for a URL' {
        # '&#104;ttps://' renders as 'https://' - the link exists for the reader but not
        # for a regex over the raw text.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value '<a href="&#104;ttps://evil.example/x">x</a> and <a href="https&#58;//also.example/y">y</a>'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $hosts = (Get-Rules (Get-Result $r) 'link-hosts').message -join ' '
        $hosts | Should -Match "'evil\.example'"
        $hosts | Should -Match "'also\.example'"
    }
}

Describe 'ninth review pass' {
    It 'reads an href split across lines as one URL' {
        # A quoted attribute value runs to the closing quote, and the URL parser drops the
        # LF, so the reader lands on evil.example while a line-bound match saw docs.claude.com.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "<a href=`"https://docs.claude.com`n@evil.example/x`">link</a>"
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'evil\.example'"
    }
    It 'still ends a prose URL at the line break' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "see https://docs.claude.com`n@evil.example is a handle, not a host"
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 0
    }
}

Describe 'tenth review pass' {
    It 'takes an href whole before decoding, so an encoded quote does not end it' {
        # '&#34;' is part of the attribute value for the HTML parser; decoding first turned
        # it into the closing quote and the check stopped at docs.claude.com.
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value "<a href=`"https://docs.claude.com&#34;`n@evil.example/x`">link</a>"
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'evil\.example'"
    }
}

Describe 'explain - rule reference and per-finding reasons' {
    It 'documents every rule with a why and a fix' {
        # The ruleset is the single source for -Explain, the README and the migration
        # brief, so a rule without text would show up in all three as a bare id.
        $rules = Get-Content -LiteralPath (Join-Path $ModuleDir 'agent-docs.rules.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($id in $rules.rules.Keys) {
            $rules.ruleDocs.ContainsKey($id) | Should -BeTrue -Because "rule '$id' needs a ruleDocs entry"
            $rules.ruleDocs[$id].why | Should -Not -BeNullOrEmpty -Because "rule '$id' needs a why"
            $rules.ruleDocs[$id].fix | Should -Not -BeNullOrEmpty -Because "rule '$id' needs a fix"
            $rules.ruleDocs[$id].tier | Should -BeIn 1, 2, 3, 4 -Because "rule '$id' needs a tier"
            $rules.tiers.ContainsKey("$($rules.ruleDocs[$id].tier)") | Should -BeTrue
        }
        foreach ($id in $rules.ruleDocs.Keys) { $rules.rules.ContainsKey($id) | Should -BeTrue -Because "ruleDocs names '$id', which is not a rule" }
    }
    It 'with -All lists every rule with its effective severity and reason, and scans nothing' {
        $r = New-Fixture
        # No -Fix run here: a scan would report the routing table as stale. The reference
        # must not report that, because it must not scan.
        $res = (Test-OctoAgentDocs -Path $r -Explain -All -Json 3>$null) | ConvertFrom-Json
        $expectedCount = (Get-Content -LiteralPath (Join-Path $ModuleDir 'agent-docs.rules.json') -Raw | ConvertFrom-Json -AsHashtable).rules.Count
        $res.data.rules.Count | Should -Be $expectedCount
        ($res.data.rules | Where-Object { $_.rule -eq 'doc-size' }).why | Should -Match 'loaded whole'
        $res.data.PSObject.Properties.Name | Should -Not -Contain 'findings'
    }
    It 'shows the severity this repository is held to, after its overrides' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"docs-count":["error",{"max":3}]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $res = (Test-OctoAgentDocs -Path $r -Explain -Rule docs-count -Json 3>$null) | ConvertFrom-Json
        $res.data.rules.Count | Should -Be 1
        $res.data.rules[0].severity | Should -Be 'error'
        $res.data.rules[0].options.max | Should -Be 3
    }
    It 'marks the non-relaxable rules' {
        $r = New-Fixture
        $res = (Test-OctoAgentDocs -Path $r -Explain -All -Json 3>$null) | ConvertFrom-Json
        ($res.data.rules | Where-Object { $_.rule -eq 'no-invisible-characters' }).nonRelaxable | Should -BeTrue
        ($res.data.rules | Where-Object { $_.rule -eq 'doc-size' }).nonRelaxable | Should -BeFalse
    }
    It 'rejects an unknown rule id instead of printing nothing' {
        $r = New-Fixture
        { Test-OctoAgentDocs -Path $r -Explain -Rule no-such-rule 3>$null } | Should -Throw '*Unknown rule*'
    }
    It 'points a finding at -Explain' {
        $r = New-Fixture
        $out = Test-OctoAgentDocs -Path $r 6>&1 3>$null | Out-String
        $out | Should -Match 'add -Explain'
    }
    It 'by default runs the check and explains only the rules that fired' {
        $r = New-Fixture
        # Fresh fixture: the routing table is stale, nothing else is wrong.
        $res = (Test-OctoAgentDocs -Path $r -Explain -Json 3>$null) | ConvertFrom-Json
        (Get-Rules $res 'routing-current').Count | Should -Be 1
        @($res.data.explanations).Count | Should -Be 1
        $res.data.explanations[0].rule | Should -Be 'routing-current'
        $res.data.explanations[0].fix | Should -Match '-Fix'
    }
    It 'explains nothing on a clean repository and points at the reference' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = (Test-OctoAgentDocs -Path $r -Explain -Json 3>$null) | ConvertFrom-Json
        @($res.data.explanations).Count | Should -Be 0
        $out = Test-OctoAgentDocs -Path $r -Explain 6>&1 3>$null | Out-String
        $out | Should -Match '-Explain -All'
    }
    It 'warns when -All is given without -Explain' {
        $r = New-Fixture
        $warn = Test-OctoAgentDocs -Path $r -All -Json 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        ($warn | Out-String) | Should -Match 'only widens -Explain'
    }
}

Describe 'diff and whatif - previewing a rewrite' {
    It 'with -Fix -WhatIf writes nothing and still reports the stale regions' {
        $r = New-Fixture -Agents
        $before = [System.IO.File]::ReadAllText((Join-Path $r 'AGENTS.md'))
        $res = (Test-OctoAgentDocs -Path $r -Fix -WhatIf -Json 3>$null) | ConvertFrom-Json
        [System.IO.File]::ReadAllText((Join-Path $r 'AGENTS.md')) | Should -Be $before
        Test-Path (Join-Path $r 'CLAUDE.md') | Should -BeFalse
        $res.data.filesWritten.Count | Should -Be 0
        (Get-Rules $res 'routing-current').Count | Should -Be 1
        (Get-Rules $res 'shim-valid').Count | Should -Be 1
    }
    It 'with -Diff shows the table -Fix would write, as added lines' {
        $r = New-Fixture -Agents
        $res = (Test-OctoAgentDocs -Path $r -Diff -Json 3>$null) | ConvertFrom-Json
        $routing = @($res.data.diffs | Where-Object { $_.region -eq 'routing' })
        $routing.Count | Should -Be 1
        ($routing[0].lines -join "`n") | Should -Match '\+ \| `src/\*\*` \| `docs/one\.md` \|'
        ($routing[0].lines | Where-Object { $_ -like '- *' }).Count | Should -Be 0
        $shim = @($res.data.diffs | Where-Object { $_.region -eq 'shim' })
        $shim.Count | Should -Be 1
    }
    It 'produces no diff once the regions are current' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = (Test-OctoAgentDocs -Path $r -Diff -Json 3>$null) | ConvertFrom-Json
        @($res.data.diffs).Count | Should -Be 0
    }
    It 'diffs a changed row rather than replacing the whole table' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'docs/one.md') -Raw) -replace 'applies_to: src/\*\*', 'applies_to: lib/**' |
            Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        $res = (Test-OctoAgentDocs -Path $r -Diff -Json 3>$null) | ConvertFrom-Json
        $lines = @(($res.data.diffs | Where-Object { $_.region -eq 'routing' })[0].lines)
        ($lines | Where-Object { $_ -like '  | When you change*' }).Count | Should -Be 1   # header kept
        ($lines | Where-Object { $_ -like '- *src/`*`**' }).Count | Should -Be 1
        ($lines | Where-Object { $_ -like '+ *lib/`*`**' }).Count | Should -Be 1
    }
}

Describe 'migration-pending - the brief must not outlive the migration' {
    It 'warns while the migration brief is present' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        '# brief' | Set-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md')
        $f = Get-Rules (Get-Result $r) 'migration-pending'
        $f.Count | Should -Be 1
        $f[0].severity | Should -Be 'warn'
        $f[0].file | Should -Be 'AGENTS-MIGRATION.md'
    }
    It 'is quiet once the brief is deleted' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Rules (Get-Result $r) 'migration-pending').Count | Should -Be 0
    }
}

Describe 'explain and diff - edge cases' {
    It 'shows no shim diff for a CLAUDE.md that -Fix would refuse to touch' {
        $r = New-Fixture -Agents
        '# real content' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        $res = (Test-OctoAgentDocs -Path $r -Diff -Json 3>$null) | ConvertFrom-Json
        @($res.data.diffs | Where-Object { $_.region -eq 'shim' }).Count | Should -Be 0
        (Get-Rules $res 'shim-valid').Count | Should -Be 1
    }
    It 'warns when -Rule is given without -Explain' {
        $r = New-Fixture
        $warn = Test-OctoAgentDocs -Path $r -Rule doc-size -Json 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        ($warn | Out-String) | Should -Match 'only filters -Explain'
    }
}

Describe 'tiered report - grouping and where to start' {
    It 'tags every finding with its tier' {
        $r = New-Fixture
        $res = Get-Result $r
        (Get-Rules $res 'routing-current')[0].tier | Should -Be 2
    }
    It 'collapses several missing sections into one finding' {
        $r = New-Fixture
        '{"schemaVersion":1,"rules":{"required-sections":["error",{"sections":["Deployment","Ownership"]}],"routing-current":["off"]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'required-sections'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'## Deployment', '## Ownership'"
    }
    It 'groups the report by tier, integrity first, and names where to start' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("hidden" + [char]0x200B)
        $out = Test-OctoAgentDocs -Path $r 6>&1 3>$null | Out-String
        $out | Should -Match 'Start here: a file carries characters a reviewer cannot see'
        $out.IndexOf('1. Integrity') | Should -BeLessThan $out.IndexOf('2. Entry point')
        $out | Should -Match '(?m)^\s+\d+ error\(s\), \d+ warning\(s\) in \d+ file\(s\)'
    }
    It 'points an unmigrated repository at Initialize' {
        $r = New-Fixture
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw).Replace('## Rules', '## Other') |
            Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        $res = Get-Result $r
        $res.data.startHere | Should -Match 'not migrated to AGENTS.md'
        $res.data.startHere | Should -Match 'Initialize-OctoAgentDocs'
    }
    It 'says when only budgets are left' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ('x' * 26000)
        $res = Get-Result $r
        (Get-Rules $res 'doc-size').Count | Should -Be 1
        $res.data.startHere | Should -Match 'only budgets are left'
    }
    It 'has no start-here line on a clean repository' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Result $r).data.startHere | Should -BeNullOrEmpty
    }
    It 'puts the explanations under their tier when -Explain is on, with their limits' {
        $r = New-Fixture
        $out = Test-OctoAgentDocs -Path $r -Explain 6>&1 3>$null | Out-String
        $out.IndexOf('2. Entry point') | Should -BeLessThan $out.IndexOf('why: The routing table')
        $out | Should -Match 'includeDescriptions=False'   # the rule's options, not only its reason
    }
}

Describe 'tiered report - order inside a tier' {
    It 'keeps the findings of one file in detection order inside a tier' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @(('a' * 130 + ' b'), 'short', ('c' * 130 + ' d'), ('e' * 130 + ' f'))
        $out = Test-OctoAgentDocs -Path $r 6>&1 3>$null | Out-String
        $lines = @($out -split "`n" | Where-Object { $_ -match 'CLAUDE\.md:(\d+): line is' } | ForEach-Object { [int]$Matches[1] })
        $lines.Count | Should -BeGreaterThan 1
        ($lines -join ',') | Should -Be (($lines | Sort-Object) -join ',')
    }
    It 'names the second cause after the first when both apply' {
        $r = New-Fixture
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw).Replace('## Rules', '## Other') |
            Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("hidden" + [char]0x200B)
        $sh = (Get-Result $r).data.startHere
        $sh | Should -Match '^a file carries characters'
        $sh | Should -Match 'After that: this repository has not migrated'
    }
}

Describe 'tiered report - counts, precedence and JSON shape' {
    It 'counts a file once however many lines are flagged in it' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @(('a' * 130 + ' b'), ('c' * 130 + ' d'))
        $out = Test-OctoAgentDocs -Path $r 6>&1 3>$null | Out-String
        $out | Should -Match 'in 1 file\(s\)'
    }
    It 'prefers the brief over Initialize when the brief already exists' {
        $r = New-Fixture
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw).Replace('## Rules', '## Other') |
            Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        '# brief' | Set-Content -LiteralPath (Join-Path $r 'AGENTS-MIGRATION.md')
        $sh = (Get-Result $r).data.startHere
        $sh | Should -Match 'brief is still present'
        $sh | Should -Not -Match 'Initialize-OctoAgentDocs'
    }
    It 'orders JSON explanations by tier like the text report' {
        $r = New-Fixture
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("hidden" + [char]0x200B)
        $res = (Test-OctoAgentDocs -Path $r -Explain -Json 3>$null) | ConvertFrom-Json
        $tiers = @($res.data.explanations | ForEach-Object { $_.tier })
        ($tiers -join ',') | Should -Be (($tiers | Sort-Object) -join ',')
        $res.data.explanations[0].rule | Should -Be 'no-invisible-characters'
    }
    It 'quotes a repository path with spaces in the commands it prints' {
        $r = New-Fixture
        $spaced = Register-Fixture (Join-Path ([System.IO.Path]::GetTempPath()) ("adocs sp " + [guid]::NewGuid().ToString('N')))
        Move-Item -LiteralPath $r -Destination $spaced
        (Get-Content -LiteralPath (Join-Path $spaced 'CLAUDE.md') -Raw).Replace('## Rules', '## Other') |
            Set-Content -LiteralPath (Join-Path $spaced 'CLAUDE.md') -NoNewline
        (Get-Result $spaced).data.startHere | Should -Match "-Path '"
    }
}

Describe 'explain - the rule id is positional' {
    It 'accepts -Explain RULE after -Path' {
        $r = New-Fixture
        $res = (Test-OctoAgentDocs -Path $r -Explain line-length -Json 3>$null) | ConvertFrom-Json
        $res.data.rules.Count | Should -Be 1
        $res.data.rules[0].rule | Should -Be 'line-length'
    }
    It 'accepts -Explain RULE without -Path' {
        $res = (Test-OctoAgentDocs -Explain doc-size,line-length -Json 3>$null) | ConvertFrom-Json
        @($res.data.rules | ForEach-Object { $_.rule }) | Should -Be @('doc-size', 'line-length')
    }
    It 'still treats a real path as the path' {
        $r = New-Fixture
        $res = (Test-OctoAgentDocs $r -Explain -Json 3>$null) | ConvertFrom-Json
        $res.data.PSObject.Properties.Name | Should -Contain 'findings'
    }
    It 'leads each finding with its severity and rule name' {
        $r = New-Fixture
        $out = Test-OctoAgentDocs -Path $r 6>&1 3>$null | Out-String
        $out | Should -Match '(?m)^\s+\[error\]\s+$'          # severity record, then the rule name record
        $out | Should -Match '(?m)^routing-current\s+$'
        $out | Should -Match '-Explain <rule>'
    }
}

Describe 'review pass - case and resolution' {
    It 'does not accept a shim whose import differs only in case' {
        # '@agents.md' resolves to nothing on a case-sensitive checkout.
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw).Replace('@AGENTS.md', '@agents.md') |
            Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        (Get-Rules (Get-Result $r) 'shim-valid').Count | Should -Be 1
    }
    It 'reports a routing table that differs only in case as stale' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Content -LiteralPath (Join-Path $r 'AGENTS.md') -Raw).Replace('docs/one.md', 'docs/One.md') |
            Set-Content -LiteralPath (Join-Path $r 'AGENTS.md') -NoNewline
        (Get-Rules (Get-Result $r) 'routing-current').Count | Should -Be 1
    }
    It 'treats a known rule id as the rule even when a folder of that name exists' {
        $r = New-Fixture
        Push-Location $r
        try {
            New-Item -ItemType Directory -Path (Join-Path $r 'doc-size') -Force | Out-Null
            $res = (Test-OctoAgentDocs -Explain doc-size -Json 3>$null) | ConvertFrom-Json
            $res.data.PSObject.Properties.Name | Should -Contain 'rules'
        }
        finally { Pop-Location }
    }
    It 'names both readings when the word after -Explain is neither a path nor a rule' {
        { Test-OctoAgentDocs -Explain octo-comunication-operator 3>$null } | Should -Throw '*neither a repository path nor a rule id*'
    }
}

Describe 'review pass - gate, start-here and path edge cases' {
    It 'does not throw under -Explain even when the repository is in enforce mode' {
        $r = New-Fixture
        '{"schemaVersion":1,"mode":"enforce"}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        { Test-OctoAgentDocs -Path $r 3>$null 6>$null } | Should -Throw
        { Test-OctoAgentDocs -Path $r -Explain 3>$null 6>$null } | Should -Not -Throw
    }
    It 'tells an empty repository that Initialize writes the entry point, not a brief' {
        $r = Register-Fixture (Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-" + [guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $r -Force | Out-Null
        $sh = (Get-Result $r).data.startHere
        $sh | Should -Match 'no agent instructions yet'
        $sh | Should -Not -Match 'migration brief'
    }
    It 'rejects an empty path instead of checking the whole root' {
        { Test-OctoAgentDocs -Path '' 3>$null } | Should -Throw '*Path is empty*'
    }
    It 'quotes a path with an embedded single quote so the printed command parses' {
        Format-OctoAgentDocsArgument -Value "/tmp/O'Brien repo" | Should -Be "'/tmp/O''Brien repo'"
        Format-OctoAgentDocsArgument -Value './octo-tools/' | Should -Be './octo-tools/'
    }
}

Describe 'review pass - inputs the checker must survive' {
    It 'skips a repository override that is valid JSON but not an object' {
        $r = New-Fixture
        '[1,2]' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        { Test-OctoAgentDocs -Path $r -Json 3>$null } | Should -Not -Throw
        $warn = Test-OctoAgentDocs -Path $r -Json 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        ($warn | Out-String) | Should -Match 'not a JSON object'
    }
    It 'keeps the file''s CRLF line endings when -Fix regenerates the routing table' {
        $r = New-Fixture -Agents
        $p = Join-Path $r 'AGENTS.md'
        [System.IO.File]::WriteAllText($p, ([System.IO.File]::ReadAllText($p) -replace "`r?`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $after = [System.IO.File]::ReadAllText($p)
        ([regex]::Matches($after, "`r`n")).Count | Should -BeGreaterThan 5
        ([regex]::Matches($after, "(?<!`r)`n")).Count | Should -Be 0
        (Get-Rules (Get-Result $r) 'routing-current').Count | Should -Be 0
    }
    It 'reads a lone-CR entry point line by line' {
        $r = New-Fixture
        $p = Join-Path $r 'CLAUDE.md'
        [System.IO.File]::WriteAllText($p, ([System.IO.File]::ReadAllText($p) -replace "`r?`n", "`r"), [System.Text.UTF8Encoding]::new($false))
        '{"schemaVersion":1,"rules":{"routing-current":["off"]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'required-sections').Count | Should -Be 0
    }
    It 'reports a mistyped rule after -Explain with the list of rules' {
        { Test-OctoAgentDocs -Explain doc-sizee 3>$null } | Should -Throw '*Rules: entry-point-lines*'
    }
    It 'matches allowlist subdomains without regard to case' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see https://docs.github.com/x and https://github.com/y'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["GitHub.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'link-hosts').Count | Should -Be 0
    }
    It 'files a repository without any entry point under the structural rule, honouring its severity' {
        $r = Register-Fixture (Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-" + [guid]::NewGuid().ToString('N')))
        New-Item -ItemType Directory -Path $r -Force | Out-Null
        $f = Get-Rules (Get-Result $r) 'required-sections'
        $f.Count | Should -Be 1
        $f[0].tier | Should -Be 2
        '{"schemaVersion":1,"rules":{"required-sections":"off"}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'required-sections').Count | Should -Be 0
    }
    It 'rejects a file path as the repository' {
        $r = New-Fixture
        { Test-OctoAgentDocs -Path (Join-Path $r 'CLAUDE.md') 3>$null } | Should -Throw '*is a file*'
    }
    It 'exposes the shim verdict in JSON even when shim-valid is off' {
        $r = New-Fixture -Agents
        '# real content' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        '{"schemaVersion":1,"rules":{"shim-valid":"off"}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $res = Get-Result $r
        (Get-Rules $res 'shim-valid').Count | Should -Be 0
        $res.data.shim | Should -Be 'differs'
    }
    It 'works with -Json when only the checker module was imported' {
        $r = New-Fixture
        $script = Join-Path ([System.IO.Path]::GetTempPath()) ("adocs-run-" + [guid]::NewGuid().ToString('N') + '.ps1')
        "Import-Module '$(Join-Path $ModuleDir 'Test-OctoAgentDocs.psm1')' -Force`nTest-OctoAgentDocs -Path '$r' -Json 3>`$null" | Set-Content -LiteralPath $script
        $out = & (Get-Process -Id $PID).Path -NoProfile -File $script 2>&1
        Remove-Item -LiteralPath $script -ErrorAction SilentlyContinue
        (($out -join '') | ConvertFrom-Json).command | Should -Be 'Test-OctoAgentDocs'
    }
}

Describe 'review pass - references, links, hosts, files' {
    It 'does not read a glob in backticks as a missing file' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value 'Every `docs/*.md` starts with frontmatter.'
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'resolves a root-relative link from the repository root' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see [the entry](/CLAUDE.md) and [self](/docs/one.md)'
        (Get-Rules (Get-Result $r) 'reference-resolves' | Where-Object { $_.message -like 'Link target not found*' }).Count | Should -Be 0
    }
    It 'refuses a -ConfigPath that does not exist' {
        $r = New-Fixture
        { Test-OctoAgentDocs -Path $r -ConfigPath (Join-Path $r 'nope.json') 3>$null } | Should -Throw '*does not exist*'
    }
    It 'parses an IPv6 literal URL and checks its host' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see http://[2001:db8::1]:8080/x'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"],"ignoreLocal":false}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match '2001:db8::1'
    }
    It 'finds a lowercase readme.md and reports it under its real name' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        'see [x](missing.md)' | Set-Content -LiteralPath (Join-Path $r 'readme.md')
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].file | Should -BeExactly 'readme.md'
    }
    It 'measures a doc the same with CRLF and LF line endings' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $p = Join-Path $r 'docs/one.md'
        $body = (1..600 | ForEach-Object { 'x' * 40 }) -join "`n"          # 24,599 chars with LF
        [System.IO.File]::WriteAllText($p, ([System.IO.File]::ReadAllText($p) + "`n" + $body), [System.Text.UTF8Encoding]::new($false))
        (Get-Rules (Get-Result $r) 'doc-size').Count | Should -Be 0
        [System.IO.File]::WriteAllText($p, ([System.IO.File]::ReadAllText($p) -replace "`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
        (Get-Rules (Get-Result $r) 'doc-size').Count | Should -Be 0
    }
}

Describe 'review pass - references and frontmatter the way authors write them' {
    It 'ignores a link inside a fenced code block' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @('```markdown', '[example](docs/example.md)', '`docs/nowhere.md`', '```')
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'does not read a placeholder like docs/<topic>.md as a file' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value 'Add `docs/<topic>.md` with frontmatter.'
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'checks a link that carries a title' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value '[guide](docs/missing.md "Read first") and [ok](<docs/one.md> ''Fine'')'
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'docs/missing\.md'
    }
    It 'reads a YAML block list in applies_to' {
        $r = New-Fixture
        "---`ndescription: Listed.`napplies_to:`n  - src/**`n  - lib/**`n---`n# Doc`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = Get-Result $r
        (Get-Rules $res 'doc-reachable').Count | Should -Be 0
        @($res.data.routes[0].globs) | Should -Be @('src/**', 'lib/**')
    }
    It 'keeps lone-CR line endings when -Fix regenerates the routing table' {
        $r = New-Fixture -Agents
        $p = Join-Path $r 'AGENTS.md'
        [System.IO.File]::WriteAllText($p, ([System.IO.File]::ReadAllText($p) -replace "`r?`n", "`r"), [System.Text.UTF8Encoding]::new($false))
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        ([System.IO.File]::ReadAllText($p)).Contains("`n") | Should -BeFalse
    }
    It 'names the absolute path it tried when a rooted path is missing' {
        { Test-OctoAgentDocs -Path '/nonexistent/abs/repo' 3>$null } | Should -Throw "*resolved to '/nonexistent/abs/repo'*"
    }
    It 'falls back to the built-in threshold when a repository removes an option' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ('x' * 26000)
        '{"schemaVersion":1,"rules":{"doc-size":["warn",{}]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'doc-size'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'limit 25000'
    }
    It 'lets a repository silence shim advice without losing broken-link errors' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see [shim](../CLAUDE.md) and [gone](missing.md)'
        '{"schemaVersion":1,"rules":{"reference-to-shim":"off"}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $res = Get-Result $r
        (Get-Rules $res 'reference-to-shim').Count | Should -Be 0
        (Get-Rules $res 'reference-resolves').Count | Should -Be 1
    }
}

Describe 'review pass - CRLF fences, quoted YAML, ordinal order, unterminated frontmatter' {
    It 'ignores a link in a fenced block in a CRLF file too' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $p = Join-Path $r 'CLAUDE.md'
        $text = [System.IO.File]::ReadAllText($p) + "`n``````markdown`n[example](docs/example.md)`n```````n"
        [System.IO.File]::WriteAllText($p, ($text -replace "`r?`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'strips YAML quotes from frontmatter values' {
        $r = New-Fixture
        "---`ndescription: `"Quoted.`"`napplies_to: '*.md'`n---`n# Doc`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = Get-Result $r
        @($res.data.routes[0].globs) | Should -Be @('*.md')
        $res.data.routes[0].description | Should -Be 'Quoted.'
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw) | Should -Match '\| `\*\.md` \|'
    }
    It 'orders the routing table ordinally, not by the current culture' {
        $r = New-Fixture
        foreach ($n in 'api-v2', 'api_v2', 'apiv2') {
            "---`ndescription: $n.`napplies_to: $n/**`n---`n# $n`n" | Set-Content -LiteralPath (Join-Path $r "docs/$n.md") -NoNewline
        }
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $files = @((Get-Result $r).data.routes | ForEach-Object { $_.file })
        # Code-point order: '-' (0x2D) before '_' (0x5F) before 'v' - whatever the culture.
        $files | Should -Be @('docs/api-v2.md', 'docs/api_v2.md', 'docs/apiv2.md', 'docs/one.md')
    }
    It 'does not read a body as frontmatter when the closing fence is missing' {
        $r = New-Fixture
        "---`n# Doc`n`nNote: run the build first.`ndescription: not a key`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        (Get-Rules (Get-Result $r) 'frontmatter-present').Count | Should -Be 1
    }
    It 'reads every file once' {
        # Observable through the cache: the entry point is in it after a run.
        $r = New-Fixture
        $res = Get-Result $r
        $res.data.filesScanned.routed | Should -Be 2
    }
}

AfterAll {
    foreach ($p in $script:Fixtures) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'review pass - invisible characters, fences, links, line length' {
    It 'catches the other invisible format characters too' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value ("plain" + [char]0x2064 + [char]0x200E + [char]0x061C + [char]0x034F + [char]0x00AD)
        $f = Get-Rules (Get-Result $r) 'no-invisible-characters'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match '^5 invisible character'
    }
    It 'does not count a heading inside a fenced block as a required section' {
        $r = New-Fixture
        (Get-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Raw).Replace("## Rules`n", "``````markdown`n## Rules`n```````n") |
            Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -NoNewline
        '{"schemaVersion":1,"rules":{"routing-current":["off"]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'required-sections'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match "'## Rules'"
    }
    It 'does not follow a link quoted in an inline code span' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value 'Use `[label](path.md)` syntax.'
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'decodes a percent-encoded link target and matches anchors without regard to case' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        '# My file' | Set-Content -LiteralPath (Join-Path $r 'docs/my file.md')
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value '[f](docs/my%20file.md) and [b](#Build--test)'
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'accepts a shim whose comment spans lines' {
        Test-OctoAgentDocsShimLike "<!-- Claude Code loads this file.`n     AGENTS.md is the source of truth. -->`n@AGENTS.md`n" | Should -BeTrue
    }
    It 'exempts only lines without any whitespace from the line limit' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $prose = ((1..23 | ForEach-Object { 'word' }) -join ' ') + ' ' + ('x' * 25)   # whitespace before the limit only
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @($prose, ('https://example.invalid/' + ('a' * 130)))
        $f = Get-Rules (Get-Result $r) 'line-length'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'line is'
    }
    It 'survives a repository override that empties the shim text' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        '{"schemaVersion":1,"rules":{"shim-valid":["error",{"content":[]}]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        { Test-OctoAgentDocs -Path $r -Json 3>$null } | Should -Not -Throw
    }
    It 'keeps the file diagnosis when -Explain is given a file path' {
        $r = New-Fixture
        { Test-OctoAgentDocs -Explain (Join-Path $r 'CLAUDE.md') 3>$null } | Should -Throw '*is a file*'
    }
}

Describe 'review pass - markers in fences, YAML shapes, IPv6, case and tildes' {
    It 'does not write the routing table into a fenced example of the markers' {
        $r = New-Fixture -Agents
        $p = Join-Path $r 'AGENTS.md'
        $example = "``````markdown`n<!-- >>> generated: routing -->`n<!-- <<< end generated: routing -->`n```````n`n"
        [System.IO.File]::WriteAllText($p, ($example + [System.IO.File]::ReadAllText($p)), [System.Text.UTF8Encoding]::new($false))
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $after = [System.IO.File]::ReadAllText($p)
        $after.IndexOf('| `src/**` |') | Should -BeGreaterThan $after.IndexOf('```markdown' + "`n<!-- >>> generated: routing -->`n<!-- <<< end generated: routing -->`n" + '```')
        (Get-Rules (Get-Result $r) 'routing-current').Count | Should -Be 0
    }
    It 'reads a column-zero block list and a flow sequence in frontmatter' {
        $r = New-Fixture
        "---`ndescription: Listed.`napplies_to:`n- src/**`n- tests/**`n---`n# Doc`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        "---`ndescription: Flow.`napplies_to: [`"lib/**`", 'bin/**']`n---`n# Two`n" | Set-Content -LiteralPath (Join-Path $r 'docs/two.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $res = Get-Result $r
        (Get-Rules $res 'doc-reachable').Count | Should -Be 0
        @(($res.data.routes | Where-Object { $_.file -eq 'docs/one.md' }).globs) | Should -Be @('src/**', 'tests/**')
        @(($res.data.routes | Where-Object { $_.file -eq 'docs/two.md' }).globs) | Should -Be @('lib/**', 'bin/**')
    }
    It 'does not treat a public IPv6 literal as a local host' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value 'see http://[2606:4700::1111]/payload and http://[::1]/local and http://[fd12::1]/ula'
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["github.com"]}]}}' | Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $f = Get-Rules (Get-Result $r) 'link-hosts'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match '2606:4700::1111'
    }
    It 'strips tilde fences like backtick fences' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @('~~~', '[x](docs/nope.md)', '## Fake Section', '~~~')
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
        '{"schemaVersion":1,"rules":{"required-sections":["error",{"sections":["Fake Section"]}],"routing-current":["off"]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        (Get-Rules (Get-Result $r) 'required-sections').Count | Should -Be 1
    }
    It 'reports a link whose case differs from the file on disk' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value '[g](docs/One.md)'
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'differs in case'
    }
    It 'reports a missing CLAUDE.md as absent in the shim verdict' {
        Get-OctoAgentDocsShimVerdict -Text $null -ExpectedLines @('@AGENTS.md') | Should -Be 'absent'
        $r = New-Fixture -Agents
        (Get-Result $r).data.shim | Should -Be 'absent'
    }
    It 'checks an angle-bracketed destination that contains a space' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value '[spec](<docs/my file.md>)'
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'docs/my file\.md'
    }
}

Describe 'review pass - CRLF marker lookup, YAML scalars, advice, exit code' {
    It 'does not write the table into a fenced example in a CRLF file either' {
        $r = New-Fixture -Agents
        $p = Join-Path $r 'AGENTS.md'
        $example = "``````markdown`n<!-- >>> generated: routing -->`n<!-- <<< end generated: routing -->`n```````n`n"
        [System.IO.File]::WriteAllText($p, (($example + [System.IO.File]::ReadAllText($p)) -replace "`r?`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $after = [System.IO.File]::ReadAllText($p)
        $after.IndexOf('| `src/**` |') | Should -BeGreaterThan $after.IndexOf('```')
        $after.IndexOf('| `src/**` |') | Should -BeGreaterThan $after.LastIndexOf('```')
        (Get-Rules (Get-Result $r) 'routing-current').Count | Should -Be 0
    }
    It 'keeps a brace expansion inside a flow sequence intact' {
        $r = New-Fixture
        "---`ndescription: Flow.`napplies_to: [src/**/*.{cs,csproj}, tests/**]`n---`n# Doc`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        @((Get-Result $r).data.routes[0].globs) | Should -Be @('src/**/*.{cs,csproj}', 'tests/**')
    }
    It 'folds a YAML block scalar description into one line' {
        $r = New-Fixture
        "---`ndescription: >`n  Long text on`n  two lines.`napplies_to: src/**`n---`n# Doc`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        (Get-Result $r).data.routes[0].description | Should -Be 'Long text on two lines.'
    }
    It 'gives the same shim advice with and without -Fix for a CLAUDE.md with real content' {
        $r = New-Fixture -Agents
        '# real content' | Set-Content -LiteralPath (Join-Path $r 'CLAUDE.md')
        (Get-Rules (Get-Result $r) 'shim-valid')[0].message | Should -Match '-Fix -Force'
        (Get-Rules (Get-Result $r) 'shim-valid')[0].message | Should -Not -Match '\(run with -Fix\)'
    }
    It 'resets LASTEXITCODE to 0 on a clean enforce run' {
        $r = New-Fixture -Agents
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $global:LASTEXITCODE = 7
        Test-OctoAgentDocs -Path $r -Mode enforce 6>$null | Out-Null
        $global:LASTEXITCODE | Should -Be 0
    }
    It 'measures long lines with the same fence rules as every other check' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        # An unterminated fence: the shared pattern sees prose, so the long line is measured.
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @('```', ('word ' * 40))
        (Get-Rules (Get-Result $r) 'line-length').Count | Should -Be 1
    }
}

Describe 'CommonMark edge cases - fences, destinations, reference definitions' {
    It 'strips a fence opened and closed with four backticks' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @('````markdown', '```', '[x](docs/nope.md)', '```', '````')
        (Get-Rules (Get-Result $r) 'reference-resolves').Count | Should -Be 0
    }
    It 'checks the host of a protocol-relative link in an href and in a Markdown destination' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'docs/one.md') -Value @('<a href="//evil.example/x">x</a>', '[y](//also.example/y)', '[z]: //third.example/z', 'see [ok](/docs/one.md)')
        '{"schemaVersion":1,"rules":{"link-hosts":["error",{"allow":["docs.claude.com"]}]}}' |
            Set-Content -LiteralPath (Join-Path $r '.agent-docs.json')
        $res = Get-Result $r
        @(Get-Rules $res 'link-hosts' | ForEach-Object { $_.message }) -join ' ' | Should -Match 'evil\.example'
        @(Get-Rules $res 'link-hosts' | ForEach-Object { $_.message }) -join ' ' | Should -Match 'also\.example'
        @(Get-Rules $res 'link-hosts' | ForEach-Object { $_.message }) -join ' ' | Should -Match 'third\.example'
        (Get-Rules $res 'reference-resolves').Count | Should -Be 0
    }
    It 'follows a reference-style definition and ignores a footnote' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value @('See [the guide][guide] and [more][missing].[^1]', '', '[guide]: docs/one.md "Routed doc"', '[missing]: <docs/nope.md>', '[^1]: Footnote text, not a path.')
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'docs/nope\.md'
    }
    It 'reads a destination with balanced parentheses to its end' {
        $r = New-Fixture
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        '# V2' | Set-Content -LiteralPath (Join-Path $r 'docs/Foo_(v2).md')
        Add-Content -LiteralPath (Join-Path $r 'CLAUDE.md') -Value '[v2](docs/Foo_(v2).md) and [gone](docs/Bar_(v3).md)'
        $f = Get-Rules (Get-Result $r) 'reference-resolves'
        $f.Count | Should -Be 1
        $f[0].message | Should -Match 'Bar_\(v3\)\.md'
    }
    It 'keeps a block scalar line that looks like a key as description text' {
        $r = New-Fixture
        "---`ndescription: >`n  Setup first,`n  note: then build.`napplies_to: src/**`n---`n# Doc`n" | Set-Content -LiteralPath (Join-Path $r 'docs/one.md') -NoNewline
        Test-OctoAgentDocs -Path $r -Fix 6>$null | Out-Null
        $route = (Get-Result $r).data.routes[0]
        $route.description | Should -Be 'Setup first, note: then build.'
        @($route.globs) | Should -Be @('src/**')
    }
}
