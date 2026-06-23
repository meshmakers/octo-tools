function Get-AllGitRepStatus {
    param(
        [string]$branch = "",
        # Skip the network fetch and compare against last-known refs only (instant, offline).
        [switch]$NoFetch,
        # Emit the per-repo status as a single JSON document instead of the colored table.
        [switch]$Json
    )

    # The status line uses Unicode glyphs (arrows / check mark). macOS, Linux and pwsh 7
    # consoles are UTF-8 already, but legacy Windows PowerShell consoles often aren't and
    # would render the glyphs as garbage - force UTF-8 output when that's the case.
    if ([Console]::OutputEncoding.WebName -ne 'utf-8') {
        try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch { }
    }

    # Accumulates one record per repo/submodule for -Json output. The recursive helper below mutates
    # this shared list (List[T].Add returns void, so it never leaks onto the success stream).
    $repoRecords = [System.Collections.Generic.List[object]]::new()

    function Check-GitStatusRecursively($path, $indentLevel = 0) {
        Push-Location $path

        $statusOutput = git status --porcelain
        # Try to determine branch name safely, especially for submodules
        # 1. symbolic-ref for normal branches
        # 2. describe for exact tag or ref fallback
        # 3. rev-parse as last resort for short commit hash
        $branchName = git symbolic-ref --short HEAD 2>$null
        if (-not $branchName) {
            $branchName = git describe --all --exact-match 2>$null
        }
        if (-not $branchName) {
            $branchName = git rev-parse --short HEAD
        }
        $repoName = Split-Path -Leaf (Get-Location)

        # Morning sync check: how does this checkout compare to its remote(s)?
        # The fetch happens once, in parallel, before this render pass (see bottom of the
        # function), so the refs below are already warm. Comparisons are local and fast; they
        # fall back to last-known refs when -NoFetch is used or a fetch failed (offline / no remote).

        # Distance from the branch's own upstream (origin/<branch>): what to pull / push.
        $behindUpstream = $null   # remote has commits I don't -> pull
        $aheadUpstream = $null    # I have commits the remote doesn't -> push
        $hasUpstream = $false
        git rev-parse --abbrev-ref --symbolic-full-name '@{u}' *> $null
        if ($LASTEXITCODE -eq 0) {
            $hasUpstream = $true
            $behindUpstream = [int](git rev-list --count 'HEAD..@{u}' 2>$null)
            $aheadUpstream = [int](git rev-list --count '@{u}..HEAD' 2>$null)
        }

        # For feature branches: how far has origin/main moved on since we branched.
        # On main/master this is already covered by the upstream check above.
        $behindMain = 0
        if ($branchName -ne "main" -and $branchName -ne "master") {
            git rev-parse --verify --quiet origin/main *> $null
            if ($LASTEXITCODE -eq 0) {
                $behindMain = [int](git rev-list --count HEAD..origin/main 2>$null)
            }
        }

        if ($statusOutput) {
            $status = "Dirty"
        }
        else {
            $status = "Clean"
        }

        # Build the compact sync tags:  ⇣N (pull)  ⇡N (push)  main+N  (no upstream)
        $tags = @()
        if ($behindUpstream -gt 0) { $tags += "$([char]0x21E3)$behindUpstream" }
        if ($aheadUpstream -gt 0) { $tags += "$([char]0x21E1)$aheadUpstream" }
        if ($behindMain -gt 0) { $tags += "main+$behindMain" }
        if (-not $hasUpstream) { $tags += "(no upstream)" }

        $outOfSync = $tags.Count -gt 0

        # Colour: dirty = red (most urgent), out of sync = yellow, clean & in sync = green.
        if ($status -eq "Dirty") {
            $color = "Red"
        }
        elseif ($outOfSync) {
            $color = "Yellow"
        }
        else {
            $color = "Green"
        }

        if ($indentLevel -gt 0) {
            $indent = ('-' * 8 * $indentLevel) + "> "
        }
        else {
            $indent = ""
        }

        if ($outOfSync) {
            $syncField = $tags -join " "
        }
        else {
            $syncField = "$([char]0x2713) up to date"
        }

        # Build the structured record regardless of render mode (so -Json gets the same data).
        $dirtyFiles = @()
        if ($status -eq "Dirty" -and $statusOutput) {
            $dirtyFiles = @($statusOutput | ForEach-Object { $_.Trim() })
        }
        $repoRecords.Add([pscustomobject]@{
            repo           = $repoName
            branch         = $branchName
            status         = $status
            behindUpstream = if ($null -ne $behindUpstream) { [int]$behindUpstream } else { $null }
            aheadUpstream  = if ($null -ne $aheadUpstream) { [int]$aheadUpstream } else { $null }
            behindMain     = [int]$behindMain
            hasUpstream    = [bool]$hasUpstream
            outOfSync      = [bool]$outOfSync
            isSubmodule    = $indentLevel -gt 0
            dirtyFiles     = $dirtyFiles
        })

        if (-not $Json) {
            $statusField = "[$status]".PadRight(10)
            $repoField = $repoName.PadRight(60 - $indent.Length)
            $branchField = "($branchName)".PadRight(40)

            Write-Host "$statusField $indent$repoField$branchField $syncField" -ForegroundColor $color

            if ($status -eq "Dirty") {
                $statusOutput | ForEach-Object {
                    Write-Host "$indent`t$_" -ForegroundColor DarkGray
                }
            }
        }

        # Recurse into submodules if any
        if (Test-Path ".gitmodules") {
            $submodules = git config --file .gitmodules --get-regexp path | ForEach-Object { $_.Split(" ")[1] }
            foreach ($submodule in $submodules) {
                $submodulePath = Join-Path -Path (Get-Location) -ChildPath $submodule
                if (Test-Path $submodulePath) {
                    Check-GitStatusRecursively -path $submodulePath -indentLevel ($indentLevel + 1)
                }
            }
        }

        Pop-Location
    }

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-"
    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $allDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"

    $gitRepos = $allDirectories | Where-Object {
        Test-Path -Path (Join-Path -Path $_.FullName -ChildPath ".git") -PathType Container
    }

    # The network fetch is the slow part, so do it for all repos up front and in parallel
    # rather than once per repo serially (which dominated the runtime). Each fetch grabs only
    # what we compare against - origin/main and the repo's current branch - and stays quiet on
    # failure so the render still works against last-known refs.
    if (-not $NoFetch) {
        $repoPaths = @($gitRepos.FullName)
        $total = $repoPaths.Count
        $done = 0
        Write-Progress -Activity "Fetching from origin" -Status "0/$total" -PercentComplete 0
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            # Each parallel fetch emits its repo name as it finishes; the downstream loop runs
            # in this runspace and advances the progress bar so the user sees it working.
            $repoPaths | ForEach-Object -ThrottleLimit 10 -Parallel {
                Push-Location $_
                $br = git symbolic-ref --short HEAD 2>$null
                if ($br) { git fetch origin main $br --quiet 2>$null }
                else { git fetch origin main --quiet 2>$null }
                Pop-Location
                Split-Path -Leaf $_
            } | ForEach-Object {
                $done++
                Write-Progress -Activity "Fetching from origin" -Status "$done/$total  $_" -PercentComplete ($done / $total * 100)
            }
        }
        else {
            # Windows PowerShell 5.1 has no -Parallel; fall back to a serial fetch.
            foreach ($repoPath in $repoPaths) {
                $done++
                Write-Progress -Activity "Fetching from origin" -Status "$done/$total  $(Split-Path -Leaf $repoPath)" -PercentComplete ($done / $total * 100)
                Push-Location $repoPath
                $br = git symbolic-ref --short HEAD 2>$null
                if ($br) { git fetch origin main $br --quiet 2>$null }
                else { git fetch origin main --quiet 2>$null }
                Pop-Location
            }
        }
        Write-Progress -Activity "Fetching from origin" -Completed
    }

    foreach ($directory in $gitRepos) {
        Check-GitStatusRecursively -path $directory.FullName
        if (-not $Json) { Write-Host "" }
    }

    if ($Json) {
        Write-OctoJson -Command 'Get-AllGitRepStatus' -Data @($repoRecords)
        return
    }
}

Export-ModuleMember -Function @('Get-AllGitRepStatus')
