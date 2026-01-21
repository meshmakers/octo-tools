function Invoke-CleanupInfraContainerDisks {
    <#
    .SYNOPSIS
        Checks disk usage on CI agents, CD agents, and registry pods in Kubernetes.
    .DESCRIPTION
        Connects to the 'infra' Kubernetes context and checks disk usage across:
        - CI agent pods (/tmp, /azp/_work)
        - CD agent pods (/tmp, /azp/_work)
        - Registry pods (docker, npm, nuget with their respective mounts)
        Highlights pods with usage >= 80% in red and provides cleanup commands where applicable.
    .EXAMPLE
        Invoke-CleanupInfraContainerDisks
    #>

    # Collection for pods that need cleanup
    $cleanupCandidates = @()

    # Check current k8s context is 'infra'
    $currentContext = kubectl config current-context 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to get current Kubernetes context. Is kubectl configured?"
        return
    }

    if ($currentContext -ne 'infra') {
        Write-Error "Not on 'infra' context. Current context: $currentContext"
        Write-Host "Switch with: kubectl config use-context infra" -ForegroundColor Yellow
        return
    }

    # Define namespace configurations
    $namespaceConfigs = @(
        @{
            Namespace   = 'azure-devops-ci'
            Label       = 'CI Agents'
            Mounts      = @('/tmp', '/azp/_work')
            CleanupPath = '/azp/_work/*'
        },
        @{
            Namespace   = 'azure-devops-cd'
            Label       = 'CD Agents'
            Mounts      = @('/tmp', '/azp/_work')
            CleanupPath = '/azp/_work/*'
        },
        @{
            Namespace   = 'registries'
            Label       = 'Registries'
            Mounts      = $null  # Dynamic based on pod type
            CleanupPath = $null  # No cleanup for registries
        }
    )

    foreach ($config in $namespaceConfigs) {
        $namespace = $config.Namespace
        $label = $config.Label

        # Get all pods in namespace
        $podOutput = kubectl get pods -n $namespace -o jsonpath='{.items[*].metadata.name}' 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to get pods from $namespace namespace"
            continue
        }

        if ([string]::IsNullOrWhiteSpace($podOutput)) {
            Write-Host "`n$label ($namespace): No pods found" -ForegroundColor Yellow
            continue
        }

        $pods = $podOutput -split ' ' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        Write-Host "`n$label ($namespace):" -ForegroundColor Cyan
        Write-Host ("=" * 60)

        foreach ($pod in $pods) {
            # Determine mounts based on namespace and pod name
            $mounts = $config.Mounts
            $cleanupPath = $config.CleanupPath

            # For registries namespace, determine mounts based on pod name
            if ($namespace -eq 'registries') {
                if ($pod -match 'docker') {
                    $mounts = @('/data', '/var/lib/registry')
                }
                elseif ($pod -match 'npm') {
                    $mounts = @('/verdaccio/storage')
                }
                elseif ($pod -match 'nuget') {
                    $mounts = @('/var/baget')
                }
                else {
                    Write-Host "$pod : Unknown registry type, skipping" -ForegroundColor Gray
                    continue
                }
            }

            Write-Host "`n  $pod" -ForegroundColor White

            foreach ($mount in $mounts) {
                # Get df -h output for this mount
                $dfOutput = kubectl exec -n $namespace $pod -- df -h $mount 2>$null

                if ($LASTEXITCODE -ne 0) {
                    Write-Host "    $mount : Unable to check disk usage" -ForegroundColor Gray
                    continue
                }

                # Parse the output to extract usage percentage
                # Format: Filesystem Size Used Avail Use% Mounted
                $lines = $dfOutput -split "`n"
                if ($lines.Count -ge 2) {
                    $dataLine = $lines[1]
                    # Extract percentage (e.g., "75%")
                    if ($dataLine -match '(\d+)%') {
                        $usagePercent = [int]$Matches[1]

                        # Also extract size info
                        $parts = $dataLine -split '\s+' | Where-Object { $_ -ne '' }
                        $size = if ($parts.Count -ge 2) { $parts[1] } else { "?" }
                        $used = if ($parts.Count -ge 3) { $parts[2] } else { "?" }
                        $avail = if ($parts.Count -ge 4) { $parts[3] } else { "?" }

                        # Display results with color coding
                        if ($usagePercent -ge 80) {
                            Write-Host "    $mount : ${usagePercent}% used ($used / $size, $avail available)" -ForegroundColor Red
                            # Collect cleanup candidate for CI/CD agents on /azp/_work
                            if ($cleanupPath -and $mount -eq '/azp/_work') {
                                $cleanupCandidates += [PSCustomObject]@{
                                    Index     = $cleanupCandidates.Count + 1
                                    Namespace = $namespace
                                    Pod       = $pod
                                    Mount     = $mount
                                    Usage     = "${usagePercent}%"
                                    Used      = $used
                                    Size      = $size
                                    Command   = "kubectl exec -n $namespace $pod -- sh -c 'rm -rf $cleanupPath'"
                                }
                            }
                        }
                        else {
                            Write-Host "    $mount : ${usagePercent}% used ($used / $size, $avail available)" -ForegroundColor Green
                        }
                    }
                    else {
                        Write-Host "    $mount : Unable to parse disk usage" -ForegroundColor Gray
                    }
                }
                else {
                    Write-Host "    $mount : Unexpected df output format" -ForegroundColor Gray
                }
            }
        }

        Write-Host ("-" * 60)
    }

    # Interactive cleanup selection
    if ($cleanupCandidates.Count -gt 0) {
        Write-Host "`nPods requiring cleanup:" -ForegroundColor Yellow
        $cleanupCandidates | ForEach-Object {
            Write-Host "  [$($_.Index)] $($_.Pod) - $($_.Usage) ($($_.Used)/$($_.Size))"
        }

        $selection = Read-Host "`nSelect pods to clean (e.g., 1,3,5 or 'all' or 'none')"

        if ($selection -eq 'none' -or [string]::IsNullOrWhiteSpace($selection)) {
            Write-Host "No cleanup performed." -ForegroundColor Gray
            return
        }

        $selectedIndices = if ($selection -eq 'all') {
            1..$cleanupCandidates.Count
        } else {
            $selection -split ',' | ForEach-Object { [int]$_.Trim() }
        }

        foreach ($idx in $selectedIndices) {
            $candidate = $cleanupCandidates | Where-Object { $_.Index -eq $idx }
            if ($candidate) {
                Write-Host "Cleaning $($candidate.Pod)..." -ForegroundColor Cyan
                Invoke-Expression $candidate.Command
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "  Done" -ForegroundColor Green
                } else {
                    Write-Host "  Failed" -ForegroundColor Red
                }
            }
        }
    } else {
        Write-Host "`nNo pods require cleanup." -ForegroundColor Green
    }
}

Export-ModuleMember -Function @('Invoke-CleanupInfraContainerDisks')
