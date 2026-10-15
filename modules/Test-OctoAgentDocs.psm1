# No -Force: forcing the import from inside a module removes the shared module from other callers.
Import-Module (Join-Path $PSScriptRoot 'OctoJsonOutput.psm1')
Import-Module (Join-Path $PSScriptRoot 'OctoAgentDocs.Common.psm1')

$script:RuleIds = Get-OctoAgentDocsRuleIdList
$script:Modes = @('logOnly', 'enforce')

class AgentDocsRuleSet {
    # The built-in ruleset with the override layers merged on top.
    [hashtable]$Config
    [string[]]$Floor
    hidden [hashtable]$BuiltIn = @{}
    hidden [hashtable]$Rank = @{ off = 0; warn = 1; error = 2 }

    AgentDocsRuleSet() {
        $this.Config = Read-OctoAgentDocsBuiltInRuleset
        $this.Floor = @($this.Config['nonRelaxable'])
        foreach ($id in $script:RuleIds) { $this.BuiltIn[$id] = $this.Config.rules[$id][1] }
    }

    [void] Merge([hashtable]$Layer, [string]$Source, [bool]$Trusted) {
        # The repository's own file is part of the branch under review: it may raise the mode
        # and the non-relaxable rules, never lower them.
        if ($Layer.ContainsKey('mode')) {
            if ($script:Modes -notcontains $Layer.mode) { Write-Warning "Invalid mode '$($Layer.mode)' in $Source - must be logOnly or enforce. Keeping '$($this.Config.mode)'." }
            elseif (-not $Trusted -and $Layer.mode -eq 'logOnly' -and $this.Config.mode -eq 'enforce') { Write-Warning "$Source asks for mode 'logOnly', which is weaker than 'enforce' - a repository may raise the mode but not lower it. Keeping 'enforce'." }
            else { $this.Config.mode = $Layer.mode }
        }
        foreach ($id in @(if ($Layer['rules'] -is [hashtable]) { $Layer['rules'].Keys })) {
            if ($script:RuleIds -notcontains $id) { Write-Warning "Unknown rule '$id' in $Source - ignored"; continue }
            $entry = ConvertTo-OctoAgentDocsRuleEntry $Layer.rules[$id]
            $current = $this.Config.rules[$id]
            if (-not $entry.valid) { Write-Warning "Invalid severity '$($entry.severity)' for rule '$id' in $Source - must be off, warn or error. Keeping '$($current[0])'."; continue }
            if (-not $Trusted -and $this.Floor -contains $id) {
                if ($this.Rank[$entry.severity] -lt $this.Rank[$current[0]]) { Write-Warning "'$id' is non-relaxable: $Source asks for '$($entry.severity)', keeping '$($current[0])'. Change the org ruleset in octo-tools if this rule is wrong."; continue }
                $this.Config.rules[$id] = @($entry.severity, $current[1])
                continue
            }
            $merged = $current[1].Clone()
            foreach ($k in $entry.options.Keys) { $merged[$k] = $entry.options[$k] }
            $this.Config.rules[$id] = @($entry.severity, $merged)
        }
    }

    [string] Mode() { return $this.Config.mode }
    [string] Severity([string]$Id) { return $this.Config.rules[$Id][0] }
    [bool] IsOn([string]$Id) { return $this.Severity($Id) -ne 'off' }
    [int] Tier([string]$Id) { return Get-OctoAgentDocsRuleTier -Config $this.Config -Id $Id }

    [object] Option([string]$Id, [string]$Name) {
        # A layer that sets an option to null falls back to the built-in value.
        $v = $this.Config.rules[$Id][1][$Name]
        if ($null -eq $v) { return $this.BuiltIn[$Id][$Name] }
        return $v
    }
}

class AgentDocsFindings {
    # Findings for a rule that is off are dropped here.
    [System.Collections.Generic.List[object]]$Items = [System.Collections.Generic.List[object]]::new()
    hidden [AgentDocsRuleSet]$Rules

    AgentDocsFindings([AgentDocsRuleSet]$Rules) { $this.Rules = $Rules }

    [void] Add([string]$Rule, [string]$File, [string]$Message) { $this.Add($Rule, $File, $Message, $this.Rules.Severity($Rule)) }

    [void] Add([string]$Rule, [string]$File, [string]$Message, [string]$Severity) {
        if ($Severity -ne 'off') { $this.Items.Add([ordered]@{ severity = $Severity; rule = $Rule; tier = $this.Rules.Tier($Rule); file = $File; message = $Message }) }
    }

    [object[]] WithSeverity([string]$Severity) { return @($this.Items | Where-Object { $_.severity -eq $Severity }) }
}

class AgentDocsRepository {
    # Read once per run; file text is cached.
    [string]$Root
    [string]$Name
    [string[]]$RootNames
    [bool]$HasAgents
    [bool]$HasClaude
    [string]$AgentsPath
    [string]$ClaudePath
    [string]$EntryPath
    [string]$EntryName = ''
    [object[]]$Docs = @()
    [System.Collections.Generic.List[string]]$Written = [System.Collections.Generic.List[string]]::new()
    hidden [hashtable]$TextCache = @{}
    hidden [hashtable]$DirCache = @{}

    AgentDocsRepository([string]$Root) {
        $this.Root = $Root
        $this.Name = Split-Path -Leaf $Root
        # By exact name: a case-insensitive file system would accept agents.md, Linux CI would not.
        $this.RootNames = @(Get-ChildItem -LiteralPath $Root -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $this.HasAgents = $this.RootNames -ccontains 'AGENTS.md'
        $this.HasClaude = $this.RootNames -ccontains 'CLAUDE.md'
        $this.AgentsPath = Join-Path $Root 'AGENTS.md'
        $this.ClaudePath = Join-Path $Root 'CLAUDE.md'
        $this.EntryPath = if ($this.HasAgents) { $this.AgentsPath } elseif ($this.HasClaude) { $this.ClaudePath } else { $null }
        if ($this.EntryPath) { $this.EntryName = Split-Path -Leaf $this.EntryPath }
        $docsDir = Join-Path $Root 'docs'
        if (Test-Path -LiteralPath $docsDir) {
            # Ordinal order: the table is committed, so its order must not depend on the machine's culture.
            $list = @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File)
            [array]::Sort($list, [System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Name, $b.Name) })
            $this.Docs = $list
        }
    }

    [string] ReadText([string]$Path) {
        if (-not $this.TextCache.ContainsKey($Path)) { $this.TextCache[$Path] = Read-OctoAgentDocsText $Path }
        return $this.TextCache[$Path]
    }

    [void] Write([string]$Path, [string]$Content) {
        Write-OctoAgentDocsText -Path $Path -Content $Content
        $this.TextCache[$Path] = $Content.Replace("`r`n", "`n")
        $this.Written.Add((Split-Path -Leaf $Path))
    }

    [string] Relative([string]$Path) { return [System.IO.Path]::GetRelativePath($this.Root, $Path).Replace('\', '/') }

    [bool] ExistsExactCase([string]$Relative) {
        # Test-Path is case-insensitive on macOS and Windows; GitHub and Linux CI are not.
        $current = $this.Root
        foreach ($segment in ($Relative -split '[\\/]+' | Where-Object { $_ -and $_ -ne '.' })) {
            if ($segment -eq '..') { $current = Split-Path -Parent $current; continue }
            if (-not $this.DirCache.ContainsKey($current)) { $this.DirCache[$current] = @([System.IO.Directory]::EnumerateFileSystemEntries($current) | ForEach-Object { [System.IO.Path]::GetFileName($_) }) }
            if ($this.DirCache[$current] -cnotcontains $segment) { return $false }
            $current = Join-Path $current $segment
        }
        return $true
    }

    [bool] PointsAtShim([string]$Path) {
        if ((Split-Path -Leaf $Path) -cne 'CLAUDE.md' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        return (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Path) 'AGENTS.md')) -and (Test-OctoAgentDocsShimLike $this.ReadText($Path))
    }
}

function Test-OctoAgentDocs {
    <#
    .SYNOPSIS
    Checks a repository's agent instruction files and regenerates the parts that are derived.

    .DESCRIPTION
    Checks the entry point (AGENTS.md, or CLAUDE.md before a migration), the README and
    docs/*.md: sections, budgets, frontmatter, links, the CLAUDE.md shim, invisible
    characters and the generated routing table. -Fix regenerates only the routing table and
    the shim; hand-written text is never changed. 'Test-OctoAgentDocs -Explain -All' lists
    every rule with its reason.

    Rules are [severity, options] with severity off | warn | error, and cascade, later wins:
    agent-docs.rules.json beside this module, the repository's .agent-docs.json, -ConfigPath,
    -Mode. The repository file may raise the mode and the 'nonRelaxable' rules, never lower
    them. Mode enforce (CI) throws and sets a non-zero exit code on an error-severity finding.

    .PARAMETER Path
    Repository to check: a path, or a repository name under $Global:ROOTPATH. Default: '.'.

    .PARAMETER Fix
    Rewrite the generated regions instead of only reporting them stale. Supports -WhatIf.

    .PARAMETER Force
    With -Fix, let the shim replace a CLAUDE.md that still has real content.

    .PARAMETER Explain
    Add why and how to fix for every rule that fired. With -All or -Rule nothing is scanned:
    the rules are listed as a reference with the severity this repository ends up with.
    -Explain never throws, whatever the mode.

    .PARAMETER Rule
    With -Explain, the rule ids to list. Positional: 'Test-OctoAgentDocs -Explain line-length'.

    .PARAMETER Mode
    Override the configured mode: logOnly or enforce.

    .PARAMETER ConfigPath
    An additional ruleset file, merged after the repository's own.

    .PARAMETER Json
    Emit the standard octo-tools JSON envelope instead of human output.

    .EXAMPLE
    Test-OctoAgentDocs -Path octo-communication-operator -Fix -WhatIf

    .EXAMPLE
    Test-OctoAgentDocs -Explain doc-size,line-length
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'Check')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Human report on the host, -Json on the pipeline: the octo-tools convention')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$Global:ROOTPATH and $global:LASTEXITCODE are the octo-tools profile contract')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'AgentDocs is the name of the thing being checked')]
    param(
        [Parameter(Position = 0, ParameterSetName = 'Check')]
        [Parameter(ParameterSetName = 'Reference')]
        [string]$Path = '.',
        [switch]$Fix,
        [switch]$Force,
        [ValidateSet('logOnly', 'enforce')]
        [string]$Mode,
        [string]$ConfigPath,
        [switch]$Json,
        [switch]$Explain,
        [switch]$All,
        [Parameter(Position = 0, ParameterSetName = 'Reference')]
        [string[]]$Rule
    )
    $ErrorActionPreference = 'Stop'

    # 'Test-OctoAgentDocs -Explain line-length' puts the rule id where -Path binds.
    if ($Explain -and -not $Rule -and $Path -ne '.') {
        if ($script:RuleIds -contains $Path) { $Rule = @($Path); $Path = '.' }
        elseif (-not (Test-Path -LiteralPath $Path) -and -not ($Global:ROOTPATH -and (Test-Path -LiteralPath (Join-Path $Global:ROOTPATH $Path)))) {
            throw "'$Path' is neither a repository path nor a rule id. Rules: $($script:RuleIds -join ', ')"
        }
    }
    if (($Rule -or $All) -and -not $Explain) { Write-Warning '-Rule and -All only shape -Explain output; ignored without -Explain' }
    $reference = $Explain -and ($All -or $Rule)
    if ($reference -and $Fix) { Write-Warning '-Fix is ignored with -Explain -All or -Rule: nothing is scanned' }
    $root = Resolve-OctoAgentDocsRepository -Path $Path
    $rules = Resolve-RuleSet -Root $root -ConfigPath $ConfigPath -Mode $Mode

    $global:LASTEXITCODE = 0
    if ($reference) {
        $ids = if ($Rule) { @($Rule) } else { @($script:RuleIds) }
        Write-RuleReference -Rules $rules -Id $ids -RepositoryName (Split-Path -Leaf $root) -Json:$Json
        return
    }

    $repo = [AgentDocsRepository]::new($root)
    $findings = [AgentDocsFindings]::new($rules)
    if (-not $repo.EntryPath) { $findings.Add('required-sections', '', 'Neither AGENTS.md nor CLAUDE.md exists - the repository has no entry point') }
    $shim = Test-ClaudeShim -Rules $rules -Repo $repo -Findings $findings -Fix:$Fix -Force:$Force
    $briefName = Get-OctoAgentDocsConstant BriefName
    if (Test-Path -LiteralPath (Join-Path $root $briefName)) {
        $findings.Add('migration-pending', $briefName, 'Migration brief is still present - follow its steps and delete it in the migration commit')
    }
    $routes = Test-DocsFolder -Rules $rules -Repo $repo -Findings $findings
    Test-InvisibleCharacter -Rules $rules -Repo $repo -Findings $findings
    Test-ReferenceSet -Rules $rules -Repo $repo -Findings $findings
    if ($repo.EntryPath) {
        Test-RequiredSection -Rules $rules -Repo $repo -Findings $findings
        Test-RoutingTable -Rules $rules -Repo $repo -Findings $findings -Route $routes -Fix:$Fix
        Test-EntryBudget -Rules $rules -Repo $repo -Findings $findings
    }

    $errorCount = $findings.WithSeverity('error').Count
    $startHere = Get-StartHere -Repo $repo -Findings $findings -PathArgument (Format-OctoAgentDocsArgument -Value $Path)
    if ($Json) {
        $fired = @($findings.Items.rule | Sort-Object -Unique)
        Write-OctoJson -Command 'Test-OctoAgentDocs' -Data ([ordered]@{
            repository   = $repo.Name
            entryPoint   = $repo.EntryName
            canonical    = if ($repo.HasAgents) { 'AGENTS.md' } else { 'CLAUDE.md' }
            shim         = $shim
            mode         = $rules.Mode()
            filesWritten = @($repo.Written)
            routes       = @($routes)
            findings     = @($findings.Items)
            startHere    = $startHere
            explanations = @(if ($Explain) { @(foreach ($id in $fired) { Get-RuleRow -Rules $rules -Id $id }) | Sort-Object -Stable { $_.tier }, { $_.rule } })
            ruleSet      = $rules.Config.rules
            summary      = [ordered]@{ errors = $errorCount; warnings = $findings.WithSeverity('warn').Count; success = ($errorCount -eq 0) }
        })
    }
    else {
        Write-FindingReport -Rules $rules -Repo $repo -Findings $findings -RouteCount @($routes).Count -StartHere $startHere -Explain:$Explain -Fix:$Fix
    }

    # -Explain is a person asking why; the gate is for pipelines.
    if ($rules.Mode() -eq 'enforce' -and $errorCount -gt 0 -and -not $Explain) {
        $global:LASTEXITCODE = 1
        throw "Test-OctoAgentDocs: $errorCount error-severity finding(s) in $($repo.Name)"
    }
}

function Resolve-RuleSet {
    param([string]$Root, [string]$ConfigPath, [string]$Mode)
    if ($ConfigPath -and -not (Test-Path -LiteralPath $ConfigPath)) { throw "-ConfigPath '$ConfigPath' does not exist" }
    $rules = [AgentDocsRuleSet]::new()
    foreach ($layer in @(@{ path = (Join-Path $Root '.agent-docs.json'); trusted = $false }, @{ path = $ConfigPath; trusted = $true })) {
        if (-not $layer.path -or -not (Test-Path -LiteralPath $layer.path)) { continue }
        $content = try { Get-Content -LiteralPath $layer.path -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
        if ($content -isnot [hashtable]) { Write-Warning "Ruleset '$($layer.path)' is not a JSON object - ignored"; continue }
        $rules.Merge($content, $layer.path, $layer.trusted)
    }
    if ($Mode) { $rules.Config.mode = $Mode }
    return $rules
}

function Test-ClaudeShim {
    # The verdict (n/a, absent, ok, differs) is computed whatever the rule's severity:
    # Initialize-OctoAgentDocs reads it.
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings, [switch]$Fix, [switch]$Force)
    if (-not $Repo.HasAgents) { return 'n/a' }
    $shim = @($Rules.Option('shim-valid', 'content')) -join "`n"
    $current = if ($Repo.HasClaude) { $Repo.ReadText($Repo.ClaudePath) } else { $null }
    $verdict = if ($null -eq $current) { 'absent' } elseif ($current.Trim() -ceq $shim) { 'ok' } else { 'differs' }
    if (-not $Rules.IsOn('shim-valid')) { return $verdict }

    # On a case-insensitive file system writing CLAUDE.md would overwrite a 'claude.md'.
    $alias = $Repo.RootNames | Where-Object { $_ -ieq 'CLAUDE.md' -and $_ -cne 'CLAUDE.md' } | Select-Object -First 1
    if ($alias) { $Findings.Add('shim-valid', $alias, "Named '$alias', not CLAUDE.md - rename it before -Fix can write the shim"); return $verdict }
    if ($verdict -eq 'ok') { return $verdict }
    if ($Repo.HasClaude -and -not $Force -and -not (Test-OctoAgentDocsShimLike $current)) {
        $Findings.Add('shim-valid', 'CLAUDE.md', 'Has real content while AGENTS.md is canonical - migrate it by hand, or run -Fix -Force to replace it with the shim')
    }
    elseif (-not $Fix) { $Findings.Add('shim-valid', 'CLAUDE.md', "$(if ($Repo.HasClaude) { 'CLAUDE.md must contain exactly the shim and nothing else' } else { 'CLAUDE.md shim is absent' }) (run with -Fix)") }
    elseif (-not (Update-ClaudeShim -Repo $Repo -Content "$shim`n")) { $Findings.Add('shim-valid', 'CLAUDE.md', 'CLAUDE.md shim would be written (run without -WhatIf)') }
    return $verdict
}

function Update-ClaudeShim {
    # False under -WhatIf or when declined.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([bool])]
    param([AgentDocsRepository]$Repo, [string]$Content)
    if (-not $PSCmdlet.ShouldProcess('CLAUDE.md', 'Write the AGENTS.md shim')) { return $false }
    $Repo.Write($Repo.ClaudePath, $Content)
    return $true
}

function Test-DocsFolder {
    # Returns the routes the table is generated from.
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings)
    $routes = [System.Collections.Generic.List[object]]::new()
    $maxDescription = $Rules.Option('frontmatter-present', 'maxDescription')
    $maxCharacters = $Rules.Option('doc-size', 'maxCharacters')
    foreach ($d in $Repo.Docs) {
        $content = $Repo.ReadText($d.FullName)
        $fm = Get-Frontmatter -Content $content
        $rel = "docs/$($d.Name)"
        if (-not $fm['description']) { $Findings.Add('frontmatter-present', $rel, "No 'description' in frontmatter") }
        elseif ($fm['description'].Length -gt $maxDescription) { $Findings.Add('frontmatter-present', $rel, "description is $($fm['description'].Length) characters, limit $maxDescription - shorten it to one scannable line") }
        $hasRoutes = [bool]$fm['applies_to']
        if (-not ($hasRoutes -xor ($fm['background'] -match '^(true|yes)$'))) { $Findings.Add('doc-reachable', $rel, "Needs either 'applies_to' globs or 'background: true', not both and not neither") }
        if ($content.Length -gt $maxCharacters) {
            $Findings.Add('doc-size', $rel, "$($content.Length) characters (limit $maxCharacters) - loaded whole whenever this doc is routed. Trim it; split only if it covers more than one topic; or raise the limit in .agent-docs.json")
        }
        if ($hasRoutes) { $routes.Add([ordered]@{ file = $rel; globs = (Split-GlobList -Value $fm['applies_to']); description = [string]$fm['description'] }) }
    }
    $maxDocs = $Rules.Option('docs-count', 'max')
    if ($routes.Count -gt $maxDocs) { $Findings.Add('docs-count', 'docs/', "$($routes.Count) routed docs (limit $maxDocs) - the routing table needs grouping") }
    return , $routes
}

function Get-Frontmatter {
    # 'key: value' lines between the two '---' fences. Quotes and [ ] around a value are
    # dropped; other YAML shapes are not supported and read as missing.
    param([string]$Content)
    $map = @{}
    $lines = @($Content -split "`n")
    if ($lines.Count -lt 2 -or $lines[0].Trim() -ne '---') { return $map }
    for ($i = 1; $i -lt $lines.Count -and $lines[$i].Trim() -ne '---'; $i++) {
        if ($lines[$i] -match '^([A-Za-z_][\w-]*)\s*:\s*(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() -replace '^\[(.*)\]$', '$1' -replace '^(["''])(.*)\1$', '$2' }
    }
    if ($i -ge $lines.Count) { return @{} }   # no closing fence: not frontmatter
    return $map
}

function Split-GlobList {
    # Commas separate globs, except inside a {a,b} alternation.
    param([string]$Value)
    return , @([regex]::Split($Value, ',(?![^{]*\})') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-InvisibleCharacter {
    # Every Markdown file an agent might read, dotfolders included, minus scan.ignore.
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings)
    if (-not $Rules.IsOn('no-invisible-characters')) { return }
    # Unicode Tag characters, zero-width and format characters, and bidirectional overrides:
    # visible to a model, not to a reviewer. U+200D is reported only outside an emoji sequence.
    $invisible = [ordered]@{
        'Unicode Tag character'   = '\uDB40[\uDC00-\uDC7F]'
        'invisible character'     = '[\u00AD\u034F\u061C\u180E\u200B\u200C\u200E\u200F\u2060-\u2064\uFEFF]'
        'stray zero-width joiner' = '(?<![\p{So}\uFE0F\uDC00-\uDFFF])\u200D|\u200D(?![\p{So}\uFE0F\uD800-\uDBFF])'
        'bidirectional override'  = '[\u202A-\u202E\u2066-\u2069]'
    }
    $ignore = @($Rules.Config['scan']['ignore'])
    $files = Get-ChildItem -LiteralPath $Repo.Root -Recurse -Force -File -Filter '*.md' -ErrorAction SilentlyContinue |
        Where-Object { -not ($Repo.Relative($_.DirectoryName) -split '/' | Where-Object { $ignore -contains $_ }) } | Sort-Object FullName
    foreach ($f in $files) {
        $content = $Repo.ReadText($f.FullName)
        foreach ($kind in $invisible.Keys) {
            $hits = [regex]::Matches($content, $invisible[$kind])
            if ($hits.Count -eq 0) { continue }
            $line = ($content.Substring(0, $hits[0].Index) -split "`n").Count
            $Findings.Add('no-invisible-characters', "$($Repo.Relative($f.FullName)):$line", "$($hits.Count) $kind(s) - invisible to a reviewer, not to a model. Remove them")
        }
    }
}

function Test-ReferenceSet {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$Global:ROOTPATH is the octo-tools profile contract')]
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings)
    if (-not $Rules.IsOn('reference-resolves') -and -not $Rules.IsOn('reference-to-shim')) { return }
    $readme = $Repo.RootNames | Where-Object { $_ -ieq 'README.md' } | Select-Object -First 1
    $files = @($Repo.EntryPath, $(if ($readme) { Join-Path $Repo.Root $readme })) + @($Repo.Docs.FullName) | Where-Object { $_ }
    $siblingPattern = $Rules.Option('reference-resolves', 'siblingRepoPattern')
    $siblingRoot = if ($Global:ROOTPATH) { $Global:ROOTPATH } else { Split-Path -Parent $Repo.Root }
    $startMarker = Get-OctoAgentDocsConstant RoutingStart
    $endMarker = Get-OctoAgentDocsConstant RoutingEnd
    $anchors = @{}
    foreach ($f in $files) {
        $source = @{ Repo = $Repo; Findings = $Findings; Anchors = $anchors; Rel = $Repo.Relative($f) }
        $prose = ConvertTo-OctoAgentDocsProse $Repo.ReadText($f)
        if ($f -eq $Repo.EntryPath) {
            # The generated table is derived, not written: a stale row naming a doc that is
            # gone is fixed by -Fix, not by a reference finding that would outlive the fix.
            $si = Find-OctoAgentDocsMarker -Text $prose -Marker $startMarker
            $ei = Find-OctoAgentDocsMarker -Text $prose -Marker $endMarker
            if ($si -ge 0 -and $ei -gt $si) { $prose = $prose.Substring(0, $si) + $prose.Substring($ei) }
        }
        # Inline links, with code spans removed first: `[label](path.md)` is quoted syntax.
        foreach ($m in [regex]::Matches(($prose -replace '`[^`\n]*`', ''), '\]\(\s*<?([^)\s>]+)>?')) {
            $target = [System.Uri]::UnescapeDataString($m.Groups[1].Value)
            if ($target -match '^([A-Za-z][A-Za-z0-9+.-]*:|//)') { continue }   # URL
            Test-ReferenceTarget @source -From $f -Target $target -Kind 'Link target'
        }
        # Paths in backticks: `docs/topic.md`. A bare `CLAUDE.md` means this repository's own.
        foreach ($m in [regex]::Matches($prose, '`([^`\s]+\.md)`')) {
            $ref = $m.Groups[1].Value
            $shimPath = $null
            if ($ref -ceq 'CLAUDE.md') { $shimPath = $Repo.ClaudePath }
            elseif ($ref -notmatch '/' -or $ref -match '^(\.\.|~|/|[A-Za-z]:)' -or $ref -match '[*?\[{<>]') { continue }   # a phrase, an outside path, or a pattern
            elseif ($siblingPattern -and $ref -match $siblingPattern) { $shimPath = Join-Path $siblingRoot $ref }
            if ($shimPath) {
                if ($Repo.PointsAtShim($shimPath)) { $Findings.Add('reference-to-shim', $source.Rel, "``$ref`` $(Get-ShimAdvice -Reference $ref)") }
                continue
            }
            Test-ReferenceTarget @source -From $Repo.AgentsPath -Target $ref -Kind 'Referenced file'
        }
    }
}

function Test-ReferenceTarget {
    # One resolver for links and backtick paths: exists, exact case, shim, anchor.
    param([AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings, [hashtable]$Anchors, [string]$Rel, [string]$From, [string]$Target, [string]$Kind)
    $filePart, $anchor = $Target -split '#', 2
    $resolved = if (-not $filePart) { $From } elseif ($filePart.StartsWith('/')) { Join-Path $Repo.Root $filePart.TrimStart('/') } else { Join-Path (Split-Path -Parent $From) $filePart }
    if (-not (Test-Path -LiteralPath $resolved)) { $Findings.Add('reference-resolves', $Rel, "$Kind not found: $Target"); return }
    $relToRepo = [System.IO.Path]::GetRelativePath($Repo.Root, [System.IO.Path]::GetFullPath($resolved))
    if ($filePart -and -not $relToRepo.StartsWith('..') -and -not $Repo.ExistsExactCase($relToRepo)) { $Findings.Add('reference-resolves', $Rel, "$Kind differs in case from the file on disk: $Target"); return }
    if ($filePart -and $Repo.PointsAtShim($resolved)) { $Findings.Add('reference-to-shim', $Rel, "$Kind $(Get-ShimAdvice -Reference $filePart)") }
    if ($anchor -and $resolved -like '*.md') {
        $full = (Resolve-Path -LiteralPath $resolved).Path
        if (-not $Anchors.ContainsKey($full)) { $Anchors[$full] = Get-HeadingAnchor -Prose (ConvertTo-OctoAgentDocsProse $Repo.ReadText($full)) }
        if (-not $Anchors[$full].Contains($anchor)) { $Findings.Add('reference-resolves', $Rel, "Anchor not found: $Target") }
    }
}

function Get-ShimAdvice {
    param([string]$Reference)
    return "points at a shim - reference '$($Reference -replace 'CLAUDE\.md$', 'AGENTS.md')' instead, since an agent reading the shim gets only '@AGENTS.md'"
}

function Get-HeadingAnchor {
    # GitHub-style heading slugs, repeats suffixed -1, -2. Case-insensitive, like github.com
    # and VS Code resolve a fragment.
    param([string]$Prose)
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $seen = @{}
    foreach ($m in [regex]::Matches($Prose, '(?m)^#{1,6}[ \t]+(.*?)[ \t]*$')) {
        $a = [regex]::Replace($m.Groups[1].Value, '\[([^\]]*)\]\([^)]*\)', '$1').ToLowerInvariant() -replace '[^\p{L}\p{N}\p{M} _-]', '' -replace ' ', '-'
        if ($seen.ContainsKey($a)) { $seen[$a]++; [void]$set.Add("$a-$($seen[$a])") } else { $seen[$a] = 0; [void]$set.Add($a) }
    }
    return , $set
}

function Test-RequiredSection {
    # A missing section is reported, never written.
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings)
    $headings = @([regex]::Matches((ConvertTo-OctoAgentDocsProse $Repo.ReadText($Repo.EntryPath)), '(?m)^##[ \t]+(.*?)[ \t]*$') | ForEach-Object { $_.Groups[1].Value })
    $missing = @(foreach ($want in @($Rules.Option('required-sections', 'sections'))) { if ($headings -notcontains $want) { "'## $want'" } })
    if ($missing.Count -eq 1) { $Findings.Add('required-sections', $Repo.EntryName, "Missing section $($missing[0]) - every repo's entry point carries it") }
    elseif ($missing.Count -gt 1) { $Findings.Add('required-sections', $Repo.EntryName, "Missing sections $($missing -join ', ') - every repo's entry point carries them") }
}

function Test-RoutingTable {
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings, [object[]]$Route, [switch]$Fix)
    if (-not $Rules.IsOn('routing-current')) { return }
    $generated = Format-RoutingTable -Route $Route -WithDescription ([bool]$Rules.Option('routing-current', 'includeDescriptions'))
    $startMarker = Get-OctoAgentDocsConstant RoutingStart
    $endMarker = Get-OctoAgentDocsConstant RoutingEnd
    $entry = $Repo.ReadText($Repo.EntryPath)
    $si = Find-OctoAgentDocsMarker -Text $entry -Marker $startMarker
    $ei = Find-OctoAgentDocsMarker -Text $entry -Marker $endMarker
    if ($si -lt 0 -or $ei -lt $si) { $Findings.Add('routing-current', $Repo.EntryName, "Add $startMarker and $endMarker around the routing table"); return }
    if ($entry.Substring($si + $startMarker.Length, $ei - $si - $startMarker.Length) -ceq "`n$generated`n") { return }
    if (-not $Fix) { $Findings.Add('routing-current', $Repo.EntryName, 'Generated routing table is out of date (run with -Fix)') }
    elseif (-not (Update-RoutingTable -Repo $Repo -Table $generated)) { $Findings.Add('routing-current', $Repo.EntryName, 'Generated routing table would be rewritten (run without -WhatIf)') }
}

function Format-RoutingTable {
    param([object[]]$Route, [bool]$WithDescription)
    $table = if ($WithDescription) { @('| When you change | Read first | What it covers |', '|---|---|---|') } else { @('| When you change | Read first |', '|---|---|') }
    foreach ($r in $Route) {
        $globs = @($r.globs | ForEach-Object { "``$_``" }) -join ', '
        $table += if ($WithDescription) { "| $globs | ``$($r.file)`` | $($r.description -replace '\|', '\|') |" } else { "| $globs | ``$($r.file)`` |" }
    }
    return $table -join "`n"
}

function Update-RoutingTable {
    # Keeps the file's own line endings. False under -WhatIf or when declined.
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([bool])]
    param([AgentDocsRepository]$Repo, [string]$Table)
    if (-not $PSCmdlet.ShouldProcess($Repo.EntryName, 'Regenerate the routing table')) { return $false }
    $startMarker = Get-OctoAgentDocsConstant RoutingStart
    $raw = [System.IO.File]::ReadAllText($Repo.EntryPath)
    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $si = Find-OctoAgentDocsMarker -Text $raw -Marker $startMarker
    $ei = Find-OctoAgentDocsMarker -Text $raw -Marker (Get-OctoAgentDocsConstant RoutingEnd)
    $Repo.Write($Repo.EntryPath, $raw.Substring(0, $si + $startMarker.Length) + $eol + ($Table -replace "`n", $eol) + $eol + $raw.Substring($ei))
    return $true
}

function Test-EntryBudget {
    # Measured on the text -Fix leaves behind, so a -Fix run and the next run agree.
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings)
    $entry = $Repo.ReadText($Repo.EntryPath)
    $name = $Repo.EntryName
    $lineCount = (Get-TextLine -Content $entry).Count
    $maxLines = $Rules.Option('entry-point-lines', 'max')
    if ($lineCount -gt $maxLines) { $Findings.Add('entry-point-lines', $name, "$lineCount lines over the budget of $maxLines - this file loads in every session. Move detail into docs/ and route it with applies_to") }
    $maxCharacters = $Rules.Option('entry-point-characters', 'max')
    $warnAt = $Rules.Option('entry-point-characters', 'warnAt')
    if ($entry.Length -gt $maxCharacters) { $Findings.Add('entry-point-characters', $name, "$($entry.Length) characters over the budget of $maxCharacters - move detail into docs/, or shorten the longest lines") }
    elseif ($Rules.IsOn('entry-point-characters') -and $warnAt -gt 0 -and $entry.Length -gt $warnAt) {
        $Findings.Add('entry-point-characters', $name, "$($entry.Length) characters, past the $warnAt target but under the $maxCharacters limit - worth trimming before it grows", 'warn')
    }
    if (-not $Rules.IsOn('line-length')) { return }
    $maxLine = $Rules.Option('line-length', 'max')
    $maxTable = $Rules.Option('line-length', 'tables')
    $cap = $Rules.Option('line-length', 'maxReported')
    $lines = Get-TextLine -Content (ConvertTo-OctoAgentDocsProse $entry -KeepLineNumbers)
    $hits = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $isTable = $line.TrimStart().StartsWith('|')
        $limit = if ($isTable) { $maxTable } else { $maxLine }
        # A line without any whitespace (a URL, a hash) cannot be wrapped and is exempt.
        if ($line.Length -le $limit -or $line -match '^\s*(```|~~~)' -or $line.Trim() -notmatch '\s') { continue }
        $hits++
        if ($hits -gt $cap) { continue }
        $what = if ($isTable) { "table row is $($line.Length) characters, limit $limit - shorten the globs or the description in the doc's frontmatter" } else { "line is $($line.Length) characters, limit $limit" }
        $Findings.Add('line-length', "${name}:$($i + 1)", $what)
    }
    if ($hits -gt $cap) { $Findings.Add('line-length', $name, "$($hits - $cap) further over-length lines not listed") }
}

function Get-TextLine {
    # Lines as wc -l counts them: a trailing newline does not add a line.
    param([string]$Content)
    if (-not $Content) { return , @() }
    return , @(($Content.TrimEnd("`n")) -split "`n")
}

function Get-StartHere {
    # The cause behind most of the findings, at most two sentences.
    param([AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings, [string]$PathArgument)
    $fired = @($Findings.Items.rule | Sort-Object -Unique)
    $causes = @()
    if ($fired -contains 'no-invisible-characters') { $causes += 'a file carries characters a reviewer cannot see. Remove them before anything else.' }
    if ($fired -contains 'migration-pending') { $causes += 'the migration brief is still present - follow its steps and delete it in the migration commit.' }
    elseif (-not $Repo.HasAgents -and $Repo.HasClaude -and ($fired | Where-Object { $_ -in 'required-sections', 'entry-point-characters', 'entry-point-lines' })) { $causes += "this repository has not migrated to AGENTS.md, and the entry-point findings follow from that. Initialize-OctoAgentDocs -Path $PathArgument writes the migration brief." }
    elseif (-not $Repo.EntryPath) { $causes += "this repository has no agent instructions yet. Initialize-OctoAgentDocs -Path $PathArgument writes the entry point and the shim." }
    if (-not $causes -and $Findings.Items.Count -gt 0 -and -not ($Findings.Items | Where-Object { $_.tier -lt 4 })) { $causes += 'only budgets are left. Move content into routed docs rather than trimming it in place.' }
    if ($causes.Count -eq 0) { return $null }
    if ($causes.Count -eq 1) { return $causes[0] }
    return "$($causes[0]) After that: $($causes[1])"
}

function Write-FindingReport {
    # By tier, errors before warnings, then by file; detection order within a file.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Human report on the host, -Json on the pipeline: the octo-tools convention')]
    param([AgentDocsRuleSet]$Rules, [AgentDocsRepository]$Repo, [AgentDocsFindings]$Findings, [int]$RouteCount, [string]$StartHere, [switch]$Explain, [switch]$Fix)
    $items = $Findings.Items
    Write-Host "Agent docs check: $($Repo.Name) (entry point: $($Repo.EntryName), mode: $($Rules.Mode()))" -ForegroundColor Yellow
    if ($items.Count -eq 0) { Write-Host "  clean - $RouteCount routed doc$(if ($RouteCount -ne 1) { 's' })" -ForegroundColor Green }
    else {
        $fileCount = @($items | ForEach-Object { ($_.file -split ':')[0] } | Where-Object { $_ } | Sort-Object -Unique).Count
        Write-Host "  $($Findings.WithSeverity('error').Count) error(s), $($Findings.WithSeverity('warn').Count) warning(s) in $fileCount file(s)" -ForegroundColor Gray
        if ($StartHere) { Write-Host "  Start here: $StartHere" -ForegroundColor Cyan }
        foreach ($t in @($items.tier | Sort-Object -Unique)) {
            Write-Host ''
            Write-Host "  $(Get-OctoAgentDocsTierHeading -Config $Rules.Config -Tier $t)" -ForegroundColor White
            $group = @($items | Where-Object { $_.tier -eq $t } | Sort-Object -Stable { $_.severity -ne 'error' }, { ($_.file -split ':')[0] })
            $width = ($group.rule | Measure-Object -Maximum -Property Length).Maximum
            foreach ($x in $group) {
                $colour = if ($x.severity -eq 'error') { 'Red' } else { 'DarkYellow' }
                Write-Host "     [$($x.severity)]".PadRight(13) -ForegroundColor $colour -NoNewline
                Write-Host $x.rule.PadRight($width + 2) -ForegroundColor Cyan -NoNewline
                Write-Host "$(if ($x.file) { "$($x.file): " })$($x.message)" -ForegroundColor $colour
            }
            if ($Explain) { foreach ($id in @($group.rule | Sort-Object -Unique)) { Write-RuleRow -Row (Get-RuleRow -Rules $Rules -Id $id) } }
        }
        Write-Host ''
    }
    if ($Repo.Written.Count -gt 0) { Write-Host "  rewrote $($Repo.Written -join ', ')" -ForegroundColor Cyan }
    elseif ($Fix -and -not $WhatIfPreference) { Write-Host '  nothing to rewrite' -ForegroundColor Cyan }
    if ($items.Count -eq 0) {
        Write-Host '  0 error(s), 0 warning(s)' -ForegroundColor Gray
        if ($Explain) { Write-Host '  nothing to explain - full rule reference: Test-OctoAgentDocs -Explain -All' -ForegroundColor Gray }
    }
    elseif (-not $Explain) { Write-Host '  add -Explain for why and how to fix, or -Explain <rule> for one rule' -ForegroundColor Gray }
}

function Write-RuleReference {
    # -Explain -All / -Rule: nothing is scanned.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Human report on the host, -Json on the pipeline: the octo-tools convention')]
    param([AgentDocsRuleSet]$Rules, [string[]]$Id, [string]$RepositoryName, [switch]$Json)
    $unknown = @($Id | Where-Object { $script:RuleIds -notcontains $_ })
    if ($unknown) { throw "Unknown rule(s): $($unknown -join ', '). Known: $($script:RuleIds -join ', ')" }
    $rows = @(foreach ($i in $Id) { Get-RuleRow -Rules $Rules -Id $i })
    if ($Json) { Write-OctoJson -Command 'Test-OctoAgentDocs' -Data ([ordered]@{ repository = $RepositoryName; mode = $Rules.Mode(); rules = $rows }); return }
    Write-Host "Agent docs rules for $RepositoryName (mode: $($Rules.Mode())) - effective severity, in the order to fix them" -ForegroundColor Yellow
    foreach ($t in @($rows.tier | Sort-Object -Unique)) {
        Write-Host ''
        Write-Host "  $(Get-OctoAgentDocsTierHeading -Config $Rules.Config -Tier $t)" -ForegroundColor White
        foreach ($r in @($rows | Where-Object { $_.tier -eq $t })) { Write-RuleRow -Row $r }
    }
    Write-Host ''
    Write-Host '  Overrides: .agent-docs.json in the repository, then -ConfigPath, then -Mode. Non-relaxable rules can be raised there, never lowered.' -ForegroundColor Gray
}

function Get-RuleRow {
    param([AgentDocsRuleSet]$Rules, [string]$Id)
    $doc = $Rules.Config['ruleDocs'][$Id]
    if ($doc -isnot [hashtable]) { $doc = @{} }
    return [ordered]@{ rule = $Id; tier = $Rules.Tier($Id); severity = $Rules.Severity($Id); nonRelaxable = ($Rules.Floor -contains $Id); options = $Rules.Config.rules[$Id][1]; why = [string]$doc['why']; fix = [string]$doc['fix'] }
}

function Write-RuleRow {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Human report on the host, -Json on the pipeline: the octo-tools convention')]
    param($Row, [string]$Indent = '     ')
    $colour = switch ($Row.severity) { 'error' { 'Red' } 'warn' { 'DarkYellow' } default { 'DarkGray' } }
    $lock = if ($Row.nonRelaxable) { ' (non-relaxable)' } else { '' }
    # Scalars inline, lists as a count; -Json has the full options.
    $opts = @(foreach ($k in ($Row.options.Keys | Sort-Object)) { $v = $Row.options[$k]; if ($v -is [array]) { "$k=[$($v.Count)]" } else { "$k=$v" } }) -join ', '
    Write-Host ''
    Write-Host "${Indent}rule $($Row.rule)  [$($Row.severity)]$lock" -ForegroundColor $colour -NoNewline
    if ($opts) { Write-Host "  $opts" -ForegroundColor DarkGray } else { Write-Host '' }
    if ($Row.why) { Write-Host "$Indent  why: $($Row.why)" }
    if ($Row.fix) { Write-Host "$Indent  fix: $($Row.fix)" }
}

Export-ModuleMember -Function @('Test-OctoAgentDocs')
