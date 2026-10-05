# Plain imports, not -Force: a forced import from inside a module re-homes the shared module
# and removes it from the session for the other callers.
Import-Module (Join-Path $PSScriptRoot 'OctoJsonOutput.psm1')
Import-Module (Join-Path $PSScriptRoot 'OctoAgentDocs.Common.psm1')

$script:RuleIds = Get-OctoAgentDocsRuleIdList
$script:Modes = @('logOnly', 'enforce')

function Test-OctoAgentDocs {
    <#
    .SYNOPSIS
    Checks a repository's agent instruction files and regenerates the parts that are derived.

    .DESCRIPTION
    Checks the entry point (AGENTS.md, or CLAUDE.md before a migration), the README and
    docs/*.md: required sections, line and character budgets, frontmatter, links and
    anchors, the CLAUDE.md shim, invisible characters, and the generated routing table.
    Nothing hand-written is ever changed. -Fix regenerates exactly two things: the routing
    table between the markers in the entry point, and the CLAUDE.md shim when AGENTS.md is
    canonical. Run 'Test-OctoAgentDocs -Explain -All' for every rule with its reason.

    Configuration cascades, later wins: agent-docs.rules.json next to this module, then
    .agent-docs.json in the repository, then -ConfigPath, then -Mode. Each rule is
    [severity, options] with severity off | warn | error. The repository file lives in the
    branch under review, so rules listed in 'nonRelaxable' and the mode can be raised there
    but never lowered; -ConfigPath and -Mode come from whoever runs the command and are exempt.

    Severity says how sure the rule is that something is wrong; mode says whether being
    wrong stops the caller. The default mode is logOnly. CI passes -Mode enforce, which
    throws and sets a non-zero exit code when an error-severity finding remains.

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
    $repo = Resolve-OctoAgentDocsRepository -Path $Path
    $repoName = Split-Path -Leaf $repo

    # ------------------------------------------------------------------ config
    $config = Read-OctoAgentDocsBuiltInRuleset
    $builtIn = @{}
    foreach ($id in $script:RuleIds) { $builtIn[$id] = $config.rules[$id][1] }
    $floor = @($config['nonRelaxable'])
    $rank = @{ off = 0; warn = 1; error = 2 }
    if ($ConfigPath -and -not (Test-Path -LiteralPath $ConfigPath)) { throw "-ConfigPath '$ConfigPath' does not exist" }
    $layers = @(@{ path = (Join-Path $repo '.agent-docs.json'); trusted = $false }, @{ path = $ConfigPath; trusted = $true })
    foreach ($l in $layers) {
        if (-not $l.path -or -not (Test-Path -LiteralPath $l.path)) { continue }
        $over = try { Get-Content -LiteralPath $l.path -Raw | ConvertFrom-Json -AsHashtable } catch { $null }
        if ($over -isnot [hashtable]) { Write-Warning "Ruleset '$($l.path)' is not a JSON object - ignored"; continue }
        if ($over.ContainsKey('mode')) {
            if ($script:Modes -notcontains $over.mode) { Write-Warning "Invalid mode '$($over.mode)' in $($l.path) - must be logOnly or enforce. Keeping '$($config.mode)'." }
            elseif (-not $l.trusted -and $over.mode -eq 'logOnly' -and $config.mode -eq 'enforce') { Write-Warning "$($l.path) asks for mode 'logOnly', which is weaker than 'enforce' - a repository may raise the mode but not lower it. Keeping 'enforce'." }
            else { $config.mode = $over.mode }
        }
        foreach ($id in @(if ($over['rules'] -is [hashtable]) { $over['rules'].Keys })) {
            if ($script:RuleIds -notcontains $id) { Write-Warning "Unknown rule '$id' in $($l.path) - ignored"; continue }
            $entry = ConvertTo-OctoAgentDocsRuleEntry $over.rules[$id]
            $current = $config.rules[$id]
            if (-not $entry.valid) { Write-Warning "Invalid severity '$($entry.severity)' for rule '$id' in $($l.path) - must be off, warn or error. Keeping '$($current[0])'."; continue }
            if (-not $l.trusted -and $floor -contains $id) {
                # A floor rule may be raised by the repository, never lowered, and keeps its options.
                if ($rank[$entry.severity] -lt $rank[$current[0]]) { Write-Warning "'$id' is non-relaxable: $($l.path) asks for '$($entry.severity)', keeping '$($current[0])'. Change the org ruleset in octo-tools if this rule is wrong."; continue }
                $config.rules[$id] = @($entry.severity, $current[1]); continue
            }
            $merged = $current[1].Clone()
            foreach ($k in $entry.options.Keys) { $merged[$k] = $entry.options[$k] }
            $config.rules[$id] = @($entry.severity, $merged)
        }
    }
    if ($Mode) { $config.mode = $Mode }
    function Sev { param([string]$Id) $config.rules[$Id][0] }
    function On { param([string]$Id) (Sev $Id) -ne 'off' }
    function Opt {
        # A repository that sets an option to null falls back to the built-in value.
        param([string]$Id, [string]$Name)
        $v = $config.rules[$Id][1][$Name]
        if ($null -eq $v) { $builtIn[$Id][$Name] } else { $v }
    }
    function Tier { param([string]$Id) Get-OctoAgentDocsRuleTier -Config $config -Id $Id }

    # ----------------------------------------------------------------- explain
    function Get-RuleRow {
        param([string]$Id)
        $doc = $config['ruleDocs'][$Id]
        if ($doc -isnot [hashtable]) { $doc = @{} }
        [ordered]@{ rule = $Id; tier = (Tier $Id); severity = (Sev $Id); nonRelaxable = ($floor -contains $Id); options = $config.rules[$Id][1]; why = [string]$doc['why']; fix = [string]$doc['fix'] }
    }
    function Write-RuleRow {
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
    if ($reference) {
        $ids = if ($Rule) { @($Rule) } else { @($script:RuleIds) }
        $unknown = @($ids | Where-Object { $script:RuleIds -notcontains $_ })
        if ($unknown) { throw "Unknown rule(s): $($unknown -join ', '). Known: $($script:RuleIds -join ', ')" }
        $rows = @(foreach ($id in $ids) { Get-RuleRow $id })
        $global:LASTEXITCODE = 0
        if ($Json) { Write-OctoJson -Command 'Test-OctoAgentDocs' -Data ([ordered]@{ repository = $repoName; mode = $config.mode; rules = $rows }); return }
        Write-Host "Agent docs rules for $repoName (mode: $($config.mode)) - effective severity, in the order to fix them" -ForegroundColor Yellow
        foreach ($t in @($rows.tier | Sort-Object -Unique)) {
            Write-Host ''
            Write-Host "  $(Get-OctoAgentDocsTierHeading -Config $config -Tier $t)" -ForegroundColor White
            foreach ($r in @($rows | Where-Object { $_.tier -eq $t })) { Write-RuleRow $r }
        }
        Write-Host ''
        Write-Host '  Overrides: .agent-docs.json in the repository, then -ConfigPath, then -Mode. Non-relaxable rules can be raised there, never lowered.' -ForegroundColor Gray
        return
    }

    # ----------------------------------------------------------------- helpers
    $findings = [System.Collections.Generic.List[object]]::new()
    $written = [System.Collections.Generic.List[string]]::new()
    $textCache = @{}
    function Add-Finding {
        param([string]$RuleId, [string]$File, [string]$Message, [string]$As)
        $sev = if ($As) { $As } else { Sev $RuleId }
        if ($sev -ne 'off') { $findings.Add([ordered]@{ severity = $sev; rule = $RuleId; tier = (Tier $RuleId); file = $File; message = $Message }) }
    }
    function Get-Text { param([string]$P) if (-not $textCache.ContainsKey($P)) { $textCache[$P] = Read-OctoAgentDocsText $P }; $textCache[$P] }
    function Get-Lines {
        # Lines as wc -l counts them: a trailing newline does not add a line.
        param([string]$Content)
        if (-not $Content) { return , @() }
        return , @(($Content.TrimEnd("`n")) -split "`n")
    }
    function Split-GlobList { param([string]$Value) return , @([regex]::Split($Value, ',(?![^{]*\})') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
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
    function Get-Anchors {
        # GitHub-style slugs of the ATX headings: lower case, punctuation dropped, spaces to
        # hyphens, repeated headings suffixed -1, -2. Compared without regard to case, which
        # is how github.com and VS Code resolve a fragment.
        param([string]$Prose)
        $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $seen = @{}
        foreach ($m in [regex]::Matches($Prose, '(?m)^#{1,6}[ \t]+(.*?)[ \t]*$')) {
            $a = [regex]::Replace($m.Groups[1].Value, '\[([^\]]*)\]\([^)]*\)', '$1').ToLowerInvariant() -replace '[^\p{L}\p{N}\p{M} _-]', '' -replace ' ', '-'
            if ($seen.ContainsKey($a)) { $seen[$a]++; [void]$set.Add("$a-$($seen[$a])") } else { $seen[$a] = 0; [void]$set.Add($a) }
        }
        return , $set
    }
    $dirCache = @{}
    function Test-PathExact {
        # Test-Path is case-insensitive on macOS and Windows; GitHub and Linux CI are not.
        param([string]$Root, [string]$Relative)
        $current = $Root
        foreach ($segment in ($Relative -split '[\\/]+' | Where-Object { $_ -and $_ -ne '.' })) {
            if ($segment -eq '..') { $current = Split-Path -Parent $current; continue }
            if (-not $dirCache.ContainsKey($current)) { $dirCache[$current] = @([System.IO.Directory]::EnumerateFileSystemEntries($current) | ForEach-Object { [System.IO.Path]::GetFileName($_) }) }
            if ($dirCache[$current] -cnotcontains $segment) { return $false }
            $current = Join-Path $current $segment
        }
        return $true
    }
    function Test-PointsAtShim {
        param([string]$P)
        if ((Split-Path -Leaf $P) -cne 'CLAUDE.md' -or -not (Test-Path -LiteralPath $P -PathType Leaf)) { return $false }
        return (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $P) 'AGENTS.md')) -and (Test-OctoAgentDocsShimLike (Get-Text $P))
    }

    # ------------------------------------------------------------ entry + shim
    # By exact name: a case-insensitive file system would accept agents.md, Linux CI would not.
    $rootNames = @(Get-ChildItem -LiteralPath $repo -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $hasAgents = $rootNames -ccontains 'AGENTS.md'
    $hasClaude = $rootNames -ccontains 'CLAUDE.md'
    $agentsPath = Join-Path $repo 'AGENTS.md'
    $claudePath = Join-Path $repo 'CLAUDE.md'
    $entryPath = if ($hasAgents) { $agentsPath } elseif ($hasClaude) { $claudePath } else { $null }
    $entryName = if ($entryPath) { Split-Path -Leaf $entryPath } else { '' }
    if (-not $entryPath) { Add-Finding 'required-sections' '' 'Neither AGENTS.md nor CLAUDE.md exists - the repository has no entry point' }

    # The shim verdict is computed whatever severity the rule has: Initialize reads it.
    $shimLines = @(Opt 'shim-valid' 'content')
    $shimVerdict = 'n/a'
    if ($hasAgents) {
        $current = if ($hasClaude) { Get-Text $claudePath } else { $null }
        $shimVerdict = if ($null -eq $current) { 'absent' } elseif ($current.Trim() -ceq ($shimLines -join "`n")) { 'ok' } else { 'differs' }
    }
    # A 'claude.md' is not the shim, and on a case-insensitive file system writing CLAUDE.md
    # would overwrite it - so nothing is written while the two names would collide.
    $claudeAlias = $rootNames | Where-Object { $_ -ieq 'CLAUDE.md' -and $_ -cne 'CLAUDE.md' } | Select-Object -First 1
    if ($hasAgents -and (On 'shim-valid') -and $claudeAlias) {
        Add-Finding 'shim-valid' $claudeAlias "Named '$claudeAlias', not CLAUDE.md - rename it before -Fix can write the shim"
    }
    elseif ($hasAgents -and (On 'shim-valid') -and $shimVerdict -ne 'ok') {
        $safe = -not $hasClaude -or $Force -or (Test-OctoAgentDocsShimLike $current)
        $realContent = 'Has real content while AGENTS.md is canonical - migrate it by hand, or run -Fix -Force to replace it with the shim'
        if ($Fix -and $safe -and $PSCmdlet.ShouldProcess('CLAUDE.md', 'Write the AGENTS.md shim')) { Write-OctoAgentDocsText $claudePath (($shimLines -join "`n") + "`n"); $written.Add('CLAUDE.md') }
        elseif ($Fix -and $safe) { Add-Finding 'shim-valid' 'CLAUDE.md' 'CLAUDE.md shim would be written (run without -WhatIf)' }
        elseif ($safe) { Add-Finding 'shim-valid' 'CLAUDE.md' "$(if ($hasClaude) { 'CLAUDE.md must contain exactly the shim and nothing else' } else { 'CLAUDE.md shim is absent' }) (run with -Fix)" }
        else { Add-Finding 'shim-valid' 'CLAUDE.md' $realContent }
    }
    $briefName = Get-OctoAgentDocsConstant BriefName
    if ((On 'migration-pending') -and (Test-Path -LiteralPath (Join-Path $repo $briefName))) {
        Add-Finding 'migration-pending' $briefName 'Migration brief is still present - follow its steps and delete it in the migration commit'
    }

    # -------------------------------------------------------------------- docs
    $docsDir = Join-Path $repo 'docs'
    $docs = @()
    if (Test-Path -LiteralPath $docsDir) {
        # Ordinal order: the table is committed, so its order must not depend on the machine's culture.
        $docs = @(Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File)
        [array]::Sort($docs, [System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Name, $b.Name) })
    }
    $routes = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $docs) {
        $content = Get-Text $d.FullName
        $fm = Get-Frontmatter $content
        $rel = "docs/$($d.Name)"
        if (On 'frontmatter-present') {
            $maxDesc = Opt 'frontmatter-present' 'maxDescription'
            if (-not $fm['description']) { Add-Finding 'frontmatter-present' $rel "No 'description' in frontmatter" }
            elseif ($fm['description'].Length -gt $maxDesc) { Add-Finding 'frontmatter-present' $rel "description is $($fm['description'].Length) characters, limit $maxDesc - shorten it to one scannable line" }
        }
        $hasRoutes = [bool]$fm['applies_to']
        if ((On 'doc-reachable') -and -not ($hasRoutes -xor ($fm['background'] -match '^(true|yes)$'))) {
            Add-Finding 'doc-reachable' $rel "Needs either 'applies_to' globs or 'background: true', not both and not neither"
        }
        $maxC = Opt 'doc-size' 'maxCharacters'
        if ((On 'doc-size') -and $content.Length -gt $maxC) {
            Add-Finding 'doc-size' $rel "$($content.Length) characters (limit $maxC) - loaded whole whenever this doc is routed. Trim it; split only if it covers more than one topic; or raise the limit in .agent-docs.json"
        }
        if ($hasRoutes) { $routes.Add([ordered]@{ file = $rel; globs = (Split-GlobList $fm['applies_to']); description = [string]$fm['description'] }) }
    }
    $maxDocs = Opt 'docs-count' 'max'
    if ((On 'docs-count') -and $routes.Count -gt $maxDocs) { Add-Finding 'docs-count' 'docs/' "$($routes.Count) routed docs (limit $maxDocs) - the routing table needs grouping" }

    # --------------------------------------------------------------- integrity
    # Integrity rules see every Markdown file an agent might read, dotfolders included,
    # minus scan.ignore from the built-in ruleset. Structural rules stay on the routed set.
    $integrityFiles = @()
    if ((On 'no-invisible-characters') -or (On 'link-hosts')) {
        $ignore = @($config['scan']['ignore'])
        $integrityFiles = @(Get-ChildItem -LiteralPath $repo -Recurse -Force -File -Filter '*.md' -ErrorAction SilentlyContinue |
            Where-Object { $relDir = [System.IO.Path]::GetRelativePath($repo, $_.DirectoryName); -not ($relDir -split '[\\/]' | Where-Object { $ignore -contains $_ }) } | Sort-Object FullName)
    }
    # Unicode Tag characters, zero-width and format characters, and bidirectional overrides:
    # visible to a model, not to a reviewer. U+200D is reported only outside an emoji sequence.
    $invisible = [ordered]@{
        'Unicode Tag character'   = '\uDB40[\uDC00-\uDC7F]'
        'invisible character'     = '[\u00AD\u034F\u061C\u180E\u200B\u200C\u200E\u200F\u2060-\u2064\uFEFF]'
        'stray zero-width joiner' = '(?<![\p{So}\uFE0F\uDC00-\uDFFF])\u200D|\u200D(?![\p{So}\uFE0F\uD800-\uDBFF])'
        'bidirectional override'  = '[\u202A-\u202E\u2066-\u2069]'
    }
    $allowed = @(Opt 'link-hosts' 'allow')
    $ignoreLocal = [bool](Opt 'link-hosts' 'ignoreLocal')
    foreach ($f in $integrityFiles) {
        $content = Get-Text $f.FullName
        $rel = [System.IO.Path]::GetRelativePath($repo, $f.FullName).Replace('\', '/')
        if (On 'no-invisible-characters') {
            foreach ($kind in $invisible.Keys) {
                $hits = [regex]::Matches($content, $invisible[$kind])
                if ($hits.Count -gt 0) { Add-Finding 'no-invisible-characters' "${rel}:$(($content.Substring(0, $hits[0].Index) -split "`n").Count)" "$($hits.Count) $kind(s) - invisible to a reviewer, not to a model. Remove them" }
            }
        }
        if (On 'link-hosts') {
            $seen = @{}
            # The authority ends at '/', '?', '#' or '\' (a browser reads '\' as '/'), so none
            # of them can make an allowlisted name after '@' look like the host.
            foreach ($m in [regex]::Matches($content, '(?i)\bhttps?://([^/?#\\\s<>)"''`\]\[]+)')) {
                $linkHost = (($m.Groups[1].Value -split '@')[-1] -split ':')[0].ToLowerInvariant().TrimEnd('.', ',')
                if (-not $linkHost -or $seen.ContainsKey($linkHost)) { continue }
                $seen[$linkHost] = $true
                $local = -not $linkHost.Contains('.') -or $linkHost -match '\.(local|localhost|internal|invalid)$' -or $linkHost -match '^(127|10|169\.254|192\.168|172\.(1[6-9]|2\d|3[01]))\.\d'
                if ($ignoreLocal -and $local) { continue }
                if (-not ($allowed | Where-Object { $linkHost -eq $_ -or $linkHost.EndsWith(".$_", [System.StringComparison]::OrdinalIgnoreCase) })) { Add-Finding 'link-hosts' $rel "Link to '$linkHost' is not on the allowlist" }
            }
        }
    }

    # -------------------------------------------- references, line length (routed set)
    $checkFiles = @()
    if ($entryPath) { $checkFiles += $entryPath }
    $readme = $rootNames | Where-Object { $_ -ieq 'README.md' } | Select-Object -First 1
    if ($readme) { $checkFiles += Join-Path $repo $readme }
    $checkFiles += @($docs | ForEach-Object { $_.FullName })
    $siblingPattern = Opt 'reference-resolves' 'siblingRepoPattern'
    $siblingRoot = if ($Global:ROOTPATH) { $Global:ROOTPATH } else { Split-Path -Parent $repo }
    $anchorCache = @{}
    function Get-ShimAdvice { param([string]$Ref) "points at a shim - reference '$($Ref -replace 'CLAUDE\.md$', 'AGENTS.md')' instead, since an agent reading the shim gets only '@AGENTS.md'" }
    function Test-Reference {
        # One resolver for links and backtick paths: exists, exact case, shim, anchor.
        param([string]$Rel, [string]$Source, [string]$Target, [string]$Kind)
        $parts = $Target -split '#', 2
        $filePart = $parts[0]
        $anchor = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $resolved = if (-not $filePart) { $Source } elseif ($filePart.StartsWith('/')) { Join-Path $repo $filePart.TrimStart('/') } else { Join-Path (Split-Path -Parent $Source) $filePart }
        if (-not (Test-Path -LiteralPath $resolved)) { Add-Finding 'reference-resolves' $Rel "$Kind not found: $Target"; return }
        $relToRepo = [System.IO.Path]::GetRelativePath($repo, [System.IO.Path]::GetFullPath($resolved))
        if ($filePart -and -not $relToRepo.StartsWith('..') -and -not (Test-PathExact $repo $relToRepo)) { Add-Finding 'reference-resolves' $Rel "$Kind differs in case from the file on disk: $Target"; return }
        if ($filePart -and (Test-PointsAtShim $resolved)) { Add-Finding 'reference-to-shim' $Rel "$Kind $(Get-ShimAdvice $filePart)" }
        if ($anchor -and $resolved -like '*.md') {
            $full = (Resolve-Path -LiteralPath $resolved).Path
            if (-not $anchorCache.ContainsKey($full)) { $anchorCache[$full] = Get-Anchors (ConvertTo-OctoAgentDocsProse (Get-Text $full)) }
            if (-not $anchorCache[$full].Contains($anchor)) { Add-Finding 'reference-resolves' $Rel "Anchor not found: $Target" }
        }
    }
    $startMarker = Get-OctoAgentDocsConstant RoutingStart
    $endMarker = Get-OctoAgentDocsConstant RoutingEnd
    foreach ($f in $checkFiles) {
        $content = Get-Text $f
        $rel = [System.IO.Path]::GetRelativePath($repo, $f).Replace('\', '/')
        $prose = ConvertTo-OctoAgentDocsProse $content
        if ($f -eq $entryPath) {
            # The generated table is derived, not written: a stale row naming a doc that is
            # gone is fixed by -Fix, not by a reference finding that would outlive the fix.
            $si = Find-OctoAgentDocsMarker -Text $prose -Marker $startMarker
            $ei = Find-OctoAgentDocsMarker -Text $prose -Marker $endMarker
            if ($si -ge 0 -and $ei -gt $si) { $prose = $prose.Substring(0, $si) + $prose.Substring($ei) }
        }
        if ((On 'reference-resolves') -or (On 'reference-to-shim')) {
            # Inline links, with code spans removed first: `[label](path.md)` is quoted syntax.
            foreach ($m in [regex]::Matches(($prose -replace '`[^`\n]*`', ''), '\]\(\s*<?([^)\s>]+)>?')) {
                $target = [System.Uri]::UnescapeDataString($m.Groups[1].Value)
                if ($target -match '^([A-Za-z][A-Za-z0-9+.-]*:|//)') { continue }   # URL
                Test-Reference $rel $f $target 'Link target'
            }
            # Paths in backticks: `docs/topic.md`. A bare `CLAUDE.md` means this repository's own.
            foreach ($m in [regex]::Matches($prose, '`([^`\s]+\.md)`')) {
                $ref = $m.Groups[1].Value
                if ($ref -ceq 'CLAUDE.md') { if (Test-PointsAtShim $claudePath) { Add-Finding 'reference-to-shim' $rel "``CLAUDE.md`` $(Get-ShimAdvice $ref)" }; continue }
                if ($ref -notmatch '/' -or $ref -match '^(\.\.|~|/|[A-Za-z]:)' -or $ref -match '[*?\[{<>]') { continue }   # a phrase, an outside path, or a pattern
                if ($siblingPattern -and $ref -match $siblingPattern) {
                    if (Test-PointsAtShim (Join-Path $siblingRoot $ref)) { Add-Finding 'reference-to-shim' $rel "``$ref`` $(Get-ShimAdvice $ref)" }
                    continue
                }
                Test-Reference $rel $agentsPath $ref 'Referenced file'
            }
        }
    }

    # --------------------------------------------- entry point: budgets, sections, routing
    if ($entryPath) {
        $entry = Get-Text $entryPath
        if (On 'required-sections') {
            # Level-2 headings outside fenced code, matched without regard to case. Nothing is
            # ever filled in: a missing section is reported, not written.
            $headings = @([regex]::Matches((ConvertTo-OctoAgentDocsProse $entry), '(?m)^##[ \t]+(.*?)[ \t]*$') | ForEach-Object { $_.Groups[1].Value })
            $missing = @(foreach ($want in @(Opt 'required-sections' 'sections')) { if ($headings -notcontains $want) { "'## $want'" } })
            if ($missing.Count -eq 1) { Add-Finding 'required-sections' $entryName "Missing section $($missing[0]) - every repo's entry point carries it" }
            elseif ($missing.Count -gt 1) { Add-Finding 'required-sections' $entryName "Missing sections $($missing -join ', ') - every repo's entry point carries them" }
        }
        if (On 'routing-current') {
            $withDesc = [bool](Opt 'routing-current' 'includeDescriptions')
            $table = if ($withDesc) { @('| When you change | Read first | What it covers |', '|---|---|---|') } else { @('| When you change | Read first |', '|---|---|') }
            foreach ($r in $routes) {
                $globs = @($r.globs | ForEach-Object { "``$_``" }) -join ', '
                $table += if ($withDesc) { "| $globs | ``$($r.file)`` | $($r.description -replace '\|', '\|') |" } else { "| $globs | ``$($r.file)`` |" }
            }
            $generated = $table -join "`n"
            $si = Find-OctoAgentDocsMarker -Text $entry -Marker $startMarker
            $ei = Find-OctoAgentDocsMarker -Text $entry -Marker $endMarker
            if ($si -lt 0 -or $ei -lt $si) { Add-Finding 'routing-current' $entryName "Add $startMarker and $endMarker around the routing table" }
            elseif ($entry.Substring($si + $startMarker.Length, $ei - $si - $startMarker.Length) -cne "`n$generated`n") {
                if ($Fix -and $PSCmdlet.ShouldProcess($entryName, 'Regenerate the routing table')) {
                    # Spliced into the raw text with the file's own line endings.
                    $raw = [System.IO.File]::ReadAllText($entryPath)
                    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
                    $rsi = Find-OctoAgentDocsMarker -Text $raw -Marker $startMarker; $rei = Find-OctoAgentDocsMarker -Text $raw -Marker $endMarker
                    $newRaw = $raw.Substring(0, $rsi + $startMarker.Length) + $eol + ($generated -replace "`n", $eol) + $eol + $raw.Substring($rei)
                    Write-OctoAgentDocsText $entryPath $newRaw
                    $written.Add($entryName)
                    $textCache[$entryPath] = $newRaw.Replace("`r`n", "`n")
                }
                elseif ($Fix) { Add-Finding 'routing-current' $entryName 'Generated routing table would be rewritten (run without -WhatIf)' }
                else { Add-Finding 'routing-current' $entryName 'Generated routing table is out of date (run with -Fix)' }
            }
        }

        # Budgets are measured on the text left behind, so a -Fix run and the next run agree.
        $entry = Get-Text $entryPath
        $entryLines = (Get-Lines $entry).Count
        $maxL = Opt 'entry-point-lines' 'max'
        if ((On 'entry-point-lines') -and $entryLines -gt $maxL) { Add-Finding 'entry-point-lines' $entryName "$entryLines lines over the budget of $maxL - this file loads in every session. Move detail into docs/ and route it with applies_to" }
        $maxC = Opt 'entry-point-characters' 'max'; $warnAt = Opt 'entry-point-characters' 'warnAt'
        if (On 'entry-point-characters') {
            if ($entry.Length -gt $maxC) { Add-Finding 'entry-point-characters' $entryName "$($entry.Length) characters over the budget of $maxC - move detail into docs/, or shorten the longest lines" }
            elseif ($warnAt -gt 0 -and $entry.Length -gt $warnAt) { Add-Finding 'entry-point-characters' $entryName "$($entry.Length) characters, past the $warnAt target but under the $maxC limit - worth trimming before it grows" 'warn' }
        }
        if (On 'line-length') {
            $maxLine = Opt 'line-length' 'max'; $maxTable = Opt 'line-length' 'tables'; $cap = Opt 'line-length' 'maxReported'
            $lines = Get-Lines (ConvertTo-OctoAgentDocsProse $entry -KeepLineNumbers)
            $hits = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                $isTable = $line.TrimStart().StartsWith('|')
                $limit = if ($isTable) { $maxTable } else { $maxLine }
                # A line without any whitespace (a URL, a hash) cannot be wrapped and is exempt.
                if ($line.Length -le $limit -or $line -match '^\s*(```|~~~)' -or $line.Trim() -notmatch '\s') { continue }
                $hits++
                if ($hits -le $cap) { Add-Finding 'line-length' "${entryName}:$($i + 1)" "$(if ($isTable) { "table row is $($line.Length) characters, limit $limit - shorten the globs or the description in the doc's frontmatter" } else { "line is $($line.Length) characters, limit $limit" })" }
            }
            if ($hits -gt $cap) { Add-Finding 'line-length' $entryName "$($hits - $cap) further over-length lines not listed" }
        }
    }

    # ------------------------------------------------------------------ output
    $errors = @($findings | Where-Object { $_.severity -eq 'error' })
    $warnings = @($findings | Where-Object { $_.severity -eq 'warn' })
    $fired = @($findings.rule | Sort-Object -Unique)
    # Where to start: the cause behind most of the findings, at most two sentences.
    $causes = @()
    $pathArg = Format-OctoAgentDocsArgument -Value $Path
    if ($fired -contains 'no-invisible-characters') { $causes += 'a file carries characters a reviewer cannot see. Remove them before anything else.' }
    if ($fired -contains 'migration-pending') { $causes += 'the migration brief is still present - follow its steps and delete it in the migration commit.' }
    elseif (-not $hasAgents -and $hasClaude -and ($fired | Where-Object { $_ -in 'required-sections', 'entry-point-characters', 'entry-point-lines' })) { $causes += "this repository has not migrated to AGENTS.md, and the entry-point findings follow from that. Initialize-OctoAgentDocs -Path $pathArg writes the migration brief." }
    elseif (-not $entryPath) { $causes += "this repository has no agent instructions yet. Initialize-OctoAgentDocs -Path $pathArg writes the entry point and the shim." }
    if (-not $causes -and $findings.Count -gt 0 -and -not ($findings | Where-Object { $_.tier -lt 4 })) { $causes += 'only budgets are left. Move content into routed docs rather than trimming it in place.' }
    $startHere = if ($causes.Count -eq 0) { $null } elseif ($causes.Count -eq 1) { $causes[0] } else { "$($causes[0]) After that: $($causes[1])" }

    if ($Json) {
        Write-OctoJson -Command 'Test-OctoAgentDocs' -Data ([ordered]@{
            repository   = $repoName
            entryPoint   = $entryName
            canonical    = if ($hasAgents) { 'AGENTS.md' } else { 'CLAUDE.md' }
            shim         = $shimVerdict
            mode         = $config.mode
            filesWritten = @($written)
            routes       = @($routes)
            findings     = @($findings)
            startHere    = $startHere
            explanations = @(if ($Explain) { @(foreach ($id in $fired) { Get-RuleRow $id }) | Sort-Object -Stable { $_.tier }, { $_.rule } })
            ruleSet      = $config.rules
            summary      = [ordered]@{ errors = $errors.Count; warnings = $warnings.Count; success = ($errors.Count -eq 0) }
        })
    }
    else {
        Write-Host "Agent docs check: $repoName (entry point: $entryName, mode: $($config.mode))" -ForegroundColor Yellow
        if ($findings.Count -eq 0) { Write-Host "  clean - $($routes.Count) routed doc$(if ($routes.Count -ne 1) { 's' })" -ForegroundColor Green }
        else {
            $fileCount = @($findings | ForEach-Object { ($_.file -split ':')[0] } | Where-Object { $_ } | Sort-Object -Unique).Count
            Write-Host "  $($errors.Count) error(s), $($warnings.Count) warning(s) in $fileCount file(s)" -ForegroundColor Gray
            if ($startHere) { Write-Host "  Start here: $startHere" -ForegroundColor Cyan }
            # By tier, errors before warnings, then by file; detection order within a file.
            foreach ($t in @($findings.tier | Sort-Object -Unique)) {
                Write-Host ''
                Write-Host "  $(Get-OctoAgentDocsTierHeading -Config $config -Tier $t)" -ForegroundColor White
                $group = @($findings | Where-Object { $_.tier -eq $t } | Sort-Object -Stable { $_.severity -ne 'error' }, { ($_.file -split ':')[0] })
                $width = ($group.rule | Measure-Object -Maximum -Property Length).Maximum
                foreach ($x in $group) {
                    $colour = if ($x.severity -eq 'error') { 'Red' } else { 'DarkYellow' }
                    Write-Host "     [$($x.severity)]".PadRight(13) -ForegroundColor $colour -NoNewline
                    Write-Host $x.rule.PadRight($width + 2) -ForegroundColor Cyan -NoNewline
                    Write-Host "$(if ($x.file) { "$($x.file): " })$($x.message)" -ForegroundColor $colour
                }
                if ($Explain) { foreach ($id in @($group.rule | Sort-Object -Unique)) { Write-RuleRow (Get-RuleRow $id) } }
            }
            Write-Host ''
        }
        if ($written.Count -gt 0) { Write-Host "  rewrote $($written -join ', ')" -ForegroundColor Cyan }
        elseif ($Fix -and -not $WhatIfPreference) { Write-Host '  nothing to rewrite' -ForegroundColor Cyan }
        if ($findings.Count -eq 0) {
            Write-Host '  0 error(s), 0 warning(s)' -ForegroundColor Gray
            if ($Explain) { Write-Host '  nothing to explain - full rule reference: Test-OctoAgentDocs -Explain -All' -ForegroundColor Gray }
        }
        elseif (-not $Explain) { Write-Host '  add -Explain for why and how to fix, or -Explain <rule> for one rule' -ForegroundColor Gray }
    }

    # -Explain is a person asking why; the gate is for pipelines.
    $global:LASTEXITCODE = 0
    if ($config.mode -eq 'enforce' -and $errors.Count -gt 0 -and -not $Explain) {
        $global:LASTEXITCODE = 1
        throw "Test-OctoAgentDocs: $($errors.Count) error-severity finding(s) in $repoName"
    }
}

Export-ModuleMember -Function @('Test-OctoAgentDocs')
