# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`octo-devstack` is a local MCP daemon (ASP.NET Core, `ModelContextProtocol.AspNetCore`, streamable HTTP on
`http://127.0.0.1:5090/mcp`) that runs the OctoMesh dev stacks, builds and test runs of a machine for several Claude
Code sessions: the shared stack (the default slot, the configured ports) and the lane stacks (further slots: shifted
ports, own data). It replaces calling `Start-Octo` / `Stop-Octo` from each session. Overview, tools and configuration:
`README.md`; the agents' flows: README "For agents (octo-claude-pm)"; the project of the octo-claude-pm adaptation:
`docs/claude-pm-integration.md`.

The tools speak the octo-claude-pm vocabulary (README "Tools"): **lane** (octo-tools: feature environment,
`<rootPath>/wt-<lane>`), **base lane** (the checkout every lane starts from), **shared stack**, **lane stack**, **job**
(a build or test run), **owner** (the caller's branch) and **session** (its `ListAgents` name), **envVars**
(environment variables). No tool parameter or result field is called `env`, `environment` or `checkout`
(`ToolSurfaceTests`); inside the code the old names (`Environment*`, `Checkout`, slot) stay where they name the
implementation. Tool names: `lane_*`, `base_build` / `base_test`, `job_*`, `build_plan`, `stack_*`, `service_*`,
`lease_*`, `workspace_list`, read-only info tools, `admin_*` for what needs the developer's go, and the developer's
`dashboard_open` with the MCP prompt `dashboard` (`/mcp?view=agent`, `AgentView`, hides the admin and developer tools and
prompts).

It references **no Octo package** (MongoDB.Driver only for `stack_verify` and the data drop of a removed lane stack): it drives the stack through processes, the octo-tools PowerShell cmdlets (`pwsh`
with `octo-tools/modules/profile.ps1`) and the file system. Keep it that way unless there is a strong reason;
`Directory.Build.props` explains what to add with the first Octo package.

## Build & Test

```bash
dotnet build Octo.DevStack.sln           # Debug. Never build Release while the shared daemon runs (it runs bin/Release)
dotnet test Octo.DevStack.sln            # ~100 s on Windows
dotnet bin/Debug/net10.0/octo-devstack.dll --dev   # development daemon: port 5190, devstack.dev.yaml, state octo-devstack-dev
```

**The shared daemon (127.0.0.1:5090, `bin/Release`) is not a development target.** Other sessions' stacks and builds run
through it. Develop and test on the development daemon (`--dev`; `--url` / `--config` / `--state` override its values; a
Debug build without `--url` is one by default). The shared daemon is restarted only from a pushed commit, and only when
`GET /api/daemon` (`daemon_status`) reports `restart.safe: true` or the developer explicitly says so. Never kill it, never
replace its binaries under it. README "Restarting the daemon" and "Development".

`TreatWarningsAsErrors` is on. The daemon is the folder `devstack/` of octo-tools (AB#9711; formerly the repository
meshmakers/octo-devstack, now retired); all paths in this file are relative to that folder. octo-tools lives next to the
lanes, **not** inside one: `Invoke-BuildAll` builds every `octo-*` folder of a lane and kills dotnet processes, which would
take the daemon down (`Get-OctoBuildOrder` skips octo-tools, `Invoke-KillDotnet` never stops `octo-devstack.dll`). CI: the
octo-tools Pester workflow does not run these tests; run `dotnet test Octo.DevStack.sln` before every commit.

## Structure

- `src/DevStack/Configuration` - `devstack.yaml` model, embedded default (`devstack.default.yaml`), `Workspace`
  (`WorkspaceResolver`: finds octo-tools, asks `Get-OctoWorkspace -Json`, nothing guessed without an answer;
  `ConfigStore` hands its `WorkspaceDefaults` to every config it loads and takes over the pre-AB#9377 file), placeholder
  expansion, `ServicePlanner` (config + per-start overrides -> `ServicePlan`), profiles: `ProfileResolver` (the one merge
  function, instance materialization, validation), `SettingsMap` (logical settings -> env keys per service section),
  `ProfileCapture` (running stack -> profile)
- `src/DevStack/Configuration` (slots) - `SlotInfo`, `SlotRules` (names, configured slots, exclusive services),
  `SlotDeriver` (port shift and the `slotDerivations` rows of the default yaml), `identity-overlay.template.yaml`
- `src/DevStack/Runtime` - `StackSupervisor` (router over the slots), `SlotRun` (the processes of one slot; one start/stop
  at a time per slot; a lane stack start without a service list leaves out what cannot run there - `SlotRun.LeaveOut`,
  `StartResult.LeftOut`), `SlotRegistry` (configured and created slots; a new index skips colliding ports and indices in use or retired), `LaneRemovals` (the lanes `lane_remove` is removing; every start checks it under its slot gate), `SlotValidator` (ports, isolated values, tenants
  against the other slots, under one admission lock), `SlotArtifacts` (overlay, installation entry, issuer smoke check),
  `SlotOperations*` (`stack_setup` and the automatic setup of a lane stack, `stack_verify`, `service_env`), `SetupCheck`
  (`setup_check`; machine probes behind `SetupProbes`), `ProcessLauncher`
  (`/bin/sh -c exec` with output redirected into the log file; Windows: `cmd.exe /s /c` with `>>` redirection, own console and
  process group), `EnvProviderRunner`, `StateStore` (adoption after a
  daemon restart), `ProfileMatcher` (which profile runs, drift), `PreStartChecks` (kind infra ports, octo-cli contexts)
- `src/DevStack/Leasing` - `LeaseManager` (one owner, FIFO queue, TTL), `LeaseRegistry` (one lease per slot),
  `LaneClaims` (`<lane>/.octo/claims/local-stack.md`, `local-stack-<slot>.md`, kept in step with the slot's lease)
- `src/DevStack/Builds` - `BuildQueue` (queue classes: lane jobs exclusive, environment jobs in parallel - one per
  environment, at most two; plain worktree builds (`PlannedBuild.Worktree`) in parallel - one per worktree, at most two,
  next to environment jobs; no two jobs on one folder; gates, stop/restart, progress, status; `BuildQueue.Jobs.cs` the job and step state,
  `BuildQueue.Restart.cs` job files, restore after a daemon restart, watching a detached step, the output for the status
  page), `BuildLauncher` (`DetachedBuildLauncher`: a wrapper runs pwsh with its output in the job log and leaves the exit
  code in `<id>.<step>.exit`, so a build needs no daemon), `BuildJobStore` (`builds/<id>.job.json`), `BuildPlanner`
  (request -> cmdlet steps via `-WhatIf`/`-DryRun`, conflicts, stale flags, gates), `BuildCapabilities` (probe of the
  cmdlets' parameters; degrade when octo-tools lacks them), `BuildEvents` (`-EventsFile` reader, log-poll fallback),
  `BuildLogParser`, `BuildHistory` (ETA), `GitWorkTree` (a job's evidence: `git status --porcelain=v2` of every repo it
  covers at its start and end with a fingerprint of the changed files' content, in `JobRecord.Evidence`; `unchanged` is the
  verdict, `clean` belongs to each point in time); pwsh runs go through `IPwshRunner`
- `src/DevStack/Discovery` - lanes (`Octo.User.props`) and git worktrees (`.git` file); `EnvironmentDiscovery` (feature
  environments: `<rootPath>/wt-*/.octo/environment.json`, schemaVersion 1, written only by octo-tools; repo paths come from
  the manifest and may lie outside the folder); `LaneRepositories` (does a lane hold octo-*/mm-* repos, developer tools such as octo-tools not counted: lane builds and
  test runs refuse one without, finished jobs of a removed environment or checkout are `gone`, AB#8915)
- `src/DevStack/Runtime` (apps) - `AppHost` (`octo-devstack.dll --serve-app`: static host with overlay folder, SPA
  fallback and path proxies), `ServiceFiles` (a service's generated files in a slot)
- `src/DevStack/Runtime` (lanes) - `EnvironmentBinding` (lane -> slot, folder, lease holder `lane:<name>`; a restored
  `env:<name>` lease is the lane's), `EnvironmentManager` (lane_list rows, lane_create / lane_remove / lane_add_repo /
  lane_sync / lane_affected around the octo-tools cmdlets); the source chain lane ->
  base lives in `StackContext.RepoPath`; `LaneProcesses` (lane_remove's process check: octo-tools `Get-OctoProcessesUnderFolder`
  sorted into the daemon's own services and the rest), `LaneBranches` (lane_remove: the feature branches Remove-OctoEnvironment keeps -
  deleted when they hold no commit beyond the base commit, else listed; git through `Common/GitProcess`, tests on temp repos),
  `SlotDataCleanup` (the data drop of a removed lane stack, store by store,
  frees the retired index when every step succeeded; the stores behind `SlotDataStores`, endpoints in `LocalInfra`)
- `src/DevStack/Runtime/DaemonJournal` - start/stop history (`daemon-history.jsonl`), the running binaries, the restart
  check (`GET /api/daemon`, `daemon_status`: builds block, leases warn)
- `src/DevStack/Tools` - the MCP tools (`LaneTools`: `lane_*`; `BuildTools`: `base_build`, `lane_build`, `job_status`, ...;
  `TestTools`: `lane_test`, `base_test`, `test_lock`; `SlotOpsTools`: `stack_setup`, `stack_verify`, `service_env`;
  `AgentView`: `/mcp?view=agent`; `DashboardTools`: `dashboard_open` and the prompt `dashboard` (`DashboardPrompts`, Claude
  Code's `/mcp__octo-devstack__dashboard`); `McpSurface`: the one registration of the MCP server - tools, prompts, agent
  view, argument errors - for `Program.cs` and `McpSurfaceTests`); every changing tool takes `owner` and (optional, recommended) `session` except a
  developer tool (`AgentView.DeveloperTools`: it changes no stack) (`StackTools.Caller`, `LeaseSession`;
  the services a call starts record the caller as `StackCaller`, also in a lane stack whose lease is `lane:<name>`);
  expected failures are thrown as `McpException` through `ToolGuard`; argument
  binding errors reach the client through the call-tool filter `ArgumentErrors`
- `src/DevStack/Common` - `SharedFile` (every file the daemon replaces while others may read it: temp file +
  ReplaceFile/move with a short retry; reads share delete, so nothing blocks a writer on Windows); `StdHandles` (Windows:
  the daemon's own stdout/stderr are not inherited by its children - they held `daemon.log` open); `DaemonLock`
  (`<state>/daemon.lock`, taken before the workspace is asked; exit code 75 when another daemon holds it, a daemon with
  `OCTO_DEVSTACK_SERVICE=launchd` waits for it instead; exclusive for the daemon's lifetime: a second daemon on the same state folder exits before it
  adopts or records anything); `PwshErrors` (the message of the first error record of a pwsh run - what a failure summary
  shows, never the last, wrapped line; pure)
- `src/DevStack/Common` (Windows) - `WindowsCommandLine` (CommandLineToArgvW quoting, cmd escaping; pure), `WindowsProcesses`
  (Toolhelp snapshot, GetProcessTimes, NtQueryInformationProcess command lines; no WMI - a full Win32_Process query takes
  seconds), `TcpListenerTable` (GetExtendedTcpTable; the parser is pure), `ConsoleSignal` (CTRL_BREAK through
  the daemon's own `--send-ctrl-break` helper mode); `ProcessTree` picks the OS path
- `src/DevStack/Ui` - read-only status page at `/` (`index.html`, `app.css`, `app.js` as embedded resources, JSON at
  `/api/overview`, `/api/logs/{service}`, `/api/builds/{id}`, `/api/builds/{id}/output`, `/api/config`, `/api/daemon`; every read-only
  MCP tool as `/api/tools/{name}` through `ToolBridge`); `Attention` builds the attention list for the page and `stack_attention`;
  `StatusPageTools` are the tools of the endpoints no other tool covered; `Dashboard` opens the page for `dashboard_open`
  (only the daemon's own URL with a route of `Dashboard.Views`; the browser launch behind `IBrowserLauncher`, `SystemBrowser`
  per OS, `--no-browser`; tests pass a fake and never open a browser); vanilla JS, no build step, no external
  resources, strict CSP - keep script and style in their files (no inline, no `style` attributes), and render API text
  with `textContent` only. Views are hash routes (`#/stack`, `#/lanes`, `#/builds` - shown as *Jobs* -, `#/profiles`,
  `#/config`; a new view is also a value of `Dashboard.Views`); where a service runs from is `runsFrom`
  (`LaneSource.RunsFrom`, set by the supervisor for stack_status and the slot rows), a lane's services in the shared stack
  `inSharedStack` (lane_list) - the page shows them, it does not work them out; one component set for
  all of them (lamp, tag, kv, fold, table, output, note - see the header of `app.css`, which also names the colour
  tokens); a new piece of content goes into the view it belongs to and uses those components, never a new ad-hoc block

## Rules

- **Tests never start an OctoMesh service, never load octo-tools, never touch a real lane or NuGet folder.** They use
  `TestCheckout` (temp folder) and harmless `pwsh -NoProfile` processes on every OS (`TestProcess`; pwsh is a requirement
  of the daemon anyway). Build tests pass `FakePwsh` (canned probe, dry-run and cmdlet output; it writes events files
  itself) and an external snapshot instead of the ps scan. Anything that drops data goes through `SlotDataStores`; tests pass
  `FakeSlotData` and never reach MongoDB, RabbitMQ, CrateDB, `~/.octo-cli` or `installations.json`.
- Apps (frontends of consumer repositories) are configuration, not code: a service block with `slot` (how it runs in a
  non-default slot), `files` (generated into `<state>/slots/<slot>/services/<service>`, never into a repository),
  `identityClients` (slot overlay; `tenant` for a client outside the system tenant) and `requiresRepos`. Never add an
  app's name to C# code and never write into an app repository; a need of one app becomes a generic service field.
  `AppHost` (`--serve-app`) is the daemon binary as a read-only static host of a built single-page app.
  `{...}` are slot placeholders (rendered by `SlotDeriver.Render`), `${...}` service placeholders (`ServicePlanner`);
  both may appear in one argument.
- Builds survive a daemon restart, and that must stay so: a build step is started through `IBuildLauncher` (detached,
  output to the job log, exit marker), never as a child with pipes to the daemon; every change of a job goes into its
  job file (`BuildJob.Changed`); a new field of a job or step that matters after a restart goes into `JobRecord` /
  `StepRecord` with a test in `BuildRestartTests` (a second `BuildQueue` on the same state folder after `Abandon()`
  stands for the next daemon run). The daemon signals a build process only after checking that the pid still is the
  process it started (start time; command line at adoption). `FakePwsh` without a launcher runs steps attached.
- Test runs (`lane_test` / `base_test`, `BuildKind.Test`) are jobs of the build queue, not a second mechanism: one step
  `Invoke-OctoTestRun ... -EventsFile -Json`, the progress rows are the test projects (`RepoRun` carries their counts), the
  class is the environment or `lane:<path>` (`BuildQueue.ClassOf`; tests are not counted against the environment build
  limit), the failed tests live in the job (`BuildJob.SetTests`, `JobRecord.Tests`). A test run stops the services of
  its target stack that run from the tested repository (`PlannedBuild.TestFolder` / `TestSlot`, own conflicts without a
  flag, the stack's lease) and starts them again after every run, through the same stop/restart as a build. The daemon never takes or reads the
  docker test lock file itself; `Invoke-OctoTestRun` owns it and `test_lock` asks `Get-OctoTestLock`. Tests fake the
  cmdlet (`FakePwsh.TestParams`, `TestRunTests`).
- Lane builds (`lane_build`, kind=env) build only what changed (octo-tools AB#8814): which repo is built or skipped is the cmdlet's
  decision - the daemon passes `repos` / `skip` / `buildUnchanged` through (probed: `EnvironmentCapabilities.BuildRepos` ...)
  and shows the prediction (`PlanRepo.Action/Reason/Detail`), the `repoSkipped` event and `repositories[].status` /
  `reason`; it never decides staleness for kind=env itself. A skipped repo has no durations and no log snapshot.
- Builds: range and all always need the lease (range also `publish=true`, all `confirm=true`); never pass
  `-ignoreRunningServices` to the cmdlets; octo-devstack stops only its own services, plus non-interactive Start-Octo
  stacks for `kind=all` with `stopExternal=true`. Decide success from the cmdlet JSON AND the exit code.
- Manual tests use the development daemon (`--dev`, or its own `--config`, `--url` and `--state`) with a throw-away
  `rootPath`, tiny repos and harmless services - a developer's stack may be running on the real ports.
- No tool output may contain environment values of secret-looking variables (`SecretMask`); env providers' values
  are never persisted (the state file holds PIDs and paths only).
- Keep the default config in step with `Start-Octo` (octo-tools `modules/Start-Octo.psm1`): services, ports, log
  names, environment, start order (`startAfter`; Start-Octo waits with `Wait-OctoServicePort`). Values octo-tools owns
  are read through env providers, not copied.
- Times shown to the developer are local time.
- Profiles: one merge function (`ProfileResolver.Merge`), no second one. Instances are clones of their base service in a
  materialized copy of the config; never add instance knowledge to `ServicePlanner`. A new setting goes into the table in
  `SettingsMap` (with a test row) and only names keys the services' options classes really have. Credentials are never
  profile fields and never saved by `admin_profile_save`.
- Tests write lane claims only into `TestCheckout` lanes and pass `PreStartChecks` with their own ports/contexts file (or
  none); they never probe the real kind infrastructure or read `~/.octo-cli`.
- Slots: the default slot derives nothing (its plans stay bit for bit what they were - `SlotDeriverTests` compares them).
  A slot value is a row in `slotDerivations` (default yaml), not code; it must name keys the options classes really have,
  and an `isolate` row for every value that names data. Names inside a slot stay unqualified; outward a service of another
  slot is `slot/name`. The state file keeps `Stack`/`Lease` (default slot) next to `Stacks`/`Leases` for one release.
- Never assume a shared `~/.nuget/packages`: every lane (main included) has its own cache through `RestorePackagesPath`.
- Lanes (octo-tools: feature environments): octo-tools owns everything on disk (folders, worktrees, feeds, manifests); the
  daemon only reads the manifests and calls the cmdlets (probed in `BuildCapabilities.Environments`; missing ones refuse with
  "octo-tools too old"). The lane holds its slot's lease (`lane:<name>`; `BuildRequest.LeaseOwner`,
  `EnvironmentScope.LeaseOwner`); `owner` stays required, `session` is recommended, and both are recorded - the services a call starts name the
  caller (`StackCaller`), never the lane. Tests build lanes as temp folders with a manifest (`EnvironmentTests.Env`) and fake
  the cmdlets.
- Vocabulary: a new tool, parameter, result field or user-facing text (refusal, note, warning, hint) uses the words of
  README "Tools" - the shared stack / the stack of lane <name>, base lane, envVars - never checkout, default slot or
  environment for a lane; `ToolSurfaceTests` pins the tool names, the parameters and every result field. devstack.yaml keys
  keep their names (`defaultCheckout`, `environment`, a service's `env`, a profile's `checkout`).
- API and MCP read the same things: a new read endpoint gets a row in `ApiParityTests.Equivalents` and a tool if none returns
  the same; a new read-only tool is a GET endpoint by itself (`ToolBridge`). Logic the page shows (like the attention list)
  is computed in C#, never only in `app.js`. Changing tools stay MCP-only - the HTTP API has no authentication.
- Everything in English (code, comments, docs, tool descriptions).
- No folder structure and no copy of an octo-tools rule in the daemon (AB#9377): the root, the default lane and the config folder come from octo-tools (`Get-OctoWorkspace`, asked once at the
  start; `ConfigStore.PathIn`), `rootPath` / `defaultCheckout` in the file are overrides, `octoToolsPath` is not read.
  The daemon only locates octo-tools (`--octo-tools`, `OCTO_TOOLS_PATH`, else the octo-tools checkout that holds its `devstack/` folder). Without an answer nothing
  is guessed: empty folders, `FolderProblems` / `setup_check` say why, `CreateContext` refuses. A new layout or config
  rule goes into octo-tools. The one mirror of an octo-tools rule is the build mode of a `kind=repo` step
  (`BuildPlanner.RepoBuildMode`, AB#9417): octo-tools has no public answer for it (`Get-OctoRepoBuildMode` is not exported
  and mirrors `Compile-Repo` itself), so a change of the mode dispatch in octo-tools changes `RepoBuildMode` and its test
  `The_build_mode_follows_the_files_in_the_repository_root` with it. Write files others may read through `SharedFile`,
  never `File.Move(..., overwrite: true)`.
- Windows: keep Windows-only calls behind `OperatingSystem.IsWindows()` / `[SupportedOSPlatform("windows")]` and their logic
  in pure functions with tests that run on every OS (macOS/Linux behaviour must not change). Test processes are one pwsh
  script for every OS (`TestProcess`: `Start-Sleep`, `ShellArgs`, `StubbornScript` for a process that ignores the graceful
  stop) - never a `/bin/sh` or `/bin/sleep` fixture, never a second script for one OS. Only what really differs per OS
  (the launcher's wrapper, signals, Unix modes vs a read-only file) is tested per OS, each OS's counterpart in the same
  test; no test skips. A command that does not exist everywhere is reached through a seam the tests replace (`IPwshRunner`,
  the docker function of `DockerVm`, `SetupProbes`), not called by a test. CI runs the tests on Linux only (pwsh is
  installed there by the pipeline when the agent lacks it): run them on Windows locally before a change to process
  handling, paths or files goes in.
  What works and what is limited on Windows: README "Windows".
