function Initialize-OctoAgentDocs {
    <#
    .SYNOPSIS
    Gives a repository the minimal agent-docs shape, or a migration brief when it already has
    a hand-written CLAUDE.md.

    .DESCRIPTION
    Every run ends with the same five-row checklist - AGENTS.md, CLAUDE.md, docs/, the
    migration brief, the check - marked done (✓), open (✗) or not applicable yet (·), and
    the next steps are derived from the open rows. Four states, decided from what is
    already in the repository, and the cmdlet never overwrites a file in any of them:

      migrated     AGENTS.md exists, CLAUDE.md is the shim and no migration brief is left.
                   Nothing is written. The next step follows from the check: -Fix when a
                   generated region is stale, -Explain when something else is open,
                   otherwise none.
      migrating    AGENTS.md exists but CLAUDE.md still has real content, or the
                   migration brief is still present. Nothing is written; the next steps
                   name what is left.
      migration    no AGENTS.md, but a CLAUDE.md with real content. Only
                   AGENTS-MIGRATION.md is written: a brief for the coding agent and the
                   developer doing the migration, rendered from the ruleset so it carries
                   the budgets, the required sections and the shim text as enforced.
                   Test-OctoAgentDocs warns while the brief exists (migration-pending).
      created      neither file, or only a shim-like CLAUDE.md. AGENTS.md is written with the
                   required sections and the routing markers, CLAUDE.md with the shim, and
                   Test-OctoAgentDocs -Fix fills the routing table. No docs/ folder and no
                   .agent-docs.json: the first routed doc creates the folder, and an override
                   file is something a repository adds when it has a reason.

    Section names, the shim text and the budgets come from the BUILT-IN ruleset shipped with
    octo-tools, not from a repository override: a repository being initialised has no
    override yet, and a repository being migrated should see the org defaults it will be
    held to.

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
    param(
        [string]$Path = ".",
        [switch]$Json
    )

    $ErrorActionPreference = 'Stop'

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
    $repoName = Split-Path -Leaf $repo

    # ------------------------------------------------------------------ ruleset
    $rulesPath = Join-Path $PSScriptRoot 'agent-docs.rules.json'
    if (-not (Test-Path -LiteralPath $rulesPath)) { throw "Built-in ruleset missing at $rulesPath" }
    $config = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json -AsHashtable

    function Get-RuleOptions {
        param([string]$Id)
        $r = $config.rules[$Id]
        if ($r -is [string]) { return @{} }
        if ($r.Count -gt 1 -and $r[1] -is [hashtable]) { return $r[1] }
        return @{}
    }
    function Get-RuleSeverity {
        param([string]$Id)
        $r = $config.rules[$Id]
        if ($r -is [string]) { return $r }
        return [string]$r[0]
    }

    $sections = @((Get-RuleOptions 'required-sections')['sections'])
    if ($sections.Count -eq 0) { $sections = @('Read before you change', 'Build & test', 'Before you commit', 'Rules') }
    $shimLines = @((Get-RuleOptions 'shim-valid')['content'])
    if ($shimLines.Count -eq 0) { $shimLines = @('@AGENTS.md') }
    $briefName = [string]((Get-RuleOptions 'migration-pending')['file'])
    if (-not $briefName) { $briefName = 'AGENTS-MIGRATION.md' }
    $startMarker = '<!-- >>> generated: routing -->'
    $endMarker = '<!-- <<< end generated: routing -->'

    function Write-Text {
        param([string]$P, [string]$Content)
        [System.IO.File]::WriteAllText($P, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    # Same test as Test-OctoAgentDocs uses before it will replace a CLAUDE.md: nothing but
    # HTML comments and at most one @import line means nobody's work is in the file.
    function Test-IsShimLike {
        param([string]$Content)
        $lines = @(($Content -replace "`r`n", "`n") -replace "`r", "`n" -split "`n")
        $meaningful = @($lines | Where-Object { $_.Trim() -ne '' -and $_.Trim() -notmatch '^<!--.*-->$' })
        if ($meaningful.Count -eq 0) { return $true }
        return ($meaningful.Count -eq 1 -and $meaningful[0].Trim() -match '^@\S+$')
    }

    # ------------------------------------------------------------------ state
    $agentsPath = Join-Path $repo 'AGENTS.md'
    $claudePath = Join-Path $repo 'CLAUDE.md'
    $briefPath = Join-Path $repo $briefName
    $hasAgents = Test-Path -LiteralPath $agentsPath
    $hasClaude = Test-Path -LiteralPath $claudePath
    $claudeIsShimLike = (-not $hasClaude) -or (Test-IsShimLike ([System.IO.File]::ReadAllText($claudePath)))

    $written = [System.Collections.Generic.List[string]]::new()
    # Each next step is what to do and, when there is one, the command that does it, kept
    # apart so the command is clean to copy and the text is not mistaken for syntax.
    $next = [System.Collections.Generic.List[object]]::new()
    function Add-Next { param([string]$What, [string]$Command) $next.Add([ordered]@{ what = $What; command = $Command }) }
    $checkCmd = "Test-OctoAgentDocs -Path $Path"
    $hasChecker = [bool](Get-Command Test-OctoAgentDocs -ErrorAction SilentlyContinue)

    # ----------------------------------------------------------------- actions
    $hasBrief = Test-Path -LiteralPath $briefPath
    $claudeState = if (-not $hasClaude) { 'absent' } elseif ($claudeIsShimLike) { 'shim' } else { 'real content' }

    if ($hasAgents) {
        # Nothing to scaffold; the checklist below says whether the migration is finished.
        $state = if ($hasBrief -or $claudeState -eq 'real content') { 'migrating' } else { 'migrated' }
    }
    elseif ($claudeState -eq 'real content') {
        $state = 'migration'
        if (-not $hasBrief -and $PSCmdlet.ShouldProcess($briefName, 'Write the migration brief')) {
            Write-Text $briefPath (New-MigrationBrief -Repo $repoName -Config $config -Sections $sections -ShimLines $shimLines)
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
            Write-Text $agentsPath ($sb.ToString())
            $written.Add('AGENTS.md')
        }
        if ($PSCmdlet.ShouldProcess('CLAUDE.md', 'Write the AGENTS.md shim')) {
            Write-Text $claudePath (($shimLines -join "`n") + "`n")
            $written.Add('CLAUDE.md')
        }
        # Fills the (empty) routing table so the first check is clean. Quiet: the checklist
        # below is the report. The checker ships beside this module, but a standalone
        # import is possible, so its absence is a row in the list, not a crash.
        if ($written.Contains('AGENTS.md') -and $hasChecker) { $null = Test-OctoAgentDocs -Path $repo -Fix -Json 3>$null 6>$null }
    }

    # --------------------------------------------------------------- checklist
    # The same five rows in every state, read off the repository AFTER any writes, so the
    # list shows the result rather than the plan. Under -WhatIf nothing was written and the
    # rows say what would happen. done is $true (✓), $false (✗, work left) or $null (·, not
    # applicable yet), and the next steps are derived from the ✗ rows.
    $whatIf = [bool]$WhatIfPreference
    $hasAgentsNow = Test-Path -LiteralPath $agentsPath
    $hasBriefNow = Test-Path -LiteralPath $briefPath
    $claudeNow = if (-not (Test-Path -LiteralPath $claudePath)) { 'absent' }
                 elseif (Test-IsShimLike ([System.IO.File]::ReadAllText($claudePath))) { 'shim' }
                 else { 'real content' }
    $check = $null
    if ($hasAgentsNow -and $hasChecker) { $check = try { (Test-OctoAgentDocs -Path $repo -Json 3>$null 6>$null) | ConvertFrom-Json } catch { $null } }

    $rows = [System.Collections.Generic.List[object]]::new()
    function Add-Row { param([string]$Item, $Done, [string]$Fact) $rows.Add([ordered]@{ item = $Item; done = $Done; fact = $Fact }) }

    if ($hasAgentsNow) { Add-Row 'AGENTS.md' $true 'present' }
    elseif ($state -eq 'created' -and $whatIf) { Add-Row 'AGENTS.md' $null 'would be written' }
    else { Add-Row 'AGENTS.md' $false 'absent' }

    switch ($claudeNow) {
        'shim' { Add-Row 'CLAUDE.md' $true 'shim' }
        'real content' { Add-Row 'CLAUDE.md' $false 'real content' }
        default { if ($state -eq 'created' -and $whatIf) { Add-Row 'CLAUDE.md' $null 'would be written' } else { Add-Row 'CLAUDE.md' $false 'absent' } }
    }

    if ($check) {
        $n = @($check.data.routes).Count
        if ($n -gt 0) { Add-Row 'docs/' $true "$n routed" } else { Add-Row 'docs/' $null 'none yet' }
    }
    elseif (-not $hasAgentsNow) { Add-Row 'docs/' $null 'not read until AGENTS.md exists' }
    else { Add-Row 'docs/' $null 'not read - checker not loaded' }

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
    else { Add-Row 'check' $null 'not run - checker not loaded' }

    # -------------------------------------------------------------- next steps
    switch ($state) {
        'created' {
            if (-not $hasChecker) { Add-Next 'Import Test-OctoAgentDocs.psm1 and fill the routing table' "$checkCmd -Fix" }
            Add-Next 'Write the sections in AGENTS.md; the checker reports a missing one, never fills it' $null
            Add-Next "Add docs/<topic>.md with 'description' and 'applies_to' frontmatter, then regenerate the table" "$checkCmd -Fix"
        }
        'migration' {
            Add-Next "Open $briefName with your coding agent and follow its steps" $null
            Add-Next 'Check after every step' $checkCmd
            Add-Next "Delete $briefName in the migration commit" $null
        }
        default {
            if ($claudeNow -eq 'real content') { Add-Next 'Move the remaining content out of CLAUDE.md into AGENTS.md or docs/, then let -Fix write the shim' "$checkCmd -Fix" }
            if ($hasBriefNow) { Add-Next "Finish the steps in $briefName and delete it" $null }
            if ($stale.Count -gt 0 -and $claudeNow -ne 'real content') { Add-Next 'Regenerate the routing table and the shim' "$checkCmd -Fix" }
            if ($other.Count -gt 0) { Add-Next "Resolve $($other.Count) open finding(s)" "$checkCmd -Explain" }
            if (-not $check -and $hasChecker -eq $false) { Add-Next 'Import Test-OctoAgentDocs.psm1 and check the repository' $checkCmd }
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
    $stateColour = switch ($state) { 'migrated' { 'Green' } 'created' { 'Green' } default { 'DarkYellow' } }
    Write-Host "Agent docs init: $repoName - " -ForegroundColor Yellow -NoNewline
    Write-Host $state -ForegroundColor $stateColour
    if ($written.Count -gt 0) { Write-Host "  wrote $($written -join ', ')" -ForegroundColor Cyan }
    foreach ($row in $rows) {
        $mark, $colour = switch ($row.done) { $true { '✓', 'Green' } $false { '✗', 'DarkYellow' } default { '·', 'DarkGray' } }
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
# the brief an agent reads carries the same numbers the checker will hold it to.
function New-MigrationBrief {
    param([string]$Repo, [hashtable]$Config, [string[]]$Sections, [string[]]$ShimLines)

    $templatePath = Join-Path $PSScriptRoot 'agent-docs-migration.template.md'
    if (-not (Test-Path -LiteralPath $templatePath)) { throw "Migration brief template missing at $templatePath" }
    $t = [System.IO.File]::ReadAllText($templatePath)

    function Opt { param([string]$Id, [string]$Name)
        $r = $Config.rules[$Id]
        if ($r -is [string] -or $r.Count -lt 2 -or $r[1] -isnot [hashtable]) { return $null }
        return $r[1][$Name]
    }
    function Sev { param([string]$Id) $r = $Config.rules[$Id]; if ($r -is [string]) { $r } else { [string]$r[0] } }

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
    $tiers = if ($Config['tiers'] -is [hashtable]) { $Config['tiers'] } else { @{} }
    $rules = [System.Text.StringBuilder]::new()
    $active = @($Config.rules.Keys | Where-Object { (Sev $_) -ne 'off' })
    foreach ($tierNo in @($active | ForEach-Object { $d = $docs[$_]; if ($d -is [hashtable] -and $d['tier']) { [int]$d['tier'] } else { 4 } } | Sort-Object -Unique)) {
        $info = $tiers["$tierNo"]
        $title = if ($info -is [hashtable] -and $info['title']) { $info['title'] } else { "Tier $tierNo" }
        $why = if ($info -is [hashtable] -and $info['why']) { " - $($info['why'])" } else { '' }
        [void]$rules.Append("**$tierNo. $title**$why`n`n")
        foreach ($id in $active) {
            $d = if ($docs[$id] -is [hashtable]) { $docs[$id] } else { @{} }
            $rt = if ($d['tier']) { [int]$d['tier'] } else { 4 }
            if ($rt -ne $tierNo) { continue }
            [void]$rules.Append("- ``$id`` [$(Sev $id)]")
            if ($d['why']) { [void]$rules.Append(" - $($d['why'])") }
            if ($d['fix']) { [void]$rules.Append(" Fix: $($d['fix'])") }
            [void]$rules.Append("`n")
        }
        [void]$rules.Append("`n")
    }

    $t = $t.Replace('{{REPO}}', $Repo)
    $t = $t.Replace('{{DATE}}', (Get-Date).ToString('yyyy-MM-dd'))
    $t = $t.Replace('{{SHIM}}', $shim)
    $t = $t.Replace('{{SECTIONS}}', $sectionList)
    $t = $t.Replace('{{BUDGETS}}', $budgets.ToString().TrimEnd("`n"))
    $t = $t.Replace('{{RULES}}', $rules.ToString().TrimEnd("`n"))
    return $t
}

Export-ModuleMember -Function @('Initialize-OctoAgentDocs')
