<#
.SYNOPSIS
    Runs the Pester test files of a folder in parallel processes and merges the results (AB#8811).

.DESCRIPTION
    `Invoke-Pester ./tests` stays the documented way to run the tests and runs the files one after the other. This
    script is the faster alternative for the same files: every *.Tests.ps1 runs in its own pwsh process (a job), at
    most -ThrottleLimit at a time, the biggest files first. A process per file, not a runspace: the tests change
    process-wide state (environment variables, $global:rootPath, the current location).

    The merged result fails when any file fails: a failed test, a failed block or container (BeforeAll, discovery),
    a file whose process ended without a result, and a file that ran no test at all each count. The script ends with
    exit code 1 then, 0 otherwise. With -PassThru it returns the merged result object instead of setting the exit
    code.

.PARAMETER Path
    Folder with the test files (default: the folder of this script) or single test files.

.PARAMETER ThrottleLimit
    Processes at a time. Default: the number of processors, at most 8.

.PARAMETER PassThru
    Return { Success; TotalCount; PassedCount; FailedCount; SkippedCount; NotRunCount; FailedFileCount; Seconds;
    Files[{ File; Success; TotalCount; PassedCount; FailedCount; SkippedCount; NotRunCount; Seconds; Error;
    FailedTests[{ Name; Error }] }] } and do not exit.

.EXAMPLE
    ./tests/Invoke-ParallelPester.ps1

.EXAMPLE
    $result = ./tests/Invoke-ParallelPester.ps1 -Path ./tests/OctoTests.Tests.ps1, ./tests/BuildRange.Tests.ps1 -PassThru
#>
[CmdletBinding()]
param(
    [string[]]$Path = @($PSScriptRoot),
    [ValidateRange(1, 64)]
    [int]$ThrottleLimit = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount)),
    [switch]$PassThru
)

$files = @(foreach ($item in $Path) {
        $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($item)
        if (Test-Path -LiteralPath $resolved -PathType Container) {
            Get-ChildItem -LiteralPath $resolved -Filter '*.Tests.ps1' -File
        }
        elseif (Test-Path -LiteralPath $resolved -PathType Leaf) { Get-Item -LiteralPath $resolved }
        else { throw "Invoke-ParallelPester: $item does not exist." }
    })
# The biggest files first: they take the longest, so they must not start last.
$files = @($files | Sort-Object -Property FullName -Unique | Sort-Object -Property Length -Descending)
if ($files.Count -eq 0) { throw "Invoke-ParallelPester: no *.Tests.ps1 in $($Path -join ', ')." }

# The children load the Pester this process would load.
$pester = Get-Module -Name Pester | Select-Object -First 1
if ($null -eq $pester) { $pester = Get-Module -Name Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1 }
if ($null -eq $pester) { throw 'Invoke-ParallelPester: the Pester module is not installed.' }
$pesterManifest = Join-Path $pester.ModuleBase 'Pester.psd1'

$runFile = {
    param([string]$file, [string]$pesterManifest)
    Import-Module $pesterManifest
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $file
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'None'
    $run = Invoke-Pester -Configuration $configuration 6>$null 3>$null
    $errors = @(
        foreach ($container in @($run.Containers | Where-Object { $_.Result -eq 'Failed' })) {
            foreach ($record in @($container.ErrorRecord)) { "container: $($record.Exception.Message)" }
        }
    )
    [pscustomobject]@{
        TotalCount            = [int]$run.TotalCount
        PassedCount           = [int]$run.PassedCount
        FailedCount           = [int]$run.FailedCount
        SkippedCount          = [int]$run.SkippedCount
        NotRunCount           = [int]$run.NotRunCount
        FailedBlocksCount     = [int]$run.FailedBlocksCount
        FailedContainersCount = [int]$run.FailedContainersCount
        Result                = [string]$run.Result
        Errors                = $errors
        FailedTests           = @($run.Failed | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.ExpandedPath; Error = [string](@($_.ErrorRecord | ForEach-Object { $_.Exception.Message }) -join "`n") }
            })
    }
}

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$pending = [System.Collections.Generic.Queue[object]]::new()
foreach ($file in $files) { $pending.Enqueue($file) }
$running = [System.Collections.Generic.List[object]]::new()
$results = [System.Collections.Generic.List[object]]::new()
if (-not $PassThru) { Write-Host "Running $($files.Count) test file(s) in up to $ThrottleLimit processes" -ForegroundColor Cyan }

try {
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
            $file = $pending.Dequeue()
            $job = Start-Job -ScriptBlock $runFile -ArgumentList $file.FullName, $pesterManifest -WorkingDirectory $PWD.ProviderPath
            $running.Add([pscustomobject]@{ File = $file; Job = $job; Watch = [System.Diagnostics.Stopwatch]::StartNew() })
        }
        $finished = @($running | Where-Object { $_.Job.State -notin @('Running', 'NotStarted') })
        if ($finished.Count -eq 0) { Start-Sleep -Milliseconds 100; continue }
        foreach ($entry in $finished) {
            $entry.Watch.Stop()
            [void]$running.Remove($entry)
            $jobErrors = @()
            $output = @(Receive-Job -Job $entry.Job -ErrorVariable jobErrors -ErrorAction SilentlyContinue 6>$null 3>$null)
            $summary = $output | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['FailedContainersCount'] } | Select-Object -Last 1
            $problem = $null
            if ($null -eq $summary) {
                # The process died, threw, or Pester returned nothing: never a pass.
                $reason = @(@($jobErrors | ForEach-Object { "$_" }) + @($entry.Job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason } | Where-Object { $_ } | ForEach-Object { $_.Message })) | Where-Object { $_ } | Select-Object -Unique
                $problem = "no result from the test process (job state $($entry.Job.State))$(if ($reason) { ': ' + ($reason -join '; ') })"
            }
            elseif ($summary.FailedContainersCount -gt 0 -or $summary.FailedBlocksCount -gt 0) {
                $problem = "$($summary.FailedContainersCount) failed container(s), $($summary.FailedBlocksCount) failed block(s)$(if (@($summary.Errors).Count -gt 0) { ': ' + (@($summary.Errors) -join '; ') })"
            }
            elseif ($summary.TotalCount -eq 0) { $problem = 'the file ran no test' }
            elseif ($summary.Result -ne 'Passed' -and $summary.FailedCount -eq 0) { $problem = "Pester result $($summary.Result)" }
            Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue

            $result = [pscustomobject]@{
                File         = $entry.File.Name
                Path         = $entry.File.FullName
                Success      = ($null -eq $problem) -and ($summary.FailedCount -eq 0)
                TotalCount   = if ($summary) { $summary.TotalCount } else { 0 }
                PassedCount  = if ($summary) { $summary.PassedCount } else { 0 }
                FailedCount  = if ($summary) { $summary.FailedCount } else { 0 }
                SkippedCount = if ($summary) { $summary.SkippedCount } else { 0 }
                NotRunCount  = if ($summary) { $summary.NotRunCount } else { 0 }
                Seconds      = [Math]::Round($entry.Watch.Elapsed.TotalSeconds, 1)
                Error        = $problem
                FailedTests  = if ($summary) { @($summary.FailedTests) } else { @() }
            }
            $results.Add($result)
            if (-not $PassThru) {
                $color = if ($result.Success) { 'Green' } else { 'Red' }
                Write-Host ('[{0}] {1,-44} {2,4} passed {3,3} failed {4,3} skipped {5,7:N1}s' -f $(if ($result.Success) { '+' } else { '-' }), $result.File, $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.Seconds) -ForegroundColor $color
                if ($result.Error) { Write-Host "      $($result.Error)" -ForegroundColor Red }
                foreach ($test in $result.FailedTests) {
                    Write-Host "      [-] $($test.Name)" -ForegroundColor Red
                    foreach ($line in @(([string]$test.Error) -split "`r?`n" | Select-Object -First 4)) { Write-Host "          $line" -ForegroundColor Red }
                }
            }
        }
    }
}
finally {
    # Ctrl+C: no test process is left behind.
    foreach ($entry in $running) { Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue; Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue }
}
$watch.Stop()

$failedFiles = @($results | Where-Object { -not $_.Success })
$merged = [pscustomobject]@{
    Success         = ($failedFiles.Count -eq 0) -and ($results.Count -eq $files.Count)
    TotalCount      = [int]($results | Measure-Object TotalCount -Sum).Sum
    PassedCount     = [int]($results | Measure-Object PassedCount -Sum).Sum
    FailedCount     = [int]($results | Measure-Object FailedCount -Sum).Sum
    SkippedCount    = [int]($results | Measure-Object SkippedCount -Sum).Sum
    NotRunCount     = [int]($results | Measure-Object NotRunCount -Sum).Sum
    FailedFileCount = $failedFiles.Count
    Seconds         = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
    Files           = @($results | Sort-Object File)
}
if ($PassThru) { return $merged }

$color = if ($merged.Success) { 'Green' } else { 'Red' }
Write-Host ('Tests completed in {0:N1}s ({1} file(s), {2} processes)' -f $merged.Seconds, $files.Count, $ThrottleLimit)
Write-Host ('Tests Passed: {0}, Failed: {1}, Skipped: {2}, NotRun: {3}' -f $merged.PassedCount, $merged.FailedCount, $merged.SkippedCount, $merged.NotRunCount) -ForegroundColor $color
if (-not $merged.Success) { Write-Host "Failed file(s): $(($failedFiles.File) -join ', ')" -ForegroundColor Red }
exit $(if ($merged.Success) { 0 } else { 1 })
