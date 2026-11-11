OctoMesh is a powerful tool designed to seamlessly transform raw data into meaningful information, all while ensuring that the data is imbued with the context it needs to be truly insightful. Whether you're working with structured data, unstructured data, or anything in between, OctoMesh empowers you to harness the full potential of your data.

This repository contains tools to simplify the development and deployment of OctoMesh. It includes a PowerShell profile to simplify the development process and a set of scripts to manage the local infrastructure. **kind (`Install-OctoKubernetes`) is the only supported local infrastructure.** The docker-compose scripts (`Install-/Start-/Stop-/Uninstall-OctoInfrastructure`, `Backup-/Restore-OctoInfrastructure`) are deprecated and will be removed on 2026-12-31; see `kubernetes/README.md`, section "Migrating from docker-compose".

# Getting started

The complete documentation of OctoMesh is available at https://docs.meshmakers.cloud.

# Configuration

Some of the tooling needs values that are environment-specific (the OctoMesh
installations you want to talk to, your container registry, your Rancher /
Vault / Semaphore endpoints, your Telerik Kendo UI license). Those don't live
in this repo — they live in a per-developer config file outside of git.

1. **Create the config directory** and copy the example file there:

   ```bash
   mkdir -p ~/.config/octo-tools
   cp installations.example.json ~/.config/octo-tools/installations.json
   ```

   You can put the file somewhere else and point `OCTO_TOOLS_CONFIG` at it.

2. **Edit it** for your environment. See
   [`docs/installations-config.md`](docs/installations-config.md) for the
   schema reference. The minimum useful content is one `installations[]`
   entry — `local` (which the example provides) is enough for an
   all-on-localhost dev loop.

3. **Add a private profile** for anything that doesn't belong in a checked-in
   config (in particular: your Telerik Kendo UI license, your Rancher API
   token):

   * macOS: `~/.config/powershell/Microsoft.PowerShell_profile_private.ps1`
   * Linux and Windows: `~/.pwsh/profile.ps1`

   Typical content:

   ```powershell
   $env:TELERIK_LICENSE   = "<your Kendo UI license JWT — see https://www.telerik.com/account/your-licenses>"
   $env:RANCHER_API_TOKEN = "token-xxxxx:secret"
   ```

   `modules/profile.ps1` sources this file at the end of its bootstrap, so
   anything set here wins over the config-file defaults.

# Fast local loop (partial DebugL rebuilds)

`Invoke-BuildAll -configuration DebugL` is the full reset: it wipes `<lane>/nuget`, deletes the
`meshmakers.*/999.0.0` folders of every package cache the lane restores into (isolated lane, i.e. `Octo.User.props` declares `RestorePackagesPath`: `<lane>/.nuget-packages` only; a legacy lane without it - main before `Initialize-OctoLaneUserProps -branch branches/main -AddRestorePackagesPath` - the global cache `NUGET_PACKAGES` / `~/.nuget/packages`, plus `<lane>/.nuget-packages` when `-laneIsolation Off` meets a `RestorePackagesPath`; never the whole cache), forces a restore and builds every solution
including its tests. For day-to-day work on a library in the chain (e.g. the construction-kit engine) use
`Invoke-BuildRange`, which rebuilds only a slice of the same build order:

```powershell
# 1. See what would happen (repositories, src/ projects, global-cache folders to purge, running services)
Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services `
    -include octo-asset-repo-services,octo-identity-services -WhatIf

# 2. Stop the local services (their bin/DebugL output is overwritten), build, start again
Stop-Octo -branch main
Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services `
    -include octo-asset-repo-services,octo-identity-services
Start-Octo -branch main -configuration DebugL -nonInteractive $true

# 3. Before handing the change to others: also compile the test projects (they are not run)
Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services `
    -include octo-asset-repo-services,octo-identity-services -verifyTests
```

> **Test projects are not compiled by a plain range run.** Only `src/` projects are built, so a test
> project that no longer compiles against the rebuilt packages stays invisible until CI. Use
> `-verifyTests` (src first, then every project outside `src/` is compiled, nothing is run) or
> `-includeTests` (whole solutions in one build) before every hand-off; a plain run prints this
> reminder at the end and reports `testsCompiled: false` / `hint` in `-Json`.

Per repository, in build order:

0. (DebugL, AB#7974) `Sync-OctoCkIntermediateVersions` brings the private catalog's intermediate versions of the
   repository's ckLanguage 2 CK models into `<lane>/.octo/local-catalog`, so the CK compile gate does not fail with
   `OCTO-CK203` (see "CK intermediate versions" below). `-skipCkSync` turns it off.
1. `dotnet build -c DebugL -nodeReuse:false` of the solution's `src/` projects only (a temporary
   `.slnf` in the temp folder; `-includeTests` builds the whole solution, `-verifyTests` compiles
   the projects outside `src/` right after with a second `.slnf`). There is no forced restore: the
   implicit restore only re-extracts the packages that were purged.
2. `Copy-NuGetPackages -onlyChanged` copies every package of the repository that `<checkout>/nuget`
   lacks or holds in an older, different version (SHA-512 compare). Pack is incremental, so this also
   catches a package written by an earlier, interrupted run (e.g. a `-verifyTests` failure) or by an IDE
   build. Orphaned nupkgs of removed projects (a `bin/DebugL` whose project folder has no project file
   any more, e.g. `Sdk.Common.Web` in `octo-sdk` after it moved to `octo-communication-sdk`) and
   packages older than the `nuget/` copy are left alone.
3. Exactly those packages are purged from `<cache>/<id>/999.0.0`, so the next repository restores
   them fresh from `<checkout>/nuget`. Nothing else in the cache and nothing else in
   `<checkout>/nuget` is touched.

**Lanes (main, feature environments).** `Invoke-BuildRange` uses the same lane isolation as `Invoke-BuildAll`
(`Get-OctoLaneBuildSettings`, `-laneIsolation Auto|On|Off`). A lane is isolated exactly when its
`<lane>/Octo.User.props` declares `<RestorePackagesPath>` - every feature environment does, and main does after a
one-time `Initialize-OctoLaneUserProps -branch branches/main -AddRestorePackagesPath` (adds the line, keeps the rest
of the file, writes `Octo.User.props.bak`). The user-level `NuGet.Config` plays no role. An isolated lane builds with
`NUGET_PACKAGES=<lane>/.nuget-packages` and `MSBUILDDISABLENODEREUSE=1`; in DebugL, repos whose
`Directory.Build.props` declares no `<RestoreSources>` also get `RestoreSources=<lane>/nuget;nuget.org` for their
build. The environment is restored afterwards. The package cache that is purged and checked for stale packages
follows the lane: `<lane>/.nuget-packages` for an isolated lane; for a legacy lane (no `RestorePackagesPath`) the
global cache (`NUGET_PACKAGES` or `~/.nuget/packages`). `-WhatIf` prints the lane, its environment, the caches and
the per-repo `RestoreSources`.

**Private feeds for library worktrees.** `-repoPaths @{ 'octo-construction-kit-engine' = '<absolute worktree folder>' }`
builds that repository from the given folder (e.g. a git worktree) instead of `<checkout>/<repo>`, at the same
position in the build order; the folder must exist and contain a `.sln`/`.slnx` or a `src/` folder.
`-feedPath <dir>` (DebugL) copies the built packages into `<dir>` instead of `<checkout>/nuget` and purges no
package cache; the caller provides the isolation (`NUGET_PACKAGES`, `RestoreSources` in its environment - the
run does not override them). `-WhatIf` shows both, `-Json` reports `feedPath` / `repoPaths`.

**Progress events.** `-EventsFile <file>` (also on `Invoke-Build` and `Invoke-BuildAll`) appends one JSON line per
event while the run is going: `plan`, per repository `repoStart` / `phase` / `repoDone`, and a closing `done`
(also when the run refuses or throws). The contract is in `CLAUDE.md` (`-Json` section).

It stops at the first failing repository (fail fast, prints the repository name and the error lines
of its `Invoke-Build.log`) and prints per-repository timings at the end (`-Json` for a
machine-readable result). It refuses to start while processes run out of a repository in the range
(`Start-Octo` services); pass `-stopServices` to send `Stop-Octo` and wait, or
`-ignoreRunningServices` to build anyway. It never kills dotnet processes. Known gap on Windows: the
process list there has no working directory and Start-Octo starts services as `dotnet <Name>.dll`
(relative path), so running services are not detected - stop them with `Stop-Octo` first, otherwise the
build fails on locked files.

| Parameter | Meaning |
|-----------|---------|
| `-from` / `-to` | First / last repository of the range (inclusive; `-to` defaults to `-from`). Exact name, name without `octo-`, or a unique substring. |
| `-include` / `-exclude` | Add repositories outside the range (kept at their build-order position) / skip repositories inside it. |
| `-includeTests` | Build the whole solution instead of `src/` only. |
| `-verifyTests` | After each repo's `src/` build, compile its projects outside `src/` (tests, samples) without running them; fails fast with `failedStep: tests`. Extra `tests` timing column. Ignored with `-includeTests`. |
| `-laneIsolation` | `Auto` (default) / `On` / `Off`, as for `Invoke-BuildAll`. |
| `-excludeFrontend` | Default `$true`; frontends produce no NuGet packages. |
| `-configuration` | Default `DebugL`. Copy and purge only run for DebugL. |
| `-msbuildProperties` | Extra MSBuild global properties (`-p:Name=Value`) for the `dotnet build` of **every** repository in the run. Global properties override values set in project files. `Invoke-BuildAll` and `Invoke-Build` accept the same parameter. Not applied to `build.ps1` / frontend / zenon builds (warning). Do **not** use it for `OctoPublishCkModel`: that stops every CK model of the run from being published into the local catalog, so downstream CK compiles see stale models (a warning is printed when `OctoPublishCkModel=false` applies to more than one repository). |
| `-msbuildPropertiesPerRepo` | Properties for single repositories (overriding `-msbuildProperties`; a key outside the selected range is warned about, add it with `-include`), e.g. `@{ 'octo-identity-services' = @{ OctoPublishCkModel = 'false' } }` to keep only identity's CK model out of the shared local catalog. Also on `Invoke-BuildAll`. |
| `-purgeStaleCache` | Purge global-cache `999.0.0` folders whose recorded SHA-512 differs from `<checkout>/nuget` before the first build (see below). Without it they are only reported. |
| `-skipCkSync` | Skip the CK intermediate-version sync before each repository (also on `Invoke-BuildAll`). |
| `-WhatIf` / `-Json` | Print the plan only / emit one JSON document (early exits emit `success: false` and set `$LASTEXITCODE` to 1). |

The build order (`mm-*` -> pinned `octo-*` -> remaining `octo-*` alphabetically) lives in
`modules/OctoBuildOrder.psm1` (`Get-OctoBuildOrder`) and is shared with `Invoke-BuildAll`.
`Get-OctoBuildOrder -branchRootPath <checkout> | Format-Table Name, Group` shows it.

`Copy-AllNuGetPackages -branch main` (also used by `Sync-NuGetPackages`) copies the newest file per
package when several repositories contain the same `Meshmakers.*.999.0.0.nupkg` (e.g. a stale
`Sdk.Common.Web` in `octo-sdk/bin` after the project moved to `octo-communication-sdk`), warns about
such duplicates and never replaces a newer package already in `<checkout>/nuget`.

**Stale cache packages.** A package cache can hold another build of a `999.0.0` package (e.g. the
global cache that the legacy lane shares with repos and tools outside the lanes). Before building,
`Invoke-BuildRange` compares every `<checkout>/nuget/<id>.999.0.0.nupkg` with the SHA-512 NuGet
recorded for `<cache>/<id>/999.0.0` (`<id>.999.0.0.nupkg.sha512`) in each cache of the lane. A mismatch
(e.g. the folder was extracted from the dev checkout's build) or a missing hash file is reported in
`-WhatIf`, as a warning and in `-Json` (`staleGlobalCache`); `-purgeStaleCache` deletes those folders
so the restores in this checkout use its own packages.

Notes for the loop:

* Run a full `Invoke-BuildAll -branch main -configuration DebugL -excludeFrontend $true` once after a
  fresh clone, a pull or a branch switch. Use `Invoke-BuildRange` afterwards. When restores fail with
  NU1101/NU1102 for a `999.0.0` package, the chain is out of sync: run `Invoke-BuildAll` again.
* Repositories outside the range are not rebuilt. If they consume a rebuilt package they pick it up
  on their next build (its global-cache copy was purged).
* `octo-construction-kit` packages are not consumed by the service chain - skip them for engine changes.
* The `System*` CK models are embedded in the service DLLs and are imported automatically when a
  tenant is resolved (with a downgrade guard), so a rebuilt and restarted service brings its newer
  System model along. The local CK catalog is `<checkout>/.octo/local-catalog` (Start-Octo points
  `OCTO_LocalFileSystemCatalog__RootPath` at it).

**CK intermediate versions (AB#7974).** The compile gate of a `ckLanguage: 2` model (baseline source `Local`, the
default outside CI) compares the declared version with the newest version of the same major below it in the local
catalog (plus the cached GitHub catalogs, which `Octo.User.props` usually switches off). When the local catalog holds
`System.Identity` 2.26.0 but never got 2.27.0/2.28.0 (built only in other lanes or PR builds with
`OctoPublishCkModel=false`), the diff 2.26.0 -> 2.29.0 lacks the acknowledgements that 2.28.0 carries and the build fails
with 7x `OCTO-CK203`. `Invoke-BuildAll` and `Invoke-BuildRange` (DebugL) therefore run, before each repository,

```powershell
Sync-OctoCkIntermediateVersions -repositoryPath <repo> -localCatalogRoot <lane>/.octo/local-catalog [-WhatIf]
```

For every `ckModel.yaml` with `ckLanguage: 2` below `<repo>/src` it lists the private catalog's versions of the declared
major strictly between the newest local version below the declared one and the declared version (read from the GitHub
Pages mirror `https://meshmakers.github.io/construction-kit-libraries-build/`, no token) and publishes them byte for
byte, ascending, with `octo-ckc -c Publish -f <file> -c LocalFileSystemCatalog -lcr <lane>/.octo/local-catalog` (index
updated). Only published versions are copied; a local catalog without a version of that major gets nothing. An
unreachable mirror is a warning and changes nothing; a failed publish prints a warning with the exact command. octo-ckc
is the lane's `octo-construction-kit-engine/bin/DebugL/net10.0/publish/octo-ckc` (in a feature environment without the
engine: the base lane's), else the one on `PATH` (`-ckc`).
The logic is the script block of `octo-pipeline-templates/templates/steps/ck-sync-intermediate-versions.yml` (the same
rule the r* tag builds use to fill the public catalog), vendored verbatim as `modules/scripts/Sync-CkIntermediateVersions.ps1`;
`tests/CkIntermediateSync.Tests.ps1` checks the copy when a templates checkout is found (`OCTO_PIPELINE_TEMPLATES_PATH`).

# Running tests

`Invoke-OctoTestRun` runs the tests of one repository of a lane or feature environment - all test projects, single
ones, or a `dotnet test --filter` expression - and tells you which tests failed and why. `Invoke-BuildRange` and
`Invoke-BuildEnvironment` only build (`-includeTests`) or compile (`-verifyTests`) the test projects; they never run
them.

```powershell
# All test projects of a repository in a feature environment (or a lane: -branch branches/main)
Invoke-OctoTestRun -env ab8625-enum-null -repo construction-kit-engine

# One project, one class
Invoke-OctoTestRun -env ab8625-enum-null -repo construction-kit-engine -project Engine.Tests -filter 'FullyQualifiedName~EnumTests'

# Only what failed last time (repeat until it is green)
Invoke-OctoTestRun -env ab8625-enum-null -repo construction-kit-engine -rerunFailed

# What would run, would it build, does it need the Docker lock?
Invoke-OctoTestRun -branch branches/main -repo octo-asset-repo-services -WhatIf

# Who is running Docker-heavy tests right now?
Get-OctoTestLock
```

- **No full rebuild.** A project whose build is current runs with `--no-build`. Otherwise `dotnet test` builds it
  incrementally first and the output says why (a source file changed, a referenced project or a lane package was
  rebuilt, no build output). `-build Always` / `-build Never` override the check.
- **Readable result.** The failed tests come first: full name, first line of the error message, first stack frame.
  `-Json` returns per test project the totals, the duration, up to 50 failed tests (`-maxFailures`, `truncated`) and
  the paths of the TRX files and the log. Everything is kept in
  `<lane>/logFiles/test-results/<repo>/<project>/<run>/` (the newest 10 runs).
- **Same isolation as the build.** The run uses the lane's package cache and feed; an in-place worktree of an
  environment gets the environment's feed, cache and CK catalog. Feed credentials never appear on the command line or
  in the output.
- **Docker-heavy suites run one at a time on the machine.** A test project with a `Testcontainers` package reference
  (its own or one of a project it references) runs under a machine-wide lock, so the containers of two sessions do
  not starve each other and tests do not fail falsely. A second run waits (`-lockTimeoutSeconds`, default 30
  minutes) and says who holds the lock; projects that need no Docker run first, without waiting. `Get-OctoTestLock`
  shows the owner (pid, since when, which run). A lock whose owner process is gone is replaced by the next run;
  `Remove-OctoTestLock` removes it at once - and refuses while the owner still runs. `-dockerLock Always` takes the
  lock for a project the marker misses, `-dockerLock Never` skips it.
- `-EventsFile <file>` writes progress events (plan, lock wait, per project start and result, done) in the format of
  the build events, for octo-devstack.

**Running a Docker-heavy suite another way** (plain `dotnet test`, Rider, a script)? Take the same lock, so it and
`Invoke-OctoTestRun` never overlap:

```powershell
$lock = Enter-OctoTestLock -TimeoutSeconds 1800 -Run @{ command = 'dotnet test (by hand)'; lane = $PWD.Path; repo = 'octo-asset-repo-services'; projects = @('AssetRepositoryServices.IntegrationTests') }
if (-not $lock.Acquired) { throw "Test lock is held by pid $($lock.Owner['pid']) ($($lock.Owner['repo'])) - see Get-OctoTestLock" }
try { dotnet test tests/AssetRepositoryServices.IntegrationTests -c DebugL }
finally { Exit-OctoTestLock -Id $lock.Id | Out-Null }
```

Lock file contract (for a caller that is not PowerShell): the lock is the file `$OCTO_TEST_LOCK_PATH`, or
`$XDG_STATE_HOME/octo-tools/locks/docker-tests.lock` (default `~/.local/state/...`; Windows
`%LOCALAPPDATA%\octo-tools\locks\docker-tests.lock`). It exists exactly while somebody holds the lock and contains
one JSON object: `schemaVersion` (1), `id` (the owner's handle), `pid` and `processStartTime` (ISO-8601 UTC) of the
owning process, `since` (ISO-8601 UTC), `user`, `host`, `command`, `lane`, `environment`, `repo`, `projects`. To take
it, write the complete object to a file of another name in the same folder and move it onto the lock path **without
overwriting** (hard link + unlink, or a rename that fails when the target exists); when the move fails, somebody else
holds it. To release it, delete the file if its `id` is yours. A lock is stale when no process has `pid`, or the
process with that `pid` started at another time than `processStartTime` (2 seconds tolerance); only then may it be
replaced. The owner must live as long as the tests run - record the pid of the process that waits for them.

# Feature environments

A feature environment is a small lane of its own at `<rootPath>/wt-<env>` for one work item - the lane folder of the
octo-claude-pm lane `<env>`: git worktrees of the
repositories you change, its own NuGet feed and package cache, its own CK and blueprint catalogs and a manifest
(`.octo/environment.json`) that octo-devstack reads to run the environment's services in their own stack slot. Work
on several features at the same time without one build overwriting another's `999.0.0` packages, and without
touching `branches/main/nuget`.

```powershell
# 1. Create it: feature worktree(s) on <user>/AB#8625_enum-null, feed and catalogs copied from branches/main
New-OctoEnvironment -env ab8625-enum-null -repos octo-construction-kit-engine -workItem AB#8625

# 2. Which repositories does the change reach? Add the ones between the library and the service you run
Get-OctoAffectedRepos -env ab8625-enum-null
Add-OctoEnvironmentRepo -env ab8625-enum-null -repo octo-asset-repo-services -role consumer -addAffected

# 3. Work in wt-ab8625-enum-null/octo-construction-kit-engine (Rider, dotnet build: isolated by Octo.User.props)
#    and build the environment incrementally; compile the tests before every hand-off
Invoke-BuildEnvironment -env ab8625-enum-null -verifyTests

# 4. main moved on? Take its new packages and catalog entries (yours keep winning)
Invoke-BuildEnvironment -env ab8625-enum-null -syncMain        # or Sync-OctoEnvironment -env ab8625-enum-null

# 5. Status, and clean-up after the PR is merged (refuses dirty or unpushed worktrees; branches are kept)
Get-OctoEnvironment -env ab8625-enum-null
Remove-OctoEnvironment -env ab8625-enum-null
```

- **Consumers** are detached worktrees at the commit `branches/main/<repo>` is on; treat them as read-only. A library
  change reaches a service only if every repository between them is rebuilt in the environment, otherwise main's
  prebuilt packages bind to the new library at runtime (`MissingMethodException`).
- **Snapshot, not live.** Main's packages and catalogs are copied when the environment is created and refreshed only
  on request (`Sync-OctoEnvironment`, `-syncMain`). Packages built in the environment always win; catalog indexes
  changed on both sides are merged. Main's feed is never added as a second NuGet source.
- **Existing worktrees** are adopted with `Add-OctoEnvironmentRepo -env <env> -path <worktree>`: an octo-claude-pm
  flat worktree `wt-<lane>-<repo>` or a Claude Code worktree `<repo>/.claude/worktrees/<name>` is moved
  (`git worktree move`, uncommitted work included) to `wt-<env>/<repo>`; refused while git has it locked or a process
  runs from it (a shell, an IDE or a Claude Code session in that folder; same matching as `Invoke-KillDotnet`,
  list-only). `-inPlace` leaves it where it is: `Invoke-BuildEnvironment` builds it with the environment's feed
  (plus the repo's own feeds, e.g. Telerik, and a private feed from `OctoNugetPrivateServer` in `Octo.User.props`;
  credentials in feed URLs are never printed), cache and CK catalog as global properties and includes it in the kill
  scope, but a plain `dotnet build` or Rider in that folder is **not** isolated, and `Remove-OctoEnvironment` only
  unregisters it (it belongs to its original owner).
- **Kill scope** per environment: `Invoke-KillDotnet -branchRootPath <rootPath>/wt-<env> -additionalRoots <in-place
  worktrees>`, run by `Invoke-BuildEnvironment` before the build (`-skipKill` to opt out); a main build never touches
  environment processes.
- **Running** the environment's services is octo-devstack's job (own stack slot per environment, fallback to main's
  binaries for the services the environment does not build). `Start-Octo` stays for main.
- Load the profile from the `octo-tools` checkout next to `branches/` (`$rootPath` = the workspace root). Environment
  folders inside `branches/main` are refused, and so is a name whose `wt-<name>` already exists as an octo-claude-pm
  lane folder or flat worktree. `Remove-OctoEnvironment` deletes only what the environment owns. Claims stay in
  `branches/main/.octo/claims/<repo>.md` (with `Environment:` / `Worktree:` lines, format documented by octo-claude-pm), never in the environment folder.

# Working on many tenants

`Invoke-OctoTenantSweep` runs one octo-cli command against a list of tenants with per-tenant authentication
(octo-cli 3.5.27 or newer), a `-WhatIf` listing, a per-tenant result table and `-Json`; a tenant the operator is
not provisioned in is reported as `Denied` and the sweep goes on. `Register-OctoCliContext -TenantId a,b,c`
registers the contexts for it in one call. No token is ever read or printed. GraphQL over many tenants goes
through the octo-cli command `GraphQl` (`-IncludeOutput` returns the answer per tenant):

```powershell
$q = '{ constructionKit { models(first:1) { totalCount } } }'
Invoke-OctoTenantSweep -Context test2_octosystem -Tenant tecob,lkv -IncludeOutput `
    -CliArguments '-c','GraphQl','-tid','{tenant}','-q',$q
```

Details and examples: [docs/tenant-sweep.md](docs/tenant-sweep.md).

# octo-devstack (local stack daemon)

[octo-devstack](https://github.com/meshmakers/octo-devstack) (private) is a background service that runs the local
OctoMesh stack for several Claude Code sessions and exposes it as an MCP server. Get it, start it, register it once:

```powershell
Invoke-CloneMainRepos -devTools         # clone next to octo-tools (e.g. ~/dev/meshmakers/octo-devstack)
Start-OctoDevStackDaemon                # builds it on first use (Invoke-Build), starts it in the background, waits for /health
claude mcp add --transport http --scope user octo-devstack http://127.0.0.1:5090/mcp
```

`Stop-OctoDevStackDaemon` stops the daemon only; the stack services keep running and the next start adopts them.
Other sessions use the daemon, so a stop asks it first (`GET /api/daemon`): while a build runs or waits,
`Stop-OctoDevStackDaemon` and `Start-OctoDevStackDaemon -Restart` stop nothing and name the builds and their owners;
`-Force` overrides (the builds go on and the next daemon re-attaches to them). Sessions holding a stack lease are listed
as a warning. A new octo-devstack commit is deployed with `Start-OctoDevStackDaemon -Restart -Rebuild` (stop, build
Release, start; `-Rebuild` alone is refused while the daemon runs from those binaries).
On macOS/Linux both cmdlets need `lsof` to find the process on the port.

From then on OctoMesh is managed through the daemon: MCP `http://127.0.0.1:5090/mcp`, status page
`http://127.0.0.1:5090/`, log `~/.local/state/octo-devstack/daemon.log`, configuration
`~/.config/octo-devstack/devstack.yaml` (written on the first start).

# Tests

Pester tests for the build tooling live in `tests/` (they run against a fake checkout in `TestDrive`
and never build or touch the real NuGet folders):

```powershell
# once; -MaximumVersion keeps it on Pester 5 - -MinimumVersion alone installs Pester 6
Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser
# Windows with Defender "Controlled Folder Access": Install-Module cannot write to Documents\PowerShell\Modules;
# use Save-Module Pester -MaximumVersion 5.99 -Path <folder> and Import-Module <folder>\Pester instead.
# every session: load Pester 5 explicitly (if Pester 6 is already loaded, start a fresh pwsh first)
Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99
Invoke-Pester ./tests
```

# Customizing Windows Terminal Profile

1. Create Environment Variable MESHMAKERS with path to the OctoMesh repository.
2. In Windows add a new Profile and set the following settings in json:

**Terminal Profile:**

```json
{
  "altGrAliasing": true,
  "antialiasingMode": "grayscale",
  "backgroundImage": "%MESHMAKERS%\\octo-tools\\assets\\Logo_schwarz.png",
  "backgroundImageAlignment": "center",
  "backgroundImageOpacity": 0.3,
  "backgroundImageStretchMode": "fill",
  "closeOnExit": "automatic",
  "colorScheme": "Meshmakers",
  "commandline": "pwsh.exe -NoExit -ExecutionPolicy Bypass -Command . '%MESHMAKERS%\\octo-tools\\modules\\profile.ps1'",
  "cursorShape": "bar",
  "guid": "{df3c5fa9-c722-465c-b399-0ffc8bd1ba96}",
  "hidden": false,
  "historySize": 90001,
  "icon": "%MESHMAKERS%\\octo-tools\\assets\\meshmakers64.png",
  "name": "MeshConsole",
  "padding": "8, 8, 8, 8",
  "snapOnInput": true,
  "startingDirectory": "%MESHMAKERS%",
  "useAcrylic": true
}
```

**Color Scheme:**

```json
{
  "background": "#3A695C",
  "black": "#0C0C0C",
  "blue": "#0037DA",
  "brightBlack": "#767676",
  "brightBlue": "#3B78FF",
  "brightCyan": "#61D6D6",
  "brightGreen": "#16C60C",
  "brightPurple": "#B4009E",
  "brightRed": "#E74856",
  "brightWhite": "#F2F2F2",
  "brightYellow": "#F9F1A5",
  "cursorColor": "#FFFFFF",
  "cyan": "#3A96DD",
  "foreground": "#FFFFFF",
  "green": "#13A10E",
  "name": "Meshmakers",
  "purple": "#881798",
  "red": "#C50F1F",
  "selectionBackground": "#FFFFFF",
  "white": "#CCCCCC",
  "yellow": "#C19C00"
}
```

3. Further customization:

create a folder in the users directory: `.pwsh` and add a `profile.ps1`
This gets loaded when the terminal starts. You can for example disable the octo promt (`OCTO >`) by disabling `$Global:WantPromt = $true` in your custom `profile.ps1`.

# AI Bastion

The `Invoke-AiBastion` module drives the operator-side flow that registers an
Anthropic subscription token on an OctoMesh tenant — the bastion CLI from
ADR-15 / ADR-18 / #4123. Two cmdlets are exported once `profile.ps1` is sourced:

```powershell
Register-AiBastion -Tenant acme -AdapterUrl https://ai.example.com
Get-AiBastionStatus -Tenant acme -AdapterUrl https://ai.example.com
```

Authentication uses the operator's own OctoMesh OAuth token (the same one
`octo-cli login` deposits) — either passed via `-BearerToken` or read from
the `OCTO_BASTION_TOKEN` environment variable. The Anthropic device-code
flow runs on the operator's terminal; the resulting access + refresh token
pair is POSTed to the adapter's
`POST /{tenantId}/v1/credentials/register` endpoint, which encrypts both
tokens at rest before persistence.

Plaintext token material is held in process memory for the minimum time
needed and explicitly overwritten + GC-collected in a `finally` block, so
that Ctrl-C while waiting for the user to approve the device code still
wipes the credentials.

## Bastion host setup

The intended deployment runs this module on a dedicated bastion host.
Allowed SSH users are managed in the OctoMesh identity service; the host's
`/etc/ssh/sshd_config` restricts inbound shells to a dedicated operator
group. Each operator's session exports `OCTO_BASTION_TOKEN` from their
`octo-cli` login and runs `Register-AiBastion` with the tenant slug they're
onboarding.

The cmdlet doesn't persist anything to disk; the only artefact of a
successful run is the lease the adapter records server-side and a one-line
status echo on stdout.

# Agent instruction files

`Test-OctoAgentDocs` checks the files coding agents load in a repository - `AGENTS.md`,
its `CLAUDE.md` shim and `docs/` - and regenerates the parts that are derived.

```powershell
Test-OctoAgentDocs                                   # current repo, report only
Test-OctoAgentDocs -Path octo-communication-operator # or a repo name under $ROOTPATH
Test-OctoAgentDocs -Fix                              # rewrite the generated regions
Test-OctoAgentDocs -Fix -WhatIf                      # name what -Fix would write, write nothing
Test-OctoAgentDocs -Explain                          # plus why and how to fix, per rule that fired
Test-OctoAgentDocs -Explain -All                     # every rule with severity, limits, why, fix; no scan
Test-OctoAgentDocs -Explain doc-size                 # one rule; no scan
Test-OctoAgentDocs -Mode enforce -Json               # for a pipeline step
```

It checks that the always-loaded entry point stays inside its budget, that every doc is
reachable and every link resolves, and that no file carries invisible characters (Unicode
Tag, zero-width, bidirectional overrides) - text a reviewer cannot see but a model reads.
Findings are grouped in the order to fix them: integrity, entry point, docs, budgets.

Every `AGENTS.md` starts the same way. Rule `required-sections` (error) checks that the first
paragraph below the `# ` title is the opening sentence, and that the level-2 headings are
exactly these five, in this order:

```markdown
# AGENTS.md

Instructions for coding agents in this repository. Detail lives in `docs/`; read the matching file before changing the
code it covers.

## What this repo is
## Read before you change
## Build & test
## Before you commit
## Rules
```

Any other `## ` heading is an error: move its content to `docs/` or under one of the five as a
`###` section. Level-3 and lower headings are not checked. A `CLAUDE.md` that is still the entry
point is only checked for missing sections. The sentence and the headings are defined once, in
`modules/agent-docs.rules.json`.

`AGENTS.md` must work with any agent, so rule `no-eager-import` (error, non-relaxable)
reports every Claude-style `@path` import in it, in `docs/*.md` and in a `CLAUDE.md` that is
still the entry point; only the `CLAUDE.md` shim imports. Like Claude Code it reads an `@` at
the start of a line or after whitespace, outside code spans, fenced blocks and HTML comments.
The target counts as a path when it starts with `./`, `../`, `~/` or `/`, or names a file
(`@src/Foo.cs`, `@notes.txt`), so e-mail addresses, npm scopes such as `@angular/core`,
decorators and mentions are not reported. Borderline: `@/components` is reported, `**@x.txt**`
(no whitespace before the `@`) is not.

Rule `globs-match` (error; a repository may lower it in `.agent-docs.json`, with a reason)
reports each `applies_to` glob that matches no file, with the doc and the line, so a rename
cannot orphan a doc unnoticed; `background: true` docs are not checked. The files are what git
lists (tracked and not deleted, plus untracked files that are not ignored), or a folder walk
outside a git checkout, minus the folders in `scan.ignore`. `**` crosses folders, `*` and `?`
stay inside one, `{a,b}` alternates, a glob without a `/` matches at any depth, and matching
is case-sensitive.

`-Fix` regenerates the routing table between the `<!-- >>> generated: routing -->` markers
from each doc's `applies_to` frontmatter, writes the `CLAUDE.md` shim, and writes the opening
sentence below the title of `AGENTS.md` (inserted, or replacing a different first paragraph).
It never writes headings or other prose, and leaves a `CLAUDE.md` with real content alone
unless you pass `-Force`.

Rules are `[severity, options]` with `off | warn | error` and cascade: the org defaults in
`modules/agent-docs.rules.json`, a repository's `.agent-docs.json`, `-ConfigPath`, `-Mode`.
A repository may raise a rule listed in `nonRelaxable` but not lower it, because its file
lives in the branch under review. `Get-Help Test-OctoAgentDocs -Full` has the rest.

## Starting a repository

```powershell
Initialize-OctoAgentDocs -Path octo-new-repo          # minimal shape, or a migration brief
Initialize-OctoAgentDocs -Path octo-new-repo -WhatIf  # show what it would write
```

`Initialize-OctoAgentDocs` never overwrites a file and ends with a five-row checklist
(`AGENTS.md`, `CLAUDE.md`, `docs/`, the migration brief, the check) and the next steps. A
repository without agent files gets `AGENTS.md` with the title, the opening sentence, the
required sections and the routing markers plus the `CLAUDE.md` shim. A repository with a hand-written `CLAUDE.md` gets only
`AGENTS-MIGRATION.md`, a brief for the agent and developer doing the migration, rendered
from the ruleset; its first step is the start shown above. The checker warns while it exists
and it is deleted in the migration commit.

Tests, from the `octo-tools` folder (Pester 5, see [Tests](#tests)): `Invoke-Pester ./tests`.

# Support and Feedback

If you encounter any issues or have questions while using OctoMesh, please don't hesitate to reach out to our support team at support@meshmakers.io. We value your feedback and are committed to helping you make the most of OctoMesh.

# License

OctoMesh is released under the MIT License. Feel free to use and modify it according to your needs, and we encourage contributions from the community to enhance the system further.

Thank you for choosing DTS as your data transformation solution. We look forward to seeing how it empowers you to turn data into valuable insights.

Happy transforming! 🚀
