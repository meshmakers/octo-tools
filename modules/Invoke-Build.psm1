function Invoke-Build
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($repositoryPath = ".\")
    
    dotnet publish $repositoryPath -f "net8.0"
}


Export-ModuleMember -Function @('Invoke-Build')