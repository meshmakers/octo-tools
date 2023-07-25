function Invoke-BuildAndStartOcto
{
    Invoke-BuildAll
    Invoke-StartOcto
}

Export-ModuleMember -Function @('Invoke-BuildAndStartOcto')