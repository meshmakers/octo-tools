function Invoke-OctoCliLoginLocal
{
    param($tenantId = "meshtest")

    octo-cli -c Config -asu "https://localhost:5001/" -isu "https://localhost:5003/" -bsu "https://localhost:5009/" -tid $tenantId
    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginLocal')

