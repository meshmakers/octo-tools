function Compare-BranchStatus {
    <#
    .SYNOPSIS
    Compares branch status for all octo-* and mm-* directories against a target origin branch

    .DESCRIPTION
    Scans a branch subdirectory for subdirectories starting with 'octo-' or 'mm-',
    checks if they are git repositories, and compares current branch with the specified
    target origin branch to show if there are new commits.

    .PARAMETER branch
    The branch subdirectory to scan (e.g., "" for root, "feature-x" for $rootPath/feature-x)

    .PARAMETER targetBranch
    The origin branch to compare against (default: main)

    .PARAMETER Details
    Shows detailed commit information for each repository

    .EXAMPLE
    Compare-BranchStatus

    .EXAMPLE
    Compare-BranchStatus -branch "feature-x"

    .EXAMPLE
    Compare-BranchStatus -branch "feature-x" -targetBranch develop

    .EXAMPLE
    Compare-BranchStatus -branch "feature-x" -Details
    #>

    [CmdletBinding()]
    param(
        [string]$branch = "",
        [string]$targetBranch = "main",
        [switch]$Details,
        [switch]$Json
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    if (-not $Json) {
        Write-Host "Checking branch status for octo-* and mm-* directories in $branchRootPath against origin/$targetBranch..." -ForegroundColor Yellow
    }

    $repoResults = [System.Collections.Generic.List[object]]::new()

    $directories = Get-ChildItem -Directory -Path $branchRootPath | Where-Object { $_.Name -match '^(octo-|mm-)' }

    if ($directories.Count -eq 0) {
        if ($Json) {
            Write-OctoJson -Command 'Compare-BranchStatus' -Data ([ordered]@{
                repositories = @()
                summary      = [ordered]@{
                    repositoryCount  = 0
                    aheadCount       = 0
                    totalCommits     = 0
                    totalCodeCommits = 0
                }
            })
            return
        }
        Write-Host "✓ No octo-* or mm-* directories found" -ForegroundColor Green
        return
    }

    foreach ($dir in $directories) {
        Push-Location $dir.FullName
        try {
            # Check if it's a git repo
            if (!(Test-Path ".git")) {
                if ($Json) {
                    $repoResults.Add([ordered]@{
                        repo             = $dir.Name
                        branch           = $null
                        commitCount      = 0
                        codeCommits      = 0
                        mergeCommits     = 0
                        submoduleCommits = 0
                        status           = 'not-a-git-repository'
                    }) | Out-Null
                    continue
                }
                Write-Host "  $($dir.Name): Not a git repository" -ForegroundColor Gray
                continue
            }

            # Get current branch
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                if ($Json) {
                    $repoResults.Add([ordered]@{
                        repo             = $dir.Name
                        branch           = $null
                        commitCount      = 0
                        codeCommits      = 0
                        mergeCommits     = 0
                        submoduleCommits = 0
                        status           = 'git-error'
                    }) | Out-Null
                    continue
                }
                Write-Host "  $($dir.Name): Git error" -ForegroundColor Red
                continue
            }

            # Fetch latest from origin
            git fetch origin $targetBranch 2>$null | Out-Null

            # Check for commits ahead of origin/$targetBranch
            $commitsAhead = git rev-list --count origin/$targetBranch..$currentBranch 2>$null
            if ($LASTEXITCODE -ne 0) {
                if ($Json) {
                    $repoResults.Add([ordered]@{
                        repo             = $dir.Name
                        branch           = $currentBranch
                        commitCount      = 0
                        codeCommits      = 0
                        mergeCommits     = 0
                        submoduleCommits = 0
                        status           = 'compare-failed'
                    }) | Out-Null
                    continue
                }
                Write-Host "  $($dir.Name): Cannot compare with origin/$targetBranch" -ForegroundColor Red
                continue
            }
            
            if ([int]$commitsAhead -gt 0) {
                # Analyze the nature of the commits
                $commitInfo = git log --oneline --pretty=format:"%h|%s" origin/$targetBranch..$currentBranch 2>$null
                $commits = $commitInfo -split "`n" | Where-Object { $_ -ne "" }
                
                $submoduleCommits = 0
                $mergeCommits = 0
                $realCommits = 0
                $commitDetails = @()
                
                foreach ($commit in $commits) {
                    $parts = $commit -split "\|", 2
                    if ($parts.Length -eq 2) {
                        $hash = $parts[0]
                        $message = $parts[1]
                        
                        # Check if this commit only changes submodules by examining the files
                        $changedFiles = git show --name-only --pretty=format:"" $hash 2>$null | Where-Object { $_ -ne "" }
                        $isSubmoduleOnly = $false
                        
                        if ($changedFiles) {
                            # Check if all changed files are submodules (no file extension or are directories)
                            $nonSubmoduleFiles = $changedFiles | Where-Object { 
                                $_ -match "\.[a-zA-Z0-9]+$" -or $_ -match "/.*\.[a-zA-Z0-9]+$" 
                            }
                            $isSubmoduleOnly = ($nonSubmoduleFiles.Count -eq 0)
                        }
                        
                        if ($message -match "^Merge|^merge") {
                            $mergeCommits++
                            $commitDetails += "    📋 $hash - $message"
                        }
                        elseif ($message -match "submodule|Submodule|Updated submodule|Update submodule" -or $isSubmoduleOnly) {
                            $submoduleCommits++
                            $commitDetails += "    📦 $hash - $message"
                        }
                        else {
                            $realCommits++
                            $commitDetails += "    💻 $hash - $message"
                        }
                    }
                }
                
                # Determine the nature and color
                $statusText = ""
                $color = "Cyan"
                
                if ($realCommits -gt 0) {
                    $statusText = "$commitsAhead commits ahead ($realCommits code"
                    if ($submoduleCommits -gt 0) { $statusText += ", $submoduleCommits submodule" }
                    if ($mergeCommits -gt 0) { $statusText += ", $mergeCommits merge" }
                    $statusText += ")"
                    $color = "Yellow"  # Real changes - more attention needed
                }
                elseif ($submoduleCommits -gt 0 -or $mergeCommits -gt 0) {
                    $statusText = "$commitsAhead commits ahead (only "
                    if ($submoduleCommits -gt 0) { $statusText += "$submoduleCommits submodule" }
                    if ($mergeCommits -gt 0 -and $submoduleCommits -gt 0) { $statusText += ", " }
                    if ($mergeCommits -gt 0) { $statusText += "$mergeCommits merge" }
                    $statusText += ")"
                    $color = "DarkCyan"  # Less critical
                }
                else {
                    $statusText = "$commitsAhead commits ahead"
                }
                
                if ($Json) {
                    $repoResults.Add([ordered]@{
                        repo             = $dir.Name
                        branch           = $currentBranch
                        commitCount      = [int]$commitsAhead
                        codeCommits      = [int]$realCommits
                        mergeCommits     = [int]$mergeCommits
                        submoduleCommits = [int]$submoduleCommits
                        status           = 'ahead'
                        details          = @($commitDetails)
                    }) | Out-Null
                }
                else {
                    Write-Host "  $($dir.Name) [$currentBranch]: $statusText" -ForegroundColor $color

                    # Show commit details if details mode is enabled
                    if ($Details -and $commitDetails.Count -gt 0) {
                        $commitDetails | ForEach-Object { Write-Host $_ -ForegroundColor Gray }
                    }
                }
            } else {
                if ($Json) {
                    $repoResults.Add([ordered]@{
                        repo             = $dir.Name
                        branch           = $currentBranch
                        commitCount      = 0
                        codeCommits      = 0
                        mergeCommits     = 0
                        submoduleCommits = 0
                        status           = 'up-to-date'
                    }) | Out-Null
                }
                else {
                    Write-Host "  $($dir.Name) [$currentBranch]: ✓ No changes vs $targetBranch" -ForegroundColor Green
                }
            }
        }
        catch {
            if ($Json) {
                $repoResults.Add([ordered]@{
                    repo             = $dir.Name
                    branch           = $currentBranch
                    commitCount      = 0
                    codeCommits      = 0
                    mergeCommits     = 0
                    submoduleCommits = 0
                    status           = 'error'
                    details          = @($_.Exception.Message)
                }) | Out-Null
            }
            else {
                Write-Host "  $($dir.Name): Error - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        finally {
            Pop-Location
        }
    }

    if ($Json) {
        $aheadRepos = @($repoResults | Where-Object { $_.status -eq 'ahead' })
        Write-OctoJson -Command 'Compare-BranchStatus' -Data ([ordered]@{
            repositories = @($repoResults)
            summary      = [ordered]@{
                repositoryCount  = $repoResults.Count
                aheadCount       = $aheadRepos.Count
                totalCommits     = [int](($aheadRepos | Measure-Object -Property commitCount -Sum).Sum)
                totalCodeCommits = [int](($aheadRepos | Measure-Object -Property codeCommits -Sum).Sum)
            }
        })
        return
    }
}

Export-ModuleMember -Function Compare-BranchStatus
