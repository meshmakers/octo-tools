function Invoke-OctoCliLoginProduction {
    param($tenantId = "meshtest", $includeReporting = $false)

    Write-Warning "Invoke-OctoCliLoginProduction is deprecated. Use 'Register-OctoCliContext -Installation prod-1 -TenantId $tenantId' (or -Installation prod-2) instead (add -IncludeReporting as needed)."

    $contextName = "production_$tenantId"

    if ($includeReporting) {
        Write-Host "Including reporting"
        octo-cli -c AddContext -n $contextName -asu "https://assets.meshmakers.cloud/" -isu "https://connect.meshmakers.cloud" -bsu "https://bots.meshmakers.cloud/" -csu "https://communication.meshmakers.cloud/" -rsu "https://reporting.meshmakers.cloud/" -tid $tenantId
    }
    else {
        Write-Host "Excluding reporting"
        octo-cli -c AddContext -n $contextName -asu "https://assets.meshmakers.cloud/" -isu "https://connect.meshmakers.cloud" -bsu "https://bots.meshmakers.cloud/" -csu "https://communication.meshmakers.cloud/" -tid $tenantId
    }

    octo-cli -c UseContext -n $contextName
    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginProduction')

