function Invoke-OctoCliLoginLocal1 {
    param($tenantId = "meshtest", $includeReporting = $false)

    if ($includeReporting) {
        Write-Host "Including reporting"
        octo-cli -c Config -asu "https://assets.local-1.srv.mm.local/" -isu "https://connect.local-1.srv.mm.local/" -bsu "https://bots.local-1.srv.mm.local/" -csu "https://communication.local-1.srv.mm.local/" -rsu "https://reporting.local-1.srv.mm.local/" -tid $tenantId
    }
    else {
        Write-Host "Excluding reporting"
        octo-cli -c Config -asu "https://assets.local-1.srv.mm.local/" -isu "https://connect.local-1.srv.mm.local/" -bsu "https://bots.local-1.srv.mm.local/" -csu "https://communication.local-1.srv.mm.local/" -tid $tenantId
    }

    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginLocal1')

