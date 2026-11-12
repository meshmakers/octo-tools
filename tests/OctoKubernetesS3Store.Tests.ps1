#Requires -Modules Pester
<#
    Pester tests for the local S3 store of the kind cluster (OctoKubernetesS3Store.psm1, AB#5967 / AB#6967).
    No cluster, no docker and no CrateDB are touched: kubectl, the host port check and the credential
    lookup are mocked, the credentials in the tests are canary values.

    Run:  Invoke-Pester ./tests/OctoKubernetesS3Store.Tests.ps1
#>

BeforeAll {
    $script:kubernetesDir = Join-Path $PSScriptRoot '../kubernetes'
    Import-Module (Join-Path $PSScriptRoot '../modules/OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../modules/OctoKubernetesS3Store.psm1') -Force
}

Describe 'Store facts and manifests' {
    It 'names the host and the in-cluster endpoint of the same store' {
        $i = Get-OctoKubernetesS3StoreInfo
        $i.HostEndpoint | Should -Be "http://localhost:$($i.HostPort)"
        $i.InClusterHostPort | Should -Be "$($i.ServiceName).$($i.Namespace):$($i.Port)"
        $i.InClusterEndpoint | Should -Be "http://$($i.InClusterHostPort)"
    }

    It 'keeps the manifest, the kind port mapping and the facts in step' {
        $i = Get-OctoKubernetesS3StoreInfo
        $manifest = Get-Content (Join-Path $kubernetesDir 'infra/s3-store.yaml') -Raw
        $kind = Get-Content (Join-Path $kubernetesDir 'kind-cluster.yaml') -Raw
        $manifest | Should -Match "(?m)^  name: $($i.ServiceName)$"
        $manifest | Should -Match "nodePort: $($i.NodePort)"
        $manifest | Should -Match "-bucket=$($i.Bucket)"
        $manifest | Should -Match "secretName: $($i.SecretName)"
        $kind | Should -Match "containerPort: $($i.NodePort), hostPort: $($i.HostPort)"
    }

    It 'never carries a credential in the manifest (the Secret is generated at install time)' {
        $manifest = Get-Content (Join-Path $kubernetesDir 'infra/s3-store.yaml') -Raw
        $manifest | Should -Not -Match '(?m)^kind: Secret'
        $manifest | Should -Not -Match 'stringData'
    }
}

Describe 'Job log filter' {
    It 'accepts exactly the expected filter, ignoring spacing and case' {
        InModuleScope OctoKubernetesS3Store {
            Test-OctoCrateJobLogFilterActive -Value "stmt NOT ILIKE 'copy %'" | Should -BeTrue
            Test-OctoCrateJobLogFilterActive -Value "  stmt   not ilike 'copy %' " | Should -BeTrue
        }
    }

    It 'does not trust the default or another expression' {
        InModuleScope OctoKubernetesS3Store {
            Test-OctoCrateJobLogFilterActive -Value 'true' | Should -BeFalse
            Test-OctoCrateJobLogFilterActive -Value $null | Should -BeFalse
            Test-OctoCrateJobLogFilterActive -Value '' | Should -BeFalse
            Test-OctoCrateJobLogFilterActive -Value "stmt NOT ILIKE 'select %'" | Should -BeFalse
        }
    }

    It 'sets the filter when the cluster holds the default' {
        InModuleScope OctoKubernetesS3Store {
            Mock Get-OctoCrateJobLogFilter { 'true' }
            Mock Invoke-OctoCrateSql { $null }
            Set-OctoKubernetesCrateDbJobLogFilter | Should -BeTrue
            Should -Invoke Invoke-OctoCrateSql -Times 1 -ParameterFilter { $Stmt -eq "SET GLOBAL PERSISTENT stats.jobs_log_filter = 'stmt NOT ILIKE ''copy %'''" }
        }
    }

    It 'does nothing when the filter is already set' {
        InModuleScope OctoKubernetesS3Store {
            Mock Get-OctoCrateJobLogFilter { "stmt NOT ILIKE 'copy %'" }
            Mock Invoke-OctoCrateSql { $null }
            Set-OctoKubernetesCrateDbJobLogFilter | Should -BeTrue
            Should -Invoke Invoke-OctoCrateSql -Times 0
        }
    }

    It 'leaves a custom value alone' {
        InModuleScope OctoKubernetesS3Store {
            Mock Get-OctoCrateJobLogFilter { "stmt NOT ILIKE 'something else%'" }
            Mock Invoke-OctoCrateSql { $null }
            Mock Write-Warning { }
            Set-OctoKubernetesCrateDbJobLogFilter | Should -BeFalse
            Should -Invoke Invoke-OctoCrateSql -Times 0
        }
    }
}

Describe 'Secret hygiene' {
    It 'removes every secret value from a text' {
        InModuleScope OctoKubernetesS3Store {
            $text = Remove-OctoSecretText -Text 'failed for s3://CANARYKEY:CANARYSECRET@host/b' -Secrets @('CANARYKEY', 'CANARYSECRET')
            $text | Should -Not -Match 'CANARYKEY'
            $text | Should -Not -Match 'CANARYSECRET'
            $text | Should -Match 'host/b'
        }
    }

    It 'creates the credential Secret once, with create (not apply), through stdin' {
        InModuleScope OctoKubernetesS3Store {
            $script:calls = @()
            $script:stdin = $null
            function kubectl {
                $script:calls += , @($args)
                if ($args -contains 'get') { $global:LASTEXITCODE = 1; return }
                $script:stdin = @($input) -join "`n"
                $global:LASTEXITCODE = 0
            }
            Mock Write-Host { }
            New-OctoKubernetesS3StoreSecret -ClusterName 'kind' | Should -BeTrue

            $create = $script:calls | Where-Object { $_ -contains 'create' }
            $create | Should -Not -BeNullOrEmpty
            ($script:calls | Where-Object { $_ -contains 'apply' }) | Should -BeNullOrEmpty
            # no secret value in any argument list
            $script:stdin | Should -Not -BeNullOrEmpty
            $manifest = $script:stdin | ConvertFrom-Json
            $manifest.stringData.accessKey | Should -Match '^[0-9a-f]{20}$'
            $manifest.stringData.secretKey | Should -Match '^[0-9a-f]{40}$'
            foreach ($call in $script:calls) {
                ($call -join ' ') | Should -Not -Match $manifest.stringData.secretKey
            }
            $s3 = $manifest.stringData.'s3.json' | ConvertFrom-Json
            $s3.identities[0].credentials[0].accessKey | Should -Be $manifest.stringData.accessKey
        }
    }

    It 'keeps an existing credential Secret' {
        InModuleScope OctoKubernetesS3Store {
            $script:created = $false
            function kubectl {
                if ($args -contains 'create') { $script:created = $true }
                $global:LASTEXITCODE = 0
            }
            Mock Write-Host { }
            New-OctoKubernetesS3StoreSecret -ClusterName 'kind' | Should -BeTrue
            $script:created | Should -BeFalse
        }
    }
}

Describe 'Bot environment (Set-OctoLocalS3StoreEnvironment)' {
    BeforeEach {
        $script:saved = @{}
        foreach ($e in (Get-ChildItem env: | Where-Object { $_.Name -like 'OCTO_ARTIFACTSTORAGE__*' })) {
            $script:saved[$e.Name] = $e.Value
            Remove-Item "Env:$($e.Name)"
        }
    }
    AfterEach {
        foreach ($e in (Get-ChildItem env: | Where-Object { $_.Name -like 'OCTO_ARTIFACTSTORAGE__*' })) { Remove-Item "Env:$($e.Name)" }
        foreach ($k in $script:saved.Keys) { Set-Item "Env:$k" $script:saved[$k] }
    }

    It 'sets the S3 provider, both endpoints and the credential when the store answers' {
        InModuleScope OctoKubernetesS3Store {
            Mock Test-OctoLocalPortOpen { $true }
            Mock Get-OctoKubernetesS3StoreCredential { [pscustomobject]@{ AccessKeyId = 'CANARYKEY'; SecretAccessKey = 'CANARYSECRET' } }
            Set-OctoLocalS3StoreEnvironment | Should -BeTrue
            $env:OCTO_ARTIFACTSTORAGE__PROVIDER | Should -Be 'S3'
            $env:OCTO_ARTIFACTSTORAGE__S3__SERVICEURL | Should -Be 'http://localhost:8333'
            $env:OCTO_ARTIFACTSTORAGE__S3__CRATEDBSERVICEURL | Should -Be 'http://seaweedfs.octo-infra:8333'
            $env:OCTO_ARTIFACTSTORAGE__S3__BUCKET | Should -Be 'octo-artifacts'
            $env:OCTO_ARTIFACTSTORAGE__S3__FORCEPATHSTYLE | Should -Be 'true'
            $env:OCTO_ARTIFACTSTORAGE__S3__ACCESSKEYID | Should -Be 'CANARYKEY'
            $env:OCTO_ARTIFACTSTORAGE__S3__SECRETACCESSKEY | Should -Be 'CANARYSECRET'
        }
    }

    It 'leaves the environment alone when there is no store' {
        InModuleScope OctoKubernetesS3Store {
            Mock Test-OctoLocalPortOpen { $false }
            $env:OCTO_ARTIFACTSTORAGE__PROVIDER = 'FileSystem'
            Set-OctoLocalS3StoreEnvironment | Should -BeFalse
            $env:OCTO_ARTIFACTSTORAGE__PROVIDER | Should -Be 'FileSystem'
        }
    }

    It 'removes what an earlier start of this shell set when the store is gone' {
        InModuleScope OctoKubernetesS3Store {
            Mock Test-OctoLocalPortOpen { $true }
            Mock Get-OctoKubernetesS3StoreCredential { [pscustomobject]@{ AccessKeyId = 'CANARYKEY'; SecretAccessKey = 'CANARYSECRET' } }
            Set-OctoLocalS3StoreEnvironment | Should -BeTrue

            Mock Test-OctoLocalPortOpen { $false }
            Set-OctoLocalS3StoreEnvironment | Should -BeFalse
            (Get-ChildItem env: | Where-Object { $_.Name -like 'OCTO_ARTIFACTSTORAGE__*' }) | Should -BeNullOrEmpty
        }
    }

    It 'does not use the store with -Disable' {
        InModuleScope OctoKubernetesS3Store {
            Mock Test-OctoLocalPortOpen { $true }
            Mock Get-OctoKubernetesS3StoreCredential { [pscustomobject]@{ AccessKeyId = 'CANARYKEY'; SecretAccessKey = 'CANARYSECRET' } }
            Set-OctoLocalS3StoreEnvironment | Should -BeTrue
            Set-OctoLocalS3StoreEnvironment -Disable | Should -BeFalse
            (Get-ChildItem env: | Where-Object { $_.Name -like 'OCTO_ARTIFACTSTORAGE__*' }) | Should -BeNullOrEmpty
        }
    }
}

Describe 'Relay address (AB#8892)' {
    It '<subnet> (from end <fromEnd>) -> <expected>' -ForEach @(
        @{ subnet = '172.23.0.0/16';   fromEnd = 1; expected = '172.23.255.254' }
        @{ subnet = '172.23.0.0/16';   fromEnd = 2; expected = '172.23.255.253' }
        @{ subnet = '172.18.0.0/16';   fromEnd = 1; expected = '172.18.255.254' }
        @{ subnet = '10.89.0.0/24';    fromEnd = 1; expected = '10.89.0.254' }
        @{ subnet = '192.168.5.64/26'; fromEnd = 1; expected = '192.168.5.126' }
        @{ subnet = '172.23.4.7/16';   fromEnd = 1; expected = '172.23.255.254' }
        @{ subnet = '10.0.0.0/8';      fromEnd = 1; expected = '10.255.255.254' }
        @{ subnet = '10.0.0.0/30';     fromEnd = 2; expected = '10.0.0.1' }
        @{ subnet = '10.0.0.0/30';     fromEnd = 3; expected = $null }
        @{ subnet = '10.0.0.0/31';     fromEnd = 1; expected = $null }
        @{ subnet = '10.0.0.0/32';     fromEnd = 1; expected = $null }
        @{ subnet = 'fc00:f853:ccd:e793::/64'; fromEnd = 1; expected = $null }
        @{ subnet = '';                fromEnd = 1; expected = $null }
        @{ subnet = '300.1.1.1/16';    fromEnd = 1; expected = $null }
    ) {
        InModuleScope OctoKubernetesS3Store -Parameters @{ subnet = $subnet; fromEnd = $fromEnd; expected = $expected } {
            Get-OctoIPv4SubnetLastHost $subnet -FromEnd $fromEnd | Should -Be $expected
        }
    }

    It 'IPv6 <subnet> (from end <fromEnd>) -> <expected>' -ForEach @(
        @{ subnet = 'fc00:f853:ccd:e793::/64';       fromEnd = 1; expected = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }
        @{ subnet = 'fc00:f853:ccd:e793::/64';       fromEnd = 2; expected = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffd' }
        @{ subnet = 'FC00:F853:0CCD:E793:0:0:0:0/64'; fromEnd = 1; expected = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }
        @{ subnet = 'fc00:f853:ccd:e793::1234/64';   fromEnd = 1; expected = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }
        @{ subnet = 'fd00:1::/48';                   fromEnd = 1; expected = 'fd00:1:0:ffff:ffff:ffff:ffff:fffe' }
        @{ subnet = 'fd00::/120';                    fromEnd = 1; expected = 'fd00::fe' }
        @{ subnet = '2001:db8::/0';                  fromEnd = 1; expected = 'ffff:ffff:ffff:ffff:ffff:ffff:ffff:fffe' }
        @{ subnet = 'fd00::/126';                    fromEnd = 2; expected = 'fd00::1' }
        @{ subnet = 'fd00::/126';                    fromEnd = 3; expected = $null }
        @{ subnet = 'fd00::/127';                    fromEnd = 1; expected = $null }
        @{ subnet = 'fd00::/128';                    fromEnd = 1; expected = $null }
        @{ subnet = 'fd00::/129';                    fromEnd = 1; expected = $null }
        @{ subnet = '172.23.0.0/16';                 fromEnd = 1; expected = $null }
        @{ subnet = '';                              fromEnd = 1; expected = $null }
        @{ subnet = 'fd00::zz/64';                   fromEnd = 1; expected = $null }
    ) {
        InModuleScope OctoKubernetesS3Store -Parameters @{ subnet = $subnet; fromEnd = $fromEnd; expected = $expected } {
            Get-OctoIPv6SubnetLastHost $subnet -FromEnd $fromEnd | Should -Be $expected
        }
    }

    It 'reads both subnets of the dual-stack kind network' {
        InModuleScope OctoKubernetesS3Store {
            $script:inspected = $null
            function docker {
                $script:inspected = $args
                $global:LASTEXITCODE = 0
                'fc00:f853:ccd:e793::/64|fc00:f853:ccd:e793::1 172.23.0.0/16|172.23.0.1 '
            }
            $addresses = Get-OctoKubernetesS3RelayAddress
            $addresses.IPv4 | Should -Be '172.23.255.254'
            $addresses.IPv6 | Should -Be 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe'
            $script:inspected[0..2] -join ' ' | Should -Be 'network inspect kind'
        }
    }

    It 'has no IPv6 address on an IPv4-only network' {
        InModuleScope OctoKubernetesS3Store {
            function docker { $global:LASTEXITCODE = 0; '172.18.0.0/16|172.18.0.1 ' }
            $addresses = Get-OctoKubernetesS3RelayAddress
            $addresses.IPv4 | Should -Be '172.18.255.254'
            $addresses.IPv6 | Should -BeNullOrEmpty
        }
    }

    It 'steps below a gateway that sits at the end of the subnet (IPv4 and IPv6)' {
        InModuleScope OctoKubernetesS3Store {
            function docker { $global:LASTEXITCODE = 0; '10.89.0.0/24|10.89.0.254 fd00:1::/64|FD00:1:0:0:FFFF:FFFF:FFFF:FFFE' }
            $addresses = Get-OctoKubernetesS3RelayAddress
            $addresses.IPv4 | Should -Be '10.89.0.253'
            $addresses.IPv6 | Should -Be 'fd00:1::ffff:ffff:ffff:fffd'
        }
    }

    It 'returns nothing when the network does not exist or has no IPv4 subnet' {
        InModuleScope OctoKubernetesS3Store {
            function docker { $global:LASTEXITCODE = 1 }
            Get-OctoKubernetesS3RelayAddress | Should -BeNullOrEmpty
            function docker { $global:LASTEXITCODE = 0; 'fc00:f853:ccd:e793::/64|fc00:f853:ccd:e793::1' }
            Get-OctoKubernetesS3RelayAddress | Should -BeNullOrEmpty
        }
    }
}

Describe 'Relay decision (AB#8892)' {
    BeforeAll {
        $script:v4 = '172.23.255.254'
        $script:v6 = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe'
    }

    It 'dual-stack: <case> -> <action>' -ForEach @(
        @{ case = 'no relay';                                 relay = $null; action = 'Create' }
        @{ case = 'running with both expected addresses';     relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }; action = 'Keep' }
        @{ case = 'running, IPv6 spelled differently';        relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = 'FC00:F853:0CCD:E793:FFFF:FFFF:FFFF:FFFE' }; action = 'Keep' }
        @{ case = 'stopped with both expected addresses';     relay = @{ Running = $false; Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }; action = 'Start' }
        @{ case = 'right IPv4, no fixed IPv6 (PR #51 relay)'; relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = '' }; action = 'Recreate' }
        @{ case = 'right IPv4, another IPv6';                 relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = 'fc00:f853:ccd:e793::2' }; action = 'Recreate' }
        @{ case = 'right IPv6, another IPv4';                 relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.18.255.254'; FixedIPv6Address = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }; action = 'Recreate' }
        @{ case = 'right IPv6, no fixed IPv4';                relay = @{ Running = $false; Owner = 'kind'; FixedAddress = '';               FixedIPv6Address = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }; action = 'Recreate' }
        @{ case = 'running without fixed addresses';          relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '';               FixedIPv6Address = '' }; action = 'Recreate' }
        @{ case = 'of another cluster';                       relay = @{ Running = $true;  Owner = 'other'; FixedAddress = '';              FixedIPv6Address = '' }; action = 'Foreign' }
        @{ case = 'without the cluster label';                relay = @{ Running = $true;  Owner = '';     FixedAddress = '172.23.255.254'; FixedIPv6Address = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }; action = 'Foreign' }
    ) {
        InModuleScope OctoKubernetesS3Store -Parameters @{ relay = $relay; action = $action; v4 = $v4; v6 = $v6 } {
            $r = if ($relay) { [pscustomobject]$relay } else { $null }
            Get-OctoKubernetesS3RelayAction -Relay $r -ExpectedAddress $v4 -ExpectedIPv6Address $v6 -ClusterName 'kind' | Should -Be $action
        }
    }

    It 'IPv4-only network: <case> -> <action>' -ForEach @(
        @{ case = 'running with the expected IPv4, no IPv6';  relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = '' }; action = 'Keep' }
        @{ case = 'stopped with the expected IPv4, no IPv6';  relay = @{ Running = $false; Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = '' }; action = 'Start' }
        @{ case = 'with another IPv4';                        relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.18.255.254'; FixedIPv6Address = '' }; action = 'Recreate' }
        @{ case = 'with a fixed IPv6 the network lacks';      relay = @{ Running = $true;  Owner = 'kind'; FixedAddress = '172.23.255.254'; FixedIPv6Address = 'fc00:f853:ccd:e793:ffff:ffff:ffff:fffe' }; action = 'Recreate' }
    ) {
        InModuleScope OctoKubernetesS3Store -Parameters @{ relay = $relay; action = $action; v4 = $v4 } {
            $r = [pscustomobject]$relay
            Get-OctoKubernetesS3RelayAction -Relay $r -ExpectedAddress $v4 -ExpectedIPv6Address $null -ClusterName 'kind' | Should -Be $action
        }
    }
}

Describe 'Relay setup (Initialize-OctoKubernetesS3HostPort, AB#8892)' {
    BeforeEach {
        InModuleScope OctoKubernetesS3Store {
            $script:dockerCalls = [System.Collections.Generic.List[string]]::new()
            $script:relayLine = $null
            $script:networkConfig = 'fc00:f853:ccd:e793::/64|fc00:f853:ccd:e793::1 172.23.0.0/16|172.23.0.1 '
            # A function defined here would not outlive this scope; every test dot-sources this block so
            # that its fake docker shadows the real one (the real docker is never called).
            $script:fakeDocker = {
                function docker {
                    $line = $args -join ' '
                    $script:dockerCalls.Add($line)
                    $global:LASTEXITCODE = 0
                    switch ($args[0]) {
                        'port'    { $global:LASTEXITCODE = 1; return }
                        'network' { return $script:networkConfig }
                        'inspect' {
                            if ($null -eq $script:relayLine) { $global:LASTEXITCODE = 1; return }
                            return $script:relayLine
                        }
                    }
                }
            }
            Mock Write-Host { }
            Mock Write-Warning { }
            Mock Test-OctoLocalPortOpen { $false }
        }
    }

    It 'creates the relay with fixed addresses at the end of both kind subnets' {
        InModuleScope OctoKubernetesS3Store {
            . $script:fakeDocker
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeTrue
            $run = $script:dockerCalls | Where-Object { $_ -like 'run *' }
            $run | Should -HaveCount 1
            $run | Should -Match '--network kind --ip 172\.23\.255\.254 --ip6 fc00:f853:ccd:e793:ffff:ffff:ffff:fffe '
            $run | Should -Match '--restart unless-stopped'
            $run | Should -Match '-p 127\.0\.0\.1:8333:8333 '
            $run | Should -Match 'TCP:kind-control-plane:30333$'
        }
    }

    It 'creates the relay without --ip6 on an IPv4-only kind network' {
        InModuleScope OctoKubernetesS3Store {
            . $script:fakeDocker
            $script:networkConfig = '172.18.0.0/16|172.18.0.1 '
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeTrue
            $run = $script:dockerCalls | Where-Object { $_ -like 'run *' }
            $run | Should -HaveCount 1
            $run | Should -Match '--network kind --ip 172\.18\.255\.254 -p '
            $run | Should -Not -Match '--ip6'
        }
    }

    It 'keeps a running relay that already has both fixed addresses (no recreate)' {
        InModuleScope OctoKubernetesS3Store {
            . $script:fakeDocker
            $script:relayLine = 'true|kind|172.23.255.254|fc00:f853:ccd:e793:ffff:ffff:ffff:fffe'
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeTrue
            $script:dockerCalls | Should -Contain 'network inspect kind -f {{range .IPAM.Config}}{{.Subnet}}|{{.Gateway}} {{end}}'
            $script:dockerCalls | Where-Object { $_ -match '^(run|rm|start|stop) ' } | Should -BeNullOrEmpty
        }
    }

    It 'starts a stopped relay that has the fixed address' {
        InModuleScope OctoKubernetesS3Store {
            . $script:fakeDocker
            $script:relayLine = 'false|kind|172.23.255.254|fc00:f853:ccd:e793:ffff:ffff:ffff:fffe'
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeTrue
            $script:dockerCalls | Where-Object { $_ -match '^(run|rm) ' } | Should -BeNullOrEmpty
            $script:dockerCalls | Should -Contain 'start octo-kind-s3-relay'
        }
    }

    It 'recreates a relay of this cluster that has <case>' -ForEach @(
        @{ case = 'no fixed address';                       relayLine = 'true|kind||' }
        @{ case = 'the fixed IPv4 but no fixed IPv6 (PR #51)'; relayLine = 'true|kind|172.23.255.254|' }
        @{ case = 'the fixed IPv4 and the node''s IPv6';      relayLine = 'false|kind|172.23.255.254|fc00:f853:ccd:e793::2' }
    ) {
        InModuleScope OctoKubernetesS3Store -Parameters @{ relayLine = $relayLine } {
            . $script:fakeDocker
            $script:relayLine = $relayLine
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeTrue
            $rm = [array]::IndexOf($script:dockerCalls.ToArray(), 'rm -f octo-kind-s3-relay')
            $rm | Should -BeGreaterOrEqual 0
            $run = $script:dockerCalls.FindIndex({ param($c) $c -like 'run *' })
            $run | Should -BeGreaterThan $rm
            $script:dockerCalls[$run] | Should -Match '--ip 172\.23\.255\.254 --ip6 fc00:f853:ccd:e793:ffff:ffff:ffff:fffe '
        }
    }

    It 'leaves a relay of another cluster alone' {
        InModuleScope OctoKubernetesS3Store {
            . $script:fakeDocker
            $script:relayLine = 'true|other||'
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeFalse
            $script:dockerCalls | Where-Object { $_ -match '^(run|rm|start|stop) ' } | Should -BeNullOrEmpty
            Should -Invoke Write-Warning -Times 1
        }
    }

    It 'does nothing with the relay when the kind node maps the host port' {
        InModuleScope OctoKubernetesS3Store {
            . $script:fakeDocker
            function docker { $script:dockerCalls.Add($args -join ' '); $global:LASTEXITCODE = 0; if ($args[0] -eq 'port') { '0.0.0.0:8333' } }
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeTrue
            $script:dockerCalls | Should -HaveCount 1
        }
    }

    It 'refuses without an IPv4 subnet instead of starting a relay with a dynamic address' {
        InModuleScope OctoKubernetesS3Store {
            . $script:fakeDocker
            function docker { $script:dockerCalls.Add($args -join ' '); $global:LASTEXITCODE = 0; if ($args[0] -eq 'port') { $global:LASTEXITCODE = 1 } elseif ($args[0] -eq 'network') { 'fc00::/64|fc00::1' } }
            Initialize-OctoKubernetesS3HostPort -ClusterName 'kind' | Should -BeFalse
            $script:dockerCalls | Where-Object { $_ -like 'run *' } | Should -BeNullOrEmpty
        }
    }
}
