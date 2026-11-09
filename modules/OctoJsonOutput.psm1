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

function Write-OctoBuildEvent {
    <#
    .SYNOPSIS
        Appends one build progress event as a single JSON line to an events file (-EventsFile).
    .DESCRIPTION
        Used by Invoke-Build, Invoke-BuildRange and Invoke-BuildAll so a caller (e.g. the octo-devstack
        daemon) can follow a running build. Each call appends exactly one line, UTF-8 without BOM, and
        closes the file again, so every line is flushed when the call returns:

            {"schemaVersion":1,"ts":"<ISO-8601 UTC>","command":"<cmdlet>","event":"<event>", ...Data}

        A no-op when -Path is empty. IO errors never throw; they are reported as a warning so a
        broken events file can never fail a build.
    .PARAMETER Path
        The events file. Created (with its folder) on the first event.
    .PARAMETER Event
        The event name (plan, repoStart, phase, repoDone, done).
    .PARAMETER Data
        Event fields, appended after the envelope fields in the given order (pass an [ordered] dictionary).
    .PARAMETER Command
        The emitting cmdlet. Defaults to the calling command's name.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,

        [Parameter(Mandatory)]
        [Alias('Event')]
        [string]$EventName,

        [System.Collections.IDictionary]$Data,

        [string]$Command = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if ([string]::IsNullOrWhiteSpace($Command)) {
        $caller = @(Get-PSCallStack)
        $Command = if ($caller.Count -gt 1) { [string]$caller[1].Command } else { '' }
    }

    try {
        $record = [ordered]@{
            schemaVersion = 1
            ts            = (Get-Date).ToUniversalTime().ToString('o')
            command       = $Command
            event         = $EventName
        }
        if ($Data) {
            foreach ($key in $Data.Keys) {
                if ($key -in @('schemaVersion', 'ts', 'command', 'event')) { continue }
                $record[$key] = $Data[$key]
            }
        }
        $line = ($record | ConvertTo-Json -Depth 12 -Compress) + "`n"
        # Relative paths resolve against $PWD (GetFullPath would use the process start directory).
        $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $directory = [IO.Path]::GetDirectoryName($fullPath)
        if ($directory -and -not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }
        # AppendAllText opens, writes and closes the file: the line is flushed when this returns.
        [IO.File]::AppendAllText($fullPath, $line, [Text.UTF8Encoding]::new($false))
    }
    catch {
        Write-Warning "Could not write build event '$EventName' to ${Path}: $($_.Exception.Message)"
    }
}

function New-OctoBuildEventState {
    <#
    .SYNOPSIS
        The mutable -EventsFile state a build cmdlet shares with its inner run (see Complete-OctoBuildEvents).
    #>
    param(
        [AllowEmptyString()] [AllowNull()] [string]$Path,
        [Parameter(Mandatory)] [string]$Command
    )
    return @{
        Path = $Path; Command = $Command
        Repo = $null; Index = $null; Count = $null; Phase = $null; RepoDone = $false; RepoWatch = $null; LogFile = $null
        Success = $false; FailedRepo = $null; FailedStep = $null; Completed = $false
    }
}

function Complete-OctoBuildEvents {
    <#
    .SYNOPSIS
        Writes the closing events of a build run: called from the cmdlet's finally block.
    .DESCRIPTION
        When the run did not complete (it threw) and a repository had started without its repoDone, a
        repoDone with success=false is written first (durations/counts null), then `done`. A run that
        stopped before its first repoStart (refusal, invalid arguments) only gets `done` with failedStep
        "preflight". A no-op without an events path.
    #>
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary]$State,
        [double]$ElapsedSeconds = 0
    )
    $path = [string]$State.Path
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $command = [string]$State.Command
    if (-not $State.Completed) {
        $State.Success = $false
        if (-not $State.FailedRepo) { $State.FailedRepo = $State.Repo }
        if (-not $State.FailedStep) { $State.FailedStep = if ($State.Repo -and $State.Phase) { $State.Phase } else { 'preflight' } }
        if ($State.Repo -and -not $State.RepoDone) {
            $seconds = if ($null -ne $State.RepoWatch) { $State.RepoWatch.Elapsed.TotalSeconds } else { $null }
            Write-OctoBuildEvent -Path $path -Command $command -Event 'repoDone' -Data ([ordered]@{
                    repo           = $State.Repo
                    index          = $State.Index
                    count          = $State.Count
                    success        = $false
                    seconds        = $seconds
                    buildSeconds   = $null
                    testSeconds    = $null
                    packageSeconds = $null
                    copied         = $null
                    purged         = $null
                    logFile        = $State.LogFile
                })
            $State.RepoDone = $true
        }
    }
    Write-OctoBuildEvent -Path $path -Command $command -Event 'done' -Data ([ordered]@{
            success        = [bool]$State.Success
            failedRepo     = if ($State.Success) { $null } else { $State.FailedRepo }
            failedStep     = if ($State.Success) { $null } else { $State.FailedStep }
            elapsedSeconds = $ElapsedSeconds
        })
}

Export-ModuleMember -Function @('Write-OctoJson', 'New-OctoActionResult', 'Write-OctoBuildEvent', 'New-OctoBuildEventState', 'Complete-OctoBuildEvents')
