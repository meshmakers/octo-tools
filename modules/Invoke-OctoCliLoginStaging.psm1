function Invoke-OctoCliLoginStaging {
    param($tenantId = "meshtest", $includeReporting = $false)

    if ($includeReporting) {
        Write-Host "Including reporting"
        octo-cli -c Config -asu "https://assets.staging.meshmakers.cloud/" -isu "https://connect.staging.meshmakers.cloud" -bsu "https://bots.staging.meshmakers.cloud/" -csu "https://communication.staging.meshmakers.cloud/" -rsu "https://reporting.staging.meshmakers.cloud/"  -tid $tenantId
    }
    else {
        Write-Host "Excluding reporting"
        octo-cli -c Config -asu "https://assets.staging.meshmakers.cloud/" -isu "https://connect.staging.meshmakers.cloud" -bsu "https://bots.staging.meshmakers.cloud/" -csu "https://communication.staging.meshmakers.cloud/" -tid $tenantId
    }

    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginStaging')

