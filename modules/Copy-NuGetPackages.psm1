
function Copy-NuGetPackages
{
    param(
        [string]$branch = "",
        [string]$directory = ".\"
    )

    $filter = "Meshmakers.*.999.0.0.nupkg"
    
    Write-Host "Searching at $directory"
    $binDirectories = Get-ChildItem -Path $directory -Filter 'DebugL' -Recurse -Directory | Where-Object { $_.FullName -like '*[/\]bin[/\]DebugL' }

    $branchRootPath = Join-Path -Path $rootPath -ChildPath $branch
    $branchNugetPath = Join-Path -Path $branchRootPath -ChildPath "nuget"
    Write-Host "Branch NuGet Path: $branchNugetPath"

    # Check if the branch NuGet path exists, if not create it
    if (!(Test-Path $branchNugetPath)) {
        Write-Host "Creating directory $branchNugetPath" -ForegroundColor Yellow
        New-Item -ItemType Directory -Path $branchNugetPath | Out-Null
    }

    foreach ($binDirectory in $binDirectories) {

        Write-Host "Working on $binDirectory"
        if ((Test-Path $binDirectory)) {
            
            $nugetFiles = Get-ChildItem -Path $binDirectory -Recurse -Filter $filter
            
            foreach ($file in $nugetFiles) {
                Write-Host "Copy $file" -ForegroundColor Green
                Copy-Item -Path $file -Destination $branchNugetPath -Force
            }
        }
    }
}

Export-ModuleMember -Function @('Copy-NuGetPackages')