<#
.SYNOPSIS
    Deletes all MongoDB databases except system databases (admin, config, local).

.DESCRIPTION
    This function deletes all MongoDB databases while preserving system databases.
    It uses mongosh in a Docker container to execute the deletion commands.
    The function will skip the admin, config, and local databases to ensure system stability.

.PARAMETER MongoUri
    Optional. MongoDB connection URI. Defaults to "mongodb://localhost:27017".

.PARAMETER Username
    Optional. MongoDB username. Defaults to "octo-system-admin".

.PARAMETER Password
    Optional. MongoDB password. Defaults to "OctoAdmin1".

.EXAMPLE
    # Delete all databases with default credentials
    Invoke-MongoDeleteOctomesh

.EXAMPLE
    # Delete all databases with custom credentials
    Invoke-MongoDeleteOctomesh -Username "admin" -Password "secret"

.NOTES
    This operation is destructive and will permanently delete all databases except system databases.
    Make sure to backup your data before running this command.
#>

function Invoke-MongoDeleteOctoMesh {
    param (
        [Parameter(Mandatory = $false)]
        [string]$MongoUri = "mongodb://localhost:27017",
        
        [Parameter(Mandatory = $false)]
        [string]$Username = "octo-system-admin",
        
        [Parameter(Mandatory = $false)]
        [string]$Password = "OctoAdmin1"
    )

    Write-Host "Starting MongoDB database deletion..."
    Write-Host "MongoDB URI: $MongoUri"
    Write-Host "Username: $Username"
    Write-Host "Password: $Password"

    # Construct MongoDB URI with authentication if credentials are provided
    if ($Username -and $Password) {
        Write-Host "Adding authentication to MongoDB URI..."
        $MongoUri = "mongodb://${Username}:${Password}@host.docker.internal:27017/?authSource=admin&directConnection=true"
    }

    # Create a temporary script for mongosh
    $tempScript = Join-Path $env:TEMP "mongosh_delete_script.js"
    Write-Host "Creating temporary script at: $tempScript"
    
    @"
// Get all databases
const dbs = db.adminCommand('listDatabases').databases;

// Skip system databases
const systemDbs = ['admin', 'config', 'local'];

// Iterate through each database
dbs.forEach(dbInfo => {
    const dbName = dbInfo.name;
    
    // Skip system databases
    if (systemDbs.includes(dbName)) {
        print('Skipping system database: ' + dbName);
        return;
    }
    
    print('Deleting database: ' + dbName);
    
    // Drop the database
    db.getSiblingDB(dbName).dropDatabase();
});

print('Database deletion completed.');
"@ -replace "`r`n", "`n" | Out-File -FilePath $tempScript -Encoding utf8 -NoNewline

    # Run mongosh in Docker container
    $containerName = "mongodb-delete-databases-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Write-Host "Starting Docker container: $containerName"
    
    try {
        # Run the deletion container
        docker run --rm `
            --name $containerName `
            -v "${tempScript}:/delete.js" `
            mongo:latest `
            mongosh "$MongoUri" /delete.js

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully deleted databases"
        }
        else {
            Write-Error "Failed to delete databases"
        }
    }
    catch {
        Write-Error "Error during database deletion: $_"
    }
    finally {
        # Cleanup
        if (Test-Path $tempScript) {
            Write-Host "Cleaning up temporary script..."
            Remove-Item $tempScript -Force
        }
    }
}

Export-ModuleMember -Function @('Invoke-MongoDeleteOctoMesh')