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
