$script:AgentDocsRuleIds = @(
    'entry-point-lines', 'entry-point-characters', 'line-length', 'doc-size',
    'frontmatter-present', 'doc-reachable', 'reference-resolves',
    'routing-current', 'docs-count', 'shim-valid', 'required-sections',
    'no-invisible-characters', 'link-hosts'
)
$script:AgentDocsSeverities = @('off', 'warn', 'error')
$script:AgentDocsModes = @('logOnly', 'enforce')

function Test-OctoAgentDocs {
    <#
    .SYNOPSIS
    Checks a repository's agent instruction files and regenerates the parts that are derived.

    .DESCRIPTION
    One repo, two jobs.

    CHECKS - hand-written content stays hand-written; these only verify it:
      entry-point-lines       always-loaded entry point stays within its line budget
      entry-point-characters  and within its character budget, so a few very long lines
                              cannot smuggle a large file past the line count
      line-length             no single line is too long to review in a diff
      doc-size                docs/ files past the character threshold are flagged for a human
                              to trim or split. Characters, not lines: lines measure how the
                              text is wrapped, characters measure how much of it there is
      frontmatter-present     every docs/*.md carries a description, within its length limit
      doc-reachable           every doc is either routed (applies_to) or marked background
      reference-resolves      every relative link and in-file anchor resolves
      docs-count              the number of routed docs stays reviewable
      shim-valid              when AGENTS.md is canonical, CLAUDE.md is exactly the shim
      routing-current         the generated routing block matches the docs' frontmatter
      required-sections       the entry point carries the sections every repo must have,
                              so an agent finds the same headings in the same places.
                              Heading text is matched case-insensitively, at level 2 only
      no-invisible-characters instruction files carry no Unicode Tag characters, zero-width
                              characters or bidirectional overrides - the carriers for text
                              a reviewer cannot see but a model still reads. Scanned over
                              EVERY *.md in the repository, not only the routed ones
      link-hosts              off by default; when on, every external link host must be
                              on the allowlist

    GENERATES - from structure only, never by summarizing code:
      the routing table between
          <!-- >>> generated: routing -->  ...  <!-- <<< end generated: routing -->
      built from each docs/*.md 'applies_to' field, and the CLAUDE.md shim when
      AGENTS.md is canonical.

    CONFIGURATION cascades, later wins:
      1. agent-docs.rules.json next to this module (org defaults)
      2. .agent-docs.json in the repository being checked
      3. -ConfigPath
      4. -Mode
    Each rule is [ severity, options ] with severity off | warn | error, the same shape
    ESLint uses. Repository overrides are merged per option, so a repo can raise one
    threshold without restating the rule. An invalid severity or mode is rejected with a
    warning and the stricter built-in value is kept, so a typo cannot quietly disable a
    gate.

    Layer 2 is the only ATTACKER-EDITABLE layer: .agent-docs.json is in the branch under
    review, so the pull request carrying a payload can carry the opt-out with it. Rules
    listed in 'nonRelaxable' in the org ruleset may therefore be raised by a repository
    but never lowered by one. -ConfigPath and -Mode are exempt - they come from whoever
    runs the command, not from the branch.

    SCANNING has two surfaces. Structural rules see the routed set (entry point, README,
    docs/*.md) because they describe what gets routed. Integrity rules see every *.md in
    the repository, dotfolders included, minus scan.ignore - a nested AGENTS.md is read
    nearest-wins without appearing in any routing table, and .claude/ and
    .github/instructions/ are loaded by tool convention.

    Sizes are counted in CHARACTERS, not bytes: bytes vary with encoding (umlauts cost
    two, em dashes three) so a byte budget is not something a human can verify by looking
    at the text. Line counts match `wc -l`.

    SEVERITY AND MODE ARE DIFFERENT DIALS, and keeping them apart is what makes the
    rollout work:

      severity  how sure we are the finding is WRONG.
                  error - decidable: a character either is U+200B or it is not
                  warn  - a budget or a policy threshold, where the right number is a
                          judgement (entry point length, doc size, doc count)
                  off   - not decidable, so it cannot be a gate at all (link-hosts)
      mode      whether being wrong STOPS THE CALLER.

    The temptation is to soften a security rule to 'warn' so it cannot break a build.
    Don't: that lies about confidence to buy a property logOnly already gives for free,
    and a warning is a thing people scroll past. A rule that is not decidable belongs at
    'off', not at 'warn'.

    Mode is a property of the CALLER, not of the repository. A person who typed the
    command has already asked to be told; throwing at them adds a stack trace over the
    report they were reading. A pipeline step reads nothing but the exit code, so for CI
    the exit code is the entire product. Hence the org default is logOnly and CI passes
    -Mode enforce (or a repository opts up once it is clean).

    Rollout follows the LogOnly -> Enforce pattern used elsewhere in the estate. To flip
    the org default to enforce: get every repository clean at error severity, change
    'mode' in agent-docs.rules.json, then drop the now-redundant 'mode' from each
    repository's own file. After the flip a repository can no longer opt down - a repo
    added later that is not migrated yet is unblocked with -Mode logOnly in its pipeline,
    which is reviewed code outside the contributor's branch rather than a line in it.

    .PARAMETER Path
    Repository to check: a path, or a repository name resolved under $Global:ROOTPATH
    when the path itself does not exist. Defaults to the current directory.

    .PARAMETER Fix
    Rewrite the generated regions instead of only reporting that they are stale.

    .PARAMETER Force
    With -Fix, allow the CLAUDE.md shim to replace a CLAUDE.md that still has real
    content. Without it, such a file is reported and left alone.

    .PARAMETER Mode
    Override the configured mode. enforce throws and sets a non-zero exit code when any
    error-severity finding remains. Warnings never fail. This is the one place the mode
    may be RELAXED: it comes from whoever runs the command, not from the branch being
    checked, so it is the escape hatch for a repository that is not migrated yet.

    .PARAMETER ConfigPath
    An additional ruleset file, merged after the repository's own.

    .PARAMETER Json
    Emit the standard octo-tools JSON envelope instead of human output.

    .EXAMPLE
    Test-OctoAgentDocs

    .EXAMPLE
    Test-OctoAgentDocs -Path octo-communication-operator -Fix

    .EXAMPLE
    Test-OctoAgentDocs -Mode enforce -Json
    #>

    [CmdletBinding()]
    param(
        [string]$Path = ".",
        [switch]$Fix,
        [switch]$Force,
        [ValidateSet('logOnly', 'enforce')]
        [string]$Mode,
        [string]$ConfigPath,
        [switch]$Json
    )

    $ErrorActionPreference = 'Stop'

    # Resolve -Path as given; if that misses, fall back to a repository name under
    # $Global:ROOTPATH, the way the other octo-tools cmdlets address repositories.
    # The Octo profile starts you at the monorepo root, so a bare repo name is the
    # form people actually type.
    $repo = try { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { $null }
    if (-not $repo -and $Global:ROOTPATH) {
        $underRoot = Join-Path $Global:ROOTPATH $Path
        $repo = try { (Resolve-Path -LiteralPath $underRoot -ErrorAction Stop).Path } catch { $null }
    }
    if (-not $repo) {
        $tried = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
        $msg = "Path '$Path' does not exist (resolved to '$tried')"
        if ($Global:ROOTPATH) { $msg += " and not under ROOTPATH '$Global:ROOTPATH'" }
        throw $msg
    }

    # ------------------------------------------------------------------ config
    # A broken built-in ruleset is a broken install and throws. A broken repository
    # override is the user's file: warn, skip it, carry on with what we have.
    function Read-RuleFile {
        param([string]$P, [switch]$Required)
        if (-not (Test-Path -LiteralPath $P)) {
            if ($Required) { throw "Built-in ruleset missing at $P" }
            return $null
        }
        try { return (Get-Content -LiteralPath $P -Raw | ConvertFrom-Json -AsHashtable) }
        catch {
            $msg = "Ruleset '$P' is not valid JSON: $($_.Exception.Message)"
            if ($Required) { throw $msg }
            Write-Warning "$msg - ignored"
            return $null
        }
    }

    # The ruleset schema allows both "rule": "warn" and "rule": ["warn", {...}].
    # Everything downstream indexes [0] and [1], and indexing a STRING yields a
    # character ("warn"[0] is 'w'), so normalise to the array form once, here.
    function ConvertTo-RuleArray {
        param($Raw)
        if ($Raw -is [string]) { return , @($Raw, @{}) }
        $sev = if ($Raw.Count -ge 1) { $Raw[0] } else { $null }
        $opt = if ($Raw.Count -gt 1 -and $Raw[1] -is [hashtable]) { $Raw[1] } else { @{} }
        return , @($sev, $opt)
    }

    $defaultsPath = Join-Path $PSScriptRoot 'agent-docs.rules.json'
    $config = Read-RuleFile $defaultsPath -Required
    if (-not $config.rules) { throw "Built-in ruleset at $defaultsPath has no 'rules' section" }

    foreach ($id in $script:AgentDocsRuleIds) {
        if (-not $config.rules.ContainsKey($id)) {
            Write-Warning "Built-in ruleset has no '$id' - treated as off"
            $config.rules[$id] = @('off', @{})
        }
        else { $config.rules[$id] = ConvertTo-RuleArray $config.rules[$id] }
    }

    # Accepts ["warn", {...}], ["warn"] or "warn"; returns $null when the severity is
    # not one of off|warn|error so the caller can keep the stricter built-in value.
    function ConvertTo-RuleEntry {
        param($Raw, [string]$Id, [string]$Source)
        $severity = if ($Raw -is [string]) { $Raw } elseif ($Raw.Count -ge 1) { $Raw[0] } else { $null }
        $options = if ($Raw -isnot [string] -and $Raw.Count -gt 1 -and $Raw[1] -is [hashtable]) { $Raw[1] } else { @{} }
        $match = $script:AgentDocsSeverities | Where-Object { $_ -eq $severity }
        if (-not $match) {
            Write-Warning "Invalid severity '$severity' for rule '$Id' in $Source - must be off, warn or error. Keeping the built-in severity."
            return $null
        }
        return @{ severity = $match; options = $options }
    }

    # Built-in severities are validated BEFORE any override is applied: the floor below
    # compares against the built-in value, and a comparison against a typo is not a floor.
    foreach ($id in $script:AgentDocsRuleIds) {
        $sev = $config.rules[$id][0]
        if ($script:AgentDocsSeverities -notcontains $sev) {
            Write-Warning "Invalid severity '$sev' for rule '$id' in the built-in ruleset - treated as error"
            $opts = if ($config.rules[$id].Count -gt 1 -and $config.rules[$id][1] -is [hashtable]) { $config.rules[$id][1] } else { @{} }
            $config.rules[$id] = @('error', $opts)
        }
    }
    if (-not ($script:AgentDocsModes -contains $config.mode)) { $config.mode = 'logOnly' }

    # The trust boundary. .agent-docs.json lives IN the repository, so anyone who can
    # open a pull request can edit it - including the pull request that carries the thing
    # a rule is meant to catch. Rules named in 'nonRelaxable' may therefore be raised by
    # the repository but never lowered by it, and the same holds for the mode. -ConfigPath
    # and -Mode are exempt: they come from whoever RUNS the tool, not from the branch.
    # Migration therefore works by a repository opting UP to enforce as it becomes clean,
    # not by the org opting down for it.
    $floor = @(if ($config['nonRelaxable'] -is [System.Collections.IEnumerable] -and $config['nonRelaxable'] -isnot [string]) { $config['nonRelaxable'] } else { @() })
    foreach ($id in $floor) {
        if ($script:AgentDocsRuleIds -notcontains $id) {
            Write-Warning "'nonRelaxable' names '$id', which is not a rule - it protects nothing. Fix the org ruleset."
        }
    }
    $severityRank = @{ off = 0; warn = 1; error = 2 }
    $modeRank = @{ logOnly = 0; enforce = 1 }

    $layers = @(
        @{ path = (Join-Path $repo '.agent-docs.json'); trusted = $false }
        @{ path = $ConfigPath; trusted = $true }
    )
    foreach ($l in $layers) {
        $layer = $l.path
        if ([string]::IsNullOrWhiteSpace($layer)) { continue }
        $over = Read-RuleFile $layer
        if (-not $over) { continue }

        if ($over.ContainsKey('mode')) {
            $modeMatch = $script:AgentDocsModes | Where-Object { $_ -eq $over.mode }
            if (-not $modeMatch) {
                Write-Warning "Invalid mode '$($over.mode)' in $layer - must be logOnly or enforce. Keeping '$($config.mode)'."
            }
            elseif (-not $l.trusted -and $modeRank[$modeMatch] -lt $modeRank[$config.mode]) {
                Write-Warning "$layer asks for mode '$modeMatch', which is weaker than '$($config.mode)' - a repository may raise the mode but not lower it. Keeping '$($config.mode)'."
            }
            else { $config.mode = $modeMatch }
        }

        if ($over.ContainsKey('rules')) {
            foreach ($id in $over.rules.Keys) {
                if ($script:AgentDocsRuleIds -notcontains $id) {
                    Write-Warning "Unknown rule '$id' in $layer - ignored"
                    continue
                }
                $entry = ConvertTo-RuleEntry $over.rules[$id] $id $layer

                if (-not $l.trusted -and $floor -contains $id) {
                    # An unreadable severity has already been warned about; treat it as an
                    # attempt to relax rather than silently reporting it as 'off'.
                    if (-not $entry) { continue }
                    if ($severityRank[$entry.severity] -lt $severityRank[$config.rules[$id][0]]) {
                        Write-Warning "'$id' is non-relaxable: $layer asks for '$($entry.severity)', keeping '$($config.rules[$id][0])'. Change the org ruleset in octo-tools if this rule is wrong."
                        continue
                    }
                    # Raising is allowed, but the repository supplies no options for a
                    # floor rule - otherwise the severity is locked and the thresholds
                    # underneath it are not, which is the same hole with an extra step.
                    $config.rules[$id] = @($entry.severity, $config.rules[$id][1])
                    continue
                }
                $severity = if ($entry) { $entry.severity } else { $config.rules[$id][0] }
                $newOptions = if ($entry) { $entry.options } else { @{} }

                $merged = @{}
                if ($config.rules[$id].Count -gt 1 -and $config.rules[$id][1]) {
                    foreach ($k in $config.rules[$id][1].Keys) { $merged[$k] = $config.rules[$id][1][$k] }
                }
                foreach ($k in $newOptions.Keys) { $merged[$k] = $newOptions[$k] }
                $config.rules[$id] = @($severity, $merged)
            }
        }
    }

    # An override layer can only have supplied a validated severity, so the built-ins are
    # the only thing that needed checking - but the mode is re-checked because -Mode wins
    # over everything and is validated by ValidateSet, not here.
    if ($Mode) { $config.mode = $Mode }

    function Get-Severity { param([string]$Id) $config.rules[$Id][0] }
    function Get-Opt {
        param([string]$Id, [string]$Name, $Default = $null)
        $o = if ($config.rules[$Id].Count -gt 1) { $config.rules[$Id][1] } else { $null }
        if ($o -and $o.ContainsKey($Name)) { return $o[$Name] }
        return $Default
    }
    function Test-RuleOn { param([string]$Id) (Get-Severity $Id) -ne 'off' }

    # ---------------------------------------------------------------- findings
    $findings = [System.Collections.Generic.List[object]]::new()
    $written = [System.Collections.Generic.List[string]]::new()

    function Add-Finding {
        param([string]$Rule, [string]$File, [string]$Message, [string]$As)
        $sev = if ($As) { $As } else { Get-Severity $Rule }
        if ($sev -eq 'off') { return }
        $findings.Add([ordered]@{ severity = $sev; rule = $Rule; file = $File; message = $Message })
    }

    function Read-Text { param([string]$P) [System.IO.File]::ReadAllText($P) }
    function Write-Text {
        param([string]$P, [string]$Content)
        [System.IO.File]::WriteAllText($P, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    # Lines as `wc -l` counts them: a trailing newline does not add a line.
    function Get-Lines {
        param([string]$Content)
        if ([string]::IsNullOrEmpty($Content)) { return , @() }
        $lines = $Content -split "`r?`n"
        # A trailing newline leaves a final empty element; drop it so counts match wc -l.
        # The count guard matters: $a[0..($a.Count-2)] on a ONE-element array is
        # $a[0..-1], and -1 means the last index, so it returns two elements.
        if ($lines.Count -gt 1 -and $lines[-1] -eq '') { $lines = $lines[0..($lines.Count - 2)] }
        elseif ($lines.Count -eq 1 -and $lines[0] -eq '') { $lines = @() }
        return , $lines
    }

    # Commas separate globs, but a comma inside braces belongs to a brace expansion
    # (src/**/*.{cs,csproj}), which both Claude Code paths: and Copilot applyTo: support.
    function Split-GlobList {
        param([string]$Value)
        $out = [System.Collections.Generic.List[string]]::new()
        $depth = 0
        $buffer = [System.Text.StringBuilder]::new()
        foreach ($ch in $Value.ToCharArray()) {
            switch ($ch) {
                '{' { $depth++; [void]$buffer.Append($ch) }
                '}' { if ($depth -gt 0) { $depth-- }; [void]$buffer.Append($ch) }
                ',' {
                    if ($depth -eq 0) { $out.Add($buffer.ToString().Trim()); [void]$buffer.Clear() }
                    else { [void]$buffer.Append($ch) }
                }
                default { [void]$buffer.Append($ch) }
            }
        }
        $out.Add($buffer.ToString().Trim())
        return , @($out | Where-Object { $_ })
    }

    function Get-Frontmatter {
        param([string]$Content)
        $map = @{}
        $lines = $Content -split "`r?`n"
        if ($lines.Count -eq 0 -or $lines[0].Trim() -ne '---') { return $map }
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') { break }
            if ($lines[$i] -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() }
        }
        return $map
    }

    # GitHub keeps Unicode letters in anchors ("Größe" -> #größe) and maps EACH space
    # to a hyphen, so runs of whitespace must not be collapsed.
    function Get-Anchors {
        param([string]$Content)
        $set = [System.Collections.Generic.HashSet[string]]::new()
        $seen = @{}
        $inCode = $false
        foreach ($line in ($Content -split "`r?`n")) {
            # A '# ' inside a fenced block is shell or C# syntax, not a heading.
            if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
            if ($inCode) { continue }
            if ($line -match '^#{1,6}\s+(.*)$') {
                # A link in a heading contributes its LABEL only: "## See [docs](x)" -> #see-docs.
                $text = [regex]::Replace($Matches[1], '\[([^\]]*)\]\([^)]*\)', '$1')
                # GitHub strips markup but keeps punctuation that is part of a word, so
                # '## applies_to' becomes #applies_to while '## _italic_' becomes #italic.
                # Only underscore runs that sit at a word edge are emphasis markers.
                $text = $text -replace '(?<![\p{L}\p{N}\p{M}])_+|_+(?![\p{L}\p{N}\p{M}])', ''
                $a = $text.ToLowerInvariant() -replace '[`*]', ''
                $a = $a -replace '[^\p{L}\p{N}\p{M} _\-]', ''
                $a = ($a.Trim() -replace ' ', '-')
                # Repeated headings: GitHub disambiguates with -1, -2, ... and a link to
                # #configuration-1 is a WORKING link, so it must not be reported as broken.
                if ($seen.ContainsKey($a)) { $seen[$a]++; [void]$set.Add("$a-$($seen[$a])") }
                else { $seen[$a] = 0; [void]$set.Add($a) }
            }
        }
        return $set
    }

    # A CLAUDE.md is safe to replace with the shim when it holds nothing but HTML
    # comments and at most one @import line. Anything else is somebody's work.
    function Test-IsShimLike {
        param([string]$Content)
        $meaningful = @((Get-Lines $Content) | Where-Object { $_.Trim() -ne '' -and $_.Trim() -notmatch '^<!--.*-->$' })
        if ($meaningful.Count -eq 0) { return $true }
        return ($meaningful.Count -eq 1 -and $meaningful[0].Trim() -match '^@\S+$')
    }

    # ----------------------------------------------------------- entry + shim
    $agentsPath = Join-Path $repo 'AGENTS.md'
    $claudePath = Join-Path $repo 'CLAUDE.md'
    $hasAgents = Test-Path -LiteralPath $agentsPath
    $hasClaude = Test-Path -LiteralPath $claudePath

    if (-not $hasAgents -and -not $hasClaude) {
        Add-Finding 'entry-point-lines' '' 'Neither AGENTS.md nor CLAUDE.md exists' 'error'
        $entryPath = $null
    }
    else { $entryPath = if ($hasAgents) { $agentsPath } else { $claudePath } }
    $entryName = if ($entryPath) { Split-Path -Leaf $entryPath } else { '' }

    if ($hasAgents -and (Test-RuleOn 'shim-valid')) {
        $expected = ((Get-Opt 'shim-valid' 'content' @('@AGENTS.md')) -join "`n")
        # A Windows checkout with core.autocrlf reads the two-line shim as CRLF; the
        # template is LF, so both are normalised or every migrated repo fails on Windows.
        $current = if ($hasClaude) { (Read-Text $claudePath) -replace "`r`n", "`n" } else { $null }
        if (($null -eq $current) -or ($current.Trim() -ne $expected)) {
            $safe = (-not $hasClaude) -or (Test-IsShimLike $current) -or $Force
            if ($Fix -and $safe) {
                Write-Text $claudePath "$expected`n"
                $written.Add('CLAUDE.md')
            }
            elseif ($Fix) {
                Add-Finding 'shim-valid' 'CLAUDE.md' 'Has real content while AGENTS.md is canonical - migrate it by hand, or re-run with -Force to replace it with the shim'
            }
            else {
                $why = if ($hasClaude) { 'CLAUDE.md must contain exactly the shim and nothing else' } else { 'CLAUDE.md shim is absent' }
                Add-Finding 'shim-valid' 'CLAUDE.md' "$why (run with -Fix)"
            }
        }
    }

    # ------------------------------------------------------------------- docs
    $docsDir = Join-Path $repo 'docs'
    $docs = @()
    if (Test-Path -LiteralPath $docsDir) { $docs = Get-ChildItem -LiteralPath $docsDir -Filter '*.md' -File | Sort-Object Name }

    $routes = [System.Collections.Generic.List[object]]::new()
    foreach ($d in $docs) {
        $content = Read-Text $d.FullName
        $fm = Get-Frontmatter $content
        $rel = "docs/$($d.Name)"
        $lineCount = (Get-Lines $content).Count
        $charCount = $content.Length

        if (Test-RuleOn 'frontmatter-present') {
            if (-not $fm.ContainsKey('description') -or [string]::IsNullOrWhiteSpace($fm['description'])) {
                Add-Finding 'frontmatter-present' $rel "No 'description' in frontmatter"
            }
            else {
                $maxDesc = Get-Opt 'frontmatter-present' 'maxDescription' 160
                if ($fm['description'].Length -gt $maxDesc) {
                    Add-Finding 'frontmatter-present' $rel "description is $($fm['description'].Length) characters, limit $maxDesc - shorten it to one scannable line"
                }
            }
        }

        $hasRoutes = $fm.ContainsKey('applies_to') -and -not [string]::IsNullOrWhiteSpace($fm['applies_to'])
        $isBackground = $fm.ContainsKey('background') -and $fm['background'] -match '^(true|yes)$'
        if ((Test-RuleOn 'doc-reachable') -and -not ($hasRoutes -xor $isBackground)) {
            Add-Finding 'doc-reachable' $rel "Needs either 'applies_to' globs or 'background: true', not both and not neither"
        }

        if (Test-RuleOn 'doc-size') {
            $maxL = Get-Opt 'doc-size' 'maxLines' 0
            $maxC = Get-Opt 'doc-size' 'maxCharacters' 24000
            # One finding per file, not one per dimension, and it must say what to do:
            # a warning nobody can act on is a warning people learn to scroll past.
            $charsPerToken = Get-Opt 'doc-size' 'charactersPerToken' 4.0
            $over = @()
            # Characters lead: tokens are the cost. Lines are the human-readability proxy.
            if ($charCount -gt $maxC) { $over += "$charCount characters (limit $maxC)" }
            if ($maxL -gt 0 -and $lineCount -gt $maxL) { $over += "$lineCount lines (limit $maxL)" }
            if ($over.Count -gt 0) {
                # The audience is an agent, not a reviewer: a routed doc is loaded WHOLE,
                # so every character is spent on tasks that need only part of it.
                # Characters are exact; tokens are not. This is a fixed YARDSTICK, not a
                # forecast: 4 characters per token is OpenAI's published English rule of
                # thumb, used here so a size reads the same on every model. Anthropic
                # publish no ratio, and newer tokenizers run ~30% heavier - hence
                # "varies by model" rather than a per-model calibration, which would make
                # the same unchanged file report a different size from one day to the next.
                # A non-positive ratio disables the estimate rather than dividing by zero.
                $estimate = ''
                if ($charsPerToken -gt 0) {
                    $tokens = $charCount / $charsPerToken
                    $inv = [cultureinfo]::InvariantCulture
                    $approx = if ($tokens -ge 1000) { [string]::Format($inv, '{0:N1}k', ($tokens / 1000)) } else { [math]::Round($tokens / 10) * 10 }
                    $estimate = " - about $approx tokens (varies by model), loaded whole whenever this doc is routed"
                }
                Add-Finding 'doc-size' $rel (($over -join ', ') + $estimate +
                    ". Trim it; split only if it covers more than one topic; or raise the limit in .agent-docs.json")
            }
        }

        if ($hasRoutes) {
            $routes.Add([ordered]@{
                file        = $rel
                globs       = (Split-GlobList $fm['applies_to'])
                description = if ($fm.ContainsKey('description')) { $fm['description'] } else { '' }
            })
        }
    }

    if (Test-RuleOn 'docs-count') {
        $maxDocs = Get-Opt 'docs-count' 'max' 12
        if ($routes.Count -gt $maxDocs) {
            Add-Finding 'docs-count' 'docs/' "$($routes.Count) routed docs (limit $maxDocs) - the routing table needs grouping"
        }
    }

    # --------------------------------------------------------- the two surfaces
    # STRUCTURAL rules describe what gets ROUTED, so they see the routed set: the entry
    # point, the README and docs/*.md. Recursing them would be a policy change, not wider
    # coverage - every docs/adr/0001-*.md would suddenly owe frontmatter and a route.
    $checkFiles = @()
    if ($entryPath) { $checkFiles += $entryPath }
    $readme = Join-Path $repo 'README.md'
    if (Test-Path -LiteralPath $readme) { $checkFiles += $readme }
    $checkFiles += ($docs | ForEach-Object { $_.FullName })

    # INTEGRITY rules ask whether text an agent might read is hiding something, and that
    # blast radius is not the routed set: a nested AGENTS.md is read nearest-wins without
    # appearing in any routing table, .claude/ and .github/instructions/ are loaded by
    # tool convention, and an agent that greps the repo reads everything else. So they see
    # every Markdown file, dotfolders included (-Force), minus build and vendor output.
    # 'scan' is read from the BUILT-IN ruleset only - the override loop merges 'mode' and
    # 'rules' and nothing else - so a repository cannot add its own docs folder to the
    # ignore list and disappear from the integrity scan.
    $scan = if ($config['scan'] -is [hashtable]) { $config['scan'] } else { @{} }
    $ignoreSegments = @(if ($scan['ignore'] -is [System.Collections.IEnumerable] -and $scan['ignore'] -isnot [string]) { $scan['ignore'] }
        else { @('.git', 'node_modules', 'bin', 'obj', 'packages', 'dist', '.vs', '.idea') })
    $maxScan = if ($scan['maxFiles']) { [int]$scan['maxFiles'] } else { 500 }
    if ($maxScan -lt 1) { Write-Warning "scan.maxFiles is $maxScan - using 500"; $maxScan = 500 }

    # Prunes as it walks rather than enumerating everything and filtering afterwards, so
    # an ignored node_modules costs nothing instead of a full traversal, and the file cap
    # is reached before the walk rather than after it.
    function Get-MarkdownTree {
        param([string]$Root, [string[]]$Ignore, [int]$Max)
        $out = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($Root)
        $truncated = $false
        while ($stack.Count -gt 0 -and -not $truncated) {
            foreach ($e in (Get-ChildItem -LiteralPath $stack.Pop() -Force -ErrorAction SilentlyContinue)) {
                if ($e.PSIsContainer) {
                    if ($Ignore -contains $e.Name) { continue }
                    # A symlinked directory can point back up the tree; do not follow it.
                    if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
                    $stack.Push($e.FullName)
                }
                elseif ($e.Extension -eq '.md') {
                    # Exactly Max files is a complete scan; only a file BEYOND the cap
                    # means something went unread.
                    if ($out.Count -ge $Max) { $truncated = $true; break }
                    $out.Add($e)
                }
            }
        }
        return @{ files = @($out | Sort-Object FullName); truncated = $truncated }
    }

    $integrityFiles = @()
    $scanTruncated = $false
    if ((Test-RuleOn 'no-invisible-characters') -or (Test-RuleOn 'link-hosts')) {
        $walk = Get-MarkdownTree -Root $repo -Ignore $ignoreSegments -Max $maxScan
        $integrityFiles = $walk.files
        if ($walk.truncated) {
            # An unfinished integrity scan is a failed integrity scan: a pull request
            # could otherwise park a payload behind enough decoy files to fall outside
            # the cap and pass enforce mode. So it is a finding under the rule(s) that
            # went unchecked, not just a warning on the console.
            $scanTruncated = $true
            $why = "Integrity scan stopped at scan.maxFiles ($maxScan) - the remaining Markdown files were not checked. Add the vendor folder to scan.ignore, or raise scan.maxFiles"
            Write-Warning "$why (repository '$repo')."
            foreach ($rule in @('no-invisible-characters', 'link-hosts')) {
                if (Test-RuleOn $rule) { Add-Finding $rule '' $why }
            }
        }
    }

    $textCache = @{}
    function Get-CachedText {
        param([string]$P)
        if (-not $textCache.ContainsKey($P)) { $textCache[$P] = Read-Text $P }
        return $textCache[$P]
    }

    foreach ($f in $integrityFiles) {
        $content = Get-CachedText $f.FullName
        $rel = [System.IO.Path]::GetRelativePath($repo, $f.FullName).Replace('\', '/')

        if (Test-RuleOn 'no-invisible-characters') {
            # Instruction files are read by a model and reviewed by a human, and these
            # characters are visible to only one of them. Unicode Tag characters
            # (U+E0000-U+E007F) can carry a whole hidden instruction; bidirectional
            # overrides reorder what a reviewer sees without changing what is parsed
            # (Boucher & Anderson, Trojan Source, USENIX Security 2023).
            #
            # A false positive at error severity is how a rule gets switched off, so the
            # one character here with a legitimate everyday use is treated in context:
            # U+200D joins emoji ("woman" ZWJ "laptop" is one glyph), and a heading with
            # an emoji in it must not fail a build. It is reported only where it is NOT
            # between two pictographs - which is exactly where it can hide something.
            # U+200C (ZWNJ) stays strict: it is required orthography in Persian, Arabic
            # and Indic scripts, and these repositories contain none. A repository that
            # ever does needs the ORG ruleset changed, not a local opt-out.
            $bad = [ordered]@{
                'Unicode Tag character'  = '\uDB40[\uDC00-\uDC7F]'
                'zero-width character'   = '[\u200B\u200C\u2060\uFEFF]'
                'stray zero-width joiner' = '(?<![\p{So}\uFE0F\uDC00-\uDFFF])\u200D|\u200D(?![\p{So}\uFE0F\uD800-\uDBFF])'
                'bidirectional override' = '[\u202A-\u202E\u2066-\u2069]'
            }
            foreach ($kind in $bad.Keys) {
                $hits = [regex]::Matches($content, $bad[$kind])
                if ($hits.Count -gt 0) {
                    $where = ($content.Substring(0, $hits[0].Index) -split "`n").Count
                    Add-Finding 'no-invisible-characters' "${rel}:$where" "$($hits.Count) $kind(s) - invisible to a reviewer, not to a model. Remove them"
                }
            }
        }

        if (Test-RuleOn 'link-hosts') {
            # Every http(s) URL, however it is written: inline link, reference definition,
            # autolink, or bare text in a code block. An agent can follow any of them, so
            # matching only the []() form would leave the other four spellings unchecked.
            # The slashes after the scheme are optional and may be backslashes: WHATWG
            # parsing of special schemes accepts 'https:\\evil.example', 'https:/evil.example'
            # and 'https:evil.example' alike, so a browser reaches evil.example from all of
            # them and the rule has to see them too.
            # NB: not $host - that is an automatic variable, and writing to it is an error
            # outside module scope.
            $allowed = @(Get-Opt 'link-hosts' 'allow' @())
            $skipLocal = [bool](Get-Opt 'link-hosts' 'ignoreLocal' $true)
            $seenHosts = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($m in [regex]::Matches($content, '(?i)\bhttps?:[/\\]*([^\s/\\<>)"''`\]]+)')) {
                # The host is whatever a BROWSER would connect to. Browsers follow the
                # WHATWG rule that '\' is '/' in http(s), so in
                # 'https://evil.example\@docs.claude.com/' the authority ends at the
                # backslash and the host is evil.example, whatever follows the '@'.
                # System.Uri does not mimic that - it rejects the host outright - so the
                # authority is cut at the first backslash here, and only then handed to
                # System.Uri for userinfo, port and IDN handling. A string .NET still
                # refuses falls back to the textual host so that a malformed link is
                # checked rather than silently skipped.
                $authority = ($m.Groups[1].Value -split '\\')[0].TrimEnd('.', ',')
                if (-not $authority) { continue }
                $uri = $null
                if ([System.Uri]::TryCreate("http://$authority", [System.UriKind]::Absolute, [ref]$uri) -and $uri.IdnHost) {
                    $linkHost = $uri.IdnHost
                }
                else {
                    $linkHost = $authority
                    if ($linkHost.Contains('@')) { $linkHost = ($linkHost -split '@')[-1] }   # userinfo
                    $linkHost = ($linkHost -split ':')[0]                                      # port
                }
                if (-not $linkHost) { continue }
                if (-not $seenHosts.Add($linkHost.ToLowerInvariant())) { continue }        # once per file
                # A host nobody outside the machine or the LAN can answer for is not the
                # threat this rule is about, and flagging every `http://localhost:5000` in a
                # run command is how a rule gets switched off. Single-label names cannot be
                # public domains; the rest are the reserved ranges and suffixes. The range
                # test applies to IPv4 LITERALS only - '10.attacker.example' is a public
                # domain that merely starts with '10.'.
                $ip = $null
                $isPrivateIp = [System.Net.IPAddress]::TryParse($linkHost, [ref]$ip) -and
                    $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                    $linkHost -match '^(127|10|169\.254|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.'
                if ($skipLocal -and (
                        -not $linkHost.Contains('.') -or
                        $linkHost -match '(?i)\.(local|localhost|internal|invalid)$' -or
                        $isPrivateIp
                    )) { continue }
                if (-not ($allowed | Where-Object { $linkHost -eq $_ -or $linkHost.EndsWith(".$_") })) {
                    Add-Finding 'link-hosts' $rel "Link to '$linkHost' is not on the allowlist"
                }
            }
        }
    }

    # ------------------------------------------------- references + line length
    $siblingPattern = Get-Opt 'reference-resolves' 'siblingRepoPattern' '^(octo|mm)-[^/]+/'
    $anchorCache = @{}

    # A reference to a CLAUDE.md that has become the shim still RESOLVES, so nothing
    # above reports it - but an agent that opens it with its Read tool gets the raw text,
    # a comment and '@AGENTS.md', because imports are only expanded when instruction
    # files are loaded, not when a file is read. The pointer quietly degrades from "here
    # is the contract" to "go and look elsewhere". Reported as a warning, not an error:
    # a capable agent usually makes the extra hop, so this is a cost, not a breakage.
    #
    # Deliberately light: only a file literally named CLAUDE.md is ever opened, at most
    # once per path, and a sibling repository that is not checked out is skipped exactly
    # as before - this never reaches outside the local checkout.
    $siblingRoot = if ($Global:ROOTPATH) { $Global:ROOTPATH } else { Split-Path -Parent $repo }
    $shimCache = @{}
    function Test-PointsAtShim {
        param([string]$Path)
        if ((Split-Path -Leaf $Path) -ne 'CLAUDE.md') { return $false }
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        $full = (Resolve-Path -LiteralPath $Path).Path
        if (-not $shimCache.ContainsKey($full)) {
            $agents = Join-Path (Split-Path -Parent $full) 'AGENTS.md'
            $shimCache[$full] = (Test-Path -LiteralPath $agents) -and (Test-IsShimLike (Read-Text $full))
        }
        return $shimCache[$full]
    }
    function Get-ShimAdvice { param([string]$Ref) "points at a shim - reference '$($Ref -replace 'CLAUDE\.md$', 'AGENTS.md')' instead, since an agent reading the shim gets only '@AGENTS.md'" }

    foreach ($f in $checkFiles) {
        $content = Get-CachedText $f
        $rel = [System.IO.Path]::GetRelativePath($repo, $f).Replace('\', '/')
        $base = Split-Path -Parent $f

        if (Test-RuleOn 'reference-resolves') {
            foreach ($m in [regex]::Matches($content, '\]\(([^)\s]+)\)')) {
                $target = $m.Groups[1].Value
                if ($target -match '^[A-Za-z][A-Za-z0-9+.-]*:') { continue }   # any URI scheme
                $parts = $target -split '#', 2
                $filePart = $parts[0]
                $anchor = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                $resolved = if ([string]::IsNullOrEmpty($filePart)) { $f } else { Join-Path $base $filePart }
                if (-not (Test-Path -LiteralPath $resolved)) {
                    Add-Finding 'reference-resolves' $rel "Link target not found: $target"; continue
                }
                if ($filePart -and (Test-PointsAtShim $resolved)) {
                    Add-Finding 'reference-resolves' $rel "Link $(Get-ShimAdvice $filePart)" 'warn'
                }
                if ($anchor -and $resolved -like '*.md') {
                    $full = (Resolve-Path -LiteralPath $resolved).Path
                    if (-not $anchorCache.ContainsKey($full)) { $anchorCache[$full] = Get-Anchors (Read-Text $full) }
                    if (-not $anchorCache[$full].Contains($anchor)) { Add-Finding 'reference-resolves' $rel "Anchor not found: $target" }
                }
            }
            foreach ($m in [regex]::Matches($content, '`([^`\s]+\.md)`')) {
                $ref = $m.Groups[1].Value
                # A bare `CLAUDE.md` means this repo's own entry point - after a migration,
                # its shim. Extracted docs routinely say "see CLAUDE.md".
                if ($ref -eq 'CLAUDE.md') {
                    if (Test-PointsAtShim (Join-Path $repo 'CLAUDE.md')) {
                        Add-Finding 'reference-resolves' $rel "``CLAUDE.md`` $(Get-ShimAdvice $ref)" 'warn'
                    }
                    continue
                }
                if ($ref -notmatch '/') { continue }
                if ($ref -match '^\.\.') { continue }
                if ($siblingPattern -and $ref -match $siblingPattern) {
                    # A sibling that is not checked out is skipped silently, as before.
                    if (Test-PointsAtShim (Join-Path $siblingRoot $ref)) {
                        Add-Finding 'reference-resolves' $rel "``$ref`` $(Get-ShimAdvice $ref)" 'warn'
                    }
                    continue
                }
                $local = Join-Path $repo $ref
                if (-not (Test-Path -LiteralPath $local)) {
                    Add-Finding 'reference-resolves' $rel "Referenced file not found: $ref"
                }
                elseif (Test-PointsAtShim $local) {
                    Add-Finding 'reference-resolves' $rel "``$ref`` $(Get-ShimAdvice $ref)" 'warn'
                }
            }
        }

        $lineScope = Get-Opt 'line-length' 'scope' 'entryPoint'
        $inScope = ($lineScope -eq 'all') -or ($entryPath -and $f -eq $entryPath)
        if ((Test-RuleOn 'line-length') -and $inScope) {
            $maxLine = Get-Opt 'line-length' 'max' 120
            $maxTable = Get-Opt 'line-length' 'tables' 200
            $listCap = Get-Opt 'line-length' 'maxReported' 5
            $skipCode = [bool](Get-Opt 'line-length' 'ignoreCodeBlocks' $true)
            $skipUnbroken = [bool](Get-Opt 'line-length' 'ignoreNoWhitespace' $true)
            $inCode = $false
            $inFrontmatter = $false
            $hits = 0
            $lines = Get-Lines $content
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($i -eq 0 -and $line.Trim() -eq '---') { $inFrontmatter = $true; continue }
                if ($inFrontmatter) { if ($line.Trim() -eq '---') { $inFrontmatter = $false }; continue }
                if ($line -match '^\s*```') { $inCode = -not $inCode; continue }
                if ($inCode -and $skipCode) { continue }
                $isTable = $line.TrimStart().StartsWith('|')
                $limit = if ($isTable) { $maxTable } else { $maxLine }
                if ($line.Length -le $limit) { continue }
                if ($skipUnbroken -and ($line.Substring($limit) -notmatch '\s')) { continue }
                $hits++
                if ($hits -le $listCap) {
                    $kind = if ($isTable) { 'table row' } else { 'line' }
                    Add-Finding 'line-length' "${rel}:$($i + 1)" "$kind is $($line.Length) characters, limit $limit"
                }
            }
            if ($hits -gt $listCap) { Add-Finding 'line-length' $rel "$($hits - $listCap) further over-length lines not listed" }
        }
    }

    # ----------------------------------------------------- entry point budgets
    $startMarker = '<!-- >>> generated: routing -->'
    $endMarker = '<!-- <<< end generated: routing -->'

    if ($entryPath) {
        $entry = Read-Text $entryPath
        $entryLines = (Get-Lines $entry).Count
        $entryChars = $entry.Length

        if (Test-RuleOn 'entry-point-lines') {
            $maxL = Get-Opt 'entry-point-lines' 'max' 200
            if ($entryLines -gt $maxL) {
                Add-Finding 'entry-point-lines' $entryName "$entryLines lines over the budget of $maxL - this file loads in every session. Move detail into docs/ and route it with applies_to"
            }
        }
        if (Test-RuleOn 'entry-point-characters') {
            $maxC = Get-Opt 'entry-point-characters' 'max' 20000
            $warnAt = Get-Opt 'entry-point-characters' 'warnAt' 12000
            if ($entryChars -gt $maxC) {
                Add-Finding 'entry-point-characters' $entryName "$entryChars characters over the budget of $maxC - move detail into docs/, or shorten the longest lines"
            }
            elseif ($warnAt -gt 0 -and $entryChars -gt $warnAt) {
                Add-Finding 'entry-point-characters' $entryName "$entryChars characters, past the $warnAt target but under the $maxC limit - worth trimming before it grows" 'warn'
            }
        }

        if (Test-RuleOn 'required-sections') {
            # Standardise the SHAPE, never the prose: a missing section fails, but nothing
            # here supplies default text, so an empty slot cannot be filled with filler.
            $required = Get-Opt 'required-sections' 'sections' @()
            $headings = @()
            foreach ($l in (Get-Lines $entry)) {
                if ($l -match '^##\s+(.*?)\s*$') { $headings += $Matches[1] }
            }
            foreach ($want in $required) {
                if (-not ($headings | Where-Object { $_ -eq $want })) {
                    Add-Finding 'required-sections' $entryName "Missing section '## $want' - every repo's entry point carries it"
                }
            }
        }

        if (Test-RuleOn 'routing-current') {
            $withDesc = [bool](Get-Opt 'routing-current' 'includeDescriptions' $false)
            $sb = [System.Text.StringBuilder]::new()
            if ($withDesc) {
                [void]$sb.AppendLine('| When you change | Read first | What it covers |')
                [void]$sb.AppendLine('|---|---|---|')
            }
            else {
                [void]$sb.AppendLine('| When you change | Read first |')
                [void]$sb.AppendLine('|---|---|')
            }
            foreach ($r in ($routes | Sort-Object { $_.file })) {
                $globs = ($r.globs | ForEach-Object { "``$_``" }) -join ', '
                if ($withDesc) {
                    # A '|' in a description would add a column and corrupt the table.
                    $desc = $r.description -replace '\|', '\|'
                    [void]$sb.AppendLine("| $globs | ``$($r.file)`` | $desc |")
                }
                else { [void]$sb.AppendLine("| $globs | ``$($r.file)`` |") }
            }
            # AppendLine emits CRLF on Windows and the marker block is compared against an
            # LF template, so both sides are normalised or a current table reads as stale.
            $generated = ($sb.ToString() -replace "`r`n", "`n").TrimEnd("`n")

            $entry = $entry -replace "`r`n", "`n"
            $si = $entry.IndexOf($startMarker)
            $ei = $entry.IndexOf($endMarker)
            if ($si -lt 0 -or $ei -lt 0 -or $ei -lt $si) {
                Add-Finding 'routing-current' $entryName "Add $startMarker and $endMarker around the routing table"
            }
            else {
                $head = $entry.Substring(0, $si + $startMarker.Length)
                $tail = $entry.Substring($ei)
                $currentBlock = $entry.Substring($si + $startMarker.Length, $ei - $si - $startMarker.Length)
                $desired = "`n$generated`n"
                if ($currentBlock -ne $desired) {
                    if ($Fix) { Write-Text $entryPath ($head + $desired + $tail); $written.Add($entryName) }
                    else { Add-Finding 'routing-current' $entryName 'Generated routing table is out of date (run with -Fix)' }
                }
            }
        }
    }

    # ----------------------------------------------------------------- output
    $errors = @($findings | Where-Object { $_.severity -eq 'error' })
    $warnings = @($findings | Where-Object { $_.severity -eq 'warn' })
    $ok = $errors.Count -eq 0

    if ($Json) {
        Write-OctoJson -Command 'Test-OctoAgentDocs' -Data ([ordered]@{
            repository   = Split-Path -Leaf $repo
            entryPoint   = $entryName
            canonical    = if ($hasAgents) { 'AGENTS.md' } else { 'CLAUDE.md' }
            mode         = $config.mode
            filesScanned = [ordered]@{ routed = $checkFiles.Count; integrity = $integrityFiles.Count; truncated = $scanTruncated }
            filesWritten = @($written)
            routes       = $routes
            findings     = $findings
            ruleSet      = $config.rules
            summary      = [ordered]@{ errors = $errors.Count; warnings = $warnings.Count; success = $ok }
        })
    }
    else {
        Write-Host "Agent docs check: $(Split-Path -Leaf $repo) (entry point: $entryName, mode: $($config.mode))" -ForegroundColor Yellow
        if ($findings.Count -eq 0) { Write-Host "  clean - $($routes.Count) routed docs" -ForegroundColor Green }
        foreach ($f in $findings) {
            $colour = if ($f.severity -eq 'error') { 'Red' } else { 'DarkYellow' }
            $where = if ($f.file) { " $($f.file):" } else { '' }
            Write-Host "  [$($f.severity)] $($f.rule)$where $($f.message)" -ForegroundColor $colour
        }
        if ($written.Count -gt 0) { Write-Host "  rewrote $($written -join ', ')" -ForegroundColor Cyan }
        elseif ($Fix) { Write-Host "  nothing to rewrite" -ForegroundColor Cyan }
        Write-Host "  $($errors.Count) error(s), $($warnings.Count) warning(s)" -ForegroundColor Gray
    }

    if ($config.mode -eq 'enforce' -and -not $ok) {
        $global:LASTEXITCODE = 1
        throw "Test-OctoAgentDocs: $($errors.Count) error-severity finding(s) in $(Split-Path -Leaf $repo)"
    }
}

Export-ModuleMember -Function @('Test-OctoAgentDocs')
