function Reset-PackageLockFiles {
    param(
        [string]$repoPath
    )

    try {
        Push-Location $repoPath

        $lockFiles = git ls-files --full-name "**/package-lock.json" "package-lock.json" 2>$null
        if ($lockFiles) {
            foreach ($file in $lockFiles) {
                Write-Host "  Resetting $file" -ForegroundColor Cyan
                git checkout HEAD -- $file
            }
        }

        # Check for submodules and reset lock files there too
        $gitmodulesPath = Join-Path $repoPath ".gitmodules"
        if (Test-Path $gitmodulesPath) {
            $submodulePaths = git config --file .gitmodules --get-regexp path | ForEach-Object {
                ($_ -split '\s+', 2)[1]
            }
            foreach ($submodulePath in $submodulePaths) {
                $fullSubmodulePath = Join-Path $repoPath $submodulePath
                if (Test-Path $fullSubmodulePath) {
                    Push-Location $fullSubmodulePath
                    try {
                        $subLockFiles = git ls-files --full-name "**/package-lock.json" "package-lock.json" 2>$null
                        if ($subLockFiles) {
                            foreach ($file in $subLockFiles) {
                                Write-Host "  Resetting $submodulePath/$file" -ForegroundColor Cyan
                                git checkout HEAD -- $file
                            }
                        }
                    }
                    finally {
                        Pop-Location
                    }
                }
            }
        }
    }
    finally {
        Pop-Location
    }
}

function Sync-AllGitRepos {
    param(
        [string]$branch = "",
        [switch]$resetPackageLock
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-""
    $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
    $allDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"
    $status = @{}
    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            try {
                if ($resetPackageLock -and $directory.Name -like "*frontend*") {
                    try {
                        Write-Host "Resetting package-lock.json files in $($directory.Name)" -ForegroundColor Cyan
                        Reset-PackageLockFiles -repoPath $directory.FullName
                    }
                    catch {
                        Write-Warning "Failed to reset package-lock.json files in $($directory.Name): $_"
                    }
                }

                Write-Host "Pulling git repository $($directory.FullName)" -ForegroundColor Green
                Sync-GitRepo $directory.FullName
                $status.Add($directory.FullName, $true)
            }
            catch {
                Write-Host "Error pulling git repository $($directory.FullName)" -ForegroundColor Red
                $status.Add($directory.FullName, $false)
            }
        }
    }
    
    foreach($key in $status.Keys) {
        if($status[$key] -eq $true) {
            Write-Host "Pulling repository ${key} was successful." -ForegroundColor Green
        }else {
            Write-Host "Pulling repository ${key} failed." -ForegroundColor Red
        }
    }

    Write-Host " "
    Write-Host "Done"
    Write-Host "To sync all submodules use 'Sync-AllSubmodules'"
}

Export-ModuleMember -Function @('Sync-AllGitRepos')