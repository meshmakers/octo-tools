<#
.Synopsis
Creates a test branch for all octo-* git repositories
.Description
This function creates a test branch with format test/0.x-word for all octo-* repositories.
Branch naming rules:
- Prefix 'test/' is mandatory
- Major version must be 0
- Minor version range: 2-999
- Description must be a single word (letters, numbers, underscore only)
- Separator '-' between version and description is mandatory
No files in the repositories will be modified.
.Example
New-TestBranch -MinorVersion 5 -Description "queries"
# Creates branch test/0.5-queries
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
Optional subdirectory path relative to rootPath where repositories are located
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
        [switch]$NoPush
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    if (!(Test-Path $branchRootPath)) {
        Write-Error "Branch root path $branchRootPath does not exist"
        return
    }

    $branchName = "test/0.$MinorVersion-$Description"
    $status = @{}

    Write-Host "Creating test branch '$branchName' in '$branchRootPath'" -ForegroundColor Cyan

    # Get all directories starting with "octo-"
    $octoDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"

    foreach ($directory in $octoDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        $directoryName = $directory.Name

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            try {
                Write-Host "Processing repository $directoryName" -ForegroundColor Green

                Push-Location $directory.FullName

                # Check if branch exists on remote
                $remoteBranchExists = git ls-remote --heads origin $branchName 2>$null

                if ($remoteBranchExists) {
                    # Branch exists on remote - fetch and checkout
                    Write-Host "  Branch '$branchName' exists on remote, switching..." -ForegroundColor Yellow
                    git fetch origin $branchName
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to fetch branch $branchName from origin"
                    }
                    git checkout $branchName
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to checkout branch $branchName"
                    }
                    Write-Host "  Switched to existing branch '$branchName'" -ForegroundColor Blue
                } else {
                    # Branch does not exist - create new branch (no file modifications)
                    git checkout -b $branchName
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to create branch $branchName"
                    }
                    Write-Host "  Branch '$branchName' created" -ForegroundColor Blue

                    # Push branch to remote origin
                    if (-not $NoPush) {
                        Write-Host "  Pushing branch to origin..." -ForegroundColor Blue
                        git push -u origin $branchName
                        if ($LASTEXITCODE -ne 0) {
                            throw "Failed to push branch $branchName to origin"
                        }
                        Write-Host "  Branch pushed successfully" -ForegroundColor Green
                    }
                }

                Pop-Location
                $status.Add($directoryName, @{Success = $true; Existed = [bool]$remoteBranchExists})

            } catch {
                Write-Host "Error processing repository $directoryName : $_" -ForegroundColor Red
                Pop-Location
                $status.Add($directoryName, @{Success = $false; Existed = $false})
            }
        } else {
            Write-Host "Skipping $directoryName (no git repository)" -ForegroundColor Yellow
        }
    }

    # Summary
    Write-Host ""
    Write-Host "Branch summary:" -ForegroundColor Cyan
    $createdCount = 0
    $switchedCount = 0
    $failedCount = 0

    foreach($key in $status.Keys) {
        $repoStatus = $status[$key]
        if ($repoStatus.Success) {
            if ($repoStatus.Existed) {
                Write-Host "  ✓ $key - Switched to existing branch '$branchName'" -ForegroundColor Yellow
                $switchedCount++
            } else {
                $pushStatus = if ($NoPush) { "(local only)" } else { "and pushed" }
                Write-Host "  ✓ $key - Branch '$branchName' created $pushStatus" -ForegroundColor Green
                $createdCount++
            }
        } else {
            Write-Host "  ✗ $key - Failed" -ForegroundColor Red
            $failedCount++
        }
    }

    Write-Host ""
    Write-Host "Done. Branch '$branchName': $createdCount created, $switchedCount switched, $failedCount failed" -ForegroundColor Cyan
}

Export-ModuleMember -Function @('New-TestBranch')