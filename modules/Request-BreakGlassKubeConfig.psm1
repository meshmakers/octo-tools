function Request-BreakGlassKubeConfig {
    <#
    .SYNOPSIS
        Requests a short-lived cluster-admin kubeconfig via Semaphore and merges
        it into ~/.kube/config.

    .DESCRIPTION
        Triggers the `break-glass-issue` Ansible template in Semaphore (which
        provisions a ServiceAccount + ClusterRoleBinding on the target cluster
        and produces a token via `kubectl create token --duration=...`), polls
        the task, unwraps the resulting single-use Vault wrap token, removes any
        previous `breakglass-<cluster>-*` context, and merges the new context
        into ~/.kube/config.

        The kubeconfig token expires automatically at the requested duration
        (1-4 hours). Stale ServiceAccount/ClusterRoleBinding objects are reaped
        by an hourly Semaphore cleanup job.

        Every request is audited in:
          - Semaphore (task #, requester, extra vars, output)
          - Vault     (AppRole login + sys/wrapping/wrap + unwrap events)
          - Kubernetes audit log (ServiceAccount + token creation under the
                                  requester-named SA)
          - Teams     (shared #ops-breakglass channel)

    .PARAMETER Cluster
        Target cluster name. Must be one of test-2, staging-1, prod-1, prod-2.

    .PARAMETER Reason
        Free-text justification, min 10 characters. Logged everywhere and
        visible to the whole team in the Teams alert.

    .PARAMETER DurationHours
        Token lifetime in hours, 1-4. Default: 2.

    .PARAMETER SemaphoreUrl
        Base URL of the Semaphore instance. Default: $env:SEMAPHORE_URL.

    .PARAMETER SemaphoreApiToken
        Per-developer API token (Semaphore UI -> User -> API Tokens).
        Default: $env:SEMAPHORE_API_TOKEN.

    .PARAMETER SemaphoreProjectId
        Numeric project id holding the break-glass templates.
        Default: $env:SEMAPHORE_BREAKGLASS_PROJECT_ID.

    .PARAMETER SemaphoreTemplateId
        Numeric template id of the `break-glass-issue` template.
        Default: $env:SEMAPHORE_BREAKGLASS_TEMPLATE_ID.

    .PARAMETER VaultAddr
        Vault base URL used to unwrap the response-wrapped kubeconfig.
        Default: $env:VAULT_ADDR or https://vault.mm.cloud.

    .PARAMETER PollIntervalSeconds
        Seconds between Semaphore task status polls. Default: 3.

    .PARAMETER TimeoutSeconds
        Maximum time to wait for the Semaphore task to finish. Default: 180.

    .EXAMPLE
        Request-BreakGlassKubeConfig -Cluster test-2 -Reason "investigating stuck PVC on octo-mesh ns"

    .EXAMPLE
        Request-BreakGlassKubeConfig -Cluster prod-1 -Reason "urgent: ingress-nginx pod crashloop, P1" -DurationHours 4
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('test-2', 'staging-1', 'prod-1', 'prod-2')]
        [string]$Cluster,

        [Parameter(Mandatory = $true)]
        [ValidateLength(10, 500)]
        [string]$Reason,

        [Parameter()]
        [ValidateRange(1, 4)]
        [int]$DurationHours = 2,

        [Parameter()]
        [string]$SemaphoreUrl = $env:SEMAPHORE_URL,

        [Parameter()]
        [string]$SemaphoreApiToken = $env:SEMAPHORE_API_TOKEN,

        [Parameter()]
        [int]$SemaphoreProjectId = ($env:SEMAPHORE_BREAKGLASS_PROJECT_ID -as [int]),

        [Parameter()]
        [int]$SemaphoreTemplateId = ($env:SEMAPHORE_BREAKGLASS_TEMPLATE_ID -as [int]),

        [Parameter()]
        [string]$VaultAddr = $(if ($env:VAULT_ADDR) { $env:VAULT_ADDR } else { 'https://vault.mm.cloud' }),

        [Parameter()]
        [int]$PollIntervalSeconds = 3,

        [Parameter()]
        [int]$TimeoutSeconds = 180,

        [Parameter()]
        [switch]$Json
    )

    if (-not $SemaphoreUrl)        { throw "SEMAPHORE_URL not set (env var or -SemaphoreUrl). See docs/BREAK-GLASS-ACCESS.md." }
    if (-not $SemaphoreApiToken)   { throw "SEMAPHORE_API_TOKEN not set. Create one in Semaphore UI: User -> API Tokens." }
    if (-not $SemaphoreProjectId)  { throw "SEMAPHORE_BREAKGLASS_PROJECT_ID not set. See docs/BREAK-GLASS-ACCESS.md for the value." }
    if (-not $SemaphoreTemplateId) { throw "SEMAPHORE_BREAKGLASS_TEMPLATE_ID not set. See docs/BREAK-GLASS-ACCESS.md for the value." }

    $semHeaders = @{ Authorization = "Bearer $SemaphoreApiToken" }

    $requesterName = if ($env:USER)     { $env:USER }
                     elseif ($env:USERNAME) { $env:USERNAME }
                     else                { [Environment]::UserName }

    $extraVars = @{
        target_cluster = $Cluster
        reason         = $Reason
        duration_hours = $DurationHours
        requester_name = $requesterName
    }

    $taskBody = @{
        template_id = $SemaphoreTemplateId
        environment = ($extraVars | ConvertTo-Json -Compress)
    } | ConvertTo-Json

    Write-Host "Submitting break-glass request: cluster=$Cluster, duration=${DurationHours}h, reason='$Reason'"
    try {
        $taskResp = Invoke-RestMethod -Uri "$SemaphoreUrl/api/project/$SemaphoreProjectId/tasks" `
            -Method POST -Headers $semHeaders -ContentType "application/json" -Body $taskBody -ErrorAction Stop
    }
    catch {
        throw "Failed to submit Semaphore task: $($_.Exception.Message)"
    }
    $taskId = $taskResp.id
    Write-Host "Submitted Semaphore task #$taskId"

    # Poll
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $task = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollIntervalSeconds
        try {
            $task = Invoke-RestMethod -Uri "$SemaphoreUrl/api/project/$SemaphoreProjectId/tasks/$taskId" `
                -Headers $semHeaders -ErrorAction Stop
        }
        catch {
            Write-Verbose "Poll error (will retry): $($_.Exception.Message)"
            continue
        }
        Write-Verbose "Task #$taskId status: $($task.status)"
        if ($task.status -in @('success', 'error', 'stopped', 'failed')) { break }
    }
    if (-not $task -or $task.status -ne 'success') {
        $url = "$SemaphoreUrl/project/$SemaphoreProjectId/templates/$SemaphoreTemplateId"
        throw "Semaphore task #$taskId did not succeed (status: $($task.status)). Check: $url"
    }
    $durationSec = if ($task.start -and $task.end) {
        try { [int]([datetime]$task.end - [datetime]$task.start).TotalSeconds } catch { '?' }
    } else { '?' }
    Write-Host "Task completed in ${durationSec}s"

    # Fetch output
    try {
        $outputLines = Invoke-RestMethod -Uri "$SemaphoreUrl/api/project/$SemaphoreProjectId/tasks/$taskId/output" `
            -Headers $semHeaders -ErrorAction Stop
    }
    catch {
        throw "Failed to fetch task output: $($_.Exception.Message)"
    }
    $allText = ($outputLines | ForEach-Object { $_.output }) -join "`n"
    # Strip ANSI color/reset escapes (Semaphore wraps task output with them)
    $allText = [regex]::Replace($allText, "`e\[[0-9;]*[A-Za-z]", '')

    # Parse markers. Token alphabet is base64url-ish, so use a tight char class
    # rather than \S+ to defend against any other trailing control chars.
    $wrapMatch    = [regex]::Match($allText, 'BREAKGLASS_WRAP_TOKEN=([A-Za-z0-9._\-]+)')
    $contextMatch = [regex]::Match($allText, 'BREAKGLASS_CONTEXT=([A-Za-z0-9._\-]+)')
    $expiresMatch = [regex]::Match($allText, 'BREAKGLASS_EXPIRES=([A-Za-z0-9:._\-]+)')
    $clusterMatch = [regex]::Match($allText, 'BREAKGLASS_CLUSTER=([A-Za-z0-9._\-]+)')

    if (-not $wrapMatch.Success) {
        throw "BREAKGLASS_WRAP_TOKEN marker not found in task output. The playbook probably failed before wrapping."
    }
    $wrapToken   = $wrapMatch.Groups[1].Value.Trim()
    $contextName = if ($contextMatch.Success) { $contextMatch.Groups[1].Value.Trim() } else { "breakglass-$Cluster" }
    $expiresAt   = if ($expiresMatch.Success) { $expiresMatch.Groups[1].Value.Trim() } else { "unknown" }

    Write-Verbose "Wrap token: length=$($wrapToken.Length), prefix=$($wrapToken.Substring(0, [Math]::Min(10, $wrapToken.Length)))..."
    Write-Verbose "Vault addr: $VaultAddr"

    # Unwrap via Vault
    Write-Host "Unwrapping kubeconfig from Vault"
    try {
        $unwrapResp = Invoke-RestMethod -Uri "$VaultAddr/v1/sys/wrapping/unwrap" `
            -Method POST `
            -Headers @{ "X-Vault-Token" = $wrapToken } `
            -ContentType "application/json" `
            -Body "{}" `
            -ErrorAction Stop
    }
    catch {
        $errBody = ''
        try {
            if ($_.Exception.Response) {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $errBody = $reader.ReadToEnd()
                }
            }
            if (-not $errBody -and $_.ErrorDetails -and $_.ErrorDetails.Message) {
                $errBody = $_.ErrorDetails.Message
            }
        } catch { }
        throw @"
Failed to unwrap Vault token at $VaultAddr/v1/sys/wrapping/unwrap.
  Status:        $($_.Exception.Message)
  Vault body:    $errBody
  Token length:  $($wrapToken.Length) (expect 95)
  Token prefix:  $($wrapToken.Substring(0, [Math]::Min(10, $wrapToken.Length)))...
Hint: 400 with 'wrapping token is not valid or does not exist' = already consumed or expired (5min TTL).
"@
    }
    $kubeconfigYaml = $unwrapResp.data.kubeconfig
    if (-not $kubeconfigYaml) {
        throw "Unwrap returned no kubeconfig payload."
    }
    Write-Host "Retrieved kubeconfig (wrap token now invalidated)"

    # Remove any previous break-glass contexts for this cluster
    $existingContexts = @(kubectl config get-contexts -o name 2>$null)
    $previousContexts = $existingContexts | Where-Object { $_ -like "breakglass-$Cluster-*" -and $_ -ne $contextName }
    foreach ($ctx in $previousContexts) {
        Write-Host "Removing previous context: $ctx"
        kubectl config delete-context $ctx 2>&1 | Out-Null
        kubectl config delete-cluster $ctx 2>&1 | Out-Null
        kubectl config delete-user    $ctx 2>&1 | Out-Null
    }

    # Merge new kubeconfig into ~/.kube/config
    $kubeDir  = if ($IsLinux -or $IsMacOS) { Join-Path $env:HOME ".kube" } else { Join-Path $env:USERPROFILE ".kube" }
    $kubeFile = Join-Path $kubeDir "config"
    if (-not (Test-Path $kubeDir)) { New-Item -ItemType Directory -Force -Path $kubeDir | Out-Null }

    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tmpFile -Value $kubeconfigYaml -NoNewline -Encoding utf8

        if (-not (Test-Path $kubeFile)) {
            Copy-Item $tmpFile $kubeFile
        }
        else {
            $sep = if ($IsLinux -or $IsMacOS) { ':' } else { ';' }
            $previousKubeconfig = $env:KUBECONFIG
            try {
                $env:KUBECONFIG = "$kubeFile$sep$tmpFile"
                $merged = (kubectl config view --flatten --raw 2>$null) -join "`n"
            }
            finally {
                $env:KUBECONFIG = $previousKubeconfig
            }
            if (-not $merged) {
                throw "kubectl config view --flatten produced empty output. Bailing out — ~/.kube/config is unchanged."
            }
            Copy-Item $kubeFile "$kubeFile.bak.breakglass" -Force
            Set-Content -Path $kubeFile -Value $merged -NoNewline -Encoding utf8
        }

        if ($IsLinux -or $IsMacOS) {
            chmod 600 $kubeFile 2>$null
        }
    }
    finally {
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
    }

    if ($Json) {
        # Emit only non-sensitive fields — never the wrap token or the kubeconfig itself.
        Write-OctoJson -Command 'Request-BreakGlassKubeConfig' -Data ([ordered]@{
            cluster       = $Cluster
            context       = $contextName
            expiresAt     = $expiresAt
            durationHours = $DurationHours
            taskId        = $taskId
            kubeFile      = $kubeFile
        })
        return
    }

    Write-Host ""
    Write-Host "Break-glass kubeconfig active:"
    Write-Host "  Context : $contextName"
    Write-Host "  Cluster : $Cluster"
    Write-Host "  Expires : $expiresAt"
    Write-Host ""
    Write-Host "Use it:"
    Write-Host "  kubectl --context=$contextName get pods -A"
    Write-Host "  kubectl config use-context $contextName"
    Write-Host ""
    Write-Host "Audit posted to the shared Teams channel."
}

Export-ModuleMember -Function @('Request-BreakGlassKubeConfig')
