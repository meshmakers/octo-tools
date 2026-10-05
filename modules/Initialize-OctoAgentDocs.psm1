Import-Module (Join-Path $PSScriptRoot 'OctoJsonOutput.psm1')
Import-Module (Join-Path $PSScriptRoot 'OctoAgentDocs.Common.psm1')

function Initialize-OctoAgentDocs {
    <#
    .SYNOPSIS
    Gives a repository the minimal agent-docs shape, or a migration brief when it already has
    a hand-written CLAUDE.md, and reports how far the migration has come.

    .DESCRIPTION
    Every run ends with the same five-row checklist - AGENTS.md, CLAUDE.md, docs/, the
    migration brief, the check - and the next steps follow from the open rows. The state is
    decided from what is in the repository, and no existing file is ever overwritten:

      created     neither file, or a CLAUDE.md with nothing but comments and an @import.
                  AGENTS.md is written with the required sections and the routing markers;
                  CLAUDE.md gets the shim when it is absent. Nothing else is created.
      migration   no AGENTS.md, but a CLAUDE.md with real content. Only AGENTS-MIGRATION.md
                  is written: a brief for the coding agent and the developer doing the
                  migration, rendered from the ruleset. Test-OctoAgentDocs warns while it exists.
      migrating   AGENTS.md exists, but CLAUDE.md is not the shim yet or the brief is still there.
      migrated    AGENTS.md exists, CLAUDE.md is the shim, no brief is left.

    Section names, the shim text and the budgets come from the built-in ruleset. The check
    this cmdlet runs for the checklist always runs in logOnly mode.

    .PARAMETER Path
    Repository to initialise: a path, or a repository name under $Global:ROOTPATH. Default: '.'.

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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$Global:ROOTPATH is the octo-tools profile contract')]
    param(
        [string]$Path = '.',
        [switch]$Json
    )
    $ErrorActionPreference = 'Stop'
    $repo = Resolve-OctoAgentDocsRepository -Path $Path
    $repoName = Split-Path -Leaf $repo
    $config = Read-OctoAgentDocsBuiltInRuleset
    $sections = @($config.rules['required-sections'][1]['sections'])
    $shimLines = @($config.rules['shim-valid'][1]['content'])
    $briefName = Get-OctoAgentDocsConstant BriefName
    $agentsPath = Join-Path $repo 'AGENTS.md'
    $claudePath = Join-Path $repo 'CLAUDE.md'
    $briefPath = Join-Path $repo $briefName
    $whatIf = [bool]$WhatIfPreference
    $written = [System.Collections.Generic.List[string]]::new()

    # The command printed for copying: the repository name when it resolves under ROOTPATH
    # (portable, and what the brief is committed with), otherwise the path as typed.
    $pathArg = if ($Global:ROOTPATH -and (Join-Path $Global:ROOTPATH $repoName) -eq $repo) { $repoName } else { Format-OctoAgentDocsArgument -Value $Path }
    $checkCmd = "Test-OctoAgentDocs -Path $pathArg"

    # CLAUDE.md is one of: absent, shim, thin (comments and at most one @import, not the
    # shim), real. Whether it IS the shim is the checker's verdict when a check ran.
    function Get-ClaudeState {
        param($Check)
        if (-not (Test-Path -LiteralPath $claudePath)) { return 'absent' }
        $text = Read-OctoAgentDocsText $claudePath
        $isShim = if ($Check) { $Check.data.shim -eq 'ok' } else { $text.Trim() -ceq ($shimLines -join "`n") }
        if ($isShim) { return 'shim' }
        if (Test-OctoAgentDocsShimLike $text) { return 'thin' }
        return 'real'
    }
    $hasChecker = [bool](Get-Command Test-OctoAgentDocs -ErrorAction SilentlyContinue)
    function Invoke-Check {
        # The checklist wants the check's data, never its gate.
        param([switch]$Fix)
        if (-not $hasChecker) { return $null }
        try { return ((Test-OctoAgentDocs -Path $repo -Mode logOnly -Json -Fix:$Fix 3>$null 6>$null) | ConvertFrom-Json) } catch { return $null }
    }

    # ----------------------------------------------------------------- actions
    $check = $null
    $hasAgents = Test-Path -LiteralPath $agentsPath
    $claudeBefore = Get-ClaudeState
    if ($hasAgents) {
        $check = Invoke-Check
        $state = if ((Test-Path -LiteralPath $briefPath) -or (Get-ClaudeState -Check $check) -ne 'shim') { 'migrating' } else { 'migrated' }
    }
    elseif ($claudeBefore -eq 'real') {
        $state = 'migration'
        if (-not (Test-Path -LiteralPath $briefPath) -and $PSCmdlet.ShouldProcess($briefName, 'Write the migration brief')) {
            Write-OctoAgentDocsText $briefPath (Format-MigrationBrief -Repo $repoName -PathArgument $pathArg -Config $config)
            $written.Add($briefName)
        }
    }
    else {
        $state = 'created'
        $skeleton = "# $repoName`n`n" + (@(for ($i = 0; $i -lt $sections.Count; $i++) { "## $($sections[$i])`n`n" + $(if ($i -eq 0) { "$(Get-OctoAgentDocsConstant RoutingStart)`n$(Get-OctoAgentDocsConstant RoutingEnd)`n`n" }) }) -join '')
        if ($PSCmdlet.ShouldProcess('AGENTS.md', 'Write the entry point with the required sections and routing markers')) { Write-OctoAgentDocsText $agentsPath $skeleton; $written.Add('AGENTS.md') }
        # A thin existing CLAUDE.md is still somebody's pointer; replacing it is what
        # Test-OctoAgentDocs -Fix is for, with its guard and its -WhatIf.
        if ($claudeBefore -eq 'absent' -and $PSCmdlet.ShouldProcess('CLAUDE.md', 'Write the AGENTS.md shim')) { Write-OctoAgentDocsText $claudePath (($shimLines -join "`n") + "`n"); $written.Add('CLAUDE.md') }
        # One -Fix pass fills the empty routing table, safe because -Fix never touches a
        # CLAUDE.md that already is the shim.
        if ($written.Contains('AGENTS.md') -and (Get-ClaudeState) -eq 'shim') { $check = Invoke-Check -Fix }
    }

    # --------------------------------------------------------------- checklist
    # Read off the repository after any writes. done: $true (check mark), $false (cross,
    # work left) or $null (dot, not applicable yet).
    $hasAgentsNow = Test-Path -LiteralPath $agentsPath
    $hasBriefNow = Test-Path -LiteralPath $briefPath
    $claudeNow = Get-ClaudeState -Check $check
    $rows = [System.Collections.Generic.List[object]]::new()
    function Add-Row { param([string]$Item, $Done, [string]$Fact) $rows.Add([ordered]@{ item = $Item; done = $Done; fact = $Fact }) }
    $wouldWrite = $whatIf -and $state -eq 'created'

    if ($hasAgentsNow) { Add-Row 'AGENTS.md' $true 'present' } elseif ($wouldWrite) { Add-Row 'AGENTS.md' $null 'would be written' } else { Add-Row 'AGENTS.md' $false 'absent' }
    switch ($claudeNow) {
        'shim' { Add-Row 'CLAUDE.md' $true 'shim' }
        'thin' { Add-Row 'CLAUDE.md' $false 'no real content, but not the shim' }
        'real' { Add-Row 'CLAUDE.md' $false 'real content' }
        default { if ($wouldWrite) { Add-Row 'CLAUDE.md' $null 'would be written' } else { Add-Row 'CLAUDE.md' $false 'absent' } }
    }
    if ($check) { $n = @($check.data.routes).Count; if ($n -gt 0) { Add-Row 'docs/' $true "$n routed" } else { Add-Row 'docs/' $null 'none yet' } }
    elseif (-not $hasAgentsNow) { Add-Row 'docs/' $null 'not read until AGENTS.md exists' }
    else { Add-Row 'docs/' $null "not read - $(if ($hasChecker) { 'the check failed' } else { 'checker not loaded' })" }
    if ($hasBriefNow -and $written.Contains($briefName)) { Add-Row $briefName $null 'written - delete it when the migration is done' }
    elseif ($hasBriefNow) { Add-Row $briefName $false 'present' }
    elseif ($whatIf -and $state -eq 'migration') { Add-Row $briefName $null 'would be written' }
    else { Add-Row $briefName $true 'absent' }
    $stale = @(); $other = @()
    if ($check) {
        $stale = @($check.data.findings | Where-Object { $_.rule -in 'routing-current', 'shim-valid' })
        $other = @($check.data.findings | Where-Object { $_.rule -notin 'routing-current', 'shim-valid', 'migration-pending' })
        $e = $check.data.summary.errors; $w = $check.data.summary.warnings
        if ($e -eq 0 -and $w -eq 0) { Add-Row 'check' $true 'clean' } else { Add-Row 'check' $false "$e error(s), $w warning(s)" }
    }
    elseif (-not $hasAgentsNow) { Add-Row 'check' $null 'not run until AGENTS.md exists' }
    else { Add-Row 'check' $null "$(if ($hasChecker) { 'failed - run it directly to see why' } else { 'not run - checker not loaded' })" }

    # -------------------------------------------------------------- next steps
    $next = [System.Collections.Generic.List[object]]::new()
    function Add-Next {
        # A command is printed once; a later step that would repeat it keeps only its text.
        param([string]$What, [string]$Command)
        if ($Command -and ($next | Where-Object { $_.command -eq $Command })) { $Command = $null }
        $next.Add([ordered]@{ what = $What; command = $Command })
    }
    if ($state -eq 'migration') {
        Add-Next "Open $briefName with your coding agent and follow its steps"
        Add-Next 'Check after every step' $checkCmd
        Add-Next "Delete $briefName in the migration commit"
    }
    else {
        if ($claudeNow -eq 'real') { Add-Next 'Move the remaining content out of CLAUDE.md into AGENTS.md or docs/, then let -Fix write the shim' "$checkCmd -Fix" }
        elseif ($claudeNow -eq 'thin' -and $hasAgentsNow) { Add-Next 'Replace the existing CLAUDE.md with the shim and fill the routing table' "$checkCmd -Fix" }
        if ($hasBriefNow) { Add-Next "Finish the steps in $briefName and delete it" }
        if ($stale.Count -gt 0 -and $claudeNow -ne 'real') { Add-Next 'Regenerate the routing table and the shim' "$checkCmd -Fix" }
        if ($other.Count -gt 0) { Add-Next "Resolve $($other.Count) open finding(s)" "$checkCmd -Explain" }
        if (-not $hasChecker) { Add-Next 'Import Test-OctoAgentDocs.psm1 and check the repository' $checkCmd }
        if ($state -eq 'created') {
            Add-Next 'Write the AGENTS.md sections; the checker reports a missing one but never writes it'
            Add-Next "Add docs/<topic>.md with 'description' and 'applies_to' frontmatter, then regenerate the table" "$checkCmd -Fix"
        }
    }

    # ------------------------------------------------------------------ output
    $open = @($rows | Where-Object { $_.done -eq $false }).Count
    if ($Json) {
        Write-OctoJson -Command 'Initialize-OctoAgentDocs' -Data (New-OctoActionResult -Success ($open -eq 0) -ExitCode 0 -Extra ([ordered]@{
            repository = $repoName; state = $state; checklist = @($rows); filesWritten = @($written); nextSteps = @($next)
        }))
        return
    }
    Write-Host "Agent docs init: $repoName - " -ForegroundColor Yellow -NoNewline
    Write-Host $state -ForegroundColor $(if ($open -eq 0) { 'Green' } else { 'DarkYellow' })
    if ($written.Count -gt 0) { Write-Host "  wrote $($written -join ', ')" -ForegroundColor Cyan }
    foreach ($row in $rows) {
        # Check mark, cross and middle dot as code points so the file stays ASCII.
        $mark, $colour = switch ($row.done) { $true { [string][char]0x2713, 'Green' } $false { [string][char]0x2717, 'DarkYellow' } default { [string][char]0x00B7, 'DarkGray' } }
        Write-Host "  $mark " -ForegroundColor $colour -NoNewline
        Write-Host $row.item.PadRight(21) -ForegroundColor Gray -NoNewline
        Write-Host $row.fact -ForegroundColor $(if ($row.done -eq $false) { 'DarkYellow' } else { 'Gray' })
    }
    foreach ($step in $next) {
        Write-Host "  next: $($step.what)" -ForegroundColor Gray
        if ($step.command) { Write-Host "        $($step.command)" -ForegroundColor White }
    }
}

function Format-MigrationBrief {
    # Renders agent-docs-migration.template.md with the values the ruleset enforces.
    param([string]$Repo, [string]$PathArgument, [hashtable]$Config)
    $templatePath = Join-Path $PSScriptRoot 'agent-docs-migration.template.md'
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Migration brief template missing at $templatePath" }
    function Sev { param([string]$Id) [string]$Config.rules[$Id][0] }

    $budgetRows = @(
        @{ label = 'AGENTS.md lines'; rule = 'entry-point-lines'; option = 'max' }
        @{ label = 'AGENTS.md characters'; rule = 'entry-point-characters'; option = 'max' }
        @{ label = 'Line length in AGENTS.md'; rule = 'line-length'; option = 'max' }
        @{ label = 'Characters per docs/*.md'; rule = 'doc-size'; option = 'maxCharacters' }
        @{ label = 'Routed docs'; rule = 'docs-count'; option = 'max' }
        @{ label = 'Frontmatter description characters'; rule = 'frontmatter-present'; option = 'maxDescription' }
    )
    $budgets = @('| Budget | Limit | Severity | Rule |', '|---|---|---|---|') + @(foreach ($row in $budgetRows) {
        $limit = $Config.rules[$row.rule][1][$row.option]
        if ($null -ne $limit) { "| $($row.label) | $limit | $(Sev $row.rule) | ``$($row.rule)`` |" }
    })
    # Rules grouped by tier: the brief says "fix in this order", like the report.
    $active = @($Config.rules.Keys | Where-Object { (Sev $_) -ne 'off' })
    $rules = @(foreach ($tier in @($active | ForEach-Object { Get-OctoAgentDocsRuleTier -Config $Config -Id $_ } | Sort-Object -Unique)) {
        Get-OctoAgentDocsTierHeading -Config $Config -Tier $tier -Markdown
        ''
        foreach ($id in $active) {
            if ((Get-OctoAgentDocsRuleTier -Config $Config -Id $id) -ne $tier) { continue }
            $d = $Config['ruleDocs'][$id]
            "- ``$id`` [$(Sev $id)]" + $(if ($d['why']) { " - $($d['why'])" }) + $(if ($d['fix']) { " Fix: $($d['fix'])" })
        }
        ''
    })
    $values = @{
        REPO         = $Repo
        PATH         = $PathArgument
        DATE         = (Get-Date).ToString('yyyy-MM-dd')
        BRIEF        = Get-OctoAgentDocsConstant BriefName
        START_MARKER = Get-OctoAgentDocsConstant RoutingStart
        END_MARKER   = Get-OctoAgentDocsConstant RoutingEnd
        SHIM         = (@($Config.rules['shim-valid'][1]['content']) | ForEach-Object { "                   $_" }) -join "`n"
        SECTIONS     = (@($Config.rules['required-sections'][1]['sections']) | ForEach-Object { "- ``## $_``" }) -join "`n"
        BUDGETS      = $budgets -join "`n"
        RULES        = ($rules -join "`n").TrimEnd("`n")
    }
    $text = Read-OctoAgentDocsText $templatePath
    foreach ($k in $values.Keys) { $text = $text.Replace("{{$k}}", [string]$values[$k]) }
    return $text
}

Export-ModuleMember -Function @('Initialize-OctoAgentDocs')
