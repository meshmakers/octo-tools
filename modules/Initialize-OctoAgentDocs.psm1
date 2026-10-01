# Plain imports, not -Force: a forced import from inside a module re-homes the shared module
# into this module's scope and removes it from the session, which breaks the other callers.
# Each cmdlet module imports what IT calls - a nested import is visible only to the module
# that made it, so the JSON envelope helper cannot be inherited through the shared module.
Import-Module (Join-Path $PSScriptRoot 'OctoJsonOutput.psm1')
Import-Module (Join-Path $PSScriptRoot 'OctoAgentDocs.Common.psm1')

$script:AgentDocsRuleIds = Get-OctoAgentDocsRuleIdList

function Initialize-OctoAgentDocs {
    <#
    .SYNOPSIS
    Gives a repository the minimal agent-docs shape, or a migration brief when it already has
    a hand-written CLAUDE.md, and reports how far the migration has come.

    .DESCRIPTION
    Every run ends with the same five-row checklist - AGENTS.md, CLAUDE.md, docs/, the
    migration brief, the check - marked done (check mark), open (cross) or not applicable
    yet (dot), and the next steps are derived from the open rows. Four states, decided from
    what is already in the repository, and the cmdlet never overwrites a file in any of them:

      migrated     AGENTS.md exists, CLAUDE.md is the shim and no migration brief is left.
                   Nothing is written. The next step follows from the check: -Fix when a
                   generated region is stale, -Explain when something else is open,
                   otherwise none.
      migrating    AGENTS.md exists but CLAUDE.md is not yet the shim - real content, or a
                   thin import pointing elsewhere - or the migration brief is still present.
                   Nothing is written; the next steps name what is left.
      migration    no AGENTS.md, but a CLAUDE.md with real content. Only
                   AGENTS-MIGRATION.md is written: a brief for the coding agent and the
                   developer doing the migration, rendered from the ruleset so it carries
                   the budgets, the required sections and the shim text as enforced.
                   Test-OctoAgentDocs warns while the brief exists (migration-pending).
      created      neither file, or a CLAUDE.md that holds nothing but comments and an
                   @import. AGENTS.md is written with the required sections and the routing
                   markers; CLAUDE.md is written with the shim only when it is absent - an
                   existing import, however thin, is left for Test-OctoAgentDocs -Fix,
                   which has the guard for replacing it. No docs/ folder and no
                   .agent-docs.json: the first routed doc creates the folder, and an
                   override file is something a repository adds when it has a reason.

    Section names, the shim text and the budgets come from the BUILT-IN ruleset shipped with
    octo-tools, not from a repository override: a repository being initialised has no
    override yet, and a repository being migrated should see the org defaults it will be
    held to. The check this cmdlet runs for the checklist always runs in logOnly mode: it
    wants the data, not the gate.

    .PARAMETER Path
    Repository to initialise: a path, or a repository name resolved under $Global:ROOTPATH
    when the path itself does not exist. Defaults to the current directory.

    .PARAMETER Json
    Emit the standard octo-tools JSON envelope instead of human output.

    .EXAMPLE
    Initialize-OctoAgentDocs -Path octo-new-repo

    .EXAMPLE
    Initialize-OctoAgentDocs -Path octo-communication-operator -WhatIf
    #>

    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Human report on the host, -Json on the pipeline: the octo-tools convention')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'AgentDocs is the name of the thing being initialised')]
    param(
        [string]$Path = ".",
        [switch]$Json
    )

    $ErrorActionPreference = 'Stop'

    $repo = Resolve-OctoAgentDocsRepository -Path $Path
    $repoName = Split-Path -Leaf $repo

    # ------------------------------------------------------------------ ruleset
    # Normalised by the shared loader, so every rule is [severity, options].
    $config = Read-OctoAgentDocsBuiltInRuleset -RuleIds $script:AgentDocsRuleIds
    $sections = @($config.rules['required-sections'][1]['sections'])
    if ($sections.Count -eq 0) { $sections = @('Read before you change', 'Build & test', 'Before you commit', 'Rules') }
    $shimLines = @($config.rules['shim-valid'][1]['content'])
    if ($shimLines.Count -eq 0) { $shimLines = @('@AGENTS.md') }
    $briefName = Get-OctoAgentDocsConstant BriefName
    $startMarker = Get-OctoAgentDocsConstant RoutingStart
    $endMarker = Get-OctoAgentDocsConstant RoutingEnd

    # -------------------------------------------------------------------- state
    $agentsPath = Join-Path $repo 'AGENTS.md'
    $claudePath = Join-Path $repo 'CLAUDE.md'
    $briefPath = Join-Path $repo $briefName
    $hasAgents = Test-Path -LiteralPath $agentsPath
    $hasClaude = Test-Path -LiteralPath $claudePath
    $hasBrief = Test-Path -LiteralPath $briefPath
    # Four answers: absent; 'shim'; 'import' (thin - comments and one @import - but not the
    # shim, so not done); 'real content'. Whether a file IS the shim is the checker's
    # verdict (its JSON 'shim' field, computed whatever severity the rule has), because a
    # repository may override shim-valid.content; the built-in text is only the fallback
    # for when the checker is not loaded.
    $expectedShim = $shimLines -join "`n"
    function Get-ClaudeState {
        param($Check)
        if (-not (Test-Path -LiteralPath $claudePath)) { return 'absent' }
        $text = ((Read-OctoAgentDocsText $claudePath) -replace "`r`n", "`n") -replace "`r", "`n"
        $isShim = if ($Check -and $Check.data.PSObject.Properties['shim']) { $Check.data.shim -eq 'ok' }
                  else { $text.Trim() -ceq $expectedShim }
        if ($isShim) { return 'shim' }
        if (Test-OctoAgentDocsShimLike $text) { return 'import' }
        return 'real content'
    }

    $written = [System.Collections.Generic.List[string]]::new()
    # Each next step is what to do and, when there is one, the command that does it, kept
    # apart so the command is clean to copy and the text is not mistaken for syntax.
    # One command is printed once: a later step that would repeat it keeps its text and
    # drops the command.
    $next = [System.Collections.Generic.List[object]]::new()
    function Add-Next {
        param([string]$What, [string]$Command)
        if ($Command -and ($next | Where-Object { $_.command -eq $Command })) { $Command = $null }
        $next.Add([ordered]@{ what = $What; command = $Command })
    }
    $checkCmd = "Test-OctoAgentDocs -Path $(Format-OctoAgentDocsArgument -Value $Path)"
    $hasChecker = [bool](Get-Command Test-OctoAgentDocs -ErrorAction SilentlyContinue)
    # The checklist wants the check's DATA, never its gate: a repository that opted up to
    # enforce must not turn a status report into a throw.
    function Invoke-Check {
        param([switch]$Fix)
        if (-not $hasChecker) { return $null }
        try { return ((Test-OctoAgentDocs -Path $repo -Mode logOnly -Json -Fix:$Fix 3>$null 6>$null) | ConvertFrom-Json) }
        catch { return $null }
    }

    # ----------------------------------------------------------------- actions
    $check = $null
    if ($hasAgents) {
        # Nothing to scaffold; the check decides whether the migration is finished.
        $check = Invoke-Check
        $state = if ($hasBrief -or (Get-ClaudeState -Check $check) -ne 'shim') { 'migrating' } else { 'migrated' }
    }
    elseif ((Get-ClaudeState) -eq 'real content') {
        $state = 'migration'
        if (-not $hasBrief -and $PSCmdlet.ShouldProcess($briefName, 'Write the migration brief')) {
            Write-OctoAgentDocsText $briefPath (Format-MigrationBrief -Repo $repoName -Config $config -Sections $sections -ShimLines $shimLines)
            $written.Add($briefName)
        }
    }
    else {
        $state = 'created'
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.Append("# $repoName`n`n")
        $first = $true
        foreach ($sec in $sections) {
            [void]$sb.Append("## $sec`n`n")
            if ($first) { [void]$sb.Append("$startMarker`n$endMarker`n`n"); $first = $false }
        }
        if ($PSCmdlet.ShouldProcess('AGENTS.md', 'Write the entry point with the required sections and routing markers')) {
            Write-OctoAgentDocsText $agentsPath ($sb.ToString())
            $written.Add('AGENTS.md')
        }
        # The shim is written only where there is no CLAUDE.md at all. A thin existing one
        # (a comment and an @import to somewhere else) is still somebody's pointer; replacing
        # it is what Test-OctoAgentDocs -Fix is for, with its guard and its -WhatIf.
        if (-not $hasClaude -and $PSCmdlet.ShouldProcess('CLAUDE.md', 'Write the AGENTS.md shim')) {
            Write-OctoAgentDocsText $claudePath (($shimLines -join "`n") + "`n")
            $written.Add('CLAUDE.md')
        }
        # One pass fills the (empty) routing table and returns the data the checklist needs,
        # so the first check is clean and the repository is scanned once. Only when the shim
        # was ours to write: otherwise -Fix would replace the existing CLAUDE.md.
        if ($written.Contains('AGENTS.md') -and -not $hasClaude) { $check = Invoke-Check -Fix }
    }

    # --------------------------------------------------------------- checklist
    # The same five rows in every state, read off the repository AFTER any writes, so the
    # list shows the result rather than the plan. Under -WhatIf nothing was written and the
    # rows say what would happen. done is $true (check mark), $false (cross, work left) or
    # $null (dot, not applicable yet), and the next steps are derived from the open rows.
    $whatIf = [bool]$WhatIfPreference
    $hasAgentsNow = Test-Path -LiteralPath $agentsPath
    $hasBriefNow = Test-Path -LiteralPath $briefPath
    if ($hasAgentsNow -and -not $check) { $check = Invoke-Check }
    $claudeNow = Get-ClaudeState -Check $check

    $rows = [System.Collections.Generic.List[object]]::new()
    function Add-Row { param([string]$Item, $Done, [string]$Fact) $rows.Add([ordered]@{ item = $Item; done = $Done; fact = $Fact }) }

    if ($hasAgentsNow) { Add-Row 'AGENTS.md' $true 'present' }
    elseif ($state -eq 'created' -and $whatIf) { Add-Row 'AGENTS.md' $null 'would be written' }
    else { Add-Row 'AGENTS.md' $false 'absent' }

    switch ($claudeNow) {
        'shim' { Add-Row 'CLAUDE.md' $true 'shim' }
        'import' { Add-Row 'CLAUDE.md' $false 'imports something else - not the shim' }
        'real content' { Add-Row 'CLAUDE.md' $false 'real content' }
        default { if ($state -eq 'created' -and $whatIf) { Add-Row 'CLAUDE.md' $null 'would be written' } else { Add-Row 'CLAUDE.md' $false 'absent' } }
    }

    if ($check) {
        $n = @($check.data.routes).Count
        if ($n -gt 0) { Add-Row 'docs/' $true "$n routed" } else { Add-Row 'docs/' $null 'none yet' }
    }
    elseif (-not $hasAgentsNow) { Add-Row 'docs/' $null 'not read until AGENTS.md exists' }
    elseif (-not $hasChecker) { Add-Row 'docs/' $null 'not read - checker not loaded' }
    else { Add-Row 'docs/' $null 'not read - the check failed' }

    if ($hasBriefNow -and $written.Contains($briefName)) { Add-Row $briefName $null 'written - delete it when the migration is done' }
    elseif ($hasBriefNow) { Add-Row $briefName $false 'present' }
    elseif ($state -eq 'migration' -and $whatIf) { Add-Row $briefName $null 'would be written' }
    else { Add-Row $briefName $true 'absent' }

    $stale = @(); $other = @()
    if ($check) {
        $stale = @($check.data.findings | Where-Object { $_.rule -in @('routing-current', 'shim-valid') })
        $other = @($check.data.findings | Where-Object { $_.rule -notin @('routing-current', 'shim-valid', 'migration-pending') })
        $e = $check.data.summary.errors; $w = $check.data.summary.warnings
        if ($e -eq 0 -and $w -eq 0) { Add-Row 'check' $true 'clean' } else { Add-Row 'check' $false "$e error(s), $w warning(s)" }
    }
    elseif (-not $hasAgentsNow) { Add-Row 'check' $null 'not run until AGENTS.md exists' }
    elseif (-not $hasChecker) { Add-Row 'check' $null 'not run - checker not loaded' }
    else { Add-Row 'check' $null 'failed - run it directly to see why' }

    # -------------------------------------------------------------- next steps
    # The migration state has its own script. Every other state lists one step per open
    # row first - that is the work - and the guidance for a fresh repository after it.
    if ($state -eq 'migration') {
        Add-Next "Open $briefName with your coding agent and follow its steps" $null
        Add-Next 'Check after every step' $checkCmd
        Add-Next "Delete $briefName in the migration commit" $null
    }
    else {
        if ($claudeNow -eq 'real content') { Add-Next 'Move the remaining content out of CLAUDE.md into AGENTS.md or docs/, then let -Fix write the shim' "$checkCmd -Fix" }
        elseif ($claudeNow -eq 'import' -and $hasAgentsNow) { Add-Next 'Replace the existing CLAUDE.md import with the shim and fill the routing table' "$checkCmd -Fix" }
        if ($hasBriefNow) { Add-Next "Finish the steps in $briefName and delete it" $null }
        if ($stale.Count -gt 0 -and $claudeNow -ne 'real content' -and -not ($next | Where-Object { $_.command -like '*-Fix' })) {
            Add-Next 'Regenerate the routing table and the shim' "$checkCmd -Fix"
        }
        if ($other.Count -gt 0) { Add-Next "Resolve $($other.Count) open finding(s)" "$checkCmd -Explain" }
        if (-not $hasChecker) { Add-Next 'Import Test-OctoAgentDocs.psm1 and check the repository' $checkCmd }
        if ($state -eq 'created') {
            Add-Next 'Write the AGENTS.md sections; the checker reports a missing one but never writes it' $null
            Add-Next "Add docs/<topic>.md with 'description' and 'applies_to' frontmatter, then regenerate the table" "$checkCmd -Fix"
        }
    }

    # ------------------------------------------------------------------ output
    if ($Json) {
        Write-OctoJson -Command 'Initialize-OctoAgentDocs' -Data ([ordered]@{
            repository   = $repoName
            state        = $state
            checklist    = @($rows)
            filesWritten = @($written)
            nextSteps    = @($next)
        })
        return
    }
    # Green only when nothing is open: a 'created' run that left work behind is not green.
    $stateColour = if (@($rows | Where-Object { $_.done -eq $false }).Count -eq 0) { 'Green' } else { 'DarkYellow' }
    Write-Host "Agent docs init: $repoName - " -ForegroundColor Yellow -NoNewline
    Write-Host $state -ForegroundColor $stateColour
    if ($written.Count -gt 0) { Write-Host "  wrote $($written -join ', ')" -ForegroundColor Cyan }
    foreach ($row in $rows) {
        # U+2713 check mark, U+2717 cross, U+00B7 middle dot - as code points so the file
        # stays ASCII, like every other module here.
        $mark, $colour = switch ($row.done) { $true { [string][char]0x2713, 'Green' } $false { [string][char]0x2717, 'DarkYellow' } default { [string][char]0x00B7, 'DarkGray' } }
        Write-Host "  $mark " -ForegroundColor $colour -NoNewline
        Write-Host $row.item.PadRight(21) -ForegroundColor Gray -NoNewline
        Write-Host $row.fact -ForegroundColor $(if ($row.done -eq $false) { 'DarkYellow' } else { 'Gray' })
    }
    foreach ($n in $next) {
        Write-Host "  next: $($n.what)" -ForegroundColor Gray
        if ($n.command) { Write-Host "        $($n.command)" -ForegroundColor White }
    }
}

# Renders modules/agent-docs-migration.template.md with the values the ruleset enforces, so
# the brief an agent reads carries the same numbers the checker will hold it to. Returns the
# text; writing it is the caller's decision.
function Format-MigrationBrief {
    param([string]$Repo, [hashtable]$Config, [string[]]$Sections, [string[]]$ShimLines)

    $templatePath = Join-Path $PSScriptRoot 'agent-docs-migration.template.md'
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Migration brief template missing at $templatePath" }
    $t = Read-OctoAgentDocsText $templatePath

    # $Config comes normalised from Read-OctoAgentDocsBuiltInRuleset: every rule is [severity, options].
    function Opt { param([string]$Id, [string]$Name) $Config.rules[$Id][1][$Name] }
    function Sev { param([string]$Id) [string]$Config.rules[$Id][0] }

    # Hashtables, not nested arrays: PowerShell unrolls @( @(..) @(..) ) into one flat list.
    $budgetRows = @(
        @{ label = 'AGENTS.md lines'; rule = 'entry-point-lines'; option = 'max' }
        @{ label = 'AGENTS.md characters'; rule = 'entry-point-characters'; option = 'max' }
        @{ label = 'Line length in AGENTS.md'; rule = 'line-length'; option = 'max' }
        @{ label = 'Characters per docs/*.md'; rule = 'doc-size'; option = 'maxCharacters' }
        @{ label = 'Routed docs'; rule = 'docs-count'; option = 'max' }
        @{ label = 'Frontmatter description characters'; rule = 'frontmatter-present'; option = 'maxDescription' }
    )
    $budgets = [System.Text.StringBuilder]::new()
    [void]$budgets.Append("| Budget | Limit | Severity | Rule |`n|---|---|---|---|`n")
    foreach ($row in $budgetRows) {
        $limit = Opt $row.rule $row.option
        if ($null -eq $limit) { continue }
        [void]$budgets.Append("| $($row.label) | $limit | $(Sev $row.rule) | ``$($row.rule)`` |`n")
    }

    $sectionList = ($Sections | ForEach-Object { "- ``## $_``" }) -join "`n"
    $shim = ($ShimLines | ForEach-Object { "                   $_" }) -join "`n"

    # Grouped by tier - the brief says "fix in this order", the same order the checker
    # reports in.
    $docs = if ($Config['ruleDocs'] -is [hashtable]) { $Config['ruleDocs'] } else { @{} }
    $rules = [System.Text.StringBuilder]::new()
    $active = @($Config.rules.Keys | Where-Object { (Sev $_) -ne 'off' })
    $tierOf = @{}
    foreach ($id in $active) { $tierOf[$id] = Get-OctoAgentDocsRuleTier -Config $Config -Id $id }
    foreach ($tierNo in @($tierOf.Values | Sort-Object -Unique)) {
        [void]$rules.Append("$(Get-OctoAgentDocsTierHeading -Config $Config -Tier $tierNo -Markdown)`n`n")
        foreach ($id in $active) {
            if ($tierOf[$id] -ne $tierNo) { continue }
            $d = if ($docs[$id] -is [hashtable]) { $docs[$id] } else { @{} }
            [void]$rules.Append("- ``$id`` [$(Sev $id)]")
            if ($d['why']) { [void]$rules.Append(" - $($d['why'])") }
            if ($d['fix']) { [void]$rules.Append(" Fix: $($d['fix'])") }
            [void]$rules.Append("`n")
        }
        [void]$rules.Append("`n")
    }

    $t = $t.Replace('{{REPO}}', $Repo)
    $t = $t.Replace('{{DATE}}', (Get-Date).ToString('yyyy-MM-dd'))
    $t = $t.Replace('{{BRIEF}}', (Get-OctoAgentDocsConstant BriefName))
    $t = $t.Replace('{{START_MARKER}}', (Get-OctoAgentDocsConstant RoutingStart))
    $t = $t.Replace('{{END_MARKER}}', (Get-OctoAgentDocsConstant RoutingEnd))
    $t = $t.Replace('{{SHIM}}', $shim)
    $t = $t.Replace('{{SECTIONS}}', $sectionList)
    $t = $t.Replace('{{BUDGETS}}', $budgets.ToString().TrimEnd("`n"))
    $t = $t.Replace('{{RULES}}', $rules.ToString().TrimEnd("`n"))
    return $t
}

Export-ModuleMember -Function @('Initialize-OctoAgentDocs')
