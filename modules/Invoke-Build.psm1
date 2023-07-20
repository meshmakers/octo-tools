function Invoke-Build
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($repositoryPath = ".\")
    
    dotnet publish $repositoryPath -f "net7.0"
}


Export-ModuleMember -Function @('Invoke-Build')