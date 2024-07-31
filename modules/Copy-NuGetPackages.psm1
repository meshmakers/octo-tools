
function Copy-NuGetPackages
{
    param(
        [string]$directory = ".\"
    )

    $filter = "Meshmakers.*.999.0.0.nupkg"
    
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

Export-ModuleMember -Function @('Copy-NuGetPackages')