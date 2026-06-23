<#
.Synopsis
Syncs meshmaker DebugL nuget packages in git repos
Attention: The $cleanBinFolder argument really cleans all bin folders.
.Description
Copies nuget packages to meshmaker nuget folder, deletes global nuget packages and syncs nuget packages in each repository
.Example
Sync-NugetPackages
.Example
 # This is function is called by convention in PowerShell
 function prompt {
     Sync-NugetPackages
 }
#>
function Sync-NuGetPackages {
    [CmdletBinding()]
    param (
        [boolean]$cleanBinFolder = $false,
        [switch]$Json
    )


    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $restoreExitCode = 0

    # Kill all dotnet processes. This is necessary to avoid file locks.
    Invoke-KillDotnet

    if ($Json) { Copy-AllNuGetPackages -Json | Out-Null } else { Copy-AllNuGetPackages }
    Remove-GlobalNuGetPackages

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        
        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            if (-not $Json) { Write-Host "Forcing restore at '$($directory.FullName)'" -ForegroundColor Green }
            Push-Location $directory.FullName
            if ($cleanBinFolder) {
                Remove-Item -Path "bin" -Recurse -Force
            }

            if ($Json) {
                dotnet restore /p:Configuration="DebugL" -f | Out-Null
            } else {
                dotnet restore /p:Configuration="DebugL" -f
            }
            if ($LASTEXITCODE -ne 0) { $restoreExitCode = $LASTEXITCODE }
            Pop-Location
        }
    }

    if ($Json) {
        $success = ($restoreExitCode -eq 0)
        Write-OctoJson -Command 'Sync-NuGetPackages' -Data (New-OctoActionResult -Success $success -ExitCode $restoreExitCode)
        return
    }
}

Export-ModuleMember -Function @('Sync-NuGetPackages')