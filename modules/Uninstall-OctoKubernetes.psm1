function Uninstall-OctoKubernetes {
    param(
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [switch]$Force
    )
    if (-not ((& kind get clusters 2>$null) -split "`n" | Where-Object { $_ -eq $ClusterName })) {
        Write-Host "kind cluster '$ClusterName' does not exist." -ForegroundColor Yellow
        return
    }
    if (-not $Force) {
        Write-Warning "This deletes the kind cluster '$ClusterName' and ALL its data (Mongo + CrateDB PVCs are destroyed)."
        $ans = Read-Host "Type 'yes' to continue"
        if ($ans -ne "yes") { Write-Host "Aborted." -ForegroundColor Yellow; return }
    }
    & kind delete cluster --name $ClusterName
    if ($LASTEXITCODE -ne 0) { Write-Error "kind delete cluster failed with exit code $LASTEXITCODE"; return }
    Write-Host "Cluster '$ClusterName' deleted." -ForegroundColor Green
}

Export-ModuleMember -Function @('Uninstall-OctoKubernetes')
