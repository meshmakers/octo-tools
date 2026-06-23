<#
.SYNOPSIS
    Shared helpers that give octo-tools cmdlets a uniform, parseable -Json output mode.

.DESCRIPTION
    Most octo-tools cmdlets render results with Write-Host, which writes straight to the host
    console and therefore cannot be captured ( `$x = Cmd` or `Cmd | ConvertFrom-Json` get nothing ).
    To make a command's result consumable by scripts / CI / agents, the command adds a [switch]$Json
    parameter and, when it is set, builds a structured object and emits it through Write-OctoJson
    instead of printing human text.

    Every -Json document shares one envelope shape:

        { "schemaVersion": 1, "command": "<Verb-Noun>", "timestamp": "<ISO-8601 UTC>", "data": <payload> }

    Centralizing serialization here fixes the two silent footguns once for all call sites:
      * ConvertTo-Json's default -Depth is 2, which truncates nested data to literal
        "System.Collections.Hashtable" strings. We default to a generous depth.
      * A single emit point keeps the envelope and timestamp format consistent everywhere.

    This module is imported FIRST by profile.ps1 so the helpers are available to every other module.
#>

function Write-OctoJson {
    <#
    .SYNOPSIS
        Wraps a payload in the standard envelope and writes it as a single JSON string.
    .PARAMETER Command
        The emitting cmdlet's name (Verb-Noun), recorded in the envelope's "command" field.
    .PARAMETER Data
        The command-specific payload (object, array, or scalar). Becomes the "data" field.
    .PARAMETER Depth
        ConvertTo-Json depth. Defaults to 12 — deep enough for every structure in this repo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        $Data,

        [int]$Depth = 12
    )

    process {
        [ordered]@{
            schemaVersion = 1
            command       = $Command
            timestamp     = (Get-Date).ToUniversalTime().ToString('o')   # ISO-8601, locale-independent
            data          = $Data
        } | ConvertTo-Json -Depth $Depth
    }
}

function New-OctoActionResult {
    <#
    .SYNOPSIS
        Builds the standard payload for pure-action commands ( { success; exitCode; ...extra } ).
    .PARAMETER Success
        Whether the action succeeded.
    .PARAMETER ExitCode
        The relevant process/exit code (0 when not applicable).
    .PARAMETER Extra
        Optional extra fields to merge in (e.g. @{ killedCount = 3 }).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Success,

        [int]$ExitCode = 0,

        [hashtable]$Extra
    )

    $result = [ordered]@{
        success  = $Success
        exitCode = $ExitCode
    }
    if ($Extra) {
        foreach ($key in $Extra.Keys) { $result[$key] = $Extra[$key] }
    }
    $result
}

Export-ModuleMember -Function @('Write-OctoJson', 'New-OctoActionResult')
