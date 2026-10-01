function Initialize-OctoAgentDocs {
    <#
    .SYNOPSIS
    Gives a repository the minimal agent-docs shape, or a migration brief when it already has
    a hand-written CLAUDE.md.

    .DESCRIPTION
    Four states, decided from what is already in the repository, and the cmdlet never
    overwrites a file in any of them:

      migrated     AGENTS.md exists, CLAUDE.md is the shim and no migration brief is left.
                   Nothing is written. The status block shows what the check sees and the
                   next step follows from it: -Fix when a generated region is stale,
                   -Explain when something else is open, otherwise nothing.
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

    $status = $null
    if ($hasAgents) {
        # Nothing to scaffold. What the user wants to know here is whether the migration
        # is FINISHED, so the answer is a status block read off the repository and the
        # check, and the next step follows from it - suggesting -Fix to a repository whose
        # generated regions are current would imply something is stale.
        $hasBrief = Test-Path -LiteralPath $briefPath
        $check = $null
        if ($hasChecker) { $check = try { (Test-OctoAgentDocs -Path $repo -Json 3>$null 6>$null) | ConvertFrom-Json } catch { $null } }
        $claudeState = if (-not $hasClaude) { 'absent' } elseif ($claudeIsShimLike) { 'shim' } else { 'real content' }
        $state = if ($hasBrief -or $claudeState -eq 'real content') { 'migrating' } else { 'migrated' }
        $status = [ordered]@{
            entryPoint = 'canonical entry point'
            claudeMd   = $claudeState
            routedDocs = if ($check) { @($check.data.routes).Count } else { $null }
            brief      = if ($hasBrief) { 'present' } else { 'absent' }
            check      = if (-not $check) { 'not run' }
                         elseif ($check.data.summary.errors -eq 0 -and $check.data.summary.warnings -eq 0) { 'clean' }
                         else { "$($check.data.summary.errors) error(s), $($check.data.summary.warnings) warning(s)" }
        }
        if ($claudeState -eq 'real content') { Add-Next 'Move the remaining content out of CLAUDE.md into AGENTS.md or docs/, then let -Fix write the shim' "$checkCmd -Fix" }
        if ($hasBrief) { Add-Next "Finish the steps in $briefName and delete it" $null }
        if ($null -eq $check) {
            Add-Next 'Check the repository' $checkCmd
        }
        else {
            $stale = @($check.data.findings | Where-Object { $_.rule -in @('routing-current', 'shim-valid') })
            $other = @($check.data.findings | Where-Object { $_.rule -notin @('routing-current', 'shim-valid', 'migration-pending') })
            if ($stale.Count -gt 0 -and $claudeState -ne 'real content') { Add-Next 'Regenerate the routing table and the shim' "$checkCmd -Fix" }
            if ($other.Count -gt 0) { Add-Next "Resolve $($other.Count) open finding(s)" "$checkCmd -Explain" }
            if ($state -eq 'migrated' -and $stale.Count -eq 0 -and $other.Count -eq 0) { Add-Next 'Migration complete - nothing to do' $null }
        }
    }
    elseif (-not $claudeIsShimLike) {
        $state = 'migration'
        if (Test-Path -LiteralPath $briefPath) {
            Add-Next "$briefName already exists - continue with its steps" $null
        }
        elseif ($PSCmdlet.ShouldProcess($briefName, 'Write the migration brief')) {
            Write-Text $briefPath (New-MigrationBrief -Repo $repoName -Config $config -Sections $sections -ShimLines $shimLines)
            $written.Add($briefName)
        }
        Add-Next "Open $briefName with your coding agent and follow its steps" $null
        Add-Next 'Check after every step' $checkCmd
        Add-Next "Delete $briefName in the migration commit" $null
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
        if ($written.Contains('AGENTS.md')) {
            # Fills the (empty) routing table so the first check is clean. Quiet: the
            # summary below is the report. The checker ships beside this module, but a
            # standalone import is possible, so its absence is a next step, not a crash.
            if ($hasChecker) { $null = Test-OctoAgentDocs -Path $repo -Fix -Json 3>$null 6>$null }
            else { Add-Next 'Import Test-OctoAgentDocs.psm1 and fill the routing table' "$checkCmd -Fix" }
        }
        Add-Next 'Write the sections in AGENTS.md; the checker reports a missing one, never fills it' $null
        Add-Next "Add docs/<topic>.md with 'description' and 'applies_to' frontmatter, then regenerate the table" "$checkCmd -Fix"
    }

    # ------------------------------------------------------------------ output
    if ($Json) {
        Write-OctoJson -Command 'Initialize-OctoAgentDocs' -Data ([ordered]@{
            repository   = $repoName
            state        = $state
            status       = $status
            filesWritten = @($written)
            nextSteps    = @($next)
        })
        return
    }
    $stateColour = switch ($state) { 'migrated' { 'Green' } 'migrating' { 'DarkYellow' } 'migration' { 'DarkYellow' } default { 'Cyan' } }
    Write-Host "Agent docs init: $repoName - " -ForegroundColor Yellow -NoNewline
    Write-Host $state -ForegroundColor $stateColour
    if ($status) {
        Write-Host "  AGENTS.md            $($status.entryPoint)" -ForegroundColor Gray
        Write-Host "  CLAUDE.md            $($status.claudeMd)" -ForegroundColor $(if ($status.claudeMd -eq 'shim') { 'Gray' } else { 'DarkYellow' })
        if ($null -ne $status.routedDocs) { Write-Host "  docs/                $($status.routedDocs) routed" -ForegroundColor Gray }
        Write-Host "  $briefName".PadRight(23) -ForegroundColor Gray -NoNewline
        Write-Host $status.brief -ForegroundColor $(if ($status.brief -eq 'absent') { 'Gray' } else { 'DarkYellow' })
        Write-Host "  check                $($status.check)" -ForegroundColor $(if ($status.check -eq 'clean') { 'Gray' } else { 'DarkYellow' })
    }
    if ($written.Count -gt 0) { Write-Host "  wrote $($written -join ', ')" -ForegroundColor Cyan }
    elseif (-not $WhatIfPreference -and -not $status) { Write-Host "  nothing written" -ForegroundColor Cyan }
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

    $docs = if ($Config['ruleDocs'] -is [hashtable]) { $Config['ruleDocs'] } else { @{} }
    $rules = [System.Text.StringBuilder]::new()
    foreach ($id in $Config.rules.Keys) {
        $sev = Sev $id
        if ($sev -eq 'off') { continue }
        $d = if ($docs[$id] -is [hashtable]) { $docs[$id] } else { @{} }
        [void]$rules.Append("- ``$id`` [$sev]")
        if ($d['why']) { [void]$rules.Append(" - $($d['why'])") }
        if ($d['fix']) { [void]$rules.Append(" Fix: $($d['fix'])") }
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
