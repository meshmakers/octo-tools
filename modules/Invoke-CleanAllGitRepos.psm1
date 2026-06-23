function Invoke-CleanAllGitRepos {

    param(
        [Parameter(Mandatory = $false)]
        [bool]$force = $false,
        [switch]$Json
    )


    Push-Location $Global:ROOTPATH

    # Get all directories starting with "octo-" and "mm-""
    $octoDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $mmDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    # merge the two arrays
    $allDirectories = $octoDirectories + $mmDirectories

    $successfullDirectories = @()
    $pendingChangesDirectories = @()
    $failedDirectories = @()
    $forcedDirectories = @()

    # loop through all directories
    foreach ($directory in $allDirectories) {
        $directoryPath = $directory.FullName
        Write-Host "Attempting to clean git repo in $directoryPath"
        Push-Location $directoryPath

        # check weather the directory has any pending changes
        $pendingChanges = git status --porcelain

        if ($pendingChanges -and !$force) {
            Write-Host "Directory $directoryPath has pending changes and is ignored." -ForegroundColor Yellow
            $pendingChangesDirectories += $directoryPath
            Pop-Location
            continue
        }

        if ($pendingChanges -and $force) {
            Write-Host "Directory $directoryPath has pending changes, but will be cleaned anyway." -ForegroundColor Yellow
            $forcedDirectories += $directoryPath
        }


        git clean -xdf
        
        if ($LASTEXITCODE -eq 0) {
            $successfullDirectories += $directoryPath
            Write-Host "Directory $directoryPath cleaned successfully." -ForegroundColor Green
        }
        else {
            $failedDirectories += $directoryPath
            Write-Host "Failed to clean directory $directoryPath." -ForegroundColor Red
        }




        Pop-Location
    }

    Pop-Location

    if ($Json) {
        $data = [ordered]@{
            successful = @($successfullDirectories)
            skipped    = @($pendingChangesDirectories)
            forced     = @($forcedDirectories)
            failed     = @($failedDirectories)
            counts     = [ordered]@{
                successful = $successfullDirectories.Count
                skipped    = $pendingChangesDirectories.Count
                forced     = $forcedDirectories.Count
                failed     = $failedDirectories.Count
            }
        }
        Write-OctoJson -Command 'Invoke-CleanAllGitRepos' -Data $data
        return
    }

    # Print summary

    Write-Host
    Write-Host
    Write-Host "Summary:"
    Write-Host "Successfull directories: $($successfullDirectories.Count)" -ForegroundColor Green
    Write-Host "Skipped directories: $($pendingChangesDirectories.Count)" -ForegroundColor Yellow
    Write-Host "Forced directories: $($forcedDirectories.Count)" -ForegroundColor Yellow
    Write-Host "Failed directories: $($failedDirectories.Count)" -ForegroundColor Red
    Write-Host

    if ($pendingChangesDirectories.Count -gt 0) {
        Write-Host "Directories with pending changes:"
        foreach ($directory in $pendingChangesDirectories) {
            Write-Host $directory -ForegroundColor Yellow
        }
    }

    if ($failedDirectories.Count -gt 0) {
        Write-Host "Directories witch failed cleaning:"
        foreach ($directory in $failedDirectories) {
            Write-Host $directory -ForegroundColor Red
        }
    }

    if ($forcedDirectories.Count -gt 0) {
        Write-Host "Directories that were forced to clean:"
        foreach ($directory in $forcedDirectories) {
            Write-Host $directory -ForegroundColor Yellow
        }
    }
}

Export-ModuleMember -Function @('Invoke-CleanAllGitRepos')