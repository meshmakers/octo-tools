function Invoke-Build
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param($repositoryPath = ".\")
    
    dotnet build $repositoryPath -c Release
}


Export-ModuleMember -Function @('Invoke-Build')