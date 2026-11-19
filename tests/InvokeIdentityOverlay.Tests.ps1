#Requires -Modules Pester
<#
    Pester tests for Invoke-IdentityOverlay -Json: per-client added / skipped-duplicate counts parsed from octo-cli's
    output. octo-cli is replaced by a fake function; nothing is called out. With powershell-yaml installed the overlay is
    parsed by it; without (a machine where Install-Module is blocked), ConvertFrom-Yaml is a stub that returns what the
    module returns for this overlay - the tests are about the counts, not the YAML parser - so they never skip.

    Run:  Invoke-Pester ./tests/InvokeIdentityOverlay.Tests.ps1
#>

BeforeAll {
    $script:StubbedYaml = -not (Get-Module -ListAvailable -Name 'powershell-yaml')
    if ($script:StubbedYaml) {
        function global:ConvertFrom-Yaml([string]$Yaml) {
            [ordered]@{
                overlayName = 'local-dev'
                clients     = @(
                    [ordered]@{ clientId = 'octo-data-refinery-studio'; redirectUris = @('http://localhost:4200/auth-callback'); allowedCorsOrigins = @('http://localhost:4200') }
                    [ordered]@{ clientId = 'octo-cli'; redirectUris = @('http://localhost:5000/callback') }
                    [ordered]@{ clientId = 'broken-client'; redirectUris = @('http://localhost:1/x') }
                )
            }
        }
    }

    $modules = Join-Path $PSScriptRoot '../modules'
    Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
    Import-Module (Join-Path $modules 'Invoke-IdentityOverlay.psm1') -Force

    $script:Overlay = Join-Path $TestDrive 'overlay.yaml'
    Set-Content -Path $script:Overlay -Value @'
overlayName: local-dev
clients:
  - clientId: octo-data-refinery-studio
    redirectUris:
      - http://localhost:4200/auth-callback
    allowedCorsOrigins:
      - http://localhost:4200
  - clientId: octo-cli
    redirectUris:
      - http://localhost:5000/callback
  - clientId: broken-client
    redirectUris:
      - http://localhost:1/x
'@
    # Fake octo-cli: the console logger output of ApplyClientOverlay (wrapped like Microsoft.Extensions.Logging's
    # console formatter), an unparseable line for octo-cli, a failure for broken-client.
    function global:fake-octo-cli {
        $id = $args[[array]::IndexOf($args, '-id') + 1]
        switch ($id) {
            'octo-data-refinery-studio' {
                'info: Meshmakers.Octo.Frontend.ManagementTool.Commands.Implementations.Identity.Clients.ApplyClientOverlay[0]'
                "      Overlay 'local-dev' on 'octo-data-refinery-studio' applied: RedirectUris=1 added / 0 skipped, PostLogoutRedirectUris=0 added / 0 skipped,"
                '      AllowedCorsOrigins=0 added / 1 skipped'
                $global:LASTEXITCODE = 0
            }
            'octo-cli' { 'info: something else entirely'; $global:LASTEXITCODE = 0 }
            default { 'fail: client not found'; $global:LASTEXITCODE = 3 }
        }
    }
}

AfterAll {
    Remove-Item -Path 'function:global:fake-octo-cli' -ErrorAction SilentlyContinue
    if ($script:StubbedYaml) { Remove-Item -Path 'function:global:ConvertFrom-Yaml' -ErrorAction SilentlyContinue }
}

Describe 'Invoke-IdentityOverlay -Json counts' {
    BeforeAll {
        # The cmdlet refuses without powershell-yaml; with the stub above it may go on.
        if ($script:StubbedYaml) {
            Mock -ModuleName Invoke-IdentityOverlay Get-Module { [pscustomobject]@{ Name = 'powershell-yaml'; Version = [version]'0.0' } } -ParameterFilter { $Name -eq 'powershell-yaml' }
        }
    }

    It 'reports per-client counts, null when unparseable or failed, totals in the summary, and only one JSON document' {
        $out = @(Invoke-IdentityOverlay -OverlayFile $Overlay -OctoCli 'fake-octo-cli' -Json)
        $out.Count | Should -Be 1
        $doc = $out[0] | ConvertFrom-Json
        $studio = $doc.data.clients | Where-Object client -eq 'octo-data-refinery-studio'
        $studio.status | Should -Be 'applied'
        $studio.counts.redirectUris.added | Should -Be 1
        $studio.counts.postLogoutRedirectUris.skippedDuplicate | Should -Be 0
        $studio.counts.allowedCorsOrigins.skippedDuplicate | Should -Be 1
        $studio.counts.added | Should -Be 1
        $studio.counts.skippedDuplicate | Should -Be 1
        $out[0] | Should -Not -Match '"(added|skippedDuplicate)":\s*\d+\.\d' -Because 'counts are integers, not doubles from Measure-Object'
        ($doc.data.clients | Where-Object client -eq 'octo-cli').counts | Should -BeNullOrEmpty
        $broken = $doc.data.clients | Where-Object client -eq 'broken-client'
        $broken.status | Should -Be 'failed (exit 3)'
        $broken.counts | Should -BeNullOrEmpty
        $doc.data.summary.added | Should -Be 1
        $doc.data.summary.skippedDuplicate | Should -Be 1
        $doc.data.summary.countsUnparsed | Should -Be 1
        $doc.data.summary.failed | Should -Be 1
    }
}

Describe 'ConvertFrom-OctoOverlayOutput' {
    It 'does not read PostLogoutRedirectUris as RedirectUris and needs all three counts' {
        InModuleScope Invoke-IdentityOverlay {
            $c = ConvertFrom-OctoOverlayOutput -output @("Overlay 'x' on 'y' applied: PostLogoutRedirectUris=7 added / 8 skipped, RedirectUris=2 added / 3 skipped, AllowedCorsOrigins=0 added / 0 skipped")
            $c.redirectUris.added | Should -Be 2
            $c.postLogoutRedirectUris.added | Should -Be 7
            $c.added | Should -Be 9
            $c.skippedDuplicate | Should -Be 11
            ConvertFrom-OctoOverlayOutput -output @('RedirectUris=1 added / 0 skipped') | Should -BeNullOrEmpty
            ConvertFrom-OctoOverlayOutput -output @() | Should -BeNullOrEmpty
        }
    }
}
