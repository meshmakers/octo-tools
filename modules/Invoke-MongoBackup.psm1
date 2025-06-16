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

.NOTES
    The backup is automatically compressed and the original backup folder is deleted.
    The backup files are stored in $Global:ROOTPATH/mongodb-backups/YYYY-MM-DD_HH-mm-ss.zip
#>

function Invoke-MongoBackup {
    param (
        [Parameter(Mandatory=$false)]
        [string[]]$DatabaseNames,
        
        [Parameter(Mandatory=$false)]
        [string]$MongoUri = "mongodb://host.docker.internal:27017/?authSource=admin&directConnection=true",
        
        [Parameter(Mandatory=$false)]
        [string]$Username = "octo-system-admin",
        
        [Parameter(Mandatory=$false)]
        [string]$Password = "OctoAdmin1"

    )

    Write-Host "Starting MongoDB backup..."

    # Create backup directory if it doesn't exist
    $backupPath = Join-Path $Global:ROOTPATH "mongodb-backups"
    Write-Host "Backup path: $backupPath"
    if (!(Test-Path $backupPath)) {
        Write-Host "Creating backup directory..."
        New-Item -Path $backupPath -ItemType Directory | Out-Null
    }

    # If no specific databases are provided, get all databases
    if (-not $DatabaseNames) {
        Write-Host "No specific databases provided. Will backup all databases."
        $DatabaseNames = @("all")
    }
    else{
        Write-Host "Databases to backup: $DatabaseNames"
    }

    $timestamp = Get-Date -Format "yyyy_MM_dd_HH_mm"

    # Run mongodump in Docker container
    $containerName = "mongodb-backup-$timestamp"
    Write-Host "Starting Docker container: $containerName"
    try {
        # Run the backup container
        docker run --rm `
            --name $containerName `
            -e "mongodb_user=$Username" `
            -e "mongodb_passwd=$Password" `
            -e "mongodb_uri=$MongoUri" `
            -e "database_list=$DatabaseNames" `
            -e "backup_path=/backup/out/" `
            -v "${backupPath}:/backup/out/" `
            meshmakers/octo-mongodb-backup:1.0.1 `

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully backed up databases"
        } else {
            Write-Error "Failed to backup databases"
        }
    }
    catch {
        Write-Error "Error during backup of databases"
    }

    Write-Host "Backup completed. Files are stored in: $backupPath"
}

Export-ModuleMember -Function @('Invoke-MongoBackup')