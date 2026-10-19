#Requires -Modules Pester
<#
    Pester tests for Register-OctoCliContext, single and multi-tenant (AB#6840).
    octo-cli and the installations config are mocked; nothing is registered for real.

    Run:  Invoke-Pester ./tests/RegisterOctoCliContext.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    # Stubs the module under test resolves through the global scope.
    function global:octo-cli { $global:LASTEXITCODE = 0 }
    function global:Get-OctoInstallation {
        param($Name)
        [pscustomobject]@{ services = [pscustomobject]@{
                assets = 'https://assets{0}.example.test/'; identity = 'https://id{0}.example.test/'
                bots = 'https://bots{0}.example.test/'; communication = 'https://comm{0}.example.test/'
                reporting = 'https://rep{0}.example.test/'; ai = 'https://ai{0}.example.test/' } }
    }
    Import-Module (Join-Path $modules 'Register-OctoCliContext.psm1') -Force

    function script:Install-CliMock {
        param([scriptblock]$Behavior = { $global:LASTEXITCODE = 0 })
        $script:Cli = [System.Collections.Generic.List[object]]::new()
        $script:Behavior = $Behavior
        Mock -ModuleName Register-OctoCliContext octo-cli {
            $script:Cli.Add(@($args))
            & $script:Behavior @($args)
        }
    }
}

AfterAll {
    Remove-Item function:global:octo-cli, function:global:Get-OctoInstallation -ErrorAction SilentlyContinue
}

Describe 'single tenant (unchanged behaviour)' {
    It 'adds the context, switches to it and logs in' {
        Install-CliMock
        Register-OctoCliContext -Installation inst -TenantId meshtest 6>$null | Out-Null
        $script:Cli.Count | Should -Be 3
        $script:Cli[0] | Should -Be '-c', 'AddContext', '-n', 'inst_meshtest', '-asu', 'https://assets.example.test/', '-isu', 'https://id.example.test/', '-bsu', 'https://bots.example.test/', '-csu', 'https://comm.example.test/', '-tid', 'meshtest'
        $script:Cli[1] | Should -Be '-c', 'UseContext', '-n', 'inst_meshtest'
        $script:Cli[2] | Should -Be '--context', 'inst_meshtest', '-c', 'Login', '-i'
    }
    It '-NoSwitch -NoLogin only adds the context' {
        Install-CliMock
        Register-OctoCliContext -Installation inst -TenantId meshtest -NoSwitch -NoLogin 6>$null | Out-Null
        $script:Cli.Count | Should -Be 1
    }
    It '-UriSuffix is part of the context name and the URIs' {
        Install-CliMock
        Register-OctoCliContext -Installation inst -TenantId t -UriSuffix pr1 -NoSwitch -NoLogin 6>$null | Out-Null
        $script:Cli[0] | Should -Contain 'inst_pr1_t'
        $script:Cli[0] | Should -Contain 'https://assets-pr1.example.test/'
    }
    It 'throws when AddContext fails' {
        Install-CliMock { $global:LASTEXITCODE = 3 }
        { Register-OctoCliContext -Installation inst -TenantId t -NoLogin 6>$null | Out-Null } | Should -Throw '*AddContext failed*'
    }
    It '-Json keeps the single action result' {
        Install-CliMock
        $doc = Register-OctoCliContext -Installation inst -TenantId t -NoLogin -Json | ConvertFrom-Json
        $doc.command | Should -Be 'Register-OctoCliContext'
        $doc.data.success | Should -BeTrue
        $doc.data.PSObject.Properties.Name | Should -Not -Contain 'contexts'
    }
}

Describe 'several tenants in one call' {
    It 'registers one context per tenant and never switches the active context' {
        Install-CliMock
        Register-OctoCliContext -Installation inst -TenantId a, b, c -NoLogin 6>$null | Out-Null
        $adds = @($script:Cli | Where-Object { $_ -contains 'AddContext' })
        $adds.Count | Should -Be 3
        ($adds | ForEach-Object { $_[3] }) | Should -Be 'inst_a', 'inst_b', 'inst_c'
        ($script:Cli | ForEach-Object { $_ }) | Should -Not -Contain 'UseContext'
    }
    It 'logs into each new context by name, not into whichever context is active' {
        Install-CliMock
        Register-OctoCliContext -Installation inst -TenantId a, b 6>$null | Out-Null
        $logins = @($script:Cli | Where-Object { $_ -contains 'Login' })
        $logins.Count | Should -Be 2
        $logins[0] | Should -Be '--context', 'inst_a', '-c', 'Login', '-i'
        $logins[1] | Should -Be '--context', 'inst_b', '-c', 'Login', '-i'
    }
    It 'removes duplicates and keeps going after a failing tenant, then reports it' {
        Install-CliMock { if ($args[0] -contains 'inst_b') { $global:LASTEXITCODE = 2 } else { $global:LASTEXITCODE = 0 } }
        { Register-OctoCliContext -Installation inst -TenantId a, b, c, a -NoLogin 6>$null | Out-Null } | Should -Throw '*1 of 3 tenants*b:*'
        @($script:Cli | Where-Object { $_ -contains 'AddContext' }).Count | Should -Be 3
    }
    It '-Json lists every tenant with its result' {
        Install-CliMock { if ($args[0] -contains 'inst_b') { $global:LASTEXITCODE = 2 } else { $global:LASTEXITCODE = 0 } }
        $doc = Register-OctoCliContext -Installation inst -TenantId a, b, c -NoLogin -Json | ConvertFrom-Json
        $doc.data.success | Should -BeFalse
        $doc.data.contexts.context | Should -Be 'inst_a', 'inst_b', 'inst_c'
        $doc.data.contexts.success | Should -Be $true, $false, $true
    }
}
