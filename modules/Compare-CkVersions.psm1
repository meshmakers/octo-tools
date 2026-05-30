#region Private helpers

function Find-CkModelFile {
    <#
    .SYNOPSIS
        Iteratively finds every ckModel.yaml under a root, pruning build/output folders.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $excluded = @('node_modules', 'bin', 'obj', '.git', '.vs', '.idea')
    $found = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()

        $candidate = Join-Path $dir 'ckModel.yaml'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $found.Add($candidate)
        }

        try {
            Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($excluded -notcontains $_.Name) {
                        $stack.Push($_.FullName)
                    }
                }
        }
        catch {
            # Unreadable directory — skip it.
        }
    }

    return $found
}

function Read-CkModelId {
    <#
    .SYNOPSIS
        Reads the `modelId:` value from a ckModel.yaml (quoted or unquoted), ignoring comments.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $match = Select-String -LiteralPath $FilePath -Pattern '^\s*modelId:' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $match) { return $null }

    if ($match.Line -match '^\s*modelId:\s*["'']?([^"''#]+?)["'']?\s*(#.*)?$') {
        return $Matches[1].Trim()
    }
    return $null
}

function ConvertTo-CkModelInfo {
    <#
    .SYNOPSIS
        Splits a modelId ("System.Bot-3.1.1") into a name and a (major/minor/patch) version.
        Models without a trailing version (e.g. "System.Sdk") get HasVersion = $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ModelId,
        [Parameter(Mandatory = $true)][string]$File
    )

    if ($ModelId -match '^(?<name>.+)-(?<ver>\d+\.\d+(?:\.\d+)?)(?<rest>.*)$') {
        $parts = $Matches['ver'].Split('.')
        return [PSCustomObject]@{
            Name       = $Matches['name']
            Version    = $Matches['ver'] + $Matches['rest']
            Major      = [int]$parts[0]
            Minor      = [int]$parts[1]
            Patch      = if ($parts.Count -ge 3) { [int]$parts[2] } else { 0 }
            HasVersion = $true
            File       = $File
        }
    }

    return [PSCustomObject]@{
        Name       = $ModelId
        Version    = $null
        Major      = 0
        Minor      = 0
        Patch      = 0
        HasVersion = $false
        File       = $File
    }
}

function Compare-CkVersionInfo {
    <#
    .SYNOPSIS
        Orders two model infos by version. Returns -1, 0 or 1 (used to keep the highest duplicate).
    #>
    [CmdletBinding()]
    param($A, $B)

    if ($A.HasVersion -and $B.HasVersion) {
        if ($A.Major -ne $B.Major) { return [Math]::Sign($A.Major - $B.Major) }
        if ($A.Minor -ne $B.Minor) { return [Math]::Sign($A.Minor - $B.Minor) }
        if ($A.Patch -ne $B.Patch) { return [Math]::Sign($A.Patch - $B.Patch) }
        return 0
    }

    $av = if ($A.HasVersion) { $A.Version } else { '' }
    $bv = if ($B.HasVersion) { $B.Version } else { '' }
    return [string]::Compare($av, $bv, $true)
}

function Get-CkModelMap {
    <#
    .SYNOPSIS
        Builds a name -> model-info map for one branch root, keeping the highest version per name.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)

    $map = @{}
    foreach ($file in (Find-CkModelFile -Root $Root)) {
        $modelId = Read-CkModelId -FilePath $file
        if ([string]::IsNullOrWhiteSpace($modelId)) { continue }

        $info = ConvertTo-CkModelInfo -ModelId $modelId -File $file
        if ($map.ContainsKey($info.Name)) {
            if ((Compare-CkVersionInfo $info $map[$info.Name]) -gt 0) {
                $map[$info.Name] = $info
            }
        }
        else {
            $map[$info.Name] = $info
        }
    }
    return $map
}

function Resolve-CkBranchRoot {
    <#
    .SYNOPSIS
        Resolves a branch argument relative to the current checkout root (like the other modules'
        -branch parameter). An empty argument resolves to the root itself.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PathArg,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($PathArg)) { $RootPath } else { Join-Path $RootPath $PathArg }
    try {
        return (Resolve-Path -Path $candidate -ErrorAction Stop).Path
    }
    catch {
        Write-Error "$Label branch path not found: '$PathArg' (resolved relative to $RootPath -> $candidate)"
        return $null
    }
}

#endregion

function Compare-CkVersions {
    <#
    .SYNOPSIS
    Compares the Construction Kit (CK) model versions available in two branch checkouts.

    .DESCRIPTION
    Scans both branch folders for `ckModel.yaml` files, extracts each model's id (name + version),
    and compares the versions per model. Results are grouped — System Construction Kits first, then
    the rest — and color coded:

        green   identical version
        yellow  same major version, but minor or patch differs
        red     major version differs
        cyan    model exists in only one of the two branches

    Both branch arguments are resolved relative to `$Global:ROOTPATH` (the current checkout root
    that `profile.ps1` sets), mirroring the `-branch` convention of the other octo-tools modules.
    So from a per-branch checkout you compare against a sibling with `../main`, and from an
    above-branches checkout against a subfolder with `branches/test`.

    Discovery only parses the `modelId:` line of each `ckModel.yaml`, so no YAML module is required.
    `bin`, `obj`, `node_modules` and `.git` folders are skipped. When a model name appears more than
    once inside one branch (for example several `Test-*` test projects), the highest version wins.

    .PARAMETER OtherBranch
    Path to the other branch checkout to compare the current checkout against, resolved relative to
    `$Global:ROOTPATH`. Examples: `../main`, `branches/test`, or an absolute path.

    .PARAMETER Branch
    Path to the subject branch checkout, resolved relative to `$Global:ROOTPATH`. Defaults to the
    current checkout (`$Global:ROOTPATH`).

    .PARAMETER Details
    Also print the source `ckModel.yaml` path for each model.

    .EXAMPLE
    Compare-CkVersions ../main
    # From a per-branch checkout (e.g. branches/test) compares the current checkout against branches/main.

    .EXAMPLE
    Compare-CkVersions branches/test
    # From an above-branches checkout compares the current checkout against branches/test.

    .EXAMPLE
    Compare-CkVersions ../featureB -Branch ../featureA
    # Compares two other branch checkouts against each other.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$OtherBranch,

        [Parameter(Position = 1)]
        [string]$Branch = '',

        [switch]$Details
    )

    $rootPath = $Global:ROOTPATH
    if (-not $rootPath) {
        Write-Error 'Global:ROOTPATH is not set. Load octo-tools/modules/profile.ps1 first.'
        return
    }

    $subjectRoot = Resolve-CkBranchRoot -RootPath $rootPath -PathArg $Branch -Label 'Subject'
    if (-not $subjectRoot) { return }
    $otherRoot = Resolve-CkBranchRoot -RootPath $rootPath -PathArg $OtherBranch -Label 'Other'
    if (-not $otherRoot) { return }

    if ($subjectRoot -ieq $otherRoot) {
        Write-Host "Both paths resolve to the same folder ($subjectRoot) - nothing to compare." -ForegroundColor Yellow
        return
    }

    $subjectName = Split-Path -Leaf $subjectRoot
    $otherName = Split-Path -Leaf $otherRoot

    Write-Host ''
    Write-Host 'Construction Kit Version Comparison' -ForegroundColor Cyan
    Write-Host '===================================' -ForegroundColor Cyan
    Write-Host ("  left  : {0}  ({1})" -f $subjectName, $subjectRoot) -ForegroundColor Gray
    Write-Host ("  right : {0}  ({1})" -f $otherName, $otherRoot) -ForegroundColor Gray
    Write-Host ''

    $subjectMap = Get-CkModelMap -Root $subjectRoot
    $otherMap = Get-CkModelMap -Root $otherRoot

    $allNames = @($subjectMap.Keys) + @($otherMap.Keys) | Sort-Object -Unique
    if ($allNames.Count -eq 0) {
        Write-Host 'No ckModel.yaml files found in either branch.' -ForegroundColor Yellow
        return
    }

    # Build comparison rows.
    $rows = foreach ($name in $allNames) {
        $left = $subjectMap[$name]
        $right = $otherMap[$name]

        if (($null -ne $left) -and ($null -ne $right)) {
            if ($left.HasVersion -and $right.HasVersion) {
                if ($left.Major -ne $right.Major) {
                    $state = 'Major'
                }
                elseif (($left.Minor -ne $right.Minor) -or ($left.Patch -ne $right.Patch)) {
                    $state = 'Minor'
                }
                else {
                    $state = 'Equal'
                }
            }
            else {
                $lv = if ($left.HasVersion) { $left.Version } else { '' }
                $rv = if ($right.HasVersion) { $right.Version } else { '' }
                $state = if ($lv -eq $rv) { 'Equal' } else { 'Minor' }
            }
        }
        elseif ($null -ne $left) {
            $state = 'OnlyLeft'
        }
        else {
            $state = 'OnlyRight'
        }

        [PSCustomObject]@{
            Name     = $name
            Left     = $left
            Right    = $right
            State    = $state
            IsSystem = $name -like 'System*'
        }
    }

    # Column widths over all rows for aligned output.
    $fmtVer = {
        param($info)
        if ($null -eq $info) { '(missing)' }
        elseif ($info.HasVersion) { $info.Version }
        else { '(no version)' }
    }
    $nameWidth = ($rows | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    $verWidth = ($rows | ForEach-Object {
            [Math]::Max((& $fmtVer $_.Left).Length, (& $fmtVer $_.Right).Length)
        } | Measure-Object -Maximum).Maximum

    $writeGroup = {
        param([string]$Title, [object[]]$GroupRows)
        if (-not $GroupRows -or $GroupRows.Count -eq 0) { return }

        Write-Host $Title -ForegroundColor White
        foreach ($r in ($GroupRows | Sort-Object Name)) {
            $color = switch ($r.State) {
                'Equal' { 'Green' }
                'Minor' { 'Yellow' }
                'Major' { 'Red' }
                default { 'Cyan' }
            }
            $marker = switch ($r.State) {
                'Equal' { [char]0x2713 }   # check
                'Minor' { [char]0x26A0 }   # warning
                'Major' { [char]0x2717 }   # cross
                default { [char]0x2205 }   # empty set (only in one branch)
            }
            $lv = (& $fmtVer $r.Left).PadRight($verWidth)
            $rv = (& $fmtVer $r.Right).PadRight($verWidth)
            $line = "  {0}  {1} -> {2}  {3}" -f $r.Name.PadRight($nameWidth), $lv, $rv, $marker
            Write-Host $line -ForegroundColor $color

            if ($Details) {
                if ($null -ne $r.Left) { Write-Host ("      L: {0}" -f $r.Left.File) -ForegroundColor DarkGray }
                if ($null -ne $r.Right) { Write-Host ("      R: {0}" -f $r.Right.File) -ForegroundColor DarkGray }
            }
        }
        Write-Host ''
    }

    & $writeGroup 'System Construction Kits' @($rows | Where-Object { $_.IsSystem })
    & $writeGroup 'Other Construction Kits' @($rows | Where-Object { -not $_.IsSystem })

    # Summary.
    $equal = @($rows | Where-Object { $_.State -eq 'Equal' }).Count
    $minor = @($rows | Where-Object { $_.State -eq 'Minor' }).Count
    $major = @($rows | Where-Object { $_.State -eq 'Major' }).Count
    $only = @($rows | Where-Object { $_.State -in 'OnlyLeft', 'OnlyRight' }).Count

    Write-Host 'Summary' -ForegroundColor Cyan
    Write-Host '=======' -ForegroundColor Cyan
    Write-Host ("  {0,-14}{1}" -f 'models total:', $rows.Count)
    Write-Host ("  {0,-14}{1}" -f 'equal:', $equal) -ForegroundColor Green
    if ($minor -gt 0) { Write-Host ("  {0,-14}{1}" -f 'minor/patch:', $minor) -ForegroundColor Yellow }
    if ($major -gt 0) { Write-Host ("  {0,-14}{1}" -f 'major:', $major) -ForegroundColor Red }
    if ($only -gt 0) { Write-Host ("  {0,-14}{1}" -f 'only in one:', $only) -ForegroundColor Cyan }
    Write-Host ''

    $global:LASTEXITCODE = $minor + $major + $only
}

Export-ModuleMember -Function @('Compare-CkVersions')
