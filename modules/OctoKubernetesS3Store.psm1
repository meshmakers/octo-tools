# OctoKubernetesS3Store — the local S3-compatible object store of the kind dev cluster (AB#5967, AB#6967).
#
# The archive COPY TO / COPY FROM staging area needs a store that every CrateDB node and the bot can
# reach. Locally that is SeaweedFS ("mini") as one more pod in octo-infra (kubernetes/infra/s3-store.yaml,
# Garage is the second candidate and not built). Two endpoints belong to it:
#   * the bot (a host process) uses the host port        http://localhost:8333
#   * CrateDB (in the cluster) uses the cluster name      seaweedfs.octo-infra:8333   (protocol = 'http')
#
# This module only ADDS to a cluster: it never restarts, recreates or deletes an existing pod, volume
# or namespace (Uninstall-OctoKubernetesS3Store removes only what it created itself). Credentials are
# generated at install time into the Kubernetes Secret octo-infra/seaweedfs-s3; they are never written
# to a file in a repository, printed or logged.

function Get-OctoKubernetesS3StoreInfo {
    <#
.SYNOPSIS
The non-secret facts about the local S3 store (names, ports, bucket, both endpoints).
#>
    [CmdletBinding()]
    param()
    [ordered]@{
        Namespace         = "octo-infra"
        ServiceName       = "seaweedfs"
        StatefulSetName   = "seaweedfs"
        SecretName        = "seaweedfs-s3"
        Port              = 8333
        NodePort          = 30333
        HostPort          = 8333
        HostEndpoint      = "http://localhost:8333"
        # Endpoint as CrateDB sees it (cluster DNS name and port, plain http). Second endpoint of the staging location.
        InClusterHostPort = "seaweedfs.octo-infra:8333"
        InClusterEndpoint = "http://seaweedfs.octo-infra:8333"
        Bucket            = "octo-artifacts"
        Region            = "us-east-1"
        InstancePrefix    = "local"
        # Host-side relay for clusters created before the host port mapping existed (kind cannot add a
        # port mapping to a running cluster): a docker container next to the node, outside the cluster.
        RelayContainer    = "octo-kind-s3-relay"
        RelayImage        = "alpine/socat:1.8.1.3"
        CrateHttpUri      = "http://127.0.0.1:4301"
        # Cluster setting that keeps COPY statements (they carry the S3 key) out of sys.jobs_log.
        JobLogFilter      = "stmt NOT ILIKE 'copy %'"
    }
}

function Remove-OctoSecretText {
    # Replaces every given secret value in a text so that an error message can be shown safely.
    param([string]$Text, [string[]]$Secrets)
    foreach ($s in $Secrets) {
        if (-not [string]::IsNullOrEmpty($s)) { $Text = $Text.Replace($s, "***") }
    }
    return $Text
}

function Get-OctoKubernetesS3StoreCredential {
    <#
.SYNOPSIS
Reads the local store credential from the Kubernetes Secret. Returns $null when the Secret does not exist.

.DESCRIPTION
The credential lives only in the Secret octo-infra/seaweedfs-s3 of the local kind cluster. The returned
object carries the values in memory for the caller (Start-Octo sets them as process environment of the
locally started bot); never print it.
#>
    [CmdletBinding()]
    param([string]$ClusterName = "kind")
    $info = Get-OctoKubernetesS3StoreInfo
    $json = & kubectl --context "kind-$ClusterName" -n $info.Namespace get secret $info.SecretName -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    $data = ($json | ConvertFrom-Json).data
    if (-not $data -or -not $data.accessKey -or -not $data.secretKey) { return $null }
    [pscustomobject]@{
        AccessKeyId     = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data.accessKey))
        SecretAccessKey = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data.secretKey))
    }
}

function New-OctoKubernetesS3StoreSecret {
    # Creates the credential Secret once. The manifest goes to kubectl on stdin (no secret in process
    # arguments) and uses create, not apply: apply would keep the plain stringData in the
    # last-applied-configuration annotation.
    param([string]$ClusterName)
    $info = Get-OctoKubernetesS3StoreInfo
    $ctx = "kind-$ClusterName"

    & kubectl --context $ctx -n $info.Namespace get secret $info.SecretName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "S3 store: credential Secret '$($info.SecretName)' already exists, keeping it" -ForegroundColor DarkGray
        return $true
    }

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $newHex = {
        param([int]$bytes)
        $b = New-Object byte[] $bytes
        $rng.GetBytes($b)
        -join ($b | ForEach-Object { $_.ToString("x2") })
    }
    $accessKey = & $newHex 10
    $secretKey = & $newHex 20
    $rng.Dispose()

    $s3Config = [ordered]@{
        identities = @(
            [ordered]@{
                name        = "octo-local"
                credentials = @([ordered]@{ accessKey = $accessKey; secretKey = $secretKey })
                actions     = @("Admin", "Read", "Write", "List", "Tagging")
            }
        )
    } | ConvertTo-Json -Depth 6 -Compress

    $manifest = [ordered]@{
        apiVersion = "v1"
        kind       = "Secret"
        metadata   = [ordered]@{ name = $info.SecretName; namespace = $info.Namespace }
        type       = "Opaque"
        stringData = [ordered]@{ accessKey = $accessKey; secretKey = $secretKey; "s3.json" = $s3Config }
    } | ConvertTo-Json -Depth 6 -Compress

    $manifest | & kubectl --context $ctx create -f - | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "S3 store: creating the credential Secret failed"
        return $false
    }
    Write-Host "S3 store: generated a local credential in Secret $($info.Namespace)/$($info.SecretName)" -ForegroundColor Cyan
    return $true
}

function Invoke-OctoCrateSql {
    # One SQL statement over the CrateDB HTTP endpoint. Returns the parsed result or throws a sanitized error.
    param(
        [Parameter(Mandatory)] [string]$Stmt,
        [string]$CrateHttpUri,
        [string[]]$Secrets = @(),
        [int]$TimeoutSec = 60
    )
    try {
        return Invoke-RestMethod -Method Post -Uri "$CrateHttpUri/_sql" -ContentType 'application/json' `
            -Body (@{ stmt = $Stmt } | ConvertTo-Json -Compress) -TimeoutSec $TimeoutSec
    }
    catch {
        $msg = if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch { "CrateDB request failed" }
        } else { $_.Exception.Message }
        throw (Remove-OctoSecretText -Text ([string]$msg) -Secrets $Secrets)
    }
}

function Get-OctoCrateJobLogFilter {
    # The effective stats.jobs_log_filter of the cluster as text, or $null when unreadable.
    param([string]$CrateHttpUri)
    try {
        $r = Invoke-OctoCrateSql -Stmt "SELECT settings['stats']['jobs_log_filter'] FROM sys.cluster" -CrateHttpUri $CrateHttpUri -TimeoutSec 15
        return [string]$r.rows[0][0]
    }
    catch { return $null }
}

function Test-OctoCrateJobLogFilterActive {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    # Exactly the expected filter, ignoring the spacing; a different expression is not trusted.
    $norm = { param($s) ($s -replace '\s+', ' ').Trim().ToLowerInvariant() }
    return (& $norm $Value) -eq (& $norm (Get-OctoKubernetesS3StoreInfo).JobLogFilter)
}

function Set-OctoKubernetesCrateDbJobLogFilter {
    <#
.SYNOPSIS
Sets the persistent CrateDB cluster setting stats.jobs_log_filter so that COPY statements, which carry the
S3 key in their text, never reach sys.jobs_log. Idempotent; additive (a cluster setting, no restart).

.DESCRIPTION
A value that is neither the default (true) nor the expected filter was set by someone on purpose: it is
left alone and reported, because overwriting it could silence a filter the developer relies on.
#>
    [CmdletBinding()]
    param([string]$CrateHttpUri = (Get-OctoKubernetesS3StoreInfo).CrateHttpUri, [int]$RetrySeconds = 60)
    $info = Get-OctoKubernetesS3StoreInfo
    $deadline = (Get-Date).AddSeconds($RetrySeconds)
    $current = $null
    while ($true) {
        $current = Get-OctoCrateJobLogFilter -CrateHttpUri $CrateHttpUri
        if ($null -ne $current) { break }
        if ((Get-Date) -gt $deadline) {
            Write-Warning "CrateDB at $CrateHttpUri is not reachable, the job log filter was not set."
            return $false
        }
        Start-Sleep -Seconds 3
    }
    if (Test-OctoCrateJobLogFilterActive -Value $current) {
        Write-Host "CrateDB: job log filter already set" -ForegroundColor DarkGray
        return $true
    }
    if ($current -and $current.Trim().ToLowerInvariant() -ne "true") {
        Write-Warning "CrateDB: stats.jobs_log_filter holds a custom value, leaving it untouched. COPY statements may be recorded with the S3 key."
        return $false
    }
    $literal = $info.JobLogFilter.Replace("'", "''")
    try {
        Invoke-OctoCrateSql -Stmt "SET GLOBAL PERSISTENT stats.jobs_log_filter = '$literal'" -CrateHttpUri $CrateHttpUri | Out-Null
    }
    catch {
        Write-Warning "CrateDB: setting stats.jobs_log_filter failed: $_"
        return $false
    }
    Write-Host "CrateDB: persistent job log filter set (COPY statements stay out of sys.jobs_log)" -ForegroundColor Cyan
    return $true
}

function Test-OctoLocalPortOpen([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(2500)) {
            try { $client.EndConnect($iar); return $client.Connected } catch { return $false }
        }
        return $false
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Initialize-OctoKubernetesS3HostPort {
    <#
.SYNOPSIS
Makes the store reachable on the host port. A cluster created from the current kind-cluster.yaml maps it
itself; a cluster created before cannot get a new mapping without being recreated, so a small relay
container (socat, outside the cluster) forwards 127.0.0.1:8333 to the node port.
#>
    [CmdletBinding()]
    param([string]$ClusterName = "kind")
    $info = Get-OctoKubernetesS3StoreInfo
    $node = "$ClusterName-control-plane"

    $mapped = & docker port $node "$($info.NodePort)/tcp" 2>$null
    if ($LASTEXITCODE -eq 0 -and $mapped) {
        Write-Host "S3 store: host port $($info.HostPort) is mapped by the kind node" -ForegroundColor DarkGray
        return $true
    }

    $state = (& docker inspect -f '{{.State.Running}}' $info.RelayContainer 2>$null)
    if ($LASTEXITCODE -eq 0) {
        if ($state -ne "true") { & docker start $info.RelayContainer | Out-Null }
        Write-Host "S3 store: relay container '$($info.RelayContainer)' provides the host port" -ForegroundColor DarkGray
        return $true
    }

    if (Test-OctoLocalPortOpen $info.HostPort) {
        Write-Warning "Host port $($info.HostPort) is already in use by another process; the S3 store is not reachable from the host."
        return $false
    }

    Write-Host "S3 store: starting relay container '$($info.RelayContainer)' (127.0.0.1:$($info.HostPort) -> $node`:$($info.NodePort)); this kind cluster has no host port mapping for the store" -ForegroundColor Green
    & docker run -d --name $info.RelayContainer --label "octo-tools.cluster=$ClusterName" --restart unless-stopped --network kind `
        -p "127.0.0.1:$($info.HostPort):$($info.HostPort)" $info.RelayImage `
        "TCP-LISTEN:$($info.HostPort),fork,reuseaddr" "TCP:$node`:$($info.NodePort)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Starting the relay container failed; the S3 store is not reachable from the host."
        return $false
    }
    return $true
}

function Install-OctoKubernetesS3Store {
    <#
.SYNOPSIS
Adds the local S3-compatible object store (SeaweedFS) to the kind cluster: credential Secret, pod, services,
volume, bucket, host port and the CrateDB job log filter. Idempotent and purely additive.

.DESCRIPTION
Install-OctoKubernetes calls this as a step; it can be run on its own on a cluster that already exists,
because it does not touch anything that is already there (no restart, no recreate, no delete).

.PARAMETER ClusterName
Name of the kind cluster. Defaults to "kind".

.PARAMETER SkipHostPort
Do not provide the host port (neither the node mapping check nor the relay container).

.EXAMPLE
Install-OctoKubernetesS3Store
#>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [switch]$SkipHostPort,
        [Parameter()] [int]$RolloutTimeoutSeconds = 300
    )
    $info = Get-OctoKubernetesS3StoreInfo
    $ctx = "kind-$ClusterName"

    foreach ($tool in @("kubectl", "docker")) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Error "$tool is not on PATH."
            return $false
        }
    }
    & kubectl --context $ctx get namespace $info.Namespace 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Namespace '$($info.Namespace)' not found in context '$ctx'. Run Install-OctoKubernetes first."
        return $false
    }

    # The filter comes first: from the moment the store is usable, a COPY with the key may run.
    if (-not (Set-OctoKubernetesCrateDbJobLogFilter)) {
        Write-Warning "The job log filter is not in place; do not run COPY statements with the S3 key until it is (Test-OctoKubernetesS3Store)."
    }

    if (-not (New-OctoKubernetesS3StoreSecret -ClusterName $ClusterName)) { return $false }

    Write-Host "Applying the S3 store (SeaweedFS) to $($info.Namespace)" -ForegroundColor Green
    & kubectl --context $ctx apply -f (Join-Path $kubernetesPath "infra/s3-store.yaml") | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Error "kubectl apply s3-store.yaml failed"; return $false }

    & kubectl --context $ctx -n $info.Namespace rollout status "statefulset/$($info.StatefulSetName)" --timeout="$($RolloutTimeoutSeconds)s" | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Error "The S3 store did not become ready within the timeout."; return $false }

    if (-not $SkipHostPort) {
        if (-not (Initialize-OctoKubernetesS3HostPort -ClusterName $ClusterName)) { return $false }
    }

    Write-Host "S3 store ready: host $($info.HostEndpoint), cluster $($info.InClusterEndpoint), bucket '$($info.Bucket)'." -ForegroundColor Cyan
    Write-Host "  Credential: Secret $($info.Namespace)/$($info.SecretName) (keys accessKey, secretKey); check with Test-OctoKubernetesS3Store" -ForegroundColor Cyan
    return $true
}

function Uninstall-OctoKubernetesS3Store {
    <#
.SYNOPSIS
Removes the local S3 store from the cluster: pod, services, volume (all staged objects), credential Secret and
the host relay container. DESTRUCTIVE for the staged objects; the CrateDB job log filter stays (it is harmless).

.DESCRIPTION
Only the objects this module created are deleted. Uninstall-OctoKubernetes (whole cluster) needs no call to it
except for the relay container, which it removes itself.
#>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [switch]$Force
    )
    $info = Get-OctoKubernetesS3StoreInfo
    $ctx = "kind-$ClusterName"
    if (-not $Force) {
        Write-Warning "This deletes the S3 store of cluster '$ClusterName' with every object in it (copy staging, tenant dumps), its credential Secret and the host relay container."
        $ans = Read-Host "Type 'yes' to continue"
        if ($ans -ne "yes") { Write-Host "Aborted." -ForegroundColor Yellow; return $false }
    }
    & kubectl --context $ctx delete -f (Join-Path $kubernetesPath "infra/s3-store.yaml") --ignore-not-found | Out-Host
    & kubectl --context $ctx -n $info.Namespace delete pvc "data-$($info.StatefulSetName)-0" --ignore-not-found | Out-Host
    & kubectl --context $ctx -n $info.Namespace delete secret $info.SecretName --ignore-not-found | Out-Host
    Remove-OctoKubernetesS3Relay -ClusterName $ClusterName | Out-Null
    return $true
}

function Remove-OctoKubernetesS3Relay {
    # Removes the host relay container if it belongs to this cluster; never touches anything else.
    param([string]$ClusterName = "kind")
    $info = Get-OctoKubernetesS3StoreInfo
    $owner = & docker inspect -f '{{index .Config.Labels "octo-tools.cluster"}}' $info.RelayContainer 2>$null
    if ($LASTEXITCODE -eq 0 -and "$owner".Trim() -eq $ClusterName) {
        & docker rm -f $info.RelayContainer | Out-Null
        return $true
    }
    return $false
}

function Invoke-OctoS3Request {
    # A signed (or, with -Unsigned, anonymous) S3 request through curl. The credential goes to curl on stdin
    # (-K -), not in the argument list. Returns the HTTP status and the body.
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Url,
        [pscustomobject]$Credential,
        [string]$Region = "us-east-1",
        [switch]$Unsigned
    )
    $curl = Get-Command curl.exe, curl -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $curl) { throw "curl is not available" }
    $bodyFile = Join-Path ([System.IO.Path]::GetTempPath()) ("octo-s3-" + [guid]::NewGuid().ToString("N") + ".out")
    try {
        $cmdArgs = @("-s", "-S", "--max-time", "30", "-X", $Method, "-o", $bodyFile, "-w", "%{http_code}")
        if ($Unsigned) {
            $code = & $curl.Source @cmdArgs $Url
        }
        else {
            $cmdArgs += @("--aws-sigv4", "aws:amz:$Region`:s3", "-K", "-")
            $code = "user = `"$($Credential.AccessKeyId):$($Credential.SecretAccessKey)`"" | & $curl.Source @cmdArgs $Url
        }
        $content = if (Test-Path $bodyFile) { Get-Content $bodyFile -Raw } else { "" }
        [pscustomobject]@{ Status = [int]("$code".Trim()); Body = $content }
    }
    catch {
        [pscustomobject]@{ Status = 0; Body = "" }
    }
    finally {
        Remove-Item $bodyFile -ErrorAction SilentlyContinue
    }
}

function Test-OctoKubernetesS3Store {
    <#
.SYNOPSIS
Checks the local S3 store and the job log filter. Prints a result per check, never a key.

.DESCRIPTION
Checks, in this order:
  1. the store pod is ready,
  2. the store answers on the host port (anonymous request is refused = it answers; a signed list works),
  3. the store answers from inside the cluster (TCP and HTTP from the CrateDB pod to the cluster name),
  4. the cluster setting stats.jobs_log_filter is the expected filter,
  5. unless -SkipCopyProbe: a COPY TO from the CrateDB node into the store under the cluster name (of a
     three-row probe table that the check creates in its own schema octo_tools_check and drops again;
     COPY TO does not accept system tables), the objects are visible through the host port, and neither the COPY nor a COPY with a
     canary key appears in sys.jobs_log while an ordinary statement does. The COPY with the real key only
     runs when check 4 passed and the canary COPY left no trace. The probe objects are deleted afterwards.

.PARAMETER SkipCopyProbe
Read-only variant: checks 1-4 only, no statement with a key, no table or object written.

.PARAMETER Json
Emit one JSON document (envelope of OctoJsonOutput) instead of text.

.OUTPUTS
An object with Success and the individual results.
#>
    [CmdletBinding()]
    param(
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [switch]$SkipCopyProbe,
        [Parameter()] [switch]$Json
    )
    $info = Get-OctoKubernetesS3StoreInfo
    $ctx = "kind-$ClusterName"
    $results = [ordered]@{}
    $lines = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Name, $Ok, [string]$Detail)
        $results[$Name] = [ordered]@{ ok = $Ok; detail = $Detail }
        $lines.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    }

    $credential = Get-OctoKubernetesS3StoreCredential -ClusterName $ClusterName
    $secrets = @()
    if ($credential) { $secrets = @($credential.AccessKeyId, $credential.SecretAccessKey) }

    # 1. pod
    $ready = & kubectl --context $ctx -n $info.Namespace get pod "$($info.StatefulSetName)-0" -o 'jsonpath={.status.containerStatuses[0].ready}' 2>$null
    $podReady = ($LASTEXITCODE -eq 0 -and $ready -eq "true")
    & $add "pod" $podReady $(if ($podReady) { "$($info.StatefulSetName)-0 ready in $($info.Namespace)" } else { "$($info.StatefulSetName)-0 is not ready (Install-OctoKubernetesS3Store)" })

    # 2. host
    $hostOk = $false
    $hostDetail = "no answer on $($info.HostEndpoint)"
    if (Test-OctoLocalPortOpen $info.HostPort) {
        $anon = Invoke-OctoS3Request -Method GET -Url "$($info.HostEndpoint)/" -Unsigned
        if ($anon.Status -in 401, 403) {
            if ($credential) {
                $signed = Invoke-OctoS3Request -Method GET -Url "$($info.HostEndpoint)/$($info.Bucket)/?list-type=2&max-keys=1" -Credential $credential -Region $info.Region
                $hostOk = ($signed.Status -eq 200)
                $hostDetail = if ($hostOk) { "answers on $($info.HostEndpoint); anonymous requests are refused; bucket '$($info.Bucket)' listable with the credential" }
                              else { "answers on $($info.HostEndpoint), but the signed bucket list returned HTTP $($signed.Status)" }
            }
            else { $hostDetail = "answers on $($info.HostEndpoint), but the credential Secret is missing" }
        }
        else { $hostDetail = "port open, unexpected answer HTTP $($anon.Status) to an anonymous request" }
    }
    & $add "host" $hostOk $hostDetail

    # 3. in cluster, from the CrateDB pod (bash /dev/tcp: no client tool needed in the image)
    $probeCmd = 'exec 3<>/dev/tcp/seaweedfs.octo-infra/8333 && printf "GET / HTTP/1.0\r\n\r\n" >&3 && head -n 1 <&3'
    $inCluster = & kubectl --context $ctx -n $info.Namespace exec cratedb-0 -- bash -c $probeCmd 2>$null
    $inClusterOk = ($LASTEXITCODE -eq 0 -and "$inCluster" -match 'HTTP/1\.[01] \d{3}')
    & $add "inCluster" $inClusterOk $(if ($inClusterOk) { "answers from the CrateDB pod as $($info.InClusterHostPort) ($("$inCluster".Trim()))" } else { "no answer from the CrateDB pod to $($info.InClusterHostPort)" })

    # 4. filter
    $filterValue = Get-OctoCrateJobLogFilter -CrateHttpUri $info.CrateHttpUri
    $filterOk = Test-OctoCrateJobLogFilterActive -Value $filterValue
    & $add "jobLogFilter" $filterOk $(if ($filterOk) { "stats.jobs_log_filter is active" } elseif ($null -eq $filterValue) { "CrateDB not reachable on $($info.CrateHttpUri)" } else { "stats.jobs_log_filter is not the expected filter (Set-OctoKubernetesCrateDbJobLogFilter)" })

    # 5. COPY probe
    if (-not $SkipCopyProbe) {
        $copyOk = $false
        $visibleOk = $false
        $traceOk = $false
        $runId = [guid]::NewGuid().ToString("N").Substring(0, 12)
        $prefix = "_status/$runId"
        $uriBase = "$($info.InClusterHostPort)/$($info.Bucket)/$prefix"
        $probeTable = "octo_tools_check.s3_probe"
        if (-not ($filterOk -and $credential -and $hostOk)) {
            & $add "copy" $false "skipped: needs the filter, the credential and the host check to pass first"
        }
        else {
            try {
                Invoke-OctoCrateSql -Stmt "DROP TABLE IF EXISTS $probeTable" -CrateHttpUri $info.CrateHttpUri | Out-Null
                Invoke-OctoCrateSql -Stmt "CREATE TABLE $probeTable (id INTEGER, v TEXT) CLUSTERED INTO 1 SHARDS WITH (number_of_replicas = 0)" -CrateHttpUri $info.CrateHttpUri | Out-Null
                Invoke-OctoCrateSql -Stmt "INSERT INTO $probeTable (id, v) VALUES (1, 'a'), (2, 'b'), (3, 'c')" -CrateHttpUri $info.CrateHttpUri | Out-Null
                Invoke-OctoCrateSql -Stmt "REFRESH TABLE $probeTable" -CrateHttpUri $info.CrateHttpUri | Out-Null
                # An ordinary statement must be recorded, a COPY with a canary key must not.
                $marker = "octo-s3-check-$runId"
                Invoke-OctoCrateSql -Stmt "SELECT '$marker' AS marker" -CrateHttpUri $info.CrateHttpUri | Out-Null
                $canaryStmt = "COPY $probeTable TO DIRECTORY 's3://canaryaccesskey:canarysecretkey@$uriBase-canary/' WITH (protocol = 'http', compression = 'gzip')"
                try { Invoke-OctoCrateSql -Stmt $canaryStmt -CrateHttpUri $info.CrateHttpUri | Out-Null } catch { }
                $copyStmt = $null
                Start-Sleep -Milliseconds 800
                # Only statements that START with COPY count: this check's own SELECTs mention the canary text.
                $canaryRows = (Invoke-OctoCrateSql -Stmt "SELECT count(*) FROM sys.jobs_log WHERE stmt ILIKE 'copy %canaryaccesskey%'" -CrateHttpUri $info.CrateHttpUri).rows[0][0]
                $markerRows = (Invoke-OctoCrateSql -Stmt "SELECT count(*) FROM sys.jobs_log WHERE stmt LIKE 'SELECT ''$marker''%'" -CrateHttpUri $info.CrateHttpUri).rows[0][0]
                if ($canaryRows -ne 0 -or $markerRows -lt 1) {
                    & $add "copy" $false "skipped the COPY with the real key: the canary COPY left $canaryRows entries in sys.jobs_log (expected 0) and the ordinary statement $markerRows (expected 1)"
                }
                else {
                    $copyStmt = "COPY $probeTable TO DIRECTORY 's3://$($credential.AccessKeyId):$($credential.SecretAccessKey)@$uriBase/' WITH (protocol = 'http', compression = 'gzip')"
                    $r = Invoke-OctoCrateSql -Stmt $copyStmt -CrateHttpUri $info.CrateHttpUri -Secrets $secrets
                    $rows = $r.rowcount
                    $copyOk = ($rows -gt 0)
                    & $add "copy" $copyOk "COPY TO from the CrateDB node into $($info.InClusterHostPort)/$($info.Bucket)/$prefix/ exported $rows rows"

                    $list = Invoke-OctoS3Request -Method GET -Url "$($info.HostEndpoint)/$($info.Bucket)/?list-type=2&prefix=$prefix/" -Credential $credential -Region $info.Region
                    $keys = @([regex]::Matches($list.Body, '<Key>([^<]+)</Key>') | ForEach-Object { $_.Groups[1].Value })
                    $visibleOk = ($list.Status -eq 200 -and $keys.Count -gt 0)
                    & $add "objects" $visibleOk "$($keys.Count) object(s) under $prefix/ visible through the host port"

                    Start-Sleep -Milliseconds 800
                    $copyRows = (Invoke-OctoCrateSql -Stmt "SELECT count(*) FROM sys.jobs_log WHERE stmt ILIKE 'copy %$runId%'" -CrateHttpUri $info.CrateHttpUri).rows[0][0]
                    $traceOk = ($copyRows -eq 0)
                    & $add "jobsLog" $traceOk $(if ($traceOk) { "no COPY entry in sys.jobs_log (the COPY with the real key and the canary COPY); the ordinary statement is recorded" } else { "sys.jobs_log holds $copyRows COPY entries with the real key" })

                    foreach ($k in $keys) {
                        Invoke-OctoS3Request -Method DELETE -Url "$($info.HostEndpoint)/$($info.Bucket)/$k" -Credential $credential -Region $info.Region | Out-Null
                    }
                }
            }
            catch {
                $msg = Remove-OctoSecretText -Text ([string]$_) -Secrets $secrets
                & $add "copy" $false "COPY probe failed: $msg"
            }
            finally {
                try { Invoke-OctoCrateSql -Stmt "DROP TABLE IF EXISTS $probeTable" -CrateHttpUri $info.CrateHttpUri | Out-Null } catch { }
            }
        }
    }

    $success = -not ($lines | Where-Object { -not $_.Ok })
    if ($Json) {
        Write-OctoJson -Command 'Test-OctoKubernetesS3Store' -Data ([ordered]@{
                success       = [bool]$success
                hostEndpoint  = $info.HostEndpoint
                inClusterHost = $info.InClusterHostPort
                bucket        = $info.Bucket
                checks        = $results
            })
        return
    }
    Write-Host "== S3 store ==" -ForegroundColor Cyan
    foreach ($l in $lines) {
        $tag = if ($l.Ok) { "OK  " } else { "FAIL" }
        $color = if ($l.Ok) { "Green" } else { "Red" }
        Write-Host ("  {0} {1,-13} {2}" -f $tag, $l.Name, $l.Detail) -ForegroundColor $color
    }
    return [pscustomobject]@{ Success = [bool]$success; Checks = $results }
}

function Set-OctoLocalS3StoreEnvironment {
    <#
.SYNOPSIS
Sets (or removes) the artifact store environment of the locally started bot: S3 provider, the host endpoint, the
bucket, the credential and the second endpoint under which CrateDB reaches the same store.

.DESCRIPTION
Called by Start-Octo before the services start. The settings are only set when the credential Secret exists
and the store answers on the host port; otherwise a value left over from an earlier Start-Octo in the same
shell is removed and the bot keeps its file system store (the row path of the archive dump). Nothing here is
printed. Returns $true when the store settings are in place.

The second-endpoint variable OCTO_ARTIFACTSTORAGE__S3__CRATEDBSERVICEURL is the S3ArtifactStorageOptions.CrateDbServiceUrl
property of octo-common-services (section ArtifactStorage).
#>
    [CmdletBinding()]
    param(
        [string]$ClusterName = "kind",
        # Do not use the store: only remove the settings an earlier Start-Octo of this shell set.
        [switch]$Disable
    )
    $info = Get-OctoKubernetesS3StoreInfo
    $names = @(
        "OCTO_ARTIFACTSTORAGE__PROVIDER", "OCTO_ARTIFACTSTORAGE__INSTANCEPREFIX",
        "OCTO_ARTIFACTSTORAGE__S3__SERVICEURL", "OCTO_ARTIFACTSTORAGE__S3__REGION", "OCTO_ARTIFACTSTORAGE__S3__BUCKET",
        "OCTO_ARTIFACTSTORAGE__S3__FORCEPATHSTYLE", "OCTO_ARTIFACTSTORAGE__S3__ACCESSKEYID", "OCTO_ARTIFACTSTORAGE__S3__SECRETACCESSKEY",
        "OCTO_ARTIFACTSTORAGE__S3__CRATEDBSERVICEURL"
    )
    $clear = {
        # Only what an earlier Start-Octo of this shell set: the host endpoint identifies it.
        if ($env:OCTO_ARTIFACTSTORAGE__S3__SERVICEURL -eq $info.HostEndpoint) {
            foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
        }
    }

    if ($Disable) {
        & $clear
        return $false
    }

    $credential = $null
    if ((Get-Command kubectl -ErrorAction SilentlyContinue) -and (Test-OctoLocalPortOpen $info.HostPort)) {
        $credential = Get-OctoKubernetesS3StoreCredential -ClusterName $ClusterName
    }
    if (-not $credential) {
        & $clear
        return $false
    }

    $env:OCTO_ARTIFACTSTORAGE__PROVIDER = "S3"
    $env:OCTO_ARTIFACTSTORAGE__INSTANCEPREFIX = $info.InstancePrefix
    $env:OCTO_ARTIFACTSTORAGE__S3__SERVICEURL = $info.HostEndpoint
    $env:OCTO_ARTIFACTSTORAGE__S3__REGION = $info.Region
    $env:OCTO_ARTIFACTSTORAGE__S3__BUCKET = $info.Bucket
    $env:OCTO_ARTIFACTSTORAGE__S3__FORCEPATHSTYLE = "true"
    $env:OCTO_ARTIFACTSTORAGE__S3__ACCESSKEYID = $credential.AccessKeyId
    $env:OCTO_ARTIFACTSTORAGE__S3__SECRETACCESSKEY = $credential.SecretAccessKey
    $env:OCTO_ARTIFACTSTORAGE__S3__CRATEDBSERVICEURL = $info.InClusterEndpoint
    return $true
}

Export-ModuleMember -Function @(
    'Get-OctoKubernetesS3StoreInfo',
    'Get-OctoKubernetesS3StoreCredential',
    'Install-OctoKubernetesS3Store',
    'Uninstall-OctoKubernetesS3Store',
    'Remove-OctoKubernetesS3Relay',
    'Test-OctoKubernetesS3Store',
    'Set-OctoKubernetesCrateDbJobLogFilter',
    'Set-OctoLocalS3StoreEnvironment'
)
