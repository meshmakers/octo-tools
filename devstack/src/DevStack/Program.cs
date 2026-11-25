using System.Net;
using System.Runtime.InteropServices;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;
using Meshmakers.Octo.DevStack.Ui;

// Windows: the daemon runs itself as a short-lived helper to send CTRL_BREAK to a service's console (ConsoleSignal).
if (args.Length > 0 && args[0] == ConsoleSignal.HelperSwitch)
{
    return OperatingSystem.IsWindows() ? ConsoleSignal.RunHelper(args) : 1;
}

// A service of the stack: the daemon binary as a static host of a built single-page app (see AppHost).
if (args.Length > 0 && args[0] == AppHost.Switch)
{
    return await AppHost.RunAsync(args);
}

string? givenConfig = null;
string? givenOctoTools = null;
string? urlOverride = null;
string? stateOverride = null;
var development = false;
var noBrowser = false;
for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--config" when i + 1 < args.Length:
            givenConfig = TemplateExpander.ExpandPath(args[++i]);
            break;
        case "--octo-tools" when i + 1 < args.Length:
            givenOctoTools = args[++i];
            break;
        case "--state" when i + 1 < args.Length:
            stateOverride = Path.GetFullPath(TemplateExpander.ExpandPath(args[++i]));
            break;
        case "--dev":
            development = true;
            break;
        case "--no-browser":
            noBrowser = true;
            break;
        case "--url" when i + 1 < args.Length:
            urlOverride = args[++i];
            break;
        case "--print-default-config":
            Console.Write(ConfigStore.ReadDefaultYaml());
            return 0;
        case "--help" or "-h":
            Console.WriteLine("""
                              octo-devstack - MCP daemon for the local OctoMesh dev stack

                                --config <path>          devstack.yaml (default: $OCTO_DEVSTACK_CONFIG, else devstack.yaml in the
                                                         octo-tools config folder that Get-OctoWorkspace names)
                                --octo-tools <path>      the octo-tools checkout to ask (default: $OCTO_TOOLS_PATH, else the
                                                         octo-tools checkout that holds this devstack folder)
                                --url <url>              listen URL, loopback only (default: server.url of the config)
                                --state <dir>            state folder (default: $OCTO_DEVSTACK_STATE or ~/.local/state/octo-devstack)
                                --dev                    development daemon next to the shared one: http://127.0.0.1:5190, config
                                                         devstack.dev.yaml next to devstack.yaml, state ~/.local/state/octo-devstack-dev
                                                         (--url, --config, --state still override each of them). A Debug build
                                                         started without --url is a development daemon.
                                --no-browser             dashboard_open never opens a browser (it answers the URL to open by hand)
                                --print-default-config   print the built-in default configuration and exit

                              octo-tools describes the workspace (Get-OctoWorkspace): root, default lane, config folder. The
                              daemon keeps no layout of its own; without octo-tools it does not start (unless --config is given).

                              State (running processes, leases, build jobs and logs, start/stop history): the state folder
                              """);
            return 0;
    }
}

// A Debug build is what a developer runs out of bin/Debug: it must never take the shared daemon's port, config or state by
// default. The shared daemon is the Release build (Start-OctoDevStackDaemon in octo-tools).
if (!development && DevelopmentDaemon.IsDebugBuild && urlOverride == null)
{
    development = true;
    Console.WriteLine("Debug build without --url: starting as a development daemon (--dev).");
}

if (development)
{
    urlOverride ??= DevelopmentDaemon.Url;
    stateOverride ??= Environment.GetEnvironmentVariable("OCTO_DEVSTACK_STATE") is { Length: > 0 } ? null : DevelopmentDaemon.StateDirectory();
}

// Windows (AB#9377): the services, builds and probes this daemon starts must not inherit its own log (see StdHandles).
if (OperatingSystem.IsWindows())
{
    StdHandles.KeepOutputFromChildren();
}

// The service manager that runs this daemon (octo-tools' unit or LaunchAgent sets it); not passed on to the services.
var serviceManager = Environment.GetEnvironmentVariable(DaemonLock.ServiceVariable);
Environment.SetEnvironmentVariable(DaemonLock.ServiceVariable, null);

// One daemon per state folder (AB#9377), before anything else: a second one would ask octo-tools, take over the services and
// write a start record (and a wrong "lost" for the running one), and only then fail at the port.
var paths = new DevStackPaths(stateOverride);
DaemonLock? daemonLock;
try
{
    daemonLock = DaemonLock.TryAcquire(paths.StateDirectory);
}
catch (Exception e) when (e is IOException or UnauthorizedAccessException)
{
    Console.Error.WriteLine($"Cannot take {DaemonLock.PathIn(paths.StateDirectory)}: {e.Message} - check the state folder's permissions.");
    return 1;
}
if (daemonLock == null && DaemonLock.WaitsForTheLock(serviceManager))
{
    // launchd (KeepAlive) would start this daemon again every 10 s: it waits for the other one to end and takes over.
    Console.Error.WriteLine($"Another octo-devstack runs with the state folder {paths.StateDirectory} ({DaemonLock.FileName} is held): " +
                            $"waiting for it to end ({serviceManager} would start this daemon again at once); nothing adopted or recorded yet.");
    try
    {
        daemonLock = await DaemonLock.WaitAsync(paths.StateDirectory, TimeSpan.FromSeconds(2));
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException)
    {
        Console.Error.WriteLine($"Cannot take {DaemonLock.PathIn(paths.StateDirectory)}: {e.Message} - check the state folder's permissions.");
        return 1;
    }

    Console.WriteLine($"{DaemonLock.FileName} is free: this daemon takes over.");
}

if (daemonLock == null)
{
    Console.Error.WriteLine($"Another octo-devstack runs with the state folder {paths.StateDirectory} ({DaemonLock.FileName} is held): " +
                            "nothing was adopted or recorded. GET /api/daemon of the running daemon names its pid.");
    return DaemonLock.HeldExitCode;
}

using var heldLock = daemonLock;

// The workspace (AB#9377): octo-tools says where the root, its default lane and its config folder are.
var workspace = await StartupWorkspace.ResolveAsync(givenOctoTools);
foreach (var problem in workspace.Problems)
{
    Console.WriteLine($"Workspace: {problem}");
}

var explicitConfig = givenConfig ?? (Environment.GetEnvironmentVariable("OCTO_DEVSTACK_CONFIG") is { Length: > 0 } fromEnv ? TemplateExpander.ExpandPath(fromEnv) : null);
if ((explicitConfig ?? ConfigStore.PathIn(workspace)) is not { } sharedConfig)
{
    Console.Error.WriteLine("No devstack.yaml: octo-tools did not describe the workspace (see above), so its config folder is unknown. " +
                            "Start the daemon with Start-OctoDevStackDaemon (octo-tools), set OCTO_TOOLS_PATH or pass --octo-tools, or pass --config.");
    return 1;
}

var configPath = development && explicitConfig == null ? DevelopmentDaemon.ConfigPath(sharedConfig) : sharedConfig;
var store = new ConfigStore(configPath) { WorkspaceInfo = workspace };
// A file of a daemon before AB#9377 (~/.config/octo-devstack) is taken over when the octo-tools config folder has none yet.
var legacyPath = explicitConfig == null ? ConfigStore.LegacyPath(Path.GetFileName(configPath)) : null;
DevStackConfig config;
try
{
    // Inside the try: a legacy file the current validation rejects is reported like a broken config, not a crash (which
    // launchd or systemd would restart in a loop).
    if (legacyPath != null && store.TakeOver(legacyPath, store.Workspace) is { } takenOver)
    {
        Console.WriteLine(takenOver);
    }
    else if (store.EnsureExists())
    {
        Console.WriteLine($"Wrote the default configuration to {configPath}");
    }

    config = store.Load();
}
catch (InvalidOperationException e)
{
    Console.Error.WriteLine(e.Message);
    return 1;
}

var url = urlOverride ?? config.Server.Url;
if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || !IsLoopback(uri.Host))
{
    Console.Error.WriteLine($"server.url must be a loopback URL (127.0.0.1, ::1, localhost), not '{url}': the daemon starts processes with your rights.");
    return 1;
}

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.UseUrls(url);
builder.Logging.AddSimpleConsole(o =>
{
    o.SingleLine = true;
    o.TimestampFormat = "HH:mm:ss ";
});

var journal = new DaemonJournal(paths, url.TrimEnd('/'), configPath, development);
var state = new StateStore(paths);
var persisted = state.Load();
// A lane's lease was held by "env:<lane>" before the lane vocabulary: a restored one keeps belonging to the lane.
var restoredLeases = persisted.LeasesBySlot().ToDictionary(l => l.Key, l => l.Value with { Owner = EnvironmentDiscovery.CurrentLeaseOwner(l.Value.Owner) });
var lease = new LeaseManager(restored: restoredLeases.GetValueOrDefault(SlotInfo.DefaultName));
var leases = new LeaseRegistry(lease, restoredLeases);
leases.Changed += state.SaveLease;
var claims = new LaneClaims { CurrentLease = lease.Current };
claims.CurrentLeaseOf = resource => leases.All.FirstOrDefault(l => LaneClaims.ResourceOf(l.Slot) == resource)?.Current();
leases.Changed += (slot, info) => claims.OnLeaseChanged(LaneClaims.ResourceOf(slot), info);

builder.Services.AddSingleton(store);
builder.Services.AddSingleton(paths);
builder.Services.AddSingleton(journal);
builder.Services.AddSingleton(state);
builder.Services.AddSingleton(lease);
builder.Services.AddSingleton(leases);
builder.Services.AddSingleton(claims);
builder.Services.AddSingleton(new PreStartChecks());
builder.Services.AddSingleton<ExternalDetector>();
builder.Services.AddSingleton<IPwshRunner, PwshProcessRunner>();
builder.Services.AddSingleton(sp => new StackSupervisor(store, lease, state, sp.GetRequiredService<ILogger<StackSupervisor>>(),
    sp.GetRequiredService<ExternalDetector>(), claims, sp.GetRequiredService<PreStartChecks>(), leases));
var dockerVm = new DockerVm(store);
builder.Services.AddSingleton(dockerVm);
builder.Services.AddSingleton(new BuildQueueOptions { Docker = dockerVm });
builder.Services.AddSingleton(sp => new SetupCheck(store, SetupCheck.MachineProbes(sp.GetRequiredService<PreStartChecks>(), dockerVm),
    () => sp.GetRequiredService<StackSupervisor>().State.Load()));
builder.Services.AddSingleton(sp => new BuildQueue(store, sp.GetRequiredService<StackSupervisor>(), lease, paths,
    sp.GetRequiredService<ILogger<BuildQueue>>(), sp.GetRequiredService<IPwshRunner>(), state, claims, sp.GetRequiredService<BuildQueueOptions>()));
builder.Services.AddSingleton(sp => new SlotOperations(store, sp.GetRequiredService<StackSupervisor>(), sp.GetRequiredService<IPwshRunner>(),
    checks: sp.GetRequiredService<PreStartChecks>()));
builder.Services.AddSingleton(sp => new SlotDataCleanup(store, sp.GetRequiredService<StackSupervisor>(),
    SlotDataStores.Local(sp.GetRequiredService<IPwshRunner>(), () => sp.GetRequiredService<SlotOperations>().OctoToolsConfigFile,
        () => sp.GetRequiredService<PreStartChecks>().ContextsFile), sp.GetRequiredService<ILogger<SlotDataCleanup>>()));
builder.Services.AddSingleton(sp => new EnvironmentManager(store, sp.GetRequiredService<StackSupervisor>(), sp.GetRequiredService<BuildQueue>(),
    sp.GetRequiredService<IPwshRunner>(), sp.GetRequiredService<SlotDataCleanup>(), sp.GetRequiredService<ILogger<EnvironmentManager>>()));

// dashboard_open: the status page of this daemon in the developer's browser (--no-browser: never).
builder.Services.AddSingleton(new Dashboard(url, new SystemBrowser(disabled: noBrowser)));

// Tools, prompts and the agent view /mcp?view=agent without the admin_* and developer tools (McpSurface, AgentView).
builder.Services.AddDevStackMcp();

var app = builder.Build();

// DNS-rebinding guard: a browser page must not reach the daemon under a foreign host name.
app.Use(async (context, next) =>
{
    var host = context.Request.Host.Host;
    var origin = context.Request.Headers.Origin.ToString();
    if (!IsLoopback(host) || (origin.Length > 0 && (!Uri.TryCreate(origin, UriKind.Absolute, out var o) || !IsLoopback(o.Host))))
    {
        context.Response.StatusCode = StatusCodes.Status403Forbidden;
        await context.Response.WriteAsync("octo-devstack accepts loopback requests only.");
        return;
    }

    await next();
});

app.MapGet("/health", () => Results.Ok(new
{
    status = "ok", config = configPath, pid = journal.Daemon.Pid, version = journal.Daemon.Version, commit = journal.Daemon.Commit,
    startedAt = journal.Daemon.StartedAt, development
}));
app.MapMcp("/mcp");
app.MapStatusUi();

claims.Logger = app.Services.GetRequiredService<ILogger<LaneClaims>>();
// Nobody may ask for a lease for a while: look every 30 s so an expired lease removes its lane claim.
using var leaseExpiry = new Timer(_ => leases.Tick(), null, TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(30));

foreach (var problem in ServicePlanner.FolderProblems(config, configPath))
{
    app.Logger.LogWarning("{Problem}", problem);
}

var supervisor = app.Services.GetRequiredService<StackSupervisor>();
supervisor.Restore(persisted);
// Now, not at the first tool call: the queue restores the jobs of the previous run and re-attaches to builds still running.
var buildQueue = app.Services.GetRequiredService<BuildQueue>();
// A lane stack sets itself up after a start that brought its identity service up healthy (slotOptions.autoSetup).
supervisor.Setup = app.Services.GetRequiredService<SlotOperations>();

// Every start and stop is written down with what triggered it (daemon.log and daemon-history.jsonl; the status page shows them).
foreach (var e in journal.RecordStart())
{
    if (e.Event == "lost")
    {
        app.Logger.LogWarning("octo-devstack {Date}: previous run (pid {Pid}, version {Version} {Commit}) ended without a shutdown record: {Detail}",
            e.At.ToString("yyyy-MM-dd HH:mm:ss zzz"), e.Pid, e.Version, e.Commit ?? "-", e.Detail);
    }
    else
    {
        app.Logger.LogInformation("octo-devstack {Date}: START pid {Pid}, version {Version}, commit {Commit}, {Detail}{Dev}",
            e.At.ToString("yyyy-MM-dd HH:mm:ss zzz"), e.Pid, e.Version, e.Commit ?? "-", e.Detail, development ? " (development daemon)" : "");
    }
}

// A signal cannot be refused, only named: the handlers leave the default handling (the host's graceful shutdown) alone.
var signals = new List<PosixSignalRegistration>();
foreach (var signal in (PosixSignal[])[PosixSignal.SIGTERM, PosixSignal.SIGINT, PosixSignal.SIGQUIT, PosixSignal.SIGHUP])
{
    try
    {
        signals.Add(PosixSignalRegistration.Create(signal, context =>
        {
            journal.NoteSignal(context.Signal.ToString());
            if (context.Signal == PosixSignal.SIGHUP)
            {
                // The host does not shut down gracefully on SIGHUP; the record is written here.
                journal.RecordStop();
            }
        }));
    }
    catch (Exception e) when (e is PlatformNotSupportedException or IOException)
    {
        // The shutdown is then recorded as "host shutdown".
    }
}

// Written when the host has stopped, not when it starts to: the host's own signal handler may run before the one above,
// and the record should name the signal.
app.Lifetime.ApplicationStopped.Register(() =>
{
    var active = buildQueue.Active();
    var stop = journal.RecordStop(active.Count > 0 ? $"{active.Count} build(s) queued or running: {string.Join(", ", active.Select(b => $"{b.Id} {b.State} ({b.Owner})"))}" : null);
    app.Logger.LogInformation(
        "octo-devstack {Date}: STOP pid {Pid}, version {Version}, commit {Commit}, trigger: {Trigger} (the sender of a signal is not available to the process). " +
        "Running services keep running and are adopted by the next start; {Builds}",
        DateTimeOffset.Now.ToString("yyyy-MM-dd HH:mm:ss zzz"), journal.Daemon.Pid, journal.Daemon.Version, journal.Daemon.Commit ?? "-", stop?.Trigger ?? "host shutdown",
        active.Count == 0
            ? "no build runs or waits."
            : $"{active.Count} build(s) go on or wait and are taken over by the next start: {string.Join(", ", active.Select(b => $"{b.Id} {b.State} ({b.Owner})"))}.");
});
app.Logger.LogInformation("octo-devstack on {Url}/mcp, status page {Url}/, config {Config}, state {State}", url.TrimEnd('/'), url.TrimEnd('/'), configPath, paths.StateDirectory);

await app.RunAsync();
GC.KeepAlive(signals);
return 0;

static bool IsLoopback(string host) =>
    host.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
    (IPAddress.TryParse(host.Trim('[', ']'), out var address) && IPAddress.IsLoopback(address));

/// <summary>
///     The development daemon (--dev): its own port, config and state next to the shared daemon's, so nobody develops
///     against the daemon the other sessions use.
/// </summary>
internal static class DevelopmentDaemon
{
    public const string Url = "http://127.0.0.1:5190";

#if DEBUG
    public const bool IsDebugBuild = true;
#else
    public const bool IsDebugBuild = false;
#endif

    /// <summary>devstack.dev.yaml next to the shared daemon's config.</summary>
    public static string ConfigPath(string sharedConfigPath) =>
        Path.Combine(Path.GetDirectoryName(sharedConfigPath) ?? ".", "devstack.dev.yaml");

    public static string StateDirectory() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "state", "octo-devstack-dev");
}

/// <summary>The MCP server instructions: the octo-claude-pm flow in the agent vocabulary (lane, base lane, shared stack, lane stack, job).</summary>
internal static class ServerInstructions
{
    public const string Text =
        "octo-devstack runs the OctoMesh dev stacks, builds and test runs of this machine for every Claude Code session. " +
        "Words: a lane (octo-tools: feature environment) is the workspace of one work item - <rootPath>/wt-<lane> with worktrees of the repos " +
        "it changes and of the repos rebuilt against them, its own NuGet feed and package cache, and its own lane stack (shifted ports, own " +
        "system database). The base lane (branches/main) is the checkout every lane starts from; services of repos a lane does not hold run " +
        "from it. The shared stack is the one local OctoMesh on the configured ports; tools act on it when no lane is given. A job is a build " +
        "or a test run in the daemon's queue. " +
        "In every changing call pass owner = your branch '<user>/AB#<id>_<desc>' and session = your ListAgents name (e.g. 'meshmakers-07'), " +
        "the same values every time: leases and lane claims record both (jobs the owner), so others can SendMessage the holder. " +
        "UC-B, a work item in its own lane: lane_create(owner, session, lane, repos, branch, workItem) -> edit in the repo paths " +
        "lane_list(lane) shows -> lane_build(owner, lane) -> lane_test(owner, lane, repo) -> stack_start(owner, lane) and verify (stack_status(lane), " +
        "service_logs(service, lane), stack_verify(lane), octo-cli --context local-<lane>_octosystem) -> lane_remove(owner, lane) after the merge " +
        "(refused, with the list, while a process it did not start holds files in the lane - an MSBuild node ends with `dotnet build-server " +
        "shutdown`; afterwards it drops the lane stack's data and deletes the lane's feature branches without commits - branches lists the " +
        "kept ones with the command for after the merge, keepBranches=true keeps all). A lane holds its stack's lease itself, so every session of the lane shares it " +
        "(services[].startedBy names who started a service). The first start of a lane stack sets up its admin, octo-cli contexts and login " +
        "(stack_setup repeats a failed step). Without services, stack_start(lane) leaves out what cannot run in a lane stack - the frontends " +
        "and an adapter whose tenant another running stack serves - and leftOut says why and how to include one. " +
        "A start that names services (stack_start services=[...], service_start) brings their startAfter dependencies that do not run yet " +
        "(added names them), so services=['platformServices'] is enough. " +
        "UC-A, a lane's service in the shared stack: lane_build, then take the shared stack's lease (lease_status; lease_acquire(owner, session, " +
        "waitSeconds) queues while another session holds it), service_restart(owner, services=[s], overrides={s: {source: 'lane:<lane>'}}), " +
        "verify, switch back with overrides={s: {}} and lease_release. Every change of the shared stack (stack_start/stop, service_*, builds " +
        "with stopServices) needs that lease; it expires 30 minutes after the holder's last changing call (lease_status: lastActivityAt, " +
        "idleMinutes). " +
        "UC-C, roles: one lane per work item, created and owned by the task's lead; its developer agents work in that lane only. " +
        "Waiting: lane_build, base_build, lane_test and base_test return a job at once; job_status(id, waitSeconds=50) answers when the job " +
        "ended (timedOut says when it did not yet - call it again; 50 s is the maximum, the MCP call of an in-process teammate times out " +
        "after about 60 s). job_list(lane, limit), job_output, job_cancel (short ids such as 'b351' work); builds never run tests. " +
        "Coordinators only read (/mcp?view=agent lists no admin_* tool): stack_status, stack_attention (what needs attention), stack_list, lane_list, lane_affected, " +
        "workspace_list, job_status, job_list, job_output, job_refusals, job_stats, build_plan, profile_list, profile_get, config_get, service_logs, " +
        "service_env, lease_status, test_lock, infra_status, daemon_status, setup_check. " +
        "Only with the developer's go: base_build kind=range (publish=true: it changes the base lane's 999.0.0 packages for every session; a " +
        "lane builds its library changes into its own feed instead) and kind=all (confirm=true, 30-90 min), lease_release(force=true), and " +
        "every admin_* tool (devstack.yaml, profiles, slots). Never restart the shared daemon while daemon_status restart.safe is false " +
        "unless the developer says so. octo-devstack never stops processes it did not start (except non-interactive Start-Octo stacks for " +
        "kind=all with stopExternal=true); the kind infrastructure (MongoDB, CrateDB, RabbitMQ) is not managed here. " +
        "dashboard_open opens the status page in the developer's browser: call it only when the developer asks to see it.";
}

/// <summary>Entry point (top-level statements).</summary>
public partial class Program;

/// <summary>The workspace at the daemon's start (AB#9377): octo-tools located (--octo-tools, OCTO_TOOLS_PATH, else the octo-tools checkout holding devstack/), then asked.</summary>
internal static class StartupWorkspace
{
    public static async Task<WorkspaceInfo> ResolveAsync(string? givenOctoTools)
    {
        var tools = WorkspaceResolver.LocateOctoTools(givenOctoTools, AppContext.BaseDirectory, Environment.GetEnvironmentVariable);
        if (tools == null)
        {
            return WorkspaceResolver.NotFound("");
        }

        Console.WriteLine($"Asking octo-tools at {tools} for the workspace (Get-OctoWorkspace)...");
        return await WorkspaceResolver.ResolveAsync(new PwshProcessRunner(), tools, TimeSpan.FromSeconds(90), CancellationToken.None);
    }
}
