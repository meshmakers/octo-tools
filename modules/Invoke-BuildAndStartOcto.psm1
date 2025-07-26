function Invoke-BuildAndStartOcto
{
    param(
        [string]$configuration = "Release",
        [string]$SystemDatabase = "OctoSystem"
    )
    
    Invoke-BuildAll -configuration $configuration
    Start-Octo -configuration $configuration -SystemDatabase $SystemDatabase
}

Export-ModuleMember -Function @('Invoke-BuildAndStartOcto')