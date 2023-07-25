function Invoke-BuildAndStartOcto
{
    Invoke-BuildAll
    Start-Octo
}

Export-ModuleMember -Function @('Invoke-BuildAndStartOcto')