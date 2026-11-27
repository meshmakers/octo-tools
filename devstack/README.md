# octo-devstack

The folder `devstack/` of octo-tools (AB#9711; formerly the repository meshmakers/octo-devstack, now retired). Commands
below run in this folder.

**One-time migration from the octo-devstack clone (AB#9711).** An installed daemon service (`Install-OctoDevStackDaemonService`)
still points at the old clone (e.g. `~/dev/meshmakers/octo-devstack`). On macOS and Linux `Start-OctoDevStackDaemon`
without `-Path` uses the path of the installed LaunchAgent or systemd unit; on Windows the logon task holds the old path
(it runs `Start-OctoDevStackDaemon -Path <old clone>`). Move it once:

1. Once `daemon_status` reports `restart.safe: true` (no build runs or waits): `Uninstall-OctoDevStackDaemonService`
   (macOS and Linux: the service manager stops the daemon; the stack services keep running). On Windows also run
   `Stop-OctoDevStackDaemon`: uninstalling the logon task leaves the daemon running there, and the stop ends the old
   daemon hard (Stop-Process - its dll lies outside this octo-tools; the stack services keep running).
2. `Install-OctoDevStackDaemonService` without `-Path` (the new default is `<octo-tools>/devstack`): it builds Release
   when that build is missing and starts the daemon.
3. Check that `http://127.0.0.1:5090/health` shows the octo-tools commit, then reconnect the MCP server in Claude Code (`/mcp`).

A daemon that ran a build from before AB#9657 comes back with renamed tools (`env_*` -> `lane_*`, `build_*` -> `job_*`).

A local MCP server (daemon) that runs, stops and builds the **one** OctoMesh dev stack of a machine for several
Claude Code sessions at once. Instead of every session calling `Start-Octo` / `Stop-Octo` in its own shell, all
sessions talk to this daemon. It owns the service processes, knows which checkout or worktree each one runs from, and
gives the stack to one session at a time through a lease.

```text
Claude session A ─┐
Claude session B ─┼──► octo-devstack (http://127.0.0.1:5090/mcp)
your cockpit      ─┘      ├─ stack supervisor: own processes, PIDs, logs, health, survives daemon restarts
                          ├─ lease: one owner at a time, FIFO queue
                          ├─ build queue: base lane builds one at a time, lane builds next to each other (octo-tools cmdlets)
                          └─ devstack.yaml: services, arguments, environment, env providers
```

The kind infrastructure (MongoDB, CrateDB, RabbitMQ, operator) is not managed here; use `Install-OctoKubernetes` and
the other octo-tools cmdlets. `infra_status` shows its state.

## For agents (octo-claude-pm)

The agents of octo-claude-pm - the workers Daidalos, Ariadne, Penelope, Argos and Odysseus, the coordinators Odin,
Frigg and the PO agents - and the developer's own Claude Code sessions use the daemon through its MCP tools. The words
(lane, base lane, shared stack, lane stack, owner, session, job) are explained under "Tools"; the server instructions
say the same in short. Every changing call takes the same two values every time:

- `owner`: the branch `<user>/AB#<id>_<desc>` of the work (e.g. `reimar/AB#8625_enum-null`). Leases and jobs are
  recorded under it.
- `session`: the caller's `ListAgents` name (e.g. `meshmakers-07`). Leases, lane claims and the services a call starts
  (`startedBy`, `startedBySession`) record it, so another session can `SendMessage` the one that holds or started
  something.

Builds and test runs are jobs: `lane_build`, `lane_test`, `base_build` and `base_test` return one at once, and
`job_status(id, waitSeconds=50)` answers when it ended (`timedOut` when it did not yet). 50 s is the maximum: a longer
value is capped and a note says so - call it again (the MCP call of an in-process teammate times out after about 60 s).

**UC-B, a work item in its own lane** (the flow of octo-claude-pm's "Code work in a feature environment"):

```text
lane_create(owner, session, lane="ab8625-enum-null", repos=["octo-sdk"], branch="reimar/AB#8625_enum-null", workItem="AB#8625")
lane_list(lane="ab8625-enum-null")                                    # repos[].path: edit there, in the lane's worktrees
lane_build(owner, session, lane="ab8625-enum-null")                   -> job_status(id, waitSeconds=50)
lane_test(owner, session, lane="ab8625-enum-null", repo="octo-sdk")   -> job_status(id, waitSeconds=50)
stack_start(owner, session, lane="ab8625-enum-null")                  # the lane stack: shifted ports, own system database
stack_status(lane="ab8625-enum-null")                                 # healthy?  leftOut, setup, startedBy
service_logs(service="assetRepoServices", lane="ab8625-enum-null", grep="error|exception")
octo-cli -c <command> --context local-ab8625-enum-null_octosystem     # the lane stack's octo-cli context
lane_remove(owner, session, lane="ab8625-enum-null")                  # after the merge
```

- The first start of a lane stack sets it up by itself once its identity service is healthy: the first admin, the
  octo-cli installation `local-<lane>` with the contexts `local-<lane>_<tenant>`, a client-credentials login and the
  identity overlay (`setup` in the result). A failed step is a warning that names the call repeating it,
  `stack_setup(owner, lane, steps=[...])`; `setup_check` names machine causes (octo-cli not on the daemon's PATH).
- `stack_start(lane)` without `services` leaves out what cannot run in a lane stack: the frontends (shared stack only)
  and an adapter whose tenant another running stack serves - the shared stack's `meshAdapter` serves `meshtest`, so a
  lane stack runs without it. `leftOut` names each one with the reason and how to include it: name the services and
  give the adapter another tenant, `overrides={"meshAdapter": {"variables": {"tenantId": "<tenant>"}}}`. A start that
  names its services is refused instead.
- A start that names its services (`stack_start(lane, services=[...])`, `service_start`) brings their `startAfter`
  dependencies that do not run yet: `services=["platformServices"]` is enough, `added` names `identityServices` and why.
- The lane holds its stack's lease (`lane:<lane>`): every session of the lane may start, stop and restart it, and
  `services[].startedBy` / `startedBySession` say who did. `stack_verify(lane)` checks that the stack's data is its own
  (`ok` is the verdict).
- `lane_remove` stops the lane stack, removes the lane (refused while a worktree is dirty or unpushed, or while a process
  the daemon did not start holds files in it - an MSBuild node of a plain `dotnet build` ends with
  `dotnet build-server shutdown`; on macOS and Linux also a shell or session whose working directory is in the lane, so
  `cd` out of it first) and drops the lane stack's data. It deletes the lane's feature branches that hold no commit of
  their own; `branches` lists the ones with commits with the `git branch -D` command for after the merge
  (`keepBranches=true` keeps them all). `dataDrop` step `s3` is `unchecked` - it blocks nothing.

**UC-A, a lane's service in the shared stack** (one local OctoMesh for every session; the others keep running from the
base lane):

```text
lane_build(owner, session, lane="ab8625-mesh", repos=["octo-mesh-adapter"])   -> job_status(id, waitSeconds=50)
lease_status()                                                                 # who holds the shared stack, idle for how long
lease_acquire(owner, session, purpose="verify enum null handling", waitSeconds=600)
service_restart(owner, session, services=["meshAdapter"], overrides={"meshAdapter": {"source": "lane:ab8625-mesh"}})
stack_status(); service_logs(service="meshAdapter", grep="error|exception")    # verify; octo-cli --context local_meshtest
service_restart(owner, session, services=["meshAdapter"], overrides={"meshAdapter": {}})   # back to the base lane's build
lease_release(owner, session)                                                  # released, formerHolder, holder (a waiter gets it at once)
```

- Every change of the shared stack needs its lease; another owner is refused with the holder's owner and session, and
  `lease_acquire(waitSeconds)` queues. The lease expires 30 minutes after the holder's last changing call.
- `source: "lane:<lane>"` runs that lane's worktree of the service's repo; a lane that does not hold the repo is refused
  with the lanes that do. While it runs there, `lane_test` of that repo stops and restarts it too, with your lease of the
  shared stack (refused, with the way out, while another session holds it).

**UC-C, octo-claude-pm roles**:

- `owner` is the task's branch, `session` the agent's `ListAgents` name.
- One lane per work item, created and owned by the task's lead (the main session or a coordinator). Its developer agents
  edit, build, test and run in that lane only; the lane's lease is shared by all of them.
- Coordinators only read: `stack_status`, `stack_attention`, `stack_list`, `lane_list`, `job_status`, `job_list`,
  `service_logs`, `lease_status` and the other tools marked read-only. Register agents with
  `http://127.0.0.1:5090/mcp?view=agent`, which hides every `admin_*` tool and the developer's `dashboard_open` and
  `dashboard` prompt.
- The developer sees all of it on the status page (`/mcp__octo-devstack__dashboard`, see "Status page"); `lane_list`
  answers the same per lane - `inSharedStack` names the shared stack's services that run the lane's build, and every
  service of `stack_status` says where it runs from (`runsFrom`: `lane:<name>`, `base lane` or a folder).
- Only with the developer's go: `base_build(kind="range", publish=true)` (it changes the base lane's `999.0.0` packages
  for every session; a lane builds its library changes into its own feed instead), `base_build(kind="all",
  confirm=true)` (30-90 min), `lease_release(force=true)`, every `admin_*` tool, and a restart of the shared daemon while
  `daemon_status` says `restart.safe: false`.

## One stack, or several in slots

The services listen on fixed ports (identity 5003, asset repo 5000/5001, ... 5025), and the identity issuer
`https://localhost:5003/` is configured into the operator values, client redirect URIs and frontends. The **shared
stack** (the default slot) is that stack, composed per service across worktrees - e.g. everything from `branches/main`,
the mesh adapter from a lane's worktree. Further backend stacks, the **lane stacks**, run next to it on shifted ports
with their own data (see "Stack slots").

## Install and run

Requirements: .NET 10 SDK, PowerShell 7 (`pwsh`) and the octo-tools checkout (env providers and builds load its
profile), `lsof` and `ps` (macOS/Linux). Windows: see "Windows".

Install and run the shared daemon only from the main octo-tools checkout (`Start-OctoDevStackDaemon` and
`Install-OctoDevStackDaemonService` default to its `devstack/`; `-Path` picks another folder). Never from a worktree
(`wt-*`, `.claude/worktrees`): a worktree of octo-tools has its own `devstack/`, and `Remove-OctoEnvironment` deletes it.

```bash
dotnet build src/DevStack/DevStack.csproj -c Release
dotnet bin/Release/net10.0/octo-devstack.dll          # foreground; Ctrl+C also stops the services (same process group)
```

The first start writes `devstack.yaml` into the octo-tools config folder - `~/.config/octo-tools`, next to
`installations.json` (the folder of `$OCTO_TOOLS_CONFIG` when that is set) - from the built-in default
(`--print-default-config` shows it). A `~/.config/octo-devstack/devstack.yaml` of an earlier version is taken over
once (see "Workspace"). State (PIDs of running services, lease, build logs) lives in `~/.local/state/octo-devstack`.

### Workspace

The daemon assumes no folder structure. octo-tools describes the machine (`Get-OctoWorkspace -Json`): the root (the
folder that holds the octo-tools checkout), the layout and the default lane - `<root>/branches/main` in the lanes
layout, the root itself in the flat layout (repositories directly below it, e.g. `C:\dev\meshmakers` or
`~/RiderProjects/meshmakers/main`), or `$env:OCTO_ENVIRONMENT_BASE` -, where feature environments live
(`<root>/wt-<lane>`) and the config folder. The daemon asks it once at its start; `config_get` shows the answer
(`workspace`) and which values the file overrides (`overrides`).

- **Where octo-tools is**: `--octo-tools <path>`, else `$OCTO_TOOLS_PATH` (`Start-OctoDevStackDaemon` and
  `Install-OctoDevStackDaemonService` set it), else the octo-tools checkout whose `devstack/` folder holds the
  daemon. That is all the daemon finds by itself.
- **Nothing is guessed**: the daemon has no layout rule of its own. Without an answer - octo-tools not found, too old
  for `Get-OctoWorkspace`, pwsh missing - it does not start (unless `--config` names a file), and with `--config` the
  folders stay unknown: `setup_check` and the folder problems say why, `git pull` in octo-tools ends it.
- **rootPath, defaultCheckout** are overrides: a new `devstack.yaml` has neither, so the same file fits every machine.
  Set one only when octo-tools' answer does not fit. `octoToolsPath` is no longer read: the daemon uses the octo-tools
  it asked.
- **Taking over the old file**: when the octo-tools config folder has no `devstack.yaml` yet and
  `~/.config/octo-devstack/devstack.yaml` exists (`devstack.dev.yaml` for a development daemon), it is copied without
  `octoToolsPath` and without the rootPath / defaultCheckout lines that only repeat the workspace's values. The old file
  is left as it is (a running older daemon still reads it) and is not read again; delete it when no older daemon runs.

On a new machine, `setup_check` (or `GET /api/tools/setup_check`) lists what is still missing and how to fix it.

With octo-tools loaded, `Start-OctoDevStackDaemon` builds and starts it in the background and `Stop-OctoDevStackDaemon`
stops it (gracefully on every OS: SIGTERM, on Windows CTRL_BREAK through the daemon's own helper). As a background
service that starts at login and after a crash, on Windows, Linux and macOS (services survive daemon restarts):

```powershell
Install-OctoDevStackDaemonService       # Windows: logon task \OctoMesh\octo-devstack; Linux: systemd user unit; macOS: LaunchAgent
Uninstall-OctoDevStackDaemonService     # the stack services are left alone
```

On Linux the unit has `KillMode=process` (systemd's default would end every stack service with the daemon), and
`loginctl enable-linger` keeps it running without a login session. On macOS the cmdlet writes the LaunchAgent
(`~/Library/LaunchAgents/io.meshmakers.octo-devstack.plist`, `KeepAlive`, `AbandonProcessGroup`) and loads it with
`launchctl bootstrap`. All of it is octo-tools PowerShell; this repository has no install script of its own.

While that service runs the daemon, `Start-OctoDevStackDaemon -Restart` restarts it through the service manager
(`launchctl kickstart -k`, `systemctl --user restart`), never by starting a second daemon next to it. On macOS
`Stop-OctoDevStackDaemon` refuses (launchd would start it again at once); `Uninstall-OctoDevStackDaemonService` stops it
for good. On Linux it stops the unit; the next `Start-OctoDevStackDaemon` starts it again through systemd (an installed
service that does not run is always started through its service manager, never next to it).

A second daemon on the same state folder stops at its start anyway: the first holds `<state>/daemon.lock`, and the
second asks octo-tools nothing, adopts nothing, records nothing and exits with code 75 (the systemd unit counts that as
a success, `SuccessExitStatus=75`, so systemd does not start it again and again). A daemon launchd runs
(`OCTO_DEVSTACK_SERVICE=launchd` in the LaunchAgent) waits for the lock instead, since KeepAlive would start it again
every 10 seconds: it takes over when the other daemon ends, and `Stop-OctoDevStackDaemon` / `-Restart` stop the other
one by its signal.

Register it once for all Claude Code sessions:

```bash
claude mcp add --transport http --scope user octo-devstack http://127.0.0.1:5090/mcp
```

Options: `--config <path>` (or `OCTO_DEVSTACK_CONFIG`), `--url <loopback url>`, `--state <dir>` (or `OCTO_DEVSTACK_STATE`),
`--dev` (a development daemon next to the shared one, see "Development"), `--no-browser` (`dashboard_open` never opens a
browser and answers the URL to open by hand).
The daemon only binds to loopback and rejects requests with a foreign `Host` or `Origin` header (DNS rebinding).

### Restarting the daemon

Other sessions use the shared daemon (port 5090). A restart keeps what it runs: services are adopted, leases restored,
**builds go on** (a running build is re-attached, a queued one keeps its place, see "Builds"). What a restart still
breaks: a tool call in flight, and a build that is stopping or restarting services at that moment.

- `GET /api/daemon` (and the MCP tool `daemon_status`) says whether a restart is safe now: `restart.safe` is true
  while no build runs or waits; `restart.blockers` name the builds and their owners, `restart.warnings` the sessions
  holding a lease (a lease does not block: environments hold theirs all the time), `daemon` the pid, version, commit
  and build time of the running binaries, `history` the last starts and stops.
- **Rule: the shared daemon is restarted only from a pushed commit, and only when `restart.safe` is true or the
  developer explicitly says so.** Develop and test on a development daemon (`--dev`), never on port 5090.
- Every start and stop is written into the daemon's log (`daemon.log`: `START` / `STOP` lines with time, pid, version,
  commit and trigger) and into `daemon-history.jsonl` of the state folder; the status page shows them under
  *Configuration > Daemon*. The trigger of a stop is the signal's name (`signal SIGTERM`, `signal SIGINT`, ...) or
  `host shutdown`; the pid of the process that sent a signal is not available to a .NET process, so it is not recorded.
  A run that left no stop record (SIGKILL, crash, power loss) is reported as `lost` by the next start.
- A signal cannot be refused by the daemon. The check belongs into what sends it: octo-tools'
  `Stop-OctoDevStackDaemon` / `Start-OctoDevStackDaemon` read `GET /api/daemon` first and refuse while
  `restart.safe` is false unless `-Force` is given.

## Status page

`http://127.0.0.1:5090/` is the read-only board of the machine's stacks, lanes and jobs. It has five views, each with its
own link (hash routes), a top bar that names the worst state (dot next to *Stack*, number of running or queued jobs next
to *Jobs*, favicon colour) and the time of the last answer; when the daemon stops answering the bar says since when and
the content is dimmed.

**Opening it from Claude Code**: the command `/mcp__octo-devstack__dashboard [view] [lane]` (the MCP prompt `dashboard`)
asks the session to call `dashboard_open(view, lane)`, which opens the page in the developer's default browser on this
machine and answers `url`, `opened` and a `note`. `view` is `stack` (default), `lanes`, `builds`, `profiles` or `config`;
`lane` (a lane of `lane_list`) jumps to it in the lanes view (`#/lanes/<lane>`; with `view=stack` to its lane stack).
Only the daemon's own page with one of these routes is ever opened, never a URL from the caller. Windows opens it with
ShellExecute (in a desktop session), macOS with `open`, Linux with `xdg-open` when the daemon has a display (`DISPLAY` or
`WAYLAND_DISPLAY`); otherwise - and for a daemon started with `--no-browser` - `opened` is false and the note says to open
the URL by hand. `dashboard_open` is for the developer: a session calls it only when the developer asks to see the page;
the agent view (`/mcp?view=agent`) lists neither the tool nor the prompt.

- **Stack** (`#/stack`, `#/stack/<slot>`): one sentence about the shared stack, then what needs attention, worst first
  (exited or unanswering services, lane problems, failed builds and test runs, running jobs whose repository or test
  project is overdue, refused builds, profile drift,
  processes on service ports the daemon did not start) - each line links to the place that explains it. The daemon builds
  this list (`attention` in `GET /api/overview`); `stack_attention` returns the same one. A failed build or test run stays
  until a newer run of the same target succeeds - a run in a lane is another target than the same repository in the base
  lane, so a green run in `wt-<lane>` does not clear a red one in `branches/main`. A failed build of base lane
  repositories (`kind=repo` of a repository of the base lane, or a range or all build that failed in some) also clears
  once later range or all builds of the same base lane built each of those repositories, and a run whose lane is gone or
  holds no repository any more (`gone`) is never listed. Below it the **board**: a row per stack - the shared stack first
  (*shared*), then the lane stacks (a lane's stack is the slot named after it) and named slots (diagnostics) -, a column
  per service, one lamp each - filled = healthy, pulsing = starting, hollow amber = not answering, red square = exited,
  ring = not running, dash = disabled, violet ring = foreign process; services that run in the shared stack only have no
  place in the other rows. The row also shows n/m healthy, the profile, a running or queued job and the lease holder with
  its session and idle time. Selecting a row opens its **sheet**: for a lane stack a link to its lane, sources
  (`branches/main + wt-<lane>: <repos>`), for the shared stack the services that run a lane's build (`lane:<name>`),
  profile and drift, start, the lease (holder, session, purpose - a lane's names the owner of the last change -, last
  activity, idle minutes, expiry) and the sessions waiting for it, port offset and prefix, log folder, the stack's
  generated files, the services and the foreign processes with their stop hint. A service row shows its state, who
  started or overrode it (`startedBy`, with its session and the call: `stack_start`, `service_start`, `service_restart`,
  the restart after a job), where it runs from (`runsFrom`: `lane:<name>` linked to the lane, `base lane`, or the folder
  of a source override; the folder below it), the PID - on Windows with the service's own process below the recorded
  `cmd.exe` wrapper (`processId`) -, uptime and ports (problems first, configured but not running last), in the shared
  stack and in every lane stack. It opens the command line, the entry assembly the process really loaded (shared stack,
  macOS/Linux; one that is not below the service's folder is listed under attention, as in `stack_status`), the health
  detail and its log (regex filter, previous run); `GET /api/logs/<service>?slot=<slot>` reads a lane stack's log.
- **Lanes** (`#/lanes`, `#/lanes/<lane>`): every lane of `lane_list` in one row - work item, owner, repositories, lane
  stack health and port offset, the session of its lease and how long it is idle, running or queued jobs and the services
  it runs in the shared stack. The **sheet** of the selected lane (the first one without `<lane>`) shows its facts (work
  item, owner, created, folder, base lane, the lane stack's port offset and prefix, the lease `lane:<name>` with the
  session and owner of the last change, last activity, idle minutes and expiry), the **repositories** (role, branch -
  or the base commit a consumer is detached at -, folder; a worktree adopted in place is marked), the **lane stack** (the
  service rows of the stack view; a name opens the stack view with its log), its **last setup** (every step - `admin`,
  `octoCli`, `login`, `overlay` - with its status and what it did, and the warnings; see "Setup of a lane stack"), the
  services of the **shared stack** that run a build of this lane (`source: "lane:<name>"`, UC-A; `inSharedStack` of
  `lane_list`) and the lane's **jobs** (builds and test runs with kind, state, owner, the evidence - `unchanged` or
  `changed`, short `HEAD` per repository - start and duration), each linked to the jobs view.
- **Jobs** (`#/builds`, `#/builds/<id>`): refusals, running builds and test runs with progress per repository (test
  project: *project i of n*) and what the running repository or test project usually takes (*usually 5m 10s, overdue
  after 14m*; an overdue one turns the job *overdue* with a note), the history (also of earlier daemon runs), and
  *Usual durations* (`job_stats`, folded); a queued job says what it waits for. Every job
  says its kind - *lane* (`lane_build`, `lane_test`) or *base* (`base_build`, `base_test`), build (with its kind) or test
  run, and how many repositories or test projects - and what it ran on (*Ran on*: `evidence.unchanged` and the short
  `HEAD` of its repositories). Finished runs whose lane or folder no longer exists (`gone`, see "Builds") are hidden from
  the history and never listed as a current failure under attention; *Show N runs of removed lanes or folders* above the
  history brings them back, marked *gone* with the reason. A test run shows its **tests**: totals, every failed test by
  name with message and first stack frame (failed projects first), run-level errors, the projects with their counts, and
  who holds the docker test lock while it waits. A row opens outcome, notes, the **evidence** per repository (`HEAD` at
  the start and the end, branch, clean or the number of changes at each point, unchanged), errors by repository, the
  time per repository and phase (build, tests, packages, total; sums and the slowest repository) and the **output**:
  the job log or the log of one repository (those with errors first), kept by the daemon when the repository's build
  ended - so it is there after the build and after a daemon restart (`GET /api/builds/<id>/output?repo=<repo>&lines=<n>`;
  URI credentials masked).
- **Profiles** (`#/profiles`): which profile runs (in the shared stack or a lane stack) and where it drifts, every profile
  with its services, where it runs from, and a button that copies `stack_start(profile="<name>")`.
- **Configuration** (`#/config/<tab>`, data from `GET /api/config`, loaded on demand with Reload): tabs
  *Daemon* (the running daemon - pid, version, commit and build time of its binaries, shared or development -, whether a
  restart is safe now and the last starts and stops with their trigger, from `GET /api/daemon`; then the loaded devstack.yaml
  with defaults, file path, written/loaded time, the environment variables of every service, env provider scripts - never
  their results), *Services* (definitions with the repo and working directory they resolve to, shared-stack-only flag),
  *Profiles* (extends chain, the fields the profile sets or overrides, the merged result), *Slots* (index, port offset, prefix,
  running/reserved/configured, the evaluated `slotDerivations` rows and ports; retired indices), *Running services* (the
  environment variables of every running service exactly as `service_env` returns them, with a variable filter and
  "differences only"; a value that differs from what the configuration, the slot derivation or the running profile would
  set is marked with the expected value and where it comes from) and *Lane manifests*. Secret-looking values are masked
  with the `service_env` rules in every view (shown as a "masked" mark); arguments too.

It refreshes every 5 s while the tab is visible; a refresh never rebuilds the page under a text selection and keeps
focus, open logs and scroll positions. Light and dark follow the system setting. The page is read-only on purpose:
changing the stack goes through the MCP tools and their lease. It loads nothing from outside the daemon (strict
Content-Security-Policy, system fonts) and is reachable on loopback only. When `rootPath` or `defaultCheckout` does not
exist, the attention list says so (so do `stack_status.configProblems` and the daemon's start log); what octo-tools
reported about the workspace is in `config_get.workspace.problems` and the start log.

### API and MCP read the same things

Every read endpoint of the page has an MCP tool, and every read-only tool is a GET endpoint:

| Endpoint | Tools |
|---|---|
| `GET /api/overview` | `stack_status`, `stack_attention`, `job_list`, `job_refusals`, `profile_list`, `stack_list`, `lane_list`, `config_get` |
| `GET /api/logs/<service>` | `service_logs` |
| `GET /api/config` | `admin_config_inspect` |
| `GET /api/daemon` | `daemon_status` |
| `GET /api/builds/<id>` / `GET /api/builds/<id>/output` | `job_status` / `job_output` |
| `GET /api/tools/<name>?arg=value` | every read-only tool, with the arguments of its MCP call (a list: repeated argument, comma-separated or a JSON array; a map: JSON); `GET /api/tools` lists them with their parameters |

Changing tools stay MCP-only (`GET /api/tools/stack_start` answers 405): the HTTP API has no authentication, and a lease
owner is a session, not whatever page a browser shows. `/api/tools/*` also refuses requests a browser marks as cross-site
(`Sec-Fetch-Site`), so no other page can trigger an expensive read such as `build_plan`. `ApiParityTests` holds the table
above; a new endpoint or read-only tool fails it until it has its counterpart.

## Tools

The tools speak the vocabulary of octo-claude-pm (the server instructions say the same in short):

| Word | Meaning |
|---|---|
| **lane** | The workspace of one work item (octo-tools: *feature environment*): `<rootPath>/wt-<lane>` with worktrees of the repos it changes (feature) and of the repos rebuilt against them (consumer), its own NuGet feed, package cache and catalogs, and its own stack. |
| **base lane** | The checkout every lane starts from and every service of a repo a lane does not hold runs from: `branches/main` (lanes layout) or the root (flat layout). Its feed holds the merged code's `999.0.0` packages. |
| **shared stack** | The stack on the configured ports (the default slot). Tools act on it when no `lane` is given. |
| **lane stack** | A lane's own stack (its slot): shifted ports, own system database and prefixes. |
| **slot** | Internal word for a stack's port offset, prefixes and state; only admin tools and diagnostics show it. |
| **owner** | The octo-claude-pm branch `<user>/AB#<id>_<desc>` of the caller, the same value in every call. Leases and jobs are recorded under it. |
| **session** | The caller's `ListAgents` name (e.g. `meshmakers-07`), so another session can message the holder of a lease or claim. Optional, recommended. |
| **envVars** | Environment variables for services. No parameter is called `env`: a lane is `lane`. |
| **job** | A build or a test run in the daemon's queue. |

| Area | Tool | What it does |
|---|---|---|
| Lanes | `lane_list(lane?)` | The lanes (`<rootPath>/wt-<lane>` folders with a manifest): work item, base lane, owner, repos with their paths (edit there), the lane stack with health and lease (`lane:<name>`, its session, `lastActivityAt`, `idleMinutes`), queued/running jobs, `inSharedStack` (the shared stack's services that run the lane's build), problems; with `lane`: that one plus `Get-OctoEnvironment`'s details (per repo exists, dirty, unpushed) |
| | `lane_create(owner, lane, repos, branch, workItem, session, addAffected, skipPackageCacheSeed)` | `New-OctoEnvironment`: feature worktrees on `branch`, own feed and package cache (filled from a local cache), its slot reserved; a note names libraries outside the lane whose base-lane packages were built from a commit behind their upstream (nuspec commit, else the checkout HEAD), with the fix `lane_add_repo(role=consumer)`, and says when that check failed |
| | `lane_add_repo(owner, lane, repo \| path, role, addAffected, inPlace, session)` | `Add-OctoEnvironmentRepo`: a new feature/consumer worktree, or an existing worktree adopted; waits up to 45 s for the lane's running or queued jobs (then `success=false`, `retryAfterJob=<id>`: call again after `job_status` says it ended); deletes the added repo's `obj/project.nuget.cache` so the next `lane_build` restores it against the lane feed; refused while a service of that repo runs in its stack; notes name stale base-lane packages |
| | `lane_sync(owner, lane, session)` | `Sync-OctoEnvironment`: refresh the snapshot of the base lane's feed and catalogs; refused while a range/all build of the base lane runs or waits, or the lane builds |
| | `lane_affected(lane, target?)` | `Get-OctoAffectedRepos [-target]`: the repos the lane's changes reach (read-only) |
| | `lane_build(owner, lane, repos, skip, verifyTests = true, syncMain, stopServices, restartServices, buildUnchanged, includeTests, maxParallel, refreshCatalogs, dryRun, session)` | `Invoke-BuildEnvironment`: the lane's repos that changed into its own feed, test projects compiled; a job (see "Lanes") |
| | `lane_test(owner, lane, repo, project, filter, rerunFailed, includeSlow, ..., session)` | `Invoke-OctoTestRun` of one repo of the lane as a job; leaves the slow categories Performance and Stress out unless `includeSlow=true` (see "Test runs") |
| | `lane_remove(owner, lane, keepData, keepBranches, session)` | Remove a lane, leaving nothing behind: refused while a process the daemon did not start holds files below it; stop the lane stack, release its lease, `Remove-OctoEnvironment` (refuses dirty or unpushed worktrees), then drop the lane stack's data (`dataDrop`; `leftovers` list what remains) and delete the feature branches without commits (`branches`) - see "Removing a lane" |
| Base lane | `base_build(owner, kind = repo \| range \| all \| profile, path, baseLane, from, to, include, exclude, profile, publish, confirm, stopServices, restartServices, ..., session)` | Builds of the base lane (see "Builds"); `range` (`publish=true`) and `all` (`confirm=true`) only with the developer's go |
| | `base_test(owner, repo, baseLane?, project, filter, rerunFailed, includeSlow, ..., session)` | `Invoke-OctoTestRun` of one repo of the base lane as a job (slow categories as `lane_test`) |
| Jobs | `job_status(id, waitSeconds, repo, project, errorsOnly, include, live, includePassed)` | A build or test run in a compact shape (progress, ETA, seconds per repo and phase, parsed errors; a test run's failed tests by name); `waitSeconds` (max 50, a longer value is capped with a note) waits until the job ends and says `timedOut` when it did not. `job_status` / `job_output` / `job_cancel` take the full id (`b351-081503`) or the short one (`b351`, `351`; exactly that sequence, an ambiguous one is refused) |
| | `job_list(lane?, limit=20)` / `job_cancel(owner, id, lane?, session)` | One line per job the daemon knows (also of earlier daemon runs), newest first - id, kind, state, lane, target, summary, queued, seconds, owner; cancel your own (any session of a lane cancels the lane's jobs) |
| | `job_output(id, repo?, lines)` / `job_refusals` | Up to 5000 log lines of one repo or the job (`GET /api/builds/<id>/output`); the builds refused in the last 2 hours with their conflicts |
| | `job_stats(repo?)` | What repository builds and test projects usually take on this machine (median, p90, max, last, the overdue limit), slowest first - see "Usual durations and overdue jobs" |
| | `build_plan(kind \| lane, ...)` | What a `base_build` or `lane_build` would do, read-only: order and mode per repo, the predicted action per repo of a lane, stale flags, conflicts with running services, warnings, gates (see "Builds") |
| Stacks | `stack_status(lane?)` | Services with pid (the process the daemon started; on Windows the `cmd.exe` wrapper, and `processId` is the service's own process below it - the pid RabbitMQ and `stack_verify` report), the entry assembly each process really loaded (macOS/Linux; `entryAssemblyProblem` when it is not below the service's folder), state (healthy/starting/unhealthy/exited), the folder it runs from and `runsFrom` (`lane:<name>`, `base lane` or the folder of a source override), who started or overrode it (`startedBy` = the owner of that call, `startedBySession`, `startedVia`: `stack_start`, `service_start`, `service_restart` or the restart after a build - in a lane stack too, whose lease the lane holds), log file, exit code and log tail of crashed services; `baseLane` (the base lane it runs from) and `lane` (a lane stack's lane); lease (owner, session, last activity); `external` = processes the daemon did not start on service ports (e.g. a `Start-Octo` in a terminal); `slots` = every stack in one line; a lane stack's last setup |
| | `stack_start(owner, lane?, profile, services, exclude, overrides, envVars, replace, waitForHealthy, timeoutSeconds, baseLane, configuration, session)` | Start the shared stack (from the base lane) or a lane stack (`lane`) from a `profile` and/or a service list; per-service `overrides` (`source` = `lane:<name>` or a folder, `args`, `extraArgs`, `envVars`, `variables`) and stack-wide `envVars`; `replace=true` switches a running stack; waits for health by default. Without `services` a lane stack leaves out what cannot run there - the frontends, an adapter whose tenant another running stack serves - and lists each in `leftOut` with the reason and how to include it (a named list is refused instead). Named services bring their `startAfter` dependencies that do not run yet (`added`, see "Start order") |
| | `stack_stop(owner, lane?, session)` | Stop all services of the stack (SIGTERM to the process tree - CTRL_BREAK on Windows -, SIGKILL after `stopTimeoutSeconds`) |
| | `stack_attention` | What needs attention, worst first - the list at the top of the status page, with `hint` = the call that explains each item |
| | `stack_list` | The stacks: the shared stack and every lane stack or named slot with index, port offset, prefix, lane, lease holder, profile, health, the ports of every service, the derived values, the generated files and the last setup |
| | `stack_setup(owner, lane, steps, tenants, renew, session)` | Set a lane stack up again, or repeat a step: `admin` (first admin of the fresh system database, password in an owner-only file), `octoCli` (installation entry `local-<slot>` and contexts `local-<slot>_<tenant>`, the active context never changes), `login` (client-credentials client `devstack-<slot>`, logs the contexts in without a browser), `overlay` (identity overlay). The daemon runs it by itself after a lane stack's identity service got healthy (see "Setup of a lane stack") |
| | `stack_verify(lane)` | A lane stack's derived data names against the local infrastructure: system database, tenant registry and ownership markers (AB#4945), tenant databases two stacks register, RabbitMQ queues and consumers with its prefix (`consumerConnections`: connection, `processId`, host and the stack's `service` it belongs to), CrateDB schemas; `ok` = no warning and every store answered |
| Services | `service_start` / `service_stop` / `service_restart(owner, services, lane?, overrides, waitForHealthy, timeoutSeconds, session)` | Change single services of the running stack; `service_start` brings the `startAfter` dependencies that do not run (`added`); restart keeps the previous overrides unless new ones are given (`{}` drops them); `overrides.<service>.source = "lane:<name>"` runs that lane's worktree of the service's repo (refused, with the lanes that hold the repo, when the lane does not) |
| | `service_logs(service, lane?, lines, grep, previous, pid, maxChars)` | Tail / grep of `<base lane>/logFiles/<logName>.log` (the files Start-Octo writes; a lane stack logs into `<rootPath>/wt-<lane>/logFiles`); `previous=true` for the run before; at most `maxChars` (default 20000) characters, newest lines kept, lines over 2000 characters cut with a marker |
| | `service_env(service, lane?)` | The environment variables of a running service (`envVars`): the ones octo-devstack started it with, or for a service adopted after a daemon restart the process environment (`ps eww` on macOS, `/proc` on Linux); secret-looking values masked by the last key segment (a path setting like `...__SECRETSWEEP__BACKUPSTORAGEPATH` stays visible) |
| Lease | `lease_status(lane?)` / `lease_acquire(owner, session, purpose, ttlMinutes, waitSeconds)` / `lease_release(owner, force, session)` | Who owns the shared stack (owner, session, `lastActivityAt`, `idleMinutes`, queue; `lane`: the lane stack's lease); queue for it; hand it on: `lease_release` answers `released`, the `formerHolder` and the `holder` now (the first waiter gets it at once; `force=true` only on the developer's go) |
| Workspace | `workspace_list` | The base lane (`isBaseLane`), other base lane folders and the lanes (`lane`, `base`), with their git worktrees (`relativeToBaseLane` is a source a service override takes), the services they can replace and their built configurations |
| Read-only info | `profile_list` / `profile_get` | The profiles, which one runs (`activeIn`) and how it differs; one profile as written or resolved, compared `against` the running stack, an external group or another profile |
| | `config_get` | The configuration as written (`baseLane`, `envVars`, the services with their `envVars`), secret-looking values masked |
| | `daemon_status` | The daemon itself: pid, version and commit of the running binaries, `restart.safe` (no job runs or waits) with blockers and lease holders, the last starts and stops (same document as `GET /api/daemon`) |
| | `setup_check` | What this machine still needs, each with its fix: octo-tools (found, describes the workspace), base lane, `installations.json`, pwsh, .NET 10 SDK, lsof (macOS; Linux reads `/proc` without it), trusted dev certificate, Docker, kind infrastructure, octo-cli contexts, whether octo-cli resolves on the daemon's own PATH (its process environment, not the caller's: a daemon started from a shell with an old PATH keeps it - restart it from a new shell with `Start-OctoDevStackDaemon -Restart`), stale paths (checkout and repository folders the daemon's state or a lane's manifest still names but that no longer exist - a checkout that moved, AB#9555), the Claude Code registration (AB#9377), and the build variables the repos of the base lane need, as the daemon's builds see them (names only, AB#9464). Run it first on a new machine, and when a lane stack's setup fails |
| | `infra_status` | `Get-OctoKubernetesStatus -SkipS3Probe -Json`, pods summarized |
| Developer | `dashboard_open(view?, lane?)` | Open the status page in the developer's default browser (only when the developer asks; the command `/mcp__octo-devstack__dashboard`): `url`, `opened`, `note` - see "Status page". Changes nothing, takes no owner; not in the agent view |
| | `test_lock` | Who holds the machine-wide docker test lock (see "Test runs"; the owner's `baseLane` and `lane`) |
| Admin (the developer's go) | `admin_profile_save` / `admin_profile_delete` | Save a profile from a spec or capture the running stack (`capture="daemon"` or an external group key); delete one (refused while extended) |
| | `admin_config_inspect` | The configuration as the status page's config view shows it (`GET /api/config`): what services resolve to, profiles merged, slots with ports and derivations, retired slots, lane manifests |
| | `admin_config_set_defaults(owner, baseLane, configuration, stopTimeoutSeconds)` | The base lane (`defaultCheckout`), configuration and stop timeout of devstack.yaml |
| | `admin_config_import_defaults` | Copy built-in services and profiles a devstack.yaml written by an older daemon lacks (e.g. the apps); without names: what is missing |
| | `admin_service_define` / `admin_service_remove` | Add a service or change fields of one (`envVars`, ...), remove one (persisted) |
| | `admin_envvar_set` | Set or remove a global or per-service environment variable (persisted) |
| | `admin_lane_seed_cache(owner, lane, dryRun)` | Fill or top up an existing lane's package cache from a local cache (`Initialize-OctoEnvironmentPackageCache`) |
| | `admin_slot_retired` / `admin_slot_forget(owner, index, confirmDataDropped, session)` | Indices of removed lanes' stacks kept back with their leftovers (and drop commands): `lane_remove(keepData=true)`, a data drop with a failed step, a lane removed before the daemon dropped data; free one with `confirmDataDropped=true` once the developer confirmed the data is dropped by hand |
| | `admin_slot_drop_data(owner, index, session)` | Drop the data of a retired index as `lane_remove` does after a removal (databases, queues and exchanges, schemas, octo-cli entry and contexts, state folder, the lane's secret files), step by step; frees the index when every step succeeded (see "Removing a lane") |

Read-only tools are marked `ReadOnly`, removing or stopping tools `Destructive`. A coordinator (Odin, Frigg, a PO agent)
uses only the read-only ones. `http://127.0.0.1:5090/mcp?view=agent` is the **agent view** of the server: every tool except
the `admin_*` ones and the developer's `dashboard_open`, which it neither lists nor calls, and without the prompt `dashboard` (register agents with that URL; `/mcp` serves every tool and prompt).

Without `lane`, `stack_*`, `service_*` and `lease_*` act on the shared stack (or on the only other slot whose lease the
owner holds; a `slot` parameter, for diagnostics only, names a slot that belongs to no lane). With `lane=<name>` they act
on the lane stack: the lane holds that stack's lease (`lane:<name>`), so every session of the lane shares it.

Every changing call takes an `owner` and, recommended, a `session`. The first changing call takes a free lease; other
sessions are refused with the holder's owner and session until it calls `lease_release`, the lease expires or they queue
with `lease_acquire(waitSeconds)`. The lease is an idle timeout: it expires 30 minutes (`lease_acquire(ttlMinutes)`:
5-720) after the holder's last activity - its last changing call, or the end of a build that pinned it - and
`lease_status` shows that activity (`lastActivityAt`, local time) and `idleMinutes`. Leases survive a daemon restart with
their last activity. Leases and lane claims keep the session next to the owner (`- Session: <session>`, `- Owner:
<owner>` in the claim file).

### Typical flows

The flows of the agents - a work item in its own lane (UC-B), a lane's service in the shared stack (UC-A) and the
octo-claude-pm roles (UC-C) - are under "For agents (octo-claude-pm)" above.

A library change of the base lane (construction kit engine, SDK, ...) reaches the services only through the base lane's
`999.0.0` packages - with the developer's go: `base_build(kind="range", from="octo-construction-kit-engine",
to="octo-asset-repo-services", publish=true, stopServices=true, restartServices=true)`. A lane builds its library changes
into its own feed with `lane_build` instead.

## Builds

Base lane builds (`base_build` kind `repo`, `range`, `all`, `profile`) run one at a time through the octo-tools cmdlets
(they share the base lane's `nuget` folder and package caches); lane builds (`lane_build`) run next to each other (see
"Lanes"), and so do builds of plain worktrees (see "Worktree builds" below). Every `base_build` / `lane_build` returns a job at once - wait with `job_status(id, waitSeconds)`, which answers
when the job ended or the time is up (`timedOut`); `job_status(id)` returns a compact state (normally below 2 KB): state, queue
position (and `waitingFor`: the builds a queued job waits for), local times with `elapsedSeconds` and `etaSeconds`,
progress (phase `stopping|build|tests|packages|restarting`, repo i of n, per repo its state and `seconds` /
`buildSeconds` / `testSeconds` / `packageSeconds` from the cmdlets' events, `totals` per phase with the slowest repo), outcome (`failedRepo`, `failedStep`, `summary`, `hint`), parsed errors (up to
20 per repo: file, line, column, code, message, project; `repo=X` returns up to 100 of one repo), stopped services, notes
and log paths. `include=["raw"]` adds the cmdlets' `-Json` documents and the output tail.

**Lanes without repositories and runs of removed places** (AB#8915):

- `base_build` / `build_plan` of kind `range`, `all` and `profile`, and `base_test`, refuse a folder that
  holds no repository - no folder named `octo-*` or `mm-*`, the rule of octo-tools' `Get-OctoBuildOrder`; the developer
  tools `octo-tools`, `octo-devstack` and `octo-claude-pm` do not count, so the old flat root that holds only them after the
  move to the lanes layout is no lane, and its finished jobs are `gone` - before a job
  exists: the error names the folder and points to `lane_build` / `lane_test` (a lane, `lane_list`) or a base lane folder
  such as `baseLane=branches/main`. The typical case is a git worktree of one repository passed as the base lane; build it
  with `base_build kind=repo path=<worktree>`. A test run of a consumer app named exactly (a git repository such as `energy-community` in
  the lane) is accepted, as `Invoke-OctoTestRun` accepts it. Lanes check their own repositories (`lane_build`,
  `lane_test`).
- A **finished** job whose lane was removed (no manifest any more), whose base lane folder was deleted or holds no
  repository any more, or - for `kind=repo`, also inside an environment - whose repository folder is gone carries `gone`
  with the reason in `job_status` and `job_list`. The flag is computed from the disk on every read and
  never stored, so a folder that comes back clears it; a queued or running job is never `gone`. A job started with
  `baseLane=` set to a lane folder counts as a job of that lane (its job file records the environment):
  the manifest decides, not the lane rule, because an environment's repos may lie outside its folder. The status page
  hides such runs by default and does not count them as current failures.

| Kind | Cmdlet | Who may run it |
|---|---|---|
| `repo` on a worktree (folder with a `.git` file) | `Invoke-Build` | every session, no lease; runs next to other worktree builds and lane builds (below) |
| `repo` on a worktree below `<repo>/.claude/worktrees/` | - | refused before it runs (NU5118, below) |
| `repo` on a lane repo | `Invoke-Build` | every session; the lease and `stopServices=true` only when octo-devstack's services run out of it |
| `range` | `Invoke-BuildRange` | the lease holder with `publish=true` - it changes `<lane>/nuget` and the lane's caches for every session |
| `range` with `packages=private` (deprecated) | `Invoke-BuildRange -feedPath` | the lease holder with `publish=true`; packages go into a feed of the owner under the state folder |
| `all` | `Invoke-BuildAll` | the lease holder (plus the lane claim) with `confirm=true`, only when the developer asks; 30-90 min, wipes `<lane>/nuget` and `meshmakers.*/999.0.0` in the caches the lane restores into (every lane has its own cache, `RestorePackagesPath` in its `Octo.User.props`) |
| `profile` | `Invoke-Build` per stale repo | every session; the lease when services must be stopped or `restartServices=true` |
| `lane_build` (kind `lane` in `job_list`) | `Invoke-BuildEnvironment -env <lane>` | every session with `lane`; the lane stack's lease (held by the lane) only when its services must be stopped |

- **Worktree builds** (WP-C): a `base_build` kind=repo of a plain git worktree - a folder with a `.git` file that is neither a
  repo folder of the base lane (`<base lane>/<repo>`) nor of a lane, built with `Invoke-Build` (or with nothing to build),
  without `packages=private` - is a class of its own: worktree builds run next to each other (one per worktree, at most
  two at once) and next to lane builds (`lane_build`). What such a build writes was checked in octo-tools' `Invoke-Build`
  and the repos' props: it restores from the base lane's feed (read only) into the base lane's package cache (NuGet extracts a
  package under its own lock and never purges), writes `bin`, `obj` and its packages into the worktree, and a CK model
  project with `OctoPublishCkModel` publishes into the base lane's local CK catalog under the catalog's index lock (the remote
  catalog caches are per user, refreshed under a lock and written atomically). It never writes the base lane's `nuget` and never
  purges the cache - that is what `range` and `all` do, and they still run alone, as every other base lane build does;
  a waiting base lane build still holds back every job queued after it. A worktree with a `build.ps1` (mode `script`, it
  may build sibling repos of the base lane such as `../octo-frontend-libraries`) or a `frontend` repo stays a base lane build.
  Two jobs that build or test the same folder never run at once (a lane may adopt a worktree in place): `waitingFor`
  names the job that has the folder.
- **Nested worktrees**: a `base_build` kind=repo of a worktree below `<repo>/.claude/worktrees/` is refused before a job is
  created: the OctoMesh repos' `Directory.Build.props` imports the next `Directory.Build.props` above the repository,
  which for a nested worktree is the main checkout's, and the pack fails with NU5118 (README.md added twice). The answer
  names the way out: `lane_add_repo` with `path` moves the worktree into a lane, `lane_build` builds it there. A
  `base_build` kind=profile leaves such a worktree out with the same reason in a warning.
- **Evidence** (WP-C): every job - build or test run - records per repository it covers (a build's plan repos, a test
  run's tested repository) the work tree path and, at the start and at the end of the job, `head` (the full SHA),
  `branch` and `clean` (`git --no-optional-locks -c core.quotePath=false status --porcelain=v2 --untracked-files=all`:
  untracked files count, each on its own, ignored ones do not; `changes` counts the entries; only the root of a work tree
  is read, a folder without its own `.git` gets an `error`) and, when it is not clean, `fingerprint` (a hash of the
  changed entries and of the content of every file they name; none - so never "the same" - when it would not cover every
  change: a path git still quotes, an untracked nested repository, a changed file over 16 MB, more than 20000 entries).
  `job_status` shows it as `evidence`: the repos with `start`, `end` and `unchanged` (the same HEAD and the same changed
  files with the same content at both - clean or not: an uncommitted edit made before the job is the normal flow, an edit
  made while it ran is not) and `unchanged` for the whole job once it ended. That verdict compares the two recorded
  points only: it says the job started and ended on the same state, not that the work tree is still so now (an edit after
  the end, or one made and undone while the job ran, does not show) - before relying on it for the current work tree,
  compare `end.head` and the work tree once more; `clean` stays per point in time. A job with more than ten repositories
  lists only the ones that are not fine (`omitted` counts the others; `repo=X` or `include=["raw"]` shows them). It is
  kept in the job file and survives a daemon restart (the next daemon reads the end of a job that ran across it).
  octo-claude-pm's verify gate can accept an unchanged, successful job for `end.head` and the work tree as it is at that
  check instead of a second plain `dotnet build` / `dotnet test`.
- **Conflicts** are checked per repo of the plan (a worktree nested in a lane repo, e.g. `.claude/worktrees/x`, is not
  part of it), for octo-devstack's own services and for processes it did not start, at `base_build` / `lane_build` and again right
  before the job runs. A conflict with an own service names who started or overrode that service (`startedBy`: the owner
  of its `stack_start`, `service_start`, or `service_restart` with overrides, that call and the caller's session) - in the shared stack often
  another session than the one that started the stack; a restart that keeps the overrides and the start after a build keep
  it. `stack_status` shows the same per service (`services[].startedBy` / `startedBySession` / `startedVia`; kept across a daemon restart).
  Own services need `stopServices=true`; `restartServices=true` starts them again after a successful
  build with their worktree overrides and profile instances. External processes refuse the build with who started them
  and their stop hint; only `kind=all` with `stopExternal=true` stops non-interactive Start-Octo stacks itself
  (`Stop-Octo -branch`, then waits until their processes are gone). When the scan of those processes fails (an error
  while reading the OS, e.g. a pid seen twice), no call fails because of it: the processes outside the daemon are
  unknown then, `stack_status` says so in `external.warning` and a job's plan in a warning, and the job runs without that
  check (AB#9556).
- While a build runs, no service starts from its repos (for range and all: from its lane); `stack_start` and
  `service_start` name the build and its owner. Jobs run strictly first in, first out. A job that needs the lease
  checks right before it runs that its owner still holds it (otherwise it fails with `failedStep: "preflight"`) and pins
  the lease while it runs, so it cannot expire during a long build.
- **Success** means the cmdlet's JSON document (of the build cmdlet itself, not of a nested one) says success and pwsh exits with 0 (`Invoke-BuildAll`: no failed repo).
- **Build mode of `kind=repo`** (and of the repos `kind=profile` builds) follows the files in the repository root, as
  `Invoke-BuildAll` decides it (octo-tools `Get-RepoBuilder` / `Get-OctoRepoBuildMode`): a `build.ps1` runs that script
  (mode `script`, e.g. `octo-frontend-refinery-studio`, whose script also builds `../octo-frontend-libraries`); without a
  `.sln`/`.slnx` (or a project file, which `Invoke-Build` takes too) there is nothing to build (mode `none`, e.g.
  `octo-frontend-libraries` - the job succeeds with "nothing to build", `Invoke-BuildAll` skips it as well); a solution of
  a repo named `*frontend*` is published with `Invoke-Publish` (mode `frontend`); everything else is `dotnet`
  (`Invoke-Build`). `build_plan` shows the mode per repo. A `script` or `none` step prints its own `-Json` result (command
  `octo-devstack-repo-build`); the exit code of `build.ps1` decides. Such steps write no build events and say nothing
  about test projects; `packages=private` and `refreshCatalogs` do not apply to them (a plan warning says so).
  `octo-plug-zenon` repos stay `dotnet` (AB#9417). When such a step fails, `job_status` reports the error lines of its
  own output (the first one also in the summary, e.g. `ERROR: TELERIK_LICENSE environment variable is not set!`); a
  repo's `Invoke-Build.log` counts only when the step wrote it, never one an earlier `Invoke-Build` left behind (AB#9464).
- **Build variables** (AB#9464): a build gets the daemon's environment plus what octo-tools' `profile.ps1` sets, and that
  loads your private PowerShell profile (`~/.pwsh/profile.ps1`; macOS `~/.config/powershell/Microsoft.PowerShell_profile_private.ps1`).
  A daemon started by a LaunchAgent, systemd unit or logon task does not read `~/.zshrc` or `~/.bashrc`, so variables the
  builds need - `TELERIK_LICENSE` for the frontend builds - go into the private profile (`$env:TELERIK_LICENSE = '...'`),
  never into `devstack.yaml`, a plist or a repository. `buildVariables` in `devstack.yaml` names them (names only; the
  built-in list always applies, an own entry adds to it), and `setup_check` says which one the builds lack and the file to
  set it in.
- **Timeouts**: repo 45 min, range 2 h, all 3 h, plus 20 min without activity: output, a build event, or - for a test
  run - a write to its test logs below `<lane>/logFiles/test-results/<repo>` (dotnet test and ng write only there, the job
  log stays empty while a suite runs; looked at every 10 s and again right before a termination, AB#9417). The outcome of a terminated job names what was
  watched ("no output, no test event and no write to the test logs under ... for 20 min"). `job_cancel` terminates
  the pwsh tree and starts the services the build stopped again; a canceled range or all build may leave the lane's
  nuget folder partially updated.
- **packages=private** (deprecated - a feature environment has its own feed, cache, slot and lease; every private build
  carries a warning saying so): the range goes into `<state>/feeds/<owner>/nuget` with its own cache `<state>/feeds/<owner>/packages`
  (`-feedPath`, `RestoreSources`/`RestorePackagesPath` global properties, `NUGET_PACKAGES`); consumer repos and worktrees
  built with `kind=repo packages=private` restore from that feed. The private feed is the only local source of a private
  build (NuGet takes whichever source answers first, not the first listed): before every private step the lane's
  packages are mirrored into it (packages built into the feed win) and extracted packages in the private cache that
  differ from the feed are purged (every local build is 999.0.0, and NuGet never re-extracts a version it has).
  Building a lane repo with `packages=private` still writes that repo's `bin`/`obj`; use a worktree as the consumer
  when other sessions run services from the lane.
- **Output while it runs**: the cmdlets print their result only at the end (`-Json`), so the job log stays nearly empty
  during a run - dotnet writes into each repo's `Invoke-Build.log`, a test project into its log below
  `<lane>/logFiles/test-results`. `job_status(id, live=N)` adds the last N lines (max 200,
  long lines cut) of the repo or test project that runs right now as `live` (`repo=X` / `project=X` picks one, also after
  the run, from the log the daemon kept). The status page shows that log by itself and refreshes it every few seconds.
- **A build never runs tests.** `verifyTests` compiles the test projects, `includeTests` builds them with the build;
  `kind=repo` and `kind=all` build the whole solution. Every built repo carries `tests: notCompiled | compiled`, and the
  summary ends with it ("...; test projects NOT compiled and no test ran (verifyTests=true compiles them, lane_test / base_test run
  them)"). Tests run with `lane_test` / `base_test` only.
- **Progress** comes from the cmdlets' `-EventsFile` (JSON lines) or, with older octo-tools, from each repo's
  `Invoke-Build.log`; the ETA from the lane's last five durations of a repo and configuration, else from the median of
  every lane's. The errors of a failed repo are parsed when its build ends and its log is copied into the state folder
  (the next build of the repo deletes `Invoke-Build.log`).
- **Usual durations and overdue jobs**: the daemon keeps the last 30 durations of every successful repository build
  (across lanes) and of every test project of an unfiltered test run (passed or failed; a run with `filter` or
  `rerunFailed` runs only a part of a project and is not counted, neither is a run with `includeSlow`), per repository,
  test project and configuration (samples recorded before octo-tools AB#9829 include the slow categories, so median and
  p90 of such a project fall only as new runs replace them - the series keeps the last 30); a
  test project's runs that compile it first and those on its last build are two series (`compilesFirst`), and a running
  project is compared with the series of its own kind (`duration-history.json` in the state folder; the
  `build-history.json` of earlier daemons is taken over, and a damaged file starts an empty history).
  `job_stats(repo?)` lists them slowest first with samples, median, p90, min, max, the last duration and `limitSeconds`
  = twice p90, at least median + 120 s, from three samples on. A running repository or test project beyond its limit is
  **overdue** - it runs far longer than usual and probably hangs: `job_status` marks it in `progress.current` /
  `progress.running` (`typicalSeconds`, `limitSeconds`, `overdue: true`), `stack_attention` lists it (kind `overdue`,
  level caution, with the `job_output` and `job_cancel` calls), and the status page marks the job *overdue*. A filtered
  test run is compared with the whole project's durations, so only a filtered run slower than a whole one is overdue.
- **rootPath**: octo-tools' `profile.ps1` sets `$rootPath`/`ROOTPATH` to `<octo-tools>/../..` (for an octo-tools worktree
  `.../octo-tools/.claude/worktrees`), and the cmdlets resolve `-branch` against it. Every build call of the daemon sets
  them to the daemon's `rootPath` first, so `-branch` is always relative to the daemon's rootPath.
- **octo-tools capabilities** are probed once (cached 10 min): without `-EventsFile` progress uses the logs, without
  `-feedPath` `packages=private` is refused, and without `-repoPaths` worktrees cannot join a range. `build_plan` lists
  what is missing. On Windows `kind=all` needs `Invoke-BuildAll -skipKill` and the lane-scoped `Invoke-KillDotnet
  -branchRootPath` (without them it would kill every dotnet process of the machine) and is refused with an older octo-tools. An external service whose
  working directory cannot be read counts as a conflict when its repo is in the plan.
- **Builds survive a daemon restart.** A build step runs detached from the daemon: a wrapper (`/bin/sh`; `cmd.exe` on
  Windows) starts pwsh with its output appended to `builds/<id>.log` and leaves the exit code in
  `builds/<id>.<step>.exit` when it ends; the daemon only watches (exit marker, pid, events file, log). Every job is kept
  in `builds/<id>.job.json` (request, plan, step pid with its OS start time, state, result, notes, errors), written on
  every change. The next start reads them:
  - a **running** build whose process still is the recorded one (pid alive, same start time, command line names the
    step's exit marker) is re-attached - progress, timeouts, `job_cancel` by its owner and the queue rules work as
    before, a note says when it was re-attached; one that **ended meanwhile** gets its result from the exit marker, the
    `-Json` document in the log and the events file; one that was killed (no marker, no `done` event) fails with
    `failedStep: lost`. A job between two steps, or stopping/restarting services, goes on from there (the services a
    build stopped are in the job file and are started again);
  - **queued** builds wait again in their order (their preflight - conflicts, leases - runs when they start);
  - **finished** builds stay answerable: `job_status` / `job_list` and the status page keep the last 50 for 14 days,
    with the logs of their repos, and always the last build and the last test run of every lane that still exists.
  - **macOS**: while a job runs the daemon keeps the machine awake with `caffeinate -i -w <job pid>`; it ends with the
    job's process (also across a daemon restart). Other systems: nothing.
  A build started by a daemon version without job files (only a pid in `state.json`) is taken over too: it is `running`
  in its queue class (an environment build holds back only its own environment), its owner can cancel it, and when it
  ends its result comes from its events file (`... the process left no exit code; result from its build events`) - there
  is no state `orphaned` any more, and such a build no longer blocks every other build.
  Windows: the wrapper is `cmd.exe`, built like the service wrapper; its marker holds the exit code as on macOS/Linux
  (`call echo %^ERRORLEVEL%` after the step, the script's text unexpanded), and the detached-step and restart tests run
  there too.

### Test runs

Builds never run tests (`verifyTests` compiles them, `includeTests` builds them). `lane_test(owner, lane, repo, project?, filter?, rerunFailed?)` /
`base_test(owner, repo, baseLane?, ...)` run them with octo-tools' `Invoke-OctoTestRun` (AB#8813) as a job of the same queue -
kind `test` in `job_list`, cancelled with `job_cancel`, kept across a daemon restart like a build:

- **Frontend tests**: an Angular workspace of the repository with a `test` script (an app such as `voest-app` or
  `energy-community`) is a test project named after its folder: `lane_test(owner, lane, repo="voest-app")` / `base_test(owner, repo="voest-app")` runs
  `ng test` headless; `filter` is then a regular expression over suite and test names, a failed test is named
  `<spec file> :: <test name>`, and `rerunFailed` runs the spec files that failed (octo-tools AB#8819). When two
  workspaces of a repository share a folder name, their project names are the repository-relative paths with dots
  (`apps.web`); pass that name as `project`.
- **Runners, filters, states** (octo-tools AB#8832): every project says its `runner` (`vstest`, `mtp` = Microsoft.Testing.Platform
  with TUnit or xunit.v3, `ng`, `pester`; known when the run ended). `filter` is handed over as given and never translated: VSTest takes
  an expression (`FullyQualifiedName~X`), TUnit and xunit.v3 on MTP a tree filter (`/*/*/Class/*`); a project whose runner
  cannot take the given form is not started (`noMatch`, the note names the form it takes). With a filter a project in which
  nothing matched is `noMatch` - a success; the run fails only when nothing matched anywhere ("the filter matched no test in
  any project"). Without a filter a project that runs no test is `noTests` and fails the run ("no test ran in X"); an older
  octo-tools reports `noTests` as a success. `includePassed=true` (`maxPassed`, default 200) keeps the names of the passed
  tests: `job_status` shows `passedListed` per project and the names with `includePassed=true`; refused with an octo-tools
  without `-includePassed`.
- **What runs**: every test project of the repository, or the ones in `project`; `filter` is a `dotnet test --filter`
  expression; `rerunFailed=true` runs only the tests that failed in each project's last result. No full rebuild: a
  project whose build is current runs with `--no-build`, otherwise `dotnet test` builds it incrementally (`buildReason`).
  A repository with `tests/*.Tests.ps1` has the test project `Pester` (runner `pester`; Pester 5 in a pwsh of its own).
- **Slow tests are left out by default** (octo-tools AB#9829): a run without `filter` and `rerunFailed` leaves out the tests
  with trait `Category=Performance` or `Category=Stress` - the wall-clock budget and memory-pressure tests that CI leaves
  out as well (`--filter "Category!=Performance&Category!=Stress"`) and runs in its performance pipelines. VSTest projects
  get that filter, xunit.v3 on MTP `--filter-not-trait Category=<name>`; TUnit, frontend and Pester projects run unchanged.
  `includeSlow=true` runs them too (in octo-construction-kit-engine-mongodb they take about 17 of the 25 minutes of
  `Runtime.Engine.MongoDb.IntegrationTests`); a `filter` or `rerunFailed` runs exactly what it names. A project that then
  runs no test stays `noTests`, and its note names the categories left out. `job_status` names them per project
  (`excludedCategories`, left out when none). A run with `includeSlow` is no sample for
  `job_stats`. Refused with an octo-tools without `-includeSlow` (there every test runs anyway).
- **rerunFailed** reruns the failed tests of one job: the newest finished test run of the repository in that lane; only its
  projects with failed tests run, and a note names the job. Refused before a job exists when that run had no failed test
  (the refusal names an earlier run that had), when octo-devstack knows no such run, or while a run of the repository
  waits or runs. A run in which no test ran is failed, never succeeded. Pester runs whole test files: its failed tests are
  not run again (the note says so); when only Pester failed, rerunFailed is refused and names `project="Pester"` without it.
- **Stopped projects**: a project ended by `job_cancel` is `canceled`, one the idle watchdog or the timeout ended
  `terminated` (never `error`); the summary names it and what the finished projects passed before. VSTest projects run
  with `--logger console;verbosity=normal`: a line per test in the project's log, which the idle watchdog counts as
  progress (suites that write their TRX only at the end are not taken for a hang).
- **Frontend preconditions**: `lane_test` of an octo-frontend-* repository is refused before it builds when the lane does
  not hold octo-frontend-libraries or `TELERIK_LICENSE` (devstack.yaml `buildVariables`) is not set for the daemon's
  builds - checked by name, never by value.
- **Queue class**: the lane (`lane_test`), or the base lane folder for `base_test`. A test run waits for a build or test run
  of the same environment or lane and for an exclusive lane build; it does not count against the limit of two parallel
  environment builds. An exclusive lane build waits for running test runs too.
- **Services that run from the tested repository** (WP-C): `Invoke-OctoTestRun` rebuilds the project of a service that
  runs from the repository (its build-state check looks only below `<project>/bin/<configuration>`, while many repos
  build into `<repo>/bin/<configuration>`), and on Windows that fails with MSB3027 while the service runs. So a test run
  stops the services of its target stack - the lane stack for `lane_test`, the shared stack for `base_test` -
  whose folder lies in the tested repository (the lane's repo folder, or the base lane's for the shared stack) before
  the run, and starts them again afterwards with their previous source, also after a failed or canceled run; the
  queued answer lists them in `stoppedServices` and says so in a note. Stopping them needs the stack's lease, as a
  build with `stopServices`: the lane holds its own (`lane:<name>`); the shared stack's is taken when it is free, and
  when another session holds it the run is refused before a job exists, naming the services and the holder. A
  `lane_test` also stops the shared stack's services that run the lane's repository (UC-A: `service_restart` with
  `source: "lane:<name>"`): with the caller's lease of the shared stack - the caller's `owner`, not the lane - taken when
  it is free; when another session holds it, the run is refused before a job exists with the services, the holder
  (with session) and the way out (switch them back with `overrides={"<service>": {}}`, or take the lease). Services
  that start while the run waits are stopped when it starts. While the run goes on no service starts from the tested
  repository (a start is refused naming the job and `job_status(id, waitSeconds)`). Services of other lane stacks that
  run from it are not stopped - the note names them; stop them first. Stopped services stay in their stack across a daemon restart
  (`stopped-for-build`), and the next daemon starts them when the run ends, as for a build.
- **Next to the environment's build** (AB#8832): a test run of an environment does not wait for the whole build when (1)
  exactly one job of the environment runs and it is its build (`lane_build`), nothing of the environment waits ahead of the
  test, (2) that build is through with the tested repository (built or skipped) and with every repository it depends on
  (the plan's `dependsOn`; without it every repository before it in the build order), and (3) the test run builds nothing:
  the daemon asks `Invoke-OctoTestRun ... -WhatIf -Json` and every selected project must say `noBuild: true`; the run then
  starts with `-build Never` and a note ("Started while build b12 of the lane still runs ..."). A test run that would
  build waits as before - its build would compile CK models into the environment's local catalog and rewrite packages while
  the build writes there - and `queue.waitingFor` says why ("... it cannot start next to that build: needs a build of
  A.Tests: <buildReason>; pass verifyTests=true to lane_build to have test projects compiled"). The conditions
  are looked at again every 5 seconds, a "needs a build" answer is asked for again after a minute. Such a test run shares
  the machine with the build: a docker test competes with it for CPU and the Docker VM, so timings (and timeouts) differ
  from a run alone.
- **Docker**: projects that start containers (Testcontainers) run one at a time on the machine - the cmdlet takes the
  machine-wide test lock. While a run waits for it, `job_status` shows `progress.phase: lock` and
  `tests.lockWait` ("waiting for the docker test lock held by Invoke-OctoTestRun of ab8797 octo-b (pid 4711, since
  10:48)"); the idle timeout is suspended meanwhile. The holder is read from the lock file on every status call (AB#9841):
  when the holder changes while the run waits, `lockWait` names the current one; no lock file reads "the docker test
  lock is free; the run takes it now", a file that names the run's own lane "the run takes the docker test lock now",
  and an unreadable or empty file falls back to the holder the cmdlet named when the wait started. `test_lock` returns `Get-OctoTestLock` (locked, stale, owner).
- **Selection**: `tests.selection` says what the run runs - the projects it names (or every test project), its
  `filter`, `rerunFailed`, or every test - in .NET test projects without the slow categories, unless `includeSlow` or
  the lane's octo-tools predates AB#9829. The dashboard shows it
  as "Runs: ...", so a filtered run does not look like a whole suite; while a project runs and has no counts yet the
  dashboard says that it reports them when it ends (VSTest writes its result at the end).
- **Result**: `job_status(id)` of a test run is the build shape - its progress rows are the test projects, so they are
  `progress.projects` with `project` (and `projectIndex` / `projectCount`, `current.project`) where a build has `repos`
  with `repo` - plus `tests`:
  `total`/`passed`/`failed`/`skipped` and per project (failed ones first) state
  (`pending|running|passed|failed|error|noTests|skipped|notRun|canceled|terminated`), counts, seconds, `buildReason` (a "no DebugL build
  output of X" while `X.dll` exists below `<repo>/bin/DebugL` says that octo-tools looks only below
  `<project>/bin/DebugL`, so the run compiled the test projects again - harmless, an octo-tools follow-up), `docker`, the failed
  tests by full name with the first error message and stack frame (20 per project, `moreFailed` counts the rest;
  `project=X` lists all the cmdlet reported) and run-level `errors` (broken build, crashed test host).
  `outcome.summary` reads "25 of 70 test(s) failed in B.Tests". Test names arrive when the run ends; while it runs the
  counts of finished projects do. Each project's `dotnet-test.log` is kept in the state folder and shown on the status
  page (Builds view: tests first, then the log picker).
- **octo-tools**: the daemon's octo-tools checkout must have `Invoke-OctoTestRun` / `Get-OctoTestLock`
  (`modules/OctoTests.psm1`); without them `lane_test` / `base_test` and `test_lock` are refused with that reason (the capability probe
  is repeated every 10 minutes).

## Configuration

`devstack.yaml` (see `src/DevStack/Configuration/devstack.default.yaml` for the commented default):

```yaml
# rootPath / defaultCheckout: from octo-tools (see "Workspace"); set them only to override it. The octo-tools checkout is never read from here: --octo-tools or OCTO_TOOLS_PATH
configuration: DebugL
environment:                       # every service; placeholders ${checkout}, ${repoPath}, ${configuration}, ${env:NAME}, ...
  OCTO_SYSTEM__SYSTEMDATABASENAME: OctoSystem
envProviders:                      # pwsh snippets with the octo-tools profile loaded, returning a hashtable
  s3Store:
    whenServices: [botServices]
    script: |
      ...
services:
  meshAdapter:
    repo: octo-mesh-adapter        # <checkout>/<repo>, or the worktree of an override
    workingDirectory: bin/${configuration}/${tfm}   # the default
    command: dotnet                # the default
    variables: { tenantId: meshtest }
    args: [Meshmakers.Octo.MeshAdapter.dll, "--Adapter:TenantId=${tenantId}"]
    ports: [5020, 5021]            # conflict check before the start; first one = health probe
    healthUrl: null                # or a URL; an answer below HTTP 500 counts as healthy
    announceEnv: {}                # env for ALL services of a start that includes this one
    startAfter: []                 # services that must be healthy first (see "Start order")
    enabled: true                  # part of a start without a service list
    optional: false                # skip instead of fail when not built
    logName: MeshAdapter
profiles:                          # saved stack starts, see "Profiles"
  core-data:
    services: [identityServices, assetRepoServices]
```

### Start order

A start (`stack_start`, `service_start` or `service_restart` of several services, the restart after a build) orders its
services by `startAfter`: a service starts only after every service in its `startAfter` that runs or is started in the
same call answers its health probe. The wait uses the call's `timeoutSeconds` (default 180; 180 s for the restart after a
build). When a dependency exits, is not healthy in time or does not start at all (e.g. an optional service that is not
built and was skipped), the service is **not started**, and neither is anything that
starts after it; the answer's `warnings` name the dependency, the exit code or the timeout and what to check
(`service_logs <dependency>`, then `service_start` the held-back service). Services without that dependency start as
usual. A `startAfter` cycle or an unknown service is refused when the configuration is read.

A start that names its services (`stack_start` with `services` or a profile's list, `service_start`) brings their
`startAfter` dependencies, transitively, that are neither named nor running in that stack: `services=["platformServices"]`
in a lane stack that runs nothing also starts `identityServices`. The answer's `added` names each one with the services
that start after it, and a note says so; in the shared stack they normally run already, so nothing is added. A dependency
the start excludes (`exclude`), one that runs in the shared stack only (in a lane stack) or one a build or test run
stopped (that job starts it again) is not added - the note says why, and the services after it start without waiting for
it. A restart (`service_restart`, the restart after a build) adds nothing.

The default starts every backend service (asset repository, adapters, bot, communication controller, platform,
reporting, MCP, AI) after `identityServices`: in a fresh slot (new system database) identity creates the system database,
and an asset repository started at the same time exits with "System tenant database does not exist, is not accessible
or the system model is missing" (AB#8951). The communication controller also starts after `assetRepoServices` (its
CK method check needs the system tenant the asset repository sets up). The `startAfter` of the built-in service of the
same name is always kept (restricted to the services the file configures), so a `devstack.yaml` written by an older
daemon gets a new dependency without an edit; an own list adds to it. `admin_config_import_defaults` keeps only the
dependencies the file configures.

Quote values with placeholders inside `[ ... ]` lists (`{` and `}` are YAML flow characters). The tools that change
the configuration rewrite the file (previous version as `devstack.yaml.bak`); comments do not survive that.

The default reproduces `Start-Octo`: the same services, ports, log files and environment. Values octo-tools owns come
from env providers instead of copies: `profileEnv` (the `OCTO_*` variables of the octo-tools session, including license
keys from your private profile), `devInstanceKey` (`Get-OctoDevInstanceSecretKey` and the SECRET key ring) and
`s3Store` (`Set-OctoLocalS3StoreEnvironment`, only when the bot starts). No tool returns environment values of
secret-looking variables.

## Profiles

A profile is a saved `stack_start`: which services, from which lane and configuration, with which tenant and
settings. "Quickly start OctoMesh for different environments" means `stack_start(owner, profile="second-adapter")`.

```yaml
profiles:
  full-main:
    checkout: branches/main
    configuration: DebugL
  second-adapter:
    description: full-main plus a second mesh adapter for another tenant on 5030/5031
    extends: full-main
    instances:
      meshAdapterB:                # an extra process of a configured service
        of: meshAdapter
        ports: [5030, 5031]
        extraArgs: ["--urls=https://0.0.0.0:5030;http://0.0.0.0:5031"]   # the last --urls wins
        variables: { tenantId: meshtest2 }
    settings:
      logLevel: Debug              # OCTO_LOGGING__LOGLEVEL__DEFAULT for every service
```

- Fields: those of `stack_start` under their devstack.yaml names (`checkout` = `baseLane`, `configuration`, `services`,
  `exclude`, `overrides`, `environment` = `envVars`) plus
  `description`, `extends`, `instances`, `envProviders` (`name: true|false`), `settings` and `requireInfra`.
- Merge order (later wins): devstack.yaml defaults, the `extends` chain, the profile, the arguments of `stack_start`.
  `services` replaces, `exclude` adds, `instances` replace per name, `environment`/`envProviders` merge per key (a null
  value removes a variable), `overrides` merge per field (`extraArgs` concatenate). Explicit `environment` wins over
  `settings`.
- `settings` are written into every service section that holds the value (the services have no shared section):
  `systemDatabase`, `mongo {host, directConnection, replicaSet}`, `broker {host, port, vhost, instancePrefix}`,
  `authorityUrl`, `streamData {enabled, schemaInstancePrefix}`, `artifactStorage` (`fileSystem` | `localS3`),
  `meshAdapter {tenantId, adapterRtId}`, `httpActivator {enabled, addressTemplate}`, `logLevel`. The key table is
  `src/DevStack/Configuration/SettingsMap.cs`. Credentials are no profile fields; secret-looking keys are never saved.
- Every config change validates all profiles (names, `extends` cycles, instances, referenced services and providers, a
  dry-run plan, duplicate ports) and leaves the file untouched when one is broken.
- `stack_status.profile` says which profile the daemon's stack runs and how it differs (`edited` when the profile changed
  since the start); a stack outside the daemon gets the profile it looks like (up to 3 differences). The environment is
  not compared.
- Before a start the daemon warns when the kind infrastructure (127.0.0.1:27017, 5672, 4301) does not answer
  (`requireInfra: true` makes it an error). The local S3 store (8333, when the `s3Store` provider applies) is optional,
  as in Start-Octo: without it the bot keeps its artifacts in the file system, and the start says so in a note
  (`Install-OctoKubernetesS3Store` adds it; a cluster created before it existed has none). Afterwards the start reports
  whether octo-cli has a context `local_<tenant>` for every mesh adapter (it never creates one).
- The default config ships `core-identity`, `core-data`, `full-main`, `backend-octogrid-studio`, `second-adapter`,
  `reporting-ai`, `lean-backend`, `simulation`, `fresh-db` and `core-data-slot` (identity, asset repository and a mesh
  adapter for `meshtest2` in the slot `second`). A profile's `slot` field starts it in that slot. An existing devstack.yaml is not changed; copy the
  `profiles:` block from `--print-default-config` into it, or save your own with `admin_profile_save`.

### Lane claim

Starting a stack writes the exclusive-resource claim of the agent operating rules for the lease holder:
`<lane>/.octo/claims/local-stack.md` (Session, Purpose, Since, Expires, Managed by); a stack slot writes its own
`local-stack-<slot>.md`. Every lease change rewrites the claim of its slot, releasing the lease removes it, and a claim
of another session that has not expired blocks a start of that slot in that lane.

## Stack slots

A slot is the port offset, prefixes and state of one OctoMesh backend stack on this machine. The default slot is the
**shared stack** (the configured ports). Every other slot is a **lane stack** - the stack of a lane (octo-tools: feature
environment), named after it, see "Lanes" - or a named slot that is no lane:
`stack_start(owner, profile="core-data-slot")` or `stack_start(owner, slot="second", services=[...])`. `stack_list` lists
them. All slots share the kind infrastructure (MongoDB, RabbitMQ, CrateDB, S3 store); what keeps them apart is derived from
the slot's index:

| | Default slot | Slot with index n (e.g. `second`, n=1) |
|---|---|---|
| Ports | as configured | every port + offset (default 100 * n): `ports`, `healthUrl`, the ports in `--urls`, announced URLs |
| System database | `OctoSystem` | `OctoSystem_s<n>` |
| RabbitMQ instance prefix (all services, adapter) | as configured | `s<n>` (the bot's Hangfire database becomes `s<n>-OctoSystemJobs`) |
| CrateDB schema prefix, artifact prefix | as configured | `s<n>`, `local-s<n>` |
| Bot upload/dump/scratch/secret backup folders, AI workspaces, edge buffer | the services' defaults | below `<state>/slots/<name>/` |
| Service URLs (authority, public URLs, service URLs) | the services' defaults | `https://localhost:<shifted port>` |
| Logs | `<lane>/logFiles/` | `<lane>/logFiles/<slot>/` |
| Lease, lane claim | `local-stack.md` | own lease, `local-stack-<slot>.md` |

- Slots are listed in `devstack.yaml` (`slots: { second: { index: 1, portOffset: 100, prefix: s1 } }`, offset and prefix
  optional) or created by the first `stack_start(slot=...)` with the next free index; the index of a created slot is kept
  in the state file. Names: lowercase letters, digits, `-`; not `default` (names may start alike: nothing matches slot names by prefix).
- **The next free index** is the lowest one that no slot of the daemon uses or retired and whose shifted ports collide with
  nothing (a configured service, a configured slot, the kind infrastructure). A colliding index is skipped (with the default
  configuration index 7 moves an app on 4300 onto 5000); only when no index fits is the new slot refused. One daemon runs per
  machine, so it alone hands out slot indices.
- The derivation is data: `slotDerivations` in the built-in default (`--print-default-config`). A row has `id`, `keys`
  (environment keys, `@instancePrefix`/`@authority` for the shared key lists of `SettingsMap`), `value` with placeholders
  (`{slot.prefix}`, `{port.identityServices.https}`, `{shift:4200}`, `{slotDir}`, ...), optional `services` (write into
  those services and their instances only), `when` (`slot.index > 1`) and `isolate`. Rows in your `devstack.yaml` replace
  built-in rows of the same id (`disabled: true` removes one); a new devstack.yaml does not copy the table, so new rows
  reach you. Explicit values always win: settings, profile/`stack_start` env and service env beat a derived value, and a
  derived value beats env provider output (e.g. the S3 store's artifact prefix).
- Work-around rows: `communicationMethodValidation` sets `OCTO_METHODS__VALIDATEREGISTRATIONS=false` for the communication
  controller in every non-default slot. A new slot's system database has no CK model System.Communication (nothing installs
  it there, a platform bug), and the controller's CK method validation at its start (`Methods:ValidateRegistrations`,
  octo-common-services) refuses the start without it. The shared stack keeps the validation.
- Rules, checked at the start: no port of the slot is used by another slot (alive or starting) or lands on a kind port;
  every `isolate` value (system database, prefixes, folders) differs from every other running slot's and from the default
  slot's configured value; an adapter tenant is served by one slot only (the tenant's database is shared); frontends
  (`exclusive: true`: refineryStudio, frontendLibraries) and the HTTP activator stay in the default slot. A slot start
  without a service list leaves out what these rules would refuse - the frontends and every adapter whose tenant a
  service of another running slot serves - and says so in `leftOut` (service, reason, how to include it: name the
  services and give the adapter another tenant through `overrides.<service>.variables.tenantId`); a start that names
  its services is refused with the rule.
- Builds: a build that stops services needs the lease of every slot they run in; `range` and `all` also the default
  slot's, `all` every slot of the lane (and their claims). A refusal names the slot and its holder.
- After a slot starts, `<state>/slots/<name>/` holds the slot's identity overlay (`identity-overlay.yaml`, the redirect URIs
  of `octo-tools/overlays/identity-local-dev.yaml` on the shifted ports) and an octo-tools installation entry
  (`octo-tools-installation.json`, `local-<slot>` with the shifted URLs); the setup below registers and applies them.
  `slotOptions.smokeCheck` (on) compares the issuer of `/.well-known/openid-configuration` with the slot's authority URL
  and warns on a mismatch.
- Use a **separate browser profile** for a slot's identity: cookies are not port-scoped, so two identity servers on
  localhost overwrite each other's login cookies in one profile.
- External processes (a `Start-Octo`, a terminal) get a `slotHint` from their port offset; profiles are compared on the
  shifted ports of their slot.

### Setup of a lane stack

A new lane stack starts with an empty system database. The daemon sets it up by itself: once a start of a non-default
slot brought its identity service up healthy (the start waits for health), it runs these steps, each idempotent, and
reports every step's outcome in the start result (`setup`, a one-line note, a warning per failed step). `stack_list` and
`stack_status(lane)` show the last setup (`<state>/slots/<name>/stack-setup.json`).

| Step | What it does | Later starts |
|---|---|---|
| `admin` | The first admin of the fresh system database (`POST /<systemTenant>/api/setup/create-admin` on the slot's identity port). Email and password come from the shared admin file (below) when it is there and usable; otherwise the password is generated (24 characters) and the admin is `admin@<slot>.local`. Either way they are written to an owner-only (600) file - `<lane>/.octo/admin-credentials.json`, for a named slot its state folder - and are never part of an answer. | unchanged: the database has users (the API answers 404) or the credentials file exists (never overwritten) |
| `octoCli` | Merges the installation entry `local-<slot>` into the octo-tools config (`~/.config/octo-tools/installations.json` or `OCTO_TOOLS_CONFIG`; a backup copy first, an entry of the same name is replaced) and registers the contexts `local-<slot>_<tenant>` with `Register-OctoCliContext -NoSwitch -NoLogin`. The active context never changes. | the same, idempotent |
| `login` | Logs the contexts in without a browser (AB#8834). The first time it creates the client-credentials client `devstack-<slot>` in the slot's system tenant (role TenantManagement, mirrored into child tenants): an `octo-cli -c LogIn` device login of the system context is approved with the admin's session (`POST /<tenant>/api/auth/login`, `POST /connect/deviceverification`; the password is read from the credentials file inside the script), then `AddClientCredentialsClient -apic`, `AddClientToRole -r TenantManagement`, `ProvisionClientInExistingTenants`. The secret is generated by the daemon and written to `<lane>/.octo/octo-cli-client.secret` (600) before the client exists; no tool returns it. The device login is dropped again right after (the context is registered anew), and every context is logged in with `LogInClientCredentials --context <ctx>`. | only the login: the token lasts about an hour and has no refresh token |
| `overlay` | Applies the identity overlay through the context `local-<slot>_octosystem` (`Invoke-IdentityOverlay`); overlays of app clients in another tenant (`identity-overlay.<tenant>.yaml`) go through that tenant's context when it exists and the setup logged that tenant in. A failure names its cause: the exit code, the number of failed clients, or a missing result. | the same, idempotent |

- **One admin password for every lane stack** (AB#9865): put a file `<base lane>/.octo/admin-credentials.json` (the base
  lane is `defaultCheckout`, usually `<rootPath>/branches/main`; the shared stack keeps its own admin in that same file)
  and every lane stack set up for the first time afterwards gets that admin. Format: the lane file's, so a copy of a
  lane's `.octo/admin-credentials.json` works - `{"email": "<you>@<domain>", "password": "<password>"}`; `email` is
  optional (without it the admin is `admin@<slot>.local`), other fields (`tenant`, `url`, `slot`, `createdAt`) are
  ignored. The lane file is still written, with the values used, and the login step reads it as before.
  - Used only when the file is **owner-only**: on macOS/Linux no group or other mode bits (`chmod 600`), on Windows the
    file's owner is the current user. A file that is not owner-only, a symbolic link, unreadable, larger than 64 KB, not
    a JSON object or without a non-empty string `password` is not used: the setup warns (the warning names the file and
    the problem, never a value from it) and the admin gets a generated password, as without the file.
  - A password that breaks an identity password rule - at least 8 characters, an uppercase and a lowercase letter
    (A-Z, a-z), a digit (0-9) and a symbol of ``!@$?_-#%&'()*+,./:;<=>[]^`{|}~`` (a space, `"`, `\` or a non-ASCII
    character is no symbol; 24 characters are not needed) - **fails** the `admin` step with the rule named;
    there is no fallback. Correct the file (or remove it) and repeat the step:
    `stack_setup(owner, lane="<lane>", steps=["admin"])`. An error of the identity's create-admin call is passed on with
    the password cut out.
  - Only lane stacks read it, on their first setup: a lane whose `.octo/admin-credentials.json` exists keeps its admin
    (existing lanes are not changed), and a named slot without a lane and the shared stack never use it.
- `stack_setup(owner, lane | slot, steps?, tenants?, renew?, session?)` runs the steps again - all by default, or some
  (`steps=["login"]` when the token expired; the answer's `shell` holds lines that let octo-cli re-acquire it by itself,
  reading the secret from the file). `tenants` adds contexts for further tenants (in a child tenant the client has roles
  only where it created the tenant itself: `octo-cli -c Create -tid <t> --scratch --context local-<slot>_octosystem`).
  `renew=true` deletes and recreates the client (a new system database, a lost secret). It needs the stack's lease (a
  lane's stack holds its own) and the slot's identity service running; the shared stack is refused (its installation is
  `local`, set up by octo-tools).
- A failed step's summary is the message of the first PowerShell error record of the step (e.g. "Register-OctoCliContext:
  The term 'octo-cli' is not recognized ..."), not the last, wrapped line of the output. That one means the daemon's own
  PATH lacks octo-cli - a daemon keeps the PATH of the shell it was started from; `setup_check` reports it with the fix.
- A failed step is a warning that names the call that repeats it (`stack_setup(owner, lane="ab1", steps=["login"])`);
  a step that needs it (`login` after `octoCli`, `overlay` after `login`) is `skipped`. A start that does not wait for
  health, or `slotOptions.autoSetup: false`, only names `stack_setup` in its notes.
- The login needs the credentials file: for a slot whose admin was created by hand (or one with a second factor) create
  the client once yourself (`octo-cli -c AddClientCredentialsClient -id devstack-<slot> --secret-stdin -apic`, then
  `AddClientToRole -id devstack-<slot> -r TenantManagement`), put its secret into the secret file (mode 600) and run
  `stack_setup(steps=["login"])`. A context that cannot log in with an existing secret file usually means a new system
  database: `renew=true`.
- `stack_verify(lane | slot)` compares the slot's derived data names with the infrastructure (system database, tenants
  and their ownership markers, RabbitMQ queues and their consumers, CrateDB schemas). A consumer on this machine whose
  pid is neither a service of the slot nor a process below one is a warning (on Windows the daemon records the `cmd.exe`
  wrapper of a service and RabbitMQ reports its dotnet child). Every consumer names the slot's `service` its process
  belongs to; on Windows that `processId` is the one `stack_status` shows as `processId`, not its `pid`.
- `admin_slot_retired`, `admin_slot_drop_data(owner, index)` and `admin_slot_forget(owner, index, confirmDataDropped=true)` show,
  drop and free the indices of removed lanes whose data remained (see "Removing a lane").

Limitations: no Refinery Studio, frontend libraries, HTTP activator or operator-deployed workloads in other slots (the
operator and its values know the default issuer only). The tenants of a slot live in the shared MongoDB under their own
names: **never `RestoreTenant` a dump into a tenant another slot uses, and never restore into another slot's system
database** - restore only into the slot that owns it. The setup creates no tenant: create the tenants a lane stack needs
(`octo-cli -c Create -tid <t> --scratch --context local-<slot>_octosystem`) before you use them.

## Lanes

A lane (octo-tools: feature environment) is the folder `<rootPath>/wt-<lane>` of one work item that octo-tools creates and owns (`New-OctoEnvironment`,
`Add-OctoEnvironmentRepo`, `Sync-OctoEnvironment`, `Invoke-BuildEnvironment`, `Remove-OctoEnvironment`): feature worktrees of
the repos the feature changes, detached consumer worktrees of the repos that must be rebuilt against them, its own
`Octo.User.props` (own package cache `.nuget-packages`; a `wt-*` folder without the manifest is a plain lane or flat worktree,
not an environment), its own feed `nuget/` (a snapshot of the base lane's packages plus what
it built), its own CK and blueprint catalogs, and the manifest `.octo/environment.json` (schemaVersion 1: name, workItem, base,
created, owner, repos with role/path/branch/baseCommit, slot). A repo's `path` may lie outside the folder when a worktree
was adopted in place (`<repo>/.claude/worktrees/<name>`, a flat `wt-<lane>-<repo>`); the daemon always uses the manifest's path. The daemon reads the manifests and has no file logic of its own.

```text
lane_create(owner, session, lane="ab8625-enum-null", repos=["octo-sdk"], workItem="AB#8625", branch="<user>/AB#8625_enum-null")
lane_build(owner, session, lane="ab8625-enum-null")                       -> job_status(id, waitSeconds=50)
stack_start(owner, session, lane="ab8625-enum-null", profile="core-data")
service_logs(service="assetRepoServices", lane="ab8625-enum-null", grep="error")
lane_remove(owner, session, lane="ab8625-enum-null")
```

- **Runtime**: an environment runs in its own stack slot, named after it (the manifest's `slot`), created on the first start
  with the next free index - shifted ports, own system database and prefixes as every slot. `${checkout}` is the environment
  folder, so catalogs and logs come from it; the logs go to `<rootPath>/wt-<lane>/logFiles` (no slot subfolder). A service whose repo the
  environment holds runs from the repo's manifest path; every other service runs from the base lane (`<base>/<repo>`, normally
  `branches/main`). An explicit `overrides.<service>.source` still wins. A repo added to a running lane stack
  (`lane_add_repo`) runs from the lane on its service's next `service_start`.
- **Claims**: the lane claim of an environment's slot (`local-stack-<slot>.md`) lives in the base lane's `.octo/claims`, never
  in the environment folder.
- **Builds that stop services**: a service a build stopped stays part of the stack (`stopped-for-build` in `stack_status`);
  `service_restart` or `service_start` starts it again with its previous source. The state file keeps them, so after a
  daemon restart during the build they are still listed and can be started. The build starts them again itself only when
  it succeeds with `restartServices=true` (default false) or is canceled; after a failed build, or a successful one
  without `restartServices`, they stay stopped until `service_start` / `service_restart`. `stack_stop(lane)` of an environment that is
  not running is a no-op.
- **Lease**: the lane holds its stack's lease (`lane:<name>`), so every session of the lane shares it; the `owner`
  of each call is still required and recorded in the lease's purpose ("last change by ...") and the daemon log, the
  `session` next to the owner. A session that uses the slot without `lane` does not hold it.
- **`lane` parameter**: resolves slot, folder and lease holder. Do not pass `slot` or `baseLane` next to it (a different
  value is refused). `build_plan(lane, kind=repo)` resolves `path` (a repo name of the manifest means its manifest path)
  inside the lane; `base_build` takes no lane, and `packages=private` is refused for a lane.
- **Builds**: `lane_build(owner, lane)` calls `Invoke-BuildEnvironment -env <lane> [-syncMain] [-verifyTests|-includeTests]
  -EventsFile <f> -Json`; packages go into `<rootPath>/wt-<lane>/nuget` and its cache only. Queue classes: a lane build runs alone; lane
  builds (`lane_build`, and test runs of a lane in their class) run in parallel, one per environment and at most two at once; jobs start in
  queue order, and a waiting lane build holds back everything queued after it. `syncMain=true` refreshes the environment's
  snapshot of the base lane's feed first and is refused while a `range` or `all` build of the base lane runs or waits (the
  snapshot would take over a half-built feed).
- **Repos in parallel** (octo-tools AB#8814): `Invoke-BuildEnvironment` builds independent repos of an environment at the
  same time, two by default; `lane_build(maxParallel=n)` (1-16; 1 = one after the other) changes that, and
  `build_plan` shows what each repo waits for (`dependsOn`) and which ones build alone (`exclusive`). While several
  build, `job_status.progress.running` lists each of them with seconds and phase (`current` is the one that started
  first, `repoIndex` counts the repos started or skipped, the ETA divides the remaining time by the number of builds at
  once); a failed parallel build names every failed repo in `outcome.failedRepos`. With two environment builds at once
  (the queue's limit) that makes up to four dotnet builds on the machine - lower `maxParallel` when it is too much.
- **Only what changed** (octo-tools AB#8814): an environment build builds the repos that changed since their last build
  and skips the others. `lane_build(repos=[..], skip=[..], buildUnchanged=true)` narrow or widen that (names
  exact or without `octo-`; an unknown name is refused): `repos` builds only those, `skip` leaves some out,
  `buildUnchanged` builds also what did not change. `build_plan` shows the prediction per repo - `action` (`build` |
  `skip`), `reason` (`sourcesChanged`, `packagesChanged`, `neverBuilt`, `upstreamBuilt`, `librariesBuilt` - an app whose
  octo-frontend-libraries were built after it -, `unchanged`, `notSelected`, `excluded`, ...) and `detail` - and warns when nothing would be built. In `job_status` a repo that was not built is
  `skipped` with its `reason` (it has no seconds and adds nothing to the phase totals; it counts as passed in
  `repoIndex`), a built one carries why it was built; the summary reads "1 repo(s) built, 2 skipped (1 unchanged, 1
  excluded)". A repo the cmdlet reports as done although nothing could be built in it (no solution, project file or
  build.ps1 in its root - octo-tools' "No solution file found", e.g. octo-frontend-libraries in `Invoke-BuildAll`) is never
  `done`: it is `skipped` with reason `nothingToBuild`, and its detail names the repo whose build.ps1 builds it ("built by
  octo-frontend-refinery-studio") where one of the job does (AB#9384); the cmdlet's stale warnings (a skipped repo whose packages are now older than what it consumes) are notes
  starting with `stale:`; `lane_build` warnings name stale base-lane packages as `lane_create` does (`feedSnapshot`; package
  ids follow MSBuild: `PackageId`, else `AssemblyName`, else the project name). The status page shows skipped repos as "skipped: unchanged since its last build". A repo that
  is definitely not built (`notSelected`, `excluded`) is no conflict with services running out of it. With an octo-tools
  checkout that lacks these parameters, `repos` / `skip` / `buildUnchanged` are refused with that reason and a plain
  environment build works as before.
- **Conflicts**: services of an environment slot that run the base lane's binaries count for builds of the base lane like
  any other slot's: a `range` of `branches/main` needs the environment's lease to stop them.
- **Removal**: `lane_remove` leaves nothing behind, see "Removing a lane" below.
- **lane_create** calls `New-OctoEnvironment -env <lane> -repos <names> [-workItem] [-branchName <git branch>] [-addAffected]
  -owner <owner> -Json` (`-branchName`: in octo-tools `-branch` means the lane).
- **octo-tools capabilities**: the cmdlets are probed like the build parameters; without them `lane_build`, `lane_create` and
  `lane_remove` are refused with "octo-tools too old" (`build_plan.missingCapabilities` names them). `lane_list`, discovery
  and the runtime need no cmdlet.
- **Profiles**: a profile whose base lane (`checkout`) is the lane's base lane, started in the lane, shows no `baseLane`
  difference; its services are compared through the environment's chain (manifest repos, the rest from the base).
- **Slot**: `lane_create` checks the slot before `New-OctoEnvironment` runs (no free index refuses the call, nothing is created)
  and reserves it after; when the reservation still fails (no index fits any more), it takes the fresh lane
  away again (`Remove-OctoEnvironment`, its `.octo` folder, its feature branches) and answers with a failure that names why;
  when that roll-back fails too, the notes name the lane folder and branches that are left to remove by hand.
  `lane_create` and `lane_add_repo` run to their end when the caller's MCP call times out (AB#9808): the caller only
  loses the answer, `lane_list` shows the lane, its repos and its reserved slot. While one of them runs, a second
  `lane_create` / `lane_add_repo` of that lane and a new `lane_build` / `lane_test` of it are refused with who runs what since when.
  A `stack_start` that fails gives back the lease it took for the call when nothing of it runs (a lease held before stays).
  `lane_create` reserves the environment's slot (index, port offset, prefix in the answer); `lane_list` shows the reserved slot or,
  for an environment created outside the daemon, the slot the next start would get. A fresh lane stack sets itself up
  after its first healthy start (see "Setup of a lane stack"; `stack_setup` repeats it), `stack_verify` checks its data.
- **Catalogs, step parts and the package cache** (AB#8831, octo-tools side): a build run reads the remote CK catalogs at most
  once. `job_status` has `catalogs` after the build - one line such as "refreshed: the remote CK catalogs were read once
  for this run (120 s, triggered by octo-a)" (`fresh`, `refreshed`, `unavailable`, `failed`, `perCompile`, `notNeeded`) - and
  per repo the parts of the steps: `catalogSeconds` (on the repo that triggered the read), `restoreSeconds`, `compileSeconds`
  (parts of `buildSeconds`) and `testRestoreSeconds` (part of `testSeconds`); the Builds view shows them below the step
  times. While the catalogs are read the repo's phase and `progress.phase` are `catalogs`. `refreshCatalogs=true` on
  `base_build` / `build_plan` passes `-refreshCatalogs` (every CK compile reads them again). `lane_create` fills the new
  environment's package cache from a local cache; the first note says how ("Package cache: 2065 package version(s), 18.9 GiB
  cloned from ~/.nuget/packages in 26.7 s (37 local builds left out)."), `skipPackageCacheSeed=true` leaves it empty.
  `admin_lane_seed_cache(owner, lane, dryRun?)` runs `Initialize-OctoEnvironmentPackageCache` for an existing environment (one
  created before this, or to top it up); refused while the environment builds or tests. With an older octo-tools the fields
  are absent, `refreshCatalogs` / `skipPackageCacheSeed` / `admin_lane_seed_cache` are refused with the reason, and everything else
  works as before.
- **Docker check of a test run** (AB#8835, octo-tools side): before projects that start containers run, `Invoke-OctoTestRun`
  compares the Docker engine's free memory with a minimum and by default refuses; it also limits the CPUs of the
  containers the tests start. A memory limit (`dockerMemory`, e.g. `4g`) is opt-in: the cmdlet sets it after the container
  started, when mongod has already sized its cache to the whole Docker VM, so mongod is OOM-killed under it (octo-tools
  pull request 54). `lane_test` / `base_test` pass `dockerCheck` (`refuse|warn|off`), `minDockerFreeMemoryGiB`, `dockerCpus` and
  `dockerMemory` through when given (refused with an octo-tools without them). After the run `job_status` has `tests.docker`:
  `check` (`ok|warned|refused|unavailable|off`), `freeGiB` against `minFreeGiB`, `memoryGiB`, `usedGiB`, the three biggest
  containers, the limits and how many containers got them. A refused run fails with `failedStep: docker` and the summary
  "not started: Docker has 1.2 GiB free, needs 3; biggest containers: kind-control-plane (6.1 GiB), ...". The cmdlet's check
  is the measurement at the start of the Docker projects and is what counts once the run ended; the daemon's own
  `dockerWarning` below is only a look at the VM size, shown at `lane_test` / `base_test` and while the run goes on.
- **Docker VM size** (AB#8835): `daemon_status` (and `GET /api/daemon`, the status page's Daemon tab) has `docker`: `memoryGb` and
  `cpus` of what `docker info` reports (the VM of Docker Desktop or colima), `kind` (a `kindest/node` container runs) and a
  `warning` when kind runs and the VM is below `dockerVm.minMemoryGb` / `dockerVm.minCpus` of the configuration (default
  12 GiB / 6 CPUs). `lane_test` / `base_test` add that warning as a note, `job_status` as `tests.dockerWarning` while a project that starts
  containers is part of the run. A warning only - nothing is refused; container limits are the test cmdlet's business. Read
  with `docker info` and `docker ps`, kept for a minute.
- **Tenant management in a lane stack without a browser** (AB#8834): the `login` step of the setup (see "Setup of a lane
  stack"); `stack_setup(owner, lane, steps=["login"])` logs the contexts in again when the token expired.
- **Tenant databases**: every slot gets its own tenant-database prefix `<slot prefix>_` (derivation row `tenantDatabasePrefix`,
  `OCTO_SYSTEM__TENANTDATABASEPREFIX`, AB#8797), so a tenant created without a database name (`octo-cli -c Create -tid <id>`) gets
  `s<n>_<id>` and two slots can create the same tenant id. An explicit name without the prefix is refused; tenants created before
  keep their names. Services built before engine-mongodb AB#8797 ignore the value, then tenant databases are shared by name with
  every slot as before and need names of their own. The platform refuses an existing database on create and a database owned by
  another system database on attach (AB#4945); databases created before the marker existed have none, and `stack_verify` warns
  about them and about a tenant database two slots register.
- **Status page**: a board row per environment (work item, slot health, lease, build), its sheet lists sources, feature and consumer repos, builds and problems.
- A lane's service in the shared stack (UC-A): `service_restart` with `overrides.<service>.source = "lane:<name>"` runs the
  lane's worktree of the service's repo in the shared stack (with the shared stack's lease; a lane that does not hold the
  repo is refused with the lanes that do) - required for features that need
  Refinery Studio, the frontend libraries, the HTTP activator or operator workloads.

### Removing a lane

`lane_remove(owner, lane, keepData?, keepBranches?, session?)` removes a lane after its work is merged and leaves nothing behind: no folder, no
process, no data of its lane stack, no retired slot index. While it runs, the lane is marked as being removed
(`lane_list` shows `removing` with owner, session and start time): every changing call on the lane from any session - a
stack start, stop or restart (also with `slot=<the lane's slot>` instead of `lane`), `stack_setup`, `lane_build`,
`lane_test`, `lane_sync`, `admin_lane_seed_cache`, the other changing `lane_*` calls, a job that names the lane only by
its folder (`checkout=wt-<lane>`), a `service_restart` with `source: "lane:<name>"`, and a job of the lane that was queued
before - is refused with who removes it. The check runs again under each stack's start gate, so it also holds for a start
that passed it before the mark was set, for a `service_restart` without overrides that keeps a lane source, for a source
given as a folder of the lane, and for the restart after a job (that service stays stopped, the job's notes say why);
`lane_remove` waits for every stack's gate once after setting the mark, so such a start has either finished - its services
are stopped with the lane stack or found by the process check - or starts nothing. Every session of a lane acts as the lane (`lane:<name>`), so the lease alone cannot tell them apart. The mark ends
when the call ends, also after a failure (the lane is usable again then); it lives in the daemon's memory, so a daemon
restart clears it. A failure after `Remove-OctoEnvironment` succeeded (the lane is gone) is reported in the answer's notes
and `leftovers`, not as an error. In this order:

1. **Refusals that change nothing**: a build or test run of the lane runs or waits; another session holds the lane stack's
   lease; a process holds files below the lane folder that is not one of the lane stack's own services. The daemon asks
   octo-tools (`Get-OctoProcessesUnderFolder` of `Invoke-KillDotnet.psm1`, list-only: working directory on macOS/Linux,
   entry assembly, on Windows the modules of dotnet processes) for the lane folder and for every in-place worktree of the
   manifest, and sorts the answer by the daemon's own services (each recorded pid and every process below it). Refused,
   with pid, name and start time of each (never a command line) and what to do:
   - a process the daemon did not start: an MSBuild node a plain `dotnet build` in the lane left running (a dotnet process
     with a module below the lane's `.nuget-packages`; `dotnet build-server shutdown` ends it), a shell, an IDE, a session
     working in the folder. Reason: on 2026-11-20 `Remove-OctoEnvironment` failed halfway with "Access denied" on the
     lane's package cache, held by a reused MSBuild node. On macOS (lsof) and Linux working directories count too: a
     shell or a Claude Code session whose working directory lies inside the lane folder - the calling session's own
     included - makes `lane_remove` refuse; leave the folder (`cd` out of it) and call it again;
   - a service of another stack that runs from the lane (a lane's build of one service in the shared stack): it is never
     stopped by `lane_remove` - stop it with that stack's lease and start it again from the base lane.

   Processes below an in-place worktree only are reported in a note and never refuse: the worktree stays
   (`Remove-OctoEnvironment` only unregisters it). Without the cmdlet (older octo-tools) or when the check fails, a note
   says the processes were not checked and the removal goes on.
2. **Stop**: the lane stack is stopped (its services and the processes below them); when it ran, the processes are
   checked again - anything still there refuses with "the lane stack is stopped now, nothing else was changed". Then the
   lease is released.
3. **Remove**: `Remove-OctoEnvironment -env <lane> -Json` removes the worktrees and what the lane owns. It refuses dirty
   or unpushed worktrees; there is no force. Its `data.leftOver` (what was still in the lane folder) is cut down to what
   still exists after the daemon's own clean-up below (the secret files kept `.octo`, the `files` step removes them).
   It keeps the feature branches as local refs in the repositories the worktrees belonged to (the base lane's checkouts):
   the daemon deletes a branch that has no commit beyond the lane's base commit (it holds nothing; read before the
   worktrees go, deleted once no other ref is needed - it is on origin or another branch - and only while it still points
   at the commit that was checked: `git update-ref -d` with that commit) and keeps one with commits. `branches` lists each
   with `deleted`, the `reason` and, for a kept one, the `delete` command for after the merge (`git branch -D`, its values in
   single quotes; none for a value with a quote). Never deleted: the base branch, a branch checked out in any worktree, a
   branch whose commit no other ref holds, a branch whose worktree's repository git could not name.
   `keepBranches=true` keeps them all.
4. **Drop the data** (`dataDrop` in the answer, one step per store with what it dropped, at most 20 names and the count):
   the slot is removed and its index retired first (no new stack takes it meanwhile), then
   - `mongodb`: the system database (`octosystem_s<n>`, as the services lowercase it), the tenant databases it owns -
     registered in it or named with the slot's prefix `s<n>_` -, the bot's Hangfire database `s<n>-OctoSystemJobs`; the
     system database last, and only when no drop of a tenant database it registers failed (else it stays, so the next
     attempt still finds them; a tenant database kept because another stack may use it does not hold it back). A tenant database another stack's system database registers, or whose ownership marker
     (AB#4945) names another system database, or one without a marker and without the prefix (a tenant created before
     AB#8797 may be another stack's too; a prefix that does not end in a separator matches no unmarked database) is kept
     and listed without a drop command. The system databases of the shared stack and of every other slot are never dropped;
   - `rabbitmq`: queues and exchanges named `s<n>-...` (management API);
   - `cratedb`: the tables and views of the schemas `s<n>_<tenant>` (views first);
   - `octoCli`: the installation entry `local-<lane>` in the octo-tools `installations.json` (a backup copy first, as the
     setup's octoCli step does) and the contexts `local-<lane>_<tenant>` (`octo-cli -c RemoveContext`);
   - `files`: the stack's state folder `<state>/slots/<name>` and the lane's secret files (`admin-credentials.json`,
     `octo-cli-client.secret`); `Remove-OctoEnvironment` leaves the folder while they are in it, so its empty folders go too.
     Links are never followed: a linked state folder loses only the link; a lane folder or `.octo` that is a link fails the
     step, and nothing below it is touched;
   - `s3`: `unchecked` - the daemon does not look into the local S3 store (its credential lives only in the kind cluster,
     kubectl), so it cannot tell whether artifacts below the prefix `local-s<n>/` exist; the step and `leftovers` say so with
     the `aws` command, and it blocks nothing.

   When every step succeeded (`kept` and `unchecked` are no failure: databases another stack may use, S3) the index is free again; a
   new lane may get it. A failed step keeps the index retired, `leftovers` lists what remains with the commands, and the
   tenant databases that remain are kept with the index: `admin_slot_drop_data(owner, index)` tries again. A
   configuration that cannot derive the slot's names fails the MongoDB, RabbitMQ and CrateDB steps (nothing could be
   checked), so the index stays retired. `admin_slot_forget` waits for a running drop of the daemon.

`keepData=true` keeps the data: the index is retired, `leftovers` (and `admin_slot_retired`) list the data with the
commands to drop it by hand (the lane's secret files `.octo/admin-credentials.json` and `.octo/octo-cli-client.secret`
go all the same, and with them the empty lane folder; one that cannot be deleted is listed in `leftovers`), and `admin_slot_drop_data(owner, index, session?)` drops it later - also for lanes removed
before the daemon dropped data itself. It is refused while a stack uses the index or anything listens on its shifted
ports. When a lane or stack of the same name exists again, the names that follow the name (state folder, octo-cli
installation and contexts, lane folder) are its own and stay; only the index's names are dropped.
`admin_slot_forget(owner, index, confirmDataDropped=true)` frees an index without dropping anything, once the developer
confirmed the data is gone.

The stores are reached as `stack_verify` reaches them: MongoDB `localhost:27017` with the admin user and password of the
configuration (`OCTO_SYSTEM__ADMINUSER` / `OCTO_SYSTEM__ADMINUSERPASSWORD`), the RabbitMQ management API on
`localhost:15672` (the local default user `guest`, octo-tools `infrastructure/rabbitmq/definitions.json`) and CrateDB on
the kind host port `localhost:4301` (`LocalInfra`); the configuration names no other host.

## Apps of consumer repositories

The frontends of consumer repositories (`energy-community`, `voest-app`) are services like the platform's own, defined in
the daemon's configuration only - nothing is added to the app repositories:

- **Default slot**: the app's own dev server. `energyCommunityApp` / `voestApp` run `pwsh -File octo-start.ps1` in the
  repository (npm ci when needed, dev certificate, `npm start`) on the app's port (44486 / 4300), with the port, the
  health URL and the log (`<checkout>/logFiles/<logName>.log`) like every service. The profiles `energy-community` and
  `voest-app` start the app with the backend services it needs. Tenants, CK models, blueprints and data are not
  provisioned by the daemon.
- **Another slot (a feature environment)**: the app's **build output** on the shifted port. The apps read their backend
  URLs from a tracked runtime config the browser fetches (`/assets/config.json`), and the dev server serves that asset
  before its proxy - so `ng serve` cannot be pointed at another identity server without editing a tracked file
  (verified: a generated proxy entry for `/assets/config.json` is ignored). Instead the service's `slot:` variant starts
  `dotnet ${daemon} --serve-app`: the daemon binary as a static host of `<repo>/.../dist` (what
  `lane_build` built) with HTTPS (ASP.NET dev certificate), index.html for the app's routes, the path proxies
  of the app's dev server, and an overlay folder laid over the build. `files:` generates that overlay into
  `<state>/slots/<slot>/services/<service>/` - the app's own config.json with the slot's backend URLs set - on every
  start. No live reload there: a code change needs a rebuild (`lane_build`) and a `service_restart`.
- **Identity**: `identityClients:` puts the app's redirect, post-logout and CORS URIs on the shifted port into the
  slot's identity overlay; a client that lives in another tenant than the system tenant (`tenant:`) gets its own file
  `identity-overlay.<tenant>.yaml`, applied by the overlay step of the setup (`stack_setup`) through `local-<slot>_<tenant>` once that context
  exists and the setup logged that tenant in (`stack_setup(tenants=["<tenant>"])` registers and logs it in; the start result names the command too).
  A setup that did not log the tenant in (the first setup of a fresh lane has only the system tenant) skips that file with a
  note: a context left from an earlier stack of the same name does not count. The client itself must exist in the slot's identity server.
  The overlay holds only the clients of the services the slot runs (a profile instance counts as its base service; a configured app the stack does not run is left out;
  a slot that runs nothing keeps them all); an app started later gets its client with `stack_setup(steps=["overlay"])`.
  A failed overlay names the failed clients and their octo-cli exit code (`Invoke-IdentityOverlay` without `-Json` prints octo-cli's message).
- **Environment builds**: an app's `build.ps1` builds `../octo-frontend-libraries` and installs its `dist`, so
  `requiresRepos: [octo-frontend-libraries]` makes `build_plan` / `lane_build` refuse an environment that
  holds the app without it (add it as a consumer with `lane_add_repo`, or `skip` the app).
- **Adapters of an app**: an app that needs its own adapter gets it as a service (or a profile instance of one) that its
  profile switches on - `edaAdapter` (octo-adapter-eda, 5022/5023, variables `tenantId` and `adapterId`, disabled by
  default) with the profile `voest-app-eda`; for another tenant pass
  `overrides.edaAdapter.variables = { tenantId, adapterId }`. In a slot the app's config points at the slot's adapter
  port. **An EDA adapter uses the market communication credentials stored in the tenant's adapter configuration: started
  on a copy of a tenant with real credentials it talks to the live market communication** (see
  `energy-community/docs/runbooks`). octo-devstack does not check or prevent that.
- **Another app** is another service block (repo, start command, port, `slot`, `files`, `identityClients`,
  `requiresRepos`) and, if wanted, a profile. An existing devstack.yaml does not get new built-in definitions by itself:
  `admin_config_import_defaults(services=["voestApp"], profiles=["voest-app"])` copies them (without names it lists what the
  file lacks).

`--serve-app --root <dir> --url <loopback url> [--overlay <dir>] [--proxy "<path regex>=<target>[|<from>=><to>]"]...` is
read-only (GET/HEAD; proxies forward as they are) and binds to loopback only.

## Differences to Start-Octo

- One service crashing does not stop the others; `stack_status` reports it with exit code and log tail.
- Services that need identity start only after identity is healthy (`startAfter`, see "Start order"); Start-Octo
  starts them all at once.
- Health without a `healthUrl`: the first port must accept connections; when the service's `--urls` serves that port as
  https, the probe completes a TLS handshake (certificate not checked) instead of a bare connect, so Kestrel does not log
  "Failed to authenticate HTTPS connection" on every probe.
- The previous log of a service is kept as `<logName>.prev.log` instead of being deleted.
- Services keep running when the daemon restarts; the next daemon adopts them from its state file.
- Processes are started through `/bin/sh -c 'exec ...'`, so their output goes straight to the log file and the PID
  is the service's own (Windows: through `cmd.exe`, see "Windows").
- A service is stopped gracefully (SIGTERM; CTRL_BREAK on Windows), then killed after `stopTimeoutSeconds`.

## Windows

The daemon runs on Windows 11 with .NET 10 and PowerShell 7; the process handling has its own Windows code paths.

- **Launch and logs**: a service runs as `cmd.exe /d /v:off /s /c "<command line> <NUL >>"<log>" 2>&1"`, so its output
  goes straight into the log file (also when the daemon is gone), after the `# octo-devstack ...` header line the daemon
  writes first. Arguments are quoted by the CommandLineToArgvW rules and every cmd metacharacter is caret-escaped, so
  they reach the service verbatim; a log path must not contain `%` or `"`. The PID the daemon tracks is cmd.exe's (the
  service is its child), and cmd.exe exits with the service's exit code. `npm`, `ng` and other `.cmd` shims resolve
  through cmd.exe.
- **Stop**: every service gets its own hidden console and process group. A stop sends `CTRL_BREAK_EVENT` to that group,
  waits `stopTimeoutSeconds`, then kills the tree. .NET Generic Host services (all OctoMesh services) shut down
  gracefully on it ("Application is shutting down"). node ends on it like on Ctrl+C (exit code 0xC000013A), also
  below the wrappers the frontends use: `node`, `pwsh -File <script>` running node and `pwsh -File` running
  `npm run start` stopped in under 0.5 s without a kill (measured with a node HTTP server; `ng serve` itself not).
  pwsh enters its debugger on CTRL_BREAK ("Entering debug mode" in the service log) and goes on, because its stdin is
  NUL: a pwsh script that waits for a child ends when the child ends, but pwsh doing work of its own (`Start-Sleep`, a
  loop) keeps running and is killed after the timeout. A wrapper script that starts children must let them share its
  console (no `CreateNoWindow`), else the signal does not reach them: octo-frontend-libraries' `octo-start.ps1` does since
  AB#9377 (its stop took the full timeout and a kill before). The event is sent by a short-lived second instance of the daemon
  (`octo-devstack --send-ctrl-break <pid> <daemonPid>`): a process can be attached to one console only, so the daemon
  does not attach to the service's console itself. When the helper cannot deliver the event (it refuses when the daemon
  shares that console; services started by a daemon before this version have no console group), the tree is killed at
  once, without waiting for the timeout.
- **Process information** comes from a Toolhelp snapshot (pids, parents, exe names; reused for 0.5 s within a request),
  GetProcessTimes (start times) and NtQueryInformationProcess (command lines, read only for the processes a caller needs).
  WMI is not used: one `Win32_Process` query took about 2.4 s. Command lines of other users' or elevated processes are
  not readable.
- **Adoption** after a daemon restart reads the command line of the recorded PID and compares the process start time with
  the one recorded at launch (all OSes, 2 s tolerance), so a reused PID is never adopted or stopped.
- **Processes the daemon did not start** (Start-Octo, a terminal, other sessions): the snapshot gives pids, parents and
  start times, command lines are read for dotnet and node processes, port listeners and their ancestors,
  `GetExtendedTcpTable` (IPv4 and IPv6) gives the listening ports. The working directory of another process is not
  readable on Windows: its repo is found from an absolute `.dll` argument, the loaded module of a relative `.dll`
  argument (when the loader mapped it), the folder of an absolute path among the arguments (node scripts) or the
  program's folder. A process without a service dll that listens on a configured port is that port's service. When
  none of these finds the repo, it is unknown and a build of the service's configured repo counts it as a conflict (as
  on macOS when lsof cannot read the cwd). The log file of such a process is only found for Start-Octo stacks (their log
  folder); stdout targets are not readable. Origins come from the parent chain (`Start-Octo` in a pwsh command line,
  `claude.exe` or node running Claude Code's `cli.js`; Git Bash, cmd and Windows PowerShell count as shells); a parent
  created after its child is a reused PID, so the child counts as an orphan. Stop hints are `taskkill /T /F /PID <pid>`
  (Stop-Process would leave the children running). pwsh is a launcher, not a shell: Claude Code's PowerShell tool runs
  a command inside its own `pwsh -Command` process, and the command text is not in that process's command line. That
  pwsh is therefore the launcher of what the call started, and its stop hint ends all of it - for a `Start-Octo` run
  there the whole stack, which is then reported as kind `session` (not `start-octo`, so no `Stop-Octo` hint).
- **Builds** see those processes again (the conflict check works); `kind=all` runs (a full build of the lane was verified)
  with an octo-tools that has `Invoke-BuildAll -skipKill` and `Invoke-KillDotnet -branchRootPath`, and is refused with an
  older one.
- **Paths**: root and default lane come from octo-tools like on every system (see "Workspace"). Paths on the status
  page and in profiles are shown relative with `/`, drive letters compared case-insensitively.
- **The daemon itself**: `Install-OctoDevStackDaemonService` registers a logon task; `Stop-OctoDevStackDaemon` stops it
  gracefully - the daemon started by `Start-OctoDevStackDaemon` has a hidden console of its own, and the helper's console
  mode (`--send-ctrl-break <pid> <guard> console`) signals that console, only when nothing else is attached to it (a
  daemon in the foreground of a terminal shares it with the shell and is killed instead). Its own stdout and stderr
  (`daemon.log`, `daemon.err.log` of `Start-OctoDevStackDaemon`) are not inherited by the services, builds and probes it
  starts (`StdHandles`): CreateProcess hands every inheritable handle to a child, so the services held the log open,
  and the next start could not keep it as `daemon.prev.log`.
- **Limits**: the working directory and stdout of foreign processes stay unknown (see above).

## Development

```bash
dotnet build Octo.DevStack.sln            # Debug; never build Release while the shared daemon runs from bin/Release
dotnet test Octo.DevStack.sln
dotnet bin/Debug/net10.0/octo-devstack.dll --dev      # the development daemon
```

**Nobody develops against the shared daemon on port 5090** - other sessions' stacks and builds depend on it. The
development daemon is a second instance with everything of its own:

| | shared daemon | development daemon (`--dev`) |
|---|---|---|
| URL | `http://127.0.0.1:5090` | `http://127.0.0.1:5190` |
| Config | `devstack.yaml` in the octo-tools config folder (`~/.config/octo-tools`) | `devstack.dev.yaml` next to it (written from the built-in default on first start) |
| State | `~/.local/state/octo-devstack` | `~/.local/state/octo-devstack-dev` |
| Binaries | `bin/Release` (built by `Start-OctoDevStackDaemon`) | `bin/Debug` |

`--url`, `--config` (or `OCTO_DEVSTACK_CONFIG`) and `--state` (or `OCTO_DEVSTACK_STATE`) still override each value, e.g.
for two development daemons at once. **A Debug build started without `--url` is a development daemon** (it says so), so
`bin/Debug` can never take port 5090 by accident. `GET /health` and `daemon_status` report `development: true`.
Point `devstack.dev.yaml` at a throw-away `rootPath` (a folder with `branches/main/Octo.User.props` and a tiny repo is
enough for builds) and harmless services (`pwsh -NoProfile -Command "Start-Sleep 600"`): with the default config it would start the real services on the
real ports and build in the real lanes. To use it from Claude Code:
`claude mcp add --transport http --scope local octo-devstack-dev http://127.0.0.1:5190/mcp`.
Restart tests (kill the development daemon while a build runs, start it again) belong there; the shared daemon follows
the rule in "Restarting the daemon".

The tests start only harmless processes in temp folders - `pwsh -NoProfile` on every OS (`Start-Sleep`, small scripts;
one script for all systems, pwsh is required anyway) - and never start an OctoMesh service, load octo-tools or touch a
real lane. The Windows logic (command-line quoting, TCP table parsing, adoption checks, process scan, stop) is
unit-tested on every OS, no test is skipped, and a test of OS-specific behaviour checks each OS's counterpart (SIGTERM /
CTRL_BREAK, the `/bin/sh` / `cmd.exe` wrapper of the launcher). CI runs them on Linux only (the pipeline installs pwsh
when the agent has none): run them on Windows (and macOS) locally before a change to process handling, paths or files
goes in.
