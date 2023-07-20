# Start infrastructure with docker-compose

You can start the infrastructure locally with docker compose. 

## Requirements

- docker
- powershell

## Initialize the infrastructure

For all commands it is expected that the current directory of your shell is `samples/infrastructure/`

- On Linux or Mac: `chmod +x *.ps1`
- run `init.ps1`

Afterwards the required containers are started, a admin-user is created and replica set is initialized.

### Default Admin credentials

User: `octo-system-admin`  
Password: `OctoAdmin1`  
Role: `root`

## Run the containers 

simply run `docker-compose up`

## Clean up

run `cleanup.ps1`
