function Initialize-OctoAgentDocs {
    <#
    .SYNOPSIS
    Gives a repository the minimal agent-docs shape, or a migration brief when it already has
    a hand-written CLAUDE.md.

    .DESCRIPTION
    Three states, decided from what is already in the repository, and the cmdlet never
    overwrites a file in any of them:

      initialised  AGENTS.md exists. Nothing is written; the next step is
                   Test-OctoAgentDocs -Fix.
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
    $next = [System.Collections.Generic.List[string]]::new()

    if ($hasAgents) {
        $state = 'initialised'
        $next.Add("Test-OctoAgentDocs -Path $repoName -Fix   # regenerate the routing table and the shim")
        if (Test-Path -LiteralPath $briefPath) { $next.Add("Finish the steps in $briefName and delete it") }
    }
    elseif (-not $claudeIsShimLike) {
        $state = 'migration'
        if (Test-Path -LiteralPath $briefPath) {
            $next.Add("$briefName already exists - continue with its steps")
        }
        elseif ($PSCmdlet.ShouldProcess($briefName, 'Write the migration brief')) {
            Write-Text $briefPath (New-MigrationBrief -Repo $repoName -Config $config -Sections $sections -ShimLines $shimLines)
            $written.Add($briefName)
        }
        $next.Add("Open $briefName with your coding agent and follow its steps")
        $next.Add("Test-OctoAgentDocs -Path $repoName   # after every step")
        $next.Add("Delete $briefName in the migration commit")
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
            # summary below is the report.
            $null = Test-OctoAgentDocs -Path $repo -Fix -Json 3>$null 6>$null
        }
        $next.Add("Write the sections in AGENTS.md; the checker reports a missing one, never fills it")
        $next.Add("Add docs/<topic>.md with 'description' and 'applies_to' frontmatter, then Test-OctoAgentDocs -Path $repoName -Fix")
    }

    # ------------------------------------------------------------------ output
    if ($Json) {
        Write-OctoJson -Command 'Initialize-OctoAgentDocs' -Data ([ordered]@{
            repository   = $repoName
            state        = $state
            filesWritten = @($written)
            nextSteps    = @($next)
        })
        return
    }
    Write-Host "Agent docs init: $repoName - $state" -ForegroundColor Yellow
    if ($written.Count -gt 0) { Write-Host "  wrote $($written -join ', ')" -ForegroundColor Cyan }
    elseif (-not $WhatIfPreference) { Write-Host "  nothing written" -ForegroundColor Cyan }
    foreach ($n in $next) { Write-Host "  next: $n" -ForegroundColor Gray }
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
