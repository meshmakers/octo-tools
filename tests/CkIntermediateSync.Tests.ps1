#Requires -Modules Pester
<#
    Pester tests for Sync-OctoCkIntermediateVersions (AB#7974) and its vendored script
    (modules/scripts/Sync-CkIntermediateVersions.ps1, a verbatim copy of the script block of
    octo-pipeline-templates templates/steps/ck-sync-intermediate-versions.yml).

    Regression case: System.Identity 2.29.0, local catalog with 2.26.0 only, private catalog with 2.26.0-2.29.0
    (the 2026-11-01 local OCTO-CK203). Catalogs are directories in TestDrive (dir: locations), octo-ckc is the
    stand-in tests/fixtures/ck-sync/stub-octo-ckc.ps1 (writes like the LocalFileSystemCatalog). No network, no real
    catalog, never the lane's .octo/local-catalog.

    Run:  Invoke-Pester ./tests
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../modules/Sync-OctoCkIntermediateVersions.psm1') -Force
    $script:Fixtures = Join-Path $PSScriptRoot 'fixtures/ck-sync'
    $script:Stub = Join-Path $script:Fixtures 'stub-octo-ckc.ps1'
    $script:Vendored = Join-Path $PSScriptRoot '../modules/scripts/Sync-CkIntermediateVersions.ps1'

    function script:New-Catalog([string]$Path, [string[]]$Versions, [hashtable]$Files = @{}) {
        $rel = 'ck-models/v3/s/System.Identity'
        New-Item -ItemType Directory -Force -Path (Join-Path $Path "$rel/2") | Out-Null
        $entries = foreach ($v in $Versions) {
            $fileName = "ck-system.identity-$v.json"
            $target = Join-Path $Path "$rel/2/$fileName"
            if ($Files.ContainsKey($v)) { Copy-Item -LiteralPath $Files[$v] -Destination $target }
            else { Set-Content -LiteralPath $target -Value (@{ modelId = "System.Identity-$v" } | ConvertTo-Json) }
            @{ version = $v; fileName = $fileName; filePath = "$rel/2/$fileName" }
        }
        @{ version = '1.0'; models = @(@{ modelName = 'System.Identity'; catalogPath = "$rel/catalog.json" }) } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $Path 'ck-models/v3/catalog.json')
        @{ version = '1.0'; modelId = 'System.Identity'; majorVersions = @(@{ majorVersion = 2; catalogPath = "$rel/2/catalog.json" }) } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $Path "$rel/catalog.json")
        @{ version = '1.0'; modelId = 'System.Identity'; majorVersion = 2; versions = @($entries) } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $Path "$rel/2/catalog.json")
    }

    function script:New-Case([string]$Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
        New-Catalog (Join-Path $Root 'private') @('2.26.0', '2.27.0', '2.28.0', '2.29.0') @{
            '2.27.0' = (Join-Path $script:Fixtures 'ck-system.identity-2.27.0.json')
            '2.28.0' = (Join-Path $script:Fixtures 'ck-system.identity-2.28.0.json')
        }
        New-Catalog (Join-Path $Root 'lane/.octo/local-catalog') @('2.26.0')
        $ck = Join-Path $Root 'lane/octo-identity-services/src/SystemIdentityCkModel/ConstructionKit'
        New-Item -ItemType Directory -Force -Path $ck | Out-Null
        Set-Content -LiteralPath (Join-Path $ck 'ckModel.yaml') -Value "modelId: System.Identity-2.29.0`nckLanguage: 2"
        $classic = Join-Path $Root 'lane/octo-identity-services/src/Classic/ConstructionKit'
        New-Item -ItemType Directory -Force -Path $classic | Out-Null
        Set-Content -LiteralPath (Join-Path $classic 'ckModel.yaml') -Value "modelId: Basic-2.4.0"
        $env:STUB_LOG = Join-Path $Root 'stub.log'
        New-Item -ItemType File -Force -Path $env:STUB_LOG | Out-Null
        return [pscustomobject]@{
            Repo  = (Join-Path $Root 'lane/octo-identity-services')
            Local = (Join-Path $Root 'lane/.octo/local-catalog')
            Private = "dir:$(Join-Path $Root 'private')"
        }
    }

    function script:Get-LocalVersions([string]$Local) {
        ((Get-Content -Raw -LiteralPath (Join-Path $Local 'ck-models/v3/s/System.Identity/2/catalog.json') | ConvertFrom-Json).versions.version)
    }
    function script:Sha([string]$File) { (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant() }
}

AfterAll {
    Remove-Item Env:STUB_LOG -ErrorAction SilentlyContinue
}

Describe 'Vendored script' {
    It 'is the verbatim script block of ck-sync-intermediate-versions.yml (when the templates checkout is next to octo-tools)' {
        $candidates = @($env:OCTO_PIPELINE_TEMPLATES_PATH,
            (Join-Path $PSScriptRoot '../../main/octo-pipeline-templates'),
            (Join-Path $PSScriptRoot '../../octo-pipeline-templates')) | Where-Object { $_ }
        $template = $candidates | ForEach-Object { Join-Path $_ 'templates/steps/ck-sync-intermediate-versions.yml' } |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $template) { Set-ItResult -Skipped -Because 'no octo-pipeline-templates checkout with the template found'; return }
        $lines = Get-Content -LiteralPath $template
        $start = ($lines | Select-String -Pattern '^\s+script: \|\s*$' | Select-Object -First 1).LineNumber
        $body = foreach ($l in $lines[$start..($lines.Count - 1)]) { if ($l -match '^\s*$') { ''; continue }; if ($l -notmatch '^ {8}') { break }; $l.Substring(8) }
        (Get-Content -Raw -LiteralPath $script:Vendored).TrimEnd() | Should -Be (($body -join "`n").TrimEnd())
    }
}

Describe 'Sync-OctoCkIntermediateVersions: System.Identity 2.26 -> 2.29 in a local catalog' {
    It 'publishes 2.27.0 and 2.28.0 byte-identical into the local catalog and updates the index' {
        $case = New-Case (Join-Path $TestDrive 'apply')
        $r = Sync-OctoCkIntermediateVersions -repositoryPath $case.Repo -localCatalogRoot $case.Local -privateCatalogLocation $case.Private -ckc $script:Stub -Quiet
        $r.Success | Should -BeTrue
        $r.CkPaths.Count | Should -Be 1   # the ckLanguage 1 model is not a candidate
        (Get-LocalVersions $case.Local) | Should -Be @('2.26.0', '2.27.0', '2.28.0')
        Sha (Join-Path $case.Local 'ck-models/v3/s/System.Identity/2/ck-system.identity-2.27.0.json') | Should -Be 'ae5ecce13ba55fac8ff5aba542f0f6ebc81ed1dd89ce23f1544fb8d8c4b7bed6'
        Sha (Join-Path $case.Local 'ck-models/v3/s/System.Identity/2/ck-system.identity-2.28.0.json') | Should -Be '133609e45b6a4ad6db2b5e8aa06c8dd8f08e4a96addd0bf41b2fcf6a023306eb'
        $calls = @(Get-Content -LiteralPath $env:STUB_LOG)
        $calls.Count | Should -Be 2
        $calls[0] | Should -Match ([regex]::Escape("-c LocalFileSystemCatalog -lcr $($case.Local)"))
        # Second run: nothing missing, no publish.
        $r2 = Sync-OctoCkIntermediateVersions -repositoryPath $case.Repo -localCatalogRoot $case.Local -privateCatalogLocation $case.Private -ckc $script:Stub -Quiet
        $r2.Success | Should -BeTrue
        @(Get-Content -LiteralPath $env:STUB_LOG).Count | Should -Be 2
        ($r2.Output -join "`n") | Should -Match 'baseline 2.28.0, no intermediate version missing'
    }

    It '-WhatIf lists the versions and writes nothing' {
        $case = New-Case (Join-Path $TestDrive 'whatif')
        $r = Sync-OctoCkIntermediateVersions -repositoryPath $case.Repo -localCatalogRoot $case.Local -privateCatalogLocation $case.Private -ckc $script:Stub -Quiet -WhatIf
        $r.Success | Should -BeTrue
        (Get-LocalVersions $case.Local) | Should -Be @('2.26.0')
        @(Get-Content -LiteralPath $env:STUB_LOG).Count | Should -Be 0
        ($r.Output -join "`n") | Should -Match 'dry run: would publish System.Identity-2.27.0'
    }

    It 'warns with the fix command when octo-ckc fails' {
        $case = New-Case (Join-Path $TestDrive 'fail')
        $env:STUB_PUBLISH_EXIT = '3'; $env:STUB_PUBLISH_OUTPUT = 'boom'
        try {
            $r = Sync-OctoCkIntermediateVersions -repositoryPath $case.Repo -localCatalogRoot $case.Local -privateCatalogLocation $case.Private -ckc $script:Stub -Quiet -WarningVariable w -WarningAction SilentlyContinue 6>$null
        } finally { Remove-Item Env:STUB_PUBLISH_EXIT, Env:STUB_PUBLISH_OUTPUT -ErrorAction SilentlyContinue }
        $r.Success | Should -BeFalse
        ($w -join "`n") | Should -Match 'OCTO-CK203'
        ($w -join "`n") | Should -Match ([regex]::Escape("-c LocalFileSystemCatalog -lcr $($case.Local)"))
    }

    It 'stays green and changes nothing when the private catalog is unreachable' {
        $case = New-Case (Join-Path $TestDrive 'offline')
        $r = Sync-OctoCkIntermediateVersions -repositoryPath $case.Repo -localCatalogRoot $case.Local -privateCatalogLocation "dir:$(Join-Path $TestDrive 'offline/missing')" -ckc $script:Stub -Quiet
        $r.Success | Should -BeTrue
        (Get-LocalVersions $case.Local) | Should -Be @('2.26.0')
    }

    It 'skips a repository without ckLanguage 2 models without starting anything' {
        $repo = Join-Path $TestDrive 'plain/repo'
        New-Item -ItemType Directory -Force -Path (Join-Path $repo 'src') | Out-Null
        $r = Sync-OctoCkIntermediateVersions -repositoryPath $repo -localCatalogRoot (Join-Path $TestDrive 'plain/cat') -ckc $script:Stub -Quiet
        $r.Skipped | Should -BeTrue
    }
}
