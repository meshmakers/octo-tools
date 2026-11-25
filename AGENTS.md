# AGENTS.md

Instructions for coding agents in this repository. Detail lives in `docs/`; read the matching file before changing the code it covers.

## What this repo is

`octo-tools` is the PowerShell tooling that builds, tests and runs the OctoMesh platform on a developer machine, plus
the local stack daemon in `devstack/` (C#; it has its own `devstack/CLAUDE.md`). The repository is public.

- `modules/` - one module per cmdlet group, imported by `modules/profile.ps1` (`tests/ProfileImports.Tests.ps1` fails
  for a module the profile does not import). `Invoke-BuildAll` picks the builder per repository: `Invoke-Publish` for
  names containing `frontend`, `Invoke-BuildZenonPlug` (Windows only) for `octo-plug-zenon`, else `Invoke-Build`
  (`modules/Invoke-BuildAll.psm1:20-26`); a `build.ps1` in the repository takes precedence over all three
  (`:9-10`).
- `tests/` - Pester 5 tests; `docs/testing.md`.
- `kubernetes/` - manifests and runbooks (`README.md`, `QUICKSTART.md`) of the local kind cluster, the only supported
  local infrastructure: MongoDB and CrateDB as single-replica StatefulSets, RabbitMQ, a local S3 store; host ports in
  `kubernetes/kind-cluster.yaml:20-27`. The .NET services run as host processes via `Start-Octo`.
- `infrastructure/` - the deprecated docker-compose infrastructure (planned removal 2026-12-31).
- `overlays/` identity overlay YAML, `metrics/` Python scripts of the scheduled reports in `.github/workflows/`,
  `assets/` logos.

## Read before you change

<!-- >>> generated: routing -->
| When you change | Read first |
|---|---|
| `modules/*OctoCliContext.psm1`, `modules/*TenantSweep.psm1`, `modules/*IdentityOverlay.psm1`, `modules/*KubeConfig.psm1`, `overlays/**` | `docs/authentication-and-cluster-access.md` |
| `modules/Invoke-Build*.psm1`, `modules/OctoBuildOrder.psm1`, `modules/Sync-OctoCk*.psm1`, `modules/scripts/**`, `tests/BuildRange.Tests.ps1` | `docs/build-commands.md` |
| `modules/Get-CiWasteReport.psm1`, `tests/CiWasteReport.Tests.ps1` | `docs/ci-waste-report.md` |
| `modules/OctoDevStack.psm1`, `tests/OctoDevStack.Tests.ps1` | `docs/devstack-daemon.md` |
| `modules/OctoEnvironment.psm1`, `modules/OctoBuildStamp.psm1`, `modules/OctoCkCatalog*.psm1`, `tests/OctoEnvironment*.Tests.ps1` | `docs/feature-environments.md` |
| `modules/Get-OctoToolsConfig.psm1`, `modules/Register-OctoCliContext.psm1` | `docs/installations-config.md` |
| `modules/OctoJsonOutput.psm1`, `tests/BuildEvents.Tests.ps1` | `docs/json-output.md` |
| `infrastructure/**`, `kubernetes/**`, `modules/*Infrastructure*.psm1`, `modules/*Kubernetes*.psm1`, `modules/OctoComposeInfra.psm1`, `modules/Start-Octo.psm1` | `docs/local-infrastructure.md` |
| `modules/*GitRep*.psm1`, `modules/*TestBranch.psm1`, `modules/Compare-CkVersions.psm1`, `modules/Invoke-KillDotnet.psm1`, `modules/*NuGetPackages.psm1`, `modules/Remove-BinAndObjFolders.psm1` | `docs/repository-and-cleanup-commands.md` |
| `modules/OctoTests.psm1`, `tests/OctoTests.Tests.ps1` | `docs/running-tests.md` |
| `modules/Invoke-OctoTenantSweep.psm1`, `tests/OctoTenantSweep.Tests.ps1` | `docs/tenant-sweep.md` |
| `tests/**` | `docs/testing.md` |
<!-- <<< end generated: routing -->

## Build & test

Load the cmdlets once per pwsh session, then run the tests with Pester 5 (5.5 to 5.99; installation:
`docs/testing.md`):

```powershell
. ./modules/profile.ps1
Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99
Invoke-Pester ./tests                      # reference run
./tests/Invoke-ParallelPester.ps1          # the same files in parallel processes, one merged result
```

Local workflow of the tools themselves: `Install-OctoKubernetes` (first time), `Invoke-BuildAll`,
`Start-Octo -nonInteractive $true`, `Stop-Octo` (the kind infrastructure keeps running; `Uninstall-OctoKubernetes`
deletes it with its data).

## Before you commit

1. `./tests/Invoke-ParallelPester.ps1` with Pester 5 reports no failed test; the workflow `.github/workflows/pester.yml`
   runs the same on every pull request.
2. Changed behaviour of a cmdlet: update `readme.md` and the routed doc of that cmdlet in the same commit.
3. Touched `AGENTS.md` or a file in `docs/`: `Test-OctoAgentDocs -Fix` reports 0 errors. It rewrites the generated
   routing table, so run it before you stage.

## Rules

- **This repository is public.** No work item ids, internal hostnames, environment, customer or tenant names, or
  secrets in docs and `readme.md` (`Test-OctoAgentDocs` scans both) and in new or changed code comments and test
  names; remove an existing one when you touch its line
  (several hundred `AB#` ids remain in code comments and tests). Not ids: the format placeholders `AB#..` and
  `AB#<id>` of the `-workItem` parameter and the branch pattern.
- **Stop processes and delete folders only inside one lane.** Other sessions run builds, services and the shared
  devstack daemon on the same machine. Stop dotnet processes only through `Invoke-KillDotnet -branchRootPath <lane>`: it
  refuses a folder that is not a lane (`modules/Invoke-KillDotnet.psm1:233-243`) and never selects the daemon
  (`:324-327`; tests `tests/KillDotnet.Tests.ps1:115` and `:138`); never by process name. `Remove-BinAndObjFolders`
  deletes below `-path`, whose default is the current folder (`modules/Remove-BinAndObjFolders.psm1:4`): always pass
  the lane. Exception: `Invoke-KillDotnet` without `-branchRootPath` is the legacy mode that kills every dotnet process
  on Windows (`docs/repository-and-cleanup-commands.md`). Second exception: the deprecated docker-compose
  `Install-OctoInfrastructure` stops every Docker process by name pattern (`Get-Process *docker* | Stop-Process`,
  `modules/Install-OctoInfrastructure.psm1:194`); it is removed with that infrastructure.
- **No credential or token reaches a command line, a log or `-Json`.** Feed URLs with `user:password@` are masked by
  `Hide-OctoUrlCredentials` (`modules/OctoBuildOrder.psm1:226`) wherever the build cmdlets print or return their MSBuild
  properties (`modules/Invoke-BuildRange.psm1:517`, `:1490`), and the credentials themselves travel in an owner-only
  `RestoreConfigFile` (`modules/OctoEnvironment.psm1:2780`; test `tests/OctoEnvironment.Tests.ps1:648`).
  `Invoke-OctoTenantSweep` never opens the octo-cli context file and scrubs token-shaped text (test
  `tests/OctoTenantSweep.Tests.ps1:164-172` also fails when its source gains a file or web cmdlet). `-Json` of
  `Get-RancherKubeConfig` and `Request-BreakGlassKubeConfig` carries metadata only
  (`modules/Get-RancherKubeConfig.psm1:186-195`, `modules/Request-BreakGlassKubeConfig.psm1:282-289`). A new command
  that handles a token follows the same pattern and adds a canary test like `tests/OctoTenantSweep.Tests.ps1`
  (canary defined at `:17`, asserted at `:141-157`).
- **Four pieces of logic have a twin elsewhere; change both together.** The start order of
  `Start-Octo` (`modules/Start-Octo.psm1:375`) and the built-in `startAfter` of the daemon, pinned by
  `devstack/tests/DevStack.Tests/ConfigurationTests.cs:143-156`; `modules/scripts/Sync-CkIntermediateVersions.ps1`, a
  verbatim copy of the step `templates/steps/ck-sync-intermediate-versions.yml` of `octo-pipeline-templates`
  (`modules/Sync-OctoCkIntermediateVersions.psm1:20`); `modules/Update-OctoCrateDb.psm1:3-4` and the customer script
  `scripts/om-upgrade-cratedb.ps1` of the getting-started repository; `Get-OctoRepoBuildMode`
  (`modules/Invoke-BuildRange.psm1:104`), which mirrors the builder dispatch of `Get-RepoBuilder` in
  `modules/Invoke-BuildAll.psm1:3-26`. Nothing in the build or the tests here notices a
  twin that was not changed.
- **Run and install the shared devstack daemon only from the main octo-tools checkout, never from a worktree** (`wt-*`,
  `.claude/worktrees`, a feature environment). A worktree has its own `devstack/`, `Remove-OctoEnvironment` deletes it
  with the worktree, and `Start-OctoDevStackDaemon` / `Install-OctoDevStackDaemonService` do not refuse a worktree: they
  default to the `devstack/` of the octo-tools they were loaded from (`modules/OctoDevStack.psm1:29`). Detail:
  `docs/devstack-daemon.md`.
