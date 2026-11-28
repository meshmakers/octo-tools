#Requires -Modules Pester
<#
    Pester tests for the Windows start of the octo-devstack daemon, Start-OctoDevStackDetachedWindows (AB#9922).

    Start-Process with -RedirectStandardOutput/-RedirectStandardError creates the process with handle inheritance, so
    every inheritable handle of the starting pwsh went to the daemon: its standard handles and the handles it had
    inherited from its own callers. When a caller pipes or captures the output, those are the caller's pipe ends, and
    the daemon held them open until it ended. The function starts the program with an explicit list of inheritable
    handles: only the two log files and NUL as standard input.

    The real daemon is never started here: the process tests start a stand-in (this pwsh running a small script from
    TestDrive) and stop it by the pid the function returned.

    Run:  Invoke-Pester ./tests/OctoDevStack.Windows.Tests.ps1
#>

BeforeAll {
    $script:Modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $script:Modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $script:Modules 'OctoDevStack.psm1') -Force
    $script:Pwsh = (Get-Process -Id $PID).Path

    # Starts the function from a pwsh of its own (the parent), as Start-OctoDevStackDaemon does.
    $script:ParentScript = Join-Path $TestDrive 'parent.ps1'
    Set-Content -LiteralPath $script:ParentScript -Value @'
param([string]$ModulesPath, [string]$StandIn, [string]$Log, [string]$ErrorLog, [string]$PidFile)
Import-Module (Join-Path $ModulesPath 'OctoJsonOutput.psm1')
$module = Import-Module (Join-Path $ModulesPath 'OctoDevStack.psm1') -PassThru
$pwsh = (Get-Process -Id $PID).Path
$arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $StandIn)
$processId = & $module { param($p, $a, $l, $e, $w) Start-OctoDevStackDetachedWindows -WorkingDirectory $w -LogPath $l -ErrorLogPath $e -FilePath $p -ArgumentList $a } $pwsh $arguments $Log $ErrorLog (Split-Path -Parent $StandIn)
Set-Content -LiteralPath $PidFile -Value $processId
[Console]::Out.WriteLine("started $processId")
[Console]::Error.WriteLine('parent stderr line')
'@

    # Calls the parent as a native command whose output it captures (pipes, normal handle inheritance).
    $script:GrandparentScript = Join-Path $TestDrive 'grandparent.ps1'
    Set-Content -LiteralPath $script:GrandparentScript -Value @'
param([string]$Pwsh, [string]$ParentScript, [string]$ModulesPath, [string]$StandIn, [string]$Log, [string]$ErrorLog, [string]$PidFile)
$watch = [Diagnostics.Stopwatch]::StartNew()
$lines = & $Pwsh -NoLogo -NoProfile -NonInteractive -File $ParentScript -ModulesPath $ModulesPath -StandIn $StandIn -Log $Log -ErrorLog $ErrorLog -PidFile $PidFile 2>&1
[Console]::Out.WriteLine("parent-returned-ms=$([int]$watch.ElapsedMilliseconds)")
foreach ($line in $lines) { [Console]::Out.WriteLine("parent: $line") }
'@

    function script:New-StandIn([string]$Name, [int]$Seconds) {
        $path = Join-Path $TestDrive "$Name.ps1"
        Set-Content -LiteralPath $path -Value "[Console]::Out.WriteLine('standin-line'); [Console]::Out.Flush(); Start-Sleep -Seconds $Seconds"
        return $path
    }

    # Starts pwsh with pipes as standard output and error; returns the process and the reads of both pipes.
    function script:Start-PipedPwsh([string[]]$Arguments) {
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new($script:Pwsh)
        foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        return [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
    }

    function script:Wait-LogLine([string]$Path, [string]$Pattern) {
        $deadline = (Get-Date).AddSeconds(15)
        while (-not ((Test-Path -LiteralPath $Path) -and ((Get-Content -LiteralPath $Path -Raw) -match $Pattern)) -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        return (Get-Content -LiteralPath $Path -Raw)
    }

    function script:Stop-StandIn([string]$PidFile) {
        if (-not (Test-Path -LiteralPath $PidFile)) { return }
        $standInPid = [int](Get-Content -LiteralPath $PidFile -Raw)
        Stop-Process -Id $standInPid -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $standInPid -Timeout 15 -ErrorAction SilentlyContinue
    }
}

Describe 'Start-OctoDevStackDetachedWindows (AB#9922)' {
    It 'quotes each argument of the command line the way Windows programs split it' {
        InModuleScope OctoDevStack {
            Join-OctoDevStackCommandLine -FilePath 'C:\Program Files\dotnet\dotnet.exe' -ArgumentList @('C:\a b\octo-devstack.dll', '--url', 'http://127.0.0.1:5190') |
                Should -Be '"C:\Program Files\dotnet\dotnet.exe" "C:\a b\octo-devstack.dll" --url http://127.0.0.1:5190'
            Join-OctoDevStackCommandLine -FilePath 'C:\x\dotnet.exe' -ArgumentList @('', 'say "hi"', 'C:\with space\', 'a\\b') |
                Should -Be '"C:\x\dotnet.exe" "" "say \"hi\"" "C:\with space\\" a\\b'
            Join-OctoDevStackCommandLine -FilePath 'C:\x\a.exe' | Should -Be '"C:\x\a.exe"'
            Join-OctoDevStackCommandLine -FilePath 'C:\x\a.exe' -ArgumentList @() | Should -Be '"C:\x\a.exe"'
            Join-OctoDevStackCommandLine -FilePath 'C:\x\a.exe' -ArgumentList @('') | Should -Be '"C:\x\a.exe" ""'
        }
    }

    It 'compiles the native start under a type name that changes with its source' {
        InModuleScope OctoDevStack {
            # Add-Type keeps a compiled type for the life of the process; Import-Module -Force after a pull that changed
            # the source must not use the old one.
            $current = Get-OctoDevStackNativeTypeName -Source $script:DetachedProcessSource
            $current | Should -Match '^OctoDevStackNative_[0-9a-f]{12}\.DetachedProcess$'
            Get-OctoDevStackNativeTypeName -Source $script:DetachedProcessSource | Should -Be $current
            Get-OctoDevStackNativeTypeName -Source ($script:DetachedProcessSource + ' ') | Should -Not -Be $current
        }
    }

    It 'lets a caller whose output is piped see the end of its pipes while the started process runs on' -Skip:(-not $IsWindows) {
        $standIn = New-StandIn 'direct' 25
        $log = Join-Path $TestDrive 'direct.log'
        $pidFile = Join-Path $TestDrive 'direct.pid'
        $parent = Start-PipedPwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:ParentScript, '-ModulesPath', $script:Modules,
            '-StandIn', $standIn, '-Log', $log, '-ErrorLog', (Join-Path $TestDrive 'direct.err.log'), '-PidFile', $pidFile)
        try {
            $parent.Process.WaitForExit(60000) | Should -BeTrue -Because 'the parent only starts the stand-in'
            $ended = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($parent.Out, $parent.Err), 10000)
            $standInPid = [int](Get-Content -LiteralPath $pidFile -Raw)

            $ended | Should -BeTrue -Because 'no process may keep a copy of the parent''s pipes'
            Get-Process -Id $standInPid -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'the stand-in sleeps 25 s'
            $parent.Out.Result | Should -Match "started $standInPid"
            $parent.Err.Result | Should -Match 'parent stderr line'
            Wait-LogLine $log 'standin-line' | Should -Match 'standin-line'
        }
        finally {
            Stop-StandIn $pidFile
            if (-not $parent.Process.HasExited) { $parent.Process.Kill($true) }
            $parent.Process.Dispose()
        }
    }

    It 'lets every caller up the chain see the end of its pipes, also one whose pipe the parent only inherited' -Skip:(-not $IsWindows) {
        # grandparent (pipes to this test) -> parent (pipes to the grandparent, plus the grandparent's pipe ends it
        # inherited as a native command) -> stand-in.
        $standIn = New-StandIn 'nested' 25
        $log = Join-Path $TestDrive 'nested.log'
        $pidFile = Join-Path $TestDrive 'nested.pid'
        $grandparent = Start-PipedPwsh @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:GrandparentScript, '-Pwsh', $script:Pwsh,
            '-ParentScript', $script:ParentScript, '-ModulesPath', $script:Modules, '-StandIn', $standIn, '-Log', $log,
            '-ErrorLog', (Join-Path $TestDrive 'nested.err.log'), '-PidFile', $pidFile)
        try {
            $grandparent.Process.WaitForExit(60000) | Should -BeTrue -Because 'the parent''s pipes must end for the grandparent to go on'
            $ended = [System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]@($grandparent.Out, $grandparent.Err), 10000)
            $standInPid = [int](Get-Content -LiteralPath $pidFile -Raw)

            $ended | Should -BeTrue -Because 'no process may keep a copy of the grandparent''s pipes'
            Get-Process -Id $standInPid -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'the stand-in sleeps 25 s'
            # The grandparent went on only after the parent's pipes ended, and that was before the stand-in ended.
            $grandparent.Out.Result | Should -Match 'parent-returned-ms=\d+'
            $grandparent.Out.Result | Should -Match "parent: started $standInPid"
            Wait-LogLine $log 'standin-line' | Should -Match 'standin-line'
        }
        finally {
            Stop-StandIn $pidFile
            if (-not $grandparent.Process.HasExited) { $grandparent.Process.Kill($true) }
            $grandparent.Process.Dispose()
        }
    }

    It 'gives the program a hidden console of its own, NUL as input, and closes the log files it opened' -Skip:(-not $IsWindows) {
        $standIn = Join-Path $TestDrive 'console.ps1'
        Set-Content -LiteralPath $standIn -Value @'
Add-Type -Namespace StandIn -Name Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);
"@
$window = [StandIn.Native]::GetConsoleWindow()
$attached = [StandIn.Native]::GetConsoleProcessList([uint[]]::new(64), 64)
$in = [Console]::In.ReadToEnd()
[Console]::Out.WriteLine("console=$([long]$window) visible=$([StandIn.Native]::IsWindowVisible($window)) processes=$attached stdin-length=$($in.Length)")
[Console]::Error.WriteLine('standin-error-line')
'@
        $log = Join-Path $TestDrive 'console.log'
        $errorLog = Join-Path $TestDrive 'console.err.log'
        # Logs that are there already, longer than what the stand-in writes, are written anew by a started program.
        Set-Content -LiteralPath $log -Value @(1..200 | ForEach-Object { "old output line $_" })
        Set-Content -LiteralPath $errorLog -Value @(1..200 | ForEach-Object { "old error line $_" })

        $processId = InModuleScope OctoDevStack -Parameters @{ p = $script:Pwsh; s = $standIn; l = $log; e = $errorLog; d = $TestDrive } {
            param($p, $s, $l, $e, $d)
            Start-OctoDevStackDetachedWindows -WorkingDirectory $d -LogPath $l -ErrorLogPath $e -FilePath $p -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $s)
        }
        $processId | Should -BeGreaterThan 0
        Wait-Process -Id $processId -Timeout 60 -ErrorAction SilentlyContinue
        $running = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($running) {
            # It still reads a standard input that never ends: stop it so the logs can be checked and removed.
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $processId -Timeout 15 -ErrorAction SilentlyContinue
        }
        $running | Should -BeNullOrEmpty -Because 'the stand-in ends by itself once its input (NUL) is read'

        $text = Get-Content -LiteralPath $log -Raw
        # Alone on a hidden console: what the CTRL_BREAK stop of Stop-OctoDevStackDaemon needs.
        $text | Should -Match 'console=[1-9]\d* visible=False processes=1 stdin-length=0'
        @(Get-Content -LiteralPath $log)[0] | Should -BeLike 'console=*'
        $text | Should -Not -Match 'old output line'
        $errorText = Get-Content -LiteralPath $errorLog -Raw
        @(Get-Content -LiteralPath $errorLog)[0] | Should -Be 'standin-error-line'
        $errorText | Should -Not -Match 'old error line'
        # Renaming fails while any process (this one included) still has a log file open.
        { Rename-Item -LiteralPath $log -NewName 'console.renamed.log' -ErrorAction Stop } | Should -Not -Throw
        { Rename-Item -LiteralPath $errorLog -NewName 'console.err.renamed.log' -ErrorAction Stop } | Should -Not -Throw
    }

    It 'fails with the Windows error when the program cannot be started, and deletes the empty logs it created' -Skip:(-not $IsWindows) {
        $notAProgram = Join-Path $TestDrive 'not-a-program.exe'
        Set-Content -LiteralPath $notAProgram -Value 'not a program'
        $log = Join-Path $TestDrive 'failed.log'
        $errorLog = Join-Path $TestDrive 'failed.err.log'

        {
            InModuleScope OctoDevStack -Parameters @{ p = $notAProgram; l = $log; e = $errorLog; d = $TestDrive } {
                param($p, $l, $e, $d)
                Start-OctoDevStackDetachedWindows -WorkingDirectory $d -LogPath $l -ErrorLogPath $e -FilePath $p -ArgumentList @('x')
            }
        } | Should -Throw 'CreateProcessW failed for *not-a-program.exe (working directory *): *(Win32 error *)'
        # The two empty logs it created are gone (the next start would keep them as the previous logs).
        Test-Path -LiteralPath $log | Should -BeFalse
        Test-Path -LiteralPath $errorLog | Should -BeFalse
    }

    It 'leaves a log that was there before a failed start in place and deletes only the one it created' -Skip:(-not $IsWindows) {
        $notAProgram = Join-Path $TestDrive 'not-a-program-2.exe'
        Set-Content -LiteralPath $notAProgram -Value 'not a program'
        $log = Join-Path $TestDrive 'kept.log'
        $errorLog = Join-Path $TestDrive 'kept.err.log'
        Set-Content -LiteralPath $log -Value 'output of the last real run'

        {
            InModuleScope OctoDevStack -Parameters @{ p = $notAProgram; l = $log; e = $errorLog; d = $TestDrive } {
                param($p, $l, $e, $d)
                Start-OctoDevStackDetachedWindows -WorkingDirectory $d -LogPath $l -ErrorLogPath $e -FilePath $p -ArgumentList @('x')
            }
        } | Should -Throw 'CreateProcessW failed for *'
        # The start opens the logs as Start-Process did (created or truncated), so its content may be gone; the file stays.
        Test-Path -LiteralPath $log | Should -BeTrue -Because 'the file was there before the start'
        Test-Path -LiteralPath $errorLog | Should -BeFalse -Because 'only the file the start created is deleted'
    }

    It 'names the working directory when it cannot be used' -Skip:(-not $IsWindows) {
        $missing = Join-Path $TestDrive 'no-such-folder'
        {
            InModuleScope OctoDevStack -Parameters @{ p = $script:Pwsh; d = $missing; l = (Join-Path $TestDrive 'wd.log'); e = (Join-Path $TestDrive 'wd.err.log') } {
                param($p, $d, $l, $e)
                Start-OctoDevStackDetachedWindows -WorkingDirectory $d -LogPath $l -ErrorLogPath $e -FilePath $p -ArgumentList @('-NoProfile', '-Command', 'exit')
            }
        } | Should -Throw "*working directory $missing*Win32 error 267*"
    }

    It 'refuses a relative path while the PowerShell location is not in the file system' -Skip:(-not $IsWindows) {
        $savedDirectory = [Environment]::CurrentDirectory
        $elsewhere = Join-Path $TestDrive 'process-folder-env'
        New-Item -ItemType Directory -Force -Path $elsewhere | Out-Null
        Push-Location -LiteralPath 'Env:'
        try {
            [Environment]::CurrentDirectory = $elsewhere
            {
                InModuleScope OctoDevStack -Parameters @{ p = $script:Pwsh; d = $TestDrive } {
                    param($p, $d)
                    Start-OctoDevStackDetachedWindows -WorkingDirectory $d -LogPath 'env-rel.log' -ErrorLogPath 'env-rel.err.log' -FilePath $p -ArgumentList @('-NoProfile', '-Command', 'exit')
                }
            } | Should -Throw '*env-rel.log*not a file system path*'
        }
        finally {
            [Environment]::CurrentDirectory = $savedDirectory
            Pop-Location
        }
        @(Get-ChildItem -LiteralPath $elsewhere).Count | Should -Be 0
    }

    It 'resolves relative paths against the PowerShell location, as Start-Process did' -Skip:(-not $IsWindows) {
        $here = Join-Path $TestDrive 'location'
        $elsewhere = Join-Path $TestDrive 'process-folder'
        New-Item -ItemType Directory -Force -Path $here, $elsewhere | Out-Null
        $standIn = Join-Path $TestDrive 'where.ps1'
        Set-Content -LiteralPath $standIn -Value "[Console]::Out.WriteLine('cwd=' + [Environment]::CurrentDirectory)"
        $savedDirectory = [Environment]::CurrentDirectory
        Push-Location -LiteralPath $here
        try {
            [Environment]::CurrentDirectory = $elsewhere
            $processId = InModuleScope OctoDevStack -Parameters @{ p = $script:Pwsh; s = $standIn } {
                param($p, $s)
                Start-OctoDevStackDetachedWindows -WorkingDirectory '.' -LogPath 'rel.log' -ErrorLogPath 'rel.err.log' -FilePath $p -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $s)
            }
            Wait-Process -Id $processId -Timeout 60 -ErrorAction SilentlyContinue
            if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { Stop-Process -Id $processId -Force; Wait-Process -Id $processId -Timeout 15 -ErrorAction SilentlyContinue }
        }
        finally {
            [Environment]::CurrentDirectory = $savedDirectory
            Pop-Location
        }

        Test-Path -LiteralPath (Join-Path $elsewhere 'rel.log') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $here 'rel.err.log') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $here 'rel.log') -Raw | Should -Match ('cwd=' + [regex]::Escape([IO.Path]::TrimEndingDirectorySeparator($here)))
    }
}
