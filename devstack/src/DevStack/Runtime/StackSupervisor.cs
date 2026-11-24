using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;

namespace Meshmakers.Octo.DevStack.Runtime;

public sealed record ServiceStatus(
    string Name,
    string State,
    bool Healthy,
    string? HealthDetail,
    int Pid,
    string? Source,
    string RepoPath,
    string WorkingDirectory,
    string Command,
    IReadOnlyList<string> Args,
    string LogFile,
    IReadOnlyList<int> Ports,
    DateTimeOffset StartedAt,
    DateTimeOffset? ExitedAt,
    int? ExitCode,
    bool Adopted,
    string? LogTail)
{
    /// <summary>stack_status: the entry assembly the process really loaded (macOS/Linux), and a problem when it is not below the service's folder.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? EntryAssembly { get; init; }

    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? EntryAssemblyProblem { get; init; }

    /// <summary>
    ///     stack_status on Windows: the service's own process, the child of the recorded <see cref="Pid"/> (the daemon records
    ///     the cmd.exe wrapper that redirects the output); RabbitMQ consumers (stack_verify) report this one. macOS/Linux: null,
    ///     the recorded pid is the service.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public int? ProcessId { get; init; }

    /// <summary>
    ///     Who started or overrode this service (the owner of its stack_start, service_start or service_restart with overrides),
    ///     which may be another session than the stack's <see cref="StackStatus.StartedBy"/>; startedVia names that call.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? StartedBy { get; init; }

    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? StartedVia { get; init; }

    /// <summary>The session (ListAgents name) <see cref="StartedBy"/> passed, so another session can SendMessage it.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? StartedBySession { get; init; }

    /// <summary>
    ///     Where the service runs from (<see cref="LaneSource.RunsFrom"/>): "lane:&lt;name&gt;" (that lane's worktree of its repo -
    ///     in a lane stack, or a lane's build in the shared stack), "base lane", or the folder of a source override.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? RunsFrom { get; init; }
}

public sealed record StackStatus(
    bool Running,
    [property: System.Text.Json.Serialization.JsonIgnore] string? Folder,
    string? Configuration,
    DateTimeOffset? StartedAt,
    string? StartedBy,
    LeaseSnapshot Lease,
    IReadOnlyList<ServiceStatus> Services,
    IReadOnlyList<string> EnabledNotRunning,
    ExternalSnapshot External,
    ProfileMatch? Profile = null,
    IReadOnlyDictionary<string, string>? Instances = null)
{
    /// <summary>The slot this status is of.</summary>
    public string Slot { get; init; } = SlotInfo.DefaultName;

    /// <summary>
    ///     The base lane the stack runs from: the shared stack's folder, or a lane stack's base lane (its services of repos the
    ///     lane does not hold run from there). Null without a stack. The folder itself is <see cref="Folder"/>.
    /// </summary>
    public string? BaseLane { get; init; }

    /// <summary>The lane whose stack this is (a lane stack), else null.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Lane { get; init; }

    /// <summary>Without a slot asked for: every slot in one line each (the fields above are the default slot's).</summary>
    public IReadOnlyList<SlotSummary>? Slots { get; init; }

    /// <summary>rootPath or defaultCheckout that do not exist (<see cref="ServicePlanner.FolderProblems"/>); null when both do.</summary>
    public IReadOnlyList<string>? ConfigProblems { get; init; }

    /// <summary>The last setup of this slot (a non-default slot asked for), or null when none ran.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public SlotSetupResult? Setup { get; init; }
}

/// <summary>One slot in stack_status, stack_list and on the status page.</summary>
public sealed record SlotSummary(
    string Name,
    int Index,
    int PortOffset,
    string Prefix,
    string Origin,
    bool Running,
    [property: System.Text.Json.Serialization.JsonIgnore] string? Folder,
    string? StartedBy,
    string? LeaseHolder,
    string? Profile,
    int Healthy,
    int Total,
    IReadOnlyList<SlotServiceRow> Services,
    string? LogDirectory,
    SlotArtifactPaths? Artifacts)
{
    /// <summary>The last setup of the slot (after a start or stack_setup), or null when none ran for its index.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public SlotSetupResult? Setup { get; init; }

    /// <summary>The base lane the slot's stack runs from (see <see cref="StackStatus.BaseLane"/>); null without a stack.</summary>
    public string? BaseLane { get; init; }

    /// <summary>The lane whose stack this is, else null.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Lane { get; init; }
}

/// <summary>
///     A compact service row of a slot: state, pid (on Windows processId, the service's own process below the cmd.exe wrapper,
///     where a tool asks for it), ports, where it runs from, the health detail and who started or overrode it (as in
///     stack_status).
/// </summary>
public sealed record SlotServiceRow(string Name, string State, int Pid, IReadOnlyList<int> Ports, string? Source)
{
    /// <summary>The folder the service runs from (a lane's repo, or its base lane's).</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? RepoPath { get; init; }

    /// <summary>"lane:&lt;name&gt;", "base lane" or a folder (<see cref="ServiceStatus.RunsFrom"/>).</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? RunsFrom { get; init; }

    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? HealthDetail { get; init; }

    /// <summary>When the process started (null for a service a build stopped).</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? StartedAt { get; init; }

    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? StartedBy { get; init; }

    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? StartedBySession { get; init; }

    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? StartedVia { get; init; }

    /// <summary>Windows: the service's own process below the recorded cmd.exe wrapper (<see cref="ServiceStatus.ProcessId"/>).</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public int? ProcessId { get; init; }
}

public sealed record StartResult(StackStatus Status, IReadOnlyList<string> Skipped, IReadOnlyList<string> Warnings, IReadOnlyList<string> Notes)
{
    /// <summary>
    ///     The services a start of every service left out because they cannot run in this stack (a lane stack: the frontends,
    ///     an adapter whose tenant another stack serves), each with the reason and how to include it. Null when none.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<LeftOutService>? LeftOut { get; init; }

    /// <summary>
    ///     The startAfter dependencies (transitively) a start that names its services added because they neither were named nor
    ///     ran in the stack, each with the services that start after it. Null when none.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<AddedService>? Added { get; init; }

    /// <summary>The setup the start ran (a non-default slot whose identity service got healthy): every step's outcome.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public SlotSetupResult? Setup { get; init; }

    /// <summary>
    ///     The restart after a job: the stopped services it did not start again (their lane is being removed, AB#9673), by the
    ///     names the job stopped them under. Internal: the job's notes say it.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public IReadOnlyList<string>? NotStarted { get; init; }
}

/// <summary>A service a start of every service left out: why, and how to include it.</summary>
public sealed record LeftOutService(string Service, string Reason, string Include);

/// <summary>A startAfter dependency a start added to the services it names, and why ("platformServices starts after it").</summary>
public sealed record AddedService(string Service, string Because);

public sealed record StopResult(IReadOnlyList<string> Stopped, IReadOnlyList<string> Killed, StackStatus Status)
{
    /// <summary>Why nothing was stopped (e.g. an environment that is not running).</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Note { get; init; }
}

/// <summary>A running job (a build or a test run) that owns a folder: services must not start from it until the job ends.</summary>
public sealed record BuildGuardHit(string JobId, string Owner, string Target)
{
    /// <summary>Whether the job is a test run (lane_test / base_test), not a build.</summary>
    public bool TestRun { get; init; }
}

/// <summary>Asked before a service starts (the build queue implements it).</summary>
public interface IBuildGuard
{
    /// <summary>The running build whose scope holds <paramref name="repoPath"/>, or null.</summary>
    BuildGuardHit? Blocking(string repoPath);
}

/// <summary>Services a build stopped and the overrides to start them with again.</summary>
public sealed record StoppedForBuild(IReadOnlyList<string> Names, IReadOnlyDictionary<string, ServiceOverride> Overrides)
{
    public static readonly StoppedForBuild None = new([], new Dictionary<string, ServiceOverride>());
}

/// <summary>What admin_profile_save(capture="daemon") needs of the running stack. Environment values are filtered by the caller.</summary>
public sealed record StackCapture(
    string Checkout,
    string Configuration,
    string? Profile,
    IReadOnlyDictionary<string, string?> RequestEnv,
    IReadOnlyDictionary<string, ProfileInstance> Instances,
    IReadOnlyDictionary<string, bool> EnvProviders,
    IReadOnlyList<(string Name, ServiceOverride? Override)> Services)
{
    /// <summary>The slot the stack runs in.</summary>
    public string Slot { get; init; } = SlotInfo.DefaultName;
}
/// <summary>
///     Owns the service processes of the stacks that run on this machine: one <see cref="SlotRun"/> per stack slot, each with
///     its own lease. Calls without a slot go to the default slot, which behaves exactly like the single stack before slots.
/// </summary>
public sealed class StackSupervisor
{
    /// <summary>How long a restart after a build waits for the startAfter dependencies of a service.</summary>
    public static TimeSpan RestartDependencyTimeout { get; set; } = TimeSpan.FromSeconds(180);

    private readonly ExternalDetector _external;
    private readonly ConfigStore _store;
    private readonly ILogger _logger;
    private readonly LaneClaims? _claims;
    private readonly PreStartChecks? _checks;
    private readonly Lock _lock = new();
    private readonly Dictionary<string, SlotRun> _slots = new(StringComparer.Ordinal);

    /// <param name="claims">Lane claims of the local stack; null keeps no claims (tests).</param>
    /// <param name="checks">Infrastructure and octo-cli checks; null skips them (tests).</param>
    /// <param name="leases">The leases of all slots; null: a registry around <paramref name="lease"/>.</param>
    public StackSupervisor(ConfigStore store, LeaseManager lease, StateStore state, ILogger<StackSupervisor> logger, ExternalDetector? external = null,
        LaneClaims? claims = null, PreStartChecks? checks = null, LeaseRegistry? leases = null)
    {
        _store = store;
        _logger = logger;
        _claims = claims;
        _checks = checks;
        State = state;
        Leases = leases ?? new LeaseRegistry(lease);
        Registry = new SlotRegistry(store, state);
        Validator = new SlotValidator(() => Runs);
        Artifacts = new SlotArtifacts();
        _external = external ?? new ExternalDetector(store);
        _external.KnownSlots ??= () => Registry.Known().Select(k => k.Slot).ToList();
        _slots[SlotInfo.DefaultName] = new SlotRun(this, SlotInfo.Default, Leases.Default, store, logger, claims, checks);
    }

    public StateStore State { get; }

    /// <summary>The daemon's state folder (slot folders live below it).</summary>
    public string StateDirectory => State.Paths.StateDirectory;

    public LeaseRegistry Leases { get; }

    /// <summary>The lanes lane_remove is removing right now: nothing new starts on them (AB#9673).</summary>
    public LaneRemovals Removals { get; } = new();

    public SlotRegistry Registry { get; }

    internal SlotValidator Validator { get; }

    internal SlotArtifacts Artifacts { get; }

    /// <summary>Running builds; services do not start from a folder a build works on (set by the build queue).</summary>
    public IBuildGuard? BuildGuard { get; set; }

    /// <summary>
    ///     The setup a non-default slot gets after a start that brought its identity service up healthy (slotOptions.autoSetup;
    ///     the daemon sets <see cref="SlotOperations"/>). Null: no automatic setup (tests that do not set one).
    /// </summary>
    public ISlotSetup? Setup { get; set; }

    /// <summary>A service name as shown outside its slot: plain in the default slot, "slot/name" elsewhere.</summary>
    public static string Qualify(string slot, string name) => slot == SlotInfo.DefaultName ? name : $"{slot}/{name}";

    /// <summary>Splits a qualified name ("slot/name" or a plain name of the default slot).</summary>
    public static (string Slot, string Name) Unqualify(string qualified)
    {
        var slash = qualified.IndexOf('/');
        return slash < 0 ? (SlotInfo.DefaultName, qualified) : (qualified[..slash], qualified[(slash + 1)..]);
    }

    /// <summary>Every slot run that exists (default first).</summary>
    public IReadOnlyList<SlotRun> Runs
    {
        get
        {
            lock (_lock)
            {
                return _slots.Values.OrderBy(r => r.Slot.Index).ToList();
            }
        }
    }

    public SlotRun Default => Slot(SlotInfo.DefaultName);

    /// <summary>The run of a slot; a slot not running yet is set up (and an unknown name created) when <paramref name="create"/> is set.</summary>
    public SlotRun Slot(string? name, bool create = false)
    {
        name ??= SlotInfo.DefaultName;
        lock (_lock)
        {
            if (_slots.TryGetValue(name, out var existing))
            {
                return existing;
            }
        }

        var info = Registry.Resolve(name, create);
        lock (_lock)
        {
            if (!_slots.TryGetValue(name, out var run))
            {
                run = new SlotRun(this, info, Leases.Get(name), _store, _logger, _claims, _checks);
                _slots[name] = run;
            }

            return run;
        }
    }

    /// <summary>
    ///     The slot a call of <paramref name="owner"/> means: the given one; else the only slot whose lease the owner holds;
    ///     else the default slot. Refused when the owner holds several and names none.
    /// </summary>
    public SlotRun SlotFor(string? owner, string? slot)
    {
        if (slot != null)
        {
            return Slot(slot);
        }

        var held = owner == null ? [] : Leases.HeldBy(owner);
        return held.Count switch
        {
            0 => Default,
            1 => Slot(held[0]),
            _ => throw new InvalidOperationException($"{owner} holds the leases of the slots {string.Join(", ", held)}; pass slot=<name>.")
        };
    }

    /// <summary>
    ///     Removes a slot created on first use (lane_remove): its run goes, its name is free, and its index is retired with
    ///     <paramref name="tenantDatabases"/> - kept back until its data is dropped (<see cref="SlotDataCleanup"/> frees it then)
    ///     or <see cref="ForgetRetiredIndexAsync"/>. Refused while the slot runs anything, for the default slot and for slots
    ///     of devstack.yaml. Touches no data itself.
    /// </summary>
    public SlotInfo? ForgetSlot(string name, IReadOnlyList<string>? tenantDatabases = null)
    {
        var known = Registry.Known().FirstOrDefault(k => k.Slot.Name == name);
        if (known.Slot == null)
        {
            return null;
        }

        if (known.Origin != "created")
        {
            throw new InvalidOperationException($"Slot '{name}' is {(known.Slot.IsDefault ? "the shared stack's" : "configured in devstack.yaml")}; it is not removed.");
        }

        lock (_lock)
        {
            if (_slots.TryGetValue(name, out var run))
            {
                if (run.Active)
                {
                    throw new InvalidOperationException($"Slot '{name}' still runs services; stop them first.");
                }

                _slots.Remove(name);
            }
        }

        // Only the facts are stored; the drop commands are generated when read (RetiredSlots), so they always use the current patterns.
        State.RetireSlot(name, known.Slot.Index, new RetiredSlot
        {
            Name = name, Prefix = known.Slot.Prefix, PortOffset = known.Slot.PortOffset, RetiredAt = DateTimeOffset.Now,
            TenantDatabases = tenantDatabases?.ToList()
        });
        _logger.LogInformation("Slot {Slot} removed; index {Index} retired, its data stays", name, known.Slot.Index);
        return known.Slot;
    }

    /// <summary>The retired indices with their leftovers and drop commands, generated now from the stored index, prefix and name.</summary>
    public Dictionary<int, RetiredSlot> RetiredSlots()
    {
        var config = _store.Load();
        return State.RetiredSlots().ToDictionary(r => r.Key, r => new RetiredSlot
        {
            Name = r.Value.Name, Prefix = r.Value.Prefix, PortOffset = r.Value.PortOffset, RetiredAt = r.Value.RetiredAt,
            TenantDatabases = r.Value.TenantDatabases,
            Leftovers = SlotCleanup.Leftovers(config, new SlotInfo(r.Value.Name, r.Key, r.Value.PortOffset, r.Value.Prefix), StateDirectory,
                r.Value.TenantDatabases, NameInUse(config, r.Value.Name))
        });
    }

    /// <summary>
    ///     Whether a stack or a lane of <paramref name="name"/> exists (again): the names that follow a slot's name - its state
    ///     folder, octo-cli installation and contexts, lane folder - then belong to it, not to a retired index of that name.
    /// </summary>
    internal bool NameInUse(DevStackConfig config, string name) =>
        Registry.Known().Any(k => k.Slot.Name == name) ||
        Discovery.EnvironmentDiscovery.Discover(config).Any(e => e.Slot == name || e.Name == name);

    /// <summary>
    ///     Un-retires an index once the developer confirmed its leftovers are dropped. Refused without the confirmation, for an
    ///     index that is not retired, and while anything still runs on it: a slot with that index, or a listener on one of its
    ///     shifted service ports.
    /// </summary>
    public async Task<RetiredSlot> ForgetRetiredIndexAsync(int index, bool confirmDataDropped)
    {
        var retired = State.RetiredSlots().GetValueOrDefault(index)
                      ?? throw new InvalidOperationException(
                          $"Index {index} is not retired. Retired: {(State.RetiredSlots().Count == 0 ? "none" : string.Join(", ", State.RetiredSlots().Keys.Order()))}.");
        if (!confirmDataDropped)
        {
            throw new InvalidOperationException(
                $"Index {index} (slot '{retired.Name}', prefix {retired.Prefix}) is retired because its data may remain; a new slot with that index " +
                "would find it. Drop the leftovers first (admin_slot_retired lists them with the commands), then call again with confirmDataDropped=true " +
                "- only when the developer confirms.");
        }

        if (Registry.Known().FirstOrDefault(k => k.Slot.Index == index).Slot is { } slot)
        {
            throw new InvalidOperationException($"Slot '{slot.Name}' uses index {index}.");
        }

        var open = await OpenPortsAsync(retired.PortOffset);
        if (open.Count > 0)
        {
            throw new InvalidOperationException($"Something still runs on the ports of index {index} ({string.Join(", ", open)}); stop it first.");
        }

        State.ForgetRetiredSlot(index);
        _logger.LogInformation("Retired index {Index} (slot {Slot}) forgotten; it may be handed out again", index, retired.Name);
        return retired;
    }

    /// <summary>The configured service ports shifted by <paramref name="portOffset"/> on which something listens.</summary>
    internal async Task<IReadOnlyList<int>> OpenPortsAsync(int portOffset)
    {
        var open = new List<int>();
        foreach (var port in _store.Load().Services.Values.SelectMany(s => s.Ports).Distinct().Select(p => p + portOffset))
        {
            if (await Probes.IsPortOpenAsync(port, TimeSpan.FromSeconds(1)))
            {
                open.Add(port);
            }
        }

        return open;
    }

    /// <summary>Un-retires an index whose data the daemon dropped (<see cref="SlotDataCleanup"/>): new slots may get it again.</summary>
    internal void FreeRetiredIndex(int index)
    {
        if (State.ForgetRetiredSlot(index))
        {
            _logger.LogInformation("Retired index {Index} freed: its data is dropped", index);
        }
    }

    /// <summary>Who started the default slot's stack (null without one).</summary>
    public string? StackOwner => Default.StackOwner;

    /// <summary>Stack processes the daemon did not start (Start-Octo, npm run start, leftovers); the pids of every slot are its own.</summary>
    public Task<ExternalSnapshot> ExternalAsync() => _external.ScanAsync(Runs.SelectMany(r => r.Pids()).ToHashSet());

    /// <summary>The profile an external group looks like, compared in the slot its ports point to.</summary>
    internal ProfileMatch? MatchExternal(DevStackConfig config, ExternalSnapshot external, ExternalGroup group)
    {
        if (config.Profiles.Count == 0)
        {
            return null;
        }

        var known = Registry.Known().Select(k => k.Slot).ToList();
        return ProfileMatcher.Best(config, ProfileMatcher.FromExternal(external, group), name => known.FirstOrDefault(k => k.Name == name));
    }

    /// <summary>Re-adopts processes of an earlier daemon run that are still alive (the default slot's stack).</summary>
    public void Restore(PersistedStack? persisted) => Default.Restore(persisted);

    /// <summary>Re-adopts the processes of every slot of an earlier daemon run.</summary>
    public void Restore(PersistedState persisted)
    {
        foreach (var (name, stack) in persisted.StacksBySlot().OrderBy(s => s.Key == SlotInfo.DefaultName ? 0 : 1))
        {
            try
            {
                Slot(name, create: true).Restore(stack);
            }
            catch (InvalidOperationException e)
            {
                _logger.LogWarning("Slot {Slot} of the previous run could not be restored: {Message}", name, e.Message);
            }
        }
    }

    /// <summary>Status of one slot; without a slot the default slot's status plus every slot in <see cref="StackStatus.Slots"/>.</summary>
    public async Task<StackStatus> StatusAsync(bool includeLogTail = true, string? slot = null)
    {
        if (slot != null && slot != SlotInfo.DefaultName)
        {
            var run = Slot(slot);
            var own = await run.StatusAsync(includeLogTail, ExternalSnapshot.Empty) with { Setup = SlotOperations.LastSetup(StateDirectory, run.Slot) };
            return WithRunsFrom(own, Lanes(_store.Load()));
        }

        var config = _store.Load();
        var status = WithRunsFrom(await Default.StatusAsync(includeLogTail), Lanes(config));
        var problems = ServicePlanner.FolderProblems(config, _store.ConfigPath);
        status = problems.Count == 0 ? status : status with { ConfigProblems = problems };
        return slot == null ? status with { Slots = await SummariesAsync() } : status;
    }

    /// <summary>The lanes whose worktrees a service may run from (<see cref="LaneSource.RunsFrom"/>); none when the root cannot be read.</summary>
    private static List<EnvironmentInfo> Lanes(DevStackConfig config)
    {
        try
        {
            return EnvironmentDiscovery.Discover(config);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            return [];
        }
    }

    private static StackStatus WithRunsFrom(StackStatus status, IReadOnlyList<EnvironmentInfo> lanes) => status with
    {
        Services = status.Services.Select(s => s with { RunsFrom = LaneSource.RunsFrom(s.RepoPath, status.BaseLane, lanes) }).ToList()
    };

    /// <summary>Every known slot in one line (used by stack_status, stack_list and the status page).</summary>
    public async Task<List<SlotSummary>> SummariesAsync()
    {
        var config = _store.Load();
        var lanes = Lanes(config);
        var result = new List<SlotSummary>();
        foreach (var (info, origin) in Registry.Known())
        {
            SlotRun? run;
            lock (_lock)
            {
                run = _slots.GetValueOrDefault(info.Name);
            }

            var status = run == null ? null : await run.StatusAsync(includeLogTail: false, ExternalSnapshot.Empty);
            var services = status?.Services.Select(s => new SlotServiceRow(s.Name, s.State, s.Pid, s.Ports, s.Source)
            {
                RepoPath = s.RepoPath, RunsFrom = LaneSource.RunsFrom(s.RepoPath, status.BaseLane, lanes), HealthDetail = s.HealthDetail,
                StartedAt = s.State == "stopped-for-build" ? null : s.StartedAt, StartedBy = s.StartedBy, StartedBySession = s.StartedBySession,
                StartedVia = s.StartedVia
            }).ToList() ?? [];
            var logDirectory = status?.Folder == null ? null : run!.CreateContext(config, status.Folder, status.Configuration).LogDirectory;
            var artifacts = info.IsDefault ? null : SlotArtifacts.PathsOf(SlotDeriver.SlotDirectory(State.Paths.StateDirectory, info));
            result.Add(new SlotSummary(info.Name, info.Index, info.PortOffset, info.Prefix, origin, status?.Running == true, status?.Folder,
                status?.StartedBy, (run?.Lease ?? Leases.Find(info.Name))?.Current()?.Owner, run?.Profile,
                services.Count(s => s.State == "healthy"), services.Count, services, logDirectory,
                artifacts != null && File.Exists(artifacts.Installation) ? artifacts : null)
            {
                Setup = info.IsDefault ? null : SlotOperations.LastSetup(StateDirectory, info),
                BaseLane = status?.BaseLane,
                Lane = status?.Lane
            });
        }

        return result;
    }

    /// <summary>The running stack of a slot for admin_profile_save(capture="daemon"); null when the slot runs no stack.</summary>
    public StackCapture? Capture(string? slot = null) => Slot(slot).Capture();

    /// <summary>Starts a stack in the slot of the spec (or the profile); an unknown slot name is created.</summary>
    /// <param name="owner">The lease owner (a lane's stack: lane:&lt;name&gt;).</param>
    /// <param name="caller">Who makes the call (owner and session), for the attribution of the stack and its services; default: <paramref name="owner"/>.</param>
    public Task<StartResult> StartStackAsync(string owner, StartSpec? adhoc, string? profile, bool replace, bool waitForHealthy, TimeSpan timeout,
        CancellationToken cancellationToken, StackCaller? caller = null)
    {
        var slot = ProfileResolver.Resolve(_store.Load(), profile, adhoc).Slot;
        return Slot(slot, create: true).StartStackAsync(owner, adhoc, profile, replace, waitForHealthy, timeout, cancellationToken, caller);
    }

    public Task<StartResult> StartServicesAsync(string owner, IReadOnlyList<string> names, IReadOnlyDictionary<string, ServiceOverride>? overrides,
        bool waitForHealthy, TimeSpan timeout, CancellationToken cancellationToken, string? slot = null, StackCaller? caller = null) =>
        (slot == null ? SlotFor(owner, null) : Slot(slot, create: true)).StartServicesAsync(owner, names, overrides, waitForHealthy, timeout, cancellationToken, caller);

    public Task<StopResult> StopServicesAsync(string owner, IReadOnlyList<string>? names, CancellationToken cancellationToken, string? slot = null) =>
        SlotFor(owner, slot).StopServicesAsync(owner, names, cancellationToken);

    public Task<StartResult> RestartServicesAsync(string owner, IReadOnlyList<string> names, IReadOnlyDictionary<string, ServiceOverride>? overrides,
        bool waitForHealthy, TimeSpan timeout, CancellationToken cancellationToken, string? slot = null, StackCaller? caller = null) =>
        SlotFor(owner, slot).RestartServicesAsync(owner, names, overrides, waitForHealthy, timeout, cancellationToken, caller);

    /// <summary>
    ///     Stops services for a build. Names are qualified ("slot/name" for slots other than the default); the result holds
    ///     the qualified names and overrides of every slot, for <see cref="StartAfterBuildAsync"/>.
    /// </summary>
    /// <param name="leaseOwnerOf">The lease owner per slot (a lane job: the caller for the shared stack, the lane for its own); default <paramref name="owner"/>.</param>
    public async Task<StoppedForBuild> StopForBuildAsync(string owner, IReadOnlyList<string> names, CancellationToken cancellationToken,
        Func<string, string>? leaseOwnerOf = null, Action<StoppedForBuild>? stoppedSoFar = null)
    {
        var names2 = new List<string>();
        var overrides = new Dictionary<string, ServiceOverride>();
        foreach (var group in names.Select(Unqualify).GroupBy(n => n.Slot))
        {
            var stopped = await Slot(group.Key).StopForBuildAsync(leaseOwnerOf?.Invoke(group.Key) ?? owner, group.Select(g => g.Name).ToList(), cancellationToken);
            names2.AddRange(stopped.Names.Select(n => Qualify(group.Key, n)));
            foreach (var (name, o) in stopped.Overrides)
            {
                overrides[Qualify(group.Key, name)] = o;
            }

            // What is stopped so far, after each slot: a later slot that throws must not hide these from the job's restart.
            stoppedSoFar?.Invoke(new StoppedForBuild(names2.ToList(), new Dictionary<string, ServiceOverride>(overrides)));
        }

        return new StoppedForBuild(names2, overrides);
    }

    /// <summary>Starts the services a build stopped again, slot by slot.</summary>
    /// <param name="leaseOwnerOf">The lease owner per slot, as for <see cref="StopForBuildAsync"/>.</param>
    public async Task<StartResult> StartAfterBuildAsync(string owner, StoppedForBuild stopped, CancellationToken cancellationToken,
        Func<string, string>? leaseOwnerOf = null)
    {
        StartResult? last = null;
        var warnings = new List<string>();
        var notes = new List<string>();
        var skipped = new List<string>();
        var notStarted = new List<string>();
        foreach (var group in stopped.Names.Select(n => (Qualified: n, Parts: Unqualify(n))).GroupBy(n => n.Parts.Slot).OrderBy(g => g.Key == SlotInfo.DefaultName ? 0 : 1))
        {
            var overrides = group.Where(g => stopped.Overrides.ContainsKey(g.Qualified))
                .ToDictionary(g => g.Parts.Name, g => stopped.Overrides[g.Qualified]);
            var result = await Slot(group.Key).StartAfterBuildAsync(leaseOwnerOf?.Invoke(group.Key) ?? owner,
                new StoppedForBuild(group.Select(g => g.Parts.Name).ToList(), overrides), cancellationToken);
            warnings.AddRange(result.Warnings.Select(w => group.Key == SlotInfo.DefaultName ? w : $"slot {group.Key}: {w}"));
            notes.AddRange(result.Notes);
            skipped.AddRange(result.Skipped);
            notStarted.AddRange((result.NotStarted ?? []).Select(n => Qualify(group.Key, n)));
            last = result;
        }

        return last == null
            ? new StartResult(await StatusAsync(), [], [], [])
            : new StartResult(last.Status, skipped, warnings, notes) { NotStarted = notStarted.Count > 0 ? notStarted : null };
    }

    /// <summary>Alive services (of every slot) whose repository folder is one of <paramref name="repoPaths"/>.</summary>
    public List<ServiceInstance> RunningIn(IEnumerable<string> repoPaths)
    {
        var repos = repoPaths.ToList();
        return Runs.SelectMany(r => r.RunningIn(repos)).ToList();
    }

    /// <summary>Alive services with their slot whose repository folder is one of <paramref name="repoPaths"/>.</summary>
    public List<(SlotRun Slot, ServiceInstance Instance)> RunningInSlots(IEnumerable<string> repoPaths)
    {
        var repos = repoPaths.ToList();
        return Runs.SelectMany(r => r.RunningIn(repos).Select(i => (r, i))).ToList();
    }

    /// <summary>The slots whose stack runs from <paramref name="lane"/> (alive or kept by a build).</summary>
    public List<SlotRun> SlotsInLane(string lane) =>
        Runs.Where(r => r.Checkout != null && PathScope.SamePath(r.Checkout, lane)).ToList();
}
