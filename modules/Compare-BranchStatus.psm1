function Compare-BranchStatus {
    <#
    .SYNOPSIS
    Compares branch status for all octo-* and mm-* directories against origin/main
    
    .DESCRIPTION
    Scans current directory for subdirectories starting with 'octo-' or 'mm-',
    checks if they are git repositories, and compares current branch with origin/main
    to show if there are new commits.
    
    .PARAMETER Details
    Shows detailed commit information for each repository
    
    .EXAMPLE
    Compare-BranchStatus
    
    .EXAMPLE
    Compare-BranchStatus -Details
    #>
    
    [CmdletBinding()]
    param(
        [switch]$Details
    )
    
    Write-Host "Checking branch status for octo-* and mm-* directories..." -ForegroundColor Yellow
    
    $currentDir = Get-Location
    $directories = Get-ChildItem -Directory | Where-Object { $_.Name -match '^(octo-|mm-)' }
    
    if ($directories.Count -eq 0) {
        Write-Host "✓ No octo-* or mm-* directories found" -ForegroundColor Green
        return
    }
    
    foreach ($dir in $directories) {
        Push-Location $dir.FullName
        try {
            # Check if it's a git repo
            if (!(Test-Path ".git")) {
                Write-Host "  $($dir.Name): Not a git repository" -ForegroundColor Gray
                continue
            }
            
            # Get current branch
            $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  $($dir.Name): Git error" -ForegroundColor Red
                continue
            }
            
            # Fetch latest from origin
            git fetch origin main 2>$null | Out-Null
            
            # Check for commits ahead of origin/main
            $commitsAhead = git rev-list --count origin/main..$currentBranch 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  $($dir.Name): Cannot compare with origin/main" -ForegroundColor Red
                continue
            }
            
            if ([int]$commitsAhead -gt 0) {
                # Analyze the nature of the commits
                $commitInfo = git log --oneline --pretty=format:"%h|%s" origin/main..$currentBranch 2>$null
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
                
                Write-Host "  $($dir.Name) [$currentBranch]: $statusText" -ForegroundColor $color
                
                # Show commit details if details mode is enabled
                if ($Details -and $commitDetails.Count -gt 0) {
                    $commitDetails | ForEach-Object { Write-Host $_ -ForegroundColor Gray }
                }
                
            } else {
                Write-Host "  $($dir.Name) [$currentBranch]: ✓ No changes vs main" -ForegroundColor Green
            }
        }
        catch {
            Write-Host "  $($dir.Name): Error - $($_.Exception.Message)" -ForegroundColor Red
        }
        finally {
            Pop-Location
        }
    }
}

Export-ModuleMember -Function Compare-BranchStatus
