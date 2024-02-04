
function Copy-AllNuGetPackages
{
    if (!(Test-Path $rootPath)) {
        Write-Error "Root path $rootPath does not exist"
        return;
    }

    Write-Host "Searching in $rootPath..."

    $filter = "Meshmakers.*.999.0.0.nupkg"
     # Get all directories starting with "octo-" and "mm-"
    $allDirectories = Get-ChildItem -Directory -Path $rootPath -Filter "octo-*" -exclude "*frontent*"
    $allDirectories += Get-ChildItem -Directory -Path $rootPath -Filter "mm-*"

    foreach ($directory in $allDirectories) {     
        Write-Host "Searching at $directory"
        $binDirectories = Get-ChildItem -Path $directory -Filter 'DebugL' -Recurse -Directory | Where-Object { $_.FullName -like '*[/\]bin[/\]DebugL' }

        foreach ($binDirectory in $binDirectories) {

            Write-Host "Working on $binDirectory"
            if ((Test-Path $binDirectory)) {
                
                $nugetFiles = Get-ChildItem -Path $binDirectory -Recurse -Filter $filter
                
                foreach ($file in $nugetFiles) {
                    Write-Host "Copy $file" -ForegroundColor Green
                    Copy-Item -Path $file -Destination $nugetPath -Force
                }
            }
        }
    }
}

Export-ModuleMember -Function @('Copy-AllNuGetPackages')