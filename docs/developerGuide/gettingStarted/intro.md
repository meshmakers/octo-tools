
# Octo Mesh getting started

Transforming data into value.

Octo Mesh revolutionizes the way companies exchange data between software applications by providing both connectivity and intelligent data mapping and transformation capabilities. Octo Mesh solves the challenges of data incompatibility, connectivity and mapping, enabling seamless and efficient data exchange. Octo Mesh accompanies organizations on their digital transformation journey with optimized connections and couplings, strong security measures and an intuitive user interface. Companies are thus discovering the full potential of their data and promoting innovation, efficiency and well-founded decisions in today's data-driven world.


## Setting up development environment

For the development environment, mainly .NET SDK and NodeJs needs to be installed. Please check the details [here](./systemRequirements.md).

### Configuration

In IDE's like Visual Studio or JetBrains Rider it is needed to configure some secrets
- [Configure UserSecrets](./configureUserSecrets.md)

Here is a list of users that are needed for main services to connect to mongodb.

| User                    | Default Password in dev environment | Comment                                                                                                    |
|-------------------------|-------------------------------------|------------------------------------------------------------------------------------------------------------|
| octo-system-admin       | OctoAdmin1                          | User for creating tenants and configuration tenant independent                                             |     
| octo-system-ds-user-{0} | OctoUser1                           | User that access a mongodb database for a specific tenant, the placeholder {0} is the name of the database |     


## Octo Mesh PowerShell

Octo Mesh PowerShell enables to simplify the process of cloning, building and starting Octo Mesh including infrastructure.

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
- $NUGETPATH: The directory of stored nuget packages of octo mesh. e. g. ~/Development/meshmakers/nuget
- $GLOBALNUGETPACKAGESPATH: The global nuget package path of .NET. e. g. {use profile path}/.nuget/packages/

### Definitions

- Main Repositories: All repositories that are the "core" of Octo Mesh, currently all except Plugs and Sockets. They are connecting directly or indirectly to MongoDB directly.
- Main Services: The services of the main repositories

### Commands

| Command                      | Description                                                                                                         |
|------------------------------|---------------------------------------------------------------------------------------------------------------------|
| Invoke-CloneMainRepos        | Clones all main repositories to your root directory.                                                                |
| Invoke-BuildAll              | Builds all repositories starting with octo-* and a solution file (*.sln).                                           |
| Invoke-Build                 | Builds a repository for .NET using the current directory by default or defining by parameter repositoryPath         |
| Start-Octo                   | Starts the main services                                                                                            |
| Invoke-BuildAndStartOcto     | Builds all repositories and starts the main services                                                                |
| Install-OctoInfrastructure   | Uses the docker compose file located at [infrastructure](https://github.com/meshmakers/octo-tools/blob/main/infrastructure/docker-compose.yml) to compose the infrastructure dependencies |
| Uninstall-OctoInfrastructure | Uninstalls the infrastructure dependencies by using docker compose file at  [infrastructure](./infrastructue)       |
| Start-OctoInfrastructure     | Starts the infrastructure dependencies by using docker compose file at [infrastructure](https://github.com/meshmakers/octo-tools/blob/main/infrastructure/docker-compose.yml)            |
| Stop-OctoInfrastructure      | Stops the infrastructure dependencies by using docker compose file at [infrastructure](https://github.com/meshmakers/octo-tools/blob/main/infrastructure/docker-compose.yml)             |
| Get-OctoInfrastructureStatus | Gets the status of containers by using docker compose file at [infrastructure](./infrastructue)                     |
| Push-GitRepo                 | Push a repository to github using the current directory by default or defining by parameter repositoryPath          |
| Push-AllGitRepos             | Push all repositories starting with octo-*                                                                          |
| Sync-AllGitRepos             | Pulls all repositories starting with octo-*                                                                         |
| Sync-AllGitSubmodules        | Pulls all submodules of all repositories starting with octo-*                                                       |
| Sync-GitRepo                 | Pulls a repository from github using the current directory by default or defining by parameter repositoryPath       |
| Sync-Submodule               | Pulls all submodules of a repository from github using the current directory by default or defining by parameter repositoryPath |
| Copy-AllNugetPackages        | Scans all octo-* and mm-* directories for nuget packages for version 999.0.0 an copies them to $NUGETPATH           |
| Remove-GlobalNugetPackages   | Removes in global nuget package folder ($GLOBALNUGETPACKAGESPATH) all meshmaker nuget packages in version 999.0.0   |
| Sync-NugetPackages     | Copies, removes globally and restores nuget packages                                                                |

# Start Octo Mesh

## Clone repositories

All git repositories are hosted on GitHub, all packages are hosted on nuget or npmjs.

We decided to use SSH keys to connect to github, therefore are some good-to-know issues documented at [Configure Git](./configureGit.md).

To clone the main repos, you need to run the command ```Invoke-CloneMainRepos``` within the PowerShell with Octo Mesh profile.

## Build and start services

Once the requirements have been met, there are following scripts that can be used to build the project and start the services.

After build, the infrastructure services needs to be started. To handle the steps to install, start, stop or uninstall you find [here](./startInfraOnDocker.md)

```powershell
Invoke-BuildAll
Install-OctoInfrastructure # First time
Start-OctoInfrastructure  # Second time+
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
After that, new tenants can be created in the [Admin Panel](https://localhost:5005).

# Further reading

Additional useful information can be found in the documentation of Octo Mesh available at https://docs.meshmakers.cloud


# Troubleshooting

## Issues with `.NET dev certificates` under Linux

To confirm a certificates issue, run the following command in PowerShell:

```shell
http get https://localhost:5003/.well-known/openid-configuration
```

It is confirmed if the console output contains the following error: `CERTIFICATE_VERIFY_FAILED`.

**Solution:**<br>
Details on how to solve this issue can be found
under [System Requirements](./systemRequirements.md).
