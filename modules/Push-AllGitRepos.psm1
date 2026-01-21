<#
.Synopsis
Pushes all git repos
.Description
This function pushes all existing local commits in octo-* and mm-* repositories to origin.
.Parameter branch
The local branch directory to use (e.g., "main" for the main branch folder).
.Example
Push-AllGitRepos
.Example
Push-AllGitRepos -branch "feature-branch"
#>
function Push-AllGitRepos
{
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
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

    # Get all directories starting with "octo-" and "mm-"
    $allDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"

    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"

        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            Write-Host "Pushing git repository $($directory.FullName)"
            Push-GitRepo -repositoryPath $directory.FullName
        }
    }
}

Export-ModuleMember -Function @('Push-AllGitRepos')