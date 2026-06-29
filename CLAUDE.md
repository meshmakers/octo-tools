# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

OctoMesh is a data transformation platform that converts raw data into meaningful information. This repository contains PowerShell-based development tools for building, deploying, and managing OctoMesh infrastructure.

## Key Technologies

- **Primary Language**: PowerShell scripting
- **Platform**: .NET 10.0 microservices
- **Infrastructure**: Docker Compose with MongoDB replica set, CrateDB cluster, and RabbitMQ
- **Frontend**: Angular — Data Refinery Studio (octo-frontend-refinery-studio)

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

### Machine-readable output (`-Json`)
Most query/status/compare commands (and many action commands) accept a `-Json` switch that suppresses
the colored human output and instead writes a single JSON document to the success stream, so the result
can be parsed by scripts, CI, or agents (`... -Json | ConvertFrom-Json`, or `... -Json > out.json`).

Every `-Json` document shares the same envelope:
```json
{ "schemaVersion": 1, "command": "Get-AllGitRepStatus", "timestamp": "<ISO-8601 UTC>", "data": <command-specific> }
```
- Query/compare commands put their results in `data` (e.g. an array of repo statuses, build results, version-diff rows).
- Pure action commands put a `{ "success": <bool>, "exitCode": <int>, ... }` summary in `data`.
- Interactive/blocking commands (the `Invoke-OctoCliLogin*` logins, `Invoke-MongoPortForward`, `Start-Octo`)
  do **not** support `-Json` — a single-emit JSON contract is meaningless while they block on input.
- Secret-bearing commands (`Get-RancherKubeConfig`, `Request-BreakGlassKubeConfig`) emit only safe metadata
  (cluster/context/expiry) under `-Json`; they never include the kubeconfig or any token.

The shared helpers live in `modules/OctoJsonOutput.psm1` (`Write-OctoJson`, `New-OctoActionResult`), loaded
first by `profile.ps1`. New cmdlets should reuse them rather than calling `ConvertTo-Json` directly (the
helper sets a safe `-Depth` so nested data isn't silently truncated).

### Building
- `Invoke-BuildAll` - Build all repositories (use `-configuration Debug` for debug builds)
- `Invoke-Build -repositoryPath .` - Build a single repository
- `Invoke-BuildAndStartOcto` - Build everything and start the application

### Infrastructure Management
- `Start-OctoInfrastructure` - Start Docker infrastructure (MongoDB, CrateDB, RabbitMQ)
- `Stop-OctoInfrastructure` - Stop Docker infrastructure
- `Install-OctoInfrastructure` - Initial infrastructure setup
- `Get-OctoInfrastructureStatus` - Check infrastructure status
- `Start-Octo` - Start the Octo application after infrastructure is running
- `Stop-Octo` - Stop services started in non-interactive mode (`Start-Octo -nonInteractive $true`)

### Local Kubernetes (Kind) dev environment
An alternative to the docker-compose infrastructure: MongoDB/RabbitMQ/CrateDB, the CRDs, and the Communication Operator run inside a local [kind](https://kind.sigs.k8s.io/) cluster (the core .NET services still run as host processes via `Start-Octo`). The two infra modes share the same host ports and **cannot run at the same time**. Full runbook: `kubernetes/README.md`; from-scratch setup: `kubernetes/QUICKSTART.md`.
- `Install-OctoKubernetes` - Create the kind cluster + CRDs + namespaces + in-cluster infra + ingress-nginx/cert-manager, then deploy the operator (idempotent; refuses while the docker-compose infra is up)
- `Deploy-OctoOperator` - (Re)deploy the Communication Operator standalone from the dev registry (`:main-latest`)
- `Get-OctoKubernetesStatus` - Show pods, Helm releases, and host-port reachability for the kind cluster
- `Uninstall-OctoKubernetes` - Delete the kind cluster and its data (also removes the local CA trust unless `-KeepCaTrust`)
- `Add-OctoLocalCaTrust` / `Remove-OctoLocalCaTrust` - Trust/untrust the local root CA ("OctoMesh Local Dev Root CA") in the OS trust store
- `Import-OctoImageToKind` - Load a locally-built image into the kind node
- `Register-OctoCliContext` - Set up the unified octo-cli context for the local environment

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
- `Register-OctoCliContext` - Unified login for all installations (`-Installation local|test-2|staging-1|prod-1|prod-2`, `-IncludeReporting`, `-IncludeAi`, `-UriSuffix`, `-NoSwitch`, `-NoLogin`, `-Json`). Replaces the removed per-environment `Invoke-OctoCliLogin{Local,Production,Staging,Test2}` helpers.

### Identity Overlays (AB#4209 Step 4)
- `Apply-IdentityOverlay` - Fans `octo-cli -c ApplyClientOverlay` across the blueprint-managed clients listed in an overlay YAML file (default: `overlays/identity-local-dev.yaml`). Idempotent — re-running on the same DB is a no-op (server dedupes against existing URIs). Per-client log lines show Added/SkippedDuplicate counts. Add `-DryRun` to print the invocations without calling out. Uses the active octo-cli context (login first with `Register-OctoCliContext -Installation local` or similar). Standalone today; Start-Octo wiring (`-SkipOverlay` opt-out) lands in a follow-up. Concept: `octo-platform-services/docs/concepts/phase-3-followup-identity-local-dev-overlay.md` §4.3.

### Cluster Access (Rancher / Break-Glass)
Two paths for Kubernetes access to managed clusters (test-2, staging-1, prod-1, prod-2, infra, local):
- `Get-RancherKubeConfig -Cluster <name>` - Routine read-only access. Fetches a kubeconfig via the Rancher v3 API using your personal `RANCHER_API_TOKEN` and merges it into `~/.kube/config`. The resulting kubeconfig inherits whatever permissions the token user has — for AD users this is the read-only role set (no secrets, no exec, no write). Requires `RANCHER_URL` (set in `profile.ps1`) and `RANCHER_API_TOKEN` (set in the private profile, format `token-xxxxx:secret`, created in Rancher UI -> Account & API Keys).
- `Request-BreakGlassKubeConfig -Cluster <name> -Reason "..." -DurationHours <1-4>` - Write access for incidents. Triggers a Semaphore playbook that provisions a short-lived `cluster-admin` ServiceAccount token via Vault response-wrapping, with audit entries in Semaphore, Vault, K8s audit log, and the `ops-breakglass` Teams channel. Used for incident response only; the token TTL closes the window automatically and an hourly cleanup reaps the SA/CRB. Full runbook in `meshmakers-infrastructure/docs/BREAK-GLASS-ACCESS.md`.

No persistent `cluster-owner` is bound to any AD group on the managed clusters — write access must always go through the break-glass flow.

## Project Structure

- `/modules/` - PowerShell modules for all development commands
- `/infrastructure/` - Docker Compose configuration and MongoDB init scripts
- `/kubernetes/` - Local kind cluster manifests, Helm values, and the dev-env runbooks (`README.md` / `QUICKSTART.md`)
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