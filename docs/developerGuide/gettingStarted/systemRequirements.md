# System Requirements

The development environment requires the packages and tools listed below.</br>

Required packages and tools:

- .NET IDE, Visual Studio 2022 (or newer) or JetBrains Rider
- .NET SDK 8.0
- PowerShell 7 (.NET Core variant)
- Docker Desktop including docker compose
- Node 20
- Angular CLI 15

## Infrastructure Components
Infrastructure components are installed by using Octo's powershell command ```Install-OctoInfrastructure```

Optional tools:

- [MongoDB Compass](https://www.mongodb.com/products/compass0)


Only SDKs needs to be installed locally, infrastructure components are setup by using Octo's powershell command ```Install-OctoInfrastructure```

## Install .NET SDK 8

### Debian bullseye

Add the package repository. For details please
click [here](https://docs.microsoft.com/en-us/dotnet/core/install/linux-debian).

```shell
wget https://packages.microsoft.com/config/debian/11/packages-microsoft-prod.deb -O packages-microsoft-prod.deb
```

```shell
sudo dpkg -i packages-microsoft-prod.deb
```

```shell
rm packages-microsoft-prod.deb
```

Install the package.

```shell
sudo apt update && sudo apt install dotnet-sdk-8.0
```

In addition, the .NET dev certificates must be activated, as there is a general problem here under Linux.
Details can be found [here](https://blog.wille-zone.de/post/aspnetcore-devcert-for-ubuntu/).</br>
Download or clone the script from [GitHub]() and run it.

```shell
./scripts/ubuntu-create-dotnet-devcert
```

### Windows 

```powershell
winget install Microsoft.DotNet.SDK.8
```

## Install PowerShell

### Debian bullseye

Download and install the `.deb` file. For details please click [here](https://github.com/PowerShell/PowerShell).

### Windows

```powershell
winget install --id Microsoft.Powershell --source winget
```

## Install Node

Node should be available in apt, but it is highly recommended to
use [Node Version Manager](https://github.com/nvm-sh/nvm).

### Debian bullseye

See documentation

### Windows 

```powershell
winget install -e --id CoreyButler.NVMforWindows
```
Start new Terminal

```powershell
nvm install lts
nvm use lts
```

### MacOS

```powershell
brew install nvm
nvm install --lts
nvm use --lts
```

## Install Angular CLI

If Node has already been installed, the Angular CLI can be installed via npm.

```powershell
npm install -g @angular/cli
```