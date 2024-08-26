function Remove-KubeConfig {
    param(
        [string]$name
    )
    
    if ([string]::IsNullOrEmpty($name)) {
        Write-Error "Name is required"
        return;
    }
    if (!(Test-Path ~/.kube/config)) {
        Write-Error "File ~/.kube/config does not exist"
        return;
    }
    
    # make a backup
    Push-Location ~/.kube/
    cp config config.bak

    kubectl config delete-context $name
    kubectl config delete-cluster $name
    kubectl config delete-user $name

    kubectl config view
    
    Read-Host -Prompt "Press Enter to continue and to apply changes..."
    
    rm config.bak
    
    Pop-Location
}


Export-ModuleMember -Function @('Remove-KubeConfig')