function Invoke-BuildAndStartOcto
{
    param(
        [string]$configuration = "Release"
    )
    
    Invoke-BuildAll -configuration $configuration
    Start-Octo -configuration $configuration
}

Export-ModuleMember -Function @('Invoke-BuildAndStartOcto')