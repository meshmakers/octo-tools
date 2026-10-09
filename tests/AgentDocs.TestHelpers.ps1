# Dot-sourced by the agent-docs test files inside BeforeAll. Builds throw-away repositories
# under the temp folder and reads the tools' output in both of its shapes.
Import-Module (Join-Path $PSScriptRoot '../modules/OctoJsonOutput.psm1')
Import-Module (Join-Path $PSScriptRoot '../modules/OctoAgentDocs.Common.psm1')
Import-Module (Join-Path $PSScriptRoot '../modules/Test-OctoAgentDocs.psm1')
Import-Module (Join-Path $PSScriptRoot '../modules/Initialize-OctoAgentDocs.psm1')

$script:Fixtures = [System.Collections.Generic.List[string]]::new()
$script:Shim = "<!-- Claude Code loads this file. AGENTS.md is the source of truth - edit that, not this. -->`n@AGENTS.md`n"
$script:Entry = @(
    '# Entry', '', '## Read before you change', '', '<!-- >>> generated: routing -->', '<!-- <<< end generated: routing -->', '',
    '## Build & test', '', 'Run the build.', '', '## Before you commit', '', '## Rules', ''
) -join "`n"
$script:DocOne = "---`ndescription: One routed document.`napplies_to: src/**`n---`n# One`n`nText.`n"

function New-TempDir {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('adocs-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root | Out-Null
    $script:Fixtures.Add($root)
    return $root
}
function Write-File {
    param([string]$Path, [string]$Text, [switch]$Crlf)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Crlf) { $Text = $Text.Replace("`n", "`r`n") }
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}
function New-Fixture {
    # A migrated repository: AGENTS.md with the sections and markers, the shim, one routed doc,
    # table filled by -Fix. -Legacy: CLAUDE.md is the entry point and there is no shim.
    # -Empty: no entry point at all. -NoFix leaves the table empty.
    param([switch]$Legacy, [switch]$Empty, [switch]$NoFix, [switch]$Crlf)
    $root = New-TempDir
    Write-File (Join-Path $root 'docs/one.md') $script:DocOne
    if ($Legacy) { Write-File (Join-Path $root 'CLAUDE.md') $script:Entry -Crlf:$Crlf }
    elseif (-not $Empty) {
        Write-File (Join-Path $root 'AGENTS.md') $script:Entry -Crlf:$Crlf
        Write-File (Join-Path $root 'CLAUDE.md') $script:Shim -Crlf:$Crlf
    }
    if (-not $NoFix -and -not $Empty) { Test-OctoAgentDocs -Path $root -Fix 6>$null 3>$null | Out-Null }
    return $root
}
function Set-Override { param([string]$Root, [string]$Json) Write-File (Join-Path $Root '.agent-docs.json') $Json }
function Add-Line { param([string]$Root, [string]$File, [string[]]$Text) Add-Content -LiteralPath (Join-Path $Root $File) -Value $Text }
function Get-Result {
    param([string]$Root, [hashtable]$Extra = @{})
    return ((Test-OctoAgentDocs -Path $Root -Json @Extra 3>$null 6>$null) | ConvertFrom-Json)
}
function Get-Rules { param($Result, [string]$Rule) @($Result.data.findings | Where-Object { $_.rule -eq $Rule }) }
function Get-Output {
    # The rendered lines of a command, host and warning streams included; -NoNewline host
    # records are joined into their line the way a console shows them.
    param([scriptblock]$Command)
    $sb = [System.Text.StringBuilder]::new()
    & $Command 6>&1 3>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.InformationRecord] -and $_.MessageData.PSObject.Properties['NoNewLine'] -and $_.MessageData.NoNewLine) { [void]$sb.Append($_.MessageData.Message) }
        elseif ($_ -is [System.Management.Automation.WarningRecord]) { [void]$sb.AppendLine("WARNING: $($_.Message)") }
        else { [void]$sb.AppendLine([string]$_) }
    }
    return @($sb.ToString() -split "`n")
}
function Remove-Fixtures { foreach ($f in $script:Fixtures) { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue } }
