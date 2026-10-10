<#
.SYNOPSIS
    Daily report of how much CI work in Azure DevOps is duplicate (AB#6369, Feature AB#6333).

.DESCRIPTION
    Read-only. Reads the build history (_apis/build/builds) and the agent pool job requests
    (_apis/distributedtask/pools/{id}/jobrequests) of the OctoMesh project and reports, per CI
    definition: runs, resource-trigger runs, same-commit duplicate runs, wasted agent-minutes,
    estimated redundant minutes, queue wait p50/p90 and, per pool, the concurrency.

    The method is the one of the 2026-10-10 analysis (octo-mesh-deployment / .po/ci-parallel-runs-analysis-20261010.md):

      * CI definition   = definition whose name ends with '-CI'.
      * Chain           = the CI definitions linked by pipeline-resource triggers (map below).
      * Strict duplicate = run with the same definition + sourceVersion + branch as another run
                           in the window; per group the last succeeded run (else the last) is
                           kept, the others are duplicates and their minutes are wasted.
      * Redundant (estimated) = a non-canceled run of a chain definition on refs/heads/main whose
                           inputs (own commit + main HEAD of every upstream definition at run
                           start, reconstructed from the observed main runs) equal the inputs of
                           an earlier non-canceled run. A rerun on the same commit is legitimate
                           when an upstream package changed in between, hence this is the
                           realistic saving, the strict duplicate minutes are the ceiling.
      * Minutes         = startTime to finishTime (in-progress runs: until -AsOf).

    The module never writes to Azure DevOps (HTTP GET only), never queues or cancels a build and
    never prints the access token. The token comes from `az account get-access-token`.

.NOTES
    Pure calculation lives in Measure-CiWaste (testable without network); Get-CiWasteReport only
    fetches and renders.
#>

# Single-parent chain from the pipeline-resource triggers on origin/main
# (child = upstream definition). Keep in sync with the `resources.pipelines` blocks of the repos.
$script:DefaultCiChainMap = [ordered]@{
    'mm-common-CI'                              = $null
    'octo-distributedEventHub-CI'               = 'mm-common-CI'
    'octo-construction-kit-engine-CI'           = 'octo-distributedEventHub-CI'
    'octo-sdk-CI'                               = 'octo-construction-kit-engine-CI'
    'octo-construction-kit-engine-mongodb-CI'   = 'octo-sdk-CI'
    'octo-common-services-CI'                   = 'octo-construction-kit-engine-mongodb-CI'
    'octo-asset-repo-services-CI'               = 'octo-common-services-CI'
    'octo-bot-services-CI'                      = 'octo-common-services-CI'
    'octo-identity-services-CI'                 = 'octo-common-services-CI'
    'octo-cli-CI'                               = 'octo-common-services-CI'
    'octo-communication-operator-CI'            = 'octo-common-services-CI'
    'octo-communication-sdk-CI'                 = 'octo-common-services-CI'
    'octo-construction-kit-CI'                  = 'octo-common-services-CI'
    'octo-mcp-services-CI'                      = 'octo-common-services-CI'
    'octo-platform-services-CI'                 = 'octo-common-services-CI'
    'octo-communication-controller-services-CI' = 'octo-bot-services-CI'
    'octo-ai-services-CI'                       = 'octo-communication-controller-services-CI'
    'octo-mesh-adapter-CI'                      = 'octo-communication-sdk-CI'
    'octo-frontend-libraries-CI'                = $null
    'octo-frontend-refinery-studio-CI'          = 'octo-frontend-libraries-CI'
}

function ConvertTo-CiWasteUtc {
    # ConvertFrom-Json / Invoke-RestMethod turn ISO strings into local DateTime values; strings and
    # DateTimeOffset values are normalised to UTC as well, so the maths never depends on the machine zone.
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    return [datetimeoffset]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Get-CiWastePercentile {
    # Linear interpolation between closest ranks; $null for an empty sample.
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $k = ($sorted.Count - 1) * $P
    $f = [math]::Floor($k)
    $c = [math]::Min($f + 1, $sorted.Count - 1)
    return $sorted[$f] + ($sorted[$c] - $sorted[$f]) * ($k - $f)
}

function Get-CiWasteRound {
    param($Value, [int]$Digits = 1)
    if ($null -eq $Value) { return $null }
    return [math]::Round([double]$Value, $Digits, [MidpointRounding]::AwayFromZero)
}

function Get-CiWasteShare {
    param([double]$Part, [double]$Whole)
    if ($Whole -le 0) { return 0.0 }
    return Get-CiWasteRound (100.0 * $Part / $Whole) 1
}

function Measure-CiWaste {
    <#
    .SYNOPSIS
        Pure calculation of the CI waste report from already fetched builds and job requests.
    .PARAMETER Builds
        Build objects as returned by _apis/build/builds (id, definition.id/name, sourceBranch,
        sourceVersion, reason, status, result, queueTime, startTime, finishTime).
    .PARAMETER JobRequests
        Hashtable poolId -> array of job requests (queueTime, assignTime, finishTime).
    .PARAMETER PoolInfo
        Hashtable poolId -> @{ name = 'CI'; capacity = 8 } (capacity may be $null).
    .PARAMETER AsOf
        End of the window; in-progress runs are measured up to this instant.
    .PARAMETER Hours
        Window length.
    .PARAMETER ChainMap
        Hashtable definition name -> upstream definition name ($null for roots).
    #>
    [CmdletBinding()]
    param(
        [object[]]$Builds = @(),
        [hashtable]$JobRequests = @{},
        [hashtable]$PoolInfo = @{},
        [Parameter(Mandatory)][datetime]$AsOf,
        [int]$Hours = 24,
        $ChainMap = $script:DefaultCiChainMap
    )

    $asOfUtc = ConvertTo-CiWasteUtc $AsOf
    $from = $asOfUtc.AddHours(-$Hours)

    # ---- normalise builds -------------------------------------------------------------------
    $rows = foreach ($b in $Builds) {
        $name = [string]$b.definition.name
        if (-not $name.EndsWith('-CI')) { continue }
        $queue = ConvertTo-CiWasteUtc $b.queueTime
        if (-not $queue -or $queue -lt $from -or $queue -gt $asOfUtc) { continue }
        $start = ConvertTo-CiWasteUtc $b.startTime
        $finish = ConvertTo-CiWasteUtc $b.finishTime
        $minutes = 0.0
        if ($start) {
            $end = if ($finish) { $finish } else { $asOfUtc }
            $minutes = [math]::Max(0.0, ($end - $start).TotalMinutes)
        }
        [pscustomobject]@{
            Id      = [int]$b.id
            DefId   = [int]$b.definition.id
            Def     = $name
            Branch  = [string]$b.sourceBranch
            Sha     = [string]$b.sourceVersion
            Reason  = [string]$b.reason
            Result  = [string]$b.result
            Queue   = $queue
            Start   = $start
            Minutes = $minutes
            Wait    = if ($start) { [math]::Max(0.0, ($start - $queue).TotalMinutes) } else { $null }
        }
    }
    $rows = @($rows)

    # ---- strict same-commit duplicates ---------------------------------------------------------
    $dupIds = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($g in ($rows | Group-Object { "$($_.DefId)|$($_.Sha)|$($_.Branch)" })) {
        if ($g.Count -lt 2) { continue }
        $ordered = @($g.Group | Sort-Object Queue, Id)
        $succeeded = @($ordered | Where-Object { $_.Result -eq 'succeeded' })
        $keep = if ($succeeded.Count -gt 0) { $succeeded[-1] } else { $ordered[-1] }
        foreach ($r in $ordered) { if ($r.Id -ne $keep.Id) { [void]$dupIds.Add($r.Id) } }
    }

    # ---- estimated redundant runs (chain definitions, refs/heads/main) -------------------------------
    $chainNames = @($ChainMap.Keys)
    $ancestors = @{}
    foreach ($n in $chainNames) {
        $list = [System.Collections.Generic.List[string]]::new()
        $cur = $n
        while ($ChainMap[$cur]) { $cur = [string]$ChainMap[$cur]; $list.Add($cur) }
        $ancestors[$n] = $list
    }
    $mainByDef = @{}
    foreach ($r in ($rows | Where-Object { $_.Branch -eq 'refs/heads/main' -and $_.Def -in $chainNames -and $_.Sha } | Sort-Object Queue, Id)) {
        if (-not $mainByDef.ContainsKey($r.Def)) { $mainByDef[$r.Def] = [System.Collections.Generic.List[object]]::new() }
        $mainByDef[$r.Def].Add($r)
    }
    $headAt = {
        param([string]$def, [datetime]$t)
        $head = $null
        if ($mainByDef.ContainsKey($def)) {
            foreach ($u in $mainByDef[$def]) { if ($u.Queue -le $t) { $head = $u.Sha } else { break } }
        }
        return $head
    }
    $redundantIds = [System.Collections.Generic.HashSet[int]]::new()
    $population = [System.Collections.Generic.HashSet[int]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $mainRuns = @($rows | Where-Object { $_.Branch -eq 'refs/heads/main' -and $_.Def -in $chainNames -and $_.Result -ne 'canceled' } | Sort-Object Queue, Id)
    foreach ($r in $mainRuns) {
        [void]$population.Add($r.Id)
        $t = if ($r.Start) { $r.Start } else { $r.Queue }
        $heads = foreach ($a in $ancestors[$r.Def]) { & $headAt $a $t }
        $signature = "$($r.Def)|$($r.Sha)|" + (($heads | ForEach-Object { "$_" }) -join ',')
        if (-not $seen.Add($signature)) { [void]$redundantIds.Add($r.Id) }
    }

    # ---- per definition ------------------------------------------------------------------------------
    $definitions = foreach ($g in ($rows | Group-Object Def)) {
        $set = @($g.Group)
        $name = $g.Name
        $inChain = $name -in $chainNames
        $rt = @($set | Where-Object { $_.Reason -eq 'resourceTrigger' })
        $dups = @($set | Where-Object { $dupIds.Contains($_.Id) })
        $waits = [double[]]@($set | Where-Object { $null -ne $_.Wait } | ForEach-Object { $_.Wait })
        $total = ($set | Measure-Object Minutes -Sum).Sum
        $entry = [ordered]@{
            definition          = $name
            definitionId        = $set[0].DefId
            inChain             = $inChain
            upstream            = if ($inChain -and $ChainMap[$name]) { [string]$ChainMap[$name] } else { $null }
            runs                = $set.Count
            resourceTriggerRuns = $rt.Count
            resourceTriggerShare = Get-CiWasteShare $rt.Count $set.Count
            duplicateRuns       = $dups.Count
            duplicateShare      = Get-CiWasteShare $dups.Count $set.Count
            wastedMinutes       = Get-CiWasteRound (($dups | Measure-Object Minutes -Sum).Sum)
            totalMinutes        = Get-CiWasteRound $total
            mainRuns            = $null
            redundantRuns       = $null
            redundantMinutes    = $null
            queueWaitP50Minutes = Get-CiWasteRound (Get-CiWastePercentile $waits 0.5)
            queueWaitP90Minutes = Get-CiWasteRound (Get-CiWastePercentile $waits 0.9)
            queueWaitMaxMinutes = if ($waits.Count) { Get-CiWasteRound (($waits | Measure-Object -Maximum).Maximum) } else { $null }
        }
        if ($inChain) {
            $pop = @($set | Where-Object { $population.Contains($_.Id) })
            $red = @($pop | Where-Object { $redundantIds.Contains($_.Id) })
            $entry.mainRuns = $pop.Count
            $entry.redundantRuns = $red.Count
            $entry.redundantMinutes = Get-CiWasteRound (($red | Measure-Object Minutes -Sum).Sum)
        }
        [pscustomobject]$entry
    }
    $definitions = @($definitions | Sort-Object @{ Expression = 'wastedMinutes'; Descending = $true }, definition)

    # ---- totals --------------------------------------------------------------------------------------------
    $chainRows = @($rows | Where-Object { $_.Def -in $chainNames })
    $newTotals = {
        param([object[]]$set)
        $set = @($set)
        $rt = @($set | Where-Object { $_.Reason -eq 'resourceTrigger' })
        $dups = @($set | Where-Object { $dupIds.Contains($_.Id) })
        [ordered]@{
            runs                 = $set.Count
            resourceTriggerRuns  = $rt.Count
            resourceTriggerShare = Get-CiWasteShare $rt.Count $set.Count
            resourceTriggerMinutes = Get-CiWasteRound (($rt | Measure-Object Minutes -Sum).Sum)
            duplicateRuns        = $dups.Count
            duplicateShare       = Get-CiWasteShare $dups.Count $set.Count
            wastedMinutes        = Get-CiWasteRound (($dups | Measure-Object Minutes -Sum).Sum)
            totalMinutes         = Get-CiWasteRound (($set | Measure-Object Minutes -Sum).Sum)
        }
    }
    $ciTotals = & $newTotals $rows
    $chainTotals = & $newTotals $chainRows
    $popRows = @($chainRows | Where-Object { $population.Contains($_.Id) })
    $redRows = @($popRows | Where-Object { $redundantIds.Contains($_.Id) })
    $chainTotals.wastedShareOfMinutes = Get-CiWasteShare $chainTotals.wastedMinutes $chainTotals.totalMinutes
    $chainTotals.mainRuns = $popRows.Count
    $chainTotals.mainMinutes = Get-CiWasteRound (($popRows | Measure-Object Minutes -Sum).Sum)
    $chainTotals.redundantRuns = $redRows.Count
    $chainTotals.redundantRunShare = Get-CiWasteShare $redRows.Count $popRows.Count
    $chainTotals.redundantMinutes = Get-CiWasteRound (($redRows | Measure-Object Minutes -Sum).Sum)
    $chainTotals.redundantMinuteShare = Get-CiWasteShare $chainTotals.redundantMinutes $chainTotals.mainMinutes

    # ---- pools ------------------------------------------------------------------------------------------------
    $pools = foreach ($poolId in ($JobRequests.Keys | Sort-Object)) {
        $reqs = @($JobRequests[$poolId] | ForEach-Object {
                [pscustomobject]@{
                    Queue  = ConvertTo-CiWasteUtc $_.queueTime
                    Assign = ConvertTo-CiWasteUtc $_.assignTime
                    Finish = ConvertTo-CiWasteUtc $_.finishTime
                }
            })
        $inWindow = @($reqs | Where-Object { $_.Queue -and $_.Queue -ge $from -and $_.Queue -le $asOfUtc })
        $waits = [double[]]@($inWindow | Where-Object { $_.Assign } | ForEach-Object { [math]::Max(0.0, ($_.Assign - $_.Queue).TotalMinutes) })
        $events = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $reqs) {
            if (-not $r.Assign) { continue }
            $end = if ($r.Finish) { $r.Finish } else { $asOfUtc }
            $s = if ($r.Assign -gt $from) { $r.Assign } else { $from }
            $e = if ($end -lt $asOfUtc) { $end } else { $asOfUtc }
            if ($e -gt $s) {
                $events.Add([pscustomobject]@{ T = $s; D = 1 })
                $events.Add([pscustomobject]@{ T = $e; D = -1 })
            }
        }
        $info = $PoolInfo[$poolId]
        $capacity = if ($info) { $info.capacity } else { $null }
        $seconds = @{}   # concurrency -> seconds held
        $current = 0; $last = $from
        foreach ($ev in ($events | Sort-Object T, D)) {
            $span = ($ev.T - $last).TotalSeconds
            if ($span -gt 0) { $seconds[$current] = [double]$seconds[$current] + $span }
            $last = $ev.T
            $current += $ev.D
        }
        $windowSeconds = ($asOfUtc - $from).TotalSeconds
        $area = 0.0; $atCapacity = 0.0; $maxC = 0; $sustained = 0
        foreach ($k in $seconds.Keys) {
            $area += $k * $seconds[$k]
            if ($k -gt $maxC) { $maxC = $k }
            if ($seconds[$k] -ge 300 -and $k -gt $sustained) { $sustained = $k }
            if ($capacity -and $k -ge $capacity) { $atCapacity += $seconds[$k] }
        }
        [pscustomobject][ordered]@{
            poolId                = [int]$poolId
            name                  = if ($info) { $info.name } else { "pool-$poolId" }
            capacity              = $capacity
            jobRequests           = $inWindow.Count
            queueWaitP50Minutes   = Get-CiWasteRound (Get-CiWastePercentile $waits 0.5)
            queueWaitP90Minutes   = Get-CiWasteRound (Get-CiWastePercentile $waits 0.9)
            queueWaitMaxMinutes   = if ($waits.Count) { Get-CiWasteRound (($waits | Measure-Object -Maximum).Maximum) } else { $null }
            maxConcurrency        = $maxC
            sustainedPeak         = $sustained
            avgConcurrency        = Get-CiWasteRound ($area / $windowSeconds) 2
            percentTimeAtCapacity = if ($capacity) { Get-CiWasteRound (100.0 * $atCapacity / $windowSeconds) 1 } else { $null }
        }
    }

    return [ordered]@{
        window      = [ordered]@{ from = $from.ToString('o'); to = $asOfUtc.ToString('o'); hours = $Hours }
        totals      = [ordered]@{ ci = $ciTotals; chain = $chainTotals }
        definitions = @($definitions)
        pools       = @($pools)
        method      = [ordered]@{
            ciDefinition    = "definition name ends with '-CI'"
            duplicate       = 'same definition + sourceVersion + branch; last succeeded run (else last) kept, others are duplicates'
            redundant       = 'chain definition, refs/heads/main, not canceled; own commit + main HEAD of all upstream definitions at run start equal to an earlier non-canceled run'
            minutes         = 'startTime to finishTime, in-progress runs until the end of the window'
            sustainedPeak   = 'highest concurrency held for at least 5 minutes'
        }
    }
}

function Get-CiWasteAdoToken {
    # Only place that touches the credential. The token is returned to the caller and never written anywhere.
    $token = & az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Could not get an Azure DevOps access token. Run 'az login' and try again."
    }
    return ($token | Select-Object -First 1).Trim()
}

function Invoke-CiWasteAdoGet {
    # HTTP GET only. Returns @{ Body; ContinuationToken }. Errors carry the status code and the
    # path without query, never headers or the token.
    param([Parameter(Mandatory)][string]$Uri, [Parameter(Mandatory)][string]$Token)
    $secure = ConvertTo-SecureString -String $Token -AsPlainText -Force
    try {
        $body = Invoke-RestMethod -Method Get -Uri $Uri -Authentication Bearer -Token $secure -ResponseHeadersVariable headers -ErrorAction Stop
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        $path = ($Uri -split '\?')[0]
        throw "Azure DevOps GET failed (HTTP $status) for $path"
    }
    $continuation = $null
    if ($headers -and $headers['x-ms-continuationtoken']) { $continuation = [string]($headers['x-ms-continuationtoken'] | Select-Object -First 1) }
    return @{ Body = $body; ContinuationToken = $continuation }
}

function Get-CiWasteReport {
    <#
    .SYNOPSIS
        Shows how much CI work in Azure DevOps is duplicate (read-only).

    .DESCRIPTION
        Per CI definition: runs, resource-trigger runs, same-commit duplicate runs and share, wasted
        agent-minutes, estimated redundant minutes, queue wait p50/p90; per agent pool: job requests,
        queue wait, max/avg concurrency, time at capacity. See the module header for the method and
        docs/ci-waste-report.md for the 2026-10-10 baseline.

        Uses HTTP GET against dev.azure.com only. The access token comes from
        `az account get-access-token` and is never printed. No build is queued or canceled.

    .PARAMETER Hours
        Window length ending at -AsOf (default 24).

    .PARAMETER AsOf
        End of the window (default now). In-progress runs are measured up to this instant.

    .PARAMETER Organization
        Azure DevOps organization (default meshmakers).

    .PARAMETER Project
        Azure DevOps project (default OctoMesh).

    .PARAMETER CiPoolId
        Agent pool of the CI builds (default 45).

    .PARAMETER CdPoolId
        Agent pool of the CD jobs (default 46).

    .PARAMETER JobRequestCount
        How many completed job requests to fetch per pool (default 3000). A warning is written when this
        does not reach back to the start of the window.

    .PARAMETER ChainMap
        Hashtable definition name -> upstream definition name; defaults to the chain of the repos.

    .PARAMETER Json
        Emit the standard octo-tools envelope (schemaVersion, command, timestamp, data) instead of text.

    .EXAMPLE
        Get-CiWasteReport

    .EXAMPLE
        Get-CiWasteReport -Hours 168 -Json | ConvertFrom-Json | ForEach-Object { $_.data.totals.chain }
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 720)][int]$Hours = 24,
        [datetime]$AsOf = [datetime]::UtcNow,
        [string]$Organization = 'meshmakers',
        [string]$Project = 'OctoMesh',
        [int]$CiPoolId = 45,
        [int]$CdPoolId = 46,
        [ValidateRange(100, 20000)][int]$JobRequestCount = 3000,
        $ChainMap = $script:DefaultCiChainMap,
        [switch]$Json
    )

    $asOfUtc = ConvertTo-CiWasteUtc $AsOf
    $from = $asOfUtc.AddHours(-$Hours)
    $base = "https://dev.azure.com/$Organization"
    $token = Get-CiWasteAdoToken
    $iso = { param([datetime]$d) [uri]::EscapeDataString($d.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')) }

    # builds, paged by continuation token
    $builds = [System.Collections.Generic.List[object]]::new()
    $continuation = $null
    do {
        $uri = "$base/$Project/_apis/build/builds?minTime=$(& $iso $from)&maxTime=$(& $iso $asOfUtc)&queryOrder=queueTimeDescending&`$top=1000&api-version=7.1"
        if ($continuation) { $uri += "&continuationToken=$([uri]::EscapeDataString($continuation))" }
        $page = Invoke-CiWasteAdoGet -Uri $uri -Token $token
        foreach ($b in @($page.Body.value)) { $builds.Add($b) }
        $continuation = $page.ContinuationToken
    } while ($continuation)

    # pools
    $jobRequests = @{}
    $poolInfo = @{}
    foreach ($pool in @(@{ id = $CiPoolId; name = 'CI' }, @{ id = $CdPoolId; name = 'CD' })) {
        $reqPage = Invoke-CiWasteAdoGet -Uri "$base/_apis/distributedtask/pools/$($pool.id)/jobrequests?completedRequestCount=$JobRequestCount&api-version=7.1" -Token $token
        $requests = @($reqPage.Body.value)
        $jobRequests[$pool.id] = $requests
        $oldest = $requests | ForEach-Object { ConvertTo-CiWasteUtc $_.queueTime } | Sort-Object | Select-Object -First 1
        if ($requests.Count -ge $JobRequestCount -and $oldest -and $oldest -gt $from) {
            Write-Warning "Pool $($pool.id): the $JobRequestCount fetched job requests do not reach back to the start of the window; raise -JobRequestCount."
        }
        $capacity = $null
        try {
            $agentPage = Invoke-CiWasteAdoGet -Uri "$base/_apis/distributedtask/pools/$($pool.id)/agents?api-version=7.1" -Token $token
            $capacity = @($agentPage.Body.value | Where-Object { $_.enabled }).Count
        }
        catch { Write-Verbose "Agent capacity of pool $($pool.id) unavailable: $($_.Exception.Message)" }
        $poolInfo[$pool.id] = @{ name = $pool.name; capacity = $capacity }
    }

    $data = Measure-CiWaste -Builds $builds.ToArray() -JobRequests $jobRequests -PoolInfo $poolInfo -AsOf $asOfUtc -Hours $Hours -ChainMap $ChainMap

    if ($Json) {
        Write-OctoJson -Command 'Get-CiWasteReport' -Data $data
        return
    }

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $n = { param($v, [int]$d = 0) if ($null -eq $v) { '-' } else { ([double]$v).ToString("N$d", $inv) } }
    $c = $data.totals.chain
    $a = $data.totals.ci
    Write-Host "CI waste report  $($data.window.from)  ->  $($data.window.to)  ($Hours h)" -ForegroundColor Cyan
    Write-Host ("All CI:  {0} runs, {1} via resource trigger ({2}%), {3} min total" -f $a.runs, $a.resourceTriggerRuns, (& $n $a.resourceTriggerShare 1), (& $n $a.totalMinutes))
    Write-Host ("Chain:   {0} runs, {1} same-commit duplicates ({2}%), {3} of {4} min wasted ({5}%)" -f $c.runs, $c.duplicateRuns, (& $n $c.duplicateShare 1), (& $n $c.wastedMinutes), (& $n $c.totalMinutes), (& $n $c.wastedShareOfMinutes 1)) -ForegroundColor Yellow
    Write-Host ("Main:    {0} runs, {1} provably redundant ({2}%), about {3} of {4} min ({5}%)" -f $c.mainRuns, $c.redundantRuns, (& $n $c.redundantRunShare 1), (& $n $c.redundantMinutes), (& $n $c.mainMinutes), (& $n $c.redundantMinuteShare 1)) -ForegroundColor Yellow
    Write-Host ''
    $nameWidth = [math]::Max(10, (($data.definitions | ForEach-Object { $_.definition.Length } | Measure-Object -Maximum).Maximum))
    Write-Host ("{0} {1,4} {2,5} {3,4} {4,6} {5,8} {6,8} {7,8} {8,6} {9,6}" -f 'definition'.PadRight($nameWidth), 'runs', 'trig', 'dups', 'dup%', 'wastedMn', 'redundMn', 'totalMn', 'w.p50', 'w.p90') -ForegroundColor Cyan
    foreach ($d in $data.definitions) {
        Write-Host ("{0} {1,4} {2,5} {3,4} {4,6} {5,8} {6,8} {7,8} {8,6} {9,6}" -f $d.definition.PadRight($nameWidth), $d.runs, $d.resourceTriggerRuns, $d.duplicateRuns, (& $n $d.duplicateShare 1), (& $n $d.wastedMinutes), (& $n $d.redundantMinutes), (& $n $d.totalMinutes), (& $n $d.queueWaitP50Minutes 1), (& $n $d.queueWaitP90Minutes 1))
    }
    Write-Host ''
    Write-Host ("{0,-6} {1,8} {2,9} {3,6} {4,6} {5,6} {6,8} {7,7} {8,8}" -f 'pool', 'capacity', 'requests', 'w.p50', 'w.p90', 'w.max', 'maxConc', 'sustPk', 'avgConc') -ForegroundColor Cyan
    foreach ($p in $data.pools) {
        $atCap = if ($null -ne $p.percentTimeAtCapacity) { "  at capacity $(& $n $p.percentTimeAtCapacity 1)% of the time" } else { '' }
        Write-Host ("{0,-6} {1,8} {2,9} {3,6} {4,6} {5,6} {6,8} {7,7} {8,8}{9}" -f "$($p.name)($($p.poolId))", (& $n $p.capacity), $p.jobRequests, (& $n $p.queueWaitP50Minutes 1), (& $n $p.queueWaitP90Minutes 1), (& $n $p.queueWaitMaxMinutes 1), $p.maxConcurrency, $p.sustainedPeak, (& $n $p.avgConcurrency 2), $atCap)
    }
}

Export-ModuleMember -Function @('Get-CiWasteReport', 'Measure-CiWaste')
