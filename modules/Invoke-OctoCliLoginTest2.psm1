function Invoke-OctoCliLoginTest2 {
    param($tenantId = "meshtest", $includeReporting = $false)

    if ($includeReporting) {
        Write-Host "Including reporting"
        octo-cli -c Config -asu "https://assets.test-2.mm.cloud/" -isu "https://connect.test-2.mm.cloud/" -bsu "https://bots.test-2.mm.cloud/" -csu "https://communication.test-2.mm.cloud/" -rsu "https://reporting.test-2.mm.cloud/" -tid $tenantId
    }
    else {
        Write-Host "Excluding reporting"
        octo-cli -c Config -asu "https://assets.test-2.mm.cloud/" -isu "https://connect.test-2.mm.cloud/" -bsu "https://bots.test-2.mm.cloud/" -csu "https://communication.test-2.mm.cloud/" -tid $tenantId
    }

    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginTest2')

