function Import-OctoImageToKind {
    <#
.SYNOPSIS
Loads a locally-present Docker image into a kind cluster's node so pods can use
it with imagePullPolicy: IfNotPresent (no registry required).

.PARAMETER Image
Full image reference, e.g. "meshmakers/octo-communication-operator:dev".

.PARAMETER ClusterName
kind cluster name. Defaults to "kind".
#>
    param(
        [Parameter(Mandatory)] [string]$Image,
        [Parameter()] [string]$ClusterName = "kind"
    )
    if (-not (docker image inspect $Image 2>$null)) {
        Write-Error "Image '$Image' not found in the local Docker daemon. Build or pull it first."
        return
    }
    Write-Host "Loading $Image into kind cluster '$ClusterName'" -ForegroundColor Green
    $kindOutput = & kind load docker-image $Image --name $ClusterName 2>&1
    $kindOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        # Docker 23+ with the containerd image store exports a multi-platform OCI
        # index that kind's "ctr import --all-platforms" cannot fully resolve,
        # leaving an incomplete image on the node. Fall back to a single-platform
        # "docker save" piped straight into the node's containerd (no
        # --all-platforms), which only imports the blobs actually present.
        Write-Host "kind load failed; falling back to single-platform docker save | ctr import" -ForegroundColor Yellow
        $controlPlane = "$ClusterName-control-plane"
        & docker save $Image | & docker exec -i $controlPlane ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs -
        if ($LASTEXITCODE -ne 0) { Write-Error "Fallback ctr import failed with exit code $LASTEXITCODE"; return }
    }
    Write-Host "Loaded $Image" -ForegroundColor Cyan
}

Export-ModuleMember -Function @('Import-OctoImageToKind')
