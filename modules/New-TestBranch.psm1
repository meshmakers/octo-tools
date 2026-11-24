<#
.Synopsis
Creates a test branch for all repositories of Invoke-CloneMainRepos
.Description
This function creates a test branch with format test/0.x-word in every repository of the checkout directory
that Invoke-CloneMainRepos clones (mm-common and the other non octo-* repositories included; repositories the
directory does not hold are skipped).
Directory: without -branch the directory is <parent of rootPath>/0.<n>-<description> (e.g. meshmakers/0.3-demo);
an explicit -branch (relative to rootPath) is used as given, so existing checkouts such as dev or demo keep working.
Base: every repository runs 'git fetch origin' and the branch starts explicitly from origin/main, never from
whatever is checked out. A repository with uncommitted changes to tracked files is not branched; it is listed
with its reason (console and -Json) and the cmdlet ends with a terminating error (non-zero exit code of `pwsh -Command`). A branch that already exists
(locally or on origin) is switched to, not recreated.
Branch naming rules:
- Prefix 'test/' is mandatory
- Major version must be 0
- Minor version range: 2-999
- Description must be a single word (letters, numbers, underscore only)
- Separator '-' between version and description is mandatory
No files in the repositories will be modified.
.Example
New-TestBranch -MinorVersion 5 -Description "queries"
# Creates branch test/0.5-queries from origin/main in <parent of rootPath>/0.5-queries
.Example
New-TestBranch -MinorVersion 12 -Description "my_feature" -NoPush
# Creates branch test/0.12-my_feature (local only)
.Example
New-TestBranch -MinorVersion 5 -Description "queries" -branch "branches/queries"
# Creates branch test/0.5-queries in subdirectory branches/queries
.Parameter MinorVersion
The minor version number (2-999) to use in branch name. Major version is always 0.
.Parameter Description
A single word (letters, numbers, underscore only) to append to branch name
.Parameter branch
Optional folder relative to rootPath where the repositories are located. Without it the directory
<parent of rootPath>/0.<n>-<description> is used.
.Parameter NoPush
Skip pushing the branch to remote origin
#>
function New-TestBranch {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(2, 999)]
        [int]$MinorVersion,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-zA-Z0-9_]+$')]
        [ValidateScript({
            if ($_ -match '\s') {
                throw "Description must be a single word without spaces"
            }
            if ($_ -match '-') {
                throw "Description must not contain hyphens"
            }
            return $true
        })]
        [string]$Description,

        [Parameter(Mandatory = $false)]
        [string]$branch = "",

        [Parameter(Mandatory = $false)]
        [switch]$NoPush,

        [switch]$Json
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    # Without -branch: <parent of rootPath>/0.<n>-<description> (AB#9259); an explicit -branch is relative to rootPath.
    $branchRootPath = Resolve-OctoTestBranchRoot -MinorVersion $MinorVersion -Description $Description -Branch $branch -RootPath $rootPath

    if (!(Test-Path $branchRootPath)) {
        Write-Error "Branch root path $branchRootPath does not exist (clone it first: Invoke-CloneMainRepos -branch <path relative to rootPath>)"
        return
    }

    $branchName = "test/0.$MinorVersion-$Description"
    $status = [ordered]@{}

    if (-not $Json) { Write-Host "Creating test branch '$branchName' in '$branchRootPath'" -ForegroundColor Cyan }

    foreach ($directory in @(Get-OctoTestBranchRepoDirectories -Root $branchRootPath)) {
        $path = $directory.FullName
        $directoryName = $directory.Name
        if (-not $Json) { Write-Host "Processing repository $directoryName" -ForegroundColor Green }

        try {
            # Fresh remote state: the branch starts from origin/main, not from what is checked out
            git -C $path fetch origin 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to fetch from origin" }
            # 'fetch origin' follows remote.origin.fetch and may leave origin/main stale: fetch the base explicitly
            git -C $path fetch origin '+refs/heads/main:refs/remotes/origin/main' 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                git -C $path fetch origin '+refs/heads/master:refs/remotes/origin/master' 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Failed to fetch origin/main (or origin/master)" }
            }

            # Tracked changes would be carried onto the new branch (or block the switch): report, do not branch
            # A repository already on the line branch needs no switch: its edits stay where they are (rerun to publish)
            $current = git -C $path branch --show-current 2>$null
            $dirty = @(git -C $path status --porcelain --untracked-files=no 2>$null)
            if ($dirty.Count -gt 0 -and $current -ne $branchName) {
                if (-not $Json) { Write-Host "  Uncommitted changes on '$current' - not branched" -ForegroundColor Red }
                $status[$directoryName] = @{ Success = $false; Existed = $false; Status = 'Dirty'; Reason = "uncommitted changes ($($dirty.Count) file(s)) on branch '$current'" }
                continue
            }

            if (-not $PSCmdlet.ShouldProcess("$directoryName", "Create or switch to branch '$branchName' from origin/main" + $(if ($NoPush) { '' } else { ' and push it' }))) {
                $status[$directoryName] = @{ Success = $true; Existed = $false; Status = 'Skipped'; Reason = 'WhatIf' }
                continue
            }

            $remoteBranchExists = [bool](git -C $path ls-remote --heads origin $branchName 2>$null)
            $localBranchExists = [bool](git -C $path branch --list $branchName 2>$null)

            if ($localBranchExists -and -not $remoteBranchExists) {
                # Published once (it has an upstream) and deleted on origin since: republishing would recreate the line
                # on an outdated base instead of a fresh origin/main. Only a -NoPush branch (never published) is pushed.
                $upstreamRemote = git -C $path config --get "branch.$branchName.remote" 2>$null
                if ($upstreamRemote) {
                    if (-not $Json) { Write-Host "  Local '$branchName' was published and deleted on origin - not republished" -ForegroundColor Red }
                    $status[$directoryName] = @{ Success = $false; Existed = $true; Status = 'Stale'; Reason = "local branch '$branchName' tracks '$upstreamRemote' but no longer exists there; delete it (git branch -D $branchName) and run again to branch from origin/main" }
                    continue
                }
            }

            if ($remoteBranchExists -or $localBranchExists) {
                if (-not $localBranchExists) {
                    git -C $path checkout -b $branchName --track "origin/$branchName" 2>&1 | Out-Null
                } else {
                    git -C $path checkout $branchName 2>&1 | Out-Null
                }
                if ($LASTEXITCODE -ne 0) { throw "Failed to checkout branch $branchName" }
                if (-not $Json) { Write-Host "  Switched to existing branch '$branchName'" -ForegroundColor Blue }
                # A branch made earlier with -NoPush is published by a later run without it
                if (-not $remoteBranchExists -and -not $NoPush) {
                    git -C $path push -u origin $branchName 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Failed to push branch $branchName to origin" }
                    if (-not $Json) { Write-Host "  Local branch pushed to origin" -ForegroundColor Green }
                }
                $status[$directoryName] = @{ Success = $true; Existed = $true; Status = 'Switched'; Reason = '' }
                continue
            }

            $base = $null
            foreach ($candidate in @('main', 'master')) {
                git -C $path rev-parse --verify --quiet "refs/remotes/origin/$candidate" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $base = "origin/$candidate"; break }
            }
            if (-not $base) { throw "No origin/main or origin/master found" }

            git -C $path checkout -b $branchName --no-track $base 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to create branch $branchName from $base" }
            if (-not $Json) { Write-Host "  Branch '$branchName' created from $base" -ForegroundColor Blue }

            if (-not $NoPush) {
                git -C $path push -u origin $branchName 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Failed to push branch $branchName to origin" }
                if (-not $Json) { Write-Host "  Branch pushed successfully" -ForegroundColor Green }
            }
            $status[$directoryName] = @{ Success = $true; Existed = $false; Status = 'Created'; Reason = '' }
        } catch {
            if (-not $Json) { Write-Host "Error processing repository $directoryName : $_" -ForegroundColor Red }
            $status[$directoryName] = @{ Success = $false; Existed = $false; Status = 'Failed'; Reason = "$_" }
        }
    }

    # Summary
    $createdCount = 0
    $switchedCount = 0
    $failedCount = 0
    $dirtyCount = 0

    if (-not $Json) {
        Write-Host ""
        Write-Host "Branch summary:" -ForegroundColor Cyan
    }

    foreach ($key in $status.Keys) {
        $repoStatus = $status[$key]
        switch ($repoStatus.Status) {
            'Created' {
                if (-not $Json) {
                    $pushStatus = if ($NoPush) { "(local only)" } else { "and pushed" }
                    Write-Host "  OK $key - Branch '$branchName' created $pushStatus" -ForegroundColor Green
                }
                $createdCount++
            }
            'Switched' {
                if (-not $Json) { Write-Host "  OK $key - Switched to existing branch '$branchName'" -ForegroundColor Yellow }
                $switchedCount++
            }
            'Skipped' {
                if (-not $Json) { Write-Host "  -- $key - Skipped ($($repoStatus.Reason))" -ForegroundColor Gray }
            }
            'Dirty' {
                if (-not $Json) { Write-Host "  !! $key - Not branched: $($repoStatus.Reason)" -ForegroundColor Red }
                $dirtyCount++
            }
            default {
                if (-not $Json) { Write-Host "  !! $key - Failed: $($repoStatus.Reason)" -ForegroundColor Red }
                $failedCount++
            }
        }
    }

    $problems = $dirtyCount + $failedCount
    $global:LASTEXITCODE = if ($problems -gt 0) { 1 } else { 0 }

    if ($Json) {
        $repositories = @(foreach ($key in $status.Keys) {
            $repoStatus = $status[$key]
            [ordered]@{
                repo    = $key
                Success = [bool]$repoStatus.Success
                Existed = [bool]$repoStatus.Existed
                status  = $repoStatus.Status
                reason  = $repoStatus.Reason
            }
        })

        $data = New-OctoActionResult -Success ($problems -eq 0) -ExitCode $global:LASTEXITCODE -Extra @{
            branchName   = $branchName
            root         = $branchRootPath
            repositories = $repositories
            summary      = [ordered]@{
                created  = $createdCount
                switched = $switchedCount
                dirty    = $dirtyCount
                failed   = $failedCount
                total    = $status.Count
            }
        }

        Write-OctoJson -Command 'New-TestBranch' -Data $data
        if ($problems -gt 0) {
            $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([Exception]::new("$problems repository(ies) were not branched; see data.repositories."), 'TestBranchNotCreated', [System.Management.Automation.ErrorCategory]::InvalidResult, $branchName))
        }
        return
    }

    Write-Host ""
    Write-Host "Done. Branch '$branchName': $createdCount created, $switchedCount switched, $dirtyCount dirty (not branched), $failedCount failed" -ForegroundColor Cyan
    if ($problems -gt 0) {
        # A terminating error: pwsh -Command takes its exit code from $?, which Write-Error -ErrorAction Continue leaves true
        $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new([Exception]::new("$problems repository(ies) were not branched; see the summary above."), 'TestBranchNotCreated', [System.Management.Automation.ErrorCategory]::InvalidResult, $branchName))
    }
}

Export-ModuleMember -Function @('New-TestBranch')
