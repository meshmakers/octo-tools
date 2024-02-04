<#
.Synopsis
Syncs meshmaker DebugL nuget packages in git repos
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

    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }
    
    Copy-AllNuGetPackages
    Remove-GlobalNuGetPackages

    # Get all directories starting with "octo-" and "mm-""
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    foreach ($directory in $allDirectories) {
        $gitDirectory = Join-Path -Path $directory.FullName -ChildPath ".git"
        
        # Check if the ".git" directory exists
        if (Test-Path -Path $gitDirectory -PathType Container) {
            Write-Host "Forcing restore at '$($directory.FullName)'" -ForegroundColor Green
            Push-Location $directory.FullName
            dotnet restore /p:Configuration="DebugL" -f
            Pop-Location
        }
    }
}

Export-ModuleMember -Function @('Sync-NuGetPackages')