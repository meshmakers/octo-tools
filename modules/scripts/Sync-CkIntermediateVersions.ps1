# Sync of private-only intermediate CK model versions (AB#7974). Single copy of the logic: the template
# ck-sync-intermediate-versions.yml in octo-pipeline-templates; octo-tools vendors this block verbatim.
$ErrorActionPreference = 'Stop'
$script:CkSyncDefaultLocations = [ordered]@{
  PrivateGitHubCatalog = 'github:meshmakers/construction-kit-libraries-build@main'
  PublicGitHubCatalog  = 'github:meshmakers/meshmakers.github.io@main'
}
$script:CkSyncRoots = @('ck-models/v3/', 'ck-models/v2/')

# ';'-separated list; an unexpanded ADO macro (variable not set) counts as empty.
function Split-CkSyncList {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '^\$\(.+\)$') { return @() }
  return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-CkSyncTrue {
  param([string]$Value)
  return [string]::Equals("$Value".Trim(), 'true', [StringComparison]::OrdinalIgnoreCase)
}

# Azure DevOps issue lines on a build agent, plain prefixes elsewhere (octo-tools runs the same block).
function Write-CkSyncIssue {
  param([ValidateSet('warning', 'error')][string]$Type, [string]$Message)
  if (Test-CkSyncTrue $env:TF_BUILD) { Write-Host "##vso[task.logissue type=$Type]$Message" }
  else { Write-Host ("{0}: {1}" -f $Type.ToUpperInvariant(), $Message) }
}

# X.Y.Z of a CK model version; anything else is not comparable.
function ConvertTo-CkSyncVersion {
  param([string]$Text)
  if ("$Text" -notmatch '^\d+\.\d+\.\d+$') { return $null }
  return [version]$Text
}

# Name, version and ckLanguage of the ckModel.yaml in a CK source folder.
function Get-CkSyncDeclaredModel {
  param([string]$CkPath)
  $file = Join-Path $CkPath 'ckModel.yaml'
  if (-not (Test-Path -LiteralPath $file)) { throw "[CK sync] no ckModel.yaml in '$CkPath'" }
  $text = Get-Content -Raw -LiteralPath $file
  if ($text -notmatch '(?m)^modelId:\s*["'']?([A-Za-z0-9_.]+)-(\d+\.\d+\.\d+)["'']?\s*$') {
    throw "[CK sync] no 'modelId: <Name>-X.Y.Z' in '$file'"
  }
  $name = $Matches[1]; $version = [version]$Matches[2]
  $language = 1
  if ($text -match '(?m)^ckLanguage:\s*(\d+)\s*$') { $language = [int]$Matches[1] }
  return [pscustomobject]@{ Name = $name; Version = $version; CkLanguage = $language; Path = $CkPath }
}

# '<catalog>=<location>;...' over the defaults.
function Get-CkSyncLocations {
  param([string]$Overrides)
  $map = [ordered]@{}
  foreach ($k in $script:CkSyncDefaultLocations.Keys) { $map[$k] = $script:CkSyncDefaultLocations[$k] }
  foreach ($entry in (Split-CkSyncList $Overrides)) {
    $i = $entry.IndexOf('=')
    if ($i -lt 1) { throw "[CK sync] invalid location entry '$entry' (expected <catalog>=<location>)" }
    $map[$entry.Substring(0, $i).Trim()] = $entry.Substring($i + 1).Trim()
  }
  return $map
}

function Get-CkSyncHttpHeaders {
  param([string]$Location)
  $headers = @{ 'User-Agent' = 'octo-ck-sync' }
  if ($Location -like 'github:*') {
    $headers['Accept'] = 'application/vnd.github.raw'
    $headers['X-GitHub-Api-Version'] = '2022-11-28'
    if (-not [string]::IsNullOrWhiteSpace($env:OCTO_CKSYNC_GITHUB_TOKEN) -and
        $env:OCTO_CKSYNC_GITHUB_TOKEN -notmatch '^\$\(.+\)$') {
      $headers['Authorization'] = "Bearer $($env:OCTO_CKSYNC_GITHUB_TOKEN)"
    }
  }
  return $headers
}

# URL (or file path) of a catalog-relative path.
function Get-CkSyncAddress {
  param([string]$Location, [string]$RelativePath)
  $rel = $RelativePath.TrimStart('/')
  if ($Location -like 'dir:*') { return (Join-Path $Location.Substring(4) $rel) }
  if ($Location -like 'pages:*') { return ($Location.Substring(6).TrimEnd('/') + '/' + $rel) }
  if ($Location -match '^github:([^/]+)/([^@]+)@(.+)$') {
    $escaped = ($rel -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    return "https://api.github.com/repos/$($Matches[1])/$($Matches[2])/contents/$($escaped)?ref=$([uri]::EscapeDataString($Matches[3]))"
  }
  throw "[CK sync] unknown location '$Location' (github:<owner>/<repo>@<branch>, pages:<url>, dir:<path>)"
}

# Downloads/copies one catalog file byte for byte. $false = not found (404 / missing file); other errors throw.
function Save-CkSyncFile {
  param([string]$Location, [string]$RelativePath, [string]$OutFile)
  $address = Get-CkSyncAddress $Location $RelativePath
  if ($Location -like 'dir:*') {
    if (-not (Test-Path -LiteralPath $address -PathType Leaf)) { return $false }
    Copy-Item -LiteralPath $address -Destination $OutFile -Force
    return $true
  }
  $attempt = 0
  while ($true) {
    $attempt++
    $response = Invoke-WebRequest -Uri $address -Headers (Get-CkSyncHttpHeaders $Location) -OutFile $OutFile `
      -SkipHttpErrorCheck -PassThru -TimeoutSec 60
    $code = [int]$response.StatusCode
    if ($code -ge 200 -and $code -lt 300) { return $true }
    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    if ($code -eq 404) { return $false }
    if ($attempt -ge 3 -or $code -in 401, 403) {
      throw "[CK sync] reading '$RelativePath' from '$Location' answered HTTP $code"
    }
    Start-Sleep -Seconds (2 * $attempt)
  }
}

function Read-CkSyncJson {
  param([string]$Location, [string]$RelativePath)
  $tmp = Join-Path $script:CkSyncTemp ([guid]::NewGuid().ToString('N') + '.json')
  if (-not (Save-CkSyncFile $Location $RelativePath $tmp)) { return $null }
  try { return (Get-Content -Raw -LiteralPath $tmp | ConvertFrom-Json) }
  finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# Every version of one major of a model in a catalog, both roots: Version, FilePath (catalog-relative), Root.
# A root without catalog.json or without the model contributes nothing; a model index the root lists but the
# location does not answer is an error (a lagging or broken catalog must not look like "nothing published").
# -RequireCatalog (the source): no root index at all is an error too, never "nothing to sync".
function Get-CkSyncVersions {
  param([string]$Location, [string]$ModelName, [int]$Major, [switch]$RequireCatalog)
  $result = @()
  $rootsFound = 0
  foreach ($root in $script:CkSyncRoots) {
    $rootIndex = Read-CkSyncJson $Location ($root + 'catalog.json')
    if ($null -eq $rootIndex) { continue }
    $rootsFound++
    foreach ($model in @($rootIndex.models | Where-Object { [string]::Equals($_.modelName, $ModelName, [StringComparison]::OrdinalIgnoreCase) })) {
      $modelIndex = Read-CkSyncJson $Location $model.catalogPath
      if ($null -eq $modelIndex) { throw "[CK sync] '$Location' lists '$($model.catalogPath)' but does not serve it" }
      foreach ($line in @($modelIndex.majorVersions | Where-Object { [int]$_.majorVersion -eq $Major })) {
        $majorIndex = Read-CkSyncJson $Location $line.catalogPath
        if ($null -eq $majorIndex) { throw "[CK sync] '$Location' lists '$($line.catalogPath)' but does not serve it" }
        foreach ($entry in @($majorIndex.versions)) {
          $v = ConvertTo-CkSyncVersion $entry.version
          if ($null -eq $v -or $v.Major -ne $Major) { continue }
          $result += [pscustomobject]@{ Name = $model.modelName; Version = $v; FilePath = $entry.filePath; Root = $root }
        }
      }
    }
  }
  if ($RequireCatalog -and $rootsFound -eq 0) {
    throw "[CK sync] '$Location' serves no catalog index ($($script:CkSyncRoots -join 'catalog.json, ')catalog.json)"
  }
  return @($result | Sort-Object Version)
}

# The rule: source versions of the declared major strictly between the target baseline and the declared version.
function Select-CkSyncCandidates {
  param([object[]]$SourceVersions, [object[]]$TargetVersions, [version]$Declared)
  $below = @($TargetVersions | Where-Object { $_.Version.Major -eq $Declared.Major -and $_.Version -lt $Declared })
  if ($below.Count -eq 0) { return @() }
  $baseline = ($below | Sort-Object Version | Select-Object -Last 1).Version
  $present = @($TargetVersions | ForEach-Object { $_.Version.ToString() })
  $seen = @{}
  $picked = foreach ($s in @($SourceVersions | Sort-Object Version)) {
    $key = $s.Version.ToString()
    if ($s.Version.Major -ne $Declared.Major -or $s.Version -le $baseline -or $s.Version -ge $Declared) { continue }
    if ($present -contains $key -or $seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
    $s
  }
  return @($picked)
}

function Get-CkSyncAcknowledgementCount {
  param([string]$File)
  $json = Get-Content -Raw -LiteralPath $File | ConvertFrom-Json
  if ($null -eq $json.compatibility -or $null -eq $json.compatibility.acknowledge) { return 0 }
  return @($json.compatibility.acknowledge).Count
}

function Invoke-CkSyncMain {
  $ckPaths = @(Split-CkSyncList $env:OCTO_CKSYNC_CK_PATHS)
  $catalogs = @(Split-CkSyncList $env:OCTO_CKSYNC_CATALOGS)
  $dryRun = Test-CkSyncTrue $env:OCTO_CKSYNC_DRYRUN
  # OCTO_CKSYNC_MODE is for octo-tools only: on a build agent the mode always follows the build (a pipeline variable
  # of that name must not switch the release sync off or down to a report).
  $modeOverride = if (Test-CkSyncTrue $env:TF_BUILD) { '' } else { "$env:OCTO_CKSYNC_MODE" }
  $mode = if (-not [string]::IsNullOrWhiteSpace($modeOverride)) { $modeOverride.Trim().ToLowerInvariant() }
          elseif (Test-CkSyncTrue $env:OCTO_CKSYNC_IS_RELEASE) { 'apply' }
          elseif (Test-CkSyncTrue $env:OCTO_CKSYNC_IS_MAIN) { 'report' }
          else { 'off' }
  if ($mode -eq 'off') { Write-Host '[CK sync] neither a release nor a main build - nothing to do.'; return 0 }
  if ($mode -notin 'apply', 'report') { throw "[CK sync] unknown mode '$mode' (apply, report)" }
  if ($catalogs.Count -eq 0) {
    Write-CkSyncIssue error '[CK sync] OctoPublishCkCatalogs carries no value. Wire update-build-number.yml before this template.'
    return 1
  }
  $source = $catalogs[0]
  $targets = if ($mode -eq 'report') { @('PublicGitHubCatalog') } else { @($catalogs | Select-Object -Skip 1) }
  $targets = @($targets | Where-Object { $_ -ne $source })
  if ($targets.Count -eq 0) { Write-Host "[CK sync] no target catalog besides '$source' - nothing to do."; return 0 }
  $onlyCkLanguage2 = Test-CkSyncTrue $env:OCTO_CKSYNC_ONLY_CKLANGUAGE2

  $locations = Get-CkSyncLocations $env:OCTO_CKSYNC_LOCATIONS
  foreach ($c in @($source) + $targets) {
    if (-not $locations.Contains($c)) { throw "[CK sync] no location for catalog '$c' (set OCTO_CKSYNC_LOCATIONS)" }
  }
  $workDir = if ([string]::IsNullOrWhiteSpace($env:OCTO_CKSYNC_WORKDIR)) { [IO.Path]::GetTempPath() } else { $env:OCTO_CKSYNC_WORKDIR }
  $script:CkSyncTemp = Join-Path $workDir ('octo-ck-sync-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $script:CkSyncTemp | Out-Null

  Write-Host "[CK sync] mode: $mode$(if ($dryRun) { ' (dry run, nothing is written)' }); source: $source ($($locations[$source])); targets: $(($targets | ForEach-Object { "$_ ($($locations[$_]))" }) -join ', ')"
  $failed = 0; $published = 0; $missingTotal = 0
  try {
    foreach ($ckPath in $ckPaths) {
     try {
      $model = Get-CkSyncDeclaredModel $ckPath
      if ($onlyCkLanguage2 -and $model.CkLanguage -lt 2) {
        Write-Host "[CK sync] $($model.Name)-$($model.Version): ckLanguage $($model.CkLanguage), skipped (only ckLanguage 2 models are gated hard)."
        continue
      }
      try { $sourceVersions = Get-CkSyncVersions $locations[$source] $model.Name $model.Version.Major -RequireCatalog }
      catch {
        Write-CkSyncIssue warning "[CK sync] $($model.Name)-$($model.Version): source catalog '$source' unreadable: $($_.Exception.Message). Nothing synced for this model; the publish gate decides."
        continue
      }
      foreach ($target in $targets) {
        $targetLocation = $locations[$target]
        try { $targetVersions = Get-CkSyncVersions $targetLocation $model.Name $model.Version.Major }
        catch {
          Write-CkSyncIssue warning "[CK sync] $($model.Name)-$($model.Version): target catalog '$target' unreadable: $($_.Exception.Message). Nothing synced for this model; the publish gate decides."
          continue
        }
        $missing = @(Select-CkSyncCandidates $sourceVersions $targetVersions $model.Version)
        $baseline = @($targetVersions | Where-Object { $_.Version.Major -eq $model.Version.Major -and $_.Version -lt $model.Version } | Select-Object -Last 1)
        $baselineText = if ($baseline.Count -gt 0) { $baseline[0].Version.ToString() } else { 'none' }
        if ($missing.Count -eq 0) {
          Write-Host "[CK sync] $($model.Name)-$($model.Version) -> ${target}: baseline $baselineText, no intermediate version missing."
          continue
        }
        $missingTotal += $missing.Count
        Write-Host "[CK sync] $($model.Name)-$($model.Version) -> ${target}: baseline $baselineText, missing $(($missing | ForEach-Object { $_.Version }) -join ', ') (held by $source)."
        foreach ($m in $missing) {
          $file = Join-Path $script:CkSyncTemp ([IO.Path]::GetFileName($m.FilePath))
          if (-not (Save-CkSyncFile $locations[$source] $m.FilePath $file)) {
            Write-CkSyncIssue ($(if ($mode -eq 'apply' -and -not $dryRun) { 'error' } else { 'warning' })) "[CK sync] $($m.Name)-$($m.Version): '$($m.FilePath)' is listed in '$source' but could not be read."
            if ($mode -eq 'apply' -and -not $dryRun) { $failed++; break }
            continue
          }
          $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
          if ($mode -eq 'report') {
            $acks = Get-CkSyncAcknowledgementCount $file
            if ($acks -gt 0) {
              Write-CkSyncIssue warning "[CK sync] $($m.Name)-$($m.Version) carries $acks acknowledgement(s) and exists in '$source' only, '$target' lacks it (baseline $baselineText). The next r* tag build publishes it to '$target' before $($model.Name)-$($model.Version) (ck-sync-intermediate-versions.yml); a tag build on an older template pin fails with OCTO-CK203."
            } else {
              Write-Host "[CK sync] $($m.Name)-$($m.Version) exists in '$source' only (no acknowledgements); the next r* tag build syncs it to '$target'."
            }
            continue
          }
          $lcr = if ($targetLocation -like 'dir:*') { $targetLocation.Substring(4) } else { Join-Path $script:CkSyncTemp 'publish-catalog' }
          $publishArgs = @('-c', 'Publish', '-f', $file, '-c', $target, '-lcr', $lcr)
          if ($dryRun) {
            Write-Host "[CK sync] dry run: would publish $($m.Name)-$($m.Version) (sha256 $sha) to ${target}: octo-ckc $($publishArgs -join ' ')"
            continue
          }
          if ($targetLocation -notlike 'dir:*') { New-Item -ItemType Directory -Force -Path $lcr | Out-Null }
          $ckc = if ([string]::IsNullOrWhiteSpace($env:OCTO_CKSYNC_CKC)) { 'octo-ckc' } else { $env:OCTO_CKSYNC_CKC }
          Write-Host "[CK sync] publishing $($m.Name)-$($m.Version) (sha256 $sha) to $target ..."
          $output = & $ckc @publishArgs 2>&1
          $exit = $LASTEXITCODE
          $output | Out-Host
          $text = ($output | Out-String)
          if ($exit -ne 0 -and ($text -match '\[compat gate\]' -or $text -notmatch [regex]::Escape("already exists in catalog '$target'"))) {
            Write-CkSyncIssue error "[CK sync] octo-ckc Publish refused $($m.Name)-$($m.Version) for '$target' (exit $exit); see the lines above (a '[compat gate] OCTO-CK2xx' line names the next step). Later versions of the line were not published. Next step: fix the reason, then re-run the job."
            $failed++
            break
          }
          # Read back what the target holds now; a version that cannot be read back or differs stops the line.
          $check = Join-Path $script:CkSyncTemp ('check-' + [IO.Path]::GetFileName($m.FilePath))
          $relTarget = $m.FilePath
          $readBack = $false
          for ($attempt = 1; $attempt -le 3 -and -not $readBack; $attempt++) {
            $readBack = Save-CkSyncFile $targetLocation $relTarget $check
            if (-not $readBack -and $targetLocation -notlike 'dir:*' -and $attempt -lt 3) { Start-Sleep -Seconds 5 }
          }
          if (-not $readBack) {
            Write-CkSyncIssue error "[CK sync] $($m.Name)-$($m.Version): '$target' does not serve '$relTarget' after the publish; the version is not verified. Later versions of the line were not published. Next step: check the catalog, then re-run the job."
            $failed++
            break
          }
          $targetSha = (Get-FileHash -LiteralPath $check -Algorithm SHA256).Hash.ToLowerInvariant()
          if ($targetSha -ne $sha) {
            Write-CkSyncIssue error "[CK sync] $($m.Name)-$($m.Version) in '$target' differs from '$source' (sha256 $targetSha vs. $sha)."
            $failed++
            break
          }
          Write-Host "[CK sync] $($m.Name)-$($m.Version) is in $target, byte-identical (sha256 $sha)."
          $published++
        }
      }
     } catch {
      # report (main) never fails the build; apply (r* tag) stops on anything unexpected.
      if ($mode -eq 'report' -or $dryRun) {
        Write-CkSyncIssue warning "[CK sync] '$ckPath': $($_.Exception.Message). Nothing reported for this model."
      } else {
        Write-CkSyncIssue error "[CK sync] '$ckPath': $($_.Exception.Message). Nothing further published for this model."
        $failed++
      }
     }
    }
  } finally {
    Remove-Item -LiteralPath $script:CkSyncTemp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if ($failed -gt 0) { return 1 }
  Write-Host "[CK sync] done: $missingTotal missing version(s), $published published$(if ($dryRun) { ' (dry run)' })."
  return 0
}

if ($env:OCTO_CKSYNC_SELFTEST -ne '1') {
  if (-not [string]::IsNullOrWhiteSpace($env:OCTO_CKSYNC_CKC_HOME) -and $env:OCTO_CKSYNC_CKC_HOME -notmatch '^\$\(.+\)$') {
    # The validate step keeps octo-ckc's settings.json (catalog tokens) in a job-temp home.
    $env:HOME = $env:OCTO_CKSYNC_CKC_HOME
    $env:USERPROFILE = $env:OCTO_CKSYNC_CKC_HOME
  }
  exit (Invoke-CkSyncMain)
}
