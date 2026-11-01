<#
.SYNOPSIS
    Brings the intermediate versions of ckLanguage 2 CK models from the private catalog into the lane's local
    catalog, so the local compile gate does not fail with OCTO-CK203 (AB#7974).

.DESCRIPTION
    The compile gate of a ckLanguage 2 model (OctoCkCompatibilityBaseline=Local, the default outside CI) compares the
    declared version with the newest version of the same major below it in the local catalog plus the cached remote
    catalogs. A developer whose local catalog holds System.Identity 2.26.0 but never built 2.27.0/2.28.0 (they came from
    other lanes or PR builds with OctoPublishCkModel=false), and whose remote catalogs are off (Octo.User.props), gets
    the diff 2.26.0 -> 2.29.0 without the acknowledgements 2.28.0 carries: 7x OCTO-CK203.

    For every ckModel.yaml with ckLanguage 2 below <repo>/src, this cmdlet lists the private catalog's versions of the
    declared major that lie strictly between the newest local version below the declared one and the declared version,
    downloads them byte for byte and publishes them in ascending order with
    `octo-ckc -c Publish -f <file> -c LocalFileSystemCatalog -lcr <lane>/.octo/local-catalog` (index updated, no compat
    gate for the local catalog). A local catalog without a version of that major gets nothing (no baseline = no gate
    failure). Only published versions are copied, never feature builds.

    The logic is the script block of octo-pipeline-templates templates/steps/ck-sync-intermediate-versions.yml, vendored
    verbatim as modules/scripts/Sync-CkIntermediateVersions.ps1 (one rule for the release pipeline and the local
    catalog). The private catalog is read from its GitHub Pages mirror: no token needed. The mirror can lag a publish
    by some minutes; an unreadable mirror is a warning and leaves the catalog unchanged.

    Invoke-BuildAll (DebugL) and Invoke-BuildRange (DebugL) run it before each repository; -skipCkSync turns it off.

.PARAMETER repositoryPath
    Repositories to scan (their src/ folders). Required unless -ckPath is given.

.PARAMETER ckPath
    CK source folders (each with a ckModel.yaml) instead of scanning repositories.

.PARAMETER branch
    Lane (checkout) whose local catalog is the target; resolved like Invoke-BuildRange. Ignored with -localCatalogRoot.

.PARAMETER localCatalogRoot
    Target catalog directory. Default <lane>/.octo/local-catalog.

.PARAMETER privateCatalogLocation
    Source location: pages:<url>, github:<owner>/<repo>@<branch> or dir:<path>.
    Default pages:https://meshmakers.github.io/construction-kit-libraries-build/.

.PARAMETER ckc
    octo-ckc executable. Default: <lane>/octo-construction-kit-engine/bin/DebugL/net10.0/publish/octo-ckc, else
    octo-ckc from PATH.

.PARAMETER WhatIf
    Dry run: lists what would be published; writes nothing.

.EXAMPLE
    Sync-OctoCkIntermediateVersions -repositoryPath ~/RiderProjects/meshmakers/main/octo-identity-services -WhatIf
#>
function Sync-OctoCkIntermediateVersions {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string[]]$repositoryPath = @(),
        [string[]]$ckPath = @(),
        [string]$branch = "",
        [string]$localCatalogRoot = "",
        [string]$privateCatalogLocation = 'pages:https://meshmakers.github.io/construction-kit-libraries-build/',
        [string]$ckc = "",
        [switch]$Quiet
    )

    $laneRoot = $null
    # <lane>/.octo/local-catalog names its lane (the lane's own octo-ckc is preferred below).
    if (-not [string]::IsNullOrWhiteSpace($localCatalogRoot) -and
        ([IO.Path]::GetFullPath($localCatalogRoot).TrimEnd('/', '\') -replace '\\', '/') -like '*/.octo/local-catalog') {
        $laneRoot = Split-Path -Parent (Split-Path -Parent ([IO.Path]::GetFullPath($localCatalogRoot).TrimEnd('/', '\')))
    }
    # Without -branch the lane is the checkout that holds the repository (a profile loaded from another lane must not
    # redirect the sync into its own catalog).
    if (-not $laneRoot -and [string]::IsNullOrWhiteSpace($branch) -and $repositoryPath.Count -gt 0) {
        $laneRoot = Split-Path -Parent ([IO.Path]::GetFullPath($repositoryPath[0]).TrimEnd('/', '\'))
    }
    if (-not $laneRoot -and ([string]::IsNullOrWhiteSpace($localCatalogRoot) -or [string]::IsNullOrWhiteSpace($ckc))) {
        $root = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($root) {
            $laneRoot = if (Get-Command Resolve-OctoBranchRootPath -ErrorAction SilentlyContinue) {
                (Resolve-OctoBranchRootPath -branch $branch -root $root).BranchRootPath
            } else { Join-Path $root $branch }
        }
    }
    if ([string]::IsNullOrWhiteSpace($localCatalogRoot)) {
        if (-not $laneRoot) { throw "Sync-OctoCkIntermediateVersions: pass -localCatalogRoot or -repositoryPath (lane root unknown)." }
        $localCatalogRoot = Join-Path $laneRoot '.octo/local-catalog'
    }
    $localCatalogRoot = [IO.Path]::GetFullPath($localCatalogRoot)

    $paths = @($ckPath | Where-Object { $_ })
    foreach ($repo in @($repositoryPath | Where-Object { $_ })) {
        $src = Join-Path $repo 'src'
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $paths += @(Get-ChildItem -LiteralPath $src -Recurse -File -Filter 'ckModel.yaml' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[/\\](bin|obj|node_modules)[/\\]' } |
            ForEach-Object { $_.DirectoryName })
    }
    # The compile gate is hard only for ckLanguage 2 models; the others need no sync (the script skips them too).
    $paths = @($paths | Where-Object {
            (Get-Content -Raw -LiteralPath (Join-Path $_ 'ckModel.yaml')) -match '(?m)^ckLanguage:\s*([2-9]|\d{2,})\s*$'
        } | Sort-Object -Unique)
    if ($paths.Count -eq 0) {
        return [pscustomobject]@{ Success = $true; Skipped = $true; CkPaths = @(); LocalCatalogRoot = $localCatalogRoot; ExitCode = 0 }
    }

    if ([string]::IsNullOrWhiteSpace($ckc)) {
        $exeName = if ($IsWindows) { 'octo-ckc.exe' } else { 'octo-ckc' }
        $laneCkc = if ($laneRoot) { Join-Path $laneRoot "octo-construction-kit-engine/bin/DebugL/net10.0/publish/$exeName" } else { $null }
        if ($laneCkc -and (Test-Path -LiteralPath $laneCkc)) { $ckc = $laneCkc }
        elseif (Get-Command octo-ckc -ErrorAction SilentlyContinue) { $ckc = (Get-Command octo-ckc).Source }
        else { $ckc = 'octo-ckc' }
    }

    $script = Join-Path $PSScriptRoot 'scripts/Sync-CkIntermediateVersions.ps1'
    $dryRun = [bool]$WhatIfPreference
    if (-not $dryRun -and -not $PSCmdlet.ShouldProcess($localCatalogRoot, "Publish missing intermediate versions of $($paths.Count) CK model(s)")) {
        return [pscustomobject]@{ Success = $true; Skipped = $true; CkPaths = $paths; LocalCatalogRoot = $localCatalogRoot; ExitCode = 0 }
    }
    $workDir = Join-Path ([IO.Path]::GetTempPath()) ("octo-ck-sync-local-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $workDir -WhatIf:$false | Out-Null
    $environment = [ordered]@{
        OCTO_CKSYNC_MODE              = 'apply'
        OCTO_CKSYNC_CK_PATHS          = ($paths -join ';')
        OCTO_CKSYNC_CATALOGS          = 'PrivateGitHubCatalog;LocalFileSystemCatalog'
        OCTO_CKSYNC_LOCATIONS         = "PrivateGitHubCatalog=$privateCatalogLocation;LocalFileSystemCatalog=dir:$localCatalogRoot"
        OCTO_CKSYNC_ONLY_CKLANGUAGE2  = 'true'
        OCTO_CKSYNC_DRYRUN            = if ($dryRun) { 'true' } else { 'false' }
        OCTO_CKSYNC_WORKDIR           = $workDir
        OCTO_CKSYNC_CKC               = $ckc
        OCTO_CKSYNC_SELFTEST          = $null
        OCTO_CKSYNC_IS_RELEASE        = $null
        OCTO_CKSYNC_IS_MAIN           = $null
        OCTO_CKSYNC_GITHUB_TOKEN      = $null
        OCTO_CKSYNC_CKC_HOME          = $null
    }
    $saved = @{}
    foreach ($name in $environment.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $environment[$name])
    }
    try {
        $output = & pwsh -NoProfile -NonInteractive -File $script 2>&1
        $exit = $LASTEXITCODE
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    $lines = @($output | ForEach-Object { "$_" })
    foreach ($line in $lines) {
        # The script's WARNING:/ERROR: lines reach the warning stream also with -Quiet (-Json builds, -WarningVariable).
        if ($line -match '^(WARNING|ERROR): (.*)$') { Write-Warning $Matches[2] }
        elseif (-not $Quiet -or $exit -ne 0) { Write-Host $line }
    }

    $quote = { param([string]$v) "'" + ($v -replace "'", "''") + "'" }
    $repoArg = if ($repositoryPath.Count -gt 0) { "-repositoryPath " + (($repositoryPath | ForEach-Object { & $quote $_ }) -join ',') } else { "-ckPath " + (($paths | ForEach-Object { & $quote $_ }) -join ',') }
    $fix = "Sync-OctoCkIntermediateVersions $repoArg -localCatalogRoot $(& $quote $localCatalogRoot) -privateCatalogLocation $(& $quote $privateCatalogLocation) -ckc $(& $quote $ckc)"
    $manual = "per missing version, ascending: octo-ckc -c Publish -f <ck-<name>-<version>.json taken byte for byte from the private catalog> -c LocalFileSystemCatalog -lcr $localCatalogRoot"
    if ($exit -ne 0) {
        Write-Warning "CK intermediate-version sync failed (exit $exit). A ckLanguage 2 build may now fail with OCTO-CK203. Fix: $fix   # or by hand, $manual"
    }
    return [pscustomobject]@{
        Success          = ($exit -eq 0)
        Skipped          = $false
        CkPaths          = $paths
        LocalCatalogRoot = $localCatalogRoot
        ExitCode         = $exit
        Output           = $lines
        FixCommand       = $fix
        ManualFix        = $manual
    }
}

Export-ModuleMember -Function Sync-OctoCkIntermediateVersions
