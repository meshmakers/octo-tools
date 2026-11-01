# Stand-in for octo-ckc in tests/ck-sync-intermediate-versions.Tests.ps1 (and the octo-tools copy of the test).
# Logs every call to $env:STUB_LOG. `-c Publish -f <file> -c <catalog> -lcr <dir>`:
#   STUB_PUBLISH_EXIT (default 0) != 0 -> prints $env:STUB_PUBLISH_OUTPUT and exits with that code, writes nothing;
#   STUB_NO_WRITE=1 -> exits 0 and writes nothing (a publish whose result cannot be read back);
#   STUB_ALREADY_EXISTS=1 -> writes like below, then prints "... already exists in catalog '<catalog>'" and exits 250;
#   otherwise copies <file> byte for byte into <dir>/<root>/<letter>/<Name>/<major>/ (root from the file: ckLanguage 2
#   or dependencyRanges/minEngineVersion -> ck-models/v3/, else ck-models/v2/) and adds it to the three index levels,
#   like the LocalFileSystemCatalog does.
$ErrorActionPreference = 'Stop'
Add-Content -LiteralPath $env:STUB_LOG -Value ($args -join ' ')
$cmd = $null; $file = $null; $catalog = $null; $lcr = $null
for ($i = 0; $i -lt $args.Count; $i++) {
  switch ($args[$i]) {
    '-c' { if ($null -eq $cmd) { $cmd = $args[$i + 1] } else { $catalog = $args[$i + 1] }; $i++ }
    '-f' { $file = $args[$i + 1]; $i++ }
    '-lcr' { $lcr = $args[$i + 1]; $i++ }
  }
}
if ($cmd -ne 'Publish') { exit 0 }
$code = if ($env:STUB_PUBLISH_EXIT) { [int]$env:STUB_PUBLISH_EXIT } else { 0 }
if ($code -ne 0) { Write-Output $env:STUB_PUBLISH_OUTPUT; exit $code }
if ($env:STUB_NO_WRITE -eq '1') { Write-Output 'Construction kit model published'; exit 0 }
$json = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
$name, $version = $json.modelId -split '-(?=\d+\.\d+\.\d+$)'
$major = ([version]$version).Major
$root = if ($json.ckLanguage -ge 2 -or $json.dependencyRanges -or $json.minEngineVersion) { 'ck-models/v3' } else { 'ck-models/v2' }
$rel = "$root/$($name.Substring(0,1).ToLower())/$name/$major"
$dir = Join-Path $lcr $rel
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$fileName = "ck-$($name.ToLower())-$version.json"
Copy-Item -LiteralPath $file -Destination (Join-Path $dir $fileName) -Force
function Read-Index($path, $default) { if (Test-Path $path) { Get-Content -Raw $path | ConvertFrom-Json -AsHashtable } else { $default } }
$rootIdxPath = Join-Path $lcr "$root/catalog.json"
$rootIdx = Read-Index $rootIdxPath @{ version = '1.0'; models = @() }
if (-not ($rootIdx.models | Where-Object { $_.modelName -eq $name })) { $rootIdx.models += @{ modelName = $name; catalogPath = "$root/$($name.Substring(0,1).ToLower())/$name/catalog.json" } }
$rootIdx | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rootIdxPath
$modelIdxPath = Join-Path $lcr "$root/$($name.Substring(0,1).ToLower())/$name/catalog.json"
$modelIdx = Read-Index $modelIdxPath @{ version = '1.0'; modelId = $name; majorVersions = @() }
if (-not ($modelIdx.majorVersions | Where-Object { $_.majorVersion -eq $major })) { $modelIdx.majorVersions += @{ majorVersion = $major; catalogPath = "$rel/catalog.json" } }
$modelIdx | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $modelIdxPath
$majorIdxPath = Join-Path $dir 'catalog.json'
$majorIdx = Read-Index $majorIdxPath @{ version = '1.0'; modelId = $name; majorVersion = $major; versions = @() }
$majorIdx.versions = @($majorIdx.versions) + @(@{ version = $version; fileName = $fileName; filePath = "$rel/$fileName" })
$majorIdx | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $majorIdxPath
if ($env:STUB_ALREADY_EXISTS -eq '1') { Write-Output "Model '$name-$version' already exists in catalog '$catalog'"; exit 250 }
Write-Output "Construction kit model published"
exit 0
