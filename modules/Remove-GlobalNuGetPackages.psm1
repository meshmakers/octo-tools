
function Remove-GlobalNuGetPackages
{
    if (!(Test-Path $globalNugetPackagesPath)) {
        Write-Error "Path $globalNugetPackagesPath does not exist"
        return;
    }

    Write-Host "Searching in $globalNugetPackagesPath..."

    $allDirectories = Get-ChildItem -Directory -Path $globalNugetPackagesPath -Filter "meshmakers.*"

    foreach ($directory in $allDirectories) {     
        Write-Host "Searching at $directory"
        $packageDirectories = Join-Path $directory '999.0.0'
     
        if ((Test-Path $packageDirectories)) {

            Write-Host "Deleting $packageDirectories" -ForegroundColor Red
            Remove-Item -Path $packageDirectories -Recurse -Force
        }
    }
}

Export-ModuleMember -Function @('Remove-GlobalNuGetPackages')