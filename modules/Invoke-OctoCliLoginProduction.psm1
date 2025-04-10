function Invoke-OctoCliLoginLocal {
    param($tenantId = "meshtest", $includeReporting = $false)

    if ($includeReporting) {
        Write-Host "Including reporting"
        octo-cli -c Config -asu "https://assets.meshmakers.cloud/" -isu "https://connect.meshmakers.cloud" -bsu "https://bots.meshmakers.cloud/" -csu "https://communication.meshmakers.cloud/" -rsu "https://reporting.meshmakers.cloud/"  -tid $tenantId
    }
    else {
        Write-Host "Excluding reporting"
        octo-cli -c Config -asu "https://assets.meshmakers.cloud/" -isu "https://connect.meshmakers.cloud" -bsu "https://bots.meshmakers.cloud/" -csu "https://communication.meshmakers.cloud/" -tid $tenantId
    }

    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginLocal')

