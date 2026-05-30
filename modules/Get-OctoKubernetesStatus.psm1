function Test-HostPortOpen([string]$hostName, [int]$port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hostName, $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(800)
        $client.Close()
        return $ok
    } catch { return $false }
}

function Get-OctoKubernetesStatus {
    param(
        [Parameter()] [string]$ClusterName = "kind"
    )
    $ctx = "kind-$ClusterName"

    if (-not ((& kind get clusters 2>$null) -split "`n" | Where-Object { $_ -eq $ClusterName })) {
        Write-Host "kind cluster '$ClusterName' does not exist." -ForegroundColor Yellow
        return
    }

    Write-Host "== Pods ==" -ForegroundColor Cyan
    foreach ($ns in @("octo-infra", "octo-operator-system", "octo")) {
        Write-Host "-- $ns --" -ForegroundColor DarkCyan
        & kubectl --context $ctx -n $ns get pods
    }

    Write-Host "== Helm releases ==" -ForegroundColor Cyan
    & helm --kube-context $ctx list -A

    Write-Host "== Host port reachability ==" -ForegroundColor Cyan
    foreach ($p in @(@{n="mongodb";port=27017}, @{n="rabbitmq-amqp";port=5672}, @{n="rabbitmq-mgmt";port=15672}, @{n="cratedb-psql";port=5432}, @{n="cratedb-http";port=4301})) {
        $state = if (Test-HostPortOpen "localhost" $p.port) { "OPEN" } else { "closed" }
        Write-Host ("  {0,-16} localhost:{1,-6} {2}" -f $p.n, $p.port, $state)
    }
}

Export-ModuleMember -Function @('Get-OctoKubernetesStatus')
