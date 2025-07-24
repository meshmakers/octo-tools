function Invoke-OctoCliLoginTest2 {
    param($tenantId = "meshtest", $uriSuffix = "", $includeReporting = $false)

    $uriExtension = if ($uriSuffix) { "-$uriSuffix" } else { "" }

    if ($includeReporting) {
        Write-Host "Including reporting"
        octo-cli -c Config -asu "https://assets$uriExtension.test-2.mm.cloud/" -isu "https://connect$uriExtension.test-2.mm.cloud/" -bsu "https://bots$uriExtension.test-2.mm.cloud/" -csu "https://communication$uriExtension.test-2.mm.cloud/" -rsu "https://reporting$uriExtension.test-2.mm.cloud/" -tid $tenantId
    }
    else {
        Write-Host "Excluding reporting"
        octo-cli -c Config -asu "https://assets$uriExtension.test-2.mm.cloud/" -isu "https://connect$uriExtension.test-2.mm.cloud/" -bsu "https://bots$uriExtension.test-2.mm.cloud/" -csu "https://communication$uriExtension.test-2.mm.cloud/" -tid $tenantId
    }

    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginTest2')

