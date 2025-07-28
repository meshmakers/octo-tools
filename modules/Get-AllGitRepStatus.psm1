function Get-AllGitRepStatus {
    param(
        [string]$branch = ""
    )

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

        if ($statusOutput) {
            $status = "Dirty"
        }
        else {
            $status = "Clean"
        }

        if ($status -eq "Clean") {
            $color = "Green"
        }
        else {
            $color = "Red"
        }

        if ($indentLevel -gt 0) {
            $indent = ('-' * 8 * $indentLevel) + "> "
        }
        else {
            $indent = ""
        }

        if ($branchName -ne "main" -and $branchName -ne "master" -and $status -eq "Clean") {
            $color = "Yellow"
        }

        $statusField = "[$status]".PadRight(10)
        $repoField = $repoName.PadRight(60 - $indent.Length)
        $branchField = "($branchName)"
        
        Write-Host "$statusField $indent$repoField$branchField" -ForegroundColor $color

        if ($status -eq "Dirty") {
            $statusOutput | ForEach-Object {
                Write-Host "$indent`t$_" -ForegroundColor DarkGray
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

    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"

        if (Test-Path -Path $gitDirectory -PathType Container) {
            Check-GitStatusRecursively -path $directory.FullName
            Write-Host ""
        }
    }
}

Export-ModuleMember -Function @('Get-AllGitRepStatus')
