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
