function Invoke-BuildAndStartOcto
{
    Invoke-BuildOcto
    Invoke-StartOcto
}

Export-ModuleMember -Function @('Invoke-BuildAndStartOct')