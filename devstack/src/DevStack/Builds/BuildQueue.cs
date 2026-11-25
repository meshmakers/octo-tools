using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>A build (base_build, lane_build) the daemon refused, for the status page's conflict banner.</summary>
public sealed record BuildRefusal(DateTimeOffset At, string Owner, string Kind, string Target, string Reason, IReadOnlyList<BuildConflict> Conflicts);

/// <summary>
///     Runs builds in the background (callers wait with job_status) by queue class: a lane job (repo, range, all, profile of the
///     base lane) runs alone - they share the lane's nuget folder and package cache, so two at the same time can poison each
///     other; environment jobs (kind=env, or any build with env) have their own feed and cache and run next to each other,
///     one per environment and at most <see cref="MaxParallelEnvironmentBuilds"/> at once. A build of a plain worktree
///     (<see cref="PlannedBuild.Worktree"/>: kind=repo of a git worktree that is no lane's repo folder) writes only into the
///     worktree and never into the lane's feed: worktree builds run next to each other - one per worktree, at most
///     <see cref="MaxParallelWorktreeBuilds"/> at once - and next to environment builds. A test run (kind test) shares
///     the class of its environment - or has the class of its lane - so it never runs next to a build or another test run
///     there; it is not counted against the limits (the machine-wide docker test lock of the cmdlet serializes test runs).
///     Two jobs that build or test the same folder never run at once. Jobs start in queue order: a waiting lane build holds
///     back every job queued after it.
/// </summary>
public sealed partial class BuildQueue : IBuildGuard
{
    /// <summary>Environment builds that may run at the same time (each in its own environment).</summary>
    public const int MaxParallelEnvironmentBuilds = 2;

    /// <summary>Builds of plain worktrees that may run at the same time (each of its own worktree), next to environment builds.</summary>
    public const int MaxParallelWorktreeBuilds = 2;

    /// <summary>The compact status lists the evidence of every repository up to this many; beyond, only the ones that are not unchanged.</summary>
    private const int MaxEvidenceRepos = 10;

    private const int KeepFinishedJobs = 50;
    private const int MaxListedRepos = 30;
    private const int ErrorsPerRepoInStatus = 20;
    private const int FailedTestsPerProjectInStatus = 20;
    private const int MaxLiveLines = 200;
    private const int MaxLiveLineLength = 400;
    private static readonly TimeSpan KeepFilesFor = TimeSpan.FromDays(14);

    private readonly BuildCapabilityCache _capabilities;
    private readonly LaneClaims? _claims;
    private readonly BuildHistory _history;
    private readonly ConcurrentDictionary<string, BuildJob> _jobs = new();
    private readonly LeaseManager _lease;
    private readonly ILogger<BuildQueue> _logger;
    private readonly BuildQueueOptions _options;
    private readonly DevStackPaths _paths;
    private readonly BuildPlanner _planner;
    private readonly Lock _refusalLock = new();
    private readonly List<BuildRefusal> _refusals = [];
    private readonly Lock _enqueueLock = new();
    private readonly Lock _scheduleLock = new();
    // Taken before _scheduleLock, never under it: PersistRunning is not called while _scheduleLock is held.
    private readonly Lock _persistLock = new();
    private readonly List<BuildJob> _waiting = [];
    private readonly List<BuildJob> _running = [];
    private readonly IPwshRunner _pwsh;
    private readonly StateStore? _state;
    private readonly ConfigStore _store;
    private readonly StackSupervisor _supervisor;
    private readonly IBuildLauncher? _launcher;
    private readonly BuildJobStore _jobStore;
    private readonly CancellationTokenSource _abandoned = new();
    private long _sequence;

    public BuildQueue(ConfigStore store, StackSupervisor supervisor, LeaseManager lease, DevStackPaths paths, ILogger<BuildQueue> logger,
        IPwshRunner? runner = null, StateStore? state = null, LaneClaims? claims = null, BuildQueueOptions? options = null,
        Func<Task<ExternalSnapshot>>? external = null, BuildCapabilityCache? capabilities = null, IBuildLauncher? launcher = null)
    {
        _store = store;
        _supervisor = supervisor;
        _lease = lease;
        _paths = paths;
        _logger = logger;
        _pwsh = runner ?? new PwshProcessRunner();
        // The real pwsh runs detached (it survives a daemon restart); a fake runner without a launcher runs attached.
        _launcher = launcher ?? (_pwsh is PwshProcessRunner ? new DetachedBuildLauncher() : null);
        _jobStore = new BuildJobStore(paths.BuildLogDirectory);
        _state = state;
        _claims = claims;
        _options = options ?? new BuildQueueOptions();
        _capabilities = capabilities ?? new BuildCapabilityCache(_pwsh);
        _history = new BuildHistory(paths);
        _planner = new BuildPlanner(store, supervisor, lease, paths, _pwsh, _capabilities, _options, external ?? supervisor.ExternalAsync);
        supervisor.BuildGuard = this;
        var resume = RestoreJobs();
        CleanOldFiles();
        Trim();
        foreach (var job in resume)
        {
            Launch(job);
        }

        Schedule();
    }

    /// <summary>
    ///     The queue class of a job: null for a lane job (exclusive), else the environment it builds in, the lane a test run
    ///     tests in, or the worktree a plain worktree build builds.
    /// </summary>
    private static string? ClassOf(BuildJob job) =>
        job.Request.Environment ?? (IsTest(job) ? "lane:" + (job.Planned.Lane == null ? "" : PathScope.Normalize(job.Planned.Lane))
            : job.Planned.Worktree is { } worktree ? "worktree:" + PathScope.Normalize(worktree) : null);

    private static bool IsTest(BuildJob job) => job.Request.Kind == BuildKind.Test;

    /// <summary>A build of a plain worktree (its own class, its own limit).</summary>
    private static bool IsWorktreeBuild(BuildJob job) => job.Request.Environment == null && !IsTest(job) && job.Planned.Worktree != null;

    /// <summary>A build of an environment (counted against <see cref="MaxParallelEnvironmentBuilds"/>).</summary>
    private static bool IsEnvironmentBuild(BuildJob job) => ClassOf(job) != null && !IsTest(job) && !IsWorktreeBuild(job);

    /// <summary>
    ///     Whether two jobs build or test the same folder (one lies in the other): an environment may adopt a worktree in place,
    ///     and a worktree build must never run next to a build of the same folder.
    /// </summary>
    private static bool Overlaps(BuildJob a, BuildJob b)
    {
        var mine = a.Planned.ConflictPaths.ToList();
        return mine.Count > 0 && b.Planned.ConflictPaths.Any(other => mine.Any(path => PathScope.IsUnder(path, other) || PathScope.IsUnder(other, path)));
    }

    /// <summary>
    ///     Starts every waiting job its class allows, in queue order: a lane build only when nothing runs (and it stops the scan
    ///     either way, so nothing overtakes it); an environment job while no lane build runs, fewer than
    ///     <see cref="MaxParallelEnvironmentBuilds"/> environment builds run and none of its environment runs or waits ahead of
    ///     it; a worktree build the same way with its worktree as the class and <see cref="MaxParallelWorktreeBuilds"/> as the
    ///     limit; a test run the same way with its environment or lane as the class, outside the limits. No job starts while a
    ///     running one builds or tests one of its folders.
    /// </summary>
    private void Schedule()
    {
        var start = new List<BuildJob>();
        var probes = new List<BuildJob>();
        lock (_scheduleLock)
        {
            if (_abandoned.IsCancellationRequested)
            {
                KeepRechecking(false);
                return;
            }

            _waiting.RemoveAll(j => j.State != "queued");
            var rechecking = false;
            var heldEnvironments = new HashSet<string>(StringComparer.Ordinal);
            foreach (var job in _waiting.ToList())
            {
                var env = ClassOf(job);
                if (env == null)
                {
                    if (_running.Count == 0)
                    {
                        Promote(job);
                    }

                    break;
                }

                if (_running.Any(r => ClassOf(r) == null))
                {
                    break;
                }

                if (heldEnvironments.Contains(env) || _running.Any(r => ClassOf(r) == env))
                {
                    // AB#8832: a test run of a repository the environment's build is through with starts next to it,
                    // when the cmdlet says the run builds nothing itself (asked outside the lock, then scheduled again).
                    if (!heldEnvironments.Contains(env) && EarlyStartBuild(job) is { } build)
                    {
                        rechecking = true;
                        var probe = job.Early;
                        var age = probe == null ? TimeSpan.MaxValue : DateTimeOffset.Now - probe.At;
                        if (probe is { Pending: false, Ok: true } && age <= _options.EarlyProbeValid)
                        {
                            if (_running.Any(r => r != build && Overlaps(r, job)))
                            {
                                // Another running job (a worktree build of a folder the lane build skipped) works on this run's folder:
                                // it waits, as on the normal path - two jobs never work on one folder at once.
                                heldEnvironments.Add(env);
                                continue;
                            }

                            job.NoBuild = true;
                            job.AddNote($"Started while build {build.Id} of the lane still runs: it is through with {job.Request.Repo} and what it depends on, " +
                                        "and this run builds nothing (-build Never).");
                            Promote(job);
                            heldEnvironments.Add(env);
                            continue;
                        }

                        if (probe == null || (!probe.Pending && age > (probe.Ok ? _options.EarlyProbeValid : _options.EarlyProbeRetry)))
                        {
                            job.Early = new EarlyProbe(DateTimeOffset.Now, true, false, probe?.Reason);
                            probes.Add(job);
                        }
                    }
                    else if (IsTest(job) && job.Request.Environment != null)
                    {
                        rechecking = true;
                    }

                    heldEnvironments.Add(env);
                    continue;
                }

                if (_running.Any(r => Overlaps(r, job)))
                {
                    heldEnvironments.Add(env); // waits for the job that builds its folder; nothing of its class overtakes it
                    continue;
                }

                if (IsWorktreeBuild(job)
                        ? _running.Count(IsWorktreeBuild) >= MaxParallelWorktreeBuilds
                        : !IsTest(job) && _running.Count(IsEnvironmentBuild) >= MaxParallelEnvironmentBuilds)
                {
                    // A test run, or a build of the other limit, queued behind it may still start - but not a later job of its own
                    // class (a test of the same lane must not start before that lane's build).
                    heldEnvironments.Add(env);
                    continue;
                }

                Promote(job);
            }

            KeepRechecking(rechecking);

            void Promote(BuildJob job)
            {
                _waiting.Remove(job);
                // Running from here on, so base_build / lane_build reports the real state (a job canceled meanwhile stays canceled).
                if (job.TryStart())
                {
                    job.Pins = PinLeases(job); // with the state, so a running job's lease never is unpinned
                    _running.Add(job);
                    start.Add(job);
                }
            }
        }

        foreach (var job in start)
        {
            Launch(job);
        }

        foreach (var job in probes)
        {
            _ = Task.Run(() => ProbeEarlyAsync(job), CancellationToken.None);
        }
    }

    /// <summary>Runs a job of <see cref="_running"/> in the background (a new one, or one taken over from the previous daemon run).</summary>
    private void Launch(BuildJob job)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                await RunAsync(job);
            }
            catch (Exception e)
            {
                _logger.LogError(e, "Build scheduler: job {Id} ended with an exception", job.Id);
            }
            finally
            {
                if (!_abandoned.IsCancellationRequested)
                {
                    lock (_scheduleLock)
                    {
                        _running.Remove(job);
                    }

                    PersistRunning();
                    Schedule();
                }
            }
        }, CancellationToken.None);
    }

    /// <summary>
    ///     The state file names every build whose pwsh runs. The job files are what a restart restores from; this list is
    ///     kept for a daemon version without them (it reports the builds as orphaned). Snapshot and save happen under one
    ///     lock: two parallel builds starting at once each persist, and without it the older snapshot (one build) could be
    ///     saved after the newer one (both) and stay in the file until the next change.
    /// </summary>
    private void PersistRunning()
    {
        if (_state == null || _abandoned.IsCancellationRequested)
        {
            return;
        }

        lock (_persistLock)
        {
            List<PersistedBuild> builds;
            lock (_scheduleLock)
            {
                // Read each pid once: a parallel job clears its own pid when its step ends (the old check-then-read raced).
                builds = _running.Where(j => j.FinishedAt == null).OrderBy(j => j.Sequence)
                    .Select(job => (Job: job, Pid: job.Pid))
                    .Where(x => x.Pid != null)
                    .Select(x => new PersistedBuild
                    {
                        Id = x.Job.Id, Owner = x.Job.Request.Owner, Kind = x.Job.Kind, Target = x.Job.Planned.Target, Pid = x.Pid!.Value,
                        StartedAt = x.Job.StartedAt ?? DateTimeOffset.Now, LogFile = x.Job.LogFile
                    }).ToList();
            }

            try
            {
                _state.SaveBuilds(builds);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // The list serves older daemon versions only (a restart restores from the job files): never fail a build for it.
                _logger.LogWarning(e, "Could not record the running builds in the state file");
            }
        }
    }

    /// <summary>
    ///     The running build whose folders hold <paramref name="repoPath"/>: its plan repos (nested worktrees excluded) and, for
    ///     range and all, the whole lane (its packages change under every service of the lane).
    /// </summary>
    public BuildGuardHit? Blocking(string repoPath)
    {
        foreach (var job in _jobs.Values.Where(j => j.State == "running"))
        {
            var inLane = job.Request.Kind is BuildKind.Range or BuildKind.All or BuildKind.Env && job.Planned.Lane != null &&
                         PathScope.Normalize(repoPath).StartsWith(PathScope.Normalize(job.Planned.Lane), StringComparison.OrdinalIgnoreCase);
            if (inLane || job.Planned.ConflictPaths.Any(p => PathScope.IsInRepo(repoPath, p)))
            {
                return new BuildGuardHit(job.Id, job.Request.Owner, job.Planned.Target) { TestRun = IsTest(job) };
            }
        }

        return null;
    }

    private LeaseManager LeaseOf(string slot) => slot == SlotInfo.DefaultName ? _lease : _supervisor.Leases.Get(slot);

    /// <summary>
    ///     Takes the leases of every slot a build needs, or none: a slot held by another session refuses the build, naming
    ///     the slot and its holder, before any lease is taken. Each slot's lease is taken for <see cref="BuildRequest.LeaseOwnerFor"/>.
    /// </summary>
    private void RequireLeases(BuildRequest request, IReadOnlyList<string> slots)
    {
        if (slots.Count <= 1)
        {
            var only = slots.FirstOrDefault() ?? SlotInfo.DefaultName;
            LeaseOf(only).Require(request.LeaseOwnerFor(only));
            return;
        }

        var held = HeldByOthers(request, slots);
        if (held.Count > 0)
        {
            throw new LeaseHeldException(
                $"The build needs the leases of the slots {string.Join(", ", slots)}; " +
                $"{string.Join("; ", held.Select(h => $"slot '{h.Slot}' is held by {Holder(h.Holder)} ({h.Holder.Purpose ?? "no purpose given"})"))}. " +
                "Wait with lease_acquire(slot, waitSeconds) or ask that session to release it.");
        }

        foreach (var slot in slots)
        {
            LeaseOf(slot).Require(request.LeaseOwnerFor(slot));
        }
    }

    /// <summary>The slots of <paramref name="slots"/> whose lease another owner than the job's for that slot holds.</summary>
    private List<(string Slot, LeaseInfo Holder)> HeldByOthers(BuildRequest request, IEnumerable<string> slots) =>
        slots.Select(s => (Slot: s, Holder: LeaseOf(s).Current()))
            .Where(x => x.Holder != null && !string.Equals(x.Holder.Owner.Trim(), request.LeaseOwnerFor(x.Slot).Trim(), StringComparison.OrdinalIgnoreCase))
            .Select(x => (x.Slot, x.Holder!)).ToList();

    /// <summary>A lease holder for a message: 'owner' (session s).</summary>
    private static string Holder(LeaseInfo holder) => $"'{holder.Owner}'{(holder.Session != null ? $" (session {holder.Session})" : "")}";

    /// <summary>Pins the leases a job needs, of every slot, for as long as it runs.</summary>
    private List<IDisposable> PinLeases(BuildJob job) =>
        job.LeaseRequired ? job.LeaseSlots.DefaultIfEmpty(SlotInfo.DefaultName).Select(slot => LeaseOf(slot).Pin(job.Request.LeaseOwnerFor(slot))).ToList() : [];

    private sealed class Unpin(BuildJob job) : IDisposable
    {
        private int _disposed;

        /// <summary>Releases the pins once (a finishing job releases them early, the using releases nothing then), the late ones too.</summary>
        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0)
            {
                return;
            }

            // Every pin is released, also when one release throws (a lease change subscriber that fails to write the state
            // file): a pin left held keeps the lease from expiring until the daemon restarts. The first error is rethrown.
            Exception? first = null;
            foreach (var pin in job.Pins.Concat(job.LatePins))
            {
                try
                {
                    pin.Dispose();
                }
                catch (Exception e)
                {
                    first ??= e;
                }
            }

            if (first != null)
            {
                System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(first).Throw();
            }
        }
    }

    // ---------- public API ----------

    /// <summary>The plan of a request without queueing it (build_plan, base_build / lane_build dryRun).</summary>
    public async Task<BuildPlanResult> PlanAsync(BuildRequest request, CancellationToken cancellationToken = default)
    {
        Validate(request);
        var planned = await _planner.PlanAsync(request, forPlanTool: true, cancellationToken);
        var conflicts = await _planner.ConflictsAsync(planned);
        var gates = _planner.Gates(planned, conflicts);
        var warnings = planned.Warnings.ToList();

        var steps = planned.Steps.Select(s => new BuildPlanStep(BuildStatus.ShownKind(s.Kind.ToString().ToLowerInvariant()), s.Target, s.Script,
            s.Repos.Select(r => planned.PlanRepos.FirstOrDefault(p => PathScope.SamePath(p.Path, r.Path)) ?? new BuildPlanRepo(r.Name, r.Mode, r.Path, null, null) { Action = r.Action, Reason = r.Reason, Detail = r.Detail, DependsOn = r.DependsOn, Exclusive = r.Exclusive })
                .ToList())).ToList();
        return new BuildPlanResult(BuildStatus.ShownKind(request.Kind.ToString().ToLowerInvariant()), planned.Target, planned.Configuration, planned.LaneInfo, steps, conflicts,
            warnings, gates, planned.Capabilities.Missing());
    }

    public async Task<BuildStatus> EnqueueAsync(BuildRequest request, CancellationToken cancellationToken = default)
    {
        Validate(request);
        // The same test run asked for again while it waits or runs (an agent that retried after a timeout): no second run.
        if (request.Kind == BuildKind.Test && SameTestRun(request) is { } existing)
        {
            var status = Describe(existing, StatusView.Default);
            return status with
            {
                Notes =
                [
                    ..status.Notes,
                    $"This test run is already {status.State} as {existing.Id} (asked for at {existing.QueuedAt:HH:mm:ss}); no second run was added - wait for it with job_status(\"{existing.Id}\", waitSeconds)."
                ]
            };
        }
        var planned = await _planner.PlanAsync(request, forPlanTool: false, cancellationToken);
        var conflicts = await _planner.ConflictsAsync(planned);
        var gates = _planner.Gates(planned, conflicts);
        var unmet = gates.Unmet.Where(u => !u.StartsWith("the stack lease", StringComparison.Ordinal)).ToList();
        if (gates.Lease)
        {
            try
            {
                RequireLeases(request, gates.LeaseSlots); // takes free leases
            }
            catch (LeaseHeldException e)
            {
                var message = request.Kind == BuildKind.Test ? TestStopRefusal(planned, conflicts, gates.LeaseSlots, e.Message)
                    : unmet.Count > 0 ? $"{e.Message} The build also needs: {string.Join("; ", unmet)}." : e.Message;
                RefusedFor(request, planned.Target, message, conflicts);

                throw new LeaseHeldException(message);
            }
        }

        if (unmet.Count > 0)
        {
            var reason = $"Build of {planned.Target} refused; it needs: {string.Join("; ", unmet)}.";
            RefusedFor(request, planned.Target, reason, conflicts);

            throw new InvalidOperationException(reason);
        }

        if (request.Kind == BuildKind.All && planned.Lane != null)
        {
            _claims?.EnsureCanClaimAll(planned.Lane, request.Owner);
        }

        if (planned.Steps.Count == 0)
        {
            throw new InvalidOperationException(string.Join(" ", planned.Warnings));
        }

        BuildJob job;
        lock (_enqueueLock)
        {
            if (request.SyncMain && MainJobOf(request) is { } main)
            {
                // The snapshot must not take over a half-built base feed: refused, not queued behind it (the agent decides).
                throw new InvalidOperationException(
                    $"syncMain refused: build {main.Id} ({main.Kind} {main.Planned.Target}, {main.Request.Owner}) is {main.State} in the base lane " +
                    $"{main.Planned.Lane}; the lane would copy a half-built feed. Wait for it (job_status(id, waitSeconds)) and start again, or build without syncMain.");
            }

            // Sequence and channel order are the same: the dispatcher runs jobs strictly first in, first out.
            var sequence = ++_sequence;
            var id = $"b{sequence}-{DateTimeOffset.Now:HHmmss}";
            job = new BuildJob(id, sequence, request, planned, Path.Combine(_paths.BuildLogDirectory, id + ".log"), _paths.BuildLogDirectory, _jobStore.PathOf(id))
            {
                LeaseRequired = gates.Lease,
                LeaseSlots = gates.LeaseSlots,
                // What the build will stop (checked again right before it runs); reported until the real stop replaces it.
                PlannedStops = StopsOwn(request)
                    ? conflicts.Where(c => c.Kind == "own").Select(c => c.Service).Distinct().ToList()
                    : []
            };
            foreach (var warning in planned.Warnings)
            {
                job.AddNote(warning);
            }

            _jobs[id] = job;
            Track(job);
            lock (_scheduleLock)
            {
                _waiting.Add(job);
            }
        }

        Schedule();
        Trim();
        var queued = Describe(job, StatusView.Default);
        // Which projects start containers is known only once the run planned them: say it now, while the developer can still act.
        return request.Kind == BuildKind.Test && _options.Docker?.Warning() is { } dockerWarning
            ? queued with { Notes = [..queued.Notes, "If this run includes test projects that start containers: " + dockerWarning] }
            : queued;
    }

    /// <summary>Whether a job stops the own services in its way: with stopServices, kind=all, and a test run (those of its target stack).</summary>
    private static bool StopsOwn(BuildRequest request) => request.StopServices || request.Kind is BuildKind.All or BuildKind.Test;

    /// <summary>
    ///     Why a test run is refused: per stack whose lease another session holds, the services it must stop, the holder (with
    ///     session) and the way out - for a lane's service in the shared stack (UC-A): switch it back or take the lease.
    /// </summary>
    private string TestStopRefusal(PlannedBuild planned, IReadOnlyList<BuildConflict> conflicts, IReadOnlyList<string> leaseSlots, string lease)
    {
        var request = planned.Request;
        var parts = new List<string>();
        foreach (var (slot, holder) in HeldByOthers(request, leaseSlots))
        {
            var services = conflicts.Where(c => c.Kind == "own" && (c.Slot ?? SlotInfo.DefaultName) == slot)
                .Select(c => StackSupervisor.Unqualify(c.Service).Name).Distinct().ToList();
            var stack = slot == SlotInfo.DefaultName ? "the shared stack" : $"the lane stack of {request.Environment ?? slot}";
            var way = slot == SlotInfo.DefaultName && request.Environment != null
                ? " The way out: switch them back to the base lane's build with the shared stack's lease - service_restart(owner, session, " +
                  $"services=[{string.Join(", ", services.Select(s => $"\"{s}\""))}], overrides={{{string.Join(", ", services.Select(s => $"\"{s}\": {{}}"))}}}) " +
                  $"(the holder, or you after lease_acquire(owner, session, waitSeconds)) - or take the lease yourself, then run lane_test again."
                : " Wait for the lease (lease_acquire(owner, session, waitSeconds)) or ask the holder to release it, then run the test again.";
            parts.Add($"it must stop {(services.Count > 0 ? string.Join(", ", services) : "services")} of {stack} first - they run from {planned.TestFolder}, and " +
                      $"Invoke-OctoTestRun rebuilds the project of a running service (MSB3027 on Windows) - and that needs {stack}'s lease, held by " +
                      $"{Holder(holder)}.{way}");
        }

        return $"Test run of {request.Repo} refused, nothing was queued: " + (parts.Count > 0 ? string.Join(" Also: ", parts) : lease);
    }

    /// <param name="live">Lines of the output to add (0 = none): of <paramref name="repo"/>, else of the repo that builds or is tested right now.</param>
    public BuildStatus Get(string id, string? repo = null, bool errorsOnly = false, bool raw = false, int tailLines = 40, int live = 0, bool includePassed = false)
    {
        if (_jobs.TryGetValue(id, out var job))
        {
            return Describe(job, new StatusView(repo, errorsOnly, raw, tailLines, Math.Clamp(live, 0, MaxLiveLines), includePassed));
        }

        throw new InvalidOperationException(UnknownJob(id));
    }

    /// <summary>Every job the daemon knows, newest first: this run's and the kept ones of earlier runs.</summary>
    public List<BuildStatus> List() =>
        _jobs.Values.OrderByDescending(j => j.QueuedAt).ThenByDescending(j => j.Sequence).Select(j => Describe(j, StatusView.Default)).ToList();

    private static string UnknownJob(string id) =>
        $"Unknown job '{id}': the daemon keeps the last {KeepFinishedJobs} finished jobs (job_list shows them), also across its restarts.";

    /// <summary>A queued or running test run of the same owner for the same environment or lane, repo, projects, filter and mode.</summary>
    private BuildJob? SameTestRun(BuildRequest request)
    {
        static string Key(BuildRequest r) => string.Join('\n', r.Owner.Trim().ToLowerInvariant(), r.Environment ?? "", r.Checkout?.Trim() ?? "",
            r.Repo?.Trim().ToLowerInvariant() ?? "", string.Join(',', r.Projects.Select(p => p.Trim().ToLowerInvariant()).Where(p => p.Length > 0).Order()),
            r.Filter?.Trim() ?? "", r.RerunFailed, r.Configuration ?? "");

        var key = Key(request);
        return _jobs.Values.Where(j => j.Request.Kind == BuildKind.Test && j.State is "queued" or "running" && Key(j.Request) == key)
            .OrderBy(j => j.Sequence).FirstOrDefault();
    }

    /// <summary>The probed octo-tools capabilities (shared with the environment tools).</summary>
    public BuildCapabilityCache Capabilities => _capabilities;

    /// <summary>Queued and running jobs of a lane (lane_remove waits for none).</summary>
    public List<BuildStatus> ActiveFor(string env) =>
        // A job that names the lane only through its folder (checkout=wt-<lane>) belongs to it too (Planned.Environment).
        _jobs.Values.Where(j => j.State is "queued" or "running" && string.Equals(j.Request.Environment ?? j.Planned.Environment, env, StringComparison.Ordinal))
            .OrderBy(j => j.Sequence).Select(j => Describe(j, StatusView.Default)).ToList();

    /// <summary>What repository builds and test projects usually take (job_stats), slowest first; optionally of one repository.</summary>
    public IReadOnlyList<DurationStat> DurationStats(string? repo = null) =>
        _history.Stats().Where(s => repo == null || string.Equals(s.Repo, repo, StringComparison.OrdinalIgnoreCase) ||
                                    string.Equals(s.Repo, "octo-" + repo, StringComparison.OrdinalIgnoreCase)).ToList();

    public IReadOnlyList<BuildRefusal> Refusals()
    {
        lock (_refusalLock)
        {
            // A refusal is over once a later build of the same target was queued (e.g. the retry with stopServices=true).
            return _refusals.Where(r => DateTimeOffset.Now - r.At < TimeSpan.FromHours(2) &&
                                        !_jobs.Values.Any(j => j.QueuedAt > r.At && j.Planned.Target == r.Target))
                .Reverse().ToList();
        }
    }

    /// <param name="env">The environment the caller works in: every session of an environment may cancel its builds.</param>
    public BuildStatus Cancel(string id, string owner, string? env = null)
    {
        if (!_jobs.TryGetValue(id, out var job))
        {
            throw new InvalidOperationException(UnknownJob(id));
        }

        var sameEnvironment = env != null && job.Request.Environment != null && string.Equals(job.Request.Environment, env, StringComparison.Ordinal);
        if (!sameEnvironment && !string.Equals(job.Request.Owner, owner, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Job {id} belongs to '{job.Request.Owner}'" +
                                                (job.Request.Environment != null ? $" (lane {job.Request.Environment}; pass lane to cancel it)." : "."));
        }

        // A queued job ends at once; the scheduler skips it. A running one is canceled through its token.
        if (job.TryCancelQueued())
        {
            Schedule();
        }
        else
        {
            job.Cancellation.Cancel();
        }

        return Describe(job, StatusView.Default);
    }

    /// <summary>
    ///     Why a sync of <paramref name="env"/> must not run now (lane_sync): a range/all build of its base lane runs or waits,
    ///     or a build of the environment itself does. Null when it may.
    /// </summary>
    public string? SyncBlocker(string env)
    {
        lock (_enqueueLock)
        {
            if (MainJobOf(new BuildRequest { Owner = "lane_sync", Kind = BuildKind.Env, Environment = env }) is { } main)
            {
                return $"build {main.Id} ({main.Kind} {main.Planned.Target}, {main.Request.Owner}) is {main.State} in the base lane {main.Planned.Lane}; " +
                       "the lane would copy a half-built feed. Wait for it (job_status(id, waitSeconds)) and sync again.";
            }
        }

        var own = ActiveFor(env);
        return own.Count > 0 ? $"builds of lane '{env}' run or wait ({string.Join(", ", own.Select(b => $"{b.Id} {b.State}"))}); sync after them." : null;
    }

    /// <summary>A range or all build of the environment's base lane that runs or waits (it rewrites the feed a sync would copy).</summary>
    private BuildJob? MainJobOf(BuildRequest request)
    {
        var baseLane = request.Environment == null ? null : EnvironmentDiscovery.Find(_store.Load(), request.Environment).BasePath;
        return baseLane == null
            ? null
            : _jobs.Values.Where(j => j.State is "queued" or "running" && j.Request.Kind is BuildKind.Range or BuildKind.All && j.Planned.Lane != null &&
                                      PathScope.SamePath(j.Planned.Lane, baseLane))
                .OrderBy(j => j.Sequence).FirstOrDefault();
    }

    // ---------- running ----------

    /// <summary>The work trees the job covers, read with git (at most a few seconds per repository). Never throws.</summary>
    private static async Task<List<(string Repo, string Path, BuildRepoState State)>> ReadEvidenceAsync(BuildJob job)
    {
        var repos = job.Planned.EvidenceRepos.ToList();
        if (repos.Count == 0)
        {
            return [];
        }

        try
        {
            var states = await GitWorkTree.ReadAllAsync(repos.Select(r => r.Path).ToList());
            return repos.Select((r, i) => (r.Repo, r.Path, states[i])).ToList();
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            return repos.Select(r => (r.Repo, r.Path, new BuildRepoState(null, null, null, null, $"git could not be run: {e.Message}"))).ToList();
        }
    }

    private static void Validate(BuildRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Owner))
        {
            throw new ArgumentException("owner is required.");
        }

        if (request.StopExternal && request.Kind != BuildKind.All)
        {
            throw new ArgumentException("stopExternal applies to kind=all only; stop processes octo-devstack did not start yourself (their stop hint says how).");
        }
    }

    /// <summary>Runs a job the scheduler started (<see cref="BuildJob.TryStart"/> happened when it was promoted).</summary>
    private async Task RunAsync(BuildJob job)
    {
        var stopped = StoppedForBuild.None;
        string state;
        BuildOutcome outcome;
        var request = job.Request;
        // A job that needs the lease keeps it (of every slot it needs) for its whole run (kind=all takes up to 3 h).
        using var unpin = new Unpin(job);
        try
        {
            // What the job runs on, read before anything of it ran (a job taken over after a daemon restart has it already).
            if (!job.HasEvidence && !job.Steps.Any(s => s.StartedAt != null))
            {
                job.SetEvidenceStart(await ReadEvidenceAsync(job));
            }

            (state, outcome, stopped) = await ExecuteAsync(job);
        }
        catch (OperationCanceledException) when (_abandoned.IsCancellationRequested)
        {
            return; // the job stays as its file says; the next queue on this state folder takes it over
        }
        catch (OperationCanceledException) when (job.Cancellation.IsCancellationRequested)
        {
            state = "canceled";
            outcome = new BuildOutcome(job.CurrentRepo(), null, "canceled while running", null);
        }
        catch (Exception e)
        {
            _logger.LogError(e, "Build {Id} failed", job.Id);
            state = "failed";
            outcome = new BuildOutcome(job.CurrentRepo(), job.FailedStepFallback, e.Message, null);
        }

        try
        {
            if (job.HasEvidence)
            {
                job.SetEvidenceEnd(await ReadEvidenceAsync(job));
            }

            if (state == "canceled" && request.Kind is BuildKind.Range or BuildKind.All or BuildKind.Env)
            {
                job.AddNote(request.Packages == PackageMode.Private || request.Kind == BuildKind.Env
                    ? $"Canceled: the {(request.Kind == BuildKind.Env ? "lane's" : "private")} feed may be partially updated."
                    : $"Canceled: {job.Planned.Lane}/nuget and the base lane's package caches may be partially updated; rebuild the range before relying on them.");
            }

            stopped = stopped.Names.Count > 0 ? stopped : job.Stopped;
            if (stopped.Names.Count > 0)
            {
                // A test run only lent the services' binaries: they come back after every run, whatever its result.
                if (IsTest(job) || (state == "succeeded" && request.RestartServices) || state == "canceled")
                {
                    job.SetPhase("restarting");
                    try
                    {
                        var restart = await _supervisor.StartAfterBuildAsync(request.LeaseOwner, stopped, CancellationToken.None, request.LeaseOwnerFor);
                        var restarted = stopped.Names.Except(restart.NotStarted ?? []).ToList();
                        if (restarted.Count > 0)
                        {
                            job.AddNote($"restarted {string.Join(", ", restarted)}");
                        }

                        if (restart.NotStarted is { Count: > 0 })
                        {
                            // AB#9673: a service of a lane being removed stays stopped; the note names the lane.
                            foreach (var note in restart.Notes.Where(n => n.StartsWith("Not started again after the job", StringComparison.Ordinal)))
                            {
                                job.AddNote(note);
                            }
                        }
                    }
                    catch (Exception e) when (e is InvalidOperationException or LeaseHeldException or IOException)
                    {
                        job.AddNote($"restart of {string.Join(", ", stopped.Names)} failed: {e.Message}");
                    }
                }
                else
                {
                    job.AddNote(state == "succeeded"
                        ? $"{string.Join(", ", stopped.Names)} stay stopped (restartServices=false)"
                        : $"{string.Join(", ", stopped.Names)} not restarted because the build did not succeed");
                }
            }
        }
        finally
        {
            // The lease is free before the job counts as finished: whoever sees it finished can take the lease at once. A
            // subscriber of the lease change that throws (a state file write) must not keep the job from its final state.
            try
            {
                unpin.Dispose();
            }
            finally
            {
                job.Finish(state, state == "succeeded", outcome);
            }
        }
    }

    private async Task<(string State, BuildOutcome Outcome, StoppedForBuild Stopped)> ExecuteAsync(BuildJob job)
    {
        var token = job.Cancellation.Token;
        var stopped = StoppedForBuild.None;
        // A job taken over after a daemon restart whose first step had started is past its preflight.
        if (!job.Steps.Any(s => s.StartedAt != null))
        {
            (var refused, stopped) = await PreflightAsync(job, token);
            if (refused != null)
            {
                return ("failed", refused, stopped);
            }
        }

        var config = _store.Load();
        var octoTools = ServicePlanner.OctoToolsPath(config);
        for (var i = 0; i < job.Steps.Count; i++)
        {
            var step = job.Steps[i];
            if (step.Completed)
            {
                // Finished before the daemon restarted.
                if (!step.Success)
                {
                    return ("failed", step.Outcome!, stopped);
                }

                continue;
            }

            var result = await RunStepAsync(job, step, octoTools, token);
            if (result.Canceled)
            {
                return ("canceled", new BuildOutcome(job.CurrentRepo(), null, "canceled while running", null), stopped);
            }

            if (!step.Success)
            {
                return ("failed", step.Outcome!, stopped);
            }
        }

        var last = job.Steps[^1].Outcome!;
        return ("succeeded", job.Steps.Count == 1 ? last : new BuildOutcome(null, null, $"{job.Steps.Count} builds succeeded", last.Hint), stopped);
    }

    /// <summary>
    ///     What is checked and done right before the first step: conflicts with running services, the leases, stopping the
    ///     services in the way. Returns why nothing was built (or null) and what it stopped.
    /// </summary>
    private async Task<(BuildOutcome? Refused, StoppedForBuild Stopped)> PreflightAsync(BuildJob job, CancellationToken token)
    {
        var request = job.Request;
        var what = IsTest(job) ? "test run" : "build";

        // AB#9673: a job queued just before its lane's removal began does not start on a lane that is being deleted.
        if ((request.Environment ?? job.Planned.Environment) is { } lane && _supervisor.Removals.Of(lane) is { } removal)
        {
            return (new BuildOutcome(null, "preflight",
                $"Lane '{lane}' is being removed by '{removal.Owner}'{(removal.Session != null ? $" (session {removal.Session})" : "")} since {removal.Since:HH:mm:ss}; " +
                $"nothing {(IsTest(job) ? "ran" : "was built")}.", null), StoppedForBuild.None);
        }

        // Services may have started and the lease may have moved while the job was queued: check again with the same plan.
        int known;
        lock (job.Planned.Warnings)
        {
            known = job.Planned.Warnings.Count;
        }

        var conflicts = await _planner.ConflictsAsync(job.Planned);
        job.SetConflicts(conflicts);
        // A warning the check adds now (the external processes are unknown, AB#9556) reaches job_status as a note.
        List<string> added;
        lock (job.Planned.Warnings)
        {
            added = job.Planned.Warnings.Skip(known).ToList();
        }

        foreach (var warning in added)
        {
            job.AddNote(warning);
        }
        var own = conflicts.Where(c => c.Kind == "own").Select(c => c.Service).Distinct().ToList();
        var foreign = conflicts.Where(c => c.Kind == "external").ToList();
        var mayStopOwn = StopsOwn(request);
        if (own.Count > 0 && !mayStopOwn && !(request.Kind == BuildKind.Repo && request.IgnoreRunningServices))
        {
            var text = $"{string.Join(", ", own)} started while the build was queued and run(s) out of the build target; nothing was built. " +
                       "Run the build again with stopServices=true.";
            RefusedFor(request, job.Planned.Target, text, conflicts);
            return (new BuildOutcome(null, "preflight", text, null), StoppedForBuild.None);
        }

        var blocking = foreign.Where(f => !(request.Kind == BuildKind.All && request.StopExternal && f.StoppableByDaemon)).ToList();
        if (blocking.Count > 0)
        {
            var text = $"{string.Join(", ", blocking.Select(b => $"{b.Service} (pid {b.Pid}, started by {b.StartedBy}{(b.StopHint != null ? $"; stop: {b.StopHint}" : "")})"))} " +
                       "run(s) out of the build target and were not started by octo-devstack; nothing was built.";
            RefusedFor(request, job.Planned.Target, text, conflicts);
            return (new BuildOutcome(null, "preflight", text, null), StoppedForBuild.None);
        }

        var gates = _planner.Gates(job.Planned, conflicts);
        if (gates.Lease)
        {
            foreach (var slot in gates.LeaseSlots)
            {
                var holder = LeaseOf(slot).Snapshot().Holder;
                var holds = holder != null && string.Equals(holder.Owner.Trim(), request.LeaseOwnerFor(slot).Trim(), StringComparison.OrdinalIgnoreCase);
                var which = slot == SlotInfo.DefaultName ? "the stack lease" : $"the lease of slot '{slot}'";
                if (!holds && job.LeaseRequired && job.LeaseSlots.Contains(slot))
                {
                    var text = $"{request.LeaseOwnerFor(slot)} no longer holds {which} ({(holder == null ? "it expired or was released" : $"held by {Holder(holder)}")}) " +
                               $"while the {what} was queued; nothing {(IsTest(job) ? "ran" : "was built")}. Take it again (lease_acquire) and start the {what} again.";
                    return (new BuildOutcome(null, "preflight", text, null), StoppedForBuild.None);
                }

                if (!holds)
                {
                    try
                    {
                        LeaseOf(slot).Require(request.LeaseOwnerFor(slot)); // needed only now (services started while queued); take it if it is free
                    }
                    catch (LeaseHeldException e)
                    {
                        var reason = IsTest(job)
                            ? $"{string.Join(", ", own)} started while the test run was queued and run(s) from {job.Planned.TestFolder}; stopping them needs {which}: {e.Message}"
                            : $"The build now needs {which}: {e.Message}";
                        return (new BuildOutcome(null, "preflight", reason, null), StoppedForBuild.None);
                    }
                }

                if (!(job.LeaseRequired && job.LeaseSlots.DefaultIfEmpty(SlotInfo.DefaultName).Contains(slot)))
                {
                    // A lease the job did not pin when it started (needed only now): kept from expiring until the services it
                    // stops are back - a test longer than the lease's idle TTL would otherwise lose it and the restart would fail.
                    job.LatePins.Add(LeaseOf(slot).Pin(request.LeaseOwnerFor(slot)));
                }
            }
        }

        var stopped = StoppedForBuild.None;
        if ((own.Count > 0 && mayStopOwn) || foreign.Count > 0)
        {
            job.SetPhase("stopping");
            if (own.Count > 0 && mayStopOwn)
            {
                // Not cancellable (CancellationToken.None): a cancel that lands while the stop waits for the slot's start/stop
                // gate would end the job before anything was stopped or recorded; the cancel is honoured right after the stop.
                // Recorded slot by slot: when a later slot fails, the services an earlier one stopped are still restarted.
                stopped = await _supervisor.StopForBuildAsync(request.LeaseOwner, own, CancellationToken.None, request.LeaseOwnerFor, job.SetStopped);
                job.SetStopped(stopped);
            }

            if (foreign.Count > 0)
            {
                await StopExternalAsync(job, foreign, token);
            }

            job.SetPhase(null);
            token.ThrowIfCancellationRequested(); // the stop itself is not cancellable; honour a cancel now

        }

        return (null, stopped);
    }

    /// <summary>Stops non-interactive Start-Octo stacks with Stop-Octo -branch and waits until their processes are gone.</summary>
    private async Task StopExternalAsync(BuildJob job, List<BuildConflict> foreign, CancellationToken token)
    {
        var config = _store.Load();
        foreach (var branch in foreign.Select(f => f.Branch).Distinct())
        {
            var call = branch == null ? "Stop-Octo" : $"Stop-Octo -branch {PwshRunner.Quote(branch)}";
            job.AddNote($"stopped the Start-Octo stack with {call}");
            await _pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), BuildPlanner.RootPrelude(ServicePlanner.RootPath(config)) + call, new PwshRunOptions { LogFile = job.LogFile, Timeout = _options.ExternalStopTimeout },
                token);
        }

        var waited = System.Diagnostics.Stopwatch.StartNew(); // monotonic: a clock set forward must not cut the wait short
        while (foreign.Any(f => ProcessTree.IsAlive(f.Pid)))
        {
            if (waited.Elapsed > _options.ExternalStopTimeout)
            {
                var alive = foreign.Where(f => ProcessTree.IsAlive(f.Pid)).Select(f => $"{f.Service} (pid {f.Pid})");
                throw new InvalidOperationException($"Stop-Octo did not stop {string.Join(", ", alive)} within {_options.ExternalStopTimeout.TotalSeconds:0} s; nothing was built.");
            }

            await Task.Delay(_options.PollInterval, token);
        }
    }

    private async Task<StepResult> RunStepAsync(BuildJob job, StepRun step, string octoTools, CancellationToken token)
    {
        StepResult result;
        if (step is { StartedAt: not null, Pid: not null })
        {
            // Taken over after a daemon restart: the step's process runs (or ran) without this daemon.
            result = await WatchAsync(job, step, null, token);
        }
        else
        {
            result = await StartStepAsync(job, step, octoTools, token);
        }

        job.Pid = null;
        PersistRunning();
        FinalizeStep(job, step, result);
        return result;
    }

    private async Task<StepResult> StartStepAsync(BuildJob job, StepRun step, string octoTools, CancellationToken token)
    {
        var script = step.Spec.Script;
        // A repo step with its own result command (build.ps1, nothing to build, Invoke-Publish; AB#9417) has no -refreshCatalogs.
        if (job.Request.RefreshCatalogs && step.Spec.Kind != BuildKind.Test && step.Spec.ResultCommand == null)
        {
            script = (script.EndsWith(" -Json", StringComparison.Ordinal) ? script[..^" -Json".Length] : script) + " -refreshCatalogs -Json";
        }

        if (job.NoBuild && step.Spec.Kind == BuildKind.Test)
        {
            // Started next to the environment's build (AB#8832): the run must not build anything.
            script = (script.EndsWith(" -Json", StringComparison.Ordinal) ? script[..^" -Json".Length] : script) + " -build Never -Json";
        }

        if (step.Spec.UsesEvents)
        {
            script += $" -EventsFile {PwshRunner.Quote(step.EventsFile)}";
        }

        if (job.Request.Packages == PackageMode.Private && job.Planned.LaneInfo?.Feed is { } feed && job.Planned.Lane != null)
        {
            var sync = PrivateFeed.Sync(feed, Path.Combine(job.Planned.Lane, "nuget"));
            if (sync.Copied + sync.Refreshed > 0)
            {
                job.AddNote($"mirrored {sync.Copied + sync.Refreshed} lane package(s) into the private feed ({sync.KeptPrivate} built privately kept)");
            }

            var purged = PrivateFeed.PurgeStaleCache(feed, Path.Combine(Path.GetDirectoryName(feed)!, "packages"));
            if (purged.Count > 0)
            {
                job.AddNote($"purged {string.Join(", ", purged)} from the private package cache (rebuilt since it was extracted)");
            }
        }

        var body = BuildPlanner.RootPrelude(ServicePlanner.RootPath(_store.Load())) + script;
        if (_launcher != null)
        {
            // Detached: the step survives a daemon restart; the daemon only watches its exit marker, events and log.
            step.Begin(BuildStepFiles.Length(job.LogFile));
            var launched = _launcher.Start(new BuildLaunch(octoTools, body, job.LogFile, step.ExitFile, step.Spec.Environment));
            using var process = launched.Process;
            step.SetProcess(launched.Pid, launched.ProcessStart);
            job.Pid = launched.Pid;
            PersistRunning();
            return await WatchAsync(job, step, process, token);
        }

        step.Begin();
        // A test run writes the dotnet test and ng output only into its per-project logs: they count as activity (AB#9417).
        var testLogs = step.Spec.Kind == BuildKind.Test ? new TestLogActivity(() => TestResultsFolder(job, step), step.StartedAt ?? DateTimeOffset.Now,
            _options.TestLogScanInterval) : null;
        var options = new PwshRunOptions
        {
            LogFile = job.LogFile,
            Timeout = step.Spec.Timeout,
            IdleTimeout = _options.IdleTimeout,
            Environment = step.Spec.Environment,
            LastActivity = fresh =>
            {
                // The events file is read after the (possibly forced) test-log scan, so an event written during the scan counts.
                var tests = testLogs?.Last(force: fresh);
                DateTimeOffset? events = step.Spec.UsesEvents && File.Exists(step.EventsFile) ? new DateTimeOffset(File.GetLastWriteTime(step.EventsFile)) : null;
                return events == null || tests > events ? tests : events;
            },
            OnStarted = pid =>
            {
                job.Pid = pid;
                PersistRunning();
            }
        };
        return StepResult.From(await _pwsh.RunAsync(octoTools, body, options, token));
    }

    /// <summary>Reads the step's last state, decides success (cmdlet JSON AND exit code), records durations and snapshots errors.</summary>
    private void FinalizeStep(BuildJob job, StepRun step, StepResult result)
    {
        // Only the step's own cmdlet document counts: a nested cmdlet's -Json output must not pass for the result.
        var command = step.Spec.ResultCommand ?? step.Spec.Kind switch
        {
            BuildKind.Range => "Invoke-BuildRange",
            BuildKind.All => "Invoke-BuildAll",
            BuildKind.Env => "Invoke-BuildEnvironment",
            BuildKind.Test => "Invoke-OctoTestRun",
            _ => "Invoke-Build"
        };
        var json = PwshRunner.ExtractOctoJson(result.Output, command);
        var data = json?["data"] as JsonObject;
        var events = job.ReadEvents(step, finished: true);
        ApplyResult(events, data, step.Spec);
        MarkNothingBuilt(events, step.Spec);

        bool success;
        string? failedRepo = null;
        string? failedStep = null;
        string summary;
        string? hint = null;
        var jsonSuccess = step.Spec.Kind == BuildKind.All
            ? BuildPlanner.Num((data?["summary"] as JsonObject)?["failed"]) is 0
            : BuildPlanner.Bool(data?["success"]) == true;
        if (result.Canceled)
        {
            success = false;
            summary = "canceled while running";
        }
        else if (result.TimedOut || result.IdleTimedOut)
        {
            success = false;
            failedRepo = events.Repos.FirstOrDefault(r => r.State == "building")?.Repo;
            failedStep = "timeout";
            summary = result.IdleTimedOut
                ? IdleSummary(job, step)
                : $"timed out after {step.Spec.Timeout.TotalMinutes:0} min; the build was terminated";
        }
        else if (result.ExitCode == null)
        {
            // No exit marker: the wrapper was killed, or a daemon version without markers started the build. What the
            // build itself wrote decides - its 'done' event and, when it got that far, its -Json document.
            var known = events.Done != null || data != null;
            success = known && (events.Done?.Success ?? true) && (data == null || jsonSuccess);
            var source = "the process left no exit code; result from " + (events.Done != null && data != null ? "its build events and -Json document" :
                events.Done != null ? "its build events" : "its -Json document");
            if (!known)
            {
                failedRepo = events.Repos.FirstOrDefault(r => r.State == "building")?.Repo;
                failedStep = "lost";
                summary = "the build process ended without a result (no exit marker, no 'done' event): it was killed or the machine went down; see logs.job";
            }
            else if (success)
            {
                summary = $"{events.Repos.Count(r => r.State == "done")} repo(s) built ({source})";
            }
            else
            {
                failedRepo = BuildPlanner.Str(data?["failedRepo"]) ?? events.Done?.FailedRepo ?? events.Repos.FirstOrDefault(r => r.State == "failed")?.Repo;
                failedStep = BuildPlanner.Str(data?["failedStep"]) ?? events.Done?.FailedStep ?? "build";
                summary = $"build failed{(failedRepo != null ? $" in {failedRepo}" : "")} ({failedStep}; {source})";
            }
        }
        else if (data == null)
        {
            success = false;
            failedStep = events.Done?.FailedStep ?? "preflight";
            // A build.ps1 that ends with a terminating error prints no result document: the repo of a repo step is known.
            failedRepo = events.Done?.FailedRepo ?? (step.Spec.Kind == BuildKind.Repo ? step.Spec.Repos.FirstOrDefault()?.Name : null);
            summary = $"{command} printed no -Json result of its own (exit code {result.ExitCode}); see logs.job";
        }
        else
        {
            success = jsonSuccess && result.ExitCode == 0;
            hint = BuildPlanner.Str(data["hint"]);
            if (!success)
            {
                failedRepo = BuildPlanner.Str(data["failedRepo"]) ?? events.Done?.FailedRepo ?? events.Repos.FirstOrDefault(r => r.State == "failed")?.Repo ??
                    (step.Spec.Kind == BuildKind.Repo ? step.Spec.Repos.FirstOrDefault()?.Name : null);
                failedStep = BuildPlanner.Str(data["failedStep"]) ?? events.Done?.FailedStep ?? (BuildPlanner.Str(data["error"]) != null ? "preflight" : "build");
                summary = BuildPlanner.Str(data["error"]) ?? (jsonSuccess
                    ? $"the cmdlet reported success but exited with {result.ExitCode}"
                    : $"build failed{(failedRepo != null ? $" in {failedRepo}" : "")}{(failedStep != null ? $" ({failedStep})" : "")}");
            }
            else
            {
                summary = step.Spec.Kind switch
                {
                    BuildKind.Repo when step.Spec.Repos[0].Mode == "none" => $"{step.Spec.Repos[0].Name}: {BuildPlanner.Str(data["detail"]) ?? "nothing to build"}",
                    BuildKind.Repo => $"{step.Spec.Repos[0].Name} built" + (step.Spec.Repos[0].Mode == "dotnet" ? "" : $" (mode {step.Spec.Repos[0].Mode})"),
                    _ => $"{events.Repos.Count(r => r.State == "done")} repo(s) built" + SkippedText(events)
                } + TestsNote(job.Request, step.Spec);
            }
        }

        if (!success && failedRepo != null && events.Repos.FirstOrDefault(r => string.Equals(r.Repo, failedRepo, StringComparison.OrdinalIgnoreCase)) is { } failed &&
            failed.State is "building" or "pending" or "done")
        {
            failed.State = "failed";
        }

        foreach (var run in events.Repos)
        {
            if (run.State == "building")
            {
                run.State = "failed";
            }

            if (!success && run.State == "pending")
            {
                run.State = "skipped";
            }

            if (run.State == "done" && step.Spec.HistoryLane.Length > 0 && (run.Seconds ?? run.BuildSeconds) is { } seconds)
            {
                _history.Record(step.Spec.HistoryLane, run.Repo, job.Planned.Configuration, seconds);
            }
        }

        // Every built repo's log is kept (the next build of the repo deletes it): the status page shows it after the
        // build and after a daemon restart; a failed repo's errors are parsed for job_status. A log the cmdlet names
        // belongs to this build; <repo>/Invoke-Build.log only when this step wrote it - a build.ps1 or Invoke-Publish step
        // writes none, and an older one (an earlier Invoke-Build of the repo) would report another build's errors
        // (AB#9464: MSB1003 for a frontend repo whose build.ps1 failed). Without a log of its own, a failed repo of such a
        // step keeps the step's output.
        foreach (var run in events.Repos.Where(r => r.State is "failed" or "done"))
        {
            var plan = step.Spec.Repos.FirstOrDefault(p => string.Equals(p.Name, run.Repo, StringComparison.OrdinalIgnoreCase));
            // A build.ps1 or nothing-to-build step (its own result document) never writes <repo>/Invoke-Build.log, so one there
            // is always an older build's - also one written a second before this step started. Invoke-Publish recreates it.
            var log = run.LogFile ?? (plan == null || step.Spec.ResultCommand == BuildPlanner.RepoScriptCommand ? null : Path.Combine(plan.Path, "Invoke-Build.log"));
            var ofThisBuild = log != null && File.Exists(log) &&
                              ((run.State == "failed" && run.LogFile != null) || step.StartedAt == null ||
                               File.GetLastWriteTime(log) >= step.StartedAt.Value.LocalDateTime.AddSeconds(-2));
            if (ofThisBuild)
            {
                job.SnapshotLog(run.Repo, log!, run.State == "failed");
            }
            else if (run.State == "failed" && step.Spec.ResultCommand != null)
            {
                job.SnapshotOutput(run.Repo, result.Output, plan?.Mode ?? "script");
            }
        }

        // The cause of a failed build.ps1 or Invoke-Publish step is in its output, not in a dotnet log: say it.
        if (!success && step.Spec.ResultCommand != null && failedRepo != null && job.FirstErrorOf(failedRepo) is { } cause)
        {
            summary += $": {cause.Message}";
        }

        if (!success && hint == null && job.HasErrors)
        {
            hint = $"job_status(id, repo=\"{failedRepo ?? job.FirstErrorRepo}\") lists up to {BuildLogParser.MaxStoredPerRepo} errors of a repo.";
        }

        // An environment build that skipped a repo others depend on says what may be stale now (AB#8814).
        foreach (var warning in (data?["staleWarnings"] as JsonArray ?? []).OfType<JsonObject>())
        {
            if (BuildPlanner.Str(warning["message"]) is { Length: > 0 } message)
            {
                job.AddNote($"stale: {message}");
            }
        }

        if (step.Spec.Kind == BuildKind.Test)
        {
            // The test projects with their failed tests; summary and hint speak of tests, the "repo" is the project.
            var tests = ExplainBuildReasons(TestProjects(events, data), job.Planned.TestFolder, job.Planned.Configuration);
            job.SetTests(tests);
            RecordTestDurations(job, events);
            var interrupted = result.Canceled || result.TimedOut || result.IdleTimedOut;
            var failedTests = tests.Sum(t => t.Failed ?? 0);
            if (success)
            {
summary = $"{tests.Sum(t => t.Passed ?? 0)} test(s) passed in {tests.Count(t => t.State is "passed" or "noTests")} project(s)" +
                          (tests.Sum(t => t.Skipped ?? 0) is > 0 and var skipped ? $", {skipped} skipped" : "") +
                          (tests.Count(t => t.State == "noMatch") is > 0 and var noMatch ? $"; the filter matched nothing in {noMatch} project(s)" : "");
            }
            else if (!interrupted)
            {
                failedRepo = BuildPlanner.Str(data?["failedProject"]) ?? events.Done?.FailedRepo ?? tests.FirstOrDefault(t => t.State is "failed" or "error")?.Project;
                if (BuildPlanner.Str(data?["error"]) is not { Length: > 0 } && failedTests > 0)
                {
                    var projects = tests.Where(t => (t.Failed ?? 0) > 0).Select(t => t.Project).ToList();
                    summary = $"{failedTests} of {tests.Sum(t => t.Total ?? 0)} test(s) failed in {string.Join(", ", projects)}";
                }
                else if (DockerRefusal(DockerOf(data)) is { } refused)
                {
                    // octo-tools AB#8835: too little free memory in the Docker engine, the Docker projects did not start.
                    summary = refused;
                }
                else if (BuildPlanner.Str(data?["error"]) is not { Length: > 0 } && !tests.Any(t => t.State == "error") &&
                         tests.Where(t => t.State == "noTests").Select(t => t.Project).ToList() is { Count: > 0 } empty)
                {
                    // octo-tools AB#8832: a project that runs no test although no filter was given is a failure, never green.
                    summary = $"no test ran in {string.Join(", ", empty)}";
                }
                else if (BuildPlanner.Str(data?["error"]) is not { Length: > 0 } && tests.Count > 0 && tests.All(t => t.State is "noMatch" or "skipped" or "notRun"))
                {
                    summary = "the filter matched no test in any project";
                }

                if (failedTests > 0)
                {
                    hint = $"job_status(id, project=\"{failedRepo}\") lists the failed tests of a project; lane_test / base_test(..., rerunFailed=true) runs only those again.";
                }
            }
        }

        if (json != null)
        {
            job.AddResult(json);
        }

        // A parallel build can fail in more than one repo (the ones that ran when the first failed finish too).
        var failedRepos = (data?["failedRepos"] as JsonArray ?? []).Select(BuildPlanner.Str).Where(r => !string.IsNullOrEmpty(r)).Select(r => r!).Distinct().ToList();
        if (!success && failedRepos.Count > 1 && step.Spec.Kind != BuildKind.Test)
        {
            summary = $"build failed in {string.Join(", ", failedRepos)}{(failedStep != null ? $" ({failedStep})" : "")}";
        }

        job.SetOutputTail(PwshRunner.Tail(result.Output, 200));
        step.Complete(events, success, new BuildOutcome(failedRepo, failedStep, summary, hint) { FailedRepos = !success && failedRepos.Count > 1 ? failedRepos : null });
    }

    /// <summary>
    ///     What a build did with a repo's test projects: compiled (Invoke-Build and Invoke-BuildAll build the whole solution;
    ///     range and environment builds with verifyTests or includeTests) or notCompiled. No build runs a test.
    /// </summary>
    internal static string? TestsOf(BuildRequest request, StepSpec step) => step.Kind switch
    {
        BuildKind.Test => null,
        // A build.ps1, Invoke-Publish or nothing-to-build repo step says nothing about .NET test projects (AB#9417).
        BuildKind.Repo when step.Repos.Count > 0 && step.Repos[0].Mode != "dotnet" => null,
        BuildKind.Repo or BuildKind.All => "compiled",
        _ => request.VerifyTests || request.IncludeTests ? "compiled" : "notCompiled"
    };

    /// <summary>The sentence a build's summary ends with, so nobody takes a green build for green tests.</summary>
    private static string TestsNote(BuildRequest request, StepSpec step) => TestsOf(request, step) switch
    {
        "compiled" => "; test projects compiled, no test ran (lane_test / base_test run them)",
        "notCompiled" => "; test projects NOT compiled and no test ran (verifyTests=true compiles them, lane_test / base_test run them)",
        _ => ""
    };

    /// <summary>", 3 skipped (2 unchanged, 1 excluded)" for the repos a build left out; empty when it built all.</summary>
    private static string SkippedText(StepEvents events)
    {
        var skipped = events.Repos.Where(r => r.State == "skipped" && r.Reason != null).ToList();
        return skipped.Count == 0
            ? ""
            : $", {skipped.Count} skipped ({string.Join(", ", skipped.GroupBy(r => r.Reason).Select(g => $"{g.Count()} {g.Key}"))})";
    }

    /// <summary>
    ///     The test projects of a test run from the cmdlet's -Json document (state, counts, failed tests, errors); for a
    ///     project the document does not name - or without a document - what the events say.
    /// </summary>
    private static List<BuildTestProject> TestProjects(StepEvents events, JsonObject? data)
    {
        var result = new List<BuildTestProject>();
        foreach (var entry in (data?["projects"] as JsonArray ?? []).OfType<JsonObject>())
        {
            if (BuildPlanner.Str(entry["project"]) is not { } name)
            {
                continue;
            }

            var failed = (entry["failedTests"] as JsonArray ?? []).OfType<JsonObject>()
                .Select(t => new BuildFailedTest(BuildPlanner.Str(t["name"]) ?? BuildPlanner.Str(t["displayName"]) ?? "?",
                    BuildPlanner.Str(t["message"]) is { } m ? SecretMask.MaskValue(m) : null, BuildPlanner.Str(t["stackFrame"]))).ToList();
            var errors = (entry["errors"] as JsonArray ?? []).Select(BuildPlanner.Str).Where(e => !string.IsNullOrWhiteSpace(e)).Select(e => SecretMask.MaskValue(e!)).ToList();
            var failedCount = (int?)BuildPlanner.Num(entry["failed"]);
            var passed = entry["passedTests"] is JsonArray names ? names.Select(BuildPlanner.Str).OfType<string>().ToList() : null;
            result.Add(new BuildTestProject(name, BuildPlanner.Str(entry["state"]) ?? (BuildPlanner.Bool(entry["success"]) == false ? "failed" : "passed"),
                (int?)BuildPlanner.Num(entry["total"]), (int?)BuildPlanner.Num(entry["passed"]), failedCount, (int?)BuildPlanner.Num(entry["skipped"]),
                Round(BuildPlanner.Num(entry["durationSeconds"])), failed, failedCount > failed.Count ? failedCount - failed.Count : null,
                errors.Count > 0 ? errors : null, BuildPlanner.Str(entry["buildReason"]), BuildPlanner.Bool(entry["docker"]), BuildPlanner.Str(entry["note"]),
                BuildPlanner.Str(entry["runner"]), passed, passed == null ? null : BuildPlanner.Bool(entry["passedTruncated"]) == true ? true : null));
        }

        foreach (var run in events.Repos.Where(r => !result.Any(p => string.Equals(p.Project, r.Repo, StringComparison.OrdinalIgnoreCase))))
        {
            result.Add(FromEvents(run, finished: true));
        }

        return result;
    }

    /// <summary>
    ///     "no DebugL build output of X" from Invoke-OctoTestRun although a build (lane_build with verifyTests) compiled X: octo-tools looks for the test
    ///     assembly only below &lt;project&gt;/bin/&lt;configuration&gt;, while the repository builds into &lt;repo&gt;/bin/&lt;configuration&gt;,
    ///     so the run compiles the project again. Explained when that is really the case - X.dll exists below the repository's
    ///     bin/&lt;configuration&gt; (octo-tools follow-up in docs/claude-pm-integration.md).
    /// </summary>
    internal static List<BuildTestProject> ExplainBuildReasons(List<BuildTestProject> projects, string? repoFolder, string configuration)
    {
        if (repoFolder == null)
        {
            return projects;
        }

        var bin = Path.Combine(repoFolder, "bin", configuration);
        return projects.Select(p =>
        {
            if (p.BuildReason is not { } reason || !reason.StartsWith($"no {configuration} build output of {p.Project}", StringComparison.Ordinal) || !Directory.Exists(bin))
            {
                return p;
            }

            bool built;
            try
            {
                built = Directory.EnumerateFiles(bin, p.Project + ".dll", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint })
                    .Any();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                built = false;
            }

            return built
                ? p with
                {
                    // Read after the run, so the assembly may be this run's own output: say only where it is and where octo-tools looks.
                    BuildReason = reason + $" - the assembly exists in <repo>/bin/{configuration} (this repository builds there), but octo-tools looks only " +
                                  $"below <project>/bin/{configuration}, so a test run compiles the test projects itself (harmless; an octo-tools follow-up)"
                }
                : p;
        }).ToList();
    }

    /// <summary>A test project as its events describe it (no test names: those come with the cmdlet's result).</summary>
    private static BuildTestProject FromEvents(RepoRun run, bool finished)
    {
        var state = run.State switch
        {
            "building" => finished ? "error" : "running",
            "done" => run.TestState ?? (run.Total == 0 ? "noTests" : "passed"),
            "failed" => run.TestState ?? ((run.Failed ?? 0) > 0 ? "failed" : "error"),
            "pending" => finished ? "notRun" : "pending",
            _ => run.State
        };
        return new BuildTestProject(run.Repo, state, run.Total, run.Passed, run.Failed, run.Skipped, Round(run.Seconds), [], (run.Failed ?? 0) > 0 ? run.Failed : null,
            null, run.BuildReason, run.Docker, Runner: run.Runner);
    }

    /// <summary>
    ///     AB#9384: a repo the step reports as done, but in which nothing could be built - no solution, no project file and
    ///     no build.ps1 in its root (octo-tools: "No solution file found"), e.g. octo-frontend-libraries in Invoke-BuildAll -
    ///     is never "done": it is "skipped" with reason nothingToBuild, and the detail names the repo of the step whose
    ///     build.ps1 builds it (octo-frontend-refinery-studio builds ../octo-frontend-libraries) where one does.
    /// </summary>
    internal static void MarkNothingBuilt(StepEvents events, StepSpec spec)
    {
        foreach (var run in events.Repos.Where(r => r.State == "done").ToList())
        {
            var plan = spec.Repos.FirstOrDefault(p => string.Equals(p.Name, run.Repo, StringComparison.OrdinalIgnoreCase));
            if (plan == null || !(plan.Mode == "none" || BuildPlanner.RepoBuildMode(plan.Path, plan.Name) == "none"))
            {
                continue;
            }

            run.State = "skipped";
            run.Reason = "nothingToBuild";
            // Only a builder that ran and succeeded in this step built it (an excluded or failed one did not).
            var builder = spec.Repos.FirstOrDefault(p => !ReferenceEquals(p, plan) &&
                                                         events.Repos.Any(r => string.Equals(r.Repo, p.Name, StringComparison.OrdinalIgnoreCase) && r.State == "done") &&
                                                         BuildsSibling(p, plan.Name));
            run.Detail = builder != null
                ? $"built by {builder.Name} (its build.ps1 builds ../{plan.Name})"
                : "no solution, project file or build.ps1 in the repository root: nothing was built";
        }

        static bool BuildsSibling(PlanRepo repo, string sibling)
        {
            try
            {
                var script = System.IO.Path.Combine(repo.Path, "build.ps1");
                // The sibling folder itself ("../octo-frontend-libraries"), not a longer name that contains it.
                return File.Exists(script) && System.Text.RegularExpressions.Regex.IsMatch(File.ReadAllText(script),
                    @"\.\.[\\/]" + System.Text.RegularExpressions.Regex.Escape(sibling) + @"(?![A-Za-z0-9_.-])", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return false;
            }
        }
    }

    /// <summary>The cmdlet's JSON is authoritative for durations, counts and success per repo (and the only source without events).</summary>
    private static void ApplyResult(StepEvents events, JsonObject? data, StepSpec spec)
    {
        if (data == null)
        {
            return;
        }

        if (spec.Kind == BuildKind.Test)
        {
            foreach (var entry in (data["projects"] as JsonArray ?? []).OfType<JsonObject>())
            {
                if (BuildPlanner.Str(entry["project"]) is not { } name)
                {
                    continue;
                }

                var run = events.Repo(name);
                run.State = BuildPlanner.Str(entry["state"]) switch
                {
                    "passed" or "noMatch" => "done",
                    // No test ran: a failure since octo-tools AB#8832 (the entry says success: false), a success before.
                    "noTests" => BuildPlanner.Bool(entry["success"]) == false ? "failed" : "done",
                    "failed" or "error" => "failed",
                    "skipped" or "notRun" => "skipped",
                    _ => run.State
                };
                // Without project events (an older octo-tools or a lost events file) the result's state is the only one.
                run.TestState ??= BuildPlanner.Str(entry["state"]);
                run.Seconds = BuildPlanner.Num(entry["durationSeconds"]) ?? run.Seconds;
                run.TestSeconds = run.Seconds;
                run.Total = (int?)BuildPlanner.Num(entry["total"]) ?? run.Total;
                run.Passed = (int?)BuildPlanner.Num(entry["passed"]) ?? run.Passed;
                run.Failed = (int?)BuildPlanner.Num(entry["failed"]) ?? run.Failed;
                run.Skipped = (int?)BuildPlanner.Num(entry["skipped"]) ?? run.Skipped;
                run.LogFile ??= BuildPlanner.Str(entry["logFile"]);
            }

            return;
        }

        if (spec.Kind == BuildKind.Repo && spec.Repos.Count > 0)
        {
            var run = events.Repo(spec.Repos[0].Name);
            if (BuildPlanner.Bool(data["success"]) is { } ok)
            {
                run.State = ok ? "done" : "failed";
            }

            run.LogFile ??= BuildPlanner.Str(data["logFile"]);
            return;
        }

        foreach (var entry in (data["repositories"] as JsonArray ?? []).OfType<JsonObject>())
        {
            if (BuildPlanner.Str(entry["repo"]) is not { } name)
            {
                continue;
            }

            var run = events.Repo(name);
            run.Reason = BuildPlanner.Str(entry["reason"]) ?? run.Reason;
            run.Detail = BuildPlanner.Str(entry["detail"]) ?? run.Detail;
            if (BuildPlanner.Str(entry["status"]) == "skipped")
            {
                // Not built (unchanged, not selected, excluded): no durations, no packages.
                run.State = "skipped";
                continue;
            }

            if (BuildPlanner.Bool(entry["success"]) is { } ok)
            {
                run.State = ok ? "done" : "failed";
            }

            run.BuildSeconds = BuildPlanner.Num(entry["buildSeconds"]) ?? BuildPlanner.Num(entry["durationSeconds"]) ?? run.BuildSeconds;
            run.TestSeconds = BuildPlanner.Num(entry["testCompileSeconds"]) ?? run.TestSeconds;
            run.PackageSeconds = BuildPlanner.Num(entry["packageSeconds"]) ?? run.PackageSeconds;
            run.CatalogSeconds = BuildPlanner.Num(entry["catalogSeconds"]) ?? run.CatalogSeconds;
            run.RestoreSeconds = BuildPlanner.Num(entry["restoreSeconds"]) ?? run.RestoreSeconds;
            run.CompileSeconds = BuildPlanner.Num(entry["compileSeconds"]) ?? run.CompileSeconds;
            run.TestRestoreSeconds = BuildPlanner.Num(entry["testRestoreSeconds"]) ?? run.TestRestoreSeconds;
            run.Seconds ??= (run.BuildSeconds ?? 0) + (run.TestSeconds ?? 0) + (run.PackageSeconds ?? 0);
            if (BuildPlanner.Num(entry["copiedCount"]) is { } copied)
            {
                run.Copied = (int)copied;
            }

            if (entry["purged"] is JsonArray purged)
            {
                run.Purged = purged.Count;
            }

            run.LogFile ??= BuildPlanner.Str(entry["logFile"]);
        }

        foreach (var name in (data["notBuilt"] as JsonArray ?? []).Select(BuildPlanner.Str).Where(n => n != null))
        {
            var run = events.Repo(name!);
            if (run.State is "pending" or "building")
            {
                run.State = "skipped";
            }
        }
    }

    // ---------- describe ----------

    private sealed record StatusView(string? Repo, bool ErrorsOnly, bool Raw, int TailLines, int Live = 0, bool Passed = false)
    {
        public static readonly StatusView Default = new(null, false, false, 0);
    }

    private BuildStatus Describe(BuildJob job, StatusView view)
    {
        var snapshot = job.Snapshot();
        var position = snapshot.State == "queued" ? _jobs.Values.Count(j => j.State == "queued" && j.Sequence <= job.Sequence) : 0;

        var (progress, eta) = snapshot.State == "queued" || view.ErrorsOnly ? (null, null) : Progress(job, snapshot);
        if (progress != null && view.Repo != null)
        {
            // repo=X of a build, project=X of a test run.
            List<BuildRepoProgress> Only(IReadOnlyList<BuildRepoProgress> rows) => rows.Where(r => string.Equals(r.Name, view.Repo, StringComparison.OrdinalIgnoreCase)).ToList();
            progress = progress with { Repos = progress.Repos is { } repos ? Only(repos) : null, Projects = progress.Projects is { } projects ? Only(projects) : null };
        }

        BuildDiagnostics? diagnostics = null;
        if (snapshot.Errors.Count > 0 || snapshot.WarningCount > 0)
        {
            var errors = view.Repo != null
                ? snapshot.Errors.GetValueOrDefault(view.Repo) ?? snapshot.Errors.FirstOrDefault(e => string.Equals(e.Key, view.Repo, StringComparison.OrdinalIgnoreCase)).Value ?? []
                : snapshot.Errors.SelectMany(e => e.Value.Take(ErrorsPerRepoInStatus)).ToList();
            diagnostics = new BuildDiagnostics(snapshot.ErrorCount, snapshot.WarningCount, errors);
        }

        double? elapsed = snapshot.StartedAt == null ? null : Math.Round(((snapshot.FinishedAt ?? DateTimeOffset.Now) - snapshot.StartedAt.Value).TotalSeconds, 1);
        // Compact: the kept logs of the failed repos (and of the repo asked for); the status page reads the others itself.
        var failedRepos = job.Steps.SelectMany(s => s.Read(false).Repos).Where(r => r.State == "failed").Select(r => r.Repo)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var perRepo = snapshot.PerRepoLogs.Where(l => failedRepos.Contains(l.Key) || string.Equals(l.Key, view.Repo, StringComparison.OrdinalIgnoreCase))
            .ToDictionary(l => l.Key, l => l.Value);
        if (progress?.Current is { Repo: { } currentRepo } && snapshot.FinishedAt == null)
        {
            var plan = job.Steps.SelectMany(s => s.Spec.Repos).FirstOrDefault(r => r.Name == currentRepo);
            if (plan != null)
            {
                perRepo.TryAdd(currentRepo, Path.Combine(plan.Path, "Invoke-Build.log"));
            }
        }

        BuildRaw? raw = null;
        if (view.Raw)
        {
            var tail = snapshot.OutputTail ?? LogReader.Tail(job.LogFile, Math.Max(view.TailLines, 1));
            raw = new BuildRaw(snapshot.Results, view.TailLines <= 0 || tail == null ? tail : PwshRunner.Tail(tail, view.TailLines));
        }

        return new BuildStatus(job.Id, job.Request.Owner, snapshot.State, snapshot.FinishedAt == null ? null : snapshot.Success, BuildStatus.ShownKind(job.Kind), job.Planned.Target,
            job.Planned.Configuration, view.ErrorsOnly ? null : job.Planned.LaneInfo, position > 0 ? new BuildQueueInfo(position, WaitReason(job)) : null,
            new BuildTimes(job.QueuedAt, snapshot.StartedAt, snapshot.FinishedAt, elapsed, eta), progress, snapshot.Outcome, diagnostics,
            snapshot.Stopped.Count > 0 || snapshot.FinishedAt != null ? snapshot.Stopped : job.PlannedStops, view.ErrorsOnly ? [] : snapshot.Notes, new BuildLogs(job.LogFile, perRepo.Count > 0 ? perRepo : null), raw,
            job.Request.Environment, IsTest(job) && snapshot.State != "queued" ? WithDockerWarning(Tests(job, snapshot, view), snapshot.FinishedAt != null) : null,
            view.Live > 0 && snapshot.State != "queued" ? Shorten(LogOf(job, snapshot, Rows(job), view.Repo, view.Live)) : null,
            snapshot.Results.Select(r => CatalogsOf(r["data"] as JsonObject ?? r)).LastOrDefault(c => c != null),
            snapshot.FinishedAt == null ? null : LaneRepositories.GoneReason(job.Request.Environment ?? job.Planned.Environment, job.Planned.EnvironmentPath ?? job.Planned.Lane, job.Planned.Lane, job.Kind, job.Planned.Target, job.Request.Repo),
            Evidence(snapshot, view));
    }

    /// <summary>
    ///     The evidence of a job: every repository, or the one of repo=X; a job with more than <see cref="MaxEvidenceRepos"/>
    ///     lists in the compact status only the repositories that are not fine (finished: not unchanged; running: not read at the
    ///     start) and counts the others as omitted. unchanged is the whole job's and comes when it finished.
    /// </summary>
    private static BuildEvidence? Evidence(JobSnapshot snapshot, StatusView view)
    {
        var repos = snapshot.Evidence;
        if (repos.Count == 0 || view.ErrorsOnly)
        {
            return null;
        }

        bool? unchanged = snapshot.FinishedAt == null ? null : repos.All(r => r.Unchanged == true);
        if (view.Repo != null)
        {
            var one = repos.Where(r => string.Equals(r.Repo, view.Repo, StringComparison.OrdinalIgnoreCase)).ToList();
            return one.Count == 0 ? null : new BuildEvidence(unchanged, one);
        }

        if (view.Raw || repos.Count <= MaxEvidenceRepos)
        {
            return new BuildEvidence(unchanged, repos);
        }

        static bool Fine(BuildRepoEvidence r) => r.End == null ? r.Start is { Clean: not null, Head: not null, Error: null } : r.Unchanged == true;
        var shown = repos.Where(r => !Fine(r)).ToList();
        return new BuildEvidence(unchanged, shown, repos.Count - shown.Count);
    }

    /// <summary>The run's catalogs block (octo-tools AB#8831) as one line: how the remote CK catalogs were read for this build.</summary>
    internal static string? CatalogsOf(JsonObject? data)
    {
        if (data?["catalogs"] is not JsonObject catalogs || BuildPlanner.Str(catalogs["mode"]) is not { } mode)
        {
            return null;
        }

        var text = mode switch
        {
            "fresh" => "the local copy of the remote CK catalogs was fresh, nothing was read",
            "refreshed" => "the remote CK catalogs were read once for this run",
            "unavailable" => "the remote CK catalogs could not be reached; the build used the local copy",
            "failed" => "reading the remote CK catalogs failed",
            "perCompile" => "every CK compile read the remote CK catalogs again (refreshCatalogs)",
            "notNeeded" => "no repository of the run compiles a CK model",
            _ => mode
        };
        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        return mode + ": " + text +
               (BuildPlanner.Num(catalogs["seconds"]) is > 0.05 and var seconds ? string.Create(invariant, $" ({seconds:0.#} s") +
                                                                                 (BuildPlanner.Str(catalogs["repo"]) is { Length: > 0 } repo ? $", triggered by {repo})" : ")") : "") +
               (BuildPlanner.Str(catalogs["detail"]) is { Length: > 0 } detail ? $" - {SecretMask.MaskValue(detail)}" : "");
    }

    /// <summary>The cmdlet's docker block, compact; null when the run needed no Docker or the octo-tools has no check.</summary>
    internal static BuildTestDocker? DockerOf(JsonObject? data)
    {
        if (data?["docker"] is not JsonObject docker || BuildPlanner.Bool(docker["required"]) != true || BuildPlanner.Str(docker["check"]) is not { } check)
        {
            return null;
        }

        static double? Gib(JsonNode? n) => BuildPlanner.Num(n) is { } v ? Math.Round(v, 1) : null;
        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        var containers = (docker["containers"] as JsonArray ?? []).OfType<JsonObject>().Where(c => BuildPlanner.Num(c["memoryGiB"]) >= 0.05).Take(3)
            .Select(c => string.Create(invariant, $"{BuildPlanner.Str(c["name"])} ({Gib(c["memoryGiB"]):0.#} GiB)")).ToList();
        var limits = docker["limits"] as JsonObject;
        var limitText = string.Join(", ", new[]
        {
            BuildPlanner.Num(limits?["cpus"]) is > 0 and var cpus ? string.Create(invariant, $"{cpus:0.##} CPUs") : null,
            (BuildPlanner.Str(limits?["memory"]) ?? limits?["memory"]?.ToString()) is { Length: > 0 } memory && memory != "0" ? $"{memory} memory" : null
        }.OfType<string>());
        var limited = (docker["limited"] as JsonArray ?? []).OfType<JsonObject>().ToList();
        return new BuildTestDocker(check, Gib(docker["freeGiB"]), Gib(docker["minFreeGiB"]), Gib(docker["memoryGiB"]), Gib(docker["usedGiB"]), BuildPlanner.Num(docker["cpus"]),
            containers.Count > 0 ? containers : null, limitText.Length > 0 ? limitText + " per test container" : null, limited.Count > 0 ? limited.Count : null,
            limited.Count(l => BuildPlanner.Bool(l["success"]) == false) is > 0 and var failed ? failed : null,
            BuildPlanner.Str(docker["message"]) is { Length: > 0 } message ? message : null);
    }

    /// <summary>"not started: Docker has 1.2 GiB free, needs 3; biggest containers: kind-control-plane (6.1 GiB), ..." for a refused run.</summary>
    internal static string? DockerRefusal(BuildTestDocker? docker)
    {
        if (docker is not { Check: "refused" })
        {
            return null;
        }

        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        return docker.FreeGiB == null
            ? "not started: " + (docker.Message ?? "the Docker check refused the run")
            : string.Create(invariant, $"not started: Docker has {docker.FreeGiB:0.#} GiB free, needs {docker.MinFreeGiB:0.#}") +
              (docker.Containers is { Count: > 0 } ? $"; biggest containers: {string.Join(", ", docker.Containers)}" : "") +
              "; stop what is not needed, give Docker more memory, or pass dockerCheck=warn";
    }

    /// <summary>A running test run with a project that starts containers: says so when the Docker VM is small next to kind.</summary>
    private BuildTests WithDockerWarning(BuildTests tests, bool finished) =>
        !finished && _options.Docker != null && tests.Projects.Any(p => p.Docker == true) && _options.Docker.Warning() is { } warning
            ? tests with { DockerWarning = warning }
            : tests;

    /// <summary>Long lines of a build log (msbuild command lines) cut for the compact status.</summary>
    private static BuildLogText Shorten(BuildLogText log) =>
        log with { Lines = log.Lines.Select(l => l.Length > MaxLiveLineLength ? l[..MaxLiveLineLength] + " ..." : l).ToList() };

    /// <summary>
    ///     The tests of a test run: the cmdlet's result once it ended, else what its events say so far. Failed projects
    ///     first; at most <see cref="FailedTestsPerProjectInStatus"/> failed tests per project unless the view asks for one.
    /// </summary>
    private static BuildTests Tests(BuildJob job, JobSnapshot snapshot, StatusView view)
    {
        var finished = snapshot.FinishedAt != null;
        var projects = snapshot.Tests ?? Rows(job).Select(r => FromEvents(r.Run, finished)).ToList();
        var lockWait = finished ? null : job.Steps.Select(s => job.ReadEvents(s, finished: false).LockWait).FirstOrDefault(w => w != null);
        var shown = projects
            .Where(p => view.Repo == null || string.Equals(p.Project, view.Repo, StringComparison.OrdinalIgnoreCase))
            .OrderBy(p => p.State is "failed" or "error" ? 0 : p.State == "running" ? 1 : 2)
            // The names of passed tests only when asked for; the count says that there are some.
            .Select(p => p.PassedTests == null ? p : p with { PassedListed = p.PassedTests.Count > 0 ? p.PassedTests.Count : null, PassedTests = view.Passed && p.PassedTests.Count > 0 ? p.PassedTests : null })
            .Select(p => view.Repo != null || p.FailedTests.Count <= FailedTestsPerProjectInStatus
                ? p
                : p with { FailedTests = p.FailedTests.Take(FailedTestsPerProjectInStatus).ToList(), MoreFailed = (p.Failed ?? p.FailedTests.Count) - FailedTestsPerProjectInStatus })
            .ToList();
        return new BuildTests(projects.Sum(p => p.Total ?? 0), projects.Sum(p => p.Passed ?? 0), projects.Sum(p => p.Failed ?? 0), projects.Sum(p => p.Skipped ?? 0),
            lockWait == null ? null : $"waiting for the docker test lock held by {lockWait}", shown,
            Docker: snapshot.Results.Select(r => DockerOf(r["data"] as JsonObject ?? r)).LastOrDefault(d => d != null));
    }

    /// <summary>Every repo of the job in plan order (then the ones only its events name), with the step it belongs to.</summary>
    private static List<(StepRun Step, RepoRun Run)> Rows(BuildJob job)
    {
        var rows = new List<(StepRun Step, RepoRun Run)>();
        foreach (var step in job.Steps)
        {
            var events = job.ReadEvents(step, finished: false);
            var names = step.Spec.Repos.Select(r => r.Name).ToList();
            foreach (var run in names.Select(events.Repo).Concat(events.Repos.Where(r => !names.Contains(r.Repo, StringComparer.OrdinalIgnoreCase))))
            {
                rows.Add((step, run));
            }
        }

        return rows;
    }

    /// <summary>A repo's state as a finished job shows it: what still "builds" failed, what still waits was skipped.</summary>
    private static string ShownState(RepoRun run, JobSnapshot snapshot)
    {
        var finished = snapshot.FinishedAt != null;
        return finished && run.State == "building" ? "failed" : finished && run.State == "pending" && snapshot.State != "succeeded" ? "skipped" : run.State;
    }

    private (BuildProgress? Progress, double? Eta) Progress(BuildJob job, JobSnapshot snapshot)
    {
        var rows = Rows(job);
        var finished = snapshot.FinishedAt != null;
        // A parallel environment build has several repos building at once: the one that started first is "current".
        var building = finished ? [] : rows.Where(r => r.Run.State == "building").OrderBy(r => r.Run.Index ?? int.MaxValue).ThenBy(r => r.Run.StartedAt).ToList();
        var currentIndex = building.Count == 0 ? -1 : rows.IndexOf(building[0]);
        (StepRun Step, RepoRun Run)? current = currentIndex < 0 ? null : rows[currentIndex];
        var now = DateTimeOffset.Now;
        double SecondsOf(RepoRun run) => run.StartedAt is { } at ? Math.Round((now - at).TotalSeconds, 1) : 0;
        var currentSeconds = current == null ? 0 : SecondsOf(current.Value.Run);
        var parallelEvents = job.Steps.Select(s => job.ReadEvents(s, finished: false)).FirstOrDefault(e => e.Parallel);

        string State(RepoRun run) => ShownState(run, snapshot);

        // A test run's rows are its test projects: they are named project, not repo.
        var test = IsTest(job);
        var repos = rows.Select(r => new BuildRepoProgress(test ? null : r.Run.Repo, State(r.Run), Round(r.Run.BuildSeconds), Round(r.Run.TestSeconds), r.Run.Copied, r.Run.Purged,
                    Round(r.Run.Seconds), Round(r.Run.PackageSeconds), State(r.Run) == "building" ? r.Run.Phase : null, test ? null : r.Run.Reason,
                    State(r.Run) is "done" or "failed" ? TestsOf(job.Request, r.Step.Spec) : null,
                    Part(r.Run.CatalogSeconds), Part(r.Run.RestoreSeconds), Part(r.Run.CompileSeconds), Part(r.Run.TestRestoreSeconds))
                { Project = test ? r.Run.Repo : null })
            .ToList();
        var testedRepo = test ? TestedRepo(job, ReportedTestRepo(job)) : null;
        BuildCurrentRepo Now(RepoRun run, double seconds, string? phase = null) =>
            WithTypical(new BuildCurrentRepo(test ? null : run.Repo, seconds, phase) { Project = test ? run.Repo : null }, job, run, testedRepo);
        // Where the time went: the phases summed over every repo that reported them, and the slowest repo.
        var timed = rows.Where(r => r.Run.Seconds != null || r.Run.BuildSeconds != null).ToList();
        var slowest = timed.OrderByDescending(r => r.Run.Seconds ?? r.Run.BuildSeconds).FirstOrDefault();
        var totals = timed.Count == 0
            ? null
            : new BuildPhaseSeconds(Round(timed.Sum(r => r.Run.BuildSeconds ?? 0))!.Value, Round(timed.Sum(r => r.Run.TestSeconds ?? 0))!.Value,
                Round(timed.Sum(r => r.Run.PackageSeconds ?? 0))!.Value,
                timed.Count > 1 ? $"{slowest.Run.Repo} ({Round(slowest.Run.Seconds ?? slowest.Run.BuildSeconds)} s)" : null);
        var count = repos.Count;
        // How far the build is: the repos that started or were skipped (in a sequential build that is the current one's place).
        var index = current != null ? rows.Count(r => r.Run.State != "pending") : repos.Count(r => r.State is "done" or "failed" or "skipped");
        var lockWait = IsTest(job) && !finished ? job.Steps.Select(s => job.ReadEvents(s, finished: false).LockWait).FirstOrDefault(w => w != null) : null;
        var phase = snapshot.Phase ?? (lockWait != null ? "lock" : null) ?? MapPhase(current?.Run.Phase) ?? (IsTest(job) ? "tests" : "build");
        if (repos.Count > MaxListedRepos)
        {
            repos = repos.Where(r => r.State != "pending").ToList();
        }

        double? eta = null;
        if (!finished && job.Steps.All(s => s.Spec.HistoryLane.Length > 0)) // no durations are kept for an adopted build (no plan) or a test run
        {
            var pending = rows.Where(r => r.Run.State == "pending").Select(r => (r.Step.Spec.HistoryLane, r.Run.Repo)).ToList();
            eta = _history.Eta(job.Planned.Configuration, pending, current == null ? null : (current.Value.Step.Spec.HistoryLane, current.Value.Run.Repo),
                currentSeconds);
            // The other repos that build right now still need their rest too; with n builds at once the wall clock is about 1/n of the sum.
            foreach (var other in building.Skip(1))
            {
                if (_history.Eta(job.Planned.Configuration, [], (other.Step.Spec.HistoryLane, other.Run.Repo), SecondsOf(other.Run)) is { } rest)
                {
                    eta = (eta ?? 0) + rest;
                }
            }

            if (eta != null && parallelEvents?.MaxParallel is > 1 and var slots)
            {
                eta = Math.Round(eta.Value / Math.Min(slots, Math.Max(1, building.Count + pending.Count)));
            }
        }

        var source = job.Steps.All(s => s.Spec.UsesEvents) ? "events" : job.Steps.Any(s => s.Spec.UsesEvents) ? "mixed" : "logs";
        return (new BuildProgress(phase, test ? null : index, test ? null : count, current == null ? null : Now(current.Value.Run, currentSeconds), test ? null : repos,
            source, totals, building.Count > 1 ? building.Select(b => Now(b.Run, SecondsOf(b.Run), b.Run.Phase)).ToList() : null,
            parallelEvents?.MaxParallel is > 1 ? parallelEvents.MaxParallel : null)
        {
            ProjectIndex = test ? index : null, ProjectCount = test ? count : null, Projects = test ? repos : null
        }, eta);
    }

    /// <summary>
    ///     The durations of the test projects of a whole test run: a filter or rerunFailed runs only a part of a project, so such
    ///     a run says nothing about what the project usually takes. Projects that ended with passed or failed count; an error, no
    ///     tests or a project the run never finished do not.
    /// </summary>
    private void RecordTestDurations(BuildJob job, StepEvents events)
    {
        if (!string.IsNullOrWhiteSpace(job.Request.Filter) || job.Request.RerunFailed || TestedRepo(job, events.TestRepo) is not { } repo)
        {
            return;
        }

        foreach (var run in events.Repos.Where(r => r.TestState is "passed" or "failed" && r.Seconds != null))
        {
            _history.RecordTest(job.Planned.Lane ?? "", repo, run.Repo, CompilesFirst(run), job.Planned.Configuration, run.Seconds!.Value, run.FinishedAt);
        }
    }

    /// <summary>
    ///     The repository a test run tests, null for a build: the one the cmdlet reported in its plan event (resolved, also for a
    ///     worktree whose folder is named otherwise, e.g. wt-8625-octo-mesh-adapter), else the requested repo, else the tested
    ///     folder's name.
    /// </summary>
    private static string? TestedRepo(BuildJob job, string? reported) =>
        !IsTest(job) ? null
        : !string.IsNullOrWhiteSpace(reported) ? reported
        : !string.IsNullOrWhiteSpace(job.Request.Repo) ? job.Request.Repo
        : job.Planned.TestFolder is { Length: > 0 } folder ? Path.GetFileName(folder.TrimEnd('/', '\\')) : null;

    /// <summary>The repository the cmdlet reported for a test run (its plan event), null before the plan or for a build.</summary>
    private static string? ReportedTestRepo(BuildJob job) =>
        !IsTest(job) ? null : job.Steps.Select(s => job.ReadEvents(s, finished: false).TestRepo).FirstOrDefault(r => !string.IsNullOrWhiteSpace(r));

    /// <summary>Whether a test project compiled before it ran: its time includes the compile then (null when the cmdlet did not say).</summary>
    private static bool? CompilesFirst(RepoRun run) => run.NoBuild is { } noBuild ? !noBuild : null;

    /// <summary>
    ///     A running repository (or test project) with what it usually takes: typicalSeconds (median), limitSeconds, and overdue
    ///     once it runs longer than the limit - it probably hangs. A test project is compared with the runs of its own kind
    ///     (compiling first or not).
    /// </summary>
    private BuildCurrentRepo WithTypical(BuildCurrentRepo now, BuildJob job, RepoRun run, string? testedRepo)
    {
        var stat = IsTest(job)
            ? testedRepo is { } repo && now.Project is { } project
                ? _history.Typical(DurationKind.Test, repo, project, job.Planned.Configuration, CompilesFirst(run))
                : null
            : now.Repo is { } built ? _history.Typical(DurationKind.Build, built, null, job.Planned.Configuration) : null;
        return stat == null
            ? now
            : now with
            {
                TypicalSeconds = stat.MedianSeconds, LimitSeconds = stat.LimitSeconds,
                Overdue = stat.LimitSeconds is { } limit && now.Seconds > limit ? true : null
            };
    }

    private static string? MapPhase(string? phase) => phase switch
    {
        null => null,
        "tests" => "tests",
        "packages" or "purge" => "packages",
        "catalogs" => "catalogs",
        _ => "build"
    };

    /// <summary>A part of a step: left out when it took no time (most repos read no catalogs and restore no tests).</summary>
    private static double? Part(double? value) => value is >= 0.05 ? Math.Round(value.Value, 1) : null;

    private static double? Round(double? value) => value == null ? null : Math.Round(value.Value, 1);

    // ---------- orphan, refusals, trimming ----------

    /// <summary>
    ///     The conflicts that block this request: own services unless the build stops them (stopServices, kind=all, a test
    ///     run, or ignoreRunningServices for a repo build), external ones unless kind=all with stopExternal may stop them.
    /// </summary>
    internal static List<BuildConflict> BlockingConflicts(BuildRequest request, IReadOnlyList<BuildConflict> conflicts) =>
        conflicts.Where(c => c.Kind == "own"
                ? !(StopsOwn(request) || (request.Kind == BuildKind.Repo && request.IgnoreRunningServices))
                : !(request.Kind == BuildKind.All && request.StopExternal && c.StoppableByDaemon))
            .ToList();

    /// <summary>Records a refusal for the conflict banner only when running services are (part of) the reason.</summary>
    private void RefusedFor(BuildRequest request, string target, string reason, IReadOnlyList<BuildConflict> conflicts)
    {
        var blocking = BlockingConflicts(request, conflicts);
        if (blocking.Count > 0)
        {
            Refused(request, target, reason, blocking);
        }
    }

    private void Refused(BuildRequest request, string target, string reason, IReadOnlyList<BuildConflict> conflicts)
    {
        lock (_refusalLock)
        {
            _refusals.Add(new BuildRefusal(DateTimeOffset.Now, request.Owner, BuildStatus.ShownKind(request.Kind.ToString().ToLowerInvariant()), target, reason, conflicts));
            if (_refusals.Count > 10)
            {
                _refusals.RemoveAt(0);
            }
        }
    }
}
