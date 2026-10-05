# Shared pieces of the agent-docs tooling. Test-OctoAgentDocs and Initialize-OctoAgentDocs
# must agree on these, so each has exactly one definition here.

$script:Constants = @{
    RoutingStart = '<!-- >>> generated: routing -->'
    RoutingEnd   = '<!-- <<< end generated: routing -->'
    BriefName    = 'AGENTS-MIGRATION.md'
}
$script:Severities = @('off', 'warn', 'error')
# Fenced code (``` or ~~~, three or more) is illustration, not structure. The closing run
# may be longer than the opening one. '\r?' because the pattern also runs over raw CRLF text.
$script:FencePattern = '(?ms)^[ \t]*(`{3,}|~{3,})[^\n]*\n.*?^[ \t]*\1[`~]*[ \t]*\r?$'
# Every rule the built-in ruleset defines. The schema's enum mirrors this list.
$script:RuleIds = @(
    'entry-point-lines', 'entry-point-characters', 'line-length', 'doc-size',
    'frontmatter-present', 'doc-reachable', 'reference-resolves', 'reference-to-shim',
    'routing-current', 'docs-count', 'shim-valid', 'required-sections',
    'no-invisible-characters', 'link-hosts', 'migration-pending'
)

function Get-OctoAgentDocsRuleIdList { return @($script:RuleIds) }

function Get-OctoAgentDocsConstant {
    param([Parameter(Mandatory)][ValidateSet('RoutingStart', 'RoutingEnd', 'BriefName')][string]$Name)
    return $script:Constants[$Name]
}

function Resolve-OctoAgentDocsRepository {
    <#
    .SYNOPSIS
    Resolves a repository argument as given, then as a repository name under $Global:ROOTPATH.
    Throws with the paths it tried; a file is rejected, since the entry point is an easy
    tab-completion slip for the folder that holds it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$Global:ROOTPATH is the octo-tools profile contract')]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'Path is empty. Pass a repository path or a repository name under ROOTPATH.' }
    $candidates = @($Path)
    if ($Global:ROOTPATH) { $candidates += Join-Path $Global:ROOTPATH $Path }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Container) { return (Resolve-Path -LiteralPath $c).Path }
        if (Test-Path -LiteralPath $c -PathType Leaf) { throw "Path '$Path' is a file, not a repository folder. Pass the folder that holds AGENTS.md or CLAUDE.md." }
    }
    $tried = [System.IO.Path]::GetFullPath($Path, (Get-Location).Path)
    $msg = "Path '$Path' does not exist (resolved to '$tried')"
    if ($Global:ROOTPATH) { $msg += " and not under ROOTPATH '$Global:ROOTPATH'" }
    throw $msg
}

function Format-OctoAgentDocsArgument {
    # Quotes a value for a command line the tools print for copying.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    if ($Value -match '^[\w./\\:~-]+$') { return $Value }
    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-OctoAgentDocsProse {
    # The text without its fenced code blocks. With -KeepLineNumbers each block becomes the
    # same number of empty lines, so a line number in the result is a line number in the file.
    param([AllowNull()][AllowEmptyString()][string]$Text, [switch]$KeepLineNumbers)
    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    if (-not $KeepLineNumbers) { return [regex]::Replace($Text, $script:FencePattern, '') }
    return [regex]::Replace($Text, $script:FencePattern, { param($m) "`n" * ([regex]::Matches($m.Value, "`n").Count) })
}

function Find-OctoAgentDocsMarker {
    # Index of the first occurrence of a marker outside fenced code, or -1: a marker quoted
    # in a ```markdown example is documentation, not the region.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Marker)
    $fences = @([regex]::Matches($Text, $script:FencePattern) | ForEach-Object { @{ s = $_.Index; e = $_.Index + $_.Length } })
    $i = $Text.IndexOf($Marker, [System.StringComparison]::Ordinal)
    while ($i -ge 0) {
        if (-not ($fences | Where-Object { $i -ge $_.s -and $i -lt $_.e })) { return $i }
        $i = $Text.IndexOf($Marker, $i + 1, [System.StringComparison]::Ordinal)
    }
    return -1
}

function Test-OctoAgentDocsShimLike {
    # True when a CLAUDE.md holds nothing but HTML comments and at most one @import line:
    # nobody's work is in it, so the shim may replace it.
    param([AllowNull()][AllowEmptyString()][string]$Content)
    $stripped = [regex]::Replace([string]$Content, '(?s)<!--.*?-->', '')
    $meaningful = @(($stripped -split "`r?`n") | Where-Object { $_.Trim() })
    return $meaningful.Count -eq 0 -or ($meaningful.Count -eq 1 -and $meaningful[0].Trim() -match '^@\S+$')
}

function Read-OctoAgentDocsText {
    # File text with CRLF normalised to LF, so sizes, line counts and comparisons do not
    # depend on the checkout. Callers that write back read the raw text themselves.
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
}

function Write-OctoAgentDocsText {
    # UTF-8 without BOM. A symlink is never written through: the target may be outside the
    # repository being fixed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The callers decide through their own ShouldProcess; this is the write primitive')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($item -and $item.LinkType) { throw "'$Path' is a symbolic link and is left alone. Replace the link with a file first." }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Read-OctoAgentDocsBuiltInRuleset {
    <#
    .SYNOPSIS
    Loads agent-docs.rules.json beside the modules with every rule normalised to the
    [severity, options] form, so callers can index [0] and [1] without checking the shape.
    #>
    $path = Join-Path $PSScriptRoot 'agent-docs.rules.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "Built-in ruleset missing at $path" }
    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($id in $script:RuleIds) {
        $entry = ConvertTo-OctoAgentDocsRuleEntry $config.rules[$id]
        if (-not $entry.valid) { throw "Built-in ruleset: rule '$id' is missing or has an invalid severity" }
        $config.rules[$id] = @($entry.severity, $entry.options)
    }
    if (@('logOnly', 'enforce') -notcontains $config.mode) { $config.mode = 'logOnly' }
    return $config
}

function ConvertTo-OctoAgentDocsRuleEntry {
    # "warn", ["warn"] or ["warn", {...}] into @{ severity; options; valid }.
    param([AllowNull()]$Raw)
    $severity = if ($Raw -is [string]) { $Raw } elseif ($Raw -is [array] -and $Raw.Count -ge 1) { $Raw[0] } else { $null }
    $options = if ($Raw -is [array] -and $Raw.Count -gt 1 -and $Raw[1] -is [hashtable]) { $Raw[1] } else { @{} }
    return @{ severity = $severity; options = $options; valid = ($script:Severities -contains $severity) }
}

function Get-OctoAgentDocsRuleTier {
    # The tier a rule reports under, from its ruleDocs entry; 4 (budgets) when unset.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Id)
    $doc = $Config['ruleDocs'][$Id]
    if ($doc -is [hashtable] -and $doc['tier']) { return [int]$doc['tier'] }
    return 4
}

function Get-OctoAgentDocsTierHeading {
    # 'N. Title - why', the same line in the report, the reference and the brief.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][int]$Tier, [switch]$Markdown)
    $info = $Config['tiers']["$Tier"]
    $title = if ($info -is [hashtable] -and $info['title']) { $info['title'] } else { "Tier $Tier" }
    $why = if ($info -is [hashtable] -and $info['why']) { " - $($info['why'])" } else { '' }
    if ($Markdown) { return "**$Tier. $title**$why" }
    return "$Tier. $title$why"
}

Export-ModuleMember -Function @(
    'Get-OctoAgentDocsConstant', 'Get-OctoAgentDocsRuleIdList', 'Resolve-OctoAgentDocsRepository',
    'Format-OctoAgentDocsArgument', 'ConvertTo-OctoAgentDocsProse', 'Find-OctoAgentDocsMarker',
    'Test-OctoAgentDocsShimLike', 'Read-OctoAgentDocsText', 'Write-OctoAgentDocsText',
    'Read-OctoAgentDocsBuiltInRuleset', 'ConvertTo-OctoAgentDocsRuleEntry',
    'Get-OctoAgentDocsRuleTier', 'Get-OctoAgentDocsTierHeading'
)
