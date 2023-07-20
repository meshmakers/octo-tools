# OCTO MESH getting started

Transforming data into value.

OCTO MESH revolutionizes the way companies exchange data between software applications by providing both connectivity and intelligent data mapping and transformation capabilities. OCTO MESH solves the challenges of data incompatibility, connectivity and mapping, enabling seamless and efficient data exchange. OCTO MESH accompanies organizations on their digital transformation journey with optimized connections and couplings, strong security measures and an intuitive user interface. Companies are thus discovering the full potential of their data and promoting innovation, efficiency and well-founded decisions in today's data-driven world.

## System requirements

For the development environment, it must be ensured that all system requirements are met.<br>
Details can be found in [here](./docs/systemRequirements.md).

## OCTO MESH PowerShell 

OCTO MESH PowerShell enables to simplify the process of cloning, building and starting Octo Mesh including infrastructure.

To get started, clone repository https://github.com/meshmakers/octo-tools to a directory like ~/Development/meshmakers/octo-tools.
```
mkdir ~/Development/meshmakers/
cd ~/Development/meshmakers/
git clone git@github.com:meshmakers/octo-tools.git
```

Add to your Powershell Profile the Octo Mesh profile by extending the profile. In this case we use Visual Studio Code so we expect that code is available in your PATH environment variable.

```powershell
code $PROFILE
``` 

Add to the profile:
```powershell
. "~/Development/meshmakers/octo-tools/modules/profile.ps1"
``` 

Restart powershell, during start you should see a message like
```powershell
Loading Octo Profile
``` 

After loading Octo Profile, there are some powershell variables existing
- $ROOTPATH: The base directory of Octo Mesh. e. g. ~/Development/meshmakers/. This directory is called root directory
- $TOOLSPATH: The directory of the tools repository.  e. g. ~/Development/meshmakers/octo-tools
- $INFRASTRUCTUREPATH: The directory of infrastructure within the tools repository. e. g. ~/Development/meshmakers/octo-tools/infrastructure

### Definitions

- Main Repositories: All repositories that are the "core" of Octo Mesh, currently all except Plugs and Sockets. They are connecting directly or indirectly to MongoDB directly.
- Main Services: The services of the main repositories
- 
### Commands

| Command                      | Description                                                                                                                     |
|------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| Invoke-CloneMainRepos        | Clones all main repositories to your root directory.                                                                            |
| Invoke-BuildAll              | Builds all repositories starting with octo-* and a solution file (*.sln).                                                       |
| Invoke-Build                 | Builds a repository for .NET using the current directory by default or defining by parameter repositoryPath                     |
| Start-Octo                   | Starts the main services                                                                                                        |
| Invoke-BuildAndStartOcto     | Builds all repositories and starts the main services                                                                            |
| Install-OctoInfrastructure   | Uses the docker compose file located at [infrastructure](./infrastructue) to compose the infrastructure dependencies            |
| Uninstall-OctoInfrastructure | Uninstalls the infrastructure dependencies by using docker compose file at  [infrastructure](./infrastructue)                   |
| Start-OctoInfrastructure     | Starts the infrastructure dependencies by using docker compose file at [infrastructure](./infrastructue)                        |
| Stop-OctoInfrastructure      | Stops the infrastructure dependencies by using docker compose file at [infrastructure](./infrastructue)                         |
| Push-GitRepo                 | Push a repository to github using the current directory by default or defining by parameter repositoryPath                      |
| Push-AllGitRepos             | Push all repositories starting with octo-*                                                                                      |
| Sync-AllGitRepos             | Pulls all repositories starting with octo-*                                                                                     |
| Sync-AllGitSubmodules        | Pulls all submodules of all repositories starting with octo-*                                                                   |
| Sync-GitRepo                 | Pulls a repository from github using the current directory by default or defining by parameter repositoryPath                   |
| Sync-Submodule               | Pulls all submodules of a repository from github using the current directory by default or defining by parameter repositoryPath |


## Configurations

In IDE's like Visual Studio or JetBrains Rider it is needed to configure some secrets
- [Configure UserSecrets](./docs/configureUserSecrets.md)

Here is a list of users that are needed for main services to connect to mongodb.

| User                    | Default Password in dev environment | Comment                                                                                                    |
|-------------------------|-------------------------------------|------------------------------------------------------------------------------------------------------------|
| octo-system-admin       | OctoAdmin1                          | User for creating tenants and configuration tenant independent                                             |     
| octo-system-ds-user-{0} | OctoUser1                           | User that access a mongodb database for a specific tenant, the placeholder {0} is the name of the database |     


## Git and repositories

All git repositories are hosted on GitHub, all packages are hosted on nuget or npmjs.

We decided to use SSH keys to connect to github, therefore are some good-to-know issues documented at [Configure Git](./docs/configureGit.md).

To clone the main repos, you need to run the command ```Invoke-CloneMainRepos``` within the PowerShell with Octo Mesh profile.

## Build and start services

Once the requirements have been met, there are following scripts that can be used to build the project and start the services.

After build, the infrastructure services needs to be started. To handle the steps to install, start, stop or uninstall you find [here](./docs/startInfraOnDocker.md)

```powershell
Invoke-BuildAll
Install-OctoInfrastructure # First time
Start-OctoInfrastructure  # After install
Start-Octo
``` 

After that, the following services should be available:

- [**Asset Repo Service** (https://localhost:5001)](https://localhost:5001)
- [**Identity Service** (https://localhost:5003)](https://localhost:5003)
- [**Admin Panel** (https://localhost:5005)](https://localhost:5005)
- [**Bot Service** (https://localhost:5009)](https://localhost:5009)
- [**Time Repo Service** (https://localhost:5013)](https://localhost:5013)
- [**Communication Controller Service** (https://localhost:5015)](https://localhost:5015)

## Create the first user account

Go to the [Identity service](https://localhost:5003) to create the first admin user.<br>
After that, new data sources can be created in the [Admin Panel](https://localhost:5005).

## General

Additional useful information can be found in the following files:

- [**Octo CLI**](../ospTool.md)
- [**Graph QL samples** (graphQLSamples.md)](../graphQLSamples.md)
- [**NPM** (npm.md)](../npm.md)

## Troubleshooting

### Issues with `.NET dev certificates` under Linux

To confirm a certificates issue, run the following command in PowerShell:

```shell
http get https://localhost:5003/.well-known/openid-configuration
```

It is confirmed if the console output contains the following error: `CERTIFICATE_VERIFY_FAILED`.

**Solution:**<br>
Details on how to solve this issue can be found
under [System Requirements](./docs/systemRequirements.md).
