#Requires -Version 5.1

<#
.SYNOPSIS
    Converts Git submodules to local symlinks to save disk space and improve performance.

.DESCRIPTION
    This module provides functions to convert Git submodules to symlinks pointing to centrally
    stored repositories in $ROOTPATH. This eliminates multiple checkouts of the same repository.

.NOTES
    Author: meshmakers.io
    Version: 1.0.0
#>

# Global configuration - use $ROOTPATH or fallback to parent directory
$script:CentralRepoPath = $env:ROOTPATH
if (-not $script:CentralRepoPath) {
    $script:CentralRepoPath = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

function Get-GitSubmodules {
    <#
    .SYNOPSIS
        Reads .gitmodules file and returns submodule information.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RepositoryPath = "."
    )
    
    $gitmodulesPath = Join-Path $RepositoryPath ".gitmodules"
    
    if (-not (Test-Path $gitmodulesPath)) {
        Write-Warning "No .gitmodules file found in $RepositoryPath"
        return @()
    }
    
    $submodules = @()
    $content = Get-Content $gitmodulesPath
    $currentSubmodule = $null
    
    foreach ($line in $content) {
        if ($line -match '^\[submodule "(.+)"\]$') {
            if ($currentSubmodule) {
                $submodules += $currentSubmodule
            }
            $currentSubmodule = @{
                Name = $matches[1]
                Path = $null
                Url = $null
                Branch = $null
            }
        }
        elseif ($line -match '^\s*path\s*=\s*(.+)$' -and $currentSubmodule) {
            $currentSubmodule.Path = $matches[1].Trim()
        }
        elseif ($line -match '^\s*url\s*=\s*(.+)$' -and $currentSubmodule) {
            $currentSubmodule.Url = $matches[1].Trim()
        }
        elseif ($line -match '^\s*branch\s*=\s*(.+)$' -and $currentSubmodule) {
            $currentSubmodule.Branch = $matches[1].Trim()
        }
    }
    
    if ($currentSubmodule) {
        $submodules += $currentSubmodule
    }
    
    return $submodules
}

function Find-ExistingRepository {
    <#
    .SYNOPSIS
        Finds an existing repository in $ROOTPATH by name or URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryUrl
    )
    
    # Extract repository name from URL
    $repoName = ($RepositoryUrl -split '/')[-1] -replace '\.git$', ''
    
    # Search for existing repository in $ROOTPATH with various naming patterns
    $possiblePaths = @(
        (Join-Path $script:CentralRepoPath $repoName),
        (Join-Path $script:CentralRepoPath ($repoName -replace '^octo-', '')),
        (Join-Path $script:CentralRepoPath ($repoName -replace '-', '_')),
        (Join-Path $script:CentralRepoPath ($repoName -replace '_', '-'))
    )
    
    foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
            $gitDir = Join-Path $path ".git"
            if (Test-Path $gitDir) {
                Write-Host "  Found existing repository: $path" -ForegroundColor Green
                return $path
            }
        }
    }
    
    # If not found, return the standard path for potential cloning
    return Join-Path $script:CentralRepoPath $repoName
}

function Get-CentralRepositoryPath {
    <#
    .SYNOPSIS
        Gets the path for a central repository based on its URL.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryUrl
    )
    
    return Find-ExistingRepository -RepositoryUrl $RepositoryUrl
}

function Invoke-CentralRepositorySetup {
    <#
    .SYNOPSIS
        Sets up a repository reference (existing or cloned) in the central location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryUrl,
        
        [Parameter()]
        [string]$Branch = $null
    )
    
    $centralPath = Get-CentralRepositoryPath -RepositoryUrl $RepositoryUrl
    $gitDir = Join-Path $centralPath ".git"
    
    if (Test-Path $gitDir) {
        Write-Host "  Using existing repository: $centralPath" -ForegroundColor Green
        
        # Optionally update existing repository
        Push-Location $centralPath
        try {
            Write-Host "  Fetching latest changes..." -ForegroundColor Blue
            git fetch --all 2>$null
            if ($Branch) {
                $currentBranch = git rev-parse --abbrev-ref HEAD 2>$null
                if ($currentBranch -ne $Branch) {
                    Write-Host "  Switching to branch: $Branch" -ForegroundColor Blue
                    git checkout $Branch 2>$null
                }
            }
        }
        catch {
            Write-Warning "Could not update repository: $_"
        }
        finally {
            Pop-Location
        }
        
        return $centralPath
    }
    
    Write-Host "  Repository not found in $ROOTPATH, cloning $RepositoryUrl to $centralPath..." -ForegroundColor Blue
    
    $cloneArgs = @('clone', $RepositoryUrl, $centralPath)
    if ($Branch) {
        $cloneArgs += @('--branch', $Branch)
    }
    
    & git @cloneArgs
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone repository: $RepositoryUrl"
    }
    
    return $centralPath
}

function Convert-SubmoduleToSymlink {
    <#
    .SYNOPSIS
        Converts a single submodule to a symlink.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Submodule,
        
        [Parameter()]
        [string]$RepositoryPath = ".",
        
        [Parameter()]
        [switch]$WhatIf
    )
    
    $submodulePath = Join-Path $RepositoryPath $Submodule.Path
    $absoluteSubmodulePath = Resolve-Path $submodulePath -ErrorAction SilentlyContinue
    
    Write-Host "`nProcessing submodule: $($Submodule.Name)" -ForegroundColor Cyan
    Write-Host "  Path: $($Submodule.Path)"
    Write-Host "  URL: $($Submodule.Url)"
    
    if ($WhatIf) {
        $potentialCentralPath = Get-CentralRepositoryPath -RepositoryUrl $Submodule.Url
        Write-Host "  [WHAT-IF] Would convert to symlink → $potentialCentralPath" -ForegroundColor Yellow
        return
    }
    
    # Get or setup central repository
    $centralPath = Invoke-CentralRepositorySetup -RepositoryUrl $Submodule.Url -Branch $Submodule.Branch
    
    # Check if submodule is currently initialized
    $isInitialized = Test-Path (Join-Path $submodulePath ".git")
    
    if ($isInitialized) {
        Write-Host "  Deinitializing submodule..." -ForegroundColor Blue
        Push-Location $RepositoryPath
        try {
            git submodule deinit -f $Submodule.Path 2>$null
            git rm -f $Submodule.Path 2>$null
        }
        finally {
            Pop-Location
        }
    }
    
    # Remove existing directory if it exists
    if (Test-Path $submodulePath) {
        Write-Host "  Removing existing directory..." -ForegroundColor Blue
        Remove-Item $submodulePath -Recurse -Force
    }
    
    # Create symlink
    Write-Host "  Creating symlink..." -ForegroundColor Green
    
    # Ensure parent directory exists
    $parentDir = Split-Path $submodulePath -Parent
    if (-not (Test-Path $parentDir)) {
        New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
    }
    
    # Create the symlink
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        # Windows: Use New-Item with symbolic link
        New-Item -Path $submodulePath -ItemType SymbolicLink -Value $centralPath | Out-Null
    } else {
        # Unix/macOS: Use ln -s
        & ln -s $centralPath $submodulePath
    }
    
    if (-not (Test-Path $submodulePath)) {
        throw "Failed to create symlink at $submodulePath"
    }
    
    Write-Host "  ✓ Successfully converted to symlink" -ForegroundColor Green
}

function Convert-AllSubmodulesToSymlinks {
    <#
    .SYNOPSIS
        Converts all submodules in a repository to symlinks.
    .PARAMETER RepositoryPath
        Path to the Git repository containing submodules.
    .PARAMETER CentralPath
        Path where central repositories should be stored.
    .PARAMETER WhatIf
        Shows what would be done without making changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RepositoryPath = ".",
        
        [Parameter()]
        [string]$CentralPath = $null,
        
        [Parameter()]
        [switch]$WhatIf
    )
    
    if ($CentralPath) {
        Set-CentralRepositoryPath -Path $CentralPath
    }
    
    Write-Host "Converting submodules to symlinks..." -ForegroundColor Cyan
    Write-Host "Repository: $(Resolve-Path $RepositoryPath)"
    Write-Host "Central repository storage: $script:CentralRepoPath"
    
    if ($WhatIf) {
        Write-Host "`n[WHAT-IF MODE] - No changes will be made`n" -ForegroundColor Yellow
    }
    
    $submodules = Get-GitSubmodules -RepositoryPath $RepositoryPath
    
    if ($submodules.Count -eq 0) {
        Write-Host "No submodules found." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Found $($submodules.Count) submodule(s):`n"
    
    foreach ($submodule in $submodules) {
        try {
            Convert-SubmoduleToSymlink -Submodule $submodule -RepositoryPath $RepositoryPath -WhatIf:$WhatIf
        }
        catch {
            Write-Error "Failed to convert submodule $($submodule.Name): $_"
        }
    }
    
    if (-not $WhatIf) {
        Write-Host "`n✓ Conversion completed!" -ForegroundColor Green
        Write-Host "Note: .gitmodules remains unchanged - symlinks will work transparently" -ForegroundColor Yellow
    }
}

function Restore-SubmodulesFromSymlinks {
    <#
    .SYNOPSIS
        Restores symlinks back to regular Git submodules.
    .PARAMETER RepositoryPath
        Path to the Git repository.
    .PARAMETER WhatIf
        Shows what would be done without making changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RepositoryPath = ".",
        
        [Parameter()]
        [switch]$WhatIf
    )
    
    Write-Host "Restoring symlinks back to submodules..." -ForegroundColor Cyan
    
    if ($WhatIf) {
        Write-Host "[WHAT-IF MODE] - No changes will be made`n" -ForegroundColor Yellow
    }
    
    $submodules = Get-GitSubmodules -RepositoryPath $RepositoryPath
    
    foreach ($submodule in $submodules) {
        $submodulePath = Join-Path $RepositoryPath $Submodule.Path
        
        Write-Host "`nProcessing: $($submodule.Name)" -ForegroundColor Cyan
        
        # Check if it's currently a symlink
        if (Test-Path $submodulePath) {
            $item = Get-Item $submodulePath
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-Host "  Found symlink, restoring to submodule..." -ForegroundColor Blue
                
                if (-not $WhatIf) {
                    # Remove symlink
                    Remove-Item $submodulePath -Force
                    
                    # Re-add as submodule
                    Push-Location $RepositoryPath
                    try {
                        git submodule add $submodule.Url $submodule.Path
                        git submodule update --init $submodule.Path
                    }
                    finally {
                        Pop-Location
                    }
                    
                    Write-Host "  ✓ Restored" -ForegroundColor Green
                }
                else {
                    Write-Host "  [WHAT-IF] Would restore to submodule" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host "  Already a regular directory/submodule" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  Path doesn't exist, adding submodule..." -ForegroundColor Blue
            
            if (-not $WhatIf) {
                Push-Location $RepositoryPath
                try {
                    git submodule add $submodule.Url $submodule.Path
                    git submodule update --init $submodule.Path
                }
                finally {
                    Pop-Location
                }
                
                Write-Host "  ✓ Added" -ForegroundColor Green
            }
            else {
                Write-Host "  [WHAT-IF] Would add submodule" -ForegroundColor Yellow
            }
        }
    }
    
    if (-not $WhatIf) {
        Write-Host "`n✓ Restoration completed!" -ForegroundColor Green
    }
}

function Get-SymlinkStatus {
    <#
    .SYNOPSIS
        Shows the current status of submodules (symlink vs. regular).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$RepositoryPath = "."
    )
    
    Write-Host "Submodule Status Report" -ForegroundColor Cyan
    Write-Host "Repository: $(Resolve-Path $RepositoryPath)`n"
    
    $submodules = Get-GitSubmodules -RepositoryPath $RepositoryPath
    
    if ($submodules.Count -eq 0) {
        Write-Host "No submodules found." -ForegroundColor Yellow
        return
    }
    
    foreach ($submodule in $submodules) {
        $submodulePath = Join-Path $RepositoryPath $Submodule.Path
        
        Write-Host "📂 $($submodule.Name)" -ForegroundColor White
        Write-Host "   Path: $($submodule.Path)"
        Write-Host "   URL:  $($submodule.Url)"
        
        if (Test-Path $submodulePath) {
            $item = Get-Item $submodulePath
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $target = $item.Target
                Write-Host "   Status: 🔗 SYMLINK → $target" -ForegroundColor Green
            }
            else {
                Write-Host "   Status: 📁 REGULAR DIRECTORY" -ForegroundColor Blue
            }
        }
        else {
            Write-Host "   Status: ❌ NOT FOUND" -ForegroundColor Red
        }
        
        Write-Host ""
    }
}

# Export functions
Export-ModuleMember -Function @(
    'Convert-AllSubmodulesToSymlinks',
    'Restore-SubmodulesFromSymlinks',
    'Get-SymlinkStatus',
    'Get-GitSubmodules'
)
