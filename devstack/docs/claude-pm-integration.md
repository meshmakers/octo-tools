# octo-devstack for octo-claude-pm agents

Project document of the branch `feat/reimar/devstack-for-claude-pm` (started 2026-11-20). It is the shared
brief of every work package below. Work happens in octo-devstack only.

## Goal

octo-devstack is adapted to octo-claude-pm: the use cases below can be carried out mainly through the octo-devstack MCP
server, by the octo-claude-pm agents (Daidalos, Ariadne, Penelope, Argos, Odysseus as workers; Odin, Frigg and the PO
agents as read-only coordinators) and by the developer's own Claude Code sessions. The agents should pick the right tool
from its name and description alone, in the words the developers already know from octo-claude-pm.

Constraints:

- Only this repository changes. octo-tools, octo-claude-pm and the OctoMesh repos stay as they are; where they have a
  bug, octo-devstack works around it and the bug is listed under "Follow-ups outside this repository".
- No compatibility: tool names, parameters, result shapes and devstack.yaml keys may change freely (one developer, the
  plugin rules of octo-claude-pm are still a draft, PR #57).
- Everything in CLAUDE.md still holds (tests never start OctoMesh services, the shared daemon on 5090 is never touched,
  everything in English, ...).
- Small rough edges an agent can get past by itself are acceptable; dead ends are not.

## Use cases

- **UC-A, shared stack**: several sessions work at the same time against the one local OctoMesh instance (the default
  slot on the configured ports). Each session changes a service in its own lane, builds it there, and runs that service
  in the shared stack in place of the base lane's build; the others keep running from the base lane.
- **UC-B, lane stack**: a session (or all sessions of one feature) works in a lane with its own stack: shifted ports, own
  system database, own feed and package cache. Services of repos the lane does not hold run from the base lane.
- **UC-C, octo-claude-pm roles**: the lead of a task (the main session or a coordinator) creates one lane per work item;
  its developer agents edit, build, test and run in that lane without touching anybody else's; coordinators only read;
  the shared resources (shared stack, base lane builds, clean-up) have one owner at a time through the lease.

The flow of octo-claude-pm PR #57 ("Code work in a feature environment") is the reference: create the lane, edit in its
worktrees, build with tests compiled, run the tests, run the lane's stack and verify, remove the lane after the merge.

## Vocabulary (agent-facing)

| Word | Meaning | Was |
|---|---|---|
| **lane** | The workspace of one work item: `<rootPath>/wt-<lane>` with worktrees of the repos it changes (feature) and of the repos rebuilt against them (consumer), its own NuGet feed, package cache and CK/blueprint catalogs, and its own stack slot. octo-tools calls it a *feature environment* (`New-OctoEnvironment`, `.octo/environment.json`); tool descriptions say "lane (octo-tools: feature environment)" once. | environment, env |
| **base lane** | The checkout every lane starts from and every service of a repo a lane does not hold runs from: `branches/main` (lanes layout) or the root (flat layout). Its feed holds the merged code's `999.0.0` packages. | lane, checkout, default checkout |
| **shared stack** | The stack of the default slot on the configured ports: the "local stack" of octo-claude-pm. Tools act on it when no `lane` is given. | default slot, stack |
| **lane stack** | A lane's own stack (its slot): shifted ports, own system database and prefixes. | environment slot |
| **slot** | Internal word for a stack's port offset, prefixes and state. Only admin tools and diagnostics show it. | slot |
| **owner** | The octo-claude-pm branch `<user>/AB#<id>_<desc>` of the caller; the same value in every call. Leases and jobs are recorded under it. | owner |
| **session** | The caller's `ListAgents` name (e.g. `meshmakers-07`), so another session can `SendMessage` the holder of a lease or claim. Optional, recommended. | (none: claims named the owner as session) |
| **envVars** | Environment variables for services. | env (in stack_start / service_* / env_set) |
| **job** | A build or a test run in the daemon's queue. | build, test run |

No parameter is called `env` any more: a lane is `lane`, environment variables are `envVars`.

## Target tool surface

Agent-facing tools (old name → new name). Read-only tools keep `ReadOnly = true`, removing or stopping tools
`Destructive = true`.

| Area | New | Old |
|---|---|---|
| Lanes | `lane_list` | `env_list` |
| | `lane_create(owner, lane, repos, branch, workItem, session, addAffected)` | `env_create(name, branchName, ...)` |
| | `lane_add_repo`, `lane_sync`, `lane_affected` | `env_add_repo`, `env_sync`, `env_affected` |
| | `lane_build(owner, lane, repos, skip, verifyTests = true, syncMain, restartServices)` | `build_start(kind=env, env=...)` |
| | `lane_test(owner, lane, repo, project, filter, rerunFailed, includeSlow)` | `test_run(env=...)` |
| | `lane_remove(owner, lane)` | `env_remove` |
| Base lane | `base_build(owner, kind = repo\|range\|all\|profile, ...)` | `build_start(kind=repo\|range\|all\|profile)` |
| | `base_test(owner, repo, ...)` | `test_run(checkout=...)` |
| Jobs | `job_status(id, waitSeconds, ...)` (builds and test runs) | `build_status`, `test_status` |
| | `job_list`, `job_cancel`, `job_output`, `job_refusals` | `build_list`, `build_cancel`, `build_output`, `build_refusals` |
| | `build_plan(..., lane)` | `build_plan` |
| Stacks | `stack_status(lane)`, `stack_start(owner, lane, profile, services, envVars, replace, session)`, `stack_stop(owner, lane)` | `stack_*(env / environment / slot)` |
| | `stack_list` | `slot_list` |
| | `stack_setup(owner, lane)` (re-runs the lane stack's setup) | `slot_bootstrap_admin`, `slot_register_octo_cli`, `slot_login`, `slot_apply_overlay` |
| | `stack_verify(lane)` | `slot_verify` |
| | `stack_attention` | `stack_attention` |
| Services | `service_start/stop/restart(owner, service, lane, overrides, envVars)`; `overrides.<service>.source` takes a path or `lane:<name>` | same, `env` |
| | `service_logs(service, lane)`, `service_env(service, lane)` | same, `env` |
| Lease | `lease_status`, `lease_acquire(owner, session, ...)`, `lease_release` | same |
| Workspace | `workspace_list` (base lane, lanes, worktrees, which services run from where) | `checkouts_list` |
| Read-only info | `profile_list`, `profile_get`, `config_get`, `daemon_status`, `setup_check`, `infra_status`, `test_lock` | same |
| Developer | `dashboard_open(view, lane)` and the MCP prompt `dashboard` (WP-H; not in the agent view) | (new) |
| Admin | `admin_profile_save`, `admin_profile_delete`, `admin_config_inspect`, `admin_config_set_defaults`, `admin_config_import_defaults`, `admin_service_define`, `admin_service_remove`, `admin_envvar_set`, `admin_lane_seed_cache`, `admin_slot_retired`, `admin_slot_forget`, `admin_slot_drop_data` | `profile_save`, `profile_delete`, `config_inspect`, `config_set_defaults`, `config_import_defaults`, `service_define`, `service_remove`, `env_set`, `env_seed_cache`, `slot_retired`, `slot_forget`, (new) |

Optional, if it is simple with ModelContextProtocol 2.2: an agent view of the server (for example `/mcp?view=agent`)
that lists no `admin_*` tool.

The server instructions are rewritten in this vocabulary as the octo-claude-pm flow (short: what a lane is, the flow,
the shared stack with the lease, waiting with `job_status(waitSeconds)`, owner and session, what needs the developer's
go). Every tool description starts with what the tool is for, in one sentence, before the details.

## Work packages

Each package is built on its own branch `feat/reimar/devstack-cpm-<wp>` in its own worktree `C:\dev\devstack-cpm-<wp>`
(outside `C:\dev\meshmakers`, see CLAUDE.md), committed locally, and integrated into the project branch by the lead.
`dotnet test Octo.DevStack.sln` must pass on Windows before a package is reported done (baseline: 491 passed, ~90 s).

### WP-A: tool surface and vocabulary (phase 1)

The tool surface above, except the slot tools of WP-B. Owns `Tools/*.cs` except `SlotOpsTools.cs` / `SlotTools.cs`,
`Program.cs` (server instructions), `Ui/ToolBridge.cs`, the status page's calls of renamed tools (`Ui/*.js`), the API
parity test, and the README's tool sections. Also:

- `session` (optional) on every changing call; leases keep it next to the owner, lane claims write `Session: <session>`
  and `Owner: <owner>` (without a session: `Session: <owner>` as today).
- `job_status(waitSeconds)`: long poll until the job ends or the time is up (max 900 s, like `lease_acquire`), then the
  normal answer; the answer says whether it timed out. `stack_start` gains `waitHealthy` (seconds) in the same way when
  it does not wait already.
- `overrides.<service>.source = "lane:<name>"`: the repo path of the service's repo in that lane's manifest (UC-A: run a
  lane's build of one service in the shared stack). A lane that does not hold the repo is refused with the lanes that do.

Acceptance: every old name is gone (code, tests, README, status page); `rg "\benv\b"` finds no tool parameter; the
instructions and every description use the vocabulary; tests pass.

### WP-B: a lane stack works out of the box (phase 1)

Owns `Tools/SlotOpsTools.cs`, `Tools/SlotTools.cs` (renamed as above), `Runtime/SlotOperations*.cs`,
`Runtime/SlotArtifacts.cs`, `Runtime/SlotVerification.cs`, the start path of a slot in `StackSupervisor` / `SlotRun`,
`devstack.default.yaml`, the README's slot section.

- The communication controller starts on a fresh system database: a `slotDerivations` row sets
  `Methods__ValidateRegistrations=false` (env key `OCTO_METHODS__VALIDATEREGISTRATIONS` or the key the service reads)
  for the communication controller in every non-default slot. Reason: its CK method validation needs
  System.Communication in the system tenant, which nothing installs on a fresh database (platform bug, follow-up below).
- First start of a lane stack: once the stack is healthy the daemon runs the setup by itself - admin bootstrap, octo-cli
  installation entry and contexts, login, identity overlay - idempotent, each step reported in the start result; a
  failed step is a warning that names `stack_setup`. `stack_setup(owner, lane)` re-runs the steps.
- `slot_login` failed on the first call for a fresh slot ("holds an interactive login") and worked on the second: fix
  the cause.
- `stack_verify` on Windows: no false "foreign consumer" warnings (RabbitMQ reports the dotnet pid, the daemon records the
  `cmd.exe` wrapper pid; map one to the other).

Acceptance: a new lane's `stack_start` ends with a healthy stack (communication controller included), a working octo-cli
context and the overlay applied, without any further call; unit tests cover the setup sequence and the login fix (fakes,
no OctoMesh service).

### WP-E: many sessions on the shared stack (phase 1)

Owns `Ui/Attention.cs`, the lease timing in `Leasing/LeaseManager.cs` (WP-A adds `session` there - keep the two apart),
the conflict attribution in the build planner.

- Default lease TTL 30 minutes, renewed by every changing call as today; `lease_status` shows the last activity and
  how long the holder has been idle.
- A build conflict names who started or overrode the service (`startedBy` of the service, not of the stack).
- Attention: a failed repo build is cleared when a later range or all build of the same lane built that repo
  successfully; an entry of a lane that is no lane any more (the old flat root after the move to the lanes layout:
  only octo-tools/octo-devstack/octo-claude-pm left) is cleared.

### WP-C: builds and tests in a running lane (phase 2, on top of WP-A)

- `lane_test` / `base_test` stop the services of the target stack that run from the tested repo before the run and
  start them again afterwards (the lane's lease covers it; shared stack: needs the lease, like `stopServices`). Reason:
  `Invoke-OctoTestRun` always rebuilds the service's project (see follow-ups) and on Windows fails with MSB3027 while the
  service runs from `<repo>/bin/DebugL`.
- Evidence: every job records per repo the worktree path, `HEAD` and whether the work tree was clean at the start and at
  the end; `job_status` shows it (`evidence`). octo-claude-pm's verify gate can later accept a job instead of a second
  plain `dotnet build` / `dotnet test`.
- `base_build(kind=repo)` of a worktree below `<repo>/.claude/worktrees/` is refused before it runs, with the reason
  (the repo's Directory.Build.props imports the main checkout's, NU5118) and the way out (`lane_add_repo` with `path`).
- Builds of different plain worktrees (`kind=repo`) run in parallel with each other (they never write the base lane's
  feed); a range or all build of the base lane still runs alone.

### WP-D: a lane leaves nothing behind (phase 2, on top of WP-A and WP-B)

- `lane_remove` stops the lane stack, then checks for processes that hold files below the lane folder: its own services
  are stopped, foreign ones (an MSBuild node of a plain `dotnet build`, a shell) are listed (pid, name, start time - never
  a command line) and the removal is refused with that list. Reason: on 2026-11-20 `Remove-OctoEnvironment` failed with
  "Access denied" on the lane's package cache, held by a reused MSBuild node.
- After the folder is gone the lane's data is dropped by the daemon itself: the slot's system database and tenant
  databases, the Hangfire database, RabbitMQ queues and exchanges with the slot prefix, CrateDB schemas with the prefix,
  the octo-cli installation entry and contexts, the slot's state folder and the lane's secret files
  (`admin-credentials.json`, `octo-cli-client.secret`); S3 artifacts if it can be done without extra tools, otherwise
  listed. Every step reports what it dropped; when every step succeeded the slot index is freed (no retired index).
  `keepData=true` keeps the data (then the index is retired as today).
- `admin_slot_drop_data(index)` does the same for an index retired before.

### Phase 3: documentation and acceptance

README and CLAUDE.md in the vocabulary (an "Agents" section with the flows of UC-A, UC-B, UC-C), then an end-to-end run
by a fresh agent that only has the tool descriptions and a small throwaway story (UC-B in a lane, UC-A with a lane's
service in the shared stack), against the daemon of this branch.

## Follow-ups outside this repository

- octo-tools `Get-OctoTestOutputTime` looks for the test assembly only below `<project>/bin/<configuration>`; 17 repos
  build into `<repo>/bin/<configuration>`, so `-build Auto` never passes `--no-build` and every test run rebuilds.
- octo-tools `Remove-OctoEnvironment` does not stop the lane's own dotnet processes (the kill scope `Invoke-BuildEnvironment`
  uses).
- OctoMesh: the communication controller cannot start on a fresh system database (System.Communication is not installed
  in the system tenant, its CK method validation refuses the start).
- OctoMesh repos: the `Directory.Build.props` root-props lookup makes nested `.claude/worktrees` import the main
  checkout's props (NU5118).
- octo-claude-pm: PR #57 in the new vocabulary; the verify gate accepts a devstack job (`evidence`) instead of a second
  plain build and test; coordinators get only the read-only devstack tools.
- octo-tools `Get-OctoBuildOrder` leaves octo-tools and octo-devstack out of the build order, but not octo-claude-pm.
- octo-tools `New-OctoEnvironment`: copying the package cache into a new lane took 22 s once and 201 s while other builds
  ran - 5.6 GB per lane on Windows (no copy-on-write clone there).
- The developer's shells may keep a stale PATH after a workspace move (octo-cli moved with the repos); a daemon started
  from such a shell keeps it. octo-tools could refresh the PATH in `Start-OctoDevStackDaemon` (or warn when octo-cli
  does not resolve); octo-devstack's `setup_check` reports it.
- octo-tools `Get-OctoProcessesUnderFolder` reads every command line with its own WMI query on Windows (about 1.3 s per
  process, over 10 minutes for ~600 processes); the daemon works around it with one `Win32_Process` query whose answer
  the cmdlet's session uses. octo-tools should read them with one CIM query itself.
- On macOS `Get-OctoProcessesUnderFolder` (lsof) reports working directories, so a shell or Claude Code session whose
  working directory lies inside the lane folder makes `lane_remove` refuse (README "Removing a lane" says so). Correct,
  but agents must `cd` out of the lane before they remove it.

## Status

All packages are committed on the project branch `feat/reimar/devstack-for-claude-pm` (2026-11-20), opened as a pull
request on 2026-11-23.

| Package | Delivered |
|---|---|
| WP-A | The tool surface and vocabulary above (`lane_*`, `base_*`, `job_*`, `stack_*`, `admin_*`), `session` next to `owner` in leases and lane claims, `job_status(waitSeconds)`, `overrides.<service>.source = "lane:<name>"`, the agent view `/mcp?view=agent`, server instructions and README tool reference in the new words. |
| WP-B | A lane stack works out of the box: the communication controller starts on a fresh system database, the automatic setup after the first healthy start (admin, octo-cli entry and contexts, login, overlay) with `stack_setup` replacing the four slot tools, the login fix, no false foreign consumers in `stack_verify` on Windows. |
| WP-E | Lease idle timeout of 30 minutes with `lastActivityAt` / `idleMinutes`, build conflicts naming who started or overrode the service, attention entries cleared by later range/all builds and for lanes that are no lanes any more. |
| WP-C | `lane_test` / `base_test` stop and restart the target stack's services of the tested repo, evidence (worktree, `HEAD`, clean) at the start and end of every job, nested `.claude/worktrees` builds refused with the way out, plain worktree builds in parallel. |
| WP-D | `lane_remove` leaves nothing behind: the process check below the lane (foreign processes refuse, with pid, name and start time), the lane stack stopped, the data dropped store by store and the slot index freed; `admin_slot_drop_data`. |
| WP-F | The fixes of the end-to-end run below, two gaps from the WP-C/WP-D reports (a `lane_test` stops the shared stack's services that run the tested lane repo, with the caller's lease of the shared stack, or is refused with the way out; the service-start guard names the job - build or test run - and `job_status(id, waitSeconds)`) and the documentation (README "For agents (octo-claude-pm)", CLAUDE.md, server instructions, this section). |
| WP-G | Polish after the acceptance test by a fresh agent: a start that names its services brings their `startAfter` dependencies (`added`); `lease_release` answers `released`, `formerHolder` and the new `holder` (the release hands the lease to the first waiter); `lane_remove` deletes feature branches without commits and lists the kept ones (`branches`, `keepBranches`), prunes `data.leftOver` and calls the `s3` step `unchecked` (blocks nothing); `stack_verify` names each consumer's `service`, `stack_status` the service's own `processId` on Windows; evidence `unchanged` (same HEAD, same changed files with the same content) is the job's verdict, `clean` stays per point in time; a test run's progress rows are `projects`; a rebuild caused by `Get-OctoTestOutputTime` (follow-up above) is explained in `buildReason`. |

| WP-H | The status page in the lane vocabulary: a Lanes view (`#/lanes[/<lane>]`: repos, lane stack, last setup, the shared stack's services that run the lane's build, jobs with evidence), service rows with `runsFrom` (`lane:<name>`, `base lane`, a folder), `startedBy` with session and call and the Windows `processId` in every stack, leases with session and idle time, jobs as lane/base build or test run with what they ran on; `lane_list` gains `inSharedStack` and the lease's idle time; `dashboard_open(view, lane)` and the MCP prompt `dashboard` (`/mcp__octo-devstack__dashboard`) open the page in the developer's browser (not in the agent view; `--no-browser`). |

### End-to-end run (2026-11-20)

Against the developer's real stack, on the shared daemon running the project branch (commit c080b7e):
`lane_create` -> `lane_build` -> `job_status(waitSeconds)` -> `lane_test` (51/51) -> `stack_start(lane)` -> `stack_setup` ->
`stack_verify` -> UC-A `service_restart(overrides.platformServices.source="lane:e2e-uc-b")` with the lease -> a second
owner refused with the holder's session -> switch back -> `lease_release` -> `lane_remove` (data dropped, index freed).
All of it worked. What got in the way, and the fix (WP-F):

| Finding | Fix |
|---|---|
| `stack_start(owner, lane)` without services failed at once: the lane stack's `meshAdapter` would serve `meshtest`, which the shared stack's `meshAdapter` serves - the natural first call dead-ended. | A lane stack start without a service list leaves out what cannot run there - the frontends and every adapter whose tenant another running stack serves - and lists each in `leftOut` with the reason and how to include it (name the services, `overrides.<service>.variables.tenantId`). A named list keeps the refusal, which now says how to get past it. |
| The setup's octoCli step failed with "Register-OctoCliContext failed: spelling of the name, or if a path was included, ..." - the last, wrapped line of PowerShell's "The term 'octo-cli' is not recognized"; the daemon had been started from a shell whose PATH was older than octo-cli's folder. | Failure summaries of the setup steps (and the other pwsh failures of the slot operations, `error` of `lane_*` results) show the first error record's message (`PwshErrors`). `setup_check` reports whether octo-cli resolves on the daemon's own PATH and names the fix (a new shell, `Start-OctoDevStackDaemon -Restart`, then `stack_setup`). |
| Old words in results and texts: base_build's refusal spoke of "the lane's nuget folder", `config_get` returned `defaultCheckout` and `environment`, `stack_status` `checkout`, `stack_verify` had no verdict. | Every result field in the vocabulary (`baseLane`, `lane`, `envVars`, `sharedStackOnly`, `relativeToBaseLane`, the test lock owner's `baseLane` / `lane`), pinned by `ToolSurfaceTests` for every tool result type; `stack_verify` has `ok`; refusals, notes and warnings say the shared stack, the stack of lane `<name>` and the base lane. devstack.yaml keys stay (`defaultCheckout`, `environment`, a service's `env`, a profile's `checkout`). |
| In a lane stack `services[].startedBy` showed the lease holder `lane:<name>`. | The tools pass the caller (owner, session) through: `startedBy` / `startedBySession` name who started or overrode a service, also in a lane stack; the lease stays the lane's. |
