function Invoke-OctoCliLoginLocal {
    param($tenantId = "meshtest", $includeReporting = $false, $includeAi = $false)

    $contextName = "local_$tenantId"

    $addArgs = @(
        '-c', 'AddContext',
        '-n', $contextName,
        '-asu', "https://localhost:5001/",
        '-isu', "https://localhost:5003/",
        '-bsu', "https://localhost:5009/",
        '-csu', "https://localhost:5015/",
        '-tid', $tenantId
    )

    if ($includeReporting) {
        Write-Host "Including reporting"
        $addArgs += @('-rsu', "https://localhost:5007/")
    }
    else {
        Write-Host "Excluding reporting"
    }

    if ($includeAi) {
        Write-Host "Including AI"
        $addArgs += @('-aisu', "https://localhost:5019/")
    }
    else {
        Write-Host "Excluding AI"
    }

    octo-cli @addArgs

    octo-cli -c UseContext -n $contextName
    octo-cli -c Login -i
}

Export-ModuleMember -Function @('Invoke-OctoCliLoginLocal')
