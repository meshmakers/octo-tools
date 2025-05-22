<#
.SYNOPSIS
    Extracts a compressed MongoDB backup archive.

.DESCRIPTION
    This function extracts a compressed MongoDB backup archive (.zip) to a folder.
    The extraction folder will have the same name as the zip file (without the .zip extension).
    If a folder with the same name already exists, it will be deleted before extraction.

.PARAMETER ZipFile
    Required. Path to the zip file to extract.

.EXAMPLE
    # Extract a backup archive
    Invoke-MongoUncompress -ZipFile "C:\dev\meshmakers\mongodb-backups\2025-05-22_19-20-58.zip"

.OUTPUTS
    Returns the path to the extracted folder.

.NOTES
    The extraction folder will be created in the same directory as the zip file.
    Any existing folder with the same name will be deleted before extraction.
#>

function Invoke-MongoUncompress {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ZipFile
    )

    if (-not (Test-Path $ZipFile)) {
        Write-Error "Zip file not found: $ZipFile"
        return
    }

    Write-Host "Uncompressing backup archive: $ZipFile"
    
    # Create extraction directory (same name as zip but without .zip extension)
    $extractPath = $ZipFile -replace '\.zip$', ''
    
    # Remove existing directory if it exists
    if (Test-Path $extractPath) {
        Remove-Item $extractPath -Recurse -Force
    }

    try {
        Expand-Archive -Path $ZipFile -DestinationPath $extractPath
        Write-Host "Successfully extracted backup to: $extractPath"
        return $extractPath
    }
    catch {
        Write-Error "Failed to extract backup: $_"
    }
}

Export-ModuleMember -Function Invoke-MongoUncompress
