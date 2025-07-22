function Find-AllGitRepos {
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeSubmodules = $false
    )

    $rootPath = $Global:ROOTPATH
    if (-not $rootPath) {
        Write-Error "Global:ROOTPATH is not set"
        return
    }

    Write-Verbose "Searching for Git repositories in: $rootPath"
    Write-Verbose "Include submodules: $IncludeSubmodules"
    
    $script:gitRepos = @()
    $excludedDirs = @('node_modules', 'obj', 'bin', '.git')
    
    function Test-GitRepository {
        param([string]$Path)
        
        $gitPath = Join-Path $Path ".git"
        if (Test-Path $gitPath -ErrorAction SilentlyContinue) {
            if ($IncludeSubmodules) {
                return $true
            }
            else {
                # Check if it's a submodule by looking for .git file (not directory)
                try {
                    $gitItem = Get-Item $gitPath -ErrorAction Stop -Force
                    return $gitItem.PSIsContainer
                }
                catch {
                    return $false
                }
            }
        }
        return $false
    }
    
    function Search-GitRepos {
        param([string]$SearchPath)
        
        Write-Verbose "Searching in: $SearchPath"
        
        if (-not (Test-Path $SearchPath)) {
            Write-Verbose "Path does not exist: $SearchPath"
            return
        }
        
        # Check if current directory is a git repo
        if (Test-GitRepository -Path $SearchPath) {
            $repoPath = $SearchPath
            Write-Verbose "Found Git repository: $repoPath"
            $script:gitRepos += $repoPath
            
            # If we found a repo and don't include submodules, skip searching inside it
            if (-not $IncludeSubmodules) {
                return
            }
        }
        else {
            Write-Verbose "Not a Git repository: $SearchPath"
        }
        
        # Get all subdirectories
        try {
            $subdirs = Get-ChildItem -Path $SearchPath -Directory -Force -ErrorAction SilentlyContinue | 
                Where-Object { $excludedDirs -notcontains $_.Name }
            
            foreach ($subdir in $subdirs) {
                Search-GitRepos -SearchPath $subdir.FullName
            }
        }
        catch {
            Write-Verbose "Error accessing directory: $SearchPath - $($_.Exception.Message)"
        }
    }
    
    # Start the search
    Search-GitRepos -SearchPath $rootPath
    
    # Sort the results
    $script:gitRepos = $script:gitRepos | Sort-Object
    
    Write-Verbose "Total Git repositories found: $($script:gitRepos.Count)"
    
    # Return the array of repos
    return $script:gitRepos
}

Export-ModuleMember -Function Find-AllGitRepos