# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OctoMesh is a data transformation platform that converts raw data into meaningful information. This repository contains PowerShell-based development tools for building, deploying, and managing OctoMesh infrastructure.

## Key Technologies

- **Primary Language**: PowerShell scripting
- **Platform**: .NET 10.0 microservices
- **Infrastructure**: Docker Compose with MongoDB replica set, CrateDB cluster, and RabbitMQ
- **Frontend**: Angular-based admin panel

## Architecture

The system uses a microservices architecture with:
- MongoDB replica set (3 nodes on ports 27017-27019) for data storage
- CrateDB cluster (3 nodes on ports 4201-4203) for distributed SQL
- RabbitMQ (ports 5672, 15672) for message queuing
- Multiple .NET microservices for business logic

## Common Development Commands

All commands require PowerShell and are available after loading the profile:
```powershell
. .\modules\profile.ps1
```

### Building
- `Invoke-BuildAll` - Build all repositories (use `-configuration Debug` for debug builds)
- `Invoke-Build -repositoryPath .` - Build a single repository
- `Invoke-BuildFrontend` - Build frontend projects specifically
- `Invoke-BuildAndStartOcto` - Build everything and start the application

### Infrastructure Management
- `Start-OctoInfrastructure` - Start Docker infrastructure (MongoDB, CrateDB, RabbitMQ)
- `Stop-OctoInfrastructure` - Stop Docker infrastructure
- `Install-OctoInfrastructure` - Initial infrastructure setup
- `Get-OctoInfrastructureStatus` - Check infrastructure status
- `Start-Octo` - Start the Octo application after infrastructure is running
- `Stop-Octo` - Stop services started in non-interactive mode (`Start-Octo -nonInteractive $true`)

### Repository Management
- `Sync-AllGitRepos` - Sync all repositories
- `Push-AllGitRepos` - Push all repositories
- `Get-AllGitRepStatus` - Check status of all repositories
- `Invoke-CleanAllGitRepos` - Clean all repositories (use `-force` to ignore pending changes)
- `Compare-CkVersions <otherBranch>` - Compare Construction Kit model versions (`ckModel.yaml`) between the current checkout and another branch, grouped System-first and color coded (green=equal, yellow=minor/patch, red=major, cyan=only in one). Resolves the path relative to `$Global:ROOTPATH`, e.g. `Compare-CkVersions ../main` or `Compare-CkVersions branches/test`

### Cleanup
- `Remove-BinAndObjFolders` - Remove all bin/obj folders
- `Invoke-KillDotnet` - Kill all dotnet processes (Windows only)
- `Remove-GlobalNuGetPackages` - Clean global NuGet cache

### Infrastructure Backup (MongoDB + CrateDB)
Backups operate on the Docker volumes; stop the infrastructure first (`Stop-OctoInfrastructure`). Stored under `infrastructure/backups/`.
- `Backup-OctoInfrastructure` - Back up all infrastructure volumes (optional `-Name`, defaults to a timestamp)
- `Restore-OctoInfrastructure` - Restore volumes from a named backup (`-Name`; omit to list backups)
- `Get-OctoInfrastructureBackup` - List available backups
- `Remove-OctoInfrastructureBackup` - Delete a named backup (`-Name`, `-Force` to skip prompt)
- `Invoke-MongoPortForward` - Port-forward MongoDB for direct DB access

### Authentication
- `Invoke-OctoCliLoginLocal` - Login to local environment
- `Invoke-OctoCliLoginProduction` - Login to production
- `Invoke-OctoCliLoginStaging` - Login to staging
- `Invoke-OctoCliLoginTest2` - Login to test2 environment

## Project Structure

- `/modules/` - PowerShell modules for all development commands
- `/infrastructure/` - Docker Compose configuration and MongoDB init scripts
- `/assets/` - Terminal profile assets and logos

## Development Workflow

1. Start infrastructure: `Start-OctoInfrastructure`
2. Build projects: `Invoke-BuildAll`
3. Start application: `Start-Octo`
4. Make changes and rebuild as needed
5. Clean up when done: `Stop-OctoInfrastructure`

## Important Notes

- The build system handles frontend projects specially by cleaning node_modules
- Zenon plug-in projects require Windows and use MSBuild
- All PowerShell modules are automatically loaded via profile.ps1
- Custom user profiles can be added in `~/.pwsh/profile.ps1`
- Infrastructure runs entirely in Docker containers defined in `infrastructure/docker-compose.yml`