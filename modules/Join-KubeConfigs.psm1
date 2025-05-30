function Join-KubeConfigs {
    param(
        [string]$externalKubeConfig
    )
    
    if (!(Test-Path $externalKubeConfig)) {
        Write-Error "File $externalKubeConfig does not exist"
        return;
    }

    if (!(Test-Path ~/.kube/config)) {
        Write-Error "File ~/.kube/config does not exist"
        return;
    }
    
    # make a backup
    Push-Location ~/.kube/
    cp config config.bak

    $configFullPath = Resolve-Path "~/.kube/config"
    $additionalConfigFullPath = Resolve-Path $externalKubeConfig
    
    # merge both kube config files
    if ($IsLinux -or $IsMacOS) {
        $ENV:KUBECONFIG = "$configFullPath`:$additionalConfigFullPath"
    }
    else {
        $ENV:KUBECONFIG = "$configFullPath;$additionalConfigFullPath"
    }
    
    # output to temp file
    kubectl config view --flatten > config-merged
    
    # verify that config-merged is correct
    Write-Host "Merged config:"
    kubectl --kubeconfig=config-merged config get-clusters
    
    Read-Host -Prompt "Press Enter to continue and to apply changes..."
    
    # delete backup
    rm config
    # move merged file to config
    mv config-merged config
    # remove (optional)
    rm config.bak

    Pop-Location
}


Export-ModuleMember -Function @('Join-KubeConfigs')