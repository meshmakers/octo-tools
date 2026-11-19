#Requires -Modules Pester
<#
    Pester tests for the tenant-database prefix handling of Start-Octo (AB#8797): no service is started, only
    the module's environment helper and the parameter block are exercised.

    Run:  Invoke-Pester ./tests/StartOctoTenantDatabasePrefix.Tests.ps1
#>

BeforeAll {
    $script:ModulePath = Join-Path $PSScriptRoot '../modules/Start-Octo.psm1'
    $script:Variable = 'OCTO_SYSTEM__TENANTDATABASEPREFIX'
    $script:Saved = [Environment]::GetEnvironmentVariable($script:Variable)
}

AfterAll {
    [Environment]::SetEnvironmentVariable($script:Variable, $script:Saved)
}

Describe 'Set-OctoTenantDatabasePrefixEnvironment' {
    BeforeEach {
        # A fresh module per test resets the "set by Start-Octo" flag.
        Import-Module $script:ModulePath -Force
        [Environment]::SetEnvironmentVariable($script:Variable, $null)
    }

    It 'sets a given prefix' {
        InModuleScope Start-Octo { Set-OctoTenantDatabasePrefixEnvironment -TenantDatabasePrefix 's2_' }
        $env:OCTO_SYSTEM__TENANTDATABASEPREFIX | Should -Be 's2_'
    }

    It 'keeps a value from the caller''s environment when no prefix is given' {
        $env:OCTO_SYSTEM__TENANTDATABASEPREFIX = 'slot_'
        InModuleScope Start-Octo { Set-OctoTenantDatabasePrefixEnvironment -TenantDatabasePrefix '' }
        $env:OCTO_SYSTEM__TENANTDATABASEPREFIX | Should -Be 'slot_'
    }

    It 'removes the prefix an earlier call set when a later call gives none' {
        InModuleScope Start-Octo {
            Set-OctoTenantDatabasePrefixEnvironment -TenantDatabasePrefix 's2_'
            Set-OctoTenantDatabasePrefixEnvironment -TenantDatabasePrefix ''
        }
        $env:OCTO_SYSTEM__TENANTDATABASEPREFIX | Should -BeNullOrEmpty
    }
}

Describe 'Wait-OctoServicePort (the start order of octo-devstack''s startAfter)' {
    BeforeAll {
        Import-Module $script:ModulePath -Force
        # A port that refuses connections and that no other socket can take meanwhile: bound, never listening.
        $script:Closed = [System.Net.Sockets.Socket]::new([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)
        $script:Closed.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Loopback, 0))
        $script:ClosedPort = $script:Closed.LocalEndPoint.Port
    }
    AfterAll { $script:Closed.Dispose() }

    It 'returns as soon as the service accepts connections' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = $listener.LocalEndpoint.Port
            InModuleScope Start-Octo -Parameters @{ port = $port } { param($port) Wait-OctoServicePort -Port $port -Name 'Identity' -IsRunning { $true } -IntervalMilliseconds 10 6>$null } | Should -BeTrue
        }
        finally { $listener.Stop() }
    }

    It 'stops waiting with a warning when the service''s job ended' {
        $result = InModuleScope Start-Octo -Parameters @{ port = $script:ClosedPort } { param($port) Wait-OctoServicePort -Port $port -Name 'Identity' -IsRunning { $false } -IntervalMilliseconds 10 -WarningVariable w -WarningAction SilentlyContinue 6>$null; $w }
        $result[0] | Should -BeFalse
        "$($result[1])" | Should -BeLike "Identity ended before it opened port $($script:ClosedPort)*starting the next services anyway*"
    }

    It 'stops waiting with a warning after the timeout' {
        $result = InModuleScope Start-Octo -Parameters @{ port = $script:ClosedPort } { param($port) Wait-OctoServicePort -Port $port -Name 'AssetRepository' -IsRunning { $true } -TimeoutSeconds 0 -IntervalMilliseconds 10 -WarningVariable w -WarningAction SilentlyContinue 6>$null; $w }
        $result[0] | Should -BeFalse
        "$($result[1])" | Should -BeLike "AssetRepository did not open port $($script:ClosedPort) within 0 s*"
    }
}

Describe 'Start-Octo parameters' {
    BeforeAll {
        Import-Module $script:ModulePath -Force
    }

    It 'declares TenantDatabasePrefix last, so the positional binding of the other parameters is unchanged' {
        $names = @((Get-Command Start-Octo).Parameters.Values |
            Where-Object { $_.Name -notin [System.Management.Automation.PSCmdlet]::CommonParameters -and
                $_.Name -notin [System.Management.Automation.PSCmdlet]::OptionalCommonParameters } |
            ForEach-Object Name)
        $names[-1] | Should -Be 'TenantDatabasePrefix'
        $names.IndexOf('botService') | Should -Be 3
    }
}
