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
# CommonMark fences open and close with three backticks OR three tildes. '\r?' before the
# anchors: in .NET, (?m)$ does not match before a carriage return, and the pattern also
# runs over raw text that may still carry CRLF.
$script:FencePattern = '(?ms)^[ \t]*(```|~~~)[^\n]*\n.*?^[ \t]*\1[ \t]*\r?$'
# Every rule the built-in ruleset must define, in report order within the tiers. The
# schema's two enums mirror this list.
$script:RuleIds = @(
    'entry-point-lines', 'entry-point-characters', 'line-length', 'doc-size',
    'frontmatter-present', 'doc-reachable', 'reference-resolves', 'reference-to-shim',
    'routing-current', 'docs-count', 'shim-valid', 'required-sections',
    'no-invisible-characters', 'link-hosts', 'migration-pending'
)

function Get-OctoAgentDocsRuleIdList { return @($script:RuleIds) }

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
    if ($repo -and -not (Test-Path -LiteralPath $repo -PathType Container)) {
        # An easy tab-completion slip: the entry point instead of the folder it is in.
        if ($AsNullIfMissing) { return $null }
        throw "Path '$Path' is a file, not a repository folder. Pass the folder that holds AGENTS.md or CLAUDE.md."
    }
    if ($repo) { return $repo }
    if ($AsNullIfMissing) { return $null }
    $tried = if ([System.IO.Path]::IsPathRooted($Path)) { [System.IO.Path]::GetFullPath($Path) } else { [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path)) }
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

function ConvertTo-OctoAgentDocsLf {
    <#
    .SYNOPSIS
    CRLF and lone CR become LF, so every size, line count and comparison in these tools
    sees the same text whatever the checkout's line endings.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    return (($Text -replace "`r`n", "`n") -replace "`r", "`n")
}

function ConvertTo-OctoAgentDocsProse {
    <#
    .SYNOPSIS
    The prose of a Markdown text: fenced code blocks (``` ... ```) removed. Fenced code is
    illustration, not structure - a heading, link or reference inside it is never followed -
    so every structural scan runs on the text this returns.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text, [switch]$KeepLineNumbers)
    if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
    $lf = ConvertTo-OctoAgentDocsLf $Text
    if (-not $KeepLineNumbers) { return [regex]::Replace($lf, $script:FencePattern, '') }
    # Each fenced block becomes the same number of empty lines, so a line number in the
    # result is a line number in the file - what a per-line rule needs.
    return [regex]::Replace($lf, $script:FencePattern, { param($m) "`n" * ([regex]::Matches($m.Value, "`n").Count) })
}

function Find-OctoAgentDocsMarker {
    <#
    .SYNOPSIS
    The index of the first occurrence of a marker that sits OUTSIDE fenced code, or -1.
    A marker quoted in a ```markdown example is documentation, not the region.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Marker)
    $fences = @([regex]::Matches($Text, $script:FencePattern) | ForEach-Object { @{ s = $_.Index; e = $_.Index + $_.Length } })
    $i = $Text.IndexOf($Marker, [System.StringComparison]::Ordinal)
    while ($i -ge 0) {
        $inside = $false
        foreach ($f in $fences) { if ($i -ge $f.s -and $i -lt $f.e) { $inside = $true; break } }
        if (-not $inside) { return $i }
        $i = $Text.IndexOf($Marker, $i + 1, [System.StringComparison]::Ordinal)
    }
    return -1
}

function Test-OctoAgentDocsPathExact {
    <#
    .SYNOPSIS
    True when every segment of a relative path exists under the root with EXACTLY that
    spelling. Test-Path is case-insensitive on macOS and Windows, GitHub and Linux are not.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath, [hashtable]$Cache)
    # -Cache: one directory listing per directory per run; the caller owns the lifetime.
    $current = $Root
    foreach ($segment in ($RelativePath -split '[\\/]+' | Where-Object { $_ -and $_ -ne '.' })) {
        if ($segment -eq '..') { $current = Split-Path -Parent $current; continue }
        $names = if ($null -ne $Cache -and $Cache.ContainsKey($current)) { $Cache[$current] }
                 else {
                     $list = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
                     foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($current)) { [void]$list.Add([System.IO.Path]::GetFileName($e)) }
                     if ($null -ne $Cache) { $Cache[$current] = $list }
                     $list
                 }
        if (-not $names.Contains($segment)) { return $false }
        $current = Join-Path $current $segment
    }
    return $true
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
    # Comments may span lines; they are removed as a whole before the lines are judged.
    $stripped = [regex]::Replace((ConvertTo-OctoAgentDocsLf $Content), '(?s)<!--.*?-->', '')
    $lines = @($stripped -split "`n")
    $meaningful = @($lines | Where-Object { $_.Trim() -ne '' })
    if ($meaningful.Count -eq 0) { return $true }
    return ($meaningful.Count -eq 1 -and $meaningful[0].Trim() -match '^@\S+$')
}

function Invoke-OctoAgentDocsOrdinalSort {
    <#
    .SYNOPSIS
    Sorts by a string key in ordinal (code point) order. The routing table is committed and
    compared byte for byte, so its order must not depend on the culture of the machine that
    ran -Fix; Sort-Object, even with -Culture '', applies word-sort rules that treat '-' and
    '_' specially.
    #>
    param([AllowEmptyCollection()][object[]]$Items, [Parameter(Mandatory)][scriptblock]$Key)
    $arr = @($Items)
    if ($arr.Count -lt 2) { return , $arr }
    # The key block reads $_, so it is run with $_ bound, the way ForEach-Object binds it.
    $keyOf = $Key
    $ordered = [System.Linq.Enumerable]::OrderBy([object[]]$arr, [System.Func[object, string]] { param($x) [string](ForEach-Object -InputObject $x -Process $keyOf) }, [System.StringComparer]::Ordinal)
    return , [System.Linq.Enumerable]::ToArray($ordered)
}

function Get-OctoAgentDocsShimVerdict {
    <#
    .SYNOPSIS
    Whether a CLAUDE.md is the shim: 'ok' (exactly the expected lines, compared
    case-sensitively after line-ending normalisation), 'absent' (no text), or 'differs'.
    #>
    # $Text is untyped on purpose: a [string] parameter turns $null into '' and the
    # 'absent' verdict could never be reached.
    param([AllowNull()]$Text, [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedLines)
    if ($null -eq $Text) { return 'absent' }
    $expected = $ExpectedLines -join "`n"
    if ((ConvertTo-OctoAgentDocsLf ([string]$Text)).Trim() -ceq $expected) { return 'ok' }
    return 'differs'
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

function ConvertTo-OctoAgentDocsRuleEntry {
    <#
    .SYNOPSIS
    Reads one rule in any shape the schema allows - "warn", ["warn"] or ["warn", {...}] -
    into @{ severity; options; valid }, where valid says whether the severity is one of
    off, warn, error. What to do about an invalid one is the caller's policy.
    #>
    param([AllowNull()]$Raw)
    $severity = if ($Raw -is [string]) { $Raw } elseif ($null -ne $Raw -and $Raw.Count -ge 1) { $Raw[0] } else { $null }
    $options = if ($Raw -isnot [string] -and $null -ne $Raw -and $Raw.Count -gt 1 -and $Raw[1] -is [hashtable]) { $Raw[1] } else { @{} }
    return @{ severity = $severity; options = $options; valid = ($script:Severities -contains $severity) }
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
        $entry = ConvertTo-OctoAgentDocsRuleEntry $config.rules[$id]
        $sev = $entry.severity
        # Validated BEFORE any override is applied: the non-relaxable floor compares against
        # the built-in value, and a comparison against a typo is not a floor.
        if (-not $entry.valid) {
            Write-Warning "Invalid severity '$sev' for rule '$id' in the built-in ruleset - treated as error"
            $sev = 'error'
        }
        $config.rules[$id] = @($sev, $entry.options)
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
    'Get-OctoAgentDocsConstant', 'Get-OctoAgentDocsRuleIdList',
    'Resolve-OctoAgentDocsRepository', 'Format-OctoAgentDocsArgument',
    'ConvertTo-OctoAgentDocsLf', 'ConvertTo-OctoAgentDocsProse', 'Find-OctoAgentDocsMarker', 'Test-OctoAgentDocsPathExact',
    'Test-OctoAgentDocsShimLike', 'Get-OctoAgentDocsShimVerdict', 'Invoke-OctoAgentDocsOrdinalSort',
    'Read-OctoAgentDocsText', 'Write-OctoAgentDocsText',
    'ConvertTo-OctoAgentDocsRuleEntry', 'Read-OctoAgentDocsBuiltInRuleset', 'Get-OctoAgentDocsRuleTier', 'Get-OctoAgentDocsTierHeading'
)
