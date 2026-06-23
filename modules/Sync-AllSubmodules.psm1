
function Sync-AllSubmodules
{
    param(
        [string]$branch = "",
        [switch]$Json
    )

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $branchRootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $branchRootPath -Filter "mm-*"

    $repoResults = [System.Collections.Generic.List[object]]::new()
    $allOk = $true

    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        $modulesFile = Join-Path -Path $directory.FullName -ChildPath ".gitmodules"

        # Check if the ".git" directory exists
        if ((Test-Path -Path $gitDirectory -PathType Container) -And (Test-Path -Path $modulesFile)) {
            if (-not $Json) { Write-Host "Pulling git repository $($directory.FullName)" }
            if ($Json) {
                $result = Sync-Submodule $directory.FullName -Json | ConvertFrom-Json
                $repoSuccess = [bool]$result.data.success
                if (-not $repoSuccess) { $allOk = $false }
                $repoResults.Add([ordered]@{ repo = $directory.Name; success = $repoSuccess }) | Out-Null
            } else {
                Sync-Submodule $directory.FullName
            }
        }
    }

    if ($Json) {
        Write-OctoJson -Command 'Sync-AllSubmodules' -Data (New-OctoActionResult -Success ([bool]$allOk) -Extra @{ repositories = @($repoResults) })
        return
    }
}

Export-ModuleMember -Function @('Sync-AllSubmodules')