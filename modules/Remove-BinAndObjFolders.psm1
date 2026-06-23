# Function to delete bin and obj folders
function Remove-BinAndObjFolders {
    param (
        [string]$path = ".",
        [switch]$Json
    )

    if (-not $Json) {
        Write-Host "Searching in $rootPath..."
    }

    # Find all bin and obj folders under the specified path
    $folders = @(Get-ChildItem -Path $path -Recurse -Directory | Where-Object { $_.Name -eq "bin" -or $_.Name -eq "obj" })

    $removedCount = 0
    # Delete each folder found
    foreach ($folder in $folders) {
        if (-not $Json) {
            Write-Host "Deleting $($folder.FullName)"  -ForegroundColor Red
        }
        Remove-Item -Recurse -Force $folder.FullName
        $removedCount++
    }

    if ($Json) {
        Write-OctoJson -Command 'Remove-BinAndObjFolders' -Data (New-OctoActionResult -Success $true -ExitCode 0 -Extra @{ removedCount = $removedCount })
        return
    }
}

Export-ModuleMember -Function @('Remove-BinAndObjFolders')