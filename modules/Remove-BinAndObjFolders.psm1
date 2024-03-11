# Function to delete bin and obj folders
function Remove-BinAndObjFolders {
    param (
        [string]$path = "."
    )

    Write-Host "Searching in $rootPath..."

    # Find all bin and obj folders under the specified path
    $folders = Get-ChildItem -Path $path -Recurse -Directory | Where-Object { $_.Name -eq "bin" -or $_.Name -eq "obj" }

    # Delete each folder found
    foreach ($folder in $folders) {
        Write-Host "Deleting $($folder.FullName)"  -ForegroundColor Red
        Remove-Item -Recurse -Force $folder.FullName
    }
}

Export-ModuleMember -Function @('Remove-BinAndObjFolders')