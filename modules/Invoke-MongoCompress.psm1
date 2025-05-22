<#
.SYNOPSIS
    Compresses a MongoDB backup folder into a zip archive.

.DESCRIPTION
    This function compresses a MongoDB backup folder into a zip archive and deletes the original folder.
    If no backup folder is specified, it will use the most recent backup folder found in the mongodb-backups directory.

.PARAMETER BackupFolder
    Optional. Path to the backup folder to compress. If not specified, the most recent backup folder will be used.

.EXAMPLE
    # Compress the most recent backup folder
    Invoke-MongoCompress

.EXAMPLE
    # Compress a specific backup folder
    Invoke-MongoCompress -BackupFolder "C:\dev\meshmakers\mongodb-backups\2025-05-22_19-20-58"

.OUTPUTS
    Returns the path to the created zip file.

.NOTES
    The original backup folder is deleted after successful compression.
    The zip file is created in the same directory as the backup folder.
#>

function Invoke-MongoCompress {
    param (
        [Parameter(Mandatory=$false)]
        [string]$BackupFolder
    )

    # If no backup folder is specified, use the most recent one
    if (-not $BackupFolder) {
        $backupPath = Join-Path $Global:ROOTPATH "mongodb-backups"
        $BackupFolder = Get-ChildItem -Path $backupPath -Directory | Sort-Object CreationTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not (Test-Path $BackupFolder)) {
        Write-Error "Backup folder not found: $BackupFolder"
        return
    }

    Write-Host "Compressing backup folder: $BackupFolder"
    
    # Create zip file in the same directory as the backup folder
    $zipFile = "$BackupFolder.zip"
    
    # Remove existing zip if it exists
    if (Test-Path $zipFile) {
        Remove-Item $zipFile -Force
    }

    # Create the zip archive
    try {
        Compress-Archive -Path $BackupFolder -DestinationPath $zipFile
        Write-Host "Successfully created zip archive: $zipFile"
        
        # Delete the original backup folder
        Remove-Item $BackupFolder -Recurse -Force
        Write-Host "Deleted original backup folder"
        
        return $zipFile
    }
    catch {
        Write-Error "Failed to create zip archive: $_"
    }
}

Export-ModuleMember -Function Invoke-MongoCompress 