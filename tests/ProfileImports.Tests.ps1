#Requires -Modules Pester
<#
    Every module in modules/ must be imported by modules/profile.ps1, otherwise its cmdlets are missing in a fresh
    profile shell (Invoke-IdentityOverlay was, AB#8700). The check reads profile.ps1; it does not load the profile
    (which changes PATH and loads the private profile).

    Run:  Invoke-Pester ./tests/ProfileImports.Tests.ps1
#>

BeforeAll {
    $script:Modules = Join-Path $PSScriptRoot '../modules'
    $script:Profile = Get-Content -Raw -Path (Join-Path $script:Modules 'profile.ps1')
    # Modules that are deliberately not imported, with the reason.
    $script:NotImported = @{
        # Older copy of AspNetDeveloperCertificate.psm1 (same three functions); importing it would shadow the
        # imported, newer module.
        'New-DeveloperCertificate.psm1' = 'superseded by AspNetDeveloperCertificate.psm1'
    }
    $script:Imported = @([regex]::Matches($script:Profile, '(?m)^\s*Import-Module\s+"\$modulePath/([^"]+\.psm1)"') | ForEach-Object { $_.Groups[1].Value })
}

Describe 'profile.ps1 imports every module' {
    It 'imports each modules/*.psm1 except the documented exceptions' {
        $missing = @(Get-ChildItem -Path $script:Modules -Filter '*.psm1' | ForEach-Object Name |
            Where-Object { $_ -notin $script:Imported -and -not $script:NotImported.ContainsKey($_) })
        $missing | Should -BeNullOrEmpty -Because 'a module that profile.ps1 does not import has no cmdlets in a profile shell'
    }

    It 'imports only modules that exist, each once' {
        foreach ($name in $script:Imported) { Test-Path (Join-Path $script:Modules $name) | Should -BeTrue -Because "$name is imported" }
        @($script:Imported | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) | Should -BeNullOrEmpty
    }

    It 'lists no exception that is imported anyway or no longer exists' {
        foreach ($name in $script:NotImported.Keys) {
            Test-Path (Join-Path $script:Modules $name) | Should -BeTrue
            $script:Imported | Should -Not -Contain $name
        }
    }

    It 'exposes Invoke-IdentityOverlay' {
        $script:Imported | Should -Contain 'Invoke-IdentityOverlay.psm1'
        Import-Module (Join-Path $script:Modules 'OctoJsonOutput.psm1') -Force
        $module = Import-Module (Join-Path $script:Modules 'Invoke-IdentityOverlay.psm1') -Force -PassThru
        $module.ExportedFunctions.Keys | Should -Contain 'Invoke-IdentityOverlay'
    }
}
