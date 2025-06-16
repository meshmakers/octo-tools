<#
.SYNOPSIS
    Restores MongoDB databases from a backup.

.DESCRIPTION
    This function restores MongoDB databases from either a backup folder or a compressed backup archive (.zip).
    If a zip file is provided, it will be automatically extracted before restoration.
    The restoration is performed using mongorestore in a Docker container.

.PARAMETER BackupPath
    Required. Path to the backup folder or zip file to restore from.

.PARAMETER MongoUri
    Optional. MongoDB connection URI. Defaults to "mongodb://localhost:27017".

.PARAMETER Username
    Optional. MongoDB username. Defaults to "octo-system-admin".

.PARAMETER Password
    Optional. MongoDB password. Defaults to "OctoAdmin1".

.EXAMPLE
    # Restore from a backup folder
    Invoke-MongoRestore -BackupPath "C:\dev\meshmakers\mongodb-backups\2025-05-22_19-20-58"

.EXAMPLE
    # Restore from a compressed backup with custom credentials
    Invoke-MongoRestore -BackupPath "C:\dev\meshmakers\mongodb-backups\2025-05-22_19-20-58.zip" -Username "admin" -Password "secret"

.NOTES
    The function automatically handles both folder and zip file backups.
    If a zip file is provided, it will be extracted to a folder with the same name (without .zip extension).
    The restoration is performed using mongorestore in a Docker container.
#>

function Invoke-MongoRestore {
    param (
        [Parameter(Mandatory=$true)]
        [string]$BackupPath,
        
        [Parameter(Mandatory=$false)]
        [string]$MongoUri = "mongodb://host.docker.internal:27017/?authSource=admin&directConnection=true",
        
        [Parameter(Mandatory=$false)]
        [string]$Username = "octo-system-admin",
        
        [Parameter(Mandatory=$false)]
        [string]$Password = "OctoAdmin1"
    )

    # Check if the path is a zip file
    if ($BackupPath -like "*.zip") {
        Write-Host "Backup is a zip file, extracting first..."
        $BackupPath = Invoke-MongoUncompress -ZipFile $BackupPath
    }

    if (-not (Test-Path $BackupPath)) {
        Write-Error "Backup path not found: $BackupPath"
        return
    }

    # Get the actual backup directory (it might be nested)
    $backupDir = Get-ChildItem -Path $BackupPath -Filter *.tar.gz | Select-Object -First 1
    if ($backupDir) {
        $BackupPath = $backupDir.FullName
        Write-Host "Found backup archive: $BackupPath"
    }

    Write-Host "Starting MongoDB restore from: $BackupPath"

    # Check if file ending is .tar.gz
    if ($BackupPath -notlike "*.tar.gz") {
        Write-Error "Backup path must be a .tar.gz file or a directory containing a .tar.gz file."
        return
    }

    # Create a temporary script for mongorestore
    $backupRootPath = Join-Path $Global:ROOTPATH "mongodb-backups"
    $tempScript = Join-Path $backupRootPath "mongorestore_script.sh"
    Write-Host "Creating temporary script at: $tempScript"
    @"
#!/bin/bash
echo "Running mongorestore..."
mongorestore -u '$Username' -p '$Password' --uri '$MongoUri' --archive=/backup.tar.gz --gzip
"@ -replace "`r`n", "`n" | Out-File -FilePath $tempScript -Encoding utf8 -NoNewline

    # Run mongorestore in Docker container
    $containerName = "mongodb-restore-$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')"
    Write-Host "Starting Docker container: $containerName"
    
    try {
        # Run the restore container
        docker run --rm `
            --name $containerName `
            -v "${BackupPath}:/backup.tar.gz" `
            -v "${tempScript}:/restore.sh" `
            mongo:latest `
            bash -c "chmod +x /restore.sh && /restore.sh"

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully restored databases"
        } else {
            Write-Error "Failed to restore databases"
        }
    }
    catch {
        Write-Error "Error during restore: $_"
    }
    finally {
        # Cleanup
        if (Test-Path $tempScript) {
            Write-Host "Cleaning up temporary script..."
            Remove-Item $tempScript -Force
        }
    }
}

Export-ModuleMember -Function Invoke-MongoRestore 