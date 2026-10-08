<#
.Synopsis
Syncs meshmaker DebugL nuget packages in git repos
Attention: The $cleanBinFolder argument really cleans all bin folders.
.Description
Copies nuget packages to meshmaker nuget folder, deletes global nuget packages and syncs nuget packages in each repository
.Parameter branch
Lane checkout to work on (e.g. main, dev), resolved like Invoke-BuildAll.
.Example
Sync-NugetPackages -branch main
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
        [string]$branch = "",
        [switch]$Json
    )


    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    $restoreExitCode = 0

    # Kill all dotnet processes. This is necessary to avoid file locks.
    Invoke-KillDotnet

    $branchRoot = (Resolve-OctoBranchRootPath -branch $branch).BranchRootPath
    if ($Json) { Copy-AllNuGetPackages -branch $branch -Json | Out-Null } else { Copy-AllNuGetPackages -branch $branch }
    # Lane-local package cache (<lane>/.nuget-packages via RestorePackagesPath in <lane>/Octo.User.props).
    # Same JSON contract as Copy-AllNuGetPackages above: forward the switch, discard the nested emit.
    $laneNugetCachePath = Join-Path -Path $branchRoot -ChildPath ".nuget-packages"
    if ($Json) { Remove-GlobalNuGetPackages -path $laneNugetCachePath -Json | Out-Null } else { Remove-GlobalNuGetPackages -path $laneNugetCachePath }

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = @(Get-ChildItem -Directory -Path $branchRoot -Filter "octo-*")
    $allDirectories += @(Get-ChildItem -Directory -Path $branchRoot -Filter "mm-*")

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