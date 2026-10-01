# Shared pieces of the agent-docs tooling: the things Test-OctoAgentDocs and
# Initialize-OctoAgentDocs must agree on have exactly one definition here - how a
# repository path is resolved, what counts as a shim, how files are written, and the
# names of the generated-region markers and the migration brief. Both modules import
# this one; the profile loads it first.

$script:Constants = @{
    RoutingStart = '<!-- >>> generated: routing -->'
    RoutingEnd   = '<!-- <<< end generated: routing -->'
    BriefName    = 'AGENTS-MIGRATION.md'
}

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
    people actually type. Throws with the paths it tried unless -AsNullIfMissing is set.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '', Justification = '$Global:ROOTPATH is the octo-tools profile contract')]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,
        [switch]$AsNullIfMissing
    )
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

Export-ModuleMember -Function @(
    'Get-OctoAgentDocsConstant', 'Resolve-OctoAgentDocsRepository', 'Test-OctoAgentDocsShimLike',
    'Read-OctoAgentDocsText', 'Write-OctoAgentDocsText'
)
