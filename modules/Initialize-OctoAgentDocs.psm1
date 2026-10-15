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
    $shim = @($config.rules['shim-valid'][1]['content']) -join "`n"
    $briefName = Get-OctoAgentDocsConstant BriefName
    $agentsPath = Join-Path $repo 'AGENTS.md'
    $claudePath = Join-Path $repo 'CLAUDE.md'
    $briefPath = Join-Path $repo $briefName
    $written = [System.Collections.Generic.List[string]]::new()

    # Commands printed for copying use the path as typed. The brief is committed and read
    # inside the repository, so it gets the repository name under ROOTPATH, otherwise '.'.
    $checkCmd = "Test-OctoAgentDocs -Path $(Format-OctoAgentDocsArgument -Value $Path)"
    $briefPathArg = if ($Global:ROOTPATH -and (Join-Path $Global:ROOTPATH $repoName) -eq $repo) { $repoName } else { '.' }

    $check = $null
    $claudeBefore = Get-ClaudeState -ClaudePath $claudePath -Shim $shim
    if (Test-Path -LiteralPath $agentsPath) {
        $check = Invoke-AgentDocsCheck -Root $repo
        $state = if ((Test-Path -LiteralPath $briefPath) -or (Get-ClaudeState -ClaudePath $claudePath -Shim $shim -Check $check) -ne 'shim') { 'migrating' } else { 'migrated' }
    }
    elseif ($claudeBefore -eq 'real') {
        $state = 'migration'
        if (-not (Test-Path -LiteralPath $briefPath) -and $PSCmdlet.ShouldProcess($briefName, 'Write the migration brief')) {
            Write-OctoAgentDocsText $briefPath (Format-MigrationBrief -Repo $repoName -PathArgument $briefPathArg -Config $config)
            $written.Add($briefName)
        }
    }
    else {
        $state = 'created'
        $skeleton = "# $repoName`n`n" + (@(for ($i = 0; $i -lt $sections.Count; $i++) { "## $($sections[$i])`n`n" + $(if ($i -eq 0) { "$(Get-OctoAgentDocsConstant RoutingStart)`n$(Get-OctoAgentDocsConstant RoutingEnd)`n`n" }) }) -join '')
        if ($PSCmdlet.ShouldProcess('AGENTS.md', 'Write the entry point with the required sections and routing markers')) { Write-OctoAgentDocsText $agentsPath $skeleton; $written.Add('AGENTS.md') }
        # A thin existing CLAUDE.md is still somebody's pointer; replacing it is what
        # Test-OctoAgentDocs -Fix is for, with its guard and its -WhatIf.
        if ($claudeBefore -eq 'absent' -and $PSCmdlet.ShouldProcess('CLAUDE.md', 'Write the AGENTS.md shim')) { Write-OctoAgentDocsText $claudePath "$shim`n"; $written.Add('CLAUDE.md') }
        # One -Fix pass fills the empty routing table, safe because -Fix never touches a
        # CLAUDE.md that already is the shim; with a thin CLAUDE.md the check only reads.
        if ($written.Contains('AGENTS.md')) { $check = Invoke-AgentDocsCheck -Root $repo -Fix:((Get-ClaudeState -ClaudePath $claudePath -Shim $shim) -eq 'shim') }
    }

    # Read off the repository after any writes.
    $facts = @{
        State      = $state
        HasAgents  = Test-Path -LiteralPath $agentsPath
        HasBrief   = Test-Path -LiteralPath $briefPath
        Claude     = Get-ClaudeState -ClaudePath $claudePath -Shim $shim -Check $check
        Check      = $check
        HasChecker = [bool](Get-Command Test-OctoAgentDocs -ErrorAction SilentlyContinue)
        WhatIf     = [bool]$WhatIfPreference
        Written    = $written
        BriefName  = $briefName
    }
    $rows = Get-InitChecklist -Facts $facts
    $next = Get-InitNextStep -Facts $facts -CheckCommand $checkCmd
    $open = @($rows | Where-Object { $_.done -eq $false }).Count
    if ($Json) {
        Write-OctoJson -Command 'Initialize-OctoAgentDocs' -Data (New-OctoActionResult -Success ($open -eq 0) -ExitCode 0 -Extra ([ordered]@{
            repository = $repoName; state = $state; checklist = @($rows); filesWritten = @($written); nextSteps = @($next)
        }))
        return
    }
    Write-InitReport -RepositoryName $repoName -State $state -Written $written -Row $rows -NextStep $next
}

function Get-ClaudeState {
    # CLAUDE.md is one of: absent, shim, thin (comments and at most one @import, not the
    # shim), real. Whether it IS the shim is the checker's verdict when a check ran.
    param([string]$ClaudePath, [string]$Shim, $Check)
    if (-not (Test-Path -LiteralPath $ClaudePath)) { return 'absent' }
    $text = Read-OctoAgentDocsText $ClaudePath
    $isShim = if ($Check) { $Check.data.shim -eq 'ok' } else { $text.Trim() -ceq $Shim }
    if ($isShim) { return 'shim' }
    if (Test-OctoAgentDocsShimLike $text) { return 'thin' }
    return 'real'
}

function Invoke-AgentDocsCheck {
    # The check's data, never its gate; $null when the checker is not loaded or fails.
    param([string]$Root, [switch]$Fix)
    if (-not (Get-Command Test-OctoAgentDocs -ErrorAction SilentlyContinue)) { return $null }
    try { return ((Test-OctoAgentDocs -Path $Root -Mode logOnly -Json -Fix:$Fix 3>$null 6>$null) | ConvertFrom-Json) } catch { return $null }
}

function Get-InitChecklist {
    # Five rows. done: $true (check mark), $false (cross, work left) or $null (dot, not
    # applicable yet).
    param([hashtable]$Facts)
    $wouldWrite = $Facts.WhatIf -and $Facts.State -eq 'created'
    $check = $Facts.Check
    $notRead = if ($Facts.HasChecker) { 'the check failed' } else { 'checker not loaded' }
    $row = { param($Item, $Done, $Fact) [ordered]@{ item = $Item; done = $Done; fact = $Fact } }

    if ($Facts.HasAgents) { & $row 'AGENTS.md' $true 'present' } elseif ($wouldWrite) { & $row 'AGENTS.md' $null 'would be written' } else { & $row 'AGENTS.md' $false 'absent' }
    switch ($Facts.Claude) {
        'shim' { & $row 'CLAUDE.md' $true 'shim' }
        'thin' { & $row 'CLAUDE.md' $false 'no real content, but not the shim' }
        'real' { & $row 'CLAUDE.md' $false 'real content' }
        default { if ($wouldWrite) { & $row 'CLAUDE.md' $null 'would be written' } else { & $row 'CLAUDE.md' $false 'absent' } }
    }
    $routed = if ($check) { @($check.data.routes).Count } else { 0 }
    if ($check -and $routed -gt 0) { & $row 'docs/' $true "$routed routed" }
    elseif ($check) { & $row 'docs/' $null 'none yet' }
    elseif (-not $Facts.HasAgents) { & $row 'docs/' $null 'not read until AGENTS.md exists' }
    else { & $row 'docs/' $null "not read - $notRead" }
    if ($Facts.HasBrief -and $Facts.Written.Contains($Facts.BriefName)) { & $row $Facts.BriefName $null 'written - delete it when the migration is done' }
    elseif ($Facts.HasBrief) { & $row $Facts.BriefName $false 'present' }
    elseif ($Facts.WhatIf -and $Facts.State -eq 'migration') { & $row $Facts.BriefName $null 'would be written' }
    else { & $row $Facts.BriefName $true 'absent' }
    $summary = if ($check) { $check.data.summary }
    if ($summary -and $summary.errors -eq 0 -and $summary.warnings -eq 0) { & $row 'check' $true 'clean' }
    elseif ($summary) { & $row 'check' $false "$($summary.errors) error(s), $($summary.warnings) warning(s)" }
    elseif (-not $Facts.HasAgents) { & $row 'check' $null 'not run until AGENTS.md exists' }
    elseif ($Facts.HasChecker) { & $row 'check' $null 'failed - run it directly to see why' }
    else { & $row 'check' $null 'not run - checker not loaded' }
}

function Get-InitNextStep {
    # What to do next, from the open rows. A command is printed once; a later step that would
    # repeat it keeps only its text.
    param([hashtable]$Facts, [string]$CheckCommand)
    $steps = [System.Collections.Generic.List[object]]::new()
    $add = {
        param([string]$What, [string]$Command)
        if ($Command -and ($steps | Where-Object { $_.command -eq $Command })) { $Command = $null }
        $steps.Add([ordered]@{ what = $What; command = $Command })
    }
    $brief = $Facts.BriefName
    if ($Facts.State -eq 'migration') {
        & $add "Open $brief with your coding agent and follow its steps"
        & $add 'Check after every step' $CheckCommand
        & $add "Delete $brief in the migration commit"
        return , $steps
    }
    $findings = if ($Facts.Check) { @($Facts.Check.data.findings) } else { @() }
    $stale = @($findings | Where-Object { $_.rule -in 'routing-current', 'shim-valid' })
    $other = @($findings | Where-Object { $_.rule -notin 'routing-current', 'shim-valid', 'migration-pending' })
    if ($Facts.Claude -eq 'real') { & $add 'Move the remaining content out of CLAUDE.md into AGENTS.md or docs/, then let -Fix write the shim' "$CheckCommand -Fix" }
    elseif ($Facts.Claude -eq 'thin' -and $Facts.HasAgents) { & $add 'Replace the existing CLAUDE.md with the shim and fill the routing table' "$CheckCommand -Fix" }
    if ($Facts.HasBrief) { & $add "Finish the steps in $brief and delete it" }
    if ($stale.Count -gt 0 -and $Facts.Claude -ne 'real') { & $add 'Regenerate the routing table and the shim' "$CheckCommand -Fix" }
    if ($other.Count -gt 0) { & $add "Resolve $($other.Count) open finding(s)" "$CheckCommand -Explain" }
    if (-not $Facts.HasChecker) { & $add 'Import Test-OctoAgentDocs.psm1 and check the repository' $CheckCommand }
    if ($Facts.State -eq 'created') {
        & $add 'Write the AGENTS.md sections; the checker reports a missing one but never writes it'
        & $add "Add docs/<topic>.md with 'description' and 'applies_to' frontmatter, then regenerate the table" "$CheckCommand -Fix"
    }
    return , $steps
}

function Write-InitReport {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Human report on the host, -Json on the pipeline: the octo-tools convention')]
    param([string]$RepositoryName, [string]$State, [string[]]$Written, [object[]]$Row, [object[]]$NextStep)
    $open = @($Row | Where-Object { $_.done -eq $false }).Count
    Write-Host "Agent docs init: $RepositoryName - " -ForegroundColor Yellow -NoNewline
    Write-Host $State -ForegroundColor $(if ($open -eq 0) { 'Green' } else { 'DarkYellow' })
    if ($Written.Count -gt 0) { Write-Host "  wrote $($Written -join ', ')" -ForegroundColor Cyan }
    foreach ($r in $Row) {
        # Check mark, cross and middle dot as code points so the file stays ASCII.
        $mark, $colour = switch ($r.done) { $true { [string][char]0x2713, 'Green' } $false { [string][char]0x2717, 'DarkYellow' } default { [string][char]0x00B7, 'DarkGray' } }
        Write-Host "  $mark " -ForegroundColor $colour -NoNewline
        Write-Host $r.item.PadRight(21) -ForegroundColor Gray -NoNewline
        Write-Host $r.fact -ForegroundColor $(if ($r.done -eq $false) { 'DarkYellow' } else { 'Gray' })
    }
    foreach ($step in $NextStep) {
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
