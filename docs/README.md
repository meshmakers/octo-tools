# OCTO MESH getting started

Transforming data into value.

OCTO MESH revolutionizes the way companies exchange data between software applications by providing both connectivity and intelligent data mapping and transformation capabilities. OCTO MESH solves the challenges of data incompatibility, connectivity and mapping, enabling seamless and efficient data exchange. OCTO MESH accompanies organizations on their digital transformation journey with optimized connections and couplings, strong security measures and an intuitive user interface. Companies are thus discovering the full potential of their data and promoting innovation, efficiency and well-founded decisions in today's data-driven world.

## System requirements

For the development environment, it must be ensured that all system requirements are met.<br>
Details can be found in [here](./systemRequirements.md).

## OCTO MESH PowerShell 

OCTO MESH PowerShell enables to simplyfi the process of cloning, building and starting Octo Mesh including infrastructure.

To get started, clone repository https://github.com/meshmakers/octo-tools to a directory like ~/source/meshmakers/octo-tools.
```
mkdir ~/source/meshmakers/
cd ~/source/meshmakers/
git clone git@github.com:meshmakers/octo-tools.git
```

Add to your Powershell Profile the Octo Mesh profile by extending the profile. In this case we use Visual Studio Code so we expect that code is available in your PATH environment variable.

```powershell
code $PROFILE
``` 

Add to the profile:
```powershell
. "~/source/meshmakers/octo-tools/modules/profile.ps1"
``` 

Restart powershell, during start you should see a message like
```powershell
Loading Octo Profile
``` 



## Configurations

The following files provide support for the configurations:

- [configureUserSecrets](./configureUserSecrets.md)

You can choose to run the infrastructure either locally...

- [configureMongoDb](./configureMongoDb.md)
- [configureRedisServer](./configureRedisServer.md)

... or run it in docker containers

- [start infrastructure in docker-compose](./startInfraOnDocker.md)‚


## Git and NuGet repositories

Difficulties with cloning the project or with private NuGet repositories are dealt with
in [cloneTheProject.md](./cloneTheProject.md).

## Build and start services

Once the requirements have been met, the script [buildAndstartservices.ps1](../../buildAndstartservices.ps1) can be used
to build the project and start the services.

After that, the following services should be available:

- [**Core Service** (https://localhost:5001)](https://localhost:5001)
- [**Identity Service** (https://localhost:5003)](https://localhost:5003)
- [**Dashboard** (https://localhost:5005)](https://localhost:5005)
- [**Job Service** (https://localhost:5009)](https://localhost:5009)

## Create the first user account

Go to the [Identity service](https://localhost:5003) to create the first admin user.<br>
After that, new data sources can be created in the [Dashboard](https://localhost:5005).

## General

Additional useful information can be found in the following files:

- [**OSP CLI - OspTool** (ospTool.md)](../ospTool.md)
- [**Graph QL samples** (graphQLSamples.md)](../graphQLSamples.md)
- [**NPM** (npm.md)](../npm.md)

## Troubleshooting

### WARNING: Service redis-server is in status Completed

When starting the project, the error message `WARNING: Service redis-server is in status Completed` appears before the
services are stopped again.

**Solution**:<br>
Make sure that the Redis server is not running when the project is started. It is automatically started with the script.

### Issues with `.NET dev certificates` under Linux

To confirm a certificates issue, run the following command in PowerShell:

```shell
http get https://localhost:5003/.well-known/openid-configuration
```

It is confirmed if the console output contains the following error: `CERTIFICATE_VERIFY_FAILED`.

**Solution:**<br>
Details on how to solve this issue can be found
under [systemRequirements.md](./systemRequirements.md) `Install .NET SDK 6`.
