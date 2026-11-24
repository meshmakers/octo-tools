using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>What a starting slot is about to use, checked against the other slots (<see cref="SlotValidator"/>).</summary>
public sealed record SlotClaim(IReadOnlyDictionary<int, string> Ports, IReadOnlyDictionary<string, IReadOnlyList<string>?> IsolateKeys,
    IReadOnlyList<(ServicePlan Plan, string Base)> Plans, IReadOnlyDictionary<string, string> Tenants)
{
    /// <summary>The values the planned services use for <paramref name="keys"/> (unset counts as a value: the service default).</summary>
    public Dictionary<string, HashSet<string>> Values(IReadOnlyDictionary<string, IReadOnlyList<string>?> keys)
    {
        var result = keys.Keys.ToDictionary(k => k, _ => new HashSet<string>(StringComparer.Ordinal), StringComparer.Ordinal);
        foreach (var (plan, baseName) in Plans)
        {
            foreach (var (key, scope) in keys)
            {
                if (scope == null || scope.Contains(plan.Name) || scope.Contains(baseName))
                {
                    result[key].Add(plan.Env.GetValueOrDefault(key) ?? SlotRun.Unset);
                }
            }
        }

        return result;
    }

    /// <summary>The planned values of the slot's own isolate keys.</summary>
    public Dictionary<string, HashSet<string>> Isolation => Values(IsolateKeys);
}

/// <summary>
///     The services of one stack slot: its processes, the stack run (checkout, profile, instances, derived slot values),
///     start, stop, restart, status and persistence. Names inside a slot are unqualified; <see cref="StackSupervisor"/>
///     routes between slots and qualifies names outward ("slot/service" for slots other than the default).
/// </summary>
public sealed class SlotRun
{
    private static readonly TimeSpan StartingGrace = TimeSpan.FromSeconds(90);

    /// <summary>Shown for a key whose value is not set (the service uses its built-in default).</summary>
    public const string Unset = "(unset: the service default)";

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly StackSupervisor _host;
    private readonly LeaseManager _lease;
    private readonly ILogger _logger;
    private readonly Lock _lock = new();
    private readonly Dictionary<string, ServiceInstance> _services = new(StringComparer.Ordinal);

    /// <summary>
    ///     Services a build stopped: still part of the stack (state "stopped-for-build") with their last instance and override,
    ///     so service_restart / service_start bring them back the way they ran. Not persisted (a daemon restart forgets them).
    /// </summary>
    private readonly Dictionary<string, ServiceInstance> _stoppedForBuild = new(StringComparer.Ordinal);
    private readonly ConfigStore _store;
    private readonly LaneClaims? _claims;
    private readonly PreStartChecks? _checks;
    private StackRun? _stack;
    private SlotClaim? _reserved;

    internal SlotRun(StackSupervisor host, SlotInfo slot, LeaseManager lease, ConfigStore store, ILogger logger, LaneClaims? claims, PreStartChecks? checks)
    {
        _host = host;
        Slot = slot;
        _lease = lease;
        _store = store;
        _logger = logger;
        _claims = claims;
        _checks = checks;
        SlotDirectory = SlotDeriver.SlotDirectory(host.State.Paths.StateDirectory, slot);
    }

    public SlotInfo Slot { get; }

    public LeaseManager Lease => _lease;

    /// <summary>The claim resource of this slot (local-stack, local-stack-&lt;slot&gt;).</summary>
    public string ClaimResource => LaneClaims.ResourceOf(Slot.Name);

    /// <summary>&lt;state&gt;/slots/&lt;name&gt;: generated files of the slot (identity overlay, octo-cli installation).</summary>
    public string SlotDirectory { get; }

    private IBuildGuard? BuildGuard => _host.BuildGuard;

    /// <summary>A service name as shown outside the slot: plain in the default slot, "slot/name" elsewhere.</summary>
    public string Qualify(string name) => StackSupervisor.Qualify(Slot.Name, name);

    /// <summary>Pids of the slot's processes (alive or not).</summary>
    public List<int> Pids()
    {
        lock (_lock)
        {
            return _services.Values.Select(i => i.Pid).ToList();
        }
    }

    /// <summary>The slot's live services: name, recorded pid, who started it (lane_remove sorts the processes below a lane by them).</summary>
    public List<(string Service, int Pid, string? StartedBy)> LiveServices()
    {
        lock (_lock)
        {
            return _services.Values.Where(i => i.IsAlive).Select(i => (i.Plan.Name, i.Pid, i.Origin?.Owner)).ToList();
        }
    }

    /// <summary>
    ///     The services the slot runs, for the identity overlay: the live services' names and, for a profile instance, also the
    ///     configured service it is a copy of (its identityClients are the base service's). Null when nothing runs.
    /// </summary>
    public IReadOnlyCollection<string>? RunningServices()
    {
        lock (_lock)
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var instance in _services.Values.Where(i => i.IsAlive))
            {
                names.Add(instance.Plan.Name);
                if (_stack?.Instances.TryGetValue(instance.Plan.Name, out var of) == true && of.Of is { Length: > 0 } baseName)
                {
                    names.Add(baseName);
                }
            }

            return names.Count > 0 ? names : null;
        }
    }

    /// <summary>Whether the slot has a stack run (alive services, a stack kept by a build, or a start in progress).</summary>
    public bool Active
    {
        get
        {
            lock (_lock)
            {
                return _stack != null || _reserved != null || _services.Values.Any(i => i.IsAlive);
            }
        }
    }

    /// <summary>Whether a service of the slot is alive (a failed start leaves none: stack_start releases the lease it took).</summary>
    public bool AnyAlive
    {
        get
        {
            lock (_lock)
            {
                return _services.Values.Any(i => i.IsAlive);
            }
        }
    }

    /// <summary>
    ///     Waits until no start, stop or restart of the slot runs (AB#9673): lane_remove calls it after it marked the lane, so a
    ///     start that passed the removal check before the mark has either finished - and its services are stopped with the
    ///     stack - or sees the mark under the slot's gate and starts nothing.
    /// </summary>
    public async Task SettleAsync(CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        _gate.Release();
    }

    /// <summary>The lane the slot's stack runs from (null without a stack).</summary>
    public string? Checkout
    {
        get
        {
            lock (_lock)
            {
                return _stack?.Context.Checkout;
            }
        }
    }

    /// <summary>The profile the slot's stack was started from.</summary>
    public string? Profile
    {
        get
        {
            lock (_lock)
            {
                return _stack?.Profile;
            }
        }
    }

    private Task<ExternalSnapshot> ExternalAsync() => _host.ExternalAsync();

    /// <summary>How to start this slot: stack_start(lane=...) for a lane's stack, stack_start(owner) for the shared stack.</summary>
    internal string StartHint() =>
        Slot.IsDefault ? "stack_start(owner)"
        : EnvironmentBinding.OfSlot(_store.Load(), Slot.Name) is { } env ? $"stack_start(owner, lane=\"{env.Name}\")" : $"stack_start(owner, slot=\"{Slot.Name}\")";

    /// <summary>
    ///     The lane whose .octo/claims holds this slot's claim: the checkout, or for an environment its base lane - claims live
    ///     in the base lane only, never in the environment folder.
    /// </summary>
    private static string ClaimLane(StackContext context) => context.Base ?? context.Checkout;

    /// <summary>
    ///     The context of a start in this slot: other slots log into &lt;lane&gt;/logFiles/&lt;slot&gt;/; an environment's folder
    ///     is its own already, so its slot logs into &lt;env&gt;/logFiles.
    /// </summary>
    public StackContext CreateContext(DevStackConfig config, string? checkout, string? configuration)
    {
        // The slot of an environment runs from the environment's folder unless a checkout is given.
        checkout ??= Slot.IsDefault ? null : EnvironmentBinding.OfSlot(config, Slot.Name)?.Path;
        var context = ServicePlanner.CreateContext(config, checkout, configuration);
        return Slot.IsDefault || context.Environment != null ? context : context with { LogDirectory = Path.Combine(context.LogDirectory, Slot.Name) };
    }

    /// <summary>The slot's values for a materialized configuration (ports shifted, rows rendered).</summary>
    private SlotDerivation Derive(DevStackConfig materialized, IReadOnlyDictionary<string, ProfileInstance>? instances,
        IReadOnlyDictionary<string, string?>? explicitEnv) =>
        SlotDeriver.Apply(materialized, Slot, SlotDirectory, instances, explicitEnv);

    /// <summary>The configuration a running stack works with: instances materialized, provider toggles and slot values applied, fresh from disk.</summary>
    private DevStackConfig ConfigFor(StackRun? stack)
    {
        var derivation = Derive(ProfileResolver.Materialize(_store.Load(), stack?.Instances, stack?.EnvProviders), stack?.Instances, stack?.RequestEnv);
        if (stack != null)
        {
            stack.Derivation = derivation;
        }

        return derivation.Config;
    }

    /// <summary>Who started the slot's stack (null without one).</summary>
    public string? StackOwner
    {
        get
        {
            lock (_lock)
            {
                return _stack?.StartedBy;
            }
        }
    }

    /// <summary>Re-adopts processes of an earlier daemon run that are still alive.</summary>
    public void Restore(PersistedStack? persisted)
    {
        if (persisted == null)
        {
            return;
        }

        StackContext context;
        Dictionary<string, ProfileInstance> instances = new();
        Dictionary<string, bool> providers = new();
        Dictionary<string, string?> profileEnv = new();
        try
        {
            var config = _store.Load();
            context = CreateContext(config, persisted.Checkout, persisted.Configuration);
            if (persisted.Profile != null && config.Profiles.ContainsKey(persisted.Profile))
            {
                // Instances and provider toggles are not persisted (they may hold env values); the profile has them.
                var resolved = ProfileResolver.Resolve(config, persisted.Profile, new StartSpec { Slot = Slot.Name });
                instances = resolved.Instances.ToDictionary();
                providers = resolved.EnvProviders.ToDictionary();
                profileEnv = resolved.Environment.ToDictionary();
            }
        }
        catch (Exception e) when (e is InvalidOperationException or IOException)
        {
            var logDirectory = persisted.Services.Count > 0 ? Path.GetDirectoryName(persisted.Services[0].LogFile) ?? persisted.Checkout : persisted.Checkout;
            context = new StackContext("", persisted.Checkout, persisted.Configuration, "", logDirectory);
        }

        lock (_lock)
        {
            foreach (var s in persisted.Services)
            {
                var alive = ProcessTree.IsAlive(s.Pid);
                var gone = NotAdoptable(s, alive, alive ? ProcessTree.CommandLine(s.Pid) : "", alive ? ProcessTree.StartTime(s.Pid) : null);
                if (gone != null)
                {
                    _logger.LogInformation("Service {Service} (pid {Pid}) of the previous run is gone: {Reason}", Qualify(s.Name), s.Pid, gone);
                    continue;
                }

                _services[s.Name] = new ServiceInstance(PlanOf(s), s.Pid, s.StartedAt, s.ProcessStartTime) { Origin = OriginOf(s, persisted.StartedBy) };
                _logger.LogInformation("Adopted {Service} (pid {Pid})", Qualify(s.Name), s.Pid);
            }

            // Services a build stopped (it starts them again when it ends, from its job file): shown as stopped-for-build
            // again, and service_restart starts them like before the daemon restart (the source of a worktree is kept).
            foreach (var s in persisted.StoppedForBuild.Where(s => !_services.ContainsKey(s.Name)))
            {
                _stoppedForBuild[s.Name] = new ServiceInstance(PlanOf(s), s.Pid, s.StartedAt, s.ProcessStartTime) { Origin = OriginOf(s, persisted.StartedBy) };
                _logger.LogInformation("{Service} stays stopped for a build", Qualify(s.Name));
            }

            // Kept stack: persisted without services (a build stopped them all), or with services a build stopped while the
            // others ended meanwhile - service_restart and the build's end start those again in it.
            if (_services.Count > 0 || _stoppedForBuild.Count > 0 || persisted.Services.Count == 0)
            {
                _stack = new StackRun(context, persisted.StartedAt, persisted.StartedBy, null, new Dictionary<string, string?>())
                {
                    Profile = persisted.Profile,
                    ProfileHash = persisted.ProfileHash,
                    // Instances of the profile that run or that a build stopped: both must be materialized again.
                    Instances = instances.Where(i => _services.ContainsKey(i.Key) || _stoppedForBuild.ContainsKey(i.Key)).ToDictionary(),
                    EnvProviders = providers,
                    AdoptedEnv = profileEnv
                };
            }
        }

        if (_stack != null && !Slot.IsDefault)
        {
            try
            {
                // The slot's isolate keys for the checks against the other slots.
                ConfigFor(_stack);
            }
            catch (InvalidOperationException e)
            {
                _logger.LogWarning("Slot {Slot}: its derived values could not be worked out again: {Message}", Slot.Name, e.Message);
            }
        }

        if (_stack != null)
        {
            _claims?.Track(ClaimLane(_stack.Context), ClaimResource);
        }

        Persist();
    }

    /// <param name="external">The scan of processes outside the daemon; null scans (the default slot's status).</param>
    public async Task<StackStatus> StatusAsync(bool includeLogTail = true, ExternalSnapshot? external = null)
    {
        List<ServiceInstance> instances;
        List<ServiceInstance> stoppedForBuild;
        StackRun? stack;
        lock (_lock)
        {
            instances = _services.Values.OrderBy(i => i.StartedAt).ToList();
            stoppedForBuild = _stoppedForBuild.Values.ToList();
            stack = _stack;
        }

        var statuses = (await Task.WhenAll(instances.Select(i => DescribeAsync(i, includeLogTail))))
            .Concat(stoppedForBuild.Select(i => new ServiceStatus(i.Plan.Name, "stopped-for-build", false, "a build stopped it; service_restart starts it again",
                0, i.Plan.Source, i.Plan.RepoPath, i.Plan.WorkingDirectory, i.Plan.Command, i.Plan.Args, i.Plan.LogFile, i.Plan.Ports, i.StartedAt, i.ExitedAt,
                null, false, null) { StartedBy = i.Origin?.Owner, StartedBySession = i.Origin?.Session, StartedVia = i.Origin?.Via }))
            .ToArray();
        var running = new HashSet<string>(instances.Where(i => i.IsAlive).Select(i => i.Plan.Name));
        List<string> enabledNotRunning;
        ProfileMatch? profile = null;
        try
        {
            var config = _store.Load();
            enabledNotRunning = config.Services
                .Where(s => s.Value.Enabled && !running.Contains(s.Key) && (Slot.IsDefault || !SlotRules.IsExclusive(config, s.Key)))
                .Select(s => s.Key).ToList();
            if (external == null)
            {
                external = await ExternalAsync();
                external = external with { Groups = external.Groups.Select(g => g with { Profile = _host.MatchExternal(config, external, g) }).ToList() };
            }

            if (stack?.Profile != null && running.Count > 0)
            {
                var observed = new ObservedStack(stack.Context.Checkout, stack.Context.Configuration,
                    instances.Where(i => i.IsAlive).Select(i => new ObservedService(i.Plan.Name, i.Plan.RepoPath, i.Plan.Args, i.Plan.Ports)).ToList());
                profile = ProfileMatcher.Compare(config, stack.Profile, observed, stack.ProfileHash, _ => Slot);
            }
        }
        catch (InvalidOperationException)
        {
            enabledNotRunning = [];
        }

        return new StackStatus(running.Count > 0, stack?.Context.Checkout, stack?.Context.Configuration, stack?.StartedAt, stack?.StartedBy,
            _lease.Snapshot(), statuses, enabledNotRunning, external ?? ExternalSnapshot.Empty, profile,
            stack?.Instances.Count > 0 ? stack.Instances.ToDictionary(i => i.Key, i => i.Value.Of!) : null)
        {
            Slot = Slot.Name,
            BaseLane = stack == null ? null : stack.Context.Base ?? stack.Context.Checkout,
            Lane = stack?.Context.Environment
        };
    }

    /// <summary>The running stack for admin_profile_save(capture="daemon"); null when the slot runs no stack.</summary>
    public StackCapture? Capture()
    {
        lock (_lock)
        {
            if (_stack == null || !_services.Values.Any(i => i.IsAlive))
            {
                return null;
            }

            return new StackCapture(_stack.Context.Checkout, _stack.Context.Configuration, _stack.Profile, _stack.RequestEnv.ToDictionary(),
                _stack.Instances.ToDictionary(), _stack.EnvProviders.ToDictionary(),
                _services.Values.Where(i => i.IsAlive).OrderBy(i => i.StartedAt).Select(i => (i.Plan.Name, i.Override)).ToList())
            {
                Slot = Slot.Name
            };
        }
    }

    /// <summary>
    ///     Starts a new stack from a profile and/or ad-hoc arguments (ad-hoc wins). Fails while services of the slot are alive,
    ///     unless <paramref name="replace"/> stops the slot's stack first; processes the daemon did not start still refuse it.
    /// </summary>
    /// <param name="owner">The lease owner (a lane's stack: lane:&lt;name&gt;).</param>
    /// <param name="caller">Who makes the call, for the attribution of the stack and its services; default: <paramref name="owner"/>.</param>
    public async Task<StartResult> StartStackAsync(string owner, StartSpec? adhoc, string? profile, bool replace, bool waitForHealthy, TimeSpan timeout,
        CancellationToken cancellationToken, StackCaller? caller = null)
    {
        _lease.Require(owner);
        caller ??= new StackCaller(owner);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            _host.Removals.RefuseSlot(Slot.Name); // AB#9673: under the gate, so lane_remove's SettleAsync orders it (before a replace stops anything)
            var resolved = ProfileResolver.Resolve(_store.Load(), profile, adhoc);
            if (resolved.Slot != Slot.Name)
            {
                throw new InvalidOperationException($"The start is for slot '{resolved.Slot}', not '{Slot.Name}'.");
            }

            var derivation = Derive(resolved.Config, resolved.Instances, resolved.Environment);
            var config = derivation.Config;
            var context = CreateContext(config, resolved.Checkout, resolved.Configuration);
            _claims?.EnsureCanClaim(ClaimLane(context), owner, ClaimResource);
            var notes = new List<string>();
            var (services, leftOut) = LeaveOut(config, context, resolved);
            List<AddedService> added = [];
            if (resolved.Spec.Services is { Count: > 0 })
            {
                // A new stack: nothing runs (replace stops what does), so every dependency the named services wait for comes along.
                var exclude = resolved.Spec.Exclude ?? [];
                (added, var notAdded) = MissingDependencies(config, services, new HashSet<string>(), d =>
                    exclude.Contains(d) ? "the start excludes it"
                    : !Slot.IsDefault && SlotRules.IsExclusive(config, d) ? "it runs in the shared stack only"
                    : null);
                services.AddRange(added.Select(a => a.Service));
                if (DependencyNote(added, notAdded) is { } note)
                {
                    notes.Add(note);
                }
            }

            var serviceOverrides = resolved.Overrides.Where(o => services.Contains(o.Key)).ToDictionary(o => o.Key, o => o.Value);
            // AB#9673: a service that would start from a lane being removed - a source lane:<name> or a folder of it, from the call or
            // from a saved profile, or the stack's base lane inside it - is refused here, before the replace below stops anything.
            foreach (var name in services)
            {
                if (RemovingLaneOf(config, context, name, serviceOverrides.GetValueOrDefault(name)) is { } removing)
                {
                    _host.Removals.Refuse(removing);
                }
            }

            if (leftOut.Count > 0)
            {
                notes.Add($"Left out of {StackLabel()}: {string.Join("; ", leftOut.Select(l => $"{l.Service} ({l.Reason})"))}. leftOut says how to include one.");
            }

            List<string> alive;
            lock (_lock)
            {
                alive = _services.Values.Where(i => i.IsAlive).Select(i => i.Plan.Name).ToList();
            }

            if (alive.Count > 0)
            {
                if (!replace)
                {
                    throw new InvalidOperationException(
                        $"{Capitalized(StackLabel())} is already running from {_stack?.Context.Checkout} ({string.Join(", ", alive)}). " +
                        "Use service_start / service_restart to change it, stack_start with replace=true to switch, or stack_stop first.");
                }

                // Refuse before stopping anything: binaries of the new stack and ports held by processes the daemon did not start.
                var (_, _, missing) = CheckBinaries(config, context, services, serviceOverrides);
                if (missing.Count > 0)
                {
                    throw NotBuilt(context, missing);
                }

                var external = await ExternalAsync();
                var ports = services.SelectMany(n => config.Services[n].Ports).ToHashSet();
                var foreign = external.Services.Where(e => e.Ports.Any(ports.Contains)).ToList();
                if (foreign.Count > 0)
                {
                    throw new InvalidOperationException(
                        $"Processes octo-devstack did not start hold ports of the new stack ({string.Join(", ", foreign.Select(f => $"{f.Service} pid {f.Pid}"))}); " +
                        "the running stack was left alone. Stop them first.");
                }

                var stopped = await StopLockedAsync(null, cancellationToken);
                notes.Add($"Replaced the running stack ({string.Join(", ", stopped.Stopped)}).");
            }

            lock (_lock)
            {
                _services.Clear();
                _stoppedForBuild.Clear();
                _stack = null;
            }

            var stack = new StackRun(context, DateTimeOffset.Now, caller.Owner, null, new Dictionary<string, string?>(resolved.Environment))
            {
                Profile = resolved.Profile,
                ProfileHash = resolved.ProfileHash,
                Instances = resolved.Instances.ToDictionary(),
                EnvProviders = resolved.EnvProviders.ToDictionary(),
                Derivation = derivation
            };
            var result = await StartLockedAsync(config, stack, services, serviceOverrides, waitForHealthy, timeout, newStack: true,
                cancellationToken, resolved.RequireInfra, starters: Origins(services, caller.Origin(ServiceOrigin.StackStart)));
            return result with { Notes = [..notes, ..result.Notes], LeftOut = leftOut.Count > 0 ? leftOut : null, Added = added.Count > 0 ? added : null };
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>How the slot's stack is named to an agent: the shared stack, the stack of lane &lt;name&gt;, or slot &lt;name&gt;.</summary>
    internal string StackLabel() =>
        Slot.IsDefault ? "the shared stack"
        : EnvironmentBinding.OfSlot(_store.Load(), Slot.Name) is { } env ? $"the stack of lane '{env.Name}'"
        : $"the stack of slot '{Slot.Name}'";

    private static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];

    /// <summary>
    ///     What a start of every service (no service list given) leaves out in a non-default slot, because it cannot run there:
    ///     the services that run in the shared stack only (<see cref="ResolvedStart.Dropped"/>), and adapters whose tenant a
    ///     service of another running stack serves (a tenant's database is shared by every stack, see
    ///     <see cref="SlotValidator.AdmitAsync"/>). A start that names its services keeps the refusal. Nothing left: refused.
    /// </summary>
    private (List<string> Services, List<LeftOutService> LeftOut) LeaveOut(DevStackConfig config, StackContext context, ResolvedStart resolved)
    {
        var services = resolved.Services.ToList();
        var leftOut = resolved.Dropped
            .Select(n => new LeftOutService(n, "it runs in the shared stack only (fixed ports, redirect URIs and cookies of the frontends)",
                "Not in a lane stack: start it in the shared stack (stack_start or service_start without lane)."))
            .ToList();
        if (Slot.IsDefault || resolved.Spec.Services is { Count: > 0 })
        {
            return (services, leftOut);
        }

        // Every service of a tenant: two adapters may serve the same one, and all of them must stay out when another stack serves it.
        var tenants = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in services)
        {
            var plan = ServicePlanner.Plan(config, context, name, resolved.Overrides.GetValueOrDefault(name), new Dictionary<string, string?>());
            if (TenantOf(plan.Args) is { } tenant)
            {
                (tenants.TryGetValue(tenant, out var list) ? list : tenants[tenant] = []).Add(name);
            }
        }

        var firstOf = tenants.ToDictionary(t => t.Key, t => t.Value[0], StringComparer.OrdinalIgnoreCase);
        foreach (var (tenant, (holder, other)) in _host.Validator.ServedElsewhere(this, firstOf))
        {
            foreach (var name in tenants[tenant])
            {
                services.Remove(name);
            }

            foreach (var name in tenants[tenant])
            {
                var rest = services.Append(name).Select(n => $"'{n}'");
                leftOut.Add(new LeftOutService(name,
                    $"it would serve tenant '{tenant}', which {other.Qualify(holder)} of {other.StackLabel()} serves - a tenant's database is shared by every stack",
                    $"Name the services and give {name} another tenant: {StartHint().TrimEnd(')')}, services=[{string.Join(", ", rest)}], " +
                    $"overrides={{\"{name}\": {{\"variables\": {{\"tenantId\": \"<another tenant>\"}}}}}})."));
            }
        }

        if (services.Count == 0)
        {
            throw new InvalidOperationException(
                $"Nothing to start in {StackLabel()}: {string.Join("; ", leftOut.Select(l => $"{l.Service}: {l.Reason}. {l.Include}"))}");
        }

        return (services, leftOut);
    }

    /// <summary>
    ///     The startAfter dependencies (transitively) of the services a start names that are neither named nor in
    ///     <paramref name="present"/> (alive in the slot): a start brings them, so a named service does not start without the
    ///     services it waits for. <paramref name="refuse"/> gives the reason a dependency cannot be added (excluded, shared stack
    ///     only, stopped for a build) - it is not added and neither are its own dependencies; the dependent then starts without
    ///     waiting for it, as before. Pure.
    /// </summary>
    internal static (List<AddedService> Added, List<string> NotAdded) MissingDependencies(DevStackConfig config, IReadOnlyCollection<string> names,
        IReadOnlySet<string> present, Func<string, string?> refuse)
    {
        var dependents = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        var order = new List<string>();
        var refused = new Dictionary<string, string>(StringComparer.Ordinal);
        var queue = new Queue<string>(names);
        var seen = names.ToHashSet(StringComparer.Ordinal);
        while (queue.TryDequeue(out var name))
        {
            if (!config.Services.TryGetValue(name, out var service))
            {
                continue;
            }

            foreach (var dependency in service.StartAfter.Where(d => config.Services.ContainsKey(d) && !names.Contains(d) && !present.Contains(d)))
            {
                if (!dependents.TryGetValue(dependency, out var list))
                {
                    dependents[dependency] = list = [];
                }

                list.Add(name);
                if (!seen.Add(dependency))
                {
                    continue;
                }

                if (refuse(dependency) is { } reason)
                {
                    refused[dependency] = reason;
                    continue;
                }

                order.Add(dependency);
                queue.Enqueue(dependency);
            }
        }

        static string Because(List<string> by) => $"{string.Join(", ", by)} start{(by.Count == 1 ? "s" : "")} after it";
        return (order.Select(d => new AddedService(d, Because(dependents[d]))).ToList(),
            refused.Select(r => $"{r.Key} ({Because(dependents[r.Key])}) was not added: {r.Value}").ToList());
    }

    /// <summary>The note of a start that added dependencies or could not add one; null when neither.</summary>
    private static string? DependencyNote(List<AddedService> added, List<string> notAdded)
    {
        var parts = new List<string>();
        if (added.Count > 0)
        {
            parts.Add($"Added {string.Join(", ", added.Select(a => $"{a.Service} ({a.Because})"))}: a named service brings the startAfter " +
                      "dependencies that do not run in the stack yet (added lists them).");
        }

        if (notAdded.Count > 0)
        {
            parts.Add($"{string.Join("; ", notAdded)}; the services after it start without waiting for it.");
        }

        return parts.Count == 0 ? null : string.Join(" ", parts);
    }

    /// <summary>Adds services to the running stack (or starts a stack from the base lane with just these).</summary>
    /// <param name="caller">Who makes the call, for the attribution of the services; default: <paramref name="owner"/>.</param>
    public async Task<StartResult> StartServicesAsync(string owner, IReadOnlyList<string> names, IReadOnlyDictionary<string, ServiceOverride>? overrides,
        bool waitForHealthy, TimeSpan timeout, CancellationToken cancellationToken, StackCaller? caller = null)
    {
        _lease.Require(owner);
        caller ??= new StackCaller(owner);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            StackRun stack;
            bool newStack;
            HashSet<string> alive;
            HashSet<string> stopped;
            lock (_lock)
            {
                // A stack run kept by a build (all services stopped for it) is still the current stack: its checkout,
                // profile, instances and overrides apply.
                newStack = _stack == null;
                stack = newStack
                    ? new StackRun(CreateContext(_store.Load(), null, null), DateTimeOffset.Now, caller.Owner, null, new Dictionary<string, string?>())
                    : _stack!;
                alive = _services.Values.Where(i => i.IsAlive).Select(i => i.Plan.Name).ToHashSet(StringComparer.Ordinal);
                stopped = _stoppedForBuild.Keys.ToHashSet(StringComparer.Ordinal);
            }

            // The startAfter dependencies of the named services that do not run in the stack come along (in the shared stack
            // they normally run already); one a build stopped is started again by that build.
            var config = ConfigFor(stack);
            var (added, notAdded) = MissingDependencies(config, names, alive, d =>
                stopped.Contains(d) ? "a build or test run stopped it and starts it again when it ends"
                : !Slot.IsDefault && SlotRules.IsExclusive(config, d) ? "it runs in the shared stack only"
                : null);
            names = [..names, ..added.Select(a => a.Service)];

            // Before the overrides of a service a build stopped are merged in: only the caller's own overrides make it the origin.
            var origins = Origins(names, caller.Origin(ServiceOrigin.ServiceStart), overrides, keepStopped: true);
            lock (_lock)
            {
                // A service a build stopped starts the way it ran unless new overrides are given - also one restored after a
                // daemon restart, which keeps only its source (the worktree), like an adopted service.
                var previous = names.Distinct()
                    .Where(n => overrides?.ContainsKey(n) != true && _stoppedForBuild.TryGetValue(n, out var i) && (i.Override != null || (i.Adopted && i.Plan.Source != null)))
                    .ToDictionary(n => n, n => _stoppedForBuild[n].Override ?? new ServiceOverride { Source = _stoppedForBuild[n].Plan.Source });
                if (previous.Count > 0)
                {
                    overrides = new Dictionary<string, ServiceOverride>(overrides ?? new Dictionary<string, ServiceOverride>()).Concat(previous)
                        .ToDictionary(p => p.Key, p => p.Value);
                }
            }

            if (newStack)
            {
                _claims?.EnsureCanClaim(ClaimLane(stack.Context), owner, ClaimResource);
            }

            var result = await StartLockedAsync(config, stack, names.Distinct().ToList(), overrides, waitForHealthy, timeout, newStack, cancellationToken,
                starters: origins);
            return DependencyNote(added, notAdded) is { } note
                ? result with { Notes = [note, ..result.Notes], Added = added.Count > 0 ? added : null }
                : result;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<StopResult> StopServicesAsync(string owner, IReadOnlyList<string>? names, CancellationToken cancellationToken)
    {
        _lease.Require(owner);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            return await StopLockedAsync(names, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Stops and starts services again from the same folders. Without new overrides the previous ones are reused.</summary>
    /// <param name="caller">Who makes the call, for the attribution of the services it overrides; default: <paramref name="owner"/>.</param>
    public async Task<StartResult> RestartServicesAsync(string owner, IReadOnlyList<string> names, IReadOnlyDictionary<string, ServiceOverride>? overrides,
        bool waitForHealthy, TimeSpan timeout, CancellationToken cancellationToken, StackCaller? caller = null)
    {
        _lease.Require(owner);
        caller ??= new StackCaller(owner);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            StackRun stack;
            Dictionary<string, ServiceOverride> effective;
            lock (_lock)
            {
                if (_stack == null)
                {
                    throw new InvalidOperationException($"{Capitalized(StackLabel())} is not running. Use {StartHint()}.");
                }

                stack = _stack;
                effective = EffectiveOverridesLocked(names, overrides);
            }

            // AB#9673: refused before anything stops - also a restart without overrides, which keeps a lane source.
            var restartConfig = ConfigFor(stack);
            foreach (var name in names)
            {
                if (RemovingLaneOf(restartConfig, stack.Context, name, effective.GetValueOrDefault(name)) is { } removing)
                {
                    _host.Removals.Refuse(removing);
                }
            }

            // A restart that keeps the previous overrides keeps who chose them; new overrides make the caller the origin.
            var origins = Origins(names, caller.Origin(ServiceOrigin.ServiceRestart), overrides, keepRunning: true, keepStopped: true);

            List<string> running;
            lock (_lock)
            {
                running = names.Where(_services.ContainsKey).Distinct().ToList(); // the others were stopped by a build
            }

            if (running.Count > 0)
            {
                await StopLockedAsync(running, cancellationToken, keepStack: true);
            }

            return await StartLockedAsync(ConfigFor(stack), stack, names.Distinct().ToList(), effective, waitForHealthy, timeout, newStack: false, cancellationToken,
                starters: origins);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>The overrides a restart keeps: new ones win, else the previous override, else the source of an adopted service.</summary>
    private Dictionary<string, ServiceOverride> EffectiveOverridesLocked(IReadOnlyList<string> names, IReadOnlyDictionary<string, ServiceOverride>? overrides)
    {
        var effective = new Dictionary<string, ServiceOverride>();
        foreach (var name in names)
        {
            if (!_services.TryGetValue(name, out var instance) && !_stoppedForBuild.TryGetValue(name, out instance))
            {
                throw new InvalidOperationException($"Service '{name}' is not part of the stack{(Slot.IsDefault ? "" : $" in slot '{Slot.Name}'")}. Use service_start.");
            }

            if (overrides?.TryGetValue(name, out var o) == true)
            {
                effective[name] = o;
            }
            else if (instance.Override != null)
            {
                effective[name] = instance.Override;
            }
            else if (instance.Adopted && instance.Plan.Source != null)
            {
                effective[name] = new ServiceOverride { Source = instance.Plan.Source };
            }
        }

        return effective;
    }

    /// <summary>
    ///     Stops services for a build and remembers how to start them again (<see cref="StartAfterBuildAsync"/>): the stack run
    ///     (checkout, profile instances, provider toggles) is kept, the overrides (worktree sources) are captured like a restart.
    /// </summary>
    public async Task<StoppedForBuild> StopForBuildAsync(string owner, IReadOnlyList<string> names, CancellationToken cancellationToken)
    {
        _lease.Require(owner);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            Dictionary<string, ServiceOverride> effective;
            List<string> present;
            lock (_lock)
            {
                present = names.Where(_services.ContainsKey).Distinct().ToList();
                effective = EffectiveOverridesLocked(present, null);
            }

            Dictionary<string, ServiceInstance> last;
            lock (_lock)
            {
                last = present.ToDictionary(n => n, n => _services[n]);
            }

            if (present.Count > 0)
            {
                await StopLockedAsync(present, cancellationToken, keepStack: true);
                lock (_lock)
                {
                    foreach (var (name, instance) in last)
                    {
                        _stoppedForBuild[name] = instance;
                    }
                }

                // A daemon restart during the build must still know them (see PersistedStack.StoppedForBuild). A failed state write
                // must not hide them from the job, which restarts them: logged, and the answer still names them.
                try
                {
                    Persist();
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    _logger.LogWarning(e, "The state of slot {Slot} could not be written after stopping {Services} for a build", Slot.Name, string.Join(", ", present));
                }
            }

            return new StoppedForBuild(present, effective);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>Starts the services a build stopped, with their overrides, in the kept stack run (or a new one when it is gone).</summary>
    public async Task<StartResult> StartAfterBuildAsync(string owner, StoppedForBuild stopped, CancellationToken cancellationToken)
    {
        _lease.Require(owner);
        await _gate.WaitAsync(cancellationToken);
        try
        {
            StackRun stack;
            bool newStack;
            lock (_lock)
            {
                newStack = _stack == null;
                stack = _stack ?? new StackRun(CreateContext(_store.Load(), null, null), DateTimeOffset.Now, owner, null,
                    new Dictionary<string, string?>());
            }

            if (newStack)
            {
                _claims?.EnsureCanClaim(ClaimLane(stack.Context), owner, ClaimResource);
            }

            // AB#9673: a service that ran from a lane being removed (its source lane:<name>, a folder of the lane, or the lane's own
            // stack) is not started again; the job's other services are.
            var config = ConfigFor(stack);
            var notStarted = stopped.Names.Distinct()
                .Select(n => (Name: n, Lane: RemovingLaneOf(config, stack.Context, n, stopped.Overrides.GetValueOrDefault(n))))
                .Where(x => x.Lane != null).ToList();
            // A service that starts after one left out stays stopped with it (it would start without its dependency).
            for (var added = true; added;)
            {
                added = false;
                foreach (var n in stopped.Names.Distinct().Where(n => notStarted.All(x => x.Name != n)).ToList())
                {
                    if (config.Services.TryGetValue(n, out var service) && notStarted.FirstOrDefault(x => service.StartAfter.Contains(x.Name)) is { Name: not null } dependency)
                    {
                        notStarted.Add((n, dependency.Lane));
                        added = true;
                    }
                }
            }

            var names = stopped.Names.Distinct().Where(n => notStarted.All(x => x.Name != n)).ToList();
            string? note = null;
            if (notStarted.Count > 0)
            {
                lock (_lock)
                {
                    foreach (var (name, _) in notStarted)
                    {
                        _stoppedForBuild.Remove(name);
                    }
                }

                note = $"Not started again after the job: {string.Join(", ", notStarted.Select(x => $"{x.Name} (lane '{x.Lane}' is being removed)"))}.";
            }

            var notStartedNames = notStarted.Count > 0 ? notStarted.Select(x => x.Name).ToList() : null;
            if (names.Count == 0)
            {
                return new StartResult(await StatusAsync(false), [], [], note != null ? [note] : []) { NotStarted = notStartedNames };
            }

            // The result does not wait for health, but startAfter dependencies get a real timeout. The services keep who
            // started them: the build only stopped them.
            var result = await StartLockedAsync(config, stack, names, stopped.Overrides.Where(o => names.Contains(o.Key)).ToDictionary(),
                waitForHealthy: false, StackSupervisor.RestartDependencyTimeout, newStack, cancellationToken, bypassBuildGuard: true,
                starters: Origins(names, new ServiceOrigin(owner, ServiceOrigin.AfterBuild), null, keepStopped: true));
            return note == null ? result : result with { Notes = [note, ..result.Notes], NotStarted = notStartedNames };
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>The pid and launch environment of a running service (empty for a service adopted after a daemon restart); null when it does not run.</summary>
    public (int Pid, IReadOnlyDictionary<string, string?> Env)? EnvOf(string name)
    {
        lock (_lock)
        {
            return _services.TryGetValue(name, out var i) && i.IsAlive ? (i.Pid, i.Plan.Env) : null;
        }
    }

    /// <summary>Alive services whose repository folder is one of <paramref name="repoPaths"/> (nested worktrees excluded, see <see cref="PathScope.IsInRepo"/>).</summary>
    public List<ServiceInstance> RunningIn(IEnumerable<string> repoPaths)
    {
        var repos = repoPaths.ToList();
        lock (_lock)
        {
            return _services.Values.Where(i => i.IsAlive && repos.Any(r => PathScope.IsInRepo(i.Plan.RepoPath, r))).ToList();
        }
    }

    // ---------- what the slot uses (checked against the other slots) ----------

    /// <summary>Ports of the alive services and of a start in progress, with the service holding them.</summary>
    public Dictionary<int, string> PortsInUse()
    {
        lock (_lock)
        {
            var ports = new Dictionary<int, string>();
            foreach (var i in _services.Values.Where(i => i.IsAlive))
            {
                foreach (var port in i.Plan.Ports)
                {
                    ports.TryAdd(port, i.Plan.Name);
                }
            }

            foreach (var (port, service) in _reserved?.Ports ?? new Dictionary<int, string>())
            {
                ports.TryAdd(port, service);
            }

            return ports;
        }
    }

    /// <summary>The isolate keys of the slot's derivation (empty for the default slot), with their service scope.</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>?> IsolateKeys()
    {
        lock (_lock)
        {
            return _reserved?.IsolateKeys ?? _stack?.Derivation?.IsolateKeys ?? new Dictionary<string, IReadOnlyList<string>?>();
        }
    }

    /// <summary>Adapter tenants of the alive services and of a start in progress (tenant -> service).</summary>
    public Dictionary<string, string> Tenants()
    {
        lock (_lock)
        {
            var tenants = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var i in _services.Values.Where(i => i.IsAlive))
            {
                if (TenantOf(i.Plan.Args) is { } tenant)
                {
                    tenants.TryAdd(tenant, i.Plan.Name);
                }
            }

            foreach (var (tenant, service) in _reserved?.Tenants ?? new Dictionary<string, string>())
            {
                tenants.TryAdd(tenant, service);
            }

            return tenants;
        }
    }

    /// <summary>
    ///     The values the slot's services use for <paramref name="keys"/> (null scope: every service; else the services of the
    ///     scope and their instances). Services started by this daemon report their planned env; adopted ones the env derived
    ///     again from the configuration and the profile (provider output is not known after a daemon restart).
    /// </summary>
    public Dictionary<string, HashSet<string>> IsolationValues(IReadOnlyDictionary<string, IReadOnlyList<string>?> keys)
    {
        List<ServiceInstance> alive;
        StackRun? stack;
        SlotClaim? reserved;
        lock (_lock)
        {
            alive = _services.Values.Where(i => i.IsAlive).ToList();
            stack = _stack;
            reserved = _reserved;
        }

        var result = keys.Keys.ToDictionary(k => k, _ => new HashSet<string>(StringComparer.Ordinal), StringComparer.Ordinal);
        if (stack == null && reserved == null)
        {
            return result;
        }

        DevStackConfig? adoptedConfig = null;
        foreach (var instance in alive)
        {
            IReadOnlyDictionary<string, string?> env = instance.Plan.Env;
            if (instance.Adopted && stack != null)
            {
                try
                {
                    adoptedConfig ??= ConfigFor(stack);
                    var stackEnv = ServicePlanner.StackEnv(adoptedConfig, alive.Select(a => a.Plan.Name).Where(adoptedConfig.Services.ContainsKey),
                        new Dictionary<string, string?>(), stack.Derivation?.Env ?? new Dictionary<string, string>(), stack.AdoptedEnv);
                    env = adoptedConfig.Services.ContainsKey(instance.Plan.Name)
                        ? ServicePlanner.Plan(adoptedConfig, stack.Context, instance.Plan.Name, instance.Override, stackEnv).Env
                        : env;
                }
                catch (InvalidOperationException)
                {
                    // The configuration changed under the adopted service; compare what is known.
                }
            }

            var baseName = stack?.Instances.TryGetValue(instance.Plan.Name, out var i) == true ? i.Of! : instance.Plan.Name;
            foreach (var (key, scope) in keys)
            {
                if (scope == null || scope.Contains(instance.Plan.Name) || scope.Contains(baseName))
                {
                    result[key].Add(env.GetValueOrDefault(key) ?? Unset);
                }
            }
        }

        foreach (var (key, values) in reserved?.Values(keys) ?? new Dictionary<string, HashSet<string>>())
        {
            result[key].UnionWith(values);
        }

        return result;
    }

    internal static string? TenantOf(IReadOnlyList<string> args)
    {
        foreach (var arg in args)
        {
            foreach (var prefix in new[] { "--Adapter:DedicatedTenantId=", "--Adapter:TenantId=" })
            {
                if (arg.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) && arg.Length > prefix.Length)
                {
                    return arg[prefix.Length..];
                }
            }
        }

        return null;
    }

    // ---------- start ----------

    /// <summary>
    ///     Who each service of a start counts as started by (<see cref="ServiceOrigin"/>): <paramref name="caller"/> for a service
    ///     <paramref name="newOverrides"/> names or that has no earlier instance to keep, else the earlier instance's origin - a
    ///     running one (<paramref name="keepRunning"/>, a restart) or one a build stopped (<paramref name="keepStopped"/>).
    /// </summary>
    private Dictionary<string, ServiceOrigin> Origins(IEnumerable<string> names, ServiceOrigin caller, IReadOnlyDictionary<string, ServiceOverride>? newOverrides = null,
        bool keepRunning = false, bool keepStopped = false)
    {
        var origins = new Dictionary<string, ServiceOrigin>();
        lock (_lock)
        {
            foreach (var name in names)
            {
                var earlier = newOverrides?.ContainsKey(name) == true
                    ? null
                    : (keepRunning ? _services.GetValueOrDefault(name) : null) ?? (keepStopped ? _stoppedForBuild.GetValueOrDefault(name) : null);
                origins[name] = earlier?.Origin ?? caller;
            }
        }

        return origins;
    }

    /// <summary>
    ///     The lane being removed a service would start from (AB#9673): the slot's own lane, the lane of a 'lane:&lt;name&gt;'
    ///     source, or the lane whose folder or repo path holds the source or the folder the service runs from. Null: none.
    /// </summary>
    private string? RemovingLaneOf(DevStackConfig config, StackContext context, string name, ServiceOverride? o)
    {
        if (!_host.Removals.Any)
        {
            return null;
        }

        if (_host.Removals.OfSlot(Slot.Name) is { } own)
        {
            return own.Lane;
        }

        if (o?.Source is { } source)
        {
            if (LaneSource.Is(source))
            {
                if (_host.Removals.Of(source[LaneSource.Prefix.Length..].Trim()) is { } byName)
                {
                    return byName.Lane;
                }
            }
            else if (_host.Removals.LaneOfPath(source) is { } bySource)
            {
                return bySource;
            }
        }

        if (!config.Services.ContainsKey(name))
        {
            return null;
        }

        try
        {
            return _host.Removals.LaneOfPath(ServicePlanner.Plan(config, context, name, o, new Dictionary<string, string?>()).RepoPath);
        }
        catch (InvalidOperationException)
        {
            // A source that does not resolve (a lane whose manifest is gone) is refused by the start itself.
            return null;
        }
    }

    private async Task<StartResult> StartLockedAsync(DevStackConfig config, StackRun stack, List<string> names,
        IReadOnlyDictionary<string, ServiceOverride>? overrides, bool waitForHealthy, TimeSpan timeout, bool newStack,
        CancellationToken cancellationToken, bool requireInfra = false, bool bypassBuildGuard = false, IReadOnlyDictionary<string, ServiceOrigin>? starters = null)
    {
        var skipped = new List<string>();
        var warnings = new List<string>();
        var notes = new List<string>();

        foreach (var name in names.Where(n => !config.Services.ContainsKey(n)))
        {
            throw new InvalidOperationException($"Unknown service '{name}'. Configured: {string.Join(", ", config.Services.Keys)}.");
        }

        foreach (var key in overrides?.Keys ?? [])
        {
            if (!names.Contains(key))
            {
                throw new InvalidOperationException($"Override for '{key}', but '{key}' is not started by this call.");
            }
        }

        if (names.Count == 0)
        {
            throw new InvalidOperationException("No services to start.");
        }

        if (!Slot.IsDefault)
        {
            var exclusive = names.Where(n => SlotRules.IsExclusive(config, n)).ToList();
            if (exclusive.Count > 0)
            {
                throw new InvalidOperationException($"{string.Join(", ", exclusive)} run(s) in the shared stack only; leave them out of the stack of slot '{Slot.Name}'.");
            }
        }

        HashSet<string> alreadyRunning;
        lock (_lock)
        {
            alreadyRunning = _services.Values.Where(i => i.IsAlive).Select(i => i.Plan.Name).ToHashSet();
            foreach (var name in names)
            {
                if (alreadyRunning.Contains(name))
                {
                    throw new InvalidOperationException($"Service '{name}' is already running. Use service_restart.");
                }

                // A crashed entry is replaced by the new start.
                _services.Remove(name);
            }
        }

        ServiceOverride? OverrideOf(string n) => overrides?.GetValueOrDefault(n);

        // AB#9673: every start runs under the slot's gate, so this check and lane_remove's SettleAsync are ordered: nothing starts
        // in the stack of a lane being removed, nor from its folders - also with a source the stack kept (a restart without
        // overrides, an adopted service, the restart after a build).
        foreach (var name in names)
        {
            if (RemovingLaneOf(config, stack.Context, name, OverrideOf(name)) is { } removing)
            {
                _host.Removals.Refuse(removing);
            }
        }

        // Preflight with an empty stack env: folders, binaries, ports.
        var (toStart, skippedNow, missing) = CheckBinaries(config, stack.Context, names, overrides);
        skipped.AddRange(skippedNow);
        if (missing.Count > 0)
        {
            throw NotBuilt(stack.Context, missing);
        }

        if (!bypassBuildGuard && BuildGuard is { } guard)
        {
            foreach (var name in toStart)
            {
                var repoPath = ServicePlanner.Plan(config, stack.Context, name, OverrideOf(name), new Dictionary<string, string?>()).RepoPath;
                if (guard.Blocking(repoPath) is { } hit)
                {
                    throw new InvalidOperationException(
                        $"{name} runs out of {repoPath}, which job {hit.JobId} ({(hit.TestRun ? "a test run" : "a build")} of {hit.Owner}: {hit.Target}) is " +
                        $"working on{(hit.TestRun ? " - the run stopped the services of that repository and starts them again when it ends" : "")}. " +
                        $"Wait for the job to end (job_status(\"{hit.JobId}\", waitSeconds=600)) and start {name} afterwards.");
                }
            }
        }

        // Other slots first: their services may still be starting (port not open yet), and the message names the slot.
        _host.Validator.CheckPorts(this, toStart.SelectMany(n => config.Services[n].Ports.Select(p => (p, n))).ToList());

        var conflicts = new List<string>();
        var origins = new List<string>();
        ExternalSnapshot? external = null;
        foreach (var name in toStart)
        {
            foreach (var port in config.Services[name].Ports)
            {
                if (await Probes.IsPortOpenAsync(port, TimeSpan.FromMilliseconds(500)))
                {
                    var holders = ProcessTree.ListeningPids(port).Select(pid => $"pid {pid}: {Shorten(ProcessTree.CommandLine(pid))}").ToList();
                    conflicts.Add($"{name} port {port} is in use ({(holders.Count == 0 ? "unknown process" : string.Join("; ", holders))})");
                    external ??= await ExternalAsync();
                    var holder = external.Services.FirstOrDefault(e => e.Ports.Contains(port));
                    var group = holder == null ? null : external.Groups.FirstOrDefault(g => g.Key == holder.Group);
                    if (group != null)
                    {
                        origins.Add($"{group.Origin.Description}{(group.Origin.StopHint != null ? $"; stop it with: {group.Origin.StopHint}" : "")}");
                    }
                }
            }
        }

        if (conflicts.Count > 0)
        {
            var who = origins.Count > 0 ? string.Join(". ", origins.Distinct()) : "Probably a Start-Octo in a terminal or a stack the daemon does not know";
            throw new InvalidOperationException($"{string.Join(". ", conflicts)}. {who}. Stop it first.");
        }

        if (newStack && _checks != null)
        {
            var unreachable = await _checks.UnreachableInfraAsync();
            if (unreachable.Count > 0)
            {
                var text = $"The kind infrastructure does not answer: {string.Join(", ", unreachable)}. Start Docker and the cluster's node container " +
                           $"(docker start {PreStartChecks.KindNodeContainer} for the default cluster; Get-OctoKubernetesStatus names it), or create it " +
                           "(Install-OctoKubernetes) - infra_status shows its state.";
                if (requireInfra)
                {
                    throw new InvalidOperationException(text + " The profile sets requireInfra, so nothing was started.");
                }

                warnings.Add(text);
            }
            else if (EnvProviderRunner.Applicable(config, alreadyRunning.Concat(toStart).ToList()).Contains(SettingsMap.S3Provider) &&
                     !await _checks.S3StoreAnswersAsync())
            {
                // Optional, as in Start-Octo: without the local S3 store the bot keeps its artifacts in the file system (a
                // cluster created before the store existed has none). Not a warning, and requireInfra does not refuse it.
                notes.Add($"No local S3 store answers on 127.0.0.1:{_checks.S3StorePort}: the bot keeps its artifacts in the file system. " +
                          "Install-OctoKubernetesS3Store adds the store to the kind cluster.");
            }
        }

        // Stack env: providers once per stack (re-run when a later start needs a provider that did not run yet),
        // announced URLs of everything that will run, the slot's derived rows, then the env of the stack start.
        var allServices = alreadyRunning.Concat(toStart).ToHashSet();
        if (stack.ProviderEnv == null || EnvProviderRunner.Applicable(config, allServices).Except(stack.ProvidersRan).Any())
        {
            var providerResult = await EnvProviderRunner.RunAsync(config, allServices, cancellationToken);
            stack.ProviderEnv = providerResult.Env;
            stack.ProvidersRan = providerResult.Ran;
            warnings.AddRange(providerResult.Warnings);
        }

        var stackEnv = ServicePlanner.StackEnv(config, allServices, stack.ProviderEnv, stack.Derivation?.Env ?? new Dictionary<string, string>(), stack.RequestEnv);

        if (!newStack && alreadyRunning.Count > 0)
        {
            var announced = toStart.SelectMany(n => config.Services[n].AnnounceEnv.Keys).ToList();
            if (announced.Count > 0)
            {
                notes.Add($"{string.Join(", ", announced)} is only seen by services started from now on; restart the services that read it (e.g. platformServices).");
            }
        }

        // Plan everything, then admit the start against the other slots (ports, isolated data, tenants) and reserve it.
        var plans = toStart.ToDictionary(n => n, n => ServicePlanner.Plan(config, stack.Context, n, OverrideOf(n), stackEnv));
        var isolateKeys = stack.Derivation?.IsolateKeys ?? new Dictionary<string, IReadOnlyList<string>?>();
        var claim = PlannedClaim(plans.Values.ToList(), stack, isolateKeys);
        if (!Slot.IsDefault)
        {
            SlotValidator.CheckAgainstDefault(Slot, config, claim);
        }

        await _host.Validator.AdmitAsync(this, claim, cancellationToken);
        try
        {
            if (newStack)
            {
                lock (_lock)
                {
                    _stack = stack;
                }

                if (_claims != null && _lease.Snapshot().Holder is { } holder)
                {
                    _claims.Claim(ClaimLane(stack.Context), holder, ClaimResource);
                }
            }

            var started = new List<ServiceInstance>();
            // Requested, not only planned: a requested dependency the preflight skipped (an optional service that is not
            // built) holds its dependents back like one that exited.
            var notStarted = names.Except(toStart).ToHashSet();
            var requestedOrRunning = alreadyRunning.Concat(names).ToHashSet();
            foreach (var name in toStart)
            {
                var plan = plans[name];
                if (await UnmetDependencyAsync(name, plan.StartAfter.Where(requestedOrRunning.Contains), notStarted, timeout, cancellationToken) is { } unmet)
                {
                    // A dependent started next to a dependency that is not up fails in its own way (the asset repository
                    // without the system database identity creates), so it is not started at all.
                    notStarted.Add(name);
                    warnings.Add(unmet);
                    _logger.LogWarning("{Service} not started: {Reason}", Qualify(name), unmet);
                    continue;
                }

                try
                {
                    if (!Slot.IsDefault)
                    {
                        // Generated files of the service (a frontend's runtime config with this slot's backend URLs).
                        foreach (var file in ServiceFiles.Write(config, Slot, SlotDirectory, name, plan.RepoPath))
                        {
                            notes.Add($"{name}: wrote {file}");
                        }
                    }

                    var process = ProcessLauncher.Start(plan);
                    var instance = new ServiceInstance(plan, process, OverrideOf(name))
                    {
                        Origin = starters?.GetValueOrDefault(name) ?? (stack.StartedBy is { } by ? new ServiceOrigin(by, ServiceOrigin.StackStart) : null)
                    };
                    lock (_lock)
                    {
                        _services[name] = instance;
                        _stoppedForBuild.Remove(name);
                    }

                    started.Add(instance);
                    _logger.LogInformation("Started {Service} (pid {Pid}) from {Repo}", Qualify(name), instance.Pid, plan.RepoPath);
                }
                catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
                {
                    notStarted.Add(name);
                    warnings.Add($"{name} could not be started: {e.Message}");
                }

                Persist();
            }

            HealthWait? health = null;
            if (waitForHealthy && started.Count > 0)
            {
                health = await WaitHealthyAsync(started, timeout, cancellationToken);
                warnings.AddRange(HealthWarnings(health, timeout));
            }

            notes.AddRange(OctoCliContextNotes(config, started.Select(i => i.Plan.Name).ToList(), overrides, stack));
            SlotSetupResult? setup = null;
            if (!Slot.IsDefault && started.Count > 0)
            {
                var after = await _host.Artifacts.AfterStartAsync(this, config, started.Select(i => i.Plan).ToList(), waitForHealthy, cancellationToken);
                notes.AddRange(after.Notes);
                warnings.AddRange(after.Warnings);
                setup = await SetupAfterStartAsync(config, stack, started, health, notes, cancellationToken);
                if (setup != null)
                {
                    notes.Add(setup.Summary());
                    warnings.AddRange(setup.Warnings);
                }
            }

            return new StartResult(await StatusAsync(external: Slot.IsDefault ? null : ExternalSnapshot.Empty), skipped, warnings, notes) { Setup = setup };
        }
        finally
        {
            lock (_lock)
            {
                _reserved = null;
            }
        }
    }

    /// <summary>
    ///     The automatic setup of a non-default slot (slotOptions.autoSetup, <see cref="StackSupervisor.Setup"/>): after a
    ///     start whose health wait saw the slot's identity service healthy - on a fresh system database it creates the admin,
    ///     the octo-cli contexts and the client and applies the overlay, later it only logs the contexts in again. Null when it
    ///     does not apply; a start of the identity service that cannot be set up says why in <paramref name="notes"/>.
    /// </summary>
    private async Task<SlotSetupResult?> SetupAfterStartAsync(DevStackConfig config, StackRun stack, IReadOnlyList<ServiceInstance> started, HealthWait? health,
        List<string> notes, CancellationToken cancellationToken)
    {
        var identity = started.FirstOrDefault(i => i.Plan.Name == SlotArtifacts.IdentityService);
        if (identity == null || _host.Setup is not { } setup)
        {
            return null;
        }

        var why = !config.SlotOptions.AutoSetup ? "slotOptions.autoSetup is off"
            : health == null ? "the start did not wait for health"
            : health.Exited.Contains(identity) || health.TimedOut.Contains(identity) ? $"{SlotArtifacts.IdentityService} is not healthy"
            : null;
        if (why != null)
        {
            notes.Add($"{Capitalized(StackLabel())} was not set up ({why}); {SlotOperations.RepairCall(stack.Context.Environment, Slot.Name, null)} creates its admin, " +
                      "octo-cli contexts and client, logs the contexts in and applies its identity overlay.");
            return null;
        }

        return await setup.AfterHealthyStartAsync(this, stack.Context.Environment, cancellationToken);
    }

    /// <summary>Called by the validator while it holds the admission lock: from now on the other slots see this start.</summary>
    internal void Reserve(SlotClaim claim)
    {
        lock (_lock)
        {
            _reserved = claim;
        }
    }

    private static SlotClaim PlannedClaim(IReadOnlyList<ServicePlan> plans, StackRun stack, IReadOnlyDictionary<string, IReadOnlyList<string>?> isolateKeys)
    {
        var ports = new Dictionary<int, string>();
        var tenants = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var plan in plans)
        {
            foreach (var port in plan.Ports)
            {
                ports.TryAdd(port, plan.Name);
            }

            if (TenantOf(plan.Args) is { } tenant)
            {
                tenants.TryAdd(tenant, plan.Name);
            }
        }

        return new SlotClaim(ports, isolateKeys,
            plans.Select(p => (p, stack.Instances.TryGetValue(p.Name, out var i) ? i.Of! : p.Name)).ToList(), tenants);
    }

    private static (List<string> ToStart, List<string> Skipped, List<string> Missing) CheckBinaries(DevStackConfig config, StackContext context,
        IReadOnlyList<string> names, IReadOnlyDictionary<string, ServiceOverride>? overrides)
    {
        var toStart = new List<string>();
        var skipped = new List<string>();
        var missing = new List<string>();
        foreach (var name in ServicePlanner.Order(config, names))
        {
            var o = overrides?.GetValueOrDefault(name);
            var plan = ServicePlanner.Plan(config, context, name, o, new Dictionary<string, string?>());
            var problem = MissingBinary(plan);
            if (problem == null)
            {
                toStart.Add(name);
            }
            else if (config.Services[name].Optional && o?.Source == null)
            {
                skipped.Add($"{name}: {problem}");
            }
            else
            {
                missing.Add($"{name}: {problem}");
            }
        }

        return (toStart, skipped, missing);
    }

    private static InvalidOperationException NotBuilt(StackContext context, List<string> missing) =>
        new($"Not built for {context.Configuration}: {string.Join("; ", missing)}. Build it (lane_build / base_build) or pick another configuration.");

    /// <summary>The octo-cli context of a tenant in this slot: local_&lt;tenant&gt;, or local-&lt;slot&gt;_&lt;tenant&gt; in another slot.</summary>
    public string OctoCliContext(string tenant) => Slot.IsDefault ? $"local_{tenant}" : $"{SlotArtifacts.InstallationName(Slot)}_{tenant}";

    /// <summary>Whether octo-cli can talk to the tenant of every started mesh adapter (context local_&lt;tenant&gt;). Report only.</summary>
    private IEnumerable<string> OctoCliContextNotes(DevStackConfig config, IReadOnlyList<string> started,
        IReadOnlyDictionary<string, ServiceOverride>? overrides, StackRun stack)
    {
        if (_checks == null)
        {
            yield break;
        }

        foreach (var name in started)
        {
            var baseName = stack.Instances.TryGetValue(name, out var instance) ? instance.Of : name;
            if (baseName != SettingsMap.MeshAdapterService)
            {
                continue;
            }

            var tenant = overrides?.GetValueOrDefault(name)?.Variables?.GetValueOrDefault("tenantId") ?? config.Services[name].Variables.GetValueOrDefault("tenantId");
            if (tenant == null)
            {
                continue;
            }

            var context = OctoCliContext(tenant);
            var installation = Slot.IsDefault ? "local" : SlotArtifacts.InstallationName(Slot);
            var register = Slot.IsDefault
                ? $"Register-OctoCliContext -Installation local -TenantId {tenant}"
                : $"Register-OctoCliContext -Installation {installation} -TenantId {tenant} (after adding the installation '{installation}', see {SlotArtifacts.InstallationFile(this)})";
            yield return _checks.HasOctoCliContext(context) switch
            {
                true => $"{name} serves tenant {tenant}; the octo-cli context {context} exists.",
                false => $"{name} serves tenant {tenant}; there is no octo-cli context {context}. Register it with {register} (not done by octo-devstack).",
                null => $"{name} serves tenant {tenant}; octo-cli contexts could not be read ({_checks.ContextsFile}), so a context {context} was not checked."
            };
        }
    }

    private async Task<StopResult> StopLockedAsync(IReadOnlyList<string>? names, CancellationToken cancellationToken, bool keepStack = false)
    {
        var config = _store.Load();
        List<ServiceInstance> targets;
        lock (_lock)
        {
            if (names is { Count: > 0 })
            {
                foreach (var name in names.Where(n => !_services.ContainsKey(n)))
                {
                    throw new InvalidOperationException(
                        $"Service '{name}' is not running{(Slot.IsDefault ? "" : $" in slot '{Slot.Name}'")}. Running: {string.Join(", ", _services.Keys)}.");
                }

                targets = names.Select(n => _services[n]).ToList();
            }
            else
            {
                targets = _services.Values.ToList();
            }
        }

        var stopped = new List<string>();
        var killed = new List<string>();
        var notes = new List<string>();
        var timeout = TimeSpan.FromSeconds(config.StopTimeoutSeconds);
        await Task.WhenAll(targets.Select(async instance =>
        {
            // Where the log stood when the stop signal went out: what the service wrote until the kill says whether it got
            // the signal ("Application is shutting down") and what held it up.
            var logOffset = LogLength(instance.Plan.LogFile);
            // Not cancellable: a stop that ends half-way leaves processes nobody tracks any more.
            if (instance.IsAlive && await ProcessTree.TerminateAsync(instance.Pid, timeout, CancellationToken.None, consoleGroup: true))
            {
                var note = KilledNote(instance.Plan.Name, instance.Plan.LogFile, logOffset, timeout);
                _logger.LogWarning("{Note}", note);
                lock (killed)
                {
                    killed.Add(instance.Plan.Name);
                    notes.Add(note);
                }
            }

            lock (stopped)
            {
                stopped.Add(instance.Plan.Name);
            }
        }));

        lock (_lock)
        {
            foreach (var instance in targets)
            {
                _services.Remove(instance.Plan.Name);
            }

            if (_services.Count == 0 && !keepStack)
            {
                _stack = null;
                _stoppedForBuild.Clear();
            }
        }

        Persist();
        return new StopResult(stopped, killed, await StatusAsync(includeLogTail: false, external: Slot.IsDefault ? null : ExternalSnapshot.Empty))
        {
            Note = notes.Count == 0 ? null : string.Join(" ", notes)
        };
    }

    private static long LogLength(string file)
    {
        try
        {
            return File.Exists(file) ? new FileInfo(file).Length : 0;
        }
        catch (IOException)
        {
            return 0;
        }
    }

    /// <summary>
    ///     Why a service had to be killed, from its log between the stop signal and the kill: whether the host saw the
    ///     signal ("Application is shutting down") and its last lines (cut), for the daemon log and the stop result.
    /// </summary>
    internal static string KilledNote(string service, string logFile, long offset, TimeSpan timeout)
    {
        string written;
        try
        {
            using var stream = new FileStream(logFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Min(offset, stream.Length), SeekOrigin.Begin);
            written = new StreamReader(stream).ReadToEnd();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            written = "";
        }

        var lines = written.Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var sawSignal = lines.Any(l => l.Contains("Application is shutting down", StringComparison.OrdinalIgnoreCase));
        var tail = lines.TakeLast(5).Select(l => l.Length > 300 ? l[..300] + " ..." : l);
        return $"{service} did not exit within {timeout.TotalSeconds:0} s of the stop signal and was killed; " +
               (lines.Length == 0
                   ? "it wrote nothing to its log after the signal."
                   : $"{(sawSignal ? "its host was shutting down" : "its log shows no \"Application is shutting down\"")} " +
                     $"({lines.Length} line(s) after the signal; last: {string.Join(" | ", tail)}).") +
               " Raise stopTimeoutSeconds if its shutdown just takes longer.";
    }

    /// <summary>
    ///     Waits until every startAfter dependency of <paramref name="name"/> in this start is healthy. Returns null when the
    ///     service may start, otherwise the warning why it is not started: a dependency that did not start, exited or was not
    ///     healthy within <paramref name="timeout"/>.
    /// </summary>
    private async Task<string?> UnmetDependencyAsync(string name, IEnumerable<string> dependencies, IReadOnlySet<string> notStarted, TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deps = new List<(string Name, ServiceInstance Instance)>();
        foreach (var dependency in dependencies)
        {
            ServiceInstance? dep;
            lock (_lock)
            {
                dep = _services.GetValueOrDefault(dependency);
            }

            if (dep == null || notStarted.Contains(dependency))
            {
                return $"{name} not started: it starts after {dependency}, which did not start. Start {dependency} first, then {name} (service_start).";
            }

            deps.Add((dependency, dep));
        }

        if (deps.Count == 0)
        {
            return null;
        }

        // One wait over all dependencies: its final exit check covers a dependency that got healthy and exited while the
        // wait went on for another one.
        var wait = await WaitHealthyAsync(deps.Select(d => d.Instance).ToList(), timeout, cancellationToken, stopOnExit: true);
        if (wait.Healthy)
        {
            return null;
        }

        var failed = deps.First(d => wait.Exited.Contains(d.Instance) || wait.TimedOut.Contains(d.Instance));
        return DependencyWarning(name, failed.Name, wait.Exited.Contains(failed.Instance), ExitCodeText(failed.Instance), timeout);
    }

    /// <summary>The warning for a service held back because its startAfter dependency exited or did not get healthy.</summary>
    internal static string DependencyWarning(string name, string dependency, bool exited, string exitCode, TimeSpan timeout) =>
        $"{name} not started: it starts after {dependency}, which " +
        (exited ? $"has exited{exitCode}" : $"was not healthy within {timeout.TotalSeconds:0} s (startAfter wait = the start's timeoutSeconds)") +
        $". Check {dependency} (service_logs {dependency}, stack_status), then start {name} with service_start once {dependency} is healthy.";

    /// <summary>Services that exited while the daemon waited, and services still not healthy when the time ran out.</summary>
    internal sealed record HealthWait(IReadOnlyList<ServiceInstance> Exited, IReadOnlyList<ServiceInstance> TimedOut)
    {
        public bool Healthy => Exited.Count == 0 && TimedOut.Count == 0;
    }

    /// <param name="stopOnExit">Return as soon as one instance has exited (a dependency wait: the dependent is held back
    ///     anyway, so waiting out the others would only delay the rest of the start and every stop behind it).</param>
    private static async Task<HealthWait> WaitHealthyAsync(IReadOnlyList<ServiceInstance> instances, TimeSpan timeout, CancellationToken cancellationToken,
        bool stopOnExit = false)
    {
        // Monotonic: a wall clock that is set forward (WSL syncing its clock, a laptop resuming) ended the wait early.
        var waited = System.Diagnostics.Stopwatch.StartNew();
        var pending = instances.ToList();
        while (true)
        {
            var results = await Task.WhenAll(pending.Select(async i => (Instance: i, Done: !i.IsAlive || (await Probes.CheckAsync(i.Plan.HealthUrl, i.Plan.Ports, i.Plan.Args)).Healthy)));
            pending = results.Where(r => !r.Done).Select(r => r.Instance).ToList();
            if (pending.Count == 0 || waited.Elapsed >= timeout || (stopOnExit && instances.Any(i => !i.IsAlive)))
            {
                return new HealthWait(instances.Where(i => !i.IsAlive).ToList(), pending.Where(i => i.IsAlive).ToList());
            }

            await Task.Delay(1000, cancellationToken);
        }
    }

    /// <summary>The start warnings of a health wait: an exit is named as such, not reported as a health timeout.</summary>
    internal static IEnumerable<string> HealthWarnings(HealthWait wait, TimeSpan timeout)
    {
        if (wait.Exited.Count > 0)
        {
            yield return $"{string.Join(", ", wait.Exited.Select(i => i.Plan.Name + ExitCodeText(i)))} exited after the start; see Services[].logTail.";
        }

        if (wait.TimedOut.Count > 0)
        {
            yield return $"{string.Join(", ", wait.TimedOut.Select(i => i.Plan.Name))} not healthy within {timeout.TotalSeconds:0} s; see Services[].state and logTail.";
        }
    }

    private static string ExitCodeText(ServiceInstance i) => i.ExitCode is { } code ? $" (exit code {code})" : "";

    private static async Task<ServiceStatus> DescribeAsync(ServiceInstance i, bool includeLogTail)
    {
        var alive = i.IsAlive;
        bool healthy = false;
        string? detail = null;
        string state;
        if (alive)
        {
            (healthy, detail) = await Probes.CheckAsync(i.Plan.HealthUrl, i.Plan.Ports, i.Plan.Args);
            state = healthy ? "healthy" : DateTimeOffset.Now - i.StartedAt < StartingGrace ? "starting" : "unhealthy";
        }
        else
        {
            state = "exited";
        }

        var tail = includeLogTail && (!alive || state == "unhealthy") ? LogReader.Tail(i.Plan.LogFile, 40) : null;
        return new ServiceStatus(i.Plan.Name, state, healthy, detail, i.Pid, i.Plan.Source, i.Plan.RepoPath, i.Plan.WorkingDirectory,
            i.Plan.Command, i.Plan.Args, i.Plan.LogFile, i.Plan.Ports, i.StartedAt, i.ExitedAt, i.ExitCode, i.Adopted, tail)
        {
            StartedBy = i.Origin?.Owner, StartedBySession = i.Origin?.Session, StartedVia = i.Origin?.Via
        };
    }

    /// <summary>
    ///     Why a persisted service cannot be adopted (null: it can): its pid is gone, now runs something else (the command
    ///     line lacks the service's first argument or program), or was reused (another start time). An unreadable start time
    ///     does not count against it; older state files have none.
    /// </summary>
    internal static string? NotAdoptable(PersistedService s, bool alive, string commandLine, DateTimeOffset? startTime)
    {
        if (!alive)
        {
            return "the process has exited";
        }

        var marker = s.Args.FirstOrDefault() ?? Path.GetFileName(s.Command);
        if (!commandLine.Contains(marker, StringComparison.Ordinal))
        {
            return commandLine.Length == 0 ? "its command line cannot be read" : $"pid {s.Pid} now runs another program";
        }

        if (!ProcessTree.SameStart(s.ProcessStartTime, startTime))
        {
            return $"pid {s.Pid} was reused (started {startTime!.Value.ToLocalTime():HH:mm:ss}, the service at {s.ProcessStartTime!.Value.ToLocalTime():HH:mm:ss})";
        }

        return null;
    }

    private static string? MissingBinary(ServicePlan plan)
    {
        if (!Directory.Exists(plan.WorkingDirectory))
        {
            return $"{plan.WorkingDirectory} does not exist";
        }

        var first = plan.Args.FirstOrDefault();
        if (first != null && first.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && !File.Exists(Path.Combine(plan.WorkingDirectory, first)))
        {
            return $"{Path.Combine(plan.WorkingDirectory, first)} does not exist";
        }

        return null;
    }

    private void Persist()
    {
        PersistedStack? persisted = null;
        lock (_lock)
        {
            if (_stack != null)
            {
                // A stack run kept by a build has no live service; it is persisted so a daemon restart keeps it.
                persisted = new PersistedStack
                {
                    Checkout = _stack.Context.Checkout,
                    Configuration = _stack.Context.Configuration,
                    StartedAt = _stack.StartedAt,
                    StartedBy = _stack.StartedBy,
                    Profile = _stack.Profile,
                    ProfileHash = _stack.ProfileHash,
                    Services = _services.Values.Where(i => i.IsAlive).Select(ToPersisted).ToList(),
                    StoppedForBuild = _stoppedForBuild.Values.Where(i => !_services.ContainsKey(i.Plan.Name)).Select(ToPersisted).ToList()
                };
            }
        }

        _host.State.SaveStack(Slot.Name, persisted);
    }

    /// <summary>What the state file keeps of a service: pid and paths, never environment values.</summary>
    private static PersistedService ToPersisted(ServiceInstance i) => new()
    {
        Name = i.Plan.Name,
        Pid = i.Pid,
        Command = i.Plan.Command,
        Args = i.Plan.Args.ToList(),
        WorkingDirectory = i.Plan.WorkingDirectory,
        RepoPath = i.Plan.RepoPath,
        Source = i.Plan.Source,
        LogFile = i.Plan.LogFile,
        Ports = i.Plan.Ports.ToList(),
        HealthUrl = i.Plan.HealthUrl,
        StartedAt = i.StartedAt,
        ProcessStartTime = i.ProcessStartTime,
        StartedBy = i.Origin?.Owner,
        StartedVia = i.Origin?.Via,
        StartedBySession = i.Origin?.Session
    };

    /// <summary>The origin of a persisted service; a state file without one names the stack's starter (stack_start).</summary>
    internal static ServiceOrigin? OriginOf(PersistedService s, string? stackStartedBy) =>
        s.StartedBy is { Length: > 0 } by ? new ServiceOrigin(by, s.StartedVia ?? ServiceOrigin.StackStart) { Session = s.StartedBySession }
        : stackStartedBy is { Length: > 0 } stack ? new ServiceOrigin(stack, ServiceOrigin.StackStart) : null;

    /// <summary>The plan of a service as the state file has it (an adopted or a stopped-for-build service).</summary>
    private static ServicePlan PlanOf(PersistedService s) =>
        new(s.Name, s.RepoPath, s.WorkingDirectory, s.Command, s.Args, new Dictionary<string, string?>(), s.LogFile, s.Ports, s.HealthUrl, [], s.Source);

    private static string Shorten(string text) => text.Length <= 160 ? text : text[..157] + "...";

    private sealed class StackRun(StackContext context, DateTimeOffset startedAt, string? startedBy, Dictionary<string, string?>? providerEnv,
        Dictionary<string, string?> requestEnv)
    {
        public StackContext Context { get; } = context;
        public DateTimeOffset StartedAt { get; } = startedAt;
        public string? StartedBy { get; } = startedBy;
        public Dictionary<string, string?>? ProviderEnv { get; set; } = providerEnv;
        public List<string> ProvidersRan { get; set; } = [];
        public Dictionary<string, string?> RequestEnv { get; } = requestEnv;
        public string? Profile { get; init; }
        public string? ProfileHash { get; init; }

        /// <summary>Instances of the start; re-materialized from a fresh config load on every later start/restart.</summary>
        public Dictionary<string, ProfileInstance> Instances { get; init; } = new();

        public Dictionary<string, bool> EnvProviders { get; init; } = new();

        /// <summary>The slot's values of the last start (renewed with the configuration on every start/restart).</summary>
        public SlotDerivation? Derivation { get; set; }

        /// <summary>For adopted services: the profile's env (settings fan-out), to work out their isolated values again.</summary>
        public Dictionary<string, string?> AdoptedEnv { get; init; } = new();
    }
}
