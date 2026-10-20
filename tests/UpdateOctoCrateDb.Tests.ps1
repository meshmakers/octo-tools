#Requires -Modules Pester
<#
    Pester tests for the guarded CrateDB upgrade (Update-OctoCrateDb.psm1, AB#7139).
    No cluster is touched: kubectl and every CrateDB helper are mocked.

    Run:  Invoke-Pester ./tests/UpdateOctoCrateDb.Tests.ps1
#>

BeforeAll {
    $script:module = Import-Module (Join-Path $PSScriptRoot '../modules/Update-OctoCrateDb.psm1') -Force -PassThru
    $script:manifest = Join-Path $TestDrive 'cratedb.yaml'
    Set-Content $script:manifest -Value "spec:`n  containers:`n    - name: cratedb`n      image: crate:6.4.6`n      args: [crate]"
}

Describe 'Get-CrateUpgradePlan' {
    It '<running> -> <target> is <action> via <steps>' -ForEach @(
        @{ running = '6.4.6';  target = '6.4.6';  action = 'NoOp';    steps = '' }
        @{ running = '6.4.6';  target = '5.10.10'; action = 'Refuse';  steps = '' }
        @{ running = '6.5.0';  target = '6.4.6';  action = 'Refuse';  steps = '' }
        @{ running = '5.9.10'; target = '6.4.6';  action = 'Upgrade'; steps = '5.10.16 6.4.6' }
        @{ running = '5.10.0'; target = '6.4.6';  action = 'Upgrade'; steps = '5.10.16 6.4.6' }
        @{ running = '5.10.1'; target = '6.4.6';  action = 'Upgrade'; steps = '6.4.6' }
        @{ running = '5.10.10'; target = '6.4.6'; action = 'Upgrade'; steps = '6.4.6' }
        @{ running = '5.9.10'; target = '5.10.10'; action = 'Upgrade'; steps = '5.10.10' }
        @{ running = '6.4.6-SNAPSHOT'; target = '6.4.6'; action = 'NoOp'; steps = '' }
    ) {
        InModuleScope Update-OctoCrateDb -Parameters @{ running = $running; target = $target; action = $action; steps = $steps } {
            param($running, $target, $action, $steps)
            $plan = Get-CrateUpgradePlan -Running $running -Target $target
            $plan.Action | Should -Be $action
            ($plan.Steps -join ' ') | Should -Be $steps
        }
    }

    It 'rejects a version that is not x.y.z' {
        InModuleScope Update-OctoCrateDb { { Get-CrateUpgradePlan -Running 'latest' -Target '6.4.6' } | Should -Throw "*not a CrateDB version*" }
    }
}

Describe 'Get-CrateManifestVersion' {
    It 'reads the tag of the crate image' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } { param($m) Get-CrateManifestVersion -ManifestPath $m | Should -Be '6.4.6' }
    }
    It 'fails when the manifest has no crate image line' {
        $bad = Join-Path $TestDrive 'bad.yaml'; Set-Content $bad 'image: busybox:1.36'
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $bad } { param($m) { Get-CrateManifestVersion -ManifestPath $m } | Should -Throw "*No 'image: crate*" }
    }
}

Describe 'Update-OctoCrateDb' {
    BeforeEach {
        $script:applied = [System.Collections.Generic.List[string]]::new()
        InModuleScope Update-OctoCrateDb {
            # Fake kubectl: contexts, the StatefulSet lookup, apply (records the image), rollout status.
            Mock kubectl {
                $a = $args -join ' '
                $global:LASTEXITCODE = 0
                if ($a -match 'config get-contexts') { return 'kind-test' }
                if ($a -match 'get statefulset cratedb') { if ($script:hasSts) { return 'statefulset.apps/cratedb' } else { return $null } }
                if ($a -match ' apply -f (.+)$') {
                    $path = $Matches[1]
                    $text = Get-Content $path -Raw
                    $script:applied.Add(([regex]::Match($text, 'crate:(\d+\.\d+\.\d+)').Groups[1].Value))
                }
            }
            Mock Wait-CrateHealthy {}
            Mock Get-CrateTableCounts { [ordered]@{ 'doc.t' = 10L } }
            Mock New-CrateUpgradeSnapshot { 'snap' }
            Mock Test-CrateSnapshotSpace { $true }
            Mock Start-Sleep {}
        }
    }

    It 'rejects a context that does not exist' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            { Update-OctoCrateDb -Context 'nope' -ManifestPath $m } | Should -Throw "*does not exist*"
        }
    }

    It 'installs on a fresh cluster without reading a version or taking a snapshot' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $false; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { throw 'must not be called' }
            (Update-OctoCrateDb -Context kind-test -ManifestPath $m).Action | Should -Be 'Install'
            $script:applied | Should -Be @('6.4.6')
            Should -Invoke New-CrateUpgradeSnapshot -Times 0
        }
    }

    It 'is a no-op when the running version equals the target' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { '6.4.6' }
            (Update-OctoCrateDb -Context kind-test -ManifestPath $m).Action | Should -Be 'NoOp'
            Should -Invoke New-CrateUpgradeSnapshot -Times 0
        }
    }

    It 'refuses a downgrade and does not apply the manifest' {
        InModuleScope Update-OctoCrateDb -Parameters @{ d = $TestDrive } {
            param($d)
            $old = Join-Path $d 'old.yaml'; Set-Content $old "image: crate:5.10.10"
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { '6.4.6' }
            { Update-OctoCrateDb -Context kind-test -ManifestPath $old } | Should -Throw "*cannot be downgraded*NOT applied*"
            $script:applied.Count | Should -Be 0
            Should -Invoke New-CrateUpgradeSnapshot -Times 0
        }
    }

    It 'does not apply anything when the running version cannot be read' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { throw 'pod down' }
            { Update-OctoCrateDb -Context kind-test -ManifestPath $m } | Should -Throw "*Cannot read the running CrateDB version*"
            $script:applied.Count | Should -Be 0
        }
    }

    It 'steps 5.9.10 -> 5.10.16 -> 6.4.6 after one snapshot' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { '5.9.10' }
            $r = Update-OctoCrateDb -Context kind-test -ManifestPath $m
            $r.Action | Should -Be 'Upgrade'
            $script:applied | Should -Be @('5.10.16', '6.4.6')
            Should -Invoke New-CrateUpgradeSnapshot -Times 1 -Exactly
            Should -Invoke Wait-CrateHealthy -Times 3 -Exactly   # before, after step 1, after step 2
        }
    }

    It 'goes straight to the target from 5.10.10' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { '5.10.10' }
            Update-OctoCrateDb -Context kind-test -ManifestPath $m | Out-Null
            $script:applied | Should -Be @('6.4.6')
        }
    }

    It 'aborts before any change when the disk is too small and it may not ask' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { '5.10.10' }
            Mock Test-CrateSnapshotSpace { $false }
            { Update-OctoCrateDb -Context kind-test -ManifestPath $m -NonInteractive } | Should -Throw "*Not enough free disk space*-SkipSnapshot*"
            $script:applied.Count | Should -Be 0
        }
    }

    It '-SkipSnapshot upgrades without checking the disk or snapshotting' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { '5.10.10' }
            Mock Test-CrateSnapshotSpace { $false }
            Update-OctoCrateDb -Context kind-test -ManifestPath $m -SkipSnapshot | Out-Null
            $script:applied | Should -Be @('6.4.6')
            Should -Invoke New-CrateUpgradeSnapshot -Times 0
        }
    }

    It 'fails the step when a table lost rows' {
        InModuleScope Update-OctoCrateDb -Parameters @{ m = $script:manifest } {
            param($m)
            $script:hasSts = $true; $script:applied = [System.Collections.Generic.List[string]]::new()
            Mock Get-CrateRunningVersion { '5.10.10' }
            $script:calls = 0
            Mock Get-CrateTableCounts { $script:calls++; [ordered]@{ 'doc.t' = $(if ($script:calls -eq 1) { 10L } else { 7L }) } }
            { Update-OctoCrateDb -Context kind-test -ManifestPath $m -SkipSnapshot } | Should -Throw "*lost rows*10 -> 7*"
        }
    }
}
