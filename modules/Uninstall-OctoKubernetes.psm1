function Uninstall-OctoKubernetes {
    param(
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [switch]$Force,
        # By default the OS-level trust of the local root CA (added by Install-OctoKubernetes
        # via Add-OctoLocalCaTrust) is removed on teardown, so no orphaned
        # 'OctoMesh Local Dev Root CA' is left trusted in the system store after the cluster
        # — whose private key it relied on — is gone. Pass -KeepCaTrust to leave it in place.
        [Parameter()] [switch]$KeepCaTrust
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

    # Reverse the OS-level CA trust that Install-OctoKubernetes added. The CA's private key
    # died with the cluster, but its public cert lingers as a trusted root in the system
    # store until removed. Non-fatal + guarded so a missing cmdlet or a declined sudo prompt
    # doesn't fail the teardown. Prompts for sudo on macOS/Linux.
    if (-not $KeepCaTrust -and (Get-Command Remove-OctoLocalCaTrust -ErrorAction SilentlyContinue)) {
        try {
            Remove-OctoLocalCaTrust
        }
        catch {
            Write-Warning "Could not remove local CA trust: $($_.Exception.Message). Remove it manually with 'Remove-OctoLocalCaTrust'."
        }
    }
}

Export-ModuleMember -Function @('Uninstall-OctoKubernetes')
