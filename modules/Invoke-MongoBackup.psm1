<#
.SYNOPSIS
    Creates a backup of MongoDB databases.

.DESCRIPTION
    This function creates a backup of specified MongoDB databases or all databases if none are specified.
    The backup is created using mongodump in a Docker container and automatically compressed into a zip file.
    The backup files are stored in the mongodb-backups directory with a timestamp.

.PARAMETER DatabaseNames
    Optional. Array of database names to backup. If not specified, all databases will be backed up.

.PARAMETER MongoUri
    Optional. MongoDB connection URI. Defaults to "mongodb://localhost:27017".

.PARAMETER Username
    Optional. MongoDB username. Defaults to "octo-system-admin".

.PARAMETER Password
    Optional. MongoDB password. Defaults to "OctoAdmin1".

.EXAMPLE
    # Backup all databases with default credentials
    Invoke-MongoBackup

.EXAMPLE
    # Backup specific databases with custom credentials
    Invoke-MongoBackup -DatabaseNames "octosystem", "OctoSystemJobs" -Username "admin" -Password "secret"

.OUTPUTS
    Returns the path to the compressed backup file (.zip).

.NOTES
    The backup is automatically compressed and the original backup folder is deleted.
    The backup files are stored in $Global:ROOTPATH/mongodb-backups/YYYY-MM-DD_HH-mm-ss.zip
#>

function Invoke-MongoBackup {
    param (
        [Parameter(Mandatory=$false)]
        [string[]]$DatabaseNames,
        
        [Parameter(Mandatory=$false)]
        [string]$MongoUri = "mongodb://localhost:27017",
        
        [Parameter(Mandatory=$false)]
        [string]$Username = "octo-system-admin",
        
        [Parameter(Mandatory=$false)]
        [string]$Password = "OctoAdmin1"

    )

    Write-Host "Starting MongoDB backup..."
    Write-Host "MongoDB URI: $MongoUri"
    Write-Host "Username: $Username"
    Write-Host "Password: $Password"

    # Create backup directory if it doesn't exist
    $backupPath = Join-Path $Global:ROOTPATH "mongodb-backups"
    Write-Host "Backup path: $backupPath"
    if (!(Test-Path $backupPath)) {
        Write-Host "Creating backup directory..."
        New-Item -Path $backupPath -ItemType Directory | Out-Null
    }

    # Get current timestamp for backup folder
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $backupFolder = Join-Path $backupPath $timestamp
    Write-Host "Creating backup folder: $backupFolder"
    New-Item -Path $backupFolder -ItemType Directory | Out-Null

    # If no specific databases are provided, get all databases
    if (-not $DatabaseNames) {
        Write-Host "No specific databases provided. Will backup all databases."
        $DatabaseNames = @("all")
    }

   # Construct MongoDB URI with authentication if credentials are provided
    if ($Username -and $Password) {
        Write-Host "Adding authentication to MongoDB URI..."
        $MongoUri = "mongodb://${Username}:${Password}@host.docker.internal:27017/?authSource=admin&directConnection=true"
    }

    foreach ($db in $DatabaseNames) {
        Write-Host "Backing up database: $db"
        
        # Create a temporary script for mongodump
        $tempScript = Join-Path $env:TEMP "mongodump_script.sh"
        Write-Host "Creating temporary script at: $tempScript"
        if ($db -eq "all") {
            @"
#!/bin/bash
echo "Running mongodump for all databases..."
# First backup all databases
mongodump --uri='$MongoUri' --out=/backup
# Then remove the admin database backup
rm -rf /backup/admin
"@ -replace "`r`n", "`n" | Out-File -FilePath $tempScript -Encoding utf8 -NoNewline
        } else {
            @"
#!/bin/bash
echo "Running mongodump for database: $db"
mongodump --uri='$MongoUri' --db='$db' --out=/backup
"@ -replace "`r`n", "`n" | Out-File -FilePath $tempScript -Encoding utf8 -NoNewline
        }

        # Run mongodump in Docker container
        $containerName = "mongodb-backup-$timestamp"
        Write-Host "Starting Docker container: $containerName"
        try {
            # Run the backup container
            docker run --rm `
                --name $containerName `
                -v "${backupFolder}:/backup" `
                -v "${tempScript}:/backup.sh" `
                mongo:latest `
                bash -c "chmod +x /backup.sh && /backup.sh && echo 'Listing backup directory contents:' && ls -la /backup"

            if ($LASTEXITCODE -eq 0) {
                Write-Host "Successfully backed up database: $db"
            } else {
                Write-Error "Failed to backup database: $db"
            }
        }
        catch {
            Write-Error "Error during backup of database $db : $_"
        }
        finally {
            # Cleanup
            if (Test-Path $tempScript) {
                Write-Host "Cleaning up temporary script..."
                Remove-Item $tempScript -Force
            }
        }
    }

    Write-Host "Backup completed. Files are stored in: $backupFolder"

    # Compress the backup folder and return the zip file path
    Write-Host "Compressing backup folder..."
    $zipFile = Invoke-MongoCompress -BackupFolder $backupFolder
    Write-Host "Backup compressed to: $zipFile"
    return $zipFile
}

Export-ModuleMember -Function @('Invoke-MongoBackup')