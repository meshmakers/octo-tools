# AGENTS.md

Instructions for coding agents in this repository. Detail lives in `docs/`; read the matching file before changing the code it covers.

## What this repo is

OctoMesh is a data transformation platform that converts raw data into meaningful information. This repository contains PowerShell-based development tools for building, deploying, and managing OctoMesh infrastructure.

### Key Technologies

- **Primary Language**: PowerShell scripting
- **Platform**: .NET 10.0 microservices
- **Infrastructure**: a local kind cluster (`Install-OctoKubernetes`) with MongoDB, CrateDB and RabbitMQ is the only supported local infrastructure. The Docker Compose setup is deprecated, removal 2026-12-31 (AB#7141)
- **Frontend**: Angular — Data Refinery Studio (octo-frontend-refinery-studio)

### Architecture

The system uses a microservices architecture with:
- MongoDB replica set (3 nodes on ports 27017-27019) for data storage
- CrateDB cluster (3 nodes on ports 4201-4203) for distributed SQL
- RabbitMQ (ports 5672, 15672) for message queuing
- Multiple .NET microservices for business logic

### Project Structure

- `/modules/` - PowerShell modules for all development commands
- `/tests/` - Pester 5 tests (`Invoke-Pester ./tests`; install with `Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser`, without `-MaximumVersion` you get Pester 6; on Windows with Controlled Folder Access, which blocks Documents\PowerShell\Modules, `New-Item -ItemType Directory -Force ~/.local/share/powershell/Modules`, then `Save-Module ... -Path ~/.local/share/powershell/Modules`, which `profile.ps1` adds to PSModulePath on Windows - load the profile or add the folder to `$env:PSModulePath` yourself; also for powershell-yaml); they use a fake checkout in `TestDrive` and mock the build step - never run real builds or touch the real NuGet folders from tests
  - Faster, same files: `./tests/Invoke-ParallelPester.ps1 [-Path <folder|files>] [-ThrottleLimit <n>] [-PassThru]` runs every `*.Tests.ps1` in its own pwsh process (default: up to 8 at a time, biggest files first) and merges the results; exit code 1 when any file has a failed test, a failed block or container, no result or no test at all (`tests/ParallelPester.Tests.ps1`). `Invoke-Pester ./tests` stays the reference run
  - Keep the suite fast (AB#8811): fixtures go into `$TestDrive`, never `[IO.Path]::GetTempPath()` (PowerShell's file cmdlets cost 30-150 ms per call below a temp folder with tens of thousands of entries); a fixture that needs many `git` calls is built once per file and copied per test (`New-FakeWorkspace` / `Initialize-FakeWorkspaceTemplate` in `tests/OctoEnvironment.TestHelpers.ps1`: a native process started from pwsh costs 15-30 ms); a test file that grows past about a minute is split (the `OctoEnvironment*.Tests.ps1` files share that helper), because the parallel run is as slow as its slowest file
- `/infrastructure/` - Docker Compose configuration and MongoDB init scripts (deprecated, removal 2026-12-31)
- `/kubernetes/` - Local kind cluster manifests, Helm values, and the dev-env runbooks (`README.md` / `QUICKSTART.md`)
- `/assets/` - Terminal profile assets and logos

### Important Notes

- The build system handles frontend projects specially by cleaning node_modules
- Zenon plug-in projects require Windows and use MSBuild
- All PowerShell modules are automatically loaded via profile.ps1
- Custom user profiles can be added in `~/.pwsh/profile.ps1`
- Local infrastructure runs in the kind cluster (`kubernetes/`); `infrastructure/docker-compose.yml` is deprecated (removal 2026-12-31)

## Read before you change

<!-- >>> generated: routing -->
| When you change | Read first |
|---|---|
| `modules/Register-OctoCliContext.psm1`, `modules/Invoke-OctoTenantSweep.psm1`, `modules/Invoke-IdentityOverlay.psm1`, `modules/Get-RancherKubeConfig.psm1`, `modules/Request-BreakGlassKubeConfig.psm1`, `overlays/**`, `tests/RegisterOctoCliContext.Tests.ps1`, `tests/OctoTenantSweep.Tests.ps1`, `tests/InvokeIdentityOverlay.Tests.ps1` | `docs/authentication-and-cluster-access.md` |
| `modules/Invoke-Build*.psm1`, `modules/OctoBuildOrder.psm1`, `modules/Sync-OctoCkIntermediateVersions.psm1`, `modules/scripts/**`, `tests/BuildRange.Tests.ps1`, `tests/LaneIsolation.Tests.ps1`, `tests/CompileRepo.Tests.ps1`, `tests/CkIntermediateSync.Tests.ps1`, `tests/RelativeRepositoryPath.Tests.ps1` | `docs/build-commands.md` |
| `modules/Get-CiWasteReport.psm1`, `tests/CiWasteReport.Tests.ps1` | `docs/ci-waste-report.md` |
| `modules/OctoDevStack.psm1`, `tests/OctoDevStack.Tests.ps1` | `docs/devstack-daemon.md` |
| `modules/OctoEnvironment.psm1`, `modules/OctoBuildStamp.psm1`, `modules/OctoCkCatalogRefresh.psm1`, `tests/OctoEnvironment*.Tests.ps1`, `tests/OctoConsumerApps.Tests.ps1` | `docs/feature-environments.md` |
| `modules/Get-OctoToolsConfig.psm1`, `modules/Register-OctoCliContext.psm1` | `docs/installations-config.md` |
| `modules/OctoJsonOutput.psm1`, `tests/BuildEvents.Tests.ps1` | `docs/json-output.md` |
| `infrastructure/**`, `kubernetes/**`, `modules/*Infrastructure*.psm1`, `modules/Install-OctoKubernetes.psm1`, `modules/OctoComposeInfra.psm1`, `modules/OctoKubernetesS3Store.psm1`, `modules/Deploy-OctoOperator.psm1`, `modules/Start-Octo.psm1`, `modules/Stop-Octo.psm1`, `tests/OctoComposeInfra.Tests.ps1`, `tests/UpdateOctoCrateDb.Tests.ps1`, `tests/OctoKubernetesS3Store.Tests.ps1` | `docs/local-infrastructure.md` |
| `modules/Sync-AllGitRepos.psm1`, `modules/Sync-GitRepo.psm1`, `modules/Push-AllGitRepos.psm1`, `modules/Get-AllGitRepStatus.psm1`, `modules/Invoke-CleanAllGitRepos.psm1`, `modules/OctoTestBranch.psm1`, `modules/New-TestBranch.psm1`, `modules/Compare-CkVersions.psm1`, `modules/Get-CiWasteReport.psm1`, `modules/Invoke-KillDotnet.psm1`, `modules/Remove-BinAndObjFolders.psm1`, `modules/Remove-GlobalNuGetPackages.psm1`, `modules/Copy-NuGetPackages.psm1`, `modules/Copy-AllNuGetPackages.psm1`, `modules/Sync-NuGetPackages.psm1`, `tests/TestBranch.Tests.ps1`, `tests/KillDotnet.Tests.ps1` | `docs/repository-and-cleanup-commands.md` |
| `modules/OctoTests.psm1`, `tests/OctoTests.Tests.ps1` | `docs/running-tests.md` |
| `modules/Invoke-OctoTenantSweep.psm1`, `tests/OctoTenantSweep.Tests.ps1` | `docs/tenant-sweep.md` |
<!-- <<< end generated: routing -->

## Build & test

### Common Development Commands

All commands require PowerShell and are available after loading the profile:
```powershell
. .\modules\profile.ps1
```

### Development Workflow

1. Start infrastructure: `Install-OctoKubernetes` (first time; afterwards the kind cluster keeps running or is started with Docker)
2. Build projects: `Invoke-BuildAll`
3. Start application: `Start-Octo`
4. Make changes and rebuild as needed
5. Clean up when done: `Stop-Octo` (the kind infra keeps running; `Uninstall-OctoKubernetes` deletes it with its data)

## Before you commit

Build and run the tests as described above.

## Rules

