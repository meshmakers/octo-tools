# Shared pieces of the agent-docs tooling: the things Test-OctoAgentDocs and
# Initialize-OctoAgentDocs must agree on have exactly one definition here - how a
# repository path is resolved, what counts as a shim, how files are written, how the
# built-in ruleset is loaded and normalised, how a tier is named, and the names of the
# generated-region markers and the migration brief. Both modules import this one; the
# profile loads it first.

$script:Constants = @{
    RoutingStart = '<!-- >>> generated: routing -->'
    RoutingEnd   = '<!-- <<< end generated: routing -->'
    BriefName    = 'AGENTS-MIGRATION.md'
}
$script:Severities = @('off', 'warn', 'error')

function Get-OctoAgentDocsConstant {
    <#
    .SYNOPSIS
    Returns one of the fixed names the agent-docs tools share.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('RoutingStart', 'RoutingEnd', 'BriefName')]
        [string]$Name
    )
    return $script:Constants[$Name]
}

function Resolve-OctoAgentDocsRepository {
    <#
    .SYNOPSIS
    Resolves a repository argument the way every octo-tools cmdlet does: as given, then as
    a repository name under $Global:ROOTPATH.

    .DESCRIPTION
    The Octo profile starts you at the monorepo root, so a bare repository name is the form
    people actually type. An empty argument is an error, not the root: Join-Path of ROOTPATH
    and '' would otherwise quietly resolve to the whole monorepo. Throws with the paths it
    tried unless -AsNullIfMissing is set.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$Global:ROOTPATH is the octo-tools profile contract')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,
        [switch]$AsNullIfMissing
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ($AsNullIfMissing) { return $null }
        throw "Path is empty. Pass a repository path or a repository name under ROOTPATH."
    }
    $repo = try { (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path } catch { $null }
    if (-not $repo -and $Global:ROOTPATH) {
        $underRoot = Join-Path $Global:ROOTPATH $Path
        $repo = try { (Resolve-Path -LiteralPath $underRoot -ErrorAction Stop).Path } catch { $null }
    }
    if ($repo) { return $repo }
    if ($AsNullIfMissing) { return $null }
    $tried = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    $msg = "Path '$Path' does not exist (resolved to '$tried')"
    if ($Global:ROOTPATH) { $msg += " and not under ROOTPATH '$Global:ROOTPATH'" }
    throw $msg
}

function Format-OctoAgentDocsArgument {
    <#
    .SYNOPSIS
    Quotes a value for a command line the tools print for copying: single quotes when the
    value holds anything beyond path-safe characters, with embedded single quotes doubled.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match "^[\w./\\:~-]+$") { return $Value }
    return "'" + ($Value -replace "'", "''") + "'"
}

function Test-OctoAgentDocsShimLike {
    <#
    .SYNOPSIS
    True when a CLAUDE.md holds nothing but HTML comments and at most one @import line -
    nobody's work is in it, so the shim may replace it.

    .DESCRIPTION
    Line endings are normalised here, so a CRLF or lone-CR file is judged by its content,
    not by how it was saved.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Content)
    if ([string]::IsNullOrEmpty($Content)) { return $true }
    $lines = @((($Content -replace "`r`n", "`n") -replace "`r", "`n") -split "`n")
    $meaningful = @($lines | Where-Object { $_.Trim() -ne '' -and $_.Trim() -notmatch '^<!--.*-->$' })
    if ($meaningful.Count -eq 0) { return $true }
    return ($meaningful.Count -eq 1 -and $meaningful[0].Trim() -match '^@\S+$')
}

function Read-OctoAgentDocsText {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Write-OctoAgentDocsText {
    <#
    .SYNOPSIS
    Writes UTF-8 without a BOM, the encoding every file in these repositories uses.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The callers decide through their own ShouldProcess; this is the write primitive')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content
    )
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Read-OctoAgentDocsBuiltInRuleset {
    <#
    .SYNOPSIS
    Loads agent-docs.rules.json beside the modules and normalises every rule to the
    [severity, options] array form, with an invalid built-in severity treated as 'error'
    and a missing rule as 'off'.

    .DESCRIPTION
    A broken built-in ruleset is a broken install and throws. Everything downstream indexes
    [0] and [1], and indexing a STRING yields a character ("warn"[0] is 'w'), so the
    normalisation happens once, here, for both modules.
    #>
    param([Parameter(Mandatory)][string[]]$RuleIds)
    $path = Join-Path $PSScriptRoot 'agent-docs.rules.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Built-in ruleset missing at $path" }
    $config = try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "Ruleset '$path' is not valid JSON: $($_.Exception.Message)" }
    if (-not $config.rules) { throw "Built-in ruleset at $path has no 'rules' section" }

    foreach ($id in $RuleIds) {
        if (-not $config.rules.ContainsKey($id)) {
            Write-Warning "Built-in ruleset has no '$id' - treated as off"
            $config.rules[$id] = @('off', @{})
            continue
        }
        $raw = $config.rules[$id]
        $sev = if ($raw -is [string]) { $raw } elseif ($raw.Count -ge 1) { $raw[0] } else { $null }
        $opt = if ($raw -isnot [string] -and $raw.Count -gt 1 -and $raw[1] -is [hashtable]) { $raw[1] } else { @{} }
        # Validated BEFORE any override is applied: the non-relaxable floor compares against
        # the built-in value, and a comparison against a typo is not a floor.
        if ($script:Severities -notcontains $sev) {
            Write-Warning "Invalid severity '$sev' for rule '$id' in the built-in ruleset - treated as error"
            $sev = 'error'
        }
        $config.rules[$id] = @($sev, $opt)
    }
    return $config
}

function Get-OctoAgentDocsRuleTier {
    <#
    .SYNOPSIS
    The tier a rule reports under, from its ruleDocs entry; 4 (budgets) when unset.
    #>
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Id)
    $docs = $Config['ruleDocs']
    if ($docs -is [hashtable] -and $docs[$Id] -is [hashtable] -and $docs[$Id]['tier']) { return [int]$docs[$Id]['tier'] }
    return 4
}

function Get-OctoAgentDocsTierHeading {
    <#
    .SYNOPSIS
    'N. Title - why' for a tier, the same line in the report, the reference and the brief.
    With -Markdown the number and title are bold and the reason stays plain.
    #>
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][int]$Tier, [switch]$Markdown)
    $tiers = $Config['tiers']
    $info = if ($tiers -is [hashtable]) { $tiers["$Tier"] } else { $null }
    $title = if ($info -is [hashtable] -and $info['title']) { $info['title'] } else { "Tier $Tier" }
    $why = if ($info -is [hashtable] -and $info['why']) { " - $($info['why'])" } else { '' }
    if ($Markdown) { return "**$Tier. $title**$why" }
    return "$Tier. $title$why"
}

Export-ModuleMember -Function @(
    'Get-OctoAgentDocsConstant', 'Resolve-OctoAgentDocsRepository', 'Format-OctoAgentDocsArgument',
    'Test-OctoAgentDocsShimLike', 'Read-OctoAgentDocsText', 'Write-OctoAgentDocsText',
    'Read-OctoAgentDocsBuiltInRuleset', 'Get-OctoAgentDocsRuleTier', 'Get-OctoAgentDocsTierHeading'
)
