#Requires -Modules Pester
<#
    Pester tests for Invoke-OctoTenantSweep (AB#6840).

    octo-cli is never started: the single process wrapper (Invoke-OctoCliCapture) is mocked, except in the
    one test that puts a fake `octo-cli` script on the PATH to cover the real wrapper. The JWT-shaped
    CANARY below stands in for a token: it must never appear in any output, return value or file.

    Run:  Invoke-Pester ./tests/OctoTenantSweep.Tests.ps1
#>

BeforeAll {
    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-OctoTenantSweep.psm1') -Force

    $script:Canary = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJjYW5hcnktc3ViamVjdCJ9.c2lnbmF0dXJlLWNhbmFyeQ'

    function script:Set-CliMock {
        param([scriptblock]$PerTenant, [string]$Version = '3.5.27')
        $script:PerTenant = $PerTenant
        $script:Version = $Version
        $script:Calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Invoke-OctoTenantSweep Invoke-OctoCliCapture {
            $script:Calls.Add(@($Arguments))
            if ($Arguments -contains '--help') {
                return [pscustomobject]@{ ExitCode = 0; Output = "Octo Mesh Management Tool, Version $($script:Version).0`nDevelopment version" }
            }
            & $script:PerTenant $Arguments
        }
    }
    function script:Ok { [pscustomobject]@{ ExitCode = 0; Output = 'done' } }
}

Describe 'octo-cli version check' {
    It 'stops with a clear message when octo-cli is older than 3.5.27' {
        Set-CliMock -Version '3.5.26' -PerTenant { Ok }
        { Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '-c', 'LibraryStatus' } | Should -Throw '*3.5.26 is too old*3.5.27*'
        $script:Calls.Count | Should -Be 1   # only the version probe
    }
    It 'accepts 3.5.27 and newer, including the 999 dev build' {
        foreach ($v in '3.5.27', '3.6.0', '999.0.0') {
            Set-CliMock -Version $v -PerTenant { Ok }
            { Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '-c', 'LibraryStatus' } | Should -Not -Throw
        }
    }
    It 'stops when the version cannot be determined' {
        Mock -ModuleName Invoke-OctoTenantSweep Invoke-OctoCliCapture { [pscustomobject]@{ ExitCode = 1; Output = 'command not found' } }
        { Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '-c', 'X' } | Should -Throw '*Cannot determine the octo-cli version*'
    }
}

Describe 'dry run' {
    It '-WhatIf lists every tenant with its call and runs nothing' {
        Set-CliMock -PerTenant { throw 'must not run' }
        $rows = Invoke-OctoTenantSweep -Installation t2 -Tenant a, b -CliArguments '-c', 'LibraryStatus', '-io' -WhatIf
        $rows.Tenant | Should -Be 'a', 'b'
        $rows.Outcome | Should -Be 'Planned', 'Planned'
        $rows.Context | Should -Be 't2_a', 't2_b'
        @($script:Calls | Where-Object { $_ -notcontains '--help' }).Count | Should -Be 0
    }
}

Describe 'sweep' {
    It 'processes each tenant through its own context and never switches the active context' {
        Set-CliMock -PerTenant { Ok }
        $null = Invoke-OctoTenantSweep -Installation t2 -UriSuffix pr1 -Tenant a, b -CliArguments '-c', 'LibraryStatus'
        $real = @($script:Calls | Where-Object { $_ -notcontains '--help' })
        $real.Count | Should -Be 2
        $real[0] | Should -Be '--context', 't2_pr1_a', '-c', 'LibraryStatus'
        $real[1] | Should -Be '--context', 't2_pr1_b', '-c', 'LibraryStatus'
        ($script:Calls | ForEach-Object { $_ }) | Should -Not -Contain 'UseContext'
    }

    It 'substitutes {tenant} in the arguments of a fixed context' {
        Set-CliMock -PerTenant { Ok }
        $null = Invoke-OctoTenantSweep -Context root -Tenant A -CliArguments '-c', 'ProvisionCurrentUser', '-ttid', '{tenant}'
        $real = @($script:Calls | Where-Object { $_ -notcontains '--help' })
        $real[0] | Should -Be '--context', 'root', '-c', 'ProvisionCurrentUser', '-ttid', 'a'
    }

    It 'a denied tenant is reported with its cause and the sweep continues' {
        Set-CliMock -PerTenant {
            param($a)
            if ($a -contains 't2_b') {
                [pscustomobject]@{ ExitCode = -4; Output = "info line`nAccess to tenant 'b' denied: not provisioned. Run ProvisionCurrentUser -ttid b" }
            } else { Ok }
        }
        $rows = Invoke-OctoTenantSweep -Installation t2 -Tenant a, b, c -CliArguments '-c', 'LibraryStatus'
        $rows.Outcome | Should -Be 'Ok', 'Denied', 'Ok'
        $rows[1].Cause | Should -BeLike '*ProvisionCurrentUser -ttid b*'
        $rows[1].ExitCode | Should -Be -4
        @($script:Calls | Where-Object { $_ -notcontains '--help' }).Count | Should -Be 3
    }

    It 'another failure is Failed, not Denied, and does not stop the sweep' {
        Set-CliMock -PerTenant {
            param($a)
            if ($a -contains 't2_a') { [pscustomobject]@{ ExitCode = -5; Output = 'Unknown context t2_a' } } else { Ok }
        }
        $rows = Invoke-OctoTenantSweep -Installation t2 -Tenant a, b -CliArguments '-c', 'X'
        $rows.Outcome | Should -Be 'Failed', 'Ok'
        $rows[0].Cause | Should -Be 'Unknown context t2_a'
    }

    It 'takes the tenant list from GetTenants --all and honours -Exclude' {
        Set-CliMock -PerTenant {
            param($a)
            if ($a -contains 'GetTenants') {
                [pscustomobject]@{ ExitCode = 0; Output = "Using tenant: octosystem`n[ { `"TenantId`": `"A`" }, { `"TenantId`": `"b`" }, { `"TenantId`": `"skipme`" } ]" }
            } else { Ok }
        }
        $rows = Invoke-OctoTenantSweep -Context root -AllTenants -Exclude skipme -CliArguments '-c', 'ClearCache', '-tid', '{tenant}'
        $rows.Tenant | Should -Be 'a', 'b'
        $script:Calls[1] | Should -Be '--context', 'root', '-c', 'GetTenants', '--all'
    }

    It 'rejects a --context inside the arguments and bad parameter combinations' {
        Set-CliMock -PerTenant { Ok }
        { Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '--context', 'x', '-c', 'Y' } | Should -Throw '*must not contain --context*'
        { Invoke-OctoTenantSweep -ContextTemplate 'nope' -Tenant a -CliArguments '-c', 'Y' } | Should -Throw '*{tenant}*'
        { Invoke-OctoTenantSweep -Installation t2 -AllTenants -CliArguments '-c', 'Y' } | Should -Throw '*-Context*'
    }

    It '-Json emits the standard envelope with summary and rows' {
        Set-CliMock -PerTenant {
            param($a)
            if ($a -contains 't2_b') { [pscustomobject]@{ ExitCode = -4; Output = 'not provisioned' } } else { Ok }
        }
        $doc = Invoke-OctoTenantSweep -Installation t2 -Tenant a, b -CliArguments '-c', 'X' -Json | ConvertFrom-Json
        $doc.schemaVersion | Should -Be 1
        $doc.command | Should -Be 'Invoke-OctoTenantSweep'
        $doc.data.summary.total | Should -Be 2
        $doc.data.summary.denied | Should -Be 1
        $doc.data.results[1].outcome | Should -Be 'Denied'
    }
}

Describe 'output of the answer' {
    It 'rows carry no Stdout unless -IncludeOutput is given; with it the scrubbed stdout is added' {
        Set-CliMock { [pscustomobject]@{ ExitCode = 0; Output = 'noise'; Stdout = "{`"v`":1} $script:Canary" } }
        $plain = Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '-c', 'GraphQl'
        $plain.PSObject.Properties.Name | Should -Not -Contain 'Stdout'
        $with = Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '-c', 'GraphQl' -IncludeOutput
        $with.Stdout | Should -BeLike '{"v":1}*'
        $with.Stdout | Should -Not -BeLike '*eyJ*'
    }
}

Describe 'token hygiene' {
    It 'a token-shaped string in the octo-cli output never reaches rows, JSON or the information stream' {
        Set-CliMock -PerTenant {
            [pscustomobject]@{ ExitCode = -4; Output = "denied for bearer $($script:Canary)`nretry with access_token=$($script:Canary)" }
        }
        $rows = Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '-c', 'X' -ShowOutput -InformationVariable info
        $json = Invoke-OctoTenantSweep -Installation t2 -Tenant a -CliArguments '-c', 'X' -Json
        ($rows | Out-String) | Should -Not -BeLike "*$($script:Canary)*"
        ($rows | ConvertTo-Json -Depth 5) | Should -Not -BeLike '*eyJ*'
        ($info | Out-String) | Should -Not -BeLike '*eyJ*'
        ($json | Out-String) | Should -Not -BeLike '*eyJ*'
        $rows[0].Outcome | Should -Be 'Denied'
    }

    It 'never opens the octo-cli context file or any other file' {
        Set-CliMock -PerTenant { Ok }
        Mock -ModuleName Invoke-OctoTenantSweep Get-Content { throw 'must not read files' }
        Mock -ModuleName Invoke-OctoTenantSweep Set-Content { throw 'must not write files' }
        Mock -ModuleName Invoke-OctoTenantSweep Out-File { throw 'must not write files' }
        { Invoke-OctoTenantSweep -Installation t2 -Tenant a, b -CliArguments '-c', 'X' } | Should -Not -Throw
        $src = Get-Content -Raw (Join-Path $PSScriptRoot '../modules/Invoke-OctoTenantSweep.psm1')
        $src | Should -Not -Match 'contexts\.json'
        $src | Should -Not -Match '(?i)Get-Content|Set-Content|Out-File|Invoke-RestMethod|Invoke-WebRequest|AccessToken'
    }
}

Describe 'real process wrapper (fake octo-cli on the PATH)' -Skip:($IsWindows) {
    BeforeAll {
        $script:FakeDir = Join-Path ([IO.Path]::GetTempPath()) ("fake-octo-cli-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:FakeDir | Out-Null
        $fake = Join-Path $script:FakeDir 'octo-cli'
        @'
#!/bin/sh
case "$*" in
  *--help*) echo "Octo Mesh Management Tool, Version 3.5.27.0"; exit 0 ;;
  *t2_bad*) echo "Access to tenant 'bad' denied (not provisioned). Run ProvisionCurrentUser -ttid bad"; echo "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJjYW5hcnkifQ.c2ln" >&2; exit 252 ;;
  *GraphQl*) echo "banner and log line on stderr" >&2; echo '{"data":{"runtime":{"n":7}}}'; exit 0 ;;
  *) echo ok; exit 0 ;;
esac
'@ | Set-Content -Path $fake -NoNewline
        chmod +x $fake
        $script:OldPath = $env:PATH
        $env:PATH = "$($script:FakeDir)$([IO.Path]::PathSeparator)$($env:PATH)"
        Remove-Module Invoke-OctoTenantSweep -Force
        Import-Module (Join-Path $PSScriptRoot '../modules/Invoke-OctoTenantSweep.psm1') -Force
    }
    AfterAll {
        $env:PATH = $script:OldPath
        Remove-Item -Recurse -Force $script:FakeDir -ErrorAction SilentlyContinue
    }
    It 'maps exit 252 to -4 (Denied), keeps going and scrubs the token from stderr' {
        $rows = Invoke-OctoTenantSweep -Installation t2 -Tenant good, bad, good2 -CliArguments '-c', 'LibraryStatus'
        $rows.Outcome | Should -Be 'Ok', 'Denied', 'Ok'
        $rows[1].ExitCode | Should -Be -4
        ($rows | ConvertTo-Json -Depth 5) | Should -Not -BeLike '*eyJ*'
    }
    It '-IncludeOutput returns the clean stdout of GraphQl (stderr banner stays out) as parseable JSON' {
        $rows = Invoke-OctoTenantSweep -Installation t2 -Tenant a, b -IncludeOutput -CliArguments '-c', 'GraphQl', '-tid', '{tenant}', '-q', '{ x }'
        $rows.Outcome | Should -Be 'Ok', 'Ok'
        ($rows[0].Stdout | ConvertFrom-Json).data.runtime.n | Should -Be 7
        $rows[0].Stdout | Should -Not -BeLike '*banner*'
    }
}
