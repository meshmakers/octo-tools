using System.ComponentModel;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>Start, stop and inspect the shared stack and the lane stacks.</summary>
[McpServerToolType]
public sealed class StackTools(StackSupervisor supervisor, ConfigStore store, ILogger<StackTools>? logger = null)
{
    internal const int DefaultLogChars = 20_000;
    internal const int MaxLogLineChars = 2_000;

    /// <summary>
    ///     Cuts lines longer than <see cref="MaxLogLineChars"/> (with a marker) and keeps the newest lines that fit into
    ///     <paramref name="maxChars"/> (DEBUG lines with whole Mongo commands are tens of KB each).
    /// </summary>
    internal static (string Text, int Lines, string? Note) Cap(IReadOnlyList<string> lines, int maxChars)
    {
        var cutLines = 0;
        var cut = lines.Select(l =>
        {
            if (l.Length <= MaxLogLineChars)
            {
                return l;
            }

            cutLines++;
            return l[..MaxLogLineChars] + $" ... [cut {l.Length - MaxLogLineChars} chars]";
        }).ToList();

        var kept = new List<string>();
        var total = 0;
        for (var i = cut.Count - 1; i >= 0; i--)
        {
            // The size the caller receives: the line JSON-escaped twice (the tool result is JSON inside the MCP text content).
            var add = SerializedLength(cut[i]) + (kept.Count > 0 ? 4 : 0); // "\n" escaped twice
            if (total + add > maxChars)
            {
                break;
            }

            kept.Add(cut[i]);
            total += add;
        }

        kept.Reverse();
        var notes = new List<string>();
        if (cutLines > 0)
        {
            notes.Add($"{cutLines} line(s) longer than {MaxLogLineChars} characters cut");
        }

        if (kept.Count < cut.Count)
        {
            notes.Add($"{cut.Count - kept.Count} older line(s) left out to stay within maxChars={maxChars}");
        }

        return (string.Join('\n', kept), kept.Count, notes.Count == 0 ? null : string.Join("; ", notes) + ".");
    }

    private static int SerializedLength(string line) =>
        System.Text.Json.JsonSerializer.Serialize(System.Text.Json.JsonSerializer.Serialize(line)).Length - 6;

    internal const string LaneDescription =
        "Lane (lane_list): act on the lane's own stack - shifted ports, own system database, created on the first start - which runs " +
        "the lane's worktrees, and services of repos the lane does not hold from the base lane. The lane holds that stack's lease, so " +
        "every session of the lane shares it; owner and session are still recorded. Leave it out for the shared stack.";

    internal const string SessionDescription =
        "Your session's ListAgents name, e.g. 'meshmakers-07', so another session can SendMessage you about the lease or claim you hold. " +
        "Optional, recommended; pass the same value in every changing call.";

    internal const string SlotDescription =
        "Diagnostics only: a stack slot that belongs to no lane (stack_list). Default: the only slot whose lease you hold, else the shared stack. " +
        "Use lane for a lane's stack.";

    /// <summary>
    ///     Resolves lane to (lease owner, slot, folder, scope); for a changing call takes the lane's lease, recording the
    ///     calling owner. Without lane everything passes through.
    /// </summary>
    private (string LeaseOwner, string? Slot, string? Checkout, EnvironmentScope? Scope) Bind(string owner, string? lane, string? slot, string? checkout = null,
        bool changing = true)
    {
        var config = store.Load();
        var scope = EnvironmentBinding.Resolve(config, lane, slot, checkout);
        if (scope == null)
        {
            if (changing && slot != null)
            {
                // AB#9673: the slot of a lane that is being removed (its lease is released before the cmdlet runs) takes no start.
                supervisor.Removals.Refuse(EnvironmentBinding.OfSlot(config, slot)?.Name);
                supervisor.Removals.RefuseSlot(slot); // also once the lane's manifest is gone (the mark records the slot)
            }

            return (owner, slot, checkout, null);
        }

        if (changing)
        {
            EnvironmentBinding.Claim(supervisor, scope, owner);
            logger?.LogInformation("{Owner} acts for lane {Lane} (slot {Slot})", owner, scope.Name, scope.Slot);
        }

        return (scope.LeaseOwner, scope.Slot, scope.Checkout, scope);
    }

    /// <summary>
    ///     After a failed stack_start: releases the leases <paramref name="leaseOwner"/> holds now but did not hold before the call,
    ///     for every slot in which nothing runs (a start that failed halfway keeps the lease of what it left running).
    /// </summary>
    private void ReleaseTakenLeases(string leaseOwner, IReadOnlyCollection<string> heldBefore)
    {
        foreach (var slotName in supervisor.Leases.HeldBy(leaseOwner).Except(heldBefore, StringComparer.Ordinal))
        {
            try
            {
                var known = supervisor.Registry.Known().Any(k => k.Slot.Name == slotName);
                if (known && supervisor.Slot(slotName).AnyAlive)
                {
                    continue;
                }

                supervisor.Leases.Find(slotName)?.Release(leaseOwner, force: false);
                logger?.LogInformation("stack_start of {Owner} failed; released the lease of slot {Slot} it had taken", leaseOwner, slotName);
            }
            catch (Exception e) when (e is InvalidOperationException or LeaseHeldException)
            {
                logger?.LogWarning(e, "stack_start of {Owner} failed; the lease of slot {Slot} could not be released", leaseOwner, slotName);
            }
        }
    }

    /// <summary>
    ///     Refuses an override source 'lane:&lt;name&gt;' that does not resolve (unknown lane, a lane without the service's repo)
    ///     before anything is stopped; the planner resolves it again for the start.
    /// </summary>
    private void CheckLaneSources(IReadOnlyDictionary<string, ServiceOverride>? overrides)
    {
        if (overrides == null || !overrides.Values.Any(o => LaneSource.Is(o.Source)))
        {
            return;
        }

        var config = store.Load();
        foreach (var (name, o) in overrides)
        {
            if (LaneSource.Is(o.Source))
            {
                supervisor.Removals.Refuse(o.Source![LaneSource.Prefix.Length..].Trim()); // AB#9673: not from a lane that is being removed
            }

            if (LaneSource.Is(o.Source) && config.Services.TryGetValue(name, out var service))
            {
                LaneSource.Resolve(config, name, service.Repo, o.Source!);
            }
        }
    }

    /// <summary>The session of a changing call, for the owner and for the lane whose lease it takes (<see cref="LeaseSession"/>).</summary>
    internal static IDisposable Caller(string? session, string owner, string? lane) =>
        LeaseSession.Use(session, owner, string.IsNullOrWhiteSpace(lane) ? null : Discovery.EnvironmentDiscovery.LeaseOwnerOf(lane.Trim()));

    internal const string OwnerDescription =
        "Your octo-claude-pm branch '<user>/AB#<id>_<desc>' (e.g. 'reimar/AB#8625_explicit-null-enum-record'): the stable name leases and " +
        "jobs are recorded under. Use the same value in every call.";

    [McpServerTool(Name = "stack_status", ReadOnly = true)]
    [Description("Shows what runs in the shared stack or in a lane's stack. Every service with pid (the process the daemon started; on Windows the " +
                 "cmd.exe wrapper, and processId is the service's own process below it - the pid RabbitMQ and stack_verify report), state (healthy / starting / unhealthy / " +
                 "exited), the folder it runs from (a lane's worktree, a source override; runsFrom says it in words: 'lane:<name>', 'base lane' or the " +
                 "folder), who started or overrode it (startedBy = the owner of that call, " +
                 "startedBySession its session - also in a lane stack, whose lease the lane holds; startedVia = stack_start | service_start | service_restart | " +
                 "restart after a build), log file, exit code and the last log lines " +
                 "of exited or unhealthy services, plus the lease holder (with session and last activity) and queue, and for a lane stack its " +
                 "last setup; baseLane (the base lane it runs from) and lane (a lane stack's lane). 'external' lists the stack processes the daemon did NOT " +
                 "start - a Start-Octo (with its -branch/-configuration), an npm run start, a leftover process - with service, pid, ports, " +
                 "health, lane/worktree, configuration, log file, and per group who started it (terminal or Claude Code session with agent and " +
                 "session id) and how to stop it; external.warning when the scan failed (the processes outside the daemon are unknown), " +
                 "external.skipped the processes left out because their analysis failed (pid, executable, exceptionType - the others " +
                 "are reported). stack_start fails while they hold service ports. 'profile' says which profile the stack runs " +
                 "(exact, or the differences: drift, and edited when the profile changed since the start); every external group carries the " +
                 "profile it looks like. Without lane: the shared stack, and 'slots' lists every lane stack in one line (ports offset, prefix, " +
                 "owner, profile, n/m healthy). Read-only; no lease needed.")]
    public Task<StackStatus> Status(
        [Description("Include the last log lines of exited/unhealthy services.")] bool includeLogTail = true,
        [Description("A lane (lane_list): the status of its stack. Default: the shared stack.")] string? lane = null,
        [Description(SlotDescription)] string? slot = null) =>
        ToolGuard.Run(async () =>
            WithServiceProcesses(WithEntryAssemblies(await supervisor.StatusAsync(includeLogTail, Bind("", lane, slot, changing: false).Slot))).Masked());

    /// <summary>
    ///     Windows: adds to every alive service its own process (processId), the child of the recorded cmd.exe wrapper - the pid
    ///     RabbitMQ and other tools see; the service rows of <see cref="StackStatus.Slots"/> (the status page) too. macOS/Linux (no
    ///     <paramref name="links"/>): unchanged, the recorded pid is the service.
    /// </summary>
    /// <param name="links">(pid, parent pid) of every process; null: the machine's on Windows (conhost.exe left out), none elsewhere.</param>
    internal static StackStatus WithServiceProcesses(StackStatus status, IReadOnlyList<(int Pid, int ParentPid)>? links = null)
    {
        static bool Alive(int pid, string state) => pid > 0 && state is not ("exited" or "stopped-for-build");
        if (links == null && !OperatingSystem.IsWindows() ||
            !status.Services.Any(s => Alive(s.Pid, s.State)) && !(status.Slots ?? []).SelectMany(s => s.Services).Any(s => Alive(s.Pid, s.State)))
        {
            return status;
        }

        links ??= ProcessTree.Links();
        var children = links.GroupBy(l => l.ParentPid).ToDictionary(g => g.Key, g => g.Select(l => l.Pid).Order().ToList());
        int? Child(int pid, string state) => Alive(pid, state) && children.GetValueOrDefault(pid) is [var child, ..] ? child : null;
        return status with
        {
            Services = status.Services.Select(s => Child(s.Pid, s.State) is { } child ? s with { ProcessId = child } : s).ToList(),
            Slots = status.Slots?.Select(slot => slot with
            {
                Services = slot.Services.Select(s => Child(s.Pid, s.State) is { } child ? s with { ProcessId = child } : s).ToList()
            }).ToList()
        };
    }

    /// <summary>
    ///     Adds to every alive service the entry assembly its process really loaded and flags one that is not below the folder
    ///     the service should run from (a stale process, a wrong source).
    /// </summary>
    internal static StackStatus WithEntryAssemblies(StackStatus status, Func<IReadOnlyDictionary<int, string>, Dictionary<int, string?>>? loaded = null)
    {
        var alive = status.Services.Where(s => s.Pid > 0 && s.State is not ("exited" or "stopped-for-build") && EntryAssemblies.DllOf(s.Args) != null).ToList();
        if (alive.Count == 0 || OperatingSystem.IsWindows() && loaded == null)
        {
            return status;
        }

        var found = (loaded ?? EntryAssemblies.Loaded)(alive.ToDictionary(s => s.Pid, s => EntryAssemblies.DllOf(s.Args)!));
        return status with
        {
            Services = status.Services.Select(s =>
            {
                if (!found.TryGetValue(s.Pid, out var path) || !alive.Contains(s))
                {
                    return s;
                }

                var problem = path == null
                    ? $"{EntryAssemblies.DllOf(s.Args)} is not among the process's open files"
                    : !PathScope.IsUnder(path, s.RepoPath) ? $"the process loaded {path}, not a file below {s.RepoPath}" : null;
                return s with { EntryAssembly = path, EntryAssemblyProblem = problem };
            }).ToList()
        };
    }

    [McpServerTool(Name = "stack_start")]
    [Description("Starts the shared stack (no lane) or a lane's stack (lane=<name>): the core .NET services and frontends Start-Octo runs. " +
                 "The shared stack runs on the configured ports from the base lane; it needs the shared stack's lease (taken for 'owner' when " +
                 "free) and claims the base lane's local stack (<lane>/.octo/claims/local-stack.md, naming owner and session). A lane's stack " +
                 "runs on shifted ports (+100 for the first lane) with its own system database, RabbitMQ/CrateDB/artifact prefixes and folders, " +
                 "from the lane's worktrees, and services of repos the lane does not hold from the base lane; the lane holds its lease. " +
                 "Frontends stay in the shared stack, and an adapter tenant may run in one stack only. 'profile' starts a saved profile " +
                 "(profile_list); every other argument given here wins over it. Without 'services' it starts every enabled service; optional " +
                 "services that are not built are skipped, and a lane stack leaves out what cannot run there - the frontends and an adapter whose " +
                 "tenant another running stack serves - and lists each in leftOut with the reason and how to include it (a named service list " +
                 "is refused instead). Named services bring the startAfter dependencies that do not run yet (services=['platformServices'] adds " +
                 "identityServices; 'added' lists them with the reason). Per service you can run it from a lane's worktree (overrides.<service>.source = " +
                 "'lane:<name>') or a folder, and pass arguments and envVars. Fails while the stack runs unless replace=true, which stops the " +
                 "daemon's stack first (processes started outside the daemon still refuse it). Warns when the kind infrastructure does not " +
                 "answer. Services start in startAfter order (the backend services after identityServices); waitForHealthy=true (default) " +
                 "waits until they answer, up to timeoutSeconds for each - one whose dependency exits or is not healthy in time is not " +
                 "started, and the warnings say why. The result names the stack's octo-cli installation and identity overlay.")]
    public Task<StartResult> Start(
        [Description(OwnerDescription)] string owner,
        [Description(LaneDescription)] string? lane = null,
        [Description("Profile to start, e.g. 'core-data' or 'second-adapter' (names from profile_list).")]
        string? profile = null,
        [Description("Services to start (replaces the profile's list); default: all enabled ones. Names from config_get.")]
        List<string>? services = null,
        [Description("Services to leave out (added to the profile's exclude list).")]
        List<string>? exclude = null,
        [Description("Per-service changes for this start, keyed by service name: source ('lane:<name>' or a folder), args, extraArgs, envVars, " +
                     "variables. Merged over the profile's overrides.")]
        Dictionary<string, ServiceOverride>? overrides = null,
        [Description("Environment variables for all services of this stack (null value removes one); merged over the profile's.")]
        Dictionary<string, string?>? envVars = null,
        [Description("Stop the stack the daemon runs and start this one instead.")]
        bool replace = false,
        [Description("Wait until the services answer on their port/health URL (default true).")]
        bool waitForHealthy = true,
        [Description("Seconds to wait for health, also the wait for each startAfter dependency (max 900).")]
        int timeoutSeconds = 180,
        [Description("Shared stack only: the base lane to run from, relative to rootPath (e.g. 'branches/main') or absolute. Default: the profile's, " +
                     "else the configured base lane. Not with lane.")]
        string? baseLane = null,
        [Description("Build configuration whose bin folders are used: DebugL (local builds), Release or Debug. Default: the profile's, else the config's.")]
        string? configuration = null,
        [Description(SessionDescription)] string? session = null,
        [Description("Diagnostics only: a stack slot that belongs to no lane, e.g. 'second' (created on first use). Default: the profile's slot, " +
                     "else the shared stack. Use lane for a lane's stack.")]
        string? slot = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = Caller(session, owner, lane);
            CheckLaneSources(overrides);
            // AB#9676: the leases this call takes (the lane's, or the shared stack's for the owner) go again when the start fails
            // and nothing of it runs; a lease held before the call stays.
            var leaseOwner = string.IsNullOrWhiteSpace(lane) ? owner : Discovery.EnvironmentDiscovery.LeaseOwnerOf(lane.Trim());
            var heldBefore = supervisor.Leases.HeldBy(leaseOwner);
            (string LeaseOwner, string? Slot, string? Checkout, EnvironmentScope? Scope) bound = default;
            StartResult result;
            try
            {
                bound = Bind(owner, lane, slot, baseLane);
                result = await supervisor.StartStackAsync(bound.LeaseOwner,
                    new StartSpec
                    {
                        Checkout = bound.Checkout, Configuration = configuration, Services = services, Exclude = exclude, Overrides = overrides, Environment = envVars,
                        Slot = bound.Slot
                    },
                    profile, replace, waitForHealthy, ToolGuard.Timeout(timeoutSeconds), cancellationToken, new StackCaller(owner, session));
            }
            catch
            {
                ReleaseTakenLeases(leaseOwner, heldBefore);
                throw;
            }
            if (bound.Scope is { } scope)
            {
                result = result with
                {
                    Notes = [..result.Notes, $"Lane {scope.Name}: its own stack (slot '{scope.Slot}'), lease held by {scope.LeaseOwner} (started by {owner}); " +
                                            $"services of repos the lane does not hold run from the base lane {scope.Environment.BasePath}."]
                };
            }

            return result.Masked();
        });

    [McpServerTool(Name = "stack_stop", Destructive = true)]
    [Description("Stops every service of the shared stack (no lane) or of a lane's stack (lane=<name>): SIGTERM, SIGKILL after " +
                 "stopTimeoutSeconds. Needs the stack's lease (a lane's: any session of the lane). The lease stays with you; call lease_release " +
                 "when you are done with the shared stack. A lane whose stack does not run is a no-op.")]
    public Task<StopResult> Stop(
        [Description(OwnerDescription)] string owner,
        [Description(LaneDescription)] string? lane = null,
        [Description(SessionDescription)] string? session = null,
        [Description(SlotDescription)] string? slot = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = Caller(session, owner, lane);
            var scope = EnvironmentBinding.Resolve(store.Load(), lane, slot);
            if (scope != null && (!supervisor.Registry.Known().Any(k => k.Slot.Name == scope.Slot) || !supervisor.Slot(scope.Slot).Active))
            {
                // Nothing runs: a no-op, not an error (and no lease is taken for it).
                return new StopResult([], [], new StackStatus(false, null, null, null, null, supervisor.Leases.Get(scope.Slot).Snapshot(), [], [], ExternalSnapshot.Empty)
                    {
                        Slot = scope.Slot
                    })
                    { Note = $"The stack of lane '{scope.Name}' is not running (slot '{scope.Slot}'); nothing to stop." };
            }

            var bound = Bind(owner, lane, slot);
            return (await supervisor.StopServicesAsync(bound.LeaseOwner, null, cancellationToken, bound.Slot)).Masked();
        });

    [McpServerTool(Name = "service_start")]
    [Description("Starts services and adds them to the running shared stack (no lane) or lane stack (lane=<name>), with the same base lane and " +
                 "configuration. Without a running stack it starts one with just these services. Their startAfter dependencies that do not run " +
                 "in the stack come along ('added' names them). Needs the stack's lease. Use overrides to run a " +
                 "service from a lane's worktree (overrides.<service>.source = 'lane:<name>'), a folder, or with other arguments/envVars.")]
    public Task<StartResult> ServiceStart(
        [Description(OwnerDescription)] string owner,
        [Description("Service names (config_get).")] List<string> services,
        [Description(LaneDescription)] string? lane = null,
        [Description("Per-service changes, keyed by service name: source ('lane:<name>' or a folder), args, extraArgs, envVars, variables.")]
        Dictionary<string, ServiceOverride>? overrides = null,
        [Description("Wait until the services answer on their port/health URL (default true).")] bool waitForHealthy = true,
        [Description("Seconds to wait for health (max 900).")] int timeoutSeconds = 180,
        [Description(SessionDescription)] string? session = null,
        [Description(SlotDescription)] string? slot = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = Caller(session, owner, lane);
            CheckLaneSources(overrides);
            var bound = Bind(owner, lane, slot);
            return (await supervisor.StartServicesAsync(bound.LeaseOwner, services, overrides, waitForHealthy, ToolGuard.Timeout(timeoutSeconds), cancellationToken,
                bound.Slot, new StackCaller(owner, session))).Masked();
        });

    [McpServerTool(Name = "service_stop", Destructive = true)]
    [Description("Stops single services of the shared stack (no lane) or of a lane's stack (lane=<name>); the others keep running. Needs the stack's lease.")]
    public Task<StopResult> ServiceStop(
        [Description(OwnerDescription)] string owner,
        [Description("Service names.")] List<string> services,
        [Description(LaneDescription)] string? lane = null,
        [Description(SessionDescription)] string? session = null,
        [Description(SlotDescription)] string? slot = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = Caller(session, owner, lane);
            var bound = Bind(owner, lane, slot);
            return (await supervisor.StopServicesAsync(bound.LeaseOwner, services, cancellationToken, bound.Slot)).Masked();
        });

    [McpServerTool(Name = "service_restart")]
    [Description("Stops and starts services of the shared stack (no lane) or of a lane's stack (lane=<name>) again: after a rebuild, or to switch " +
                 "a service to or from a lane's build. UC-A, a lane's service in the shared stack: hold the shared stack's lease, then " +
                 "service_restart(owner, services=[<service>], overrides={<service>: {source: 'lane:<name>'}}) runs the lane's worktree of the " +
                 "service's repo (built with lane_build) in place of the base lane's; overrides={<service>: {}} switches it back. Without new " +
                 "overrides the ones of the previous start are kept. A changed devstack config (args, envVars) applies. Needs the stack's lease.")]
    public Task<StartResult> ServiceRestart(
        [Description(OwnerDescription)] string owner,
        [Description("Service names.")] List<string> services,
        [Description(LaneDescription)] string? lane = null,
        [Description("New per-service changes, replacing the previous ones of that service: source ('lane:<name>' or a folder), args, extraArgs, " +
                     "envVars, variables; {} drops them.")]
        Dictionary<string, ServiceOverride>? overrides = null,
        [Description("Wait until the services answer on their port/health URL (default true).")] bool waitForHealthy = true,
        [Description("Seconds to wait for health (max 900).")] int timeoutSeconds = 180,
        [Description(SessionDescription)] string? session = null,
        [Description(SlotDescription)] string? slot = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = Caller(session, owner, lane);
            CheckLaneSources(overrides);
            var bound = Bind(owner, lane, slot);
            return (await supervisor.RestartServicesAsync(bound.LeaseOwner, services, overrides, waitForHealthy, ToolGuard.Timeout(timeoutSeconds), cancellationToken,
                bound.Slot, new StackCaller(owner, session))).Masked();
        });

    [McpServerTool(Name = "service_logs", ReadOnly = true)]
    [Description("Shows the last lines of a service's log, optionally filtered by a case-insensitive regex: <base lane>/logFiles/<logName>.log for " +
                 "the shared stack (the same files Start-Octo writes), <rootPath>/wt-<lane>/logFiles for a lane's stack. Works for running and " +
                 "stopped services. Read-only.")]
    public Task<ServiceLogResult> Logs(
        [Description("Service name.")] string service,
        [Description("The lane whose stack runs the service (lane_list); default: the shared stack.")] string? lane = null,
        [Description("Number of lines (max 5000).")] int lines = 200,
        [Description("Only lines matching this regex (case-insensitive), e.g. 'fail|error|exception'.")] string? grep = null,
        [Description("Read the log of the previous run (<logName>.prev.log) instead.")] bool previous = false,
        [Description("For a service running more than once outside the daemon (see stack_status external): the pid whose log to read.")] int? pid = null,
        [Description(SlotDescription)] string? slot = null,
        [Description("At most this many characters of log text in the MCP answer, counted as serialized (JSON-escaped) - default 20000, max 200000; " +
                     "the newest lines are kept. Lines longer than 2000 characters are cut.")]
        int maxChars = DefaultLogChars) =>
        ToolGuard.Run(async () =>
        {
            slot = Bind("", lane, slot, changing: false).Slot;
            var run = supervisor.Slot(slot);
            var status = run.Slot.IsDefault ? await supervisor.StatusAsync(includeLogTail: false, SlotInfo.DefaultName) : await run.StatusAsync(false, ExternalSnapshot.Empty);
            var file = status.Services.FirstOrDefault(s => s.Name == service)?.LogFile
                       ?? status.External.Services.FirstOrDefault(s => s.Service == service && (pid == null || s.Pid == pid) && s.LogFile != null)?.LogFile;
            if (file == null && pid != null)
            {
                throw new InvalidOperationException($"No log file known for {service} pid {pid}.");
            }

            if (file == null)
            {
                var config = store.Load();
                if (!config.Services.TryGetValue(service, out var definition))
                {
                    throw new InvalidOperationException($"Unknown service '{service}'.");
                }

                var context = run.CreateContext(config, status.Folder, null);
                file = Path.Combine(context.LogDirectory, (definition.LogName ?? service) + ".log");
            }

            if (previous)
            {
                file = Path.ChangeExtension(file, ".prev.log");
            }

            if (!File.Exists(file))
            {
                throw new InvalidOperationException($"No log file {file}.");
            }

            var result = LogReader.TailLines(file, lines, grep);
            var (text, count, note) = Cap(result, Math.Clamp(maxChars, 1000, 200_000));
            return new ServiceLogResult(service, file, count, text) { Note = note };
        });
}

public sealed record ServiceLogResult(string Service, string LogFile, int Lines, string Text)
{
    /// <summary>What was cut (long lines, older lines over maxChars), or null.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Note { get; init; }
}
