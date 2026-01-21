
function Push-AllGitRepos
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [string]$commitMessage = "Updated",
        [string]$branch = ""
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    if (!(Test-Path $branchRootPath)) {
        Write-Error "Branch path $branchRootPath does not exist"
        return;
    }

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"

    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            Write-Host "Pushing git repository $($directory.FullName)"
            Push-GitRepo $directory.FullName $commitMessage
        }
    }
}

Export-ModuleMember -Function @('Push-AllGitRepos')