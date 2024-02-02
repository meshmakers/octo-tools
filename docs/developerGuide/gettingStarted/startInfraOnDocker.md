# Start infrastructure with docker-compose

You can start the infrastructure locally with docker compose. 

## Requirements

We expect that you use the OctoMesh Profile in PowerShell and your have Docker including Docker compose running.

### Default Admin credentials

User: `octo-system-admin`  
Password: `OctoAdmin1`  
Role: `root`

## Setup the containers

```powershell
Install-OctoInfrastructure
``` 

## Start the containers 

```powershell
Start-OctoInfrastructure
``` 


## Stop the containers

```powershell
Stop-OctoInfrastructure
``` 


## Uninstall the containers

```powershell
 Uninstall-OctoInfrastructure.ps1
``` 


## Get status of container

```powershell
 Get-OctoInfrastructureStatus.ps1
``` 
