<#
    Steerable test runs (AB#8813): Invoke-OctoTestRun runs the tests of ONE repository of a lane or feature
    environment - all test projects, single ones (-project) and/or a `dotnet test --filter` expression - without
    rebuilding everything, and returns a result a session can read: per test project the totals, the duration and the
    failed tests by full name with the first error message and stack frame (parsed from TRX).

    Docker-heavy suites (Testcontainers) of several sessions must not run at the same time: their containers starve
    each other and tests fail falsely. Such projects run under a machine-wide lock (Enter-OctoTestLock /
    Exit-OctoTestLock, Get-OctoTestLock, Remove-OctoTestLock): one file below the user's state folder that names its
    owner (pid, process start time, since when, which run).

    Invoke-BuildRange / Invoke-BuildEnvironment never run a test (-includeTests builds the test projects,
    -verifyTests compiles them), so this module is the only place that takes the lock.

    Layout of the results, below the lane (or environment) folder:
        <lane>/logFiles/test-results/<repo>/<project>/<run>/   *.trx, dotnet-test.log   (the newest 10 runs are kept)
        <lane>/logFiles/test-results/<repo>/<project>/last-result.json                  (read by -rerunFailed)
#>

$script:TestResultSchemaVersion = 1
$script:TestLockSchemaVersion = 1
$script:KeptTestRuns = 10
$script:MaxMessageLength = 1000
$script:MaxErrorLines = 10
# Folders a source walk never enters (same set as the package graph of OctoEnvironment.psm1).
$script:TestScanSkippedFolders = [System.Collections.Generic.HashSet[string]]::new([string[]]@('node_modules', 'bin', 'obj', '.git', '.vs', '.idea', 'TestResults', 'packages', '.nuget-packages', 'dist', '.angular', 'artifacts', 'coverage', '.nx', '.cache'), [StringComparer]::OrdinalIgnoreCase)
# Files whose change makes a build stale.
$script:TestSourceExtensions = [System.Collections.Generic.HashSet[string]]::new([string[]]@('.cs', '.csproj', '.props', '.targets', '.resx', '.razor', '.cshtml', '.proto', '.json', '.yaml', '.yml', '.xml', '.graphql', '.sql', '.sln', '.slnx'), [StringComparer]::OrdinalIgnoreCase)

# ---------------------------------------------------------------------------------------------------------------
# Shared plumbing
# ---------------------------------------------------------------------------------------------------------------

function Invoke-OctoModuleFunction {
    # Calls a function of another octo-tools module that the module does not export (the environment and build-range
    # helpers), so their logic is reused instead of copied. The module must be loaded (profile.ps1 loads all of them).
    param(
        [Parameter(Mandatory = $true)] [string]$module,
        [Parameter(Mandatory = $true)] [string]$name,
        [System.Collections.IDictionary]$arguments = @{}
    )
    $loaded = Get-Module -Name $module | Select-Object -First 1
    if ($null -eq $loaded) { throw "Module $module is not loaded - load modules/profile.ps1 first." }
    return & $loaded { param($functionName, $functionArguments) & $functionName @functionArguments } $name $arguments
}

function Get-OctoTestUtcNow {
    # A wrapper so tests can move the clock.
    return [DateTime]::UtcNow
}

function ConvertTo-OctoTestUtc {
    # ISO-8601 text (or a DateTime) as a UTC DateTime; $null when it cannot be read. ConvertFrom-Json turns
    # ISO-8601 strings into DateTime values of either kind, so both forms arrive here.
    param($value)
    if ($null -eq $value) { return $null }
    if ($value -is [DateTime]) {
        if ($value.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($value, [DateTimeKind]::Utc) }
        return $value.ToUniversalTime()
    }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------
# Machine-wide lock for Docker-heavy test suites
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoTestLockPath {
    <#
    .SYNOPSIS
        The file of the machine-wide lock for Docker-heavy test suites.
    .DESCRIPTION
        $env:OCTO_TEST_LOCK_PATH when set; otherwise <state>/octo-tools/locks/docker-tests.lock with <state> =
        %LOCALAPPDATA% on Windows and $XDG_STATE_HOME or ~/.local/state elsewhere. One file per user account: every
        session of the developer (and every agent) on this machine shares it.
    #>
    if (-not [string]::IsNullOrWhiteSpace($env:OCTO_TEST_LOCK_PATH)) { return $env:OCTO_TEST_LOCK_PATH }
    if ($IsWindows) {
        $state = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($state)) { $state = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) }
    }
    else {
        $state = $env:XDG_STATE_HOME
        if ([string]::IsNullOrWhiteSpace($state)) {
            $state = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) '.local/state'
        }
    }
    return Join-Path $state 'octo-tools/locks/docker-tests.lock'
}

function Get-OctoTestProcessStartTime {
    # UTC start time of a running process; $null when no process has the id. A process whose start time cannot be
    # read (access denied) counts as running with an unknown start time ([DateTime]::MinValue).
    param([Parameter(Mandatory = $true)] [int]$processId)
    try { $process = [System.Diagnostics.Process]::GetProcessById($processId) }
    catch { return $null }
    try { return $process.StartTime.ToUniversalTime() }
    catch { return [DateTime]::MinValue }
    finally { $process.Dispose() }
}

function Read-OctoTestLockFile {
    # The lock file as an ordered hashtable; $null when it does not exist; @{ unreadable = $true } when it holds no
    # JSON object (written by something else, or truncated).
    param([Parameter(Mandatory = $true)] [string]$path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        $text = [IO.File]::ReadAllText($path)
        $owner = $text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($owner -isnot [System.Collections.IDictionary] -or -not $owner.Contains('pid')) { throw 'no owner record' }
        return $owner
    }
    catch [System.IO.FileNotFoundException] { return $null }
    catch [System.IO.DirectoryNotFoundException] { return $null }
    catch { return @{ unreadable = $true } }
}

function Test-OctoTestLockOwnerAlive {
    # $true while the process that wrote the lock still runs: same pid AND same process start time (a recycled pid
    # has another start time). An unreadable lock file counts as alive for 30 seconds after its last write.
    param(
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary]$owner,
        [Parameter(Mandatory = $true)] [string]$path
    )
    if ($owner['unreadable']) {
        try { $age = (Get-OctoTestUtcNow) - [IO.File]::GetLastWriteTimeUtc($path) } catch { return $false }
        return $age.TotalSeconds -lt 30
    }
    $started = Get-OctoTestProcessStartTime -processId ([int]$owner['pid'])
    if ($null -eq $started) { return $false }
    $recorded = ConvertTo-OctoTestUtc $owner['processStartTime']
    # Unknown on either side: the pid runs, that is all we know - never take a lock away from a live process.
    if ($null -eq $recorded -or $started -eq [DateTime]::MinValue) { return $true }
    return [Math]::Abs(($started - $recorded).TotalSeconds) -lt 2
}

function ConvertTo-OctoTestLockReport {
    # The owner record for -Json / events (no id: it is the owner's handle).
    param([System.Collections.IDictionary]$owner)
    if ($null -eq $owner) { return $null }
    if ($owner['unreadable']) { return [ordered]@{ unreadable = $true } }
    $since = ConvertTo-OctoTestUtc $owner['since']
    $started = ConvertTo-OctoTestUtc $owner['processStartTime']
    return [ordered]@{
        pid              = [int]$owner['pid']
        processStartTime = if ($null -ne $started) { $started.ToString('o') } else { $null }
        since            = if ($null -ne $since) { $since.ToString('o') } else { $null }
        heldSeconds      = if ($null -ne $since) { [Math]::Round(((Get-OctoTestUtcNow) - $since).TotalSeconds, 1) } else { $null }
        user             = $owner['user']
        host             = $owner['host']
        command          = $owner['command']
        lane             = $owner['lane']
        environment      = $owner['environment']
        repo             = $owner['repo']
        projects         = @($owner['projects'] | Where-Object { $null -ne $_ })
    }
}

function Format-OctoTestLockOwner {
    param([System.Collections.IDictionary]$owner)
    if ($null -eq $owner) { return 'nobody' }
    if ($owner['unreadable']) { return 'an unreadable lock file' }
    $what = @($owner['repo'], (@($owner['projects']) -join ', ')) | Where-Object { $_ }
    $where = if ($owner['environment']) { "environment $($owner['environment'])" } else { [string]$owner['lane'] }
    $since = ConvertTo-OctoTestUtc $owner['since']
    $sinceText = if ($null -ne $since) { $since.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown' }
    return "pid $($owner['pid']) ($($owner['command']): $($what -join ' / ') in $where, since $sinceText)"
}

function Remove-OctoTestLockFile {
    <#
        Takes a lock file away whose owner is gone. Two waiting sessions may see the same stale file: only one wins
        the rename to a private name; it then checks that the file it moved is the one it judged (same id) and puts it
        back when another session had already replaced it. Returns $true when the stale file is gone.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary]$owner
    )
    $aside = "$path.stale-$([guid]::NewGuid().ToString('N'))"
    try { [IO.File]::Move($path, $aside) }
    catch { return -not (Test-Path -LiteralPath $path -PathType Leaf) }
    $moved = Read-OctoTestLockFile -path $aside
    $same = ($null -ne $moved) -and (([bool]$moved['unreadable'] -and [bool]$owner['unreadable']) -or ([string]$moved['id'] -eq [string]$owner['id'] -and -not $moved['unreadable']))
    if (-not $same) {
        # Not the file that was judged stale: a live owner took the lock in between. Give it back.
        try { [IO.File]::Move($aside, $path) } catch { Write-Warning "Could not restore the test lock $path that another session took: $($_.Exception.Message)" }
        return $false
    }
    Remove-Item -LiteralPath $aside -Force -ErrorAction SilentlyContinue
    return $true
}

function Enter-OctoTestLock {
    <#
    .SYNOPSIS
        Takes the machine-wide lock for Docker-heavy test suites, waiting for another owner up to a timeout.
    .DESCRIPTION
        The lock is one JSON file (Get-OctoTestLockPath). It is written completely under a private name and then
        moved into place without overwriting, so it either names its owner or does not exist. A lock whose owner
        process is gone (pid not running, or running with another start time) is stale and is replaced.
        Returns { Acquired; Id; Path; WaitedSeconds; Owner (the blocking owner when not acquired); StaleRemoved }.
        Release it with Exit-OctoTestLock -Id <Id> in a finally block.
    .PARAMETER Run
        What the lock is taken for, recorded in the file: command, lane, environment, repo, projects.
    .PARAMETER TimeoutSeconds
        How long to wait for another owner. 0 = do not wait.
    .PARAMETER OnWait
        Called once with the blocking owner (hashtable) when the lock is held by somebody else.
    #>
    param(
        [System.Collections.IDictionary]$Run = @{},
        [int]$TimeoutSeconds = 1800,
        [int]$PollMilliseconds = 2000,
        [string]$LockPath = '',
        [scriptblock]$OnWait = $null
    )
    $path = if ([string]::IsNullOrWhiteSpace($LockPath)) { Get-OctoTestLockPath } else { $LockPath }
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    $directory = [IO.Path]::GetDirectoryName($path)
    if ($directory -and -not [IO.Directory]::Exists($directory)) { [void][IO.Directory]::CreateDirectory($directory) }

    $id = [guid]::NewGuid().ToString('N')
    $started = Get-OctoTestProcessStartTime -processId $PID
    $record = [ordered]@{
        schemaVersion    = $script:TestLockSchemaVersion
        id               = $id
        pid              = $PID
        processStartTime = if ($null -ne $started -and $started -ne [DateTime]::MinValue) { $started.ToString('o') } else { $null }
        since            = $null
        user             = [Environment]::UserName
        host             = [Environment]::MachineName
        command          = [string]$Run['command']
        lane             = $Run['lane']
        environment      = $Run['environment']
        repo             = $Run['repo']
        projects         = @($Run['projects'] | Where-Object { $null -ne $_ })
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $staleRemoved = [System.Collections.Generic.List[object]]::new()
    $announced = $false
    $blocking = $null
    while ($true) {
        $record['since'] = (Get-OctoTestUtcNow).ToString('o')
        $pending = "$path.new-$id"
        [IO.File]::WriteAllText($pending, (ConvertTo-Json -InputObject $record -Depth 5), [Text.UTF8Encoding]::new($false))
        try {
            # Move without overwrite: fails when the lock exists, so exactly one session gets it.
            [IO.File]::Move($pending, $path)
            return [pscustomobject]@{ Acquired = $true; Id = $id; Path = $path; WaitedSeconds = $watch.Elapsed.TotalSeconds; Owner = $null; StaleRemoved = @($staleRemoved) }
        }
        catch [System.IO.IOException] { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
        catch { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue; throw }

        $owner = Read-OctoTestLockFile -path $path
        if ($null -eq $owner) { continue }   # released in between: try again at once
        if (-not (Test-OctoTestLockOwnerAlive -owner $owner -path $path)) {
            if (Remove-OctoTestLockFile -path $path -owner $owner) { $staleRemoved.Add((ConvertTo-OctoTestLockReport -owner $owner)) }
            continue
        }
        $blocking = $owner
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        if (-not $announced -and $null -ne $OnWait) { & $OnWait $owner }
        $announced = $true
        Start-Sleep -Milliseconds ([Math]::Max(1, $PollMilliseconds))
    }
    return [pscustomobject]@{ Acquired = $false; Id = $null; Path = $path; WaitedSeconds = $watch.Elapsed.TotalSeconds; Owner = $blocking; StaleRemoved = @($staleRemoved) }
}

function Exit-OctoTestLock {
    <#
    .SYNOPSIS
        Releases the machine-wide test lock taken with Enter-OctoTestLock; only the owner's own file (-Id) is removed.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$Id,
        [string]$LockPath = ''
    )
    $path = if ([string]::IsNullOrWhiteSpace($LockPath)) { Get-OctoTestLockPath } else { $LockPath }
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    $owner = Read-OctoTestLockFile -path $path
    if ($null -eq $owner -or $owner['unreadable'] -or [string]$owner['id'] -ne $Id) { return $false }
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    return -not (Test-Path -LiteralPath $path -PathType Leaf)
}

function Get-OctoTestLockState {
    param([string]$LockPath = '')
    $path = if ([string]::IsNullOrWhiteSpace($LockPath)) { Get-OctoTestLockPath } else { $LockPath }
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    $owner = Read-OctoTestLockFile -path $path
    $alive = if ($null -ne $owner) { Test-OctoTestLockOwnerAlive -owner $owner -path $path } else { $false }
    return [pscustomobject]@{ Path = $path; Owner = $owner; Alive = $alive }
}

<#
.SYNOPSIS
    Shows the machine-wide lock for Docker-heavy test suites: who holds it, since when, for which run.
.DESCRIPTION
    Invoke-OctoTestRun takes the lock while it runs test projects that start containers (Testcontainers), so only one
    such suite runs on this machine at a time. `stale` is true when the lock file is still there but its owner
    process is gone (pid not running, or running with another start time); the next run replaces it on its own,
    Remove-OctoTestLock removes it now.
    -Json data: { locked, stale, ownerAlive, path, owner { pid, processStartTime, since, heldSeconds, user, host,
    command, lane, environment, repo, projects } | null }.
.EXAMPLE
    Get-OctoTestLock
#>
function Get-OctoTestLock {
    [CmdletBinding()]
    param(
        [string]$LockPath = '',
        [switch]$Json
    )
    $state = Get-OctoTestLockState -LockPath $LockPath
    $locked = $null -ne $state.Owner
    $data = [ordered]@{
        locked     = $locked
        stale      = $locked -and -not $state.Alive
        ownerAlive = $locked -and $state.Alive
        path       = $state.Path
        owner      = ConvertTo-OctoTestLockReport -owner $state.Owner
    }
    $global:LASTEXITCODE = 0
    if ($Json) { Write-OctoJson -Command 'Get-OctoTestLock' -Data $data; return }
    if (-not $locked) { Write-Host "Test lock is free ($($state.Path))." -ForegroundColor Green; return }
    $color = if ($state.Alive) { 'Yellow' } else { 'Red' }
    Write-Host "Test lock $($state.Path) is held by $(Format-OctoTestLockOwner -owner $state.Owner)" -ForegroundColor $color
    if (-not $state.Alive) { Write-Host "  The owner process is gone: the lock is stale. The next test run replaces it; Remove-OctoTestLock removes it now." -ForegroundColor Red }
}

<#
.SYNOPSIS
    Removes the machine-wide test lock - only when its owner process is gone.
.DESCRIPTION
    A lock whose owner still runs is never removed (there is no -Force): stop that run instead. Without a lock file
    nothing happens. -Json data: { success, exitCode, removed, locked, ownerAlive, path, owner }.
.EXAMPLE
    Remove-OctoTestLock
#>
function Remove-OctoTestLock {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$LockPath = '',
        [switch]$Json
    )
    $state = Get-OctoTestLockState -LockPath $LockPath
    $locked = $null -ne $state.Owner
    $removed = $false
    $success = $true
    $message = "Test lock is free ($($state.Path)) - nothing to remove."
    if ($locked -and $state.Alive) {
        $success = $false
        $message = "Test lock $($state.Path) is held by $(Format-OctoTestLockOwner -owner $state.Owner), and that process is running - not removed. Stop that run instead."
    }
    elseif ($locked) {
        $message = "Removed the stale test lock of $(Format-OctoTestLockOwner -owner $state.Owner)."
        if ($PSCmdlet.ShouldProcess($state.Path, 'Remove the stale test lock')) {
            $removed = Remove-OctoTestLockFile -path $state.Path -owner $state.Owner
            if (-not $removed) {
                $success = $false
                $message = "Test lock $($state.Path) changed while it was removed (another session took it) - not removed."
            }
        }
        else { $message = "WhatIf: the stale test lock of $(Format-OctoTestLockOwner -owner $state.Owner) would be removed." }
    }
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    if ($Json) {
        Write-OctoJson -Command 'Remove-OctoTestLock' -Data (New-OctoActionResult -Success $success -ExitCode $global:LASTEXITCODE -Extra ([ordered]@{
                    removed    = $removed
                    locked     = $locked
                    ownerAlive = $locked -and $state.Alive
                    path       = $state.Path
                    owner      = ConvertTo-OctoTestLockReport -owner $state.Owner
                    message    = $message
                }))
        return
    }
    if ($success) { Write-Host $message -ForegroundColor Green } else { Write-Error $message }
}

# ---------------------------------------------------------------------------------------------------------------
# Docker capacity and limits for test containers (AB#8835)
# ---------------------------------------------------------------------------------------------------------------

function Invoke-OctoDocker {
    # The one place that calls the docker CLI (tests mock it). Returns { ExitCode; Output (string[]) }; exit code 127
    # when docker is not installed.
    param([Parameter(Mandatory = $true)] [string[]]$arguments)
    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ ExitCode = 127; Output = @('the docker command is not on PATH') }
    }
    $output = @(& docker @arguments 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function ConvertTo-OctoByteCount {
    # "6.154GiB", "572KiB", "3g", "1.5 GB", "2048" -> bytes; $null when it is no size.
    param([string]$text)
    if ([string]$text -notmatch '^\s*(?<number>\d+(\.\d+)?)\s*(?<unit>[kKmMgGtT]?)(?<binary>i?)[bB]?\s*$') { return $null }
    $number = [double]::Parse($Matches['number'], [Globalization.CultureInfo]::InvariantCulture)
    $power = switch ($Matches['unit'].ToLowerInvariant()) { 'k' { 1 } 'm' { 2 } 'g' { 3 } 't' { 4 } default { 0 } }
    # docker prints kB/MB/GB (1000) and KiB/MiB/GiB (1024); a bare "3g" as in `docker run --memory 3g` is 1024-based.
    $base = if ($Matches['binary'] -or $text -notmatch '[bB]\s*$') { 1024 } else { 1000 }
    return [long]($number * [Math]::Pow($base, $power))
}

function Get-OctoDockerCapacity {
    <#
        What the Docker engine has and what its running containers use right now: { Available; Error; MemoryBytes;
        Cpus; UsedBytes; FreeBytes; Containers = @({ Name; MemoryBytes }) }. On Docker Desktop the engine is one VM
        that the kind cluster (MongoDB, CrateDB, RabbitMQ of the local stack) and every test container share.
        Available is $false when docker cannot be asked; the caller decides what that means.
    #>
    $info = Invoke-OctoDocker -arguments @('info', '--format', '{{.MemTotal}} {{.NCPU}}')
    $line = @($info.Output | Where-Object { $_ -match '^\d+ \d+$' }) | Select-Object -Last 1
    if ($info.ExitCode -ne 0 -or -not $line) {
        return [pscustomobject]@{ Available = $false; Error = "docker info failed: $((@($info.Output) | Select-Object -Last 1))"; MemoryBytes = $null; Cpus = $null; UsedBytes = $null; FreeBytes = $null; Containers = @() }
    }
    $memory = [long]($line -split ' ')[0]
    $cpus = [int]($line -split ' ')[1]
    $stats = Invoke-OctoDocker -arguments @('stats', '--no-stream', '--format', '{{.Name}}|{{.MemUsage}}')
    $containers = @()
    if ($stats.ExitCode -eq 0) {
        $containers = @(foreach ($row in $stats.Output) {
                if ($row -notmatch '^(?<name>[^|]+)\|(?<used>[^/]+)/') { continue }
                $used = ConvertTo-OctoByteCount -text $Matches['used']
                if ($null -ne $used) { [pscustomobject]@{ Name = $Matches['name']; MemoryBytes = $used } }
            })
    }
    $usedTotal = [long](($containers | Measure-Object MemoryBytes -Sum).Sum)
    return [pscustomobject]@{
        Available = $true; Error = $(if ($stats.ExitCode -ne 0) { "docker stats failed: $((@($stats.Output) | Select-Object -Last 1))" })
        MemoryBytes = $memory; Cpus = $cpus; UsedBytes = $usedTotal; FreeBytes = [Math]::Max([long]0, [long]($memory - $usedTotal)); Containers = $containers
    }
}

function Invoke-OctoDockerLimitPass {
    <#
        One pass of the limiter: every running container Testcontainers started (label org.testcontainers=true) that
        was not seen before gets its CPU and memory limit with `docker update` - from outside the test code. The
        resource reaper (ryuk) is left alone. $State.Seen remembers the ids, $State.Limited collects
        { id; name; image; success; error }.
        Only containers of this run are touched. Docker cannot tell which run started a container, so two facts stand
        in for it: the label, and the creation time - a container created before $State.Since (the moment the run
        took the test lock; 5 seconds of clock difference to the engine are allowed) is never changed, nor is one
        whose creation time cannot be read. With the lock held, no other Invoke-OctoTestRun starts containers in that
        window; a Testcontainers suite somebody starts by hand in that window is limited too.
        A limit set this way starts a moment after the container did: a process that sized itself to the whole VM at
        start (a JVM heap, a database cache) keeps that size; a memory limit then is a ceiling that kills it when it
        grows past it. mongod sizes its WiredTiger cache to the whole VM at start and is OOM-killed (exit 137) under a
        memory limit set afterwards, so Invoke-OctoTestRun passes no memory by default (AB#8835). Limits at creation
        need the test fixture (see the readme).
    #>
    param(
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary]$State,
        [double]$Cpus = 0,
        [string]$Memory = ''
    )
    if ($Cpus -le 0 -and -not $Memory) { return }
    $list = Invoke-OctoDocker -arguments @('ps', '--no-trunc', '--filter', 'label=org.testcontainers=true', '--filter', 'status=running', '--format', '{{.ID}}|{{.Image}}|{{.Names}}|{{.CreatedAt}}')
    if ($list.ExitCode -ne 0) { return }
    foreach ($row in $list.Output) {
        $parts = ([string]$row) -split '\|', 4
        if ($parts.Count -lt 4 -or $parts[0] -notmatch '^[0-9a-f]{12,}$') { continue }
        $id = $parts[0]
        if ($State.Seen.Contains($id)) { continue }
        [void]$State.Seen.Add($id)
        if ($parts[1] -match '(^|/)ryuk(:|$)|testcontainers/ryuk') { continue }
        # "2026-11-11 16:34:50 +0100 CET": created before this run took the lock = not ours.
        $created = [DateTimeOffset]::MinValue
        $stamp = if ($parts[3] -match '^(?<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (?<sign>[+-])(?<hours>\d\d):?(?<minutes>\d\d)') { "$($Matches['time']) $($Matches['sign'])$($Matches['hours']):$($Matches['minutes'])" } else { '' }
        if (-not [DateTimeOffset]::TryParseExact($stamp, 'yyyy-MM-dd HH:mm:ss zzz', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$created)) { continue }
        if ($State.Since -is [DateTimeOffset] -and $created -lt $State.Since.AddSeconds(-5)) { continue }
        $arguments = @('update')
        if ($Cpus -gt 0) { $arguments += @('--cpus', $Cpus.ToString([Globalization.CultureInfo]::InvariantCulture)) }
        if ($Memory) { $arguments += @('--memory', $Memory, '--memory-swap', $Memory) }
        $arguments += $id
        $update = Invoke-OctoDocker -arguments $arguments
        [void]$State.Limited.Add([ordered]@{
                id = $id.Substring(0, 12); name = $parts[2]; image = $parts[1]; success = ($update.ExitCode -eq 0)
                error = $(if ($update.ExitCode -ne 0) { [string](@($update.Output) | Select-Object -Last 1) })
            })
    }
}

function Start-OctoDockerLimiter {
    # Runs Invoke-OctoDockerLimitPass every second in a background thread until Stop-OctoDockerLimiter. Returns the
    # handle { Job; State }, or $null when no limit is set.
    param([double]$Cpus = 0, [string]$Memory = '')
    if ($Cpus -le 0 -and -not $Memory) { return $null }
    $state = [hashtable]::Synchronized(@{
            Stop    = $false
            # Containers created before this moment are not this run's.
            Since   = [DateTimeOffset]::Now
            Seen    = [System.Collections.Generic.HashSet[string]]::new()
            Limited = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        })
    $job = Start-ThreadJob -ArgumentList $PSCommandPath, $state, $Cpus, $Memory -ScriptBlock {
        param([string]$modulePath, $state, [double]$cpus, [string]$memory)
        $module = Import-Module $modulePath -PassThru -Force
        while (-not $state.Stop) {
            try { & $module { param($s, $c, $m) Invoke-OctoDockerLimitPass -State $s -Cpus $c -Memory $m } $state $cpus $memory } catch { $null = $_ }
            Start-Sleep -Milliseconds 1000
        }
    }
    return [pscustomobject]@{ Job = $job; State = $state }
}

function Stop-OctoDockerLimiter {
    # Stops the limiter thread and returns what it limited.
    param($Limiter)
    if ($null -eq $Limiter) { return @() }
    $Limiter.State.Stop = $true
    [void](Wait-Job -Job $Limiter.Job -Timeout 10)
    Remove-Job -Job $Limiter.Job -Force -ErrorAction SilentlyContinue
    return @($Limiter.State.Limited)
}

# ---------------------------------------------------------------------------------------------------------------
# Test projects of a repository
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoTestRepoFiles {
    # Every file below a repository with one of the given extensions; never enters node_modules, bin, obj, .git,
    # generated output or symbolic links (a plain recursive Get-ChildItem would enumerate node_modules completely).
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        [Parameter(Mandatory = $true)] [System.Collections.Generic.HashSet[string]]$extensions
    )
    $files = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        try {
            foreach ($file in [IO.Directory]::EnumerateFiles($directory)) {
                if ($extensions.Contains([IO.Path]::GetExtension($file))) { $files.Add($file) }
            }
            foreach ($child in [IO.Directory]::EnumerateDirectories($directory)) {
                if ($script:TestScanSkippedFolders.Contains([IO.Path]::GetFileName($child))) { continue }
                if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($child)
            }
        }
        catch [System.UnauthorizedAccessException] { continue }
        catch [System.IO.IOException] { continue }
    }
    return @($files)
}

function Read-OctoTestProjectFile {
    # What a csproj or Directory.Build.props says about tests: IsTestProject, AssemblyName, package and project
    # references. Unparsable files yield nothing (a warning names the file).
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        # Directory.Build.props applies to many projects: there only elements without a Condition (on themselves or
        # their group) count, so a rule such as "projects named *Tests are test projects" marks nothing by mistake.
        [switch]$unconditionalOnly
    )
    $info = [pscustomobject]@{ IsTestProject = $null; AssemblyName = $null; OutputType = $null; Packages = @(); ProjectReferences = @() }
    try { [xml]$xml = Get-Content -LiteralPath $path -Raw }
    catch { Write-Warning "Cannot parse $path - ignored for the test project detection: $($_.Exception.Message)"; return $info }
    if ($unconditionalOnly) {
        foreach ($node in @($xml.SelectNodes("//*[@Condition]"))) { [void]$node.ParentNode.RemoveChild($node) }
    }
    $flag = @($xml.SelectNodes("//*[local-name()='IsTestProject']")) | Select-Object -Last 1
    if ($null -ne $flag) { $info.IsTestProject = ([string]$flag.InnerText).Trim() -ieq 'true' }
    $assembly = @($xml.SelectNodes("//*[local-name()='AssemblyName']")) | Select-Object -Last 1
    if ($null -ne $assembly -and ([string]$assembly.InnerText).Trim() -notmatch '\$\(') { $info.AssemblyName = ([string]$assembly.InnerText).Trim() }
    $outputType = @($xml.SelectNodes("//*[local-name()='OutputType']")) | Select-Object -Last 1
    if ($null -ne $outputType) { $info.OutputType = ([string]$outputType.InnerText).Trim() }
    $info.Packages = @($xml.SelectNodes("//*[local-name()='PackageReference']") | ForEach-Object { [string]$_.GetAttribute('Include') } | Where-Object { $_ })
    $directory = Split-Path -Parent $path
    $info.ProjectReferences = @($xml.SelectNodes("//*[local-name()='ProjectReference']") | ForEach-Object { [string]$_.GetAttribute('Include') } | Where-Object { $_ -and $_ -notmatch '\$\(' } |
        ForEach-Object { [IO.Path]::GetFullPath((Join-Path $directory ($_ -replace '\\', '/'))) })
    return $info
}

function Test-OctoTestPackageSet {
    <#
        Do these package references make a project a test project? Microsoft.NET.Test.Sdk (VSTest), or a framework
        that brings its own runner on Microsoft.Testing.Platform: TUnit (the package that carries the engine and the TRX
        report; TUnit.Engine alone does not count), MSTest, or xunit.v3 in an executable
        (-outputType Exe). octo-communication-operator's tests reference only TUnit - no Test.Sdk, no IsTestProject.
    #>
    param([string[]]$packages = @(), [string]$outputType = '')
    if ($packages -contains 'Microsoft.NET.Test.Sdk') { return $true }
    if (@($packages | Where-Object { $_ -ieq 'TUnit' -or $_ -ieq 'MSTest' }).Count -gt 0) { return $true }
    return ($outputType -ieq 'Exe' -and @($packages | Where-Object { $_ -match '^xunit\.v3($|\.)' }).Count -gt 0)
}

function Get-OctoTestRunner {
    <#
        'mtp' when the nearest global.json from the project folder up to the repository root selects
        Microsoft.Testing.Platform ({ "test": { "runner": "Microsoft.Testing.Platform" } }): with the .NET 10 SDK
        `dotnet test` then runs the test applications themselves and takes other arguments. Otherwise 'vstest'.
    #>
    param([Parameter(Mandatory = $true)] [string]$projectDirectory, [Parameter(Mandatory = $true)] [string]$repositoryRoot)
    # Returns { Runner; Directory }: Directory is the folder of the global.json that decided (the repository root
    # without one) - `dotnet test` must start there, because the CLI reads global.json from its current folder up.
    # The search goes on above the repository (a global.json in the lane folder applies to every repository below it);
    # dotnet then starts in the repository root, from where the CLI finds that file.
    $directory = $projectDirectory
    while ($directory) {
        $file = Join-Path $directory 'global.json'
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            $runner = 'vstest'
            try {
                $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
                if ($json -is [System.Collections.IDictionary] -and $json['test'] -is [System.Collections.IDictionary] -and [string]$json['test']['runner'] -ieq 'Microsoft.Testing.Platform') { $runner = 'mtp' }
            }
            catch { Write-Warning "Cannot parse $file - the test runner counts as VSTest: $($_.Exception.Message)" }
            $inside = $directory.Length -ge $repositoryRoot.Length -and $directory.StartsWith($repositoryRoot, [StringComparison]::OrdinalIgnoreCase)
            return [pscustomobject]@{ Runner = $runner; Directory = $(if ($inside) { $directory } else { $repositoryRoot }) }
        }
        $parent = Split-Path -Parent $directory
        if (-not $parent -or $parent -eq $directory) { break }
        $directory = $parent
    }
    return [pscustomobject]@{ Runner = 'vstest'; Directory = $repositoryRoot }
}

function Get-OctoTestProjects {
    <#
        The test projects of a repository: every csproj (outside bin/obj/node_modules/...) that sets
        <IsTestProject>true</IsTestProject> or references Microsoft.NET.Test.Sdk - in the project itself or in a
        Directory.Build.props between it and the repository root; an explicit <IsTestProject>false</IsTestProject> in
        the project wins. Each entry: Name (csproj name), Path, RelativePath, Directory, AssemblyName, Docker,
        DockerReason, ProjectReferences (transitive, existing files).
        Docker marker: a PackageReference to Testcontainers or Testcontainers.* in the project, in such a
        Directory.Build.props, or in a project it references (transitively).
    #>
    param([Parameter(Mandatory = $true)] [string]$repositoryPath)
    # Relative to $PWD (AB#8954): [IO.Path]::GetFullPath would resolve against the process start directory.
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($repositoryPath)))
    $extensions = [System.Collections.Generic.HashSet[string]]::new([string[]]@('.csproj'), [StringComparer]::OrdinalIgnoreCase)
    $cache = @{}
    $read = {
        param([string]$file)
        if (-not $cache.ContainsKey($file)) {
            $cache[$file] = Read-OctoTestProjectFile -path $file -unconditionalOnly:([IO.Path]::GetExtension($file) -ieq '.props')
        }
        return $cache[$file]
    }
    $projects = @()
    foreach ($file in @(Get-OctoTestRepoFiles -path $root -extensions $extensions | Sort-Object)) {
        $own = & $read $file
        # Directory.Build.props files from the project folder up to the repository root.
        $inherited = @()
        $directory = Split-Path -Parent $file
        while ($directory -and $directory.Length -ge $root.Length) {
            $props = Join-Path $directory 'Directory.Build.props'
            if (Test-Path -LiteralPath $props -PathType Leaf) { $inherited += (& $read $props) }
            if ($directory -ieq $root) { break }
            $directory = Split-Path -Parent $directory
        }
        $isTest = $own.IsTestProject
        $allPackages = @($own.Packages) + @($inherited | ForEach-Object { $_.Packages })
        if ($null -eq $isTest) {
            $isTest = (Test-OctoTestPackageSet -packages $allPackages -outputType $own.OutputType) -or
                @($inherited | Where-Object { $_.IsTestProject -eq $true }).Count -gt 0
        }
        if (-not $isTest) { continue }

        # Transitive project references (breadth first, each file once).
        $references = [System.Collections.Generic.List[string]]::new()
        $queue = [System.Collections.Generic.Queue[string]]::new()
        foreach ($reference in $own.ProjectReferences) { $queue.Enqueue($reference) }
        while ($queue.Count -gt 0) {
            $reference = $queue.Dequeue()
            if ($references.Contains($reference) -or -not (Test-Path -LiteralPath $reference -PathType Leaf)) { continue }
            $references.Add($reference)
            foreach ($next in (& $read $reference).ProjectReferences) { $queue.Enqueue($next) }
        }

        $dockerReason = $null
        $sources = @([pscustomobject]@{ File = $file; Info = $own }) + @($references | ForEach-Object { [pscustomobject]@{ File = $_; Info = (& $read $_) } })
        foreach ($source in $sources) {
            $package = @($source.Info.Packages | Where-Object { $_ -match '^Testcontainers(\.|$)' }) | Select-Object -First 1
            if ($package) { $dockerReason = "PackageReference $package in $([IO.Path]::GetFileName($source.File))"; break }
        }
        if (-not $dockerReason -and @($inherited | Where-Object { @($_.Packages | Where-Object { $_ -match '^Testcontainers(\.|$)' }).Count -gt 0 }).Count -gt 0) {
            $dockerReason = 'PackageReference Testcontainers in a Directory.Build.props'
        }

        $name = [IO.Path]::GetFileNameWithoutExtension($file)
        $runner = Get-OctoTestRunner -projectDirectory (Split-Path -Parent $file) -repositoryRoot $root
        $projects += [pscustomobject]@{
            Name              = $name
            Path              = $file
            RelativePath      = ([IO.Path]::GetRelativePath($root, $file) -replace '\\', '/')
            Directory         = (Split-Path -Parent $file)
            AssemblyName      = if ($own.AssemblyName) { $own.AssemblyName } else { $name }
            Docker            = [bool]$dockerReason
            DockerReason      = $dockerReason
            # How `dotnet test` runs it (vstest | mtp) and which framework's filter and report options apply.
            Runner            = $runner.Runner
            # Where `dotnet test` starts: the folder whose global.json selected the runner.
            RunnerDirectory   = $runner.Directory
            Framework         = if (@($allPackages | Where-Object { $_ -ieq 'TUnit' }).Count -gt 0) { 'tunit' } elseif (@($allPackages | Where-Object { $_ -match '^xunit\.v3($|\.)' }).Count -gt 0) { 'xunit3' } else { 'other' }
            ProjectReferences = @($references | ForEach-Object { [pscustomobject]@{ Path = $_; Directory = (Split-Path -Parent $_); AssemblyName = $(if ((& $read $_).AssemblyName) { (& $read $_).AssemblyName } else { [IO.Path]::GetFileNameWithoutExtension($_) }) } })
        }
    }
    return $projects
}

function Get-OctoFrontendTestProjects {
    <#
        The frontend test projects of a repository (AB#8819): every folder (outside node_modules/dist/..., at most four
        levels deep) that holds an angular.json and a package.json with a "test" script; the search goes on below a
        workspace without one. Each entry has the shape of Get-OctoTestProjects plus Kind = 'frontend': Name (the folder
        name; the folder path relative to the repository, with dots, when two workspaces share a folder name), Path (its
        package.json), Directory.
    #>
    param([Parameter(Mandatory = $true)] [string]$repositoryPath)
    # Relative to $PWD (AB#8954): [IO.Path]::GetFullPath would resolve against the process start directory.
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($repositoryPath)))
    $skip = @('node_modules', 'dist', 'bin', 'obj', '.git', '.angular', 'coverage', 'artifacts', 'test-results', '.claude')
    $projects = @()
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue([pscustomobject]@{ Path = $root; Depth = 0 })
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $package = Join-Path $item.Path 'package.json'
        if ((Test-Path -LiteralPath $package -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $item.Path 'angular.json') -PathType Leaf)) {
            $scripts = $null
            try { $scripts = (Get-Content -LiteralPath $package -Raw | ConvertFrom-Json).scripts } catch { $scripts = $null }
            if ($scripts -and $scripts.PSObject.Properties['test']) {
                $projects += [pscustomobject]@{
                    Kind = 'frontend'; Name = (Split-Path -Leaf $item.Path); Path = $package
                    RelativePath = ([IO.Path]::GetRelativePath($root, $package) -replace '\\', '/'); Directory = $item.Path
                    AssemblyName = (Split-Path -Leaf $item.Path); Docker = $false; DockerReason = $null; ProjectReferences = @()
                }
                continue   # an Angular workspace with tests holds no further one
            }
        }
        if ($item.Depth -ge 4) { continue }
        foreach ($child in @(Get-ChildItem -LiteralPath $item.Path -Directory -ErrorAction SilentlyContinue | Where-Object { $skip -notcontains $_.Name -and -not $_.LinkType } | Sort-Object Name)) {
            $queue.Enqueue([pscustomobject]@{ Path = $child.FullName; Depth = $item.Depth + 1 })
        }
    }
    # Two workspaces in folders of the same name (apps/web, tools/web) would share the results folder, last-result.json
    # and the -project name: those get their folder path relative to the repository as the name (apps.web, tools.web).
    foreach ($group in @($projects | Group-Object Name | Where-Object Count -gt 1)) {
        foreach ($entry in $group.Group) {
            $relative = ([IO.Path]::GetRelativePath($root, $entry.Directory) -replace '[\\/]+', '.').Trim('.')
            if ($relative) { $entry.Name = $relative; $entry.AssemblyName = $relative }
        }
    }
    return $projects
}

function Test-OctoFrontendTestProject {
    param($project)
    return ($null -ne $project.PSObject.Properties['Kind'] -and $project.Kind -eq 'frontend')
}

function Read-OctoJUnitFile {
    <#
        Reads one JUnit XML report (vitest / `ng test --reporters=junit`). Same shape as Read-OctoTrxFile. A failed test's
        Name is "<spec file> :: <test name>" - the spec file is what -rerunFailed runs again.
    #>
    param([Parameter(Mandatory = $true)] [string]$path)
    [xml]$xml = Get-Content -LiteralPath $path -Raw
    $total = 0; $passed = 0; $failed = 0; $skipped = 0; $seconds = 0.0
    $failedTests = [System.Collections.Generic.List[object]]::new()
    $passedTests = [System.Collections.Generic.List[string]]::new()
    foreach ($case in @($xml.SelectNodes('//testcase'))) {
        $total++
        $time = 0.0
        [void][double]::TryParse([string]$case.GetAttribute('time'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$time)
        $seconds += $time
        $problem = $case.SelectSingleNode('failure')
        if ($null -eq $problem) { $problem = $case.SelectSingleNode('error') }
        if ($null -eq $problem) {
            if ($null -ne $case.SelectSingleNode('skipped')) { $skipped++ }
            else {
                $passed++
                $passedFile = [string]$case.GetAttribute('classname'); $passedName = [string]$case.GetAttribute('name')
                $passedTests.Add($(if ($passedFile -and $passedFile -ne $passedName) { "$passedFile :: $passedName" } else { $passedName }))
            }
            continue
        }
        $failed++
        $file = [string]$case.GetAttribute('classname')
        $testName = [string]$case.GetAttribute('name')
        $message = ([string]$problem.GetAttribute('message')).Trim()
        if ($message.Length -gt $script:MaxMessageLength) { $message = $message.Substring(0, $script:MaxMessageLength) + ' ...' }
        # The first line of the body that names a place (vitest marks it with an arrow), else the first line after the message.
        $lines = @(([string]$problem.InnerText) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $frame = @($lines | Where-Object { $_ -match '^(\u276f|at )\s*\S' -or $_ -match '\.(ts|js|mjs):\d+' }) | Select-Object -First 1
        $frameText = $null
        if ($frame) { $frameText = (([string]$frame) -replace '^\u276f\s*', '') }
        $failedTests.Add([pscustomobject]@{
                Name            = if ($file -and $file -ne $testName) { "$file :: $testName" } else { $testName }
                DisplayName     = $testName
                Outcome         = 'Failed'
                Message         = if ($message) { $message } else { $null }
                StackFrame      = $frameText
                DurationSeconds = $time
            })
    }
    return [pscustomobject]@{
        Path = $path; Total = $total; Passed = $passed; Failed = $failed; Skipped = $skipped
        DurationSeconds = $seconds; FailedTests = @($failedTests); PassedTests = @($passedTests); RunErrors = @()
    }
}

function Invoke-OctoFrontendTest {
    # The one place that starts a frontend test run (tests mock it): `npx ng test ...` in the app's folder, after
    # `npm ci` when it has no node_modules. All output goes to the log; returns the exit code.
    param(
        [Parameter(Mandatory = $true)] [string]$directory,
        [Parameter(Mandatory = $true)] [string[]]$arguments,
        [Parameter(Mandatory = $true)] [string]$logFile
    )
    Push-Location -LiteralPath $directory
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $directory 'node_modules') -PathType Container)) {
            'Invoke-OctoTestRun: npm ci (no node_modules)' | Add-Content -LiteralPath $logFile
            & npm ci *>> $logFile
            if ($LASTEXITCODE -ne 0) { return $LASTEXITCODE }
        }
        & npx @arguments *>> $logFile
        return $LASTEXITCODE
    }
    finally { Pop-Location }
}

function Resolve-OctoTestProject {
    # -project: the csproj name, its path relative to the repository, or a unique part of the name.
    param(
        [Parameter(Mandatory = $true)] [string]$name,
        [Parameter(Mandatory = $true)] [object[]]$projects
    )
    $wanted = ($name -replace '\\', '/') -replace '\.csproj$', ''
    $exact = @($projects | Where-Object { $_.Name -ieq $wanted -or ($_.RelativePath -replace '\.csproj$', '') -ieq $wanted })
    if ($exact.Count -eq 1) { return $exact[0] }
    $partial = @($projects | Where-Object { $_.Name -like "*$wanted*" })
    if ($partial.Count -eq 1) { return $partial[0] }
    if ($partial.Count -gt 1) { throw "Test project '$name' is ambiguous. Candidates: $(($partial.Name) -join ', ')" }
    throw "Test project '$name' not found. Test projects of the repository: $(($projects.Name) -join ', ')"
}

function Get-OctoTestOutputTime {
    # Newest <AssemblyName>.dll below <project>/bin/<configuration> (UTC), or $null without a build output. The newest,
    # not the oldest: folders of a target framework the project no longer builds stay behind after an upgrade.
    param(
        [Parameter(Mandatory = $true)] [string]$projectDirectory,
        [Parameter(Mandatory = $true)] [string]$assemblyName,
        [Parameter(Mandatory = $true)] [string]$configuration
    )
    $bin = Join-Path $projectDirectory "bin/$configuration"
    if (-not (Test-Path -LiteralPath $bin -PathType Container)) { return $null }
    $newest = Get-ChildItem -LiteralPath $bin -Recurse -File -Filter "$assemblyName.dll" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -eq $newest) { return $null }
    return $newest.LastWriteTimeUtc
}

function Get-OctoTestNewestSource {
    # The most recently written source file of a repository: { Time (UTC); File } or $null.
    param([Parameter(Mandatory = $true)] [string]$repositoryPath)
    $newestTime = [DateTime]::MinValue
    $newestFile = $null
    foreach ($file in @(Get-OctoTestRepoFiles -path $repositoryPath -extensions $script:TestSourceExtensions)) {
        $time = [IO.File]::GetLastWriteTimeUtc($file)
        if ($time -gt $newestTime) { $newestTime = $time; $newestFile = $file }
    }
    if ($null -eq $newestFile) { return $null }
    return [pscustomobject]@{ Time = $newestTime; File = $newestFile }
}

function Get-OctoTestBuildState {
    <#
        Is the build of a test project current, so `dotnet test --no-build` runs what the sources say?
        Not current when: there is no <AssemblyName>.dll below bin/<configuration>; a source file of the repository is
        newer than it; the output of a referenced project is newer (a src-only build ran after the tests were built);
        or (DebugL) the lane feed holds a newer build of a 999.0.0 package the project restored (an upstream library
        was rebuilt). Returns { Current; Reason }.
    #>
    param(
        [Parameter(Mandatory = $true)] [object]$project,
        [Parameter(Mandatory = $true)] [string]$repositoryPath,
        [Parameter(Mandatory = $true)] [string]$configuration,
        [string]$laneFeed = '',
        # Get-OctoTestNewestSource of the repository, computed once per run.
        $newestSource = $null
    )
    $output = Get-OctoTestOutputTime -projectDirectory $project.Directory -assemblyName $project.AssemblyName -configuration $configuration
    if ($null -eq $output) {
        # A build with -verifyTests compiles the solution's projects: one that is not in the solution stays unbuilt.
        $hint = ''
        try {
            $solution = Invoke-OctoModuleFunction -module 'Invoke-BuildRange' -name 'Get-OctoRepoSolution' -arguments @{ path = $repositoryPath }
            if ($solution -and $project.PSObject.Properties['RelativePath']) {
                $inSolution = @(Invoke-OctoModuleFunction -module 'Invoke-BuildRange' -name 'Get-OctoSolutionProjects' -arguments @{ solutionPath = $solution.FullName } | ForEach-Object { $_ -replace '\\', '/' })
                if ($inSolution -notcontains $project.RelativePath) { $hint = " (the project is not in $($solution.Name): a build with -verifyTests or -includeTests does not compile it)" }
            }
        }
        catch { $hint = '' }
        return [pscustomobject]@{ Current = $false; Reason = "no $configuration build output of $($project.Name)$hint" }
    }
    if ($null -ne $newestSource -and $newestSource.Time -gt $output) {
        $relative = [IO.Path]::GetRelativePath($repositoryPath, $newestSource.File) -replace '\\', '/'
        return [pscustomobject]@{ Current = $false; Reason = "source changed after the last build ($relative)" }
    }
    foreach ($reference in @($project.ProjectReferences)) {
        $referenceOutput = Get-OctoTestOutputTime -projectDirectory $reference.Directory -assemblyName $reference.AssemblyName -configuration $configuration
        if ($null -ne $referenceOutput -and $referenceOutput -gt $output) {
            return [pscustomobject]@{ Current = $false; Reason = "$([IO.Path]::GetFileNameWithoutExtension($reference.Path)) was built after $($project.Name)" }
        }
    }
    if ($configuration -ieq 'DebugL' -and $laneFeed -and (Test-Path -LiteralPath $laneFeed -PathType Container)) {
        $assets = Join-Path $project.Directory 'obj/project.assets.json'
        if (Test-Path -LiteralPath $assets -PathType Leaf) {
            $ids = @([regex]::Matches([IO.File]::ReadAllText($assets), '"(?<id>[^"/]+)/999\.0\.0"') | ForEach-Object { $_.Groups['id'].Value } | Sort-Object -Unique)
            foreach ($id in $ids) {
                $package = Join-Path $laneFeed "$id.999.0.0.nupkg"
                if ((Test-Path -LiteralPath $package -PathType Leaf) -and [IO.File]::GetLastWriteTimeUtc($package) -gt $output) {
                    return [pscustomobject]@{ Current = $false; Reason = "the lane feed holds a newer $id.999.0.0.nupkg" }
                }
            }
        }
    }
    return [pscustomobject]@{ Current = $true; Reason = 'build output is newer than the sources, the referenced projects and the lane packages' }
}

# ---------------------------------------------------------------------------------------------------------------
# TRX
# ---------------------------------------------------------------------------------------------------------------

function Get-OctoTestFilterName {
    # The name `dotnet test --filter FullyQualifiedName=` matches: <class>.<method>, without theory arguments.
    param([string]$className, [string]$methodName, [string]$testName)
    $method = [string]$methodName
    $cut = $method.IndexOf('(')
    if ($cut -gt 0) { $method = $method.Substring(0, $cut) }
    if ($className -and $method) {
        if ($method.StartsWith("$className.", [StringComparison]::Ordinal)) { return $method }
        return "$className.$method"
    }
    $name = [string]$testName
    $cut = $name.IndexOf('(')
    if ($cut -gt 0) { $name = $name.Substring(0, $cut) }
    return $name.Trim()
}

function Read-OctoTrxFile {
    <#
        Reads one TRX file (`dotnet test --logger trx`). Returns Total / Passed / Failed / Skipped (counted from the
        results; the summary counters when the file lists none), DurationSeconds, FailedTests (every one: Name =
        <class>.<method> for filters, DisplayName, Message, StackFrame, DurationSeconds) and RunErrors (run-level
        messages, e.g. an aborted test host).
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$path,
        # Names of passed tests to collect (-includePassed); 0 = none.
        [int]$maxPassed = 0
    )
    [xml]$xml = Get-Content -LiteralPath $path -Raw
    $methods = @{}
    foreach ($unitTest in @($xml.SelectNodes("//*[local-name()='TestDefinitions']/*[local-name()='UnitTest']"))) {
        $method = $unitTest.SelectSingleNode("*[local-name()='TestMethod']")
        if ($null -ne $method) { $methods[[string]$unitTest.GetAttribute('id')] = $method }
    }
    $total = 0; $passed = 0; $failed = 0; $skipped = 0
    $failedTests = [System.Collections.Generic.List[object]]::new()
    $passedTests = [System.Collections.Generic.List[string]]::new()
    $durationSum = [TimeSpan]::Zero
    foreach ($result in @($xml.SelectNodes("//*[local-name()='Results']/*[local-name()='UnitTestResult']"))) {
        $total++
        $duration = [TimeSpan]::Zero
        [void][TimeSpan]::TryParse([string]$result.GetAttribute('duration'), [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
        $durationSum += $duration
        $outcome = [string]$result.GetAttribute('outcome')
        if ($outcome -in @('Passed', 'PassedButRunAborted', 'Warning', 'Completed')) {
            $passed++
            if ($passedTests.Count -lt $maxPassed) {
                $method = $methods[[string]$result.GetAttribute('testId')]
                $passedTests.Add((Get-OctoTestFilterName -className $(if ($method) { $method.GetAttribute('className') }) -methodName $(if ($method) { $method.GetAttribute('name') }) -testName $result.GetAttribute('testName')))
            }
            continue
        }
        if ($outcome -notin @('Failed', 'Error', 'Timeout', 'Aborted')) { $skipped++; continue }
        $failed++
        $method = $methods[[string]$result.GetAttribute('testId')]
        $message = [string]$result.SelectSingleNode("*[local-name()='Output']/*[local-name()='ErrorInfo']/*[local-name()='Message']").InnerText
        $stack = [string]$result.SelectSingleNode("*[local-name()='Output']/*[local-name()='ErrorInfo']/*[local-name()='StackTrace']").InnerText
        $message = $message.Trim()
        if ($message.Length -gt $script:MaxMessageLength) { $message = $message.Substring(0, $script:MaxMessageLength) + ' ...' }
        $frame = @($stack -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
        $failedTests.Add([pscustomobject]@{
                Name            = Get-OctoTestFilterName -className $(if ($method) { $method.GetAttribute('className') }) -methodName $(if ($method) { $method.GetAttribute('name') }) -testName $result.GetAttribute('testName')
                DisplayName     = [string]$result.GetAttribute('testName')
                Outcome         = $outcome
                Message         = if ($message) { $message } else { $null }
                StackFrame      = if ($frame) { [string]$frame } else { $null }
                DurationSeconds = $duration.TotalSeconds
            })
    }
    $counters = $xml.SelectSingleNode("//*[local-name()='ResultSummary']/*[local-name()='Counters']")
    if ($total -eq 0 -and $null -ne $counters) {
        $total = [int]$counters.GetAttribute('total')
        $passed = [int]$counters.GetAttribute('passed')
        $failed = [int]$counters.GetAttribute('failed') + [int]$counters.GetAttribute('error') + [int]$counters.GetAttribute('timeout') + [int]$counters.GetAttribute('aborted')
        $skipped = [Math]::Max(0, $total - $passed - $failed)
    }
    $seconds = $durationSum.TotalSeconds
    $times = $xml.SelectSingleNode("//*[local-name()='Times']")
    if ($null -ne $times) {
        $start = [DateTimeOffset]::MinValue; $finish = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$times.GetAttribute('start'), [ref]$start) -and [DateTimeOffset]::TryParse([string]$times.GetAttribute('finish'), [ref]$finish) -and $finish -ge $start) {
            $seconds = ($finish - $start).TotalSeconds
        }
    }
    $runErrors = @($xml.SelectNodes("//*[local-name()='ResultSummary']/*[local-name()='RunInfos']/*[local-name()='RunInfo'][@outcome='Error' or @outcome='Failed']/*[local-name()='Text']") |
        ForEach-Object { ([string]$_.InnerText).Trim() } |
        # xunit repeats every failed test as a run-level "[xUnit.net 00:00:01.14]  <test> [FAIL]" line: not a run error.
        # Microsoft.Testing.Platform repeats its exit code there: no news either.
        Where-Object { $_ -and $_ -notmatch '^\[xUnit\.net [\d:.]+\]\s+.*\[FAIL\]$' -and $_ -notmatch '^Exit code indicates failure' } |
        ForEach-Object { if ($_.Length -gt $script:MaxMessageLength) { $_.Substring(0, $script:MaxMessageLength) + ' ...' } else { $_ } })
    return [pscustomobject]@{
        Path = $path; Total = $total; Passed = $passed; Failed = $failed; Skipped = $skipped
        DurationSeconds = $seconds; FailedTests = @($failedTests); PassedTests = @($passedTests); RunErrors = $runErrors
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------------------------------------------

function ConvertTo-OctoTestFilterValue {
    # Escapes the characters that are operators in a `dotnet test --filter` expression.
    param([Parameter(Mandatory = $true)] [string]$value)
    return [regex]::Replace($value, '[\\()&|=!~]', { param($m) '\' + $m.Value })
}

function Get-OctoTestFilterChunks {
    <#
        Filters that run exactly the given tests: FullyQualifiedName=<a>|FullyQualifiedName=<b>|..., split into
        several filters so that none is longer than -maxLength (a command line has a length limit), each combined
        with the caller's own -filter as (<filter>)&(<names>). A single name longer than the limit gets its own
        filter. Returns one string per `dotnet test` call.
    #>
    param(
        [string[]]$names = @(),
        [string]$filter = '',
        [int]$maxLength = 6000
    )
    $clauses = @($names | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { "FullyQualifiedName=$(ConvertTo-OctoTestFilterValue -value $_)" })
    $wrap = {
        param([string[]]$group)
        $joined = $group -join '|'
        if ([string]::IsNullOrWhiteSpace($filter)) { return $joined }
        return "($filter)&($joined)"
    }
    $overhead = if ([string]::IsNullOrWhiteSpace($filter)) { 0 } else { $filter.Length + 5 }
    $chunks = [System.Collections.Generic.List[string]]::new()
    $group = [System.Collections.Generic.List[string]]::new()
    $length = $overhead
    foreach ($clause in $clauses) {
        $added = $clause.Length + $(if ($group.Count -gt 0) { 1 } else { 0 })
        if ($group.Count -gt 0 -and ($length + $added) -gt $maxLength) {
            $chunks.Add((& $wrap $group.ToArray()))
            $group.Clear()
            $length = $overhead
            $added = $clause.Length
        }
        $group.Add($clause)
        $length += $added
    }
    if ($group.Count -gt 0) { $chunks.Add((& $wrap $group.ToArray())) }
    return @($chunks)
}

function Get-OctoTestFilterCalls {
    <#
        The `dotnet test` calls of one test project: per call the filter arguments and how they read.
        Returns { Calls = @({ Display; Arguments }); Mismatch } - Mismatch is set (and Calls empty) when -filter is
        written in a form the project's runner does not take.

        -filter is passed through in the project's own filter language:
          VSTest (and MSTest/NUnit on Microsoft.Testing.Platform): an expression, --filter FullyQualifiedName~Name
          TUnit:   a tree-node filter,  --treenode-filter /*/*/ClassName/*      (starts with "/")
          xunit.v3 on Microsoft.Testing.Platform: a query filter, --filter-query /*/*/ClassName/*   (starts with "/")
        -failedNames (-rerunFailed, <namespace>.<class>.<method>) become calls that run exactly those tests:
          VSTest:   FullyQualifiedName=..|.. clauses, combined with -filter, split at -maxLength
          TUnit:    one tree-node filter per class, /*/<namespace>/<class>/(<method>|<method>)
          xunit.v3: --filter-method <name> per test, split at -maxLength
        For the two Microsoft.Testing.Platform forms -filter is not combined with the rerun (no AND there).
    #>
    param(
        [Parameter(Mandatory = $true)] $project,
        [string]$filter = '',
        [string[]]$failedNames = $null,
        [int]$maxLength = 6000
    )
    $runner = if ($project.PSObject.Properties['Runner']) { [string]$project.Runner } else { 'vstest' }
    $framework = if ($project.PSObject.Properties['Framework']) { [string]$project.Framework } else { 'other' }
    $kind = if ($runner -ne 'mtp') { 'expression' } elseif ($framework -eq 'tunit') { 'treenode' } elseif ($framework -eq 'xunit3') { 'query' } else { 'expression' }
    $call = { param([string]$display, [string[]]$arguments) [pscustomobject]@{ Display = $display; Arguments = @($arguments) } }
    $isTree = $filter.TrimStart().StartsWith('/')
    $mismatch = $null
    if ($filter) {
        if ($kind -eq 'expression' -and $isTree) { $mismatch = "the filter '$filter' is a tree filter; $($project.Name) takes a filter expression such as FullyQualifiedName~ClassName" }
        elseif ($kind -eq 'treenode' -and -not $isTree) { $mismatch = "the filter '$filter' is a filter expression; $($project.Name) (TUnit on Microsoft.Testing.Platform) takes a tree-node filter such as /*/*/ClassName/* or /*/*/*/MethodName" }
        elseif ($kind -eq 'query' -and -not $isTree) { $mismatch = "the filter '$filter' is a filter expression; $($project.Name) (xunit.v3 on Microsoft.Testing.Platform) takes a query filter such as /*/*/ClassName/* or /*/*/*/MethodName" }
    }

    if ($null -eq $failedNames) {
        if ($mismatch) { return [pscustomobject]@{ Calls = @(); Mismatch = $mismatch } }
        if (-not $filter) { return [pscustomobject]@{ Calls = @((& $call '' @())); Mismatch = $null } }
        $option = switch ($kind) { 'treenode' { '--treenode-filter' } 'query' { '--filter-query' } default { '--filter' } }
        return [pscustomobject]@{ Calls = @((& $call $filter @($option, $filter))); Mismatch = $null }
    }

    $names = @($failedNames | Where-Object { $_ } | Sort-Object -Unique)
    $calls = [System.Collections.Generic.List[object]]::new()
    if ($kind -eq 'expression') {
        # The rerun is combined with -filter here: a filter this runner cannot take matches nothing, also in a rerun.
        if ($mismatch) { return [pscustomobject]@{ Calls = @(); Mismatch = $mismatch } }
        foreach ($chunk in @(Get-OctoTestFilterChunks -names $names -filter $filter -maxLength $maxLength)) { $calls.Add((& $call $chunk @('--filter', $chunk))) }
    }
    elseif ($kind -eq 'treenode') {
        # <namespace>.<class>.<method>: one filter per class, its methods as alternatives.
        $classes = [ordered]@{}
        foreach ($name in $names) {
            $cut = $name.LastIndexOf('.')
            $class = if ($cut -gt 0) { $name.Substring(0, $cut) } else { '' }
            $method = if ($cut -gt 0) { $name.Substring($cut + 1) } else { $name }
            if (-not $classes.Contains($class)) { $classes[$class] = [System.Collections.Generic.List[string]]::new() }
            $classes[$class].Add($method)
        }
        foreach ($class in $classes.Keys) {
            $cut = $class.LastIndexOf('.')
            $namespace = if ($cut -gt 0) { $class.Substring(0, $cut) } else { '*' }
            $className = if ($cut -gt 0) { $class.Substring($cut + 1) } elseif ($class) { $class } else { '*' }
            $prefix = "/*/$namespace/$className/"
            $group = [System.Collections.Generic.List[string]]::new()
            $length = $prefix.Length + 2
            foreach ($method in $classes[$class]) {
                if ($group.Count -gt 0 -and ($length + $method.Length + 1) -gt $maxLength) {
                    $text = "$prefix($($group -join '|'))"; $calls.Add((& $call $text @('--treenode-filter', $text)))
                    $group.Clear(); $length = $prefix.Length + 2
                }
                $group.Add($method); $length += $method.Length + 1
            }
            if ($group.Count -gt 0) { $text = "$prefix($($group -join '|'))"; $calls.Add((& $call $text @('--treenode-filter', $text))) }
        }
    }
    else {
        $group = [System.Collections.Generic.List[string]]::new()
        $length = 0
        $flush = {
            $arguments = @(foreach ($name in $group) { '--filter-method'; $name })
            $calls.Add((& $call (($group | ForEach-Object { "--filter-method $_" }) -join ' ') $arguments))
        }
        foreach ($name in $names) {
            $added = $name.Length + 17
            if ($group.Count -gt 0 -and ($length + $added) -gt $maxLength) { & $flush; $group.Clear(); $length = 0 }
            $group.Add($name); $length += $added
        }
        if ($group.Count -gt 0) { & $flush }
    }
    return [pscustomobject]@{ Calls = @($calls); Mismatch = $null }
}

# ---------------------------------------------------------------------------------------------------------------
# Running
# ---------------------------------------------------------------------------------------------------------------

function Invoke-OctoDotnetTest {
    # The one place that starts `dotnet test` (tests mock it). All output goes to the log; returns the exit code.
    # -workingDirectory: the repository - `dotnet test` reads global.json (the test runner) from the current folder up.
    param(
        [Parameter(Mandatory = $true)] [string[]]$arguments,
        [Parameter(Mandatory = $true)] [string]$logFile,
        [string]$workingDirectory = ''
    )
    if ($workingDirectory) { Push-Location -LiteralPath $workingDirectory }
    try {
        & dotnet @arguments *>> $logFile
        return $LASTEXITCODE
    }
    finally { if ($workingDirectory) { Pop-Location } }
}

function Get-OctoTestLogErrors {
    # Up to 10 distinct error lines of a dotnet log (the tail when it has none), feed credentials masked.
    param([string]$logFile)
    if (-not $logFile -or -not (Test-Path -LiteralPath $logFile -PathType Leaf)) { return @() }
    $lines = @(Get-Content -LiteralPath $logFile -ErrorAction SilentlyContinue)
    $errors = @($lines | Where-Object { $_ -match '(\berror\b|\bFAILED\b|aborted|Unhandled exception)' } | ForEach-Object { $_.Trim() } | Select-Object -Unique -First $script:MaxErrorLines)
    if ($errors.Count -eq 0) { $errors = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 5 | ForEach-Object { $_.Trim() }) }
    return @($errors | ForEach-Object {
            $line = Hide-OctoUrlCredentials $_
            if ($line.Length -gt 500) { $line.Substring(0, 500) + ' ...' } else { $line }
        })
}

function Get-OctoTestResultsRoot {
    param([Parameter(Mandatory = $true)] [string]$lanePath, [Parameter(Mandatory = $true)] [string]$repo)
    return Join-Path $lanePath "logFiles/test-results/$repo"
}

function Read-OctoTestLastResult {
    # last-result.json of a test project, or $null.
    param([Parameter(Mandatory = $true)] [string]$projectResultsPath)
    $file = Join-Path $projectResultsPath 'last-result.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
    catch { Write-Warning "Cannot read $file - treated as no previous result: $($_.Exception.Message)"; return $null }
}

function Remove-OctoTestOldRuns {
    # Keeps the newest run folders of a test project.
    param([Parameter(Mandatory = $true)] [string]$projectResultsPath, [int]$keep = $script:KeptTestRuns)
    $runs = @(Get-ChildItem -LiteralPath $projectResultsPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($run in @($runs | Select-Object -Skip $keep)) {
        Remove-Item -LiteralPath $run.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-OctoTestInPlaceProperties {
    <#
        The global MSBuild properties of an in-place worktree of a feature environment, the same ones
        Invoke-BuildEnvironment passes: RestoreSources (Get-OctoInPlaceRestoreSources, credentials split off),
        RestorePackagesPath and OctoLocalCatalogRootPath of the environment. Returns { Properties; Sources;
        Credentials } - the caller writes the credentials into an owner-only RestoreConfigFile.
    #>
    param(
        [Parameter(Mandatory = $true)] [string]$repositoryPath,
        [Parameter(Mandatory = $true)] [string]$environmentPath,
        [Parameter(Mandatory = $true)] [string]$basePath
    )
    $sources = Invoke-OctoModuleFunction -module 'OctoEnvironment' -name 'Get-OctoInPlaceRestoreSources' -arguments @{
        repositoryPath  = $repositoryPath
        environmentFeed = (Join-Path $environmentPath 'nuget')
        userPropsPaths  = @((Join-Path $basePath 'Octo.User.props'), (Join-Path $environmentPath 'Octo.User.props'))
    }
    $split = Invoke-OctoModuleFunction -module 'OctoEnvironment' -name 'Split-OctoSourceCredentials' -arguments @{ restoreSources = $sources }
    return [pscustomobject]@{
        Properties  = @{
            RestoreSources           = ($split.Sources -join ';')
            RestorePackagesPath      = (Join-Path $environmentPath '.nuget-packages')
            OctoLocalCatalogRootPath = (Join-Path $environmentPath '.octo/local-catalog')
        }
        Sources     = @($split.Sources)
        Credentials = $split.Credentials
    }
}

function Resolve-OctoTestTarget {
    <#
        Where the tests run: the lane folder (results, feed, isolation), the repository folder and, for a feature
        environment, whether the repository is an in-place worktree. Throws with a message for the caller.
    #>
    param([string]$env = '', [string]$branch = '', [Parameter(Mandatory = $true)] [string]$repo)
    if ($env -and $branch) { throw 'Pass either -env or -branch, not both.' }
    if (-not $env -and -not $branch) { throw 'Pass -env <environment> or -branch <lane> (e.g. -branch branches/main).' }

    if ($env) {
        $manifest = Invoke-OctoModuleFunction -module 'OctoEnvironment' -name 'Read-OctoEnvironmentManifest' -arguments @{ env = $env }
        if ($null -eq $manifest) { throw "Environment $env does not exist." }
        $environmentPath = Invoke-OctoModuleFunction -module 'OctoEnvironment' -name 'Get-OctoEnvironmentPath' -arguments @{ env = $env }
        $basePath = Invoke-OctoModuleFunction -module 'OctoEnvironment' -name 'Get-OctoEnvironmentBasePath' -arguments @{ base = ([string]$manifest['base']) }
        $order = @($manifest['repos'] | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ Name = [string]$_['name']; Path = [string]$_['path']; Entry = $_ } })
        if ($order.Count -eq 0) { throw "Environment $env holds no repository - add one with Add-OctoEnvironmentRepo -env $env -repo <name>." }
        $broken = @($order | Where-Object { [string]::IsNullOrWhiteSpace($_.Name) -or [string]::IsNullOrWhiteSpace($_.Path) })
        if ($broken.Count -gt 0) { throw "The manifest of environment $env lists a repository without name or path ($environmentPath/.octo/environment.json)." }
        try { $selected = Invoke-OctoModuleFunction -module 'Invoke-BuildRange' -name 'Resolve-OctoBuildRangeRepo' -arguments @{ name = $repo; order = $order } }
        catch { throw "$($_.Exception.Message -replace 'the build order', "environment $env") Tests of a repository outside the environment run in its base lane (-branch $($manifest['base']))." }
        $inPlace = [bool](Invoke-OctoModuleFunction -module 'OctoEnvironment' -name 'Test-OctoEnvironmentRepoInPlace' -arguments @{ repo = $selected.Entry; environmentPath = $environmentPath })
        return [pscustomobject]@{ Environment = $env; LanePath = $environmentPath; BasePath = $basePath; Repo = $selected.Name; RepoPath = $selected.Path; InPlace = $inPlace }
    }

    $root = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace([string]$root)) { throw "`$rootPath is not set - load modules/profile.ps1 first." }
    $resolved = Resolve-OctoBranchRootPath -branch $branch -root ([string]$root)
    $lanePath = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($resolved.BranchRootPath))
    if (-not (Test-Path -LiteralPath $lanePath -PathType Container)) { throw "Checkout $lanePath does not exist." }
    $order = @(Get-OctoBuildOrder -branchRootPath $lanePath -excludeFrontend $false -excludeAdditional $false | Where-Object { $null -ne $_ })
    # Only folders named octo-* / mm-* are repositories of a lane (Get-OctoBuildOrder); say so instead of failing on
    # an empty list or a name that cannot match.
    $outside = ''
    if (Test-Path -LiteralPath (Join-Path $lanePath $repo) -PathType Container) {
        # A consumer app (energy-community, voest-app): not part of a lane's build order, but its tests run here.
        if (Test-Path -LiteralPath (Join-Path (Join-Path $lanePath $repo) '.git')) {
            return [pscustomobject]@{ Environment = $null; LanePath = $lanePath; BasePath = $null; Repo = $repo; RepoPath = (Join-Path $lanePath $repo); InPlace = $false }
        }
        $outside = " The folder $(Join-Path $lanePath $repo) exists, but only folders named octo-* or mm-* (or a git repository named exactly) are repositories of a lane."
    }
    if ($order.Count -eq 0) {
        throw "Lane $lanePath holds no repository (no folder named octo-* or mm-*) - '$repo' cannot be resolved.$outside Pass the lane that holds the repositories with -branch (e.g. branches/main), or -env <environment>."
    }
    try { $selected = Invoke-OctoModuleFunction -module 'Invoke-BuildRange' -name 'Resolve-OctoBuildRangeRepo' -arguments @{ name = $repo; order = $order } }
    catch { throw "$($_.Exception.Message -replace 'the build order', "the build order of $lanePath")$outside" }
    return [pscustomobject]@{ Environment = $null; LanePath = $lanePath; BasePath = $null; Repo = $selected.Name; RepoPath = $selected.Path; InPlace = $false }
}

function Write-OctoTestRunSummary {
    # Human output: the failed tests first, then one line per test project.
    param([Parameter(Mandatory = $true)] [System.Collections.IDictionary]$data)
    $failedProjects = @($data.projects | Where-Object { @($_.failedTests).Count -gt 0 -or $_.state -in @('error', 'noTests') })
    if ($failedProjects.Count -gt 0) {
        Write-Host ''
        Write-Host 'Failed tests:' -ForegroundColor Red
        foreach ($project in $failedProjects) {
            Write-Host "  $($project.project)" -ForegroundColor Red
            foreach ($test in @($project.failedTests)) {
                Write-Host "    x $($test.name)" -ForegroundColor Red
                if ($test.displayName -and $test.displayName -ne $test.name) { Write-Host "        $($test.displayName)" -ForegroundColor DarkGray }
                if ($test.message) { Write-Host "        $(($test.message -split "`r?`n")[0])" }
                if ($test.stackFrame) { Write-Host "        $($test.stackFrame)" -ForegroundColor DarkGray }
            }
            if ($project.truncated) { Write-Host "    ... $($project.failed - @($project.failedTests).Count) more failed test(s), see $(@($project.trx) -join ', ')" -ForegroundColor Red }
            foreach ($line in @($project.errors)) { Write-Host "    $line" -ForegroundColor Red }
        }
    }
    Write-Host ''
    Write-Host "Summary (Invoke-OctoTestRun, $($data.repo), $($data.configuration)):"
    Write-Host '---------------------------------'
    foreach ($project in @($data.projects)) {
        $color = switch ($project.state) { 'passed' { 'Green' } 'failed' { 'Red' } 'error' { 'Red' } 'noTests' { 'Red' } default { 'DarkGray' } }
        $line = '{0,-55} {1,-8} total {2,5}  passed {3,5}  failed {4,4}  skipped {5,4}  {6,8}' -f $project.project, $project.state, $project.total, $project.passed, $project.failed, $project.skipped, (Format-OctoTestDuration -seconds $project.durationSeconds)
        Write-Host $line -ForegroundColor $color
        if ($project.note) { Write-Host "    $($project.note)" -ForegroundColor DarkGray }
        if ($project.state -in @('failed', 'error', 'noTests')) {
            foreach ($file in @($project.trx)) { Write-Host "    trx: $file" -ForegroundColor DarkGray }
            if ($project.logFile) { Write-Host "    log: $($project.logFile)" -ForegroundColor DarkGray }
        }
    }
    Write-Host '---------------------------------'
    Write-Host ("Total: {0} test(s), {1} passed, {2} failed, {3} skipped in {4}" -f $data.totals.total, $data.totals.passed, $data.totals.failed, $data.totals.skipped, (Format-OctoTestDuration -seconds $data.elapsedSeconds))
    if ($data.totals.failed -gt 0) { Write-Host 'Run only the failed tests again: add -rerunFailed to the same call.' -ForegroundColor Yellow }
}

function Format-OctoTestDuration {
    param([double]$seconds)
    if ($seconds -ge 60) { return '{0:N0}m {1:N0}s' -f [Math]::Floor($seconds / 60), ($seconds % 60) }
    return '{0:N1}s' -f $seconds
}

<#
.SYNOPSIS
    Runs the tests of one repository of a lane or feature environment and returns a readable result.

.DESCRIPTION
    Runs `dotnet test` for the test projects of -repo (all of them, or the ones named with -project), optionally with
    a `dotnet test --filter` expression, and reports per test project the totals, the duration and the failed tests
    by full name with the first error message and stack frame.

    No full rebuild: with -build Auto (default) a project whose build is current runs with --no-build; otherwise
    `dotnet test` builds it first (incremental) and the result says why ("source changed after the last build
    (src/X/Y.cs)", "the lane feed holds a newer <package>", "no DebugL build output"). -build Always never passes
    --no-build, -build Never always does.

    Isolation is the lane's, as in Invoke-BuildRange / Invoke-BuildEnvironment: an isolated lane (every feature
    environment) runs with NUGET_PACKAGES=<lane>/.nuget-packages, MSBUILDDISABLENODEREUSE=1 and, in DebugL for a
    repository without its own <RestoreSources>, RestoreSources=<lane>/nuget;nuget.org. An in-place worktree of an
    environment gets the environment's RestoreSources, RestorePackagesPath and OctoLocalCatalogRootPath as global
    properties, credentials in an owner-only RestoreConfigFile that is deleted afterwards. The process environment
    is restored after the run.

    Docker-heavy projects (a Testcontainers package reference in the project or a project it references; -dockerLock
    Always / Never overrides the detection) run one at a time on this machine: the run takes the machine-wide test
    lock before the first of them and releases it after the last one. Projects that need no Docker run first,
    without the lock. When another run holds the lock, this one waits up to -lockTimeoutSeconds and then fails with
    failedStep "lock" and the owner (see Get-OctoTestLock); a lock whose owner process is gone is replaced.

    Results: <lane>/logFiles/test-results/<repo>/<project>/<run>/ holds the TRX file(s) and dotnet-test.log (the
    newest 10 runs are kept); last-result.json next to the run folders holds the last result of the project with
    every failed test name. -rerunFailed reads it and runs only those tests (FullyQualifiedName filters, split into
    several `dotnet test` calls when the filter would get too long); the result of that run then replaces it, so
    repeated -rerunFailed calls narrow down to what still fails.

    All test projects are run, also after one failed. $LASTEXITCODE is 0 when every executed test passed, else 1.
    A run with -filter or -rerunFailed in which no test ran at all fails (the filter matches nothing). Without a
    filter, a project that runs no test fails the run (state noTests): it is never reported green.

    Projects on Microsoft.Testing.Platform (the repository's global.json selects that runner: TUnit, xunit.v3) are
    run with `dotnet test --project <csproj> ... -- --report-trx`, VSTest projects with `dotnet test <csproj>
    --logger trx`; the result names the runner of each project.

.PARAMETER env
    Feature environment (wt-<env>). Either -env or -branch.

.PARAMETER branch
    Lane checkout, resolved like Invoke-BuildRange -branch (e.g. branches/main).

.PARAMETER repo
    Repository: the folder name, the name without "octo-", or a unique part of it.

.PARAMETER project
    Test project(s): csproj name, path relative to the repository, or a unique part of the name. Default: all.

.PARAMETER filter
    A filter in the language of the project's runner: for VSTest projects a `dotnet test --filter` expression, e.g.
    'FullyQualifiedName~RtEntityTests' or 'Category!=Slow'; for TUnit a tree-node filter and for xunit.v3 on
    Microsoft.Testing.Platform a query filter, both of the form '/<assembly>/<namespace>/<class>/<method>' with '*'
    as wildcard, e.g. '/*/*/RtEntityTests/*'. A project whose runner cannot take the given form is not started
    (state noMatch). Projects in which the filter matches no test are noMatch too; the run fails only when no test
    ran in any project.

.PARAMETER includePassed
    Also list the names of the passed tests per project (passedTests), at most -maxPassed (default 200).

.PARAMETER rerunFailed
    Run only the tests that failed in the last result of each selected project. Projects without failed tests in
    their last result are skipped.

.PARAMETER build
    Auto (default): --no-build when the build is current. Always: build. Never: --no-build.

.PARAMETER dockerLock
    Auto (default): lock for projects with a Testcontainers reference. Always: for every project. Never: no lock.

.PARAMETER dockerCheck
    Refuse (default): do not start the Docker-heavy projects when the Docker engine has less free memory than
    -minDockerFreeMemoryGiB (failedStep "docker"). Warn: start them anyway. Off: do not ask docker. The test
    containers share the engine (on Docker Desktop one VM) with the kind cluster of the local stack.

.PARAMETER minDockerFreeMemoryGiB
    Free memory of the Docker engine the Docker-heavy projects need: its total memory minus what the running
    containers use (default 3).

.PARAMETER dockerCpus
    CPU limit for every container Testcontainers starts during the run (default 4, 0 = none), set with
    `docker update` about a second after the container started. Safe after the start: a CPU limit only slows a
    container down.

.PARAMETER dockerMemory
    Opt-in memory limit for those containers (default '' = none; 0 = none). Not safe for every image: it is set with
    `docker update` after the container started, when a process has already sized itself to the whole Docker VM -
    mongod sizes its WiredTiger cache that way and is OOM-killed (exit 137) under the limit, the tests then hang in
    database timeouts. Use it only for containers whose memory use is bounded at creation (for MongoDB a
    `--wiredTigerCacheSizeGB` the fixture sets); the run warns when it is set and passes the value to the test
    process as OCTO_TEST_CONTAINER_MEMORY_BYTES, so a fixture can set the limit at creation instead.

.PARAMETER lockTimeoutSeconds
    How long to wait for the machine-wide test lock (default 1800). 0 = fail at once when it is taken.

.PARAMETER maxFailures
    Failed tests listed per project (default 50); `truncated` tells when there are more. last-result.json and the
    TRX always hold all of them.

.PARAMETER EventsFile
    Append progress events (one JSON object per line, Write-OctoBuildEvent, command "Invoke-OctoTestRun"):
    plan, lockWait, lockAcquired, testProjectStart, testProjectDone, lockReleased, done. Nothing under -WhatIf.

.PARAMETER WhatIf
    Print the plan (projects, Docker marker, build or --no-build and why, the dotnet calls) and run nothing.

.PARAMETER Json
    Emit a single JSON document (standard envelope).

.EXAMPLE
    Invoke-OctoTestRun -env ab8625-enum-null -repo construction-kit-engine -project Engine.Tests -filter 'FullyQualifiedName~EnumTests'

.EXAMPLE
    Invoke-OctoTestRun -branch branches/main -repo octo-asset-repo-services -Json

.EXAMPLE
    Invoke-OctoTestRun -env ab8625-enum-null -repo construction-kit-engine -rerunFailed
#>
function Invoke-OctoTestRun {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$env = '',
        [string]$branch = '',
        [Parameter(Mandatory = $true)] [string]$repo,
        [string[]]$project = @(),
        [string]$filter = '',
        [switch]$rerunFailed,
        [ValidateSet('Auto', 'Always', 'Never')] [string]$build = 'Auto',
        [ValidateSet('Auto', 'Always', 'Never')] [string]$dockerLock = 'Auto',
        [int]$lockTimeoutSeconds = 1800,
        [int]$lockPollMilliseconds = 2000,
        [string]$lockPath = '',
        [ValidateSet('Refuse', 'Warn', 'Off')] [string]$dockerCheck = 'Refuse',
        [double]$minDockerFreeMemoryGiB = 3,
        [double]$dockerCpus = 4,
        [string]$dockerMemory = '',
        [string]$configuration = 'DebugL',
        [int]$maxFailures = 50,
        [switch]$includePassed,
        [int]$maxPassed = 200,
        [int]$maxFilterLength = 6000,
        [string]$EventsFile = '',
        [switch]$Json
    )
    $command = 'Invoke-OctoTestRun'
    $whatIf = [bool]$WhatIfPreference
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $eventsPath = if ($whatIf) { '' } else { $EventsFile }
    $emit = {
        param([string]$name, [System.Collections.IDictionary]$data)
        Write-OctoBuildEvent -Path $eventsPath -Command $command -Event $name -Data $data
    }
    $totals = [ordered]@{ total = 0; passed = 0; failed = 0; skipped = 0 }
    $fail = {
        param([string]$message, [string]$step = 'preflight')
        $global:LASTEXITCODE = 1
        & $emit 'done' ([ordered]@{ success = $false; failedRepo = $repo; failedProject = $null; failedStep = $step; elapsedSeconds = $watch.Elapsed.TotalSeconds; total = 0; passed = 0; failed = 0; skipped = 0 })
        if ($Json) {
            Write-OctoJson -Command $command -Data ([ordered]@{ success = $false; exitCode = 1; error = $message; failedStep = $step; repo = $repo; totals = $totals; projects = @() })
        }
        else { Write-Error $message }
    }

    try {
        $target = Resolve-OctoTestTarget -env $env -branch $branch -repo $repo
        if (-not (Test-Path -LiteralPath $target.RepoPath -PathType Container)) { throw "Repository folder $($target.RepoPath) does not exist." }
        $repo = $target.Repo
        $allProjects = @(Get-OctoTestProjects -repositoryPath $target.RepoPath) + @(Get-OctoFrontendTestProjects -repositoryPath $target.RepoPath)
        if ($allProjects.Count -eq 0) { throw "$repo has no test project (no csproj with <IsTestProject>true</IsTestProject> or a Microsoft.NET.Test.Sdk reference, and no Angular workspace with a ""test"" script in its package.json, below $($target.RepoPath))." }
        $selected = $allProjects
        if (@($project | Where-Object { $_ }).Count -gt 0) {
            $names = @($project | Where-Object { $_ } | ForEach-Object { (Resolve-OctoTestProject -name $_ -projects $allProjects).Name })
            $selected = @($allProjects | Where-Object { $names -contains $_.Name })
        }
    }
    catch { & $fail $_.Exception.Message; return }

    $resultsRoot = Get-OctoTestResultsRoot -lanePath $target.LanePath -repo $repo
    $laneSettings = Get-OctoLaneBuildSettings -laneRootPath $target.LanePath
    $newestSource = if ($build -eq 'Auto') { Get-OctoTestNewestSource -repositoryPath $target.RepoPath } else { $null }

    # The plan: per project what runs (filters), whether it builds and whether it needs the lock.
    $plan = @()
    foreach ($entry in $selected) {
        $projectResults = Join-Path $resultsRoot $entry.Name
        $frontendEntry = Test-OctoFrontendTestProject $entry
        $calls = @()
        $noMatch = $null
        $skip = $null
        $rerunCount = $null
        $rerunFiles = @()
        if ($rerunFailed) {
            $last = Read-OctoTestLastResult -projectResultsPath $projectResults
            $failedNames = @()
            if ($null -ne $last) { $failedNames = @($last['failedTests'] | Where-Object { $_ }) }
            if ($null -eq $last) { $skip = 'no previous result - run the project without -rerunFailed first' }
            elseif ($failedNames.Count -eq 0 -and $last['state'] -eq 'error') { $skip = 'the last run produced no test result (state error) - run the project without -rerunFailed' }
            elseif ($failedNames.Count -eq 0) { $skip = 'no failed test in the last result' }
            elseif ($frontendEntry) {
                # A frontend rerun runs the spec files that held a failed test ("<spec file> :: <test name>").
                $rerunFiles = @($failedNames | ForEach-Object { ([string]$_ -split ' :: ', 2)[0] } | Where-Object { $_ } | Sort-Object -Unique)
                $rerunCount = @($failedNames | Sort-Object -Unique).Count
            }
            else {
                $callPlan = Get-OctoTestFilterCalls -project $entry -filter $filter -failedNames $failedNames -maxLength $maxFilterLength
                $calls = @($callPlan.Calls)
                $noMatch = $callPlan.Mismatch
                $rerunCount = @($failedNames | Sort-Object -Unique).Count
            }
        }
        elseif (-not $frontendEntry) {
            $callPlan = Get-OctoTestFilterCalls -project $entry -filter $filter -maxLength $maxFilterLength
            $calls = @($callPlan.Calls)
            # A filter in a form this project's runner does not take cannot match here: not run, not a failure.
            $noMatch = $callPlan.Mismatch
        }
        $filters = if ($frontendEntry) { @($filter) } else { @($calls | ForEach-Object { $_.Display }) }
        $buildState = if (Test-OctoFrontendTestProject $entry) {
            [pscustomobject]@{ Current = $false; Reason = 'frontend tests: ng test builds the test bundle itself' }
        }
        else {
            switch ($build) {
                'Always' { [pscustomobject]@{ Current = $false; Reason = '-build Always' } }
                'Never' { [pscustomobject]@{ Current = $true; Reason = '-build Never' } }
                default { Get-OctoTestBuildState -project $entry -repositoryPath $target.RepoPath -configuration $configuration -laneFeed $laneSettings.laneFeed -newestSource $newestSource }
            }
        }
        $docker = switch ($dockerLock) { 'Always' { $true } 'Never' { $false } default { $entry.Docker } }
        $plan += [pscustomobject]@{
            Project     = $entry
            ResultsPath = $projectResults
            Filters     = $filters
            Calls       = $calls
            NoMatch     = $noMatch
            Runner      = if ($frontendEntry) { 'ng' } elseif ($entry.PSObject.Properties['Runner']) { $entry.Runner } else { 'vstest' }
            RerunFiles  = $rerunFiles
            Skip        = $skip
            RerunCount  = $rerunCount
            NoBuild     = [bool]$buildState.Current
            BuildReason = $buildState.Reason
            Docker      = [bool]$docker
            DockerReason = switch ($dockerLock) { 'Always' { '-dockerLock Always' } 'Never' { '-dockerLock Never' } default { $entry.DockerReason } }
        }
    }
    # Projects without Docker first, so the lock is held only while the Docker-heavy ones run.
    $plan = @(@($plan | Where-Object { -not $_.Docker }) + @($plan | Where-Object { $_.Docker }))
    $runnable = @($plan | Where-Object { -not $_.Skip -and -not $_.NoMatch })
    if ($rerunFailed -and $runnable.Count -eq 0) {
        $withoutResult = @($plan | Where-Object { $_.Skip -like 'no previous result*' })
        if ($withoutResult.Count -eq $plan.Count) {
            & $fail "-rerunFailed: no previous result for $(($plan | ForEach-Object { $_.Project.Name }) -join ', ') in $resultsRoot - run the tests without -rerunFailed first."
            return
        }
    }

    # Isolation: the lane's environment, plus the global properties of an in-place worktree.
    $runEnvironment = [ordered]@{}
    foreach ($name in @($laneSettings.environment.Keys)) { $runEnvironment[$name] = $laneSettings.environment[$name] }
    $properties = @{}
    $inPlace = $null
    try {
        if ($target.InPlace) {
            $inPlace = Get-OctoTestInPlaceProperties -repositoryPath $target.RepoPath -environmentPath $target.LanePath -basePath $target.BasePath
            $properties = $inPlace.Properties
        }
        elseif ($configuration -ieq 'DebugL') {
            $restoreSources = Get-OctoRepoRestoreSourcesOverride -repositoryPath $target.RepoPath -laneSettings $laneSettings
            if ($restoreSources) { $runEnvironment['RestoreSources'] = $restoreSources }
        }
    }
    catch { & $fail $_.Exception.Message; return }
    $displayProperties = @(ConvertTo-OctoMsBuildPropertyArgs -properties $properties | ForEach-Object { Hide-OctoUrlCredentials $_ })
    $lockNeeded = @($runnable | Where-Object { $_.Docker }).Count -gt 0
    if ($dockerMemory -and $null -eq (ConvertTo-OctoByteCount -text $dockerMemory)) { & $fail "-dockerMemory '$dockerMemory' is no size (e.g. 4g, 2048m, or '' for no limit)."; return }
    # AB#8835: 0 is no limit, as '' (octo-devstack passes '0' for "none").
    if ($dockerMemory -and (ConvertTo-OctoByteCount -text $dockerMemory) -eq 0) { $dockerMemory = '' }
    # A memory limit set after the start kills a process that sized itself to the whole VM (mongod): opt-in only.
    $memoryWarning = if ($dockerMemory) { "-dockerMemory $dockerMemory is applied with docker update after each test container started: a process that already sized itself to the whole Docker VM (mongod's WiredTiger cache) is OOM-killed (exit 137) under it and the tests hang in timeouts. Use it only for containers whose memory is bounded at creation." }
    if ($lockNeeded) {
        # For test fixtures that set the limits when they create a container (the only way to limit it from its first
        # moment): the same values the run applies from outside afterwards.
        if ($dockerCpus -gt 0) { $runEnvironment['OCTO_TEST_CONTAINER_CPUS'] = $dockerCpus.ToString([Globalization.CultureInfo]::InvariantCulture) }
        if ($dockerMemory) { $runEnvironment['OCTO_TEST_CONTAINER_MEMORY_BYTES'] = [string](ConvertTo-OctoByteCount -text $dockerMemory) }
    }
    $lockFile = if ([string]::IsNullOrWhiteSpace($lockPath)) { Get-OctoTestLockPath } else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($lockPath) }

    $planReport = @($plan | ForEach-Object {
            [ordered]@{
                project      = $_.Project.Name
                path         = $_.Project.Path
                docker       = $_.Docker
                dockerReason = $_.DockerReason
                noBuild      = $_.NoBuild
                buildReason  = $_.BuildReason
                filters      = @($_.Filters | Where-Object { $_ })
                rerunCount   = $_.RerunCount
                rerunFiles   = @($_.RerunFiles | Where-Object { $_ })
                skip         = $_.Skip
                runner       = $_.Runner
                noMatch      = $_.NoMatch
            }
        })

    if ($whatIf) {
        $global:LASTEXITCODE = 0
        if ($Json) {
            Write-OctoJson -Command $command -Data ([ordered]@{
                    whatIf        = $true
                    environment   = $target.Environment
                    lanePath      = $target.LanePath
                    repo          = $repo
                    repoPath      = $target.RepoPath
                    inPlace       = $target.InPlace
                    configuration = $configuration
                    filter        = if ($filter) { $filter } else { $null }
                    rerunFailed   = [bool]$rerunFailed
                    lane          = [ordered]@{ isolated = $laneSettings.isolated; reason = $laneSettings.reason; environment = $runEnvironment }
                    msbuildProperties = $displayProperties
                    lock          = [ordered]@{ required = $lockNeeded; path = $lockFile; timeoutSeconds = $lockTimeoutSeconds }
                    resultsPath   = $resultsRoot
                    projects      = $planReport
                })
            return
        }
        Write-Host "Invoke-OctoTestRun plan ($configuration): $repo in $($target.LanePath)" -ForegroundColor Cyan
        Write-Host "  Lane isolated: $($laneSettings.isolated) ($($laneSettings.reason))" -ForegroundColor DarkGray
        foreach ($name in $runEnvironment.Keys) { Write-Host "    env $name=$(Hide-OctoUrlCredentials ([string]$runEnvironment[$name]))" -ForegroundColor DarkGray }
        if ($displayProperties.Count -gt 0) { Write-Host "  MSBuild properties (in-place worktree): $($displayProperties -join ' ')" -ForegroundColor DarkGray }
        Write-Host "  Results: $resultsRoot" -ForegroundColor DarkGray
        if ($lockNeeded) { Write-Host "  Machine-wide test lock: $lockFile (wait up to $lockTimeoutSeconds s)" -ForegroundColor DarkGray }
        foreach ($item in $plan) {
            Write-Host ''
            Write-Host "  $($item.Project.Name)$(if ($item.Docker) { '  [docker: ' + $item.DockerReason + ']' })" -ForegroundColor Green
            if ($item.Skip) { Write-Host "    skipped: $($item.Skip)" -ForegroundColor Yellow; continue }
            if ($item.NoMatch) { Write-Host "    not run: $($item.NoMatch)" -ForegroundColor Yellow; continue }
            Write-Host "    $(if ($item.NoBuild) { '--no-build' } else { 'builds first' }): $($item.BuildReason)"
            if ($null -ne $item.RerunCount -and (Test-OctoFrontendTestProject $item.Project)) {
                Write-Host "    reruns $($item.RerunCount) failed test(s): npx ng test with --include for $(@($item.RerunFiles).Count) spec file(s)"
                foreach ($file in @($item.RerunFiles)) { Write-Host "      --include $file" }
            }
            elseif ($null -ne $item.RerunCount) { Write-Host "    reruns $($item.RerunCount) failed test(s) in $(@($item.Filters).Count) dotnet test call(s)" }
            elseif ($filter) { Write-Host "    filter: $filter" }
        }
        Write-Host ''
        Write-Host 'WhatIf: nothing was built or run.' -ForegroundColor Cyan
        return
    }

    & $emit 'plan' ([ordered]@{ repo = $repo; environment = $target.Environment; projects = @($planReport | ForEach-Object { [ordered]@{ project = $_.project; runner = $_.runner; docker = $_.docker; noBuild = $_.noBuild; buildReason = $_.buildReason; skip = $_.skip; noMatch = $_.noMatch } }); count = $plan.Count })
    if (-not $Json) {
        Write-Host "Invoke-OctoTestRun ($configuration): $repo in $($target.LanePath) - $($runnable.Count) test project(s)" -ForegroundColor Cyan
    }

    $results = [System.Collections.Generic.List[object]]::new()
    $lockState = [ordered]@{ required = $lockNeeded; path = $lockFile; acquired = $false; waitedSeconds = 0.0; staleRemoved = @(); blockedBy = $null }
    $lockId = $null
    $limiter = $null
    # AB#8835: what the Docker engine had when the Docker-heavy projects started, and what was limited.
    $dockerState = [ordered]@{
        required = $lockNeeded; checked = $false; check = $(if ($dockerCheck -eq 'Off') { 'off' } else { $null }); available = $null
        memoryGiB = $null; cpus = $null; usedGiB = $null; freeGiB = $null; minFreeGiB = $minDockerFreeMemoryGiB; containers = @(); message = $null
        limits = [ordered]@{ cpus = $(if ($dockerCpus -gt 0) { $dockerCpus } else { $null }); memory = $(if ($dockerMemory) { $dockerMemory } else { $null }); memoryWarning = $memoryWarning }
        limited = @()
    }
    # The projects from $from on (0-based index into the plan) did not run.
    $markNotRun = {
        param([int]$from, [string]$note)
        foreach ($pending in @($plan | Select-Object -Skip $from)) {
            $results.Add([ordered]@{
                    project = $pending.Project.Name; path = $pending.Project.Path; state = 'notRun'; success = $false; exitCode = $null
                    docker = $pending.Docker; dockerReason = $pending.DockerReason; noBuild = $pending.NoBuild; buildReason = $pending.BuildReason
                    filters = @($pending.Filters | Where-Object { $_ }); rerunCount = $pending.RerunCount
                    total = 0; passed = 0; failed = 0; skipped = 0; durationSeconds = 0.0; failedTests = @(); truncated = $false
                    passedTests = @(); passedTruncated = $false; errors = @(); runner = $pending.Runner
                    note = $note; resultsPath = $null; trx = @(); logFile = $null
                })
        }
    }
    $failedStep = $null
    $failedProject = $null
    $runError = $null
    $restoreConfig = $null
    $finished = $false   # reached the end of the try block (not cut off by Ctrl+C)
    $savedEnvironment = Set-OctoBuildEnvironment -environment $runEnvironment
    try {
        if ($null -ne $inPlace -and $inPlace.Credentials.Count -gt 0) {
            $restoreConfig = Invoke-OctoModuleFunction -module 'OctoEnvironment' -name 'New-OctoRestoreConfigFile' -arguments @{ sources = @($inPlace.Sources); credentials = $inPlace.Credentials }
            $properties['RestoreConfigFile'] = $restoreConfig
        }
        $propertyArgs = @(ConvertTo-OctoMsBuildPropertyArgs -properties $properties)
        $runStamp = '{0}-{1}' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff'), $PID
        $index = 0
        foreach ($item in $plan) {
            $index++
            $name = $item.Project.Name
            $result = [ordered]@{
                project         = $name
                path            = $item.Project.Path
                state           = 'skipped'
                success         = $true
                exitCode        = $null
                docker          = $item.Docker
                dockerReason    = $item.DockerReason
                noBuild         = $item.NoBuild
                buildReason     = $item.BuildReason
                filters         = @($item.Filters | Where-Object { $_ })
                rerunCount      = $item.RerunCount
                total           = 0
                passed          = 0
                failed          = 0
                skipped         = 0
                durationSeconds = 0.0
                failedTests     = @()
                truncated       = $false
                passedTests     = @()
                passedTruncated = $false
                errors          = @()
                runner          = $item.Runner
                note            = $item.Skip
                resultsPath     = $null
                trx             = @()
                logFile         = $null
            }
            if ($item.Skip) {
                $results.Add($result)
                continue
            }
            if ($item.NoMatch) {
                $result.state = 'noMatch'
                $result.note = $item.NoMatch
                $results.Add($result)
                continue
            }

            if ($item.Docker -and -not $lockId) {
                $lock = Enter-OctoTestLock -LockPath $lockFile -TimeoutSeconds $lockTimeoutSeconds -PollMilliseconds $lockPollMilliseconds -Run ([ordered]@{
                        command     = $command
                        lane        = $target.LanePath
                        environment = $target.Environment
                        repo        = $repo
                        projects    = @($runnable | Where-Object { $_.Docker } | ForEach-Object { $_.Project.Name })
                    }) -OnWait {
                    param($owner)
                    & $emit 'lockWait' ([ordered]@{ path = $lockFile; timeoutSeconds = $lockTimeoutSeconds; owner = (ConvertTo-OctoTestLockReport -owner $owner) })
                    if (-not $Json) { Write-Host "Waiting for the machine-wide test lock (up to $lockTimeoutSeconds s): held by $(Format-OctoTestLockOwner -owner $owner)" -ForegroundColor Yellow }
                }
                $lockState.waitedSeconds = $lock.WaitedSeconds
                $lockState.staleRemoved = @($lock.StaleRemoved)
                if (-not $lock.Acquired) {
                    $lockState.blockedBy = ConvertTo-OctoTestLockReport -owner $lock.Owner
                    $failedStep = 'lock'
                    $failedProject = $name
                    $runError = "The machine-wide test lock $lockFile is held by $(Format-OctoTestLockOwner -owner $lock.Owner); waited $([Math]::Round($lock.WaitedSeconds)) s (-lockTimeoutSeconds $lockTimeoutSeconds). The Docker-heavy project(s) $((@($runnable | Where-Object { $_.Docker } | ForEach-Object { $_.Project.Name })) -join ', ') were not run."
                    & $markNotRun ($index - 1) 'not run: the machine-wide test lock was not available'
                    break   # reported below like every other result
                }
                $lockId = $lock.Id
                $lockState.acquired = $true
                & $emit 'lockAcquired' ([ordered]@{ path = $lockFile; waitedSeconds = $lock.WaitedSeconds })

                # AB#8835: the test containers share the Docker engine (on Docker Desktop one VM) with the kind cluster
                # of the local stack. Checked with the lock held, so no other test run changes the picture.
                if ($dockerCheck -ne 'Off') {
                    $capacity = Get-OctoDockerCapacity
                    $dockerState.checked = $true
                    $dockerState.available = [bool]$capacity.Available
                    if (-not $capacity.Available) {
                        # Cannot be judged from here (no CLI, another Docker host): the tests decide.
                        $dockerState.check = 'unavailable'
                        $dockerState.message = "Docker capacity not checked: $($capacity.Error)"
                        if (-not $Json) { Write-Warning $dockerState.message }
                    }
                    else {
                        $gib = { param([long]$bytes) [Math]::Round($bytes / 1GB, 1) }
                        $dockerState.memoryGiB = & $gib $capacity.MemoryBytes
                        $dockerState.cpus = $capacity.Cpus
                        $dockerState.usedGiB = & $gib $capacity.UsedBytes
                        $dockerState.freeGiB = & $gib $capacity.FreeBytes
                        $dockerState.containers = @($capacity.Containers | Sort-Object MemoryBytes -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ name = $_.Name; memoryGiB = (& $gib $_.MemoryBytes) } })
                        if ($capacity.FreeBytes -lt ($minDockerFreeMemoryGiB * 1GB)) {
                            $top = @($dockerState.containers | ForEach-Object { "$($_.name) $($_.memoryGiB) GiB" }) -join ', '
                            $dockerState.message = "The Docker engine has $($dockerState.freeGiB) GiB of $($dockerState.memoryGiB) GiB free (running containers use $($dockerState.usedGiB) GiB: $top); the Docker-heavy tests need at least $minDockerFreeMemoryGiB GiB (-minDockerFreeMemoryGiB) or they starve the local stack's MongoDB, CrateDB and RabbitMQ in the same engine. Stop a stack you do not need, give the Docker VM more memory, or pass -dockerCheck Warn to run anyway."
                            if ($dockerCheck -eq 'Refuse') {
                                $dockerState.check = 'refused'
                                $failedStep = 'docker'
                                $failedProject = $name
                                $runError = "$($dockerState.message) The Docker-heavy project(s) $((@($runnable | Where-Object { $_.Docker } | ForEach-Object { $_.Project.Name })) -join ', ') were not run."
                                & $markNotRun ($index - 1) 'not run: the Docker engine has too little free memory'
                                break
                            }
                            $dockerState.check = 'warned'
                            if (-not $Json) { Write-Warning $dockerState.message }
                        }
                        else { $dockerState.check = 'ok' }
                    }
                }
                if ($memoryWarning -and -not $Json) { Write-Warning $memoryWarning }
                $limiter = Start-OctoDockerLimiter -Cpus $dockerCpus -Memory $dockerMemory
            }

            $runPath = Join-Path $item.ResultsPath $runStamp
            [void][IO.Directory]::CreateDirectory($runPath)
            $frontend = Test-OctoFrontendTestProject $item.Project
            $logFile = Join-Path $runPath $(if ($frontend) { 'ng-test.log' } else { 'dotnet-test.log' })
            $result.resultsPath = $runPath
            $result.logFile = $logFile
            & $emit 'testProjectStart' ([ordered]@{ repo = $repo; project = $name; index = $index; count = $plan.Count; runner = $item.Runner; docker = $item.Docker; noBuild = $item.NoBuild; buildReason = $item.BuildReason; calls = $(if ($frontend) { 1 } else { @($item.Calls).Count }) })
            if (-not $Json) {
                $mode = if ($item.NoBuild) { '--no-build' } else { "builds first: $($item.BuildReason)" }
                Write-Host "==> $name ($mode)$(if ($item.Docker) { ' [test lock held]' })" -ForegroundColor Cyan
            }
            $projectWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $exitCode = 0
            $call = 0
            $zeroTestCalls = 0
            if ($frontend) {
                # One `ng test` call: headless (no watch), the JUnit report first (--output-file belongs to the first reporter).
                $arguments = @('ng', 'test', '--watch=false', '--reporters=junit', "--output-file=$(Join-Path $runPath 'results.junit.xml')", '--reporters=default')
                if ($filter) { $arguments += @('--filter', $filter) }
                foreach ($file in @($item.RerunFiles)) { $arguments += @('--include', $file) }
                "Invoke-OctoTestRun: npx $($arguments -join ' ') (in $($item.Project.Directory))" | Add-Content -LiteralPath $logFile
                $exitCode = Invoke-OctoFrontendTest -directory $item.Project.Directory -arguments $arguments -logFile $logFile
            }
            $mtp = $item.Runner -eq 'mtp'
            foreach ($testCall in @($(if (-not $frontend) { $item.Calls }))) {
                $call++
                $trxName = if (@($item.Calls).Count -gt 1) { "results-$call.trx" } else { 'results.trx' }
                if ($mtp) {
                    # Microsoft.Testing.Platform (global.json): `dotnet test --project`, the report and filter options
                    # belong to the test application and follow `--`. No -nodeReuse here: it would reach the application.
                    $arguments = @('test', '--project', $item.Project.Path, '-c', $configuration)
                    if ($item.NoBuild -or $call -gt 1) { $arguments += '--no-build' }
                    $arguments += @('--results-directory', $runPath)
                    $arguments += $propertyArgs
                    $arguments += '--'
                    $arguments += if ($item.Project.Framework -eq 'xunit3') { @('--report-xunit-trx', '--report-xunit-trx-filename', $trxName) } else { @('--report-trx', '--report-trx-filename', $trxName) }
                    $arguments += @($testCall.Arguments)
                }
                else {
                    $arguments = @('test', $item.Project.Path, '-c', $configuration)
                    # Only the first call of a chunked rerun may build.
                    if ($item.NoBuild -or $call -gt 1) { $arguments += '--no-build' }
                    $arguments += @('--results-directory', $runPath, '--logger', "trx;LogFileName=$trxName", '-nodeReuse:false')
                    $arguments += @($testCall.Arguments)
                    $arguments += $propertyArgs
                }
                $startIn = if ($item.Project.PSObject.Properties['RunnerDirectory'] -and $item.Project.RunnerDirectory) { $item.Project.RunnerDirectory } else { $target.RepoPath }
                "Invoke-OctoTestRun: dotnet $(Hide-OctoUrlCredentials ($arguments -join ' ')) (in $startIn)" | Add-Content -LiteralPath $logFile
                $callExit = Invoke-OctoDotnetTest -arguments $arguments -logFile $logFile -workingDirectory $startIn
                # Microsoft.Testing.Platform: 8 = no test ran (a filter that matches nothing in this call) - judged below.
                if ($mtp -and $callExit -eq 8) { $callExit = 0; $zeroTestCalls++ }
                if ($callExit -ne 0 -and $exitCode -eq 0) { $exitCode = $callExit }
            }
            $projectWatch.Stop()

            $trxFiles = @(Get-ChildItem -LiteralPath $runPath -Recurse -File -Filter $(if ($frontend) { '*.junit.xml' } else { '*.trx' }) -ErrorAction SilentlyContinue | Sort-Object FullName)
            $failedTests = [System.Collections.Generic.List[object]]::new()
            $passedTests = [System.Collections.Generic.List[string]]::new()
            # One more than is reported, so `passedTruncated` can tell that there were more.
            $passedLimit = if ($includePassed) { [Math]::Max(0, $maxPassed) + 1 } else { 0 }
            $errors = [System.Collections.Generic.List[string]]::new()
            foreach ($file in $trxFiles) {
                try { $trx = if ($frontend) { Read-OctoJUnitFile -path $file.FullName } else { Read-OctoTrxFile -path $file.FullName -maxPassed $passedLimit } }
                catch { $errors.Add("Cannot read $($file.FullName): $($_.Exception.Message)"); continue }
                $result.total += $trx.Total; $result.passed += $trx.Passed; $result.failed += $trx.Failed; $result.skipped += $trx.Skipped
                foreach ($test in $trx.FailedTests) { $failedTests.Add($test) }
                if ($trx.PSObject.Properties['PassedTests']) { foreach ($test in @($trx.PassedTests)) { if ($passedTests.Count -lt $passedLimit) { $passedTests.Add([string]$test) } } }
                foreach ($line in $trx.RunErrors) { $errors.Add($line) }
            }
            $result.exitCode = $exitCode
            $result.trx = @($trxFiles | ForEach-Object FullName)
            $result.durationSeconds = $projectWatch.Elapsed.TotalSeconds
            $result.failedTests = @($failedTests | Select-Object -First ([Math]::Max(0, $maxFailures)) | ForEach-Object {
                    [ordered]@{ name = $_.Name; displayName = $_.DisplayName; outcome = $_.Outcome; message = $_.Message; stackFrame = $_.StackFrame; durationSeconds = $_.DurationSeconds }
                })
            $result.truncated = $failedTests.Count -gt @($result.failedTests).Count
            if ($includePassed) {
                $result.passedTests = @($passedTests | Select-Object -First ([Math]::Max(0, $maxPassed)))
                $result.passedTruncated = $result.passed -gt @($result.passedTests).Count
            }
            $filteredRun = [bool]$filter -or $null -ne $item.RerunCount
            if ($result.failed -gt 0) { $result.state = 'failed' }
            elseif ($exitCode -ne 0) {
                # No failed test, but dotnet failed: the build broke, the test host crashed, or no TRX was written.
                $result.state = 'error'
                foreach ($line in @(Get-OctoTestLogErrors -logFile $logFile)) { if (-not $errors.Contains($line)) { $errors.Add($line) } }
            }
            elseif ($result.total -eq 0 -and $filteredRun) {
                # Not a failure of this project: another project of the run may hold the tests the filter means.
                $result.state = 'noMatch'
                $result.note = 'no test matched the filter'
            }
            elseif ($result.total -eq 0) {
                # Without a filter a project that runs nothing is broken (wrong runner, discovery failed): never green.
                $result.state = 'noTests'
                $result.note = 'the project ran no test although no filter was given'
                foreach ($line in @(Get-OctoTestLogErrors -logFile $logFile)) { if (-not $errors.Contains($line)) { $errors.Add($line) } }
            }
            else { $result.state = 'passed' }
            $result.success = $result.state -in @('passed', 'noMatch')
            $result.errors = @($errors | Select-Object -First $script:MaxErrorLines)
            if (-not $result.success -and -not $failedProject) {
                $failedProject = $name
                $failedStep = if ($result.state -eq 'error' -and -not $item.NoBuild -and $trxFiles.Count -eq 0) { 'build' } else { 'tests' }
            }

            # The last result of the project, with every failed test name (-rerunFailed reads it).
            $last = [ordered]@{
                schemaVersion = $script:TestResultSchemaVersion
                timestamp     = (Get-Date).ToUniversalTime().ToString('o')
                repo          = $repo
                project       = $name
                configuration = $configuration
                filter        = if ($filter) { $filter } else { $null }
                rerunFailed   = [bool]$rerunFailed
                state         = $result.state
                total         = $result.total
                passed        = $result.passed
                failed        = $result.failed
                skipped       = $result.skipped
                failedTests   = @($failedTests | ForEach-Object { $_.Name } | Where-Object { $_ } | Sort-Object -Unique)
                resultsPath   = $runPath
                trx           = $result.trx
                logFile       = $logFile
            }
            [IO.File]::WriteAllText((Join-Path $item.ResultsPath 'last-result.json'), (ConvertTo-Json -InputObject $last -Depth 5) + "`n", [Text.UTF8Encoding]::new($false))
            Remove-OctoTestOldRuns -projectResultsPath $item.ResultsPath

            $results.Add($result)
            & $emit 'testProjectDone' ([ordered]@{
                    repo = $repo; project = $name; index = $index; count = $plan.Count; success = [bool]$result.success; state = $result.state
                    total = $result.total; passed = $result.passed; failed = $result.failed; skipped = $result.skipped
                    seconds = $result.durationSeconds; trx = $result.trx; logFile = $logFile
                })
            if (-not $Json) {
                $color = if ($result.success) { 'Green' } else { 'Red' }
                Write-Host ("    {0}: {1} test(s), {2} passed, {3} failed, {4} skipped in {5}" -f $result.state, $result.total, $result.passed, $result.failed, $result.skipped, (Format-OctoTestDuration -seconds $result.durationSeconds)) -ForegroundColor $color
            }

            # Release the lock as soon as the last Docker-heavy project is through.
            if ($lockId -and @($plan | Select-Object -Skip $index | Where-Object { $_.Docker -and -not $_.Skip }).Count -eq 0) {
                $dockerState.limited = @(Stop-OctoDockerLimiter -Limiter $limiter)
                $limiter = $null
                [void](Exit-OctoTestLock -Id $lockId -LockPath $lockFile)
                $lockId = $null
                & $emit 'lockReleased' ([ordered]@{ path = $lockFile })
            }
        }
        $finished = $true
    }
    catch {
        # e.g. the results folder cannot be written: report it like every other failure (also with -Json).
        if (-not $failedStep) { $failedStep = 'tests' }
        $runError = "Invoke-OctoTestRun stopped: $($_.Exception.Message)"
        $finished = $true
    }
    finally {
        if ($limiter) { $dockerState.limited = @(Stop-OctoDockerLimiter -Limiter $limiter) }
        if ($lockId) {
            [void](Exit-OctoTestLock -Id $lockId -LockPath $lockFile)
            & $emit 'lockReleased' ([ordered]@{ path = $lockFile })
        }
        if ($restoreConfig) { Remove-Item -LiteralPath (Split-Path -Parent $restoreConfig) -Recurse -Force -ErrorAction SilentlyContinue }
        Restore-OctoBuildEnvironment -saved $savedEnvironment
        $watch.Stop()
        foreach ($result in $results) {
            $totals.total += $result.total; $totals.passed += $result.passed; $totals.failed += $result.failed; $totals.skipped += $result.skipped
        }
        if (-not $finished) {
            # Cut off (Ctrl+C, a stopped pipeline): the closing event still goes out, best effort.
            & $emit 'done' ([ordered]@{ success = $false; failedRepo = $repo; failedProject = $failedProject; failedStep = 'canceled'; elapsedSeconds = $watch.Elapsed.TotalSeconds; total = $totals.total; passed = $totals.passed; failed = $totals.failed; skipped = $totals.skipped })
        }
    }

    # A filter (or a rerun) that matched nothing at all is a mistake, not a green run.
    $filtered = [bool]$filter -or [bool]$rerunFailed
    $unmatched = @($results | Where-Object { $_.state -eq 'noMatch' })
    if (-not $failedStep -and $filtered -and $totals.total -eq 0 -and $unmatched.Count -gt 0) {
        $failedStep = 'tests'
        $reasons = @($unmatched | ForEach-Object { $_.note } | Where-Object { $_ -and $_ -ne 'no test matched the filter' } | Select-Object -Unique)
        $runError = "No test ran: $(if ($rerunFailed) { 'the failed tests of the last result no longer exist' } else { "the filter '$filter' matches no test" }) in $(($unmatched | ForEach-Object { $_.project }) -join ', ').$(if ($reasons.Count -gt 0) { ' ' + ($reasons -join '; ') + '.' })"
    }
    $success = -not $failedStep
    $global:LASTEXITCODE = if ($success) { 0 } else { 1 }
    $data = [ordered]@{
        success        = $success
        exitCode       = $global:LASTEXITCODE
        failedStep     = $failedStep
        failedProject  = $failedProject
        error          = $runError
        environment    = $target.Environment
        lanePath       = $target.LanePath
        repo           = $repo
        repoPath       = $target.RepoPath
        inPlace        = $target.InPlace
        configuration  = $configuration
        filter         = if ($filter) { $filter } else { $null }
        rerunFailed    = [bool]$rerunFailed
        totals         = $totals
        elapsedSeconds = $watch.Elapsed.TotalSeconds
        lane           = [ordered]@{ isolated = $laneSettings.isolated; reason = $laneSettings.reason; environment = $runEnvironment }
        msbuildProperties = $displayProperties
        lock           = $lockState
        docker         = $dockerState
        resultsPath    = $resultsRoot
        projects       = @($results)
    }
    & $emit 'done' ([ordered]@{ success = $success; failedRepo = if ($success) { $null } else { $repo }; failedProject = $failedProject; failedStep = $failedStep; elapsedSeconds = $watch.Elapsed.TotalSeconds; total = $totals.total; passed = $totals.passed; failed = $totals.failed; skipped = $totals.skipped })
    if ($Json) {
        Write-OctoJson -Command $command -Data $data
        return
    }
    Write-OctoTestRunSummary -data $data
    if ($runError) { Write-Error $runError }
    elseif (-not $success) { Write-Error "Invoke-OctoTestRun: $($totals.failed) test(s) failed in $repo$(if ($failedProject) { " (first failing project: $failedProject)" })." }
}

Export-ModuleMember -Function @(
    'Invoke-OctoTestRun',
    'Get-OctoTestLock',
    'Remove-OctoTestLock',
    'Enter-OctoTestLock',
    'Exit-OctoTestLock'
)
