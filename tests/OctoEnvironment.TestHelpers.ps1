<#
    Shared setup of the feature environment tests (OctoEnvironment*.Tests.ps1, AB#8700): dot-sourced inside each file's
    BeforeAll. Loads the modules, isolates git, builds the fake workspace template once per file and defines the
    fixture helpers; Restore-OctoEnvironmentTestState (AfterAll) puts the session back.

    The tests are split over several files so that Invoke-ParallelPester.ps1 can run them side by side; each file is
    self-contained and runs alone with Invoke-Pester as well.
#>

$modules = Join-Path $PSScriptRoot '../modules'
Import-Module (Join-Path $modules 'OctoJsonOutput.psm1') -Force
Import-Module (Join-Path $modules 'Get-OctoLaneBuildSettings.psm1') -Force
Import-Module (Join-Path $modules 'OctoBuildOrder.psm1') -Force
Import-Module (Join-Path $modules 'Copy-NuGetPackages.psm1') -Force
Import-Module (Join-Path $modules 'Invoke-KillDotnet.psm1') -Force
Import-Module (Join-Path $modules 'Stop-Octo.psm1') -Force
Import-Module (Join-Path $modules 'Invoke-Publish.psm1') -Force
Import-Module (Join-Path $modules 'Invoke-BuildAll.psm1') -Force
Import-Module (Join-Path $modules 'Sync-OctoCkIntermediateVersions.psm1') -Force
Import-Module (Join-Path $modules 'OctoBuildStamp.psm1') -Force
Import-Module (Join-Path $modules 'OctoCkCatalogRefresh.psm1') -Force
Import-Module (Join-Path $modules 'Invoke-BuildRange.psm1') -Force
Import-Module (Join-Path $modules 'OctoEnvironment.psm1') -Force

# Isolated git: no global/system config, fixed identity.
$script:SavedEnv = @{}
$gitEnv = @{
    GIT_CONFIG_GLOBAL   = (Join-Path $TestDrive 'gitconfig')
    GIT_CONFIG_NOSYSTEM = '1'
    GIT_AUTHOR_NAME     = 'Pester'
    GIT_AUTHOR_EMAIL    = 'pester@example.invalid'
    GIT_COMMITTER_NAME  = 'Pester'
    GIT_COMMITTER_EMAIL = 'pester@example.invalid'
}
foreach ($name in $gitEnv.Keys) {
    $script:SavedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $gitEnv[$name])
}
Set-Content -Path $gitEnv.GIT_CONFIG_GLOBAL -Value "[init]`n`tdefaultBranch = main`n[advice]`n`tdetachedHead = false"

# The tests of this file mock the in-process build step (Invoke-OctoBuildRangeRepo). A parallel run builds in child
# processes, where a mock does not reach: every Invoke-BuildEnvironment here is sequential unless a test asks for
# more - those tests mock the job functions (Start-OctoRepoBuildJob / Get-OctoRepoBuildJobState) instead.
$script:PreviousMaxParallelDefault = $global:PSDefaultParameterValues['Invoke-BuildEnvironment:maxParallel']
$global:PSDefaultParameterValues['Invoke-BuildEnvironment:maxParallel'] = 1

# AB#8831: nothing in these files reads the developer's package cache, CK catalog caches or octo-ckc. The user-level
# package cache "does not exist" (an environment is filled from it otherwise), the remote CK catalog caches are fresh
# files in TestDrive (no refresh is due), and there is no octo-ckc.
Mock -ModuleName OctoEnvironment Get-OctoGlobalPackageCachePath { Join-Path $TestDrive 'no-user-level-package-cache' }
Mock -ModuleName OctoCkCatalogRefresh Resolve-OctoCkc { $null }
$script:PreviousCkCacheDirectory = $env:OCTO_CK_CACHE_DIRECTORY
$env:OCTO_CK_CACHE_DIRECTORY = Join-Path $TestDrive 'ck-cache'
New-Item -ItemType Directory -Force -Path $env:OCTO_CK_CACHE_DIRECTORY | Out-Null
foreach ($name in 'public-github-catalog-cache.json', 'private-github-catalog-cache.json') { Set-Content -Path (Join-Path $env:OCTO_CK_CACHE_DIRECTORY $name) -Value '{}' }

$script:PreviousRootPath = Get-Variable -Name rootPath -Scope Global -ValueOnly -ErrorAction SilentlyContinue
$script:PreviousNugetPackages = $env:NUGET_PACKAGES
$env:NUGET_PACKAGES = $null

function Invoke-TestGit([string]$path) {
    $output = & git -C $path @args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed in ${path}: $output" }
    return $output
}

function New-Csproj([string]$repo, [string]$project, [string]$packageId = '', [string[]]$references = @(), [switch]$notPackable) {
    $folder = Join-Path $repo "src/$project"
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $lines = @('<Project Sdk="Microsoft.NET.Sdk">', '  <PropertyGroup>')
    if ($packageId) { $lines += "    <PackageId>$packageId</PackageId>" }
    if ($notPackable) { $lines += '    <IsPackable>false</IsPackable>' }
    $lines += '  </PropertyGroup>', '  <ItemGroup>'
    foreach ($reference in $references) { $lines += "    <PackageReference Include=""$reference"" Version=""`$(OctoCoreLibVersion)"" />" }
    $lines += '    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />', '  </ItemGroup>', '</Project>'
    Set-Content -Path (Join-Path $folder "$project.csproj") -Value $lines
}

function New-FakeRepo([string]$lane, [string]$name, [scriptblock]$content) {
    $repo = Join-Path $lane $name
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    & $content $repo
    # a solution with the src/ projects, so Invoke-BuildRange plans a build
    $projects = @(Get-ChildItem -Path (Join-Path $repo 'src') -Recurse -Filter '*.csproj' | ForEach-Object { "  <Project Path=""src/$($_.Directory.Name)/$($_.Name)"" />" })
    Set-Content -Path (Join-Path $repo "$name.slnx") -Value (@('<Solution>') + $projects + @('</Solution>'))
    Set-Content -Path (Join-Path $repo '.gitignore') -Value "bin/`nobj/"
    Invoke-TestGit $repo init -q -b main | Out-Null
    Invoke-TestGit $repo add -A | Out-Null
    Invoke-TestGit $repo commit -q -m "initial $name" | Out-Null
    $origin = Join-Path $TestDrive "origins/$name.git"
    if (Test-Path $origin) { Remove-Item $origin -Recurse -Force }
    Invoke-TestGit $TestDrive init -q --bare $origin | Out-Null
    Invoke-TestGit $repo remote add origin $origin | Out-Null
    Invoke-TestGit $repo push -q -u origin main | Out-Null
    return $repo
}

function New-FakePackage([string]$folder, [string]$id, [string]$content) {
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $file = Join-Path $folder "$id.999.0.0.nupkg"
    Set-Content -Path $file -Value $content -NoNewline
    return $file
}

function New-FakeCatalogIndex([string]$path, [string[]]$models) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    $doc = [ordered]@{ version = '1.0'; updatedAt = '2026-01-01T00:00:00Z'; models = @($models | ForEach-Object { [ordered]@{ modelName = $_; catalogPath = "ck-models/v3/x/$_/catalog.json" } }) }
    Set-Content -Path $path -Value (ConvertTo-Json -InputObject $doc -Depth 5)
}

# Workspace: <ws>/branches/main (base lane), environments in <ws>/wt-<env> (octo-claude-pm lane folders).
# Building it takes about 36 git calls (six repositories, each with a bare origin). It is built once per test file
# (Initialize-FakeWorkspaceTemplate) and New-FakeWorkspace puts a fresh copy in place before every test: the copy
# sits at the path it was built at, so the absolute origin URLs in .git/config stay valid.
function New-FakeWorkspace {
    $ws = Join-Path $TestDrive 'ws'
    foreach ($folder in @($ws, (Join-Path $TestDrive 'origins'))) { if (Test-Path $folder) { Remove-Item $folder -Recurse -Force } }
    $template = Join-Path $TestDrive 'workspace-template'
    if (-not (Test-Path -LiteralPath (Join-Path $template 'ws'))) { Initialize-FakeWorkspaceTemplate }
    if ($IsWindows) {
        foreach ($name in 'ws', 'origins') { Copy-Item -LiteralPath (Join-Path $template $name) -Destination (Join-Path $TestDrive $name) -Recurse -Force }
    }
    else {
        # -p keeps the file times, so git's index still matches the working tree.
        & cp -Rp (Join-Path $template 'ws') (Join-Path $template 'origins') ([string]$TestDrive)
        if ($LASTEXITCODE -ne 0) { throw "Copying the workspace template $template failed." }
    }
    $global:rootPath = $ws
    return [pscustomobject]@{ Root = $ws; Main = (Join-Path $ws 'branches/main') }
}

function Initialize-FakeWorkspaceTemplate {
    $ws = Join-Path $TestDrive 'ws'
    foreach ($folder in @($ws, (Join-Path $TestDrive 'origins'))) { if (Test-Path $folder) { Remove-Item $folder -Recurse -Force } }
    $main = Join-Path $ws 'branches/main'
    New-Item -ItemType Directory -Force -Path $main | Out-Null
    Set-Content -Path (Join-Path $main 'Octo.User.props') -Value '<Project><PropertyGroup><OctoSomething>1</OctoSomething></PropertyGroup></Project>'

    # Package chain: engine -> sdk -> asset-repo (service); identity consumes only mm-common; cli consumes sdk.
    New-FakeRepo $main 'mm-common' { param($r) New-Csproj $r 'Common.Shared' -packageId 'Meshmakers.Common.Shared' } | Out-Null
    New-FakeRepo $main 'octo-construction-kit-engine' { param($r)
        New-Csproj $r 'Runtime.Engine' -packageId 'Meshmakers.Octo.Runtime.Engine' -references 'Meshmakers.Common.Shared'
        New-Csproj $r 'Engine.Tests' -references 'Meshmakers.Octo.Runtime.Engine' -notPackable } | Out-Null
    New-FakeRepo $main 'octo-sdk' { param($r) New-Csproj $r 'Sdk.Common' -packageId 'Meshmakers.Octo.Sdk.Common' -references 'Meshmakers.Octo.Runtime.Engine' } | Out-Null
    New-FakeRepo $main 'octo-asset-repo-services' { param($r) New-Csproj $r 'AssetRepository' -references 'Meshmakers.Octo.Sdk.Common' -notPackable } | Out-Null
    New-FakeRepo $main 'octo-identity-services' { param($r) New-Csproj $r 'Identity' -references 'Meshmakers.Common.Shared' -notPackable } | Out-Null
    New-FakeRepo $main 'octo-cli' { param($r) New-Csproj $r 'ManagementTool' -references 'Meshmakers.Octo.Sdk.Common' -notPackable } | Out-Null

    New-FakePackage (Join-Path $main 'nuget') 'Meshmakers.Common.Shared' 'common-v1' | Out-Null
    New-FakePackage (Join-Path $main 'nuget') 'Meshmakers.Octo.Runtime.Engine' 'engine-v1' | Out-Null
    New-FakePackage (Join-Path $main 'nuget') 'Meshmakers.Octo.Sdk.Common' 'sdk-v1' | Out-Null
    New-FakeCatalogIndex (Join-Path $main '.octo/local-catalog/ck-models/v3/catalog.json') @('Basic', 'System')
    New-Item -ItemType Directory -Force -Path (Join-Path $main '.octo/local-catalog/cache') | Out-Null
    Set-Content -Path (Join-Path $main '.octo/local-catalog/cache/local-catalog-cache.json') -Value '{"models":{"Basic":{}}}'
    Set-Content -Path (Join-Path $main '.octo/local-catalog/ck-models/v3/.catalog-index.lock') -Value ''
    New-Item -ItemType Directory -Force -Path (Join-Path $main '.octo/local-blueprint-catalog/blueprints/v1/App/1.0.0') | Out-Null
    Set-Content -Path (Join-Path $main '.octo/local-blueprint-catalog/blueprints/v1/App/1.0.0/blueprint.yaml') -Value 'name: App'

    # Built at its final path (the origin URLs are absolute), then moved aside as the template.
    $template = Join-Path $TestDrive 'workspace-template'
    if (Test-Path $template) { Remove-Item $template -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $template | Out-Null
    Move-Item -LiteralPath $ws -Destination (Join-Path $template 'ws')
    Move-Item -LiteralPath (Join-Path $TestDrive 'origins') -Destination (Join-Path $template 'origins')
}

function Get-Doc([object[]]$output) { return (($output -join "`n") | ConvertFrom-Json) }

# AfterAll of every file that dot-sourced this helper.
function Restore-OctoEnvironmentTestState {
    foreach ($name in $script:SavedEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:SavedEnv[$name]) }
    if ($null -ne $script:PreviousMaxParallelDefault) { $global:PSDefaultParameterValues['Invoke-BuildEnvironment:maxParallel'] = $script:PreviousMaxParallelDefault }
    else { $global:PSDefaultParameterValues.Remove('Invoke-BuildEnvironment:maxParallel') }
    $env:NUGET_PACKAGES = $script:PreviousNugetPackages
    $env:OCTO_CK_CACHE_DIRECTORY = $script:PreviousCkCacheDirectory
    if ($null -ne $script:PreviousRootPath) { $global:rootPath = $script:PreviousRootPath } else { Remove-Variable -Name rootPath -Scope Global -ErrorAction SilentlyContinue }
}

# Once per file, before the first Describe: Pester keeps what exists in TestDrive when a block starts. Last, so that
# the AfterAll function above exists also when a git call of the template fails.
Initialize-FakeWorkspaceTemplate
