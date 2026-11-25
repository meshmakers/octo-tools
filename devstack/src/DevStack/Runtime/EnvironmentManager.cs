using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>One lane in lane_list: the manifest, the slot its stack runs in and the jobs that run or wait for it.</summary>
public sealed record EnvironmentRow(
    string Name,
    string Path,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? WorkItem,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Base,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Owner,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DateTimeOffset? Created,
    IReadOnlyList<EnvironmentRepo> Repos,
    string Slot,
    bool Running,
    int Healthy,
    int Total,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    LeaseInfo? Lease,
    IReadOnlyList<string> Builds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Problem)
{
    /// <summary>lane_list(lane): Get-OctoEnvironment's data (per repo exists, dirty, unpushed, role, path, branch).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public JsonNode? Details { get; init; }

    /// <summary>Why the details are missing (cmdlet too old, or it failed).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? DetailsProblem { get; init; }

    /// <summary>A lane_remove that runs (owner, session, since): nothing new starts on the lane until it ends (AB#9673).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public LaneRemoval? Removing { get; init; }

    /// <summary>
    ///     The lane's slot: index, port offset and prefix. reserved = the slot exists (lane_create reserves it, or a
    ///     start created it); otherwise it is the slot the next start would get (lowest index neither in use nor retired).
    /// </summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public EnvironmentSlot? SlotInfo { get; init; }

    /// <summary>
    ///     The services of the shared stack that run this lane's build now (source lane:&lt;name&gt;, UC-A: runsFrom
    ///     "lane:&lt;name&gt;" in stack_status); null when none does.
    /// </summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<string>? InSharedStack { get; init; }
}

/// <summary>The slot an environment runs in (or would get now).</summary>
public sealed record EnvironmentSlot(string Name, int Index, int PortOffset, string Prefix, bool Reserved);

/// <summary>The result of lane_create / lane_remove / ...: the cmdlet's -Json data, what the daemon did around it, and the lane afterwards (JSON "lane").</summary>
public sealed record EnvironmentCommandResult(
    bool Success,
    int ExitCode,
    string Command,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [property: JsonPropertyName("lane")]
    EnvironmentRow? Environment,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    JsonNode? Data,
    IReadOnlyList<string> Notes,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? OutputTail)
{
    /// <summary>The message of the first pwsh error record in <see cref="OutputTail"/> (not its last, wrapped line); null when it has none.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Error => Common.PwshErrors.FirstError(OutputTail);

    /// <summary>lane_remove: the data of the removed lane stack that stays (keepData, or what a step could not drop), with the commands to drop it by hand.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<SlotLeftover>? Leftovers { get; init; }

    /// <summary>lane_remove: what the daemon dropped of the lane stack's data, store by store, and whether the slot index is free again.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public SlotDataDrop? DataDrop { get; init; }

    /// <summary>
    ///     lane_add_repo that did not run because a job of the lane still ran after the in-call wait (AB#9808): the job to wait for
    ///     with job_status before calling again.
    /// </summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RetryAfterJob { get; init; }

    /// <summary>lane_remove: the lane's feature branches - deleted when they held nothing, else kept with the reason and the command.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<LaneBranch>? Branches { get; init; }
}

/// <summary>
///     The daemon's side of lanes (octo-tools: feature environments). octo-tools owns everything on disk
///     (New-/Remove-OctoEnvironment); the daemon lists them with their slots and wraps the cmdlets: lane_remove first checks
///     which processes hold files below the lane, stops the lane stack and releases its lease, and drops the stack's data after
///     the cmdlet removed the folder.
/// </summary>
/// <param name="cleanup">Drops the data of a removed lane stack (tests pass fake stores: never the real databases).</param>
/// <param name="processLinks">(pid, parent pid) of every process (<see cref="ProcessTree.Links"/>; tests pass their own).</param>
public sealed class EnvironmentManager(ConfigStore store, StackSupervisor supervisor, BuildQueue queue, IPwshRunner pwsh, SlotDataCleanup cleanup,
    ILogger<EnvironmentManager>? logger = null, Func<DevStackConfig, ISlotInventory>? inventory = null, Func<IEnumerable<(int Pid, int ParentPid)>>? processLinks = null)
{
    public static TimeSpan CommandTimeout { get; set; } = TimeSpan.FromMinutes(15);

    public async Task<List<EnvironmentRow>> ListAsync() => await ListAsync(null, CancellationToken.None);

    /// <summary>Every environment; with <paramref name="env"/> only that one, plus Get-OctoEnvironment's details (per repo exists, dirty, unpushed).</summary>
    public async Task<List<EnvironmentRow>> ListAsync(string? env, CancellationToken cancellationToken)
    {
        var config = store.Load();
        var slots = await supervisor.SummariesAsync();
        var all = EnvironmentDiscovery.Discover(config);
        if (env == null)
        {
            return all.Select(e => Row(e, slots)).ToList();
        }

        var info = all.FirstOrDefault(e => e.Name == env) ?? throw new InvalidOperationException($"Unknown lane '{env}' (lane_list).");
        var row = Row(info, slots);
        var probed = await queue.Capabilities.GetAsync(ServicePlanner.OctoToolsPath(config), cancellationToken);
        if (!probed.Environments.Get)
        {
            return [row with { DetailsProblem = $"no details: {EnvironmentCapabilities.Unavailable(probed, "Get-OctoEnvironment -env")}" }];
        }

        var (success, exitCode, _, data, tail) = await RunAsync(config, $"Get-OctoEnvironment -env {PwshRunner.Quote(env)} -Json", "Get-OctoEnvironment", cancellationToken);
        return [success ? row with { Details = data } : row with { DetailsProblem = $"Get-OctoEnvironment failed (exit code {exitCode}): {tail}" }];
    }

    /// <summary>
    ///     Add-OctoEnvironmentRepo: a repo as a new feature/consumer worktree (repo), or an existing worktree adopted (path,
    ///     inPlace keeps it where it is). Waits for the lane's running or queued jobs (at most <see cref="AddRepoJobWait" />), and
    ///     answers with retryAfterJob when one still runs then; refused while a service of that repo runs in its slot.
    /// </summary>
    public async Task<EnvironmentCommandResult> AddRepoAsync(string owner, string env, string? repo, string? path, string? role, bool addAffected, bool inPlace,
        CancellationToken cancellationToken)
    {
        // AB#9808: the work runs to its end when the caller's MCP call times out - a cancelled cmdlet run would leave a half-added
        // repo; the caller only loses the answer (lane_list shows the result).
        cancellationToken = CancellationToken.None;
        RequireOwner(owner);
        var config = store.Load();
        var info = EnvironmentDiscovery.Find(config, env);
        if ((repo == null) == (path == null))
        {
            throw new ArgumentException("Pass either repo (a new worktree of that repo) or path (an existing worktree to adopt).");
        }

        if (inPlace && path == null)
        {
            throw new ArgumentException("inPlace applies to path (adopt the worktree where it is).");
        }

        if (role is not (null or "feature" or "consumer"))
        {
            throw new ArgumentException($"role must be 'feature' or 'consumer', not '{role}'.");
        }

        var probed = await queue.Capabilities.GetAsync(ServicePlanner.OctoToolsPath(config), cancellationToken);
        var caps = probed.Environments;
        if (!caps.AddRepo)
        {
            throw new InvalidOperationException($"lane_add_repo needs the cmdlet {EnvironmentCapabilities.Unavailable(probed, "Add-OctoEnvironmentRepo -env")}.");
        }

        string? fullPath = null;
        if (path != null)
        {
            fullPath = ServicePlanner.ResolveFolder(path, ServicePlanner.RootPath(config), info.Path, "path");
            if (!caps.AddRepoPath || (inPlace && !caps.AddRepoInPlace))
            {
                throw new InvalidOperationException($"Add-OctoEnvironmentRepo of the daemon's octo-tools takes no -{(caps.AddRepoPath ? "inPlace" : "path")} yet: {EnvironmentCapabilities.TooOld}.");
            }
        }

        if ((role != null && !caps.AddRepoRole) || (addAffected && !caps.AddRepoAddAffected))
        {
            throw new InvalidOperationException($"Add-OctoEnvironmentRepo of the daemon's octo-tools takes no -{(role != null && !caps.AddRepoRole ? "role" : "addAffected")}.");
        }

        var (waited, waitedFor, stillActive) = await WaitForJobsAsync(env, cancellationToken);
        if (stillActive.Count > 0)
        {
            // AB#9808: no bare refusal - the answer names the jobs to wait for; nothing was added.
            var first = stillActive[0].Id;
            return new EnvironmentCommandResult(false, 0, "Add-OctoEnvironmentRepo (not run: the lane's jobs still run)", null, null,
            [
                $"Nothing was added yet: job(s) of lane '{env}' still run or wait after {waited:0} s ({string.Join(", ", stillActive.Select(b => $"{b.Id} {b.State}"))}). " +
                $"Retry lane_add_repo after job_status(\"{first}\", waitSeconds) ended (or job_cancel(owner, \"{first}\", lane=\"{env}\") it)."
            ], null) { RetryAfterJob = first };
        }

        var repoName = repo ?? (Common.PathScope.IsWorktree(fullPath!) ? CheckoutDiscovery.ReadWorktree(Path.Combine(fullPath!, ".git")).Repo : null) ?? Path.GetFileName(fullPath!);
        var services = config.Services.Where(s => string.Equals(s.Value.Repo, repoName, StringComparison.OrdinalIgnoreCase)).Select(s => s.Key).ToHashSet();
        if (supervisor.Registry.Known().Any(k => k.Slot.Name == info.Slot))
        {
            var running = (await supervisor.Slot(info.Slot).StatusAsync(includeLogTail: false, ExternalSnapshot.Empty)).Services
                .Where(s => s.State != "exited" && services.Contains(s.Name)).Select(s => s.Name).ToList();
            if (running.Count > 0)
            {
                throw new InvalidOperationException($"{string.Join(", ", running)} of {repoName} run(s) in the stack of lane '{env}'; " +
                                                    $"stop them first (service_stop(owner, services=[...], lane=\"{env}\")), then add the repo and start them again.");
            }
        }

        var parts = new List<string> { "Add-OctoEnvironmentRepo", $"-env {PwshRunner.Quote(env)}" };
        parts.Add(repo != null ? $"-repo {PwshRunner.Quote(repo)}" : $"-path {PwshRunner.Quote(fullPath!)}");
        if (inPlace)
        {
            parts.Add("-inPlace");
        }

        if (role != null)
        {
            parts.Add($"-role {PwshRunner.Quote(role)}");
        }

        if (addAffected)
        {
            parts.Add("-addAffected");
        }

        var (success, exitCode, command, data, tail) = await RunAsync(config, string.Join(' ', parts) + " -Json", "Add-OctoEnvironmentRepo", cancellationToken);
        logger?.LogInformation("{Owner} added {Repo} to environment {Env}: {Result}", owner, repoName, env, success ? "ok" : $"failed ({exitCode})");
        var row = success ? (await ListAsync(null, cancellationToken)).FirstOrDefault(r => r.Name == env) : null;
        var notes = FeedSnapshot.Notes((data as JsonObject)?["feedSnapshot"], env);
        if (waitedFor.Count > 0)
        {
            notes.Insert(0, $"Waited {waited:0} s for the lane's job(s) {string.Join(", ", waitedFor)} to end before adding the repo.");
        }

        if (success)
        {
            notes.Add($"Build it: lane_build(owner, lane=\"{env}\").");
        }

        return new EnvironmentCommandResult(success, exitCode, command, row, data, notes, success ? null : tail);
    }

    /// <summary>Sync-OctoEnvironment: refresh the snapshot of the base lane's feed and catalogs; refused like lane_build syncMain=true.</summary>
    public async Task<EnvironmentCommandResult> SyncAsync(string owner, string env, CancellationToken cancellationToken)
    {
        RequireOwner(owner);
        supervisor.Removals.Refuse(env); // AB#9673: a lane that is being removed is not synced
        var config = store.Load();
        EnvironmentDiscovery.Find(config, env);
        var probed = await queue.Capabilities.GetAsync(ServicePlanner.OctoToolsPath(config), cancellationToken);
        if (!probed.Environments.Sync)
        {
            throw new InvalidOperationException($"lane_sync needs the cmdlet {EnvironmentCapabilities.Unavailable(probed, "Sync-OctoEnvironment -env")}.");
        }

        if (queue.SyncBlocker(env) is { } blocker)
        {
            throw new InvalidOperationException($"lane_sync refused: {blocker}");
        }

        var (success, exitCode, command, data, tail) = await RunAsync(config, $"Sync-OctoEnvironment -env {PwshRunner.Quote(env)} -Json", "Sync-OctoEnvironment", cancellationToken);
        logger?.LogInformation("{Owner} synced environment {Env}: {Result}", owner, env, success ? "ok" : $"failed ({exitCode})");
        return new EnvironmentCommandResult(success, exitCode, command, null, data, [], success ? null : tail);
    }

    /// <summary>Get-OctoAffectedRepos: the transitive consumers of the environment's feature repos (read-only).</summary>
    public async Task<EnvironmentCommandResult> AffectedAsync(string env, string? target, CancellationToken cancellationToken)
    {
        var config = store.Load();
        EnvironmentDiscovery.Find(config, env);
        var probed = await queue.Capabilities.GetAsync(ServicePlanner.OctoToolsPath(config), cancellationToken);
        if (!probed.Environments.Affected || (target != null && !probed.Environments.AffectedTarget))
        {
            throw new InvalidOperationException($"lane_affected needs the cmdlet {EnvironmentCapabilities.Unavailable(probed, target == null ? "Get-OctoAffectedRepos -env" : "Get-OctoAffectedRepos -target")}.");
        }

        var call = $"Get-OctoAffectedRepos -env {PwshRunner.Quote(env)}{(target != null ? $" -target {PwshRunner.Quote(target)}" : "")} -Json";
        var (success, exitCode, command, data, tail) = await RunAsync(config, call, "Get-OctoAffectedRepos", cancellationToken);
        return new EnvironmentCommandResult(success, exitCode, command, null, data, [], success ? null : tail);
    }

    /// <summary>
    ///     How long lane_add_repo waits in the call for the lane's running or queued jobs (AB#9808): below the ~60 s after which an
    ///     agent's MCP call times out.
    /// </summary>
    public TimeSpan AddRepoJobWait { get; set; } = TimeSpan.FromSeconds(45);

    /// <summary>How often the wait looks at the lane's jobs again (tests shorten it).</summary>
    public TimeSpan JobPollInterval { get; set; } = TimeSpan.FromSeconds(2);

    /// <summary>
    ///     lane_add_repo while a build or test run of the lane runs or waits: wait for them to end, at most <see cref="AddRepoJobWait" />
    ///     (AB#9808). Returns the seconds waited, the jobs waited for, and the jobs that still run or wait (empty: go on). Refused when
    ///     the lane is being removed.
    /// </summary>
    private async Task<(double Seconds, List<string> WaitedFor, List<BuildStatus> StillActive)> WaitForJobsAsync(string env, CancellationToken cancellationToken)
    {
        supervisor.Removals.Refuse(env); // AB#9673: a lane that is being removed takes no change
        var waitedFor = new List<string>();
        var clock = System.Diagnostics.Stopwatch.StartNew();
        while (queue.ActiveFor(env) is { Count: > 0 } active)
        {
            waitedFor.AddRange(active.Select(b => b.Id).Where(id => !waitedFor.Contains(id)));
            if (clock.Elapsed >= AddRepoJobWait)
            {
                return (clock.Elapsed.TotalSeconds, waitedFor, active);
            }

            await Task.Delay(JobPollInterval, cancellationToken);
        }

        supervisor.Removals.Refuse(env);
        return (waitedFor.Count == 0 ? 0 : clock.Elapsed.TotalSeconds, waitedFor, []);
    }

    private void RefuseWhileJobs(string env)
    {
        var builds = queue.ActiveFor(env);
        if (builds.Count > 0)
        {
            throw new InvalidOperationException($"Jobs of lane '{env}' run or wait ({string.Join(", ", builds.Select(b => $"{b.Id} {b.State}"))}); " +
                                                "wait for them (job_status(id, waitSeconds)) or job_cancel(owner, id, lane) them first.");
        }
    }

    private EnvironmentRow Row(EnvironmentInfo env, IReadOnlyList<SlotSummary> slots)
    {
        var slot = slots.FirstOrDefault(s => s.Name == env.Slot);
        var m = env.Manifest;
        EnvironmentSlot? slotInfo = null;
        if (env.Problem == null)
        {
            try
            {
                var (info, exists) = supervisor.Registry.Predict(env.Slot);
                slotInfo = new EnvironmentSlot(info.Name, info.Index, info.PortOffset, info.Prefix, exists);
            }
            catch (InvalidOperationException)
            {
                // No free index without a port clash: shown as no slot; the start says why.
            }
        }

        // UC-A: the shared stack's services that run this lane's worktree of their repo.
        var shared = slots.FirstOrDefault(s => s.Name == SlotInfo.DefaultName)?.Services
            .Where(s => s.RunsFrom == LaneSource.Prefix + env.Name).Select(s => s.Name).ToList();
        // The lease with its last activity and idle minutes, as lease_status(lane) shows it.
        return new EnvironmentRow(env.Name, env.Path, m?.WorkItem, m?.Base, m?.Owner, m?.Created, m?.Repos ?? [], env.Slot, slot?.Running == true,
            slot?.Healthy ?? 0, slot?.Total ?? 0, supervisor.Leases.Find(env.Slot)?.Snapshot().Holder,
            queue.ActiveFor(env.Name).Select(b => $"{b.Id} {b.Kind} {b.State} ({b.Owner})").ToList(), env.Problem)
        {
            SlotInfo = slotInfo, InSharedStack = shared is { Count: > 0 } ? shared : null, Removing = supervisor.Removals.Of(env.Name)
        };
    }

    /// <summary>
    ///     Initialize-OctoEnvironmentPackageCache (octo-tools AB#8831): fills or tops up the package cache of an existing
    ///     environment from a local cache (clone where the file system can, else copy), so its next build restores without
    ///     downloads. Refused while the environment builds or tests.
    /// </summary>
    public async Task<EnvironmentCommandResult> SeedCacheAsync(string owner, string env, bool dryRun, CancellationToken cancellationToken)
    {
        RequireOwner(owner);
        supervisor.Removals.Refuse(env); // AB#9673: no cache seeding into a lane that is being removed
        var config = store.Load();
        var probed = await queue.Capabilities.GetAsync(ServicePlanner.OctoToolsPath(config), cancellationToken);
        if (!probed.Environments.SeedPackageCache)
        {
            throw new InvalidOperationException($"admin_lane_seed_cache needs the cmdlet {EnvironmentCapabilities.Unavailable(probed, "Initialize-OctoEnvironmentPackageCache -env")} " +
                                                "(octo-tools AB#8831).");
        }

        if (EnvironmentDiscovery.Discover(config).All(e => e.Name != env))
        {
            throw new ArgumentException($"There is no lane '{env}' (lane_list).");
        }

        if (!dryRun && queue.ActiveFor(env).FirstOrDefault() is { } active)
        {
            throw new InvalidOperationException($"Lane '{env}' has the job {active.Id} ({active.Kind}, {active.State}) of {active.Owner}: its restore reads the package cache now. " +
                                                "Fill the cache when it ended.");
        }

        var (success, exitCode, command, data, tail) = await RunAsync(config,
            $"Initialize-OctoEnvironmentPackageCache -env {PwshRunner.Quote(env)}{(dryRun ? " -WhatIf" : "")} -Json", "Initialize-OctoEnvironmentPackageCache", cancellationToken);
        var notes = new List<string>();
        if (PackageCacheNote(data as JsonObject) is { } cache)
        {
            notes.Add(cache);
        }

        logger?.LogInformation("{Owner} filled the package cache of environment {Env}: {Result}", owner, env, success ? "ok" : $"failed ({exitCode})");
        return new EnvironmentCommandResult(success, exitCode, command, null, null, notes, success ? null : tail);
    }

    /// <summary>The packageCache block of New-OctoEnvironment / Initialize-OctoEnvironmentPackageCache as one sentence; null without one.</summary>
    internal static string? PackageCacheNote(JsonObject? cache)
    {
        if (cache == null || (cache["method"] == null && cache["skipped"] == null && cache["packages"] == null))
        {
            return null;
        }

        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        if (BuildPlanner.Bool(cache["skipped"]) == true || BuildPlanner.Str(cache["skipped"]) is { Length: > 0 })
        {
            return "Package cache: not filled" + (BuildPlanner.Str(cache["skipped"]) is { Length: > 0 } why ? $" ({why})" : "") + "; admin_lane_seed_cache fills it later.";
        }

        var packages = (int?)BuildPlanner.Num(cache["packages"]) ?? 0;
        var size = BuildPlanner.Num(cache["sizeBytes"]) is > 0 and var bytes ? string.Create(invariant, $", {bytes / 1024d / 1024d / 1024d:0.#} GiB") : "";
        var seconds = BuildPlanner.Num(cache["seconds"]) is { } s ? string.Create(invariant, $" in {s:0.#} s") : "";
        var extras = new[]
        {
            (int?)BuildPlanner.Num(cache["alreadyPresent"]) is > 0 and var present ? $"{present} already there" : null,
            (int?)BuildPlanner.Num(cache["skippedLocalBuilds"]) is > 0 and var local ? $"{local} local builds left out" : null,
            (int?)BuildPlanner.Num(cache["skippedIncomplete"]) is > 0 and var incomplete ? $"{incomplete} incomplete left out" : null
        }.OfType<string>().ToList();
        var errors = cache["errors"] switch
        {
            JsonArray list => list.Count,
            JsonValue value => (int?)BuildPlanner.Num(value) ?? (BuildPlanner.Str(value) is { Length: > 0 } ? 1 : 0),
            _ => 0
        };
        var firstError = (cache["errors"] as JsonArray)?.Select(e => BuildPlanner.Str(e) ?? e?.ToJsonString()).FirstOrDefault(e => !string.IsNullOrWhiteSpace(e));
        return $"Package cache: {(BuildPlanner.Bool(cache["dryRun"]) == true ? "would get " : "")}{packages} package version(s){size} " +
               $"{(BuildPlanner.Str(cache["method"]) is { } method ? method == "clone" ? "cloned" : method == "copy" ? "copied" : method : "taken")} from " +
               $"{BuildPlanner.Str(cache["source"]) ?? "?"}{seconds}" + (extras.Count > 0 ? $" ({string.Join(", ", extras)})" : "") +
               (errors > 0 ? $"; {errors} error(s){(firstError != null ? ": " + SecretMask.MaskValue(firstError) : "")}" : "") + ".";
    }

    /// <summary>New-OctoEnvironment: the folder, its Octo.User.props, manifest, feature worktrees, feed and catalogs (all octo-tools).</summary>
    public async Task<EnvironmentCommandResult> CreateAsync(string owner, string name, IReadOnlyList<string> repos, string? workItem, string? branchName,
        bool addAffected, CancellationToken cancellationToken, bool skipPackageCacheSeed = false)
    {
        // AB#9808: the work runs to its end when the caller's MCP call times out (a lane with many repos takes longer than a
        // teammate's ~60 s): a cancellation between New-OctoEnvironment and the slot reservation left a lane without its slot, and
        // the next lane_create got the same index. The caller only loses the answer (lane_list shows the lane and its slot).
        cancellationToken = CancellationToken.None;
        RequireOwner(owner);
        var config = store.Load();
        CheckName(name);
        var probed = await queue.Capabilities.GetAsync(ServicePlanner.OctoToolsPath(config), cancellationToken);
        var caps = probed.Environments;
        if (!caps.Create)
        {
            throw new InvalidOperationException($"lane_create needs the cmdlet {EnvironmentCapabilities.Unavailable(probed, "New-OctoEnvironment")}.");
        }

        if (EnvironmentDiscovery.Discover(config).Any(e => e.Name == name))
        {
            throw new InvalidOperationException($"Lane '{name}' exists already (lane_list).");
        }

        // AB#9676: the lane stack's slot is checked before anything is created (a lane's slot is named after the lane): no free
        // index refuses the call here, not after New-OctoEnvironment made the folder and the branches.
        supervisor.Registry.Predict(name);

        var parts = new List<string> { "New-OctoEnvironment", $"-{caps.CreateNameParameter} {PwshRunner.Quote(name)}" };
        if (repos.Count > 0)
        {
            if (caps.CreateReposParameter == null)
            {
                throw new InvalidOperationException("New-OctoEnvironment of the daemon's octo-tools takes no repos parameter.");
            }

            parts.Add($"-{caps.CreateReposParameter} @({string.Join(",", repos.Select(PwshRunner.Quote))})");
        }

        if (workItem != null)
        {
            parts.Add(caps.CreateWorkItem ? $"-workItem {PwshRunner.Quote(workItem)}" : throw new InvalidOperationException("New-OctoEnvironment of the daemon's octo-tools takes no -workItem."));
        }

        if (branchName != null)
        {
            // -branchName is the git branch of the feature worktrees; -branch means the lane in octo-tools.
            parts.Add(caps.CreateBranchName
                ? $"-branchName {PwshRunner.Quote(branchName)}"
                : throw new InvalidOperationException("New-OctoEnvironment of the daemon's octo-tools takes no -branchName."));
        }

        if (addAffected)
        {
            parts.Add(caps.CreateAddAffected ? "-addAffected" : throw new InvalidOperationException("New-OctoEnvironment of the daemon's octo-tools takes no -addAffected."));
        }

        if (caps.CreateOwner)
        {
            parts.Add($"-owner {PwshRunner.Quote(owner)}");
        }

        if (skipPackageCacheSeed)
        {
            parts.Add(caps.SkipPackageCacheSeed
                ? "-skipPackageCacheSeed"
                : throw new InvalidOperationException("New-OctoEnvironment of the daemon's octo-tools takes no -skipPackageCacheSeed (it fills no package cache at all; octo-tools AB#8831 does)."));
        }

        var (success, exitCode, command, data, tail) = await RunAsync(config, string.Join(' ', parts) + " -Json", "New-OctoEnvironment", cancellationToken);
        var notes = new List<string>();
        if (PackageCacheNote((data as JsonObject)?["packageCache"] as JsonObject) is { } cache)
        {
            notes.Add(cache);
            (data as JsonObject)?.Remove("packageCache");
        }
        else if (success && !caps.SkipPackageCacheSeed)
        {
            notes.Add("The lane's package cache is empty (this octo-tools does not fill it): the first build restores every package.");
        }

        EnvironmentRow? row = null;
        if (success && EnvironmentDiscovery.Discover(config).FirstOrDefault(e => e.Name == name) is { } created)
        {
            // Reserve the slot now, so its ports and data names are known (and stay the same) before the first start.
            SlotInfo reserved;
            try
            {
                reserved = supervisor.Registry.Resolve(created.Slot, create: true);
            }
            catch (Exception e) when (e is not OperationCanceledException)
            {
                // AB#9676: the slot could not be reserved (no free index, a slot name the manifest gives): the lane goes again.
                return await RollBackCreateAsync(owner, created, config, caps, command, data, notes, e.Message, cancellationToken);
            }

            notes.Add($"Slot '{reserved.Name}' reserved: index {reserved.Index}, ports +{reserved.PortOffset}, prefix {reserved.Prefix} " +
                      "(stack_list shows its derived data names).");
            row = Row(created, await supervisor.SummariesAsync());
            // The row carries the manifest already; the cmdlet's copy would double the answer.
            (data as JsonObject)?.Remove("manifest");
            notes.AddRange(FeedSnapshot.Notes((data as JsonObject)?["feedSnapshot"], name));
            notes.Add($"Edit in the repo paths of lane_list(lane=\"{name}\"). Build it: lane_build(owner, lane=\"{name}\"); test it: lane_test(owner, lane=\"{name}\", repo=...). " +
                      $"Run it: stack_start(owner, lane=\"{name}\", profile=...) - its own stack (slot '{created.Slot}'), lease held by {created.LeaseOwner}.");
        }
        else if (success)
        {
            notes.Add($"New-OctoEnvironment reported success, but {EnvironmentDiscovery.ManifestPath(EnvironmentDiscovery.FolderOf(ServicePlanner.RootPath(config), name))} " +
                      "is missing or unusable.");
        }

        logger?.LogInformation("{Owner} created environment {Env}: {Result}", owner, name, success ? "ok" : $"failed ({exitCode})");
        return new EnvironmentCommandResult(success, exitCode, command, row, data, notes, success ? null : tail);
    }

    /// <summary>
    ///     A lane_create whose slot could not be reserved after New-OctoEnvironment made the lane (AB#9676): Remove-OctoEnvironment
    ///     takes the fresh lane away again and its feature branches (no commits yet) are deleted, so no folder, branch or slot is
    ///     left. The answer is a failure that names why and what is left when the roll-back failed too.
    /// </summary>
    private async Task<EnvironmentCommandResult> RollBackCreateAsync(string owner, EnvironmentInfo created, DevStackConfig config, EnvironmentCapabilities caps,
        string command, JsonNode? data, List<string> notes, string why, CancellationToken cancellationToken)
    {
        notes.Add($"The lane's stack slot could not be reserved ({why}).");
        if (!caps.Remove)
        {
            notes.Add($"Not rolled back: the daemon's octo-tools has no Remove-OctoEnvironment. Remove {created.Path} and its feature branches by hand " +
                      "(Remove-OctoEnvironment, then git branch -d in each repo).");
            return new EnvironmentCommandResult(false, 1, command, null, data, notes, why);
        }

        var targets = await LaneBranches.TargetsAsync(created);
        var call = $"Remove-OctoEnvironment -{caps.RemoveNameParameter} {PwshRunner.Quote(created.Name)} -Json";
        var removed = await RunAsync(config, call, "Remove-OctoEnvironment", cancellationToken);
        List<LaneBranch>? branches = null;
        if (removed.Success)
        {
            notes.Add("The lane was taken away again (Remove-OctoEnvironment).");
            // What the cmdlet leaves of a lane it just made (its .octo folder) goes with it, as after a lane_remove.
            var rest = SlotDataCleanup.DeleteLaneSecrets(created.Path);
            notes.AddRange(rest.Failed.Select(f => $"Not removed: {f}"));
            PruneLeftOver(removed.Data, created.Path);
            branches = await LaneBranches.CleanAsync(targets, keepAll: false);
            if (BranchNote(branches) is { } branchNote)
            {
                notes.Add(branchNote);
            }
        }
        else
        {
            notes.Add($"The roll-back failed too ({removed.Command}, exit {removed.ExitCode}): {created.Path} and its branches are left; lane_remove(owner, " +
                      $"lane=\"{created.Name}\") removes them once a slot index is free, or remove them by hand.");
        }

        logger?.LogWarning("{Owner} created lane {Env}, but its slot could not be reserved ({Why}); rolled back: {Result}", owner, created.Name, why,
            removed.Success ? "ok" : $"failed ({removed.ExitCode})");
        return new EnvironmentCommandResult(false, 1, command, null, data, notes, removed.Success ? why : removed.Tail)
        {
            Branches = branches is { Count: > 0 } ? branches : null
        };
    }

    /// <summary>
    ///     lane_remove: Remove-OctoEnvironment, after the daemon checked which processes hold files below the lane, stopped the
    ///     lane stack and released its lease; then the daemon drops the lane stack's data (<paramref name="keepData"/> keeps it,
    ///     the index stays retired). Refused while a build of the lane runs or waits, while another session holds the slot's
    ///     lease, and while a process the daemon did not start - or a service of another stack - holds files below the lane
    ///     (on 2026-11-20 a reused MSBuild node held the lane's package cache and the cmdlet failed halfway with "Access denied").
    ///     The cmdlet refuses dirty or unpushed worktrees; the daemon has no way around that. It keeps the feature branches: the
    ///     daemon deletes the ones that hold nothing (<see cref="LaneBranches"/>; <paramref name="keepBranches"/> keeps all).
    /// </summary>
    public async Task<EnvironmentCommandResult> RemoveAsync(string owner, string name, bool keepData, CancellationToken cancellationToken, bool keepBranches = false)
    {
        RequireOwner(owner);
        var config = store.Load();
        var env = EnvironmentDiscovery.Discover(config).FirstOrDefault(e => e.Name == name)
                  ?? throw new InvalidOperationException($"Unknown lane '{name}' (lane_list).");
        var probed = await queue.Capabilities.GetAsync(ServicePlanner.OctoToolsPath(config), cancellationToken);
        var caps = probed.Environments;
        if (!caps.Remove)
        {
            throw new InvalidOperationException($"lane_remove needs the cmdlet {EnvironmentCapabilities.Unavailable(probed, "Remove-OctoEnvironment")}.");
        }

        // AB#9673: marked first - every session of the lane acts as the lane, so its lease does not keep them out. From here
        // on nothing new starts on it; the mark ends in the finally, whatever the removal did.
        using var removing = supervisor.Removals.Begin(env.Name, owner, LeaseSession.Of(owner), env.Slot, [env.Path, ..env.RepoPaths().Values]);
        RefuseWhileJobs(name);
        return await RemoveMarkedAsync(owner, name, env, config, probed, keepData, keepBranches, cancellationToken);
    }

    private async Task<EnvironmentCommandResult> RemoveMarkedAsync(string owner, string name, EnvironmentInfo env, DevStackConfig config, BuildCapabilities probed,
        bool keepData, bool keepBranches, CancellationToken cancellationToken)
    {
        var caps = probed.Environments;
        var notes = new List<string>();
        var lease = supervisor.Leases.Find(env.Slot);
        var holder = lease?.Current();
        if (holder != null && !string.Equals(holder.Owner, env.LeaseOwner, StringComparison.OrdinalIgnoreCase))
        {
            throw new LeaseHeldException($"The stack of lane '{name}' (slot '{env.Slot}') is held by '{holder.Owner}'{(holder.Session != null ? $" (session {holder.Session})" : "")} " +
                                         $"({holder.Purpose ?? "no purpose given"}), not by the lane; that session must release it first.");
        }

        // AB#9673: a start that passed the removal check before the mark was set may still be launching services - in the lane
        // stack (also one that does not run yet) or in another stack from the lane's worktrees. Every start runs under its
        // slot's gate and checks the mark there, so after waiting for every slot's gate once, such a start has either finished
        // (its services are stopped or found below) or starts nothing.
        foreach (var run in supervisor.Runs)
        {
            await run.SettleAsync(cancellationToken);
        }

        // Before anything changes: which processes hold files below the lane. The lane stack's own services are stopped
        // below; anything else refuses the removal.
        if (!caps.ProcessesUnderFolder)
        {
            notes.Add("Not checked which processes hold files below the lane (" +
                      (probed.Probed
                          ? $"the daemon's octo-tools has no {LaneProcesses.Cmdlet} -path: update it, git pull in its checkout"
                          : $"the octo-tools capability probe failed: {probed.Error ?? "unknown error"}") +
                      "): Remove-OctoEnvironment fails with \"Access denied\" on Windows when one does.");
        }

        var checkedProcesses = caps.ProcessesUnderFolder && await CheckProcessesAsync(config, env, notes, afterStop: false, cancellationToken);

        var stoppedAny = false;
        if (supervisor.Registry.Known().Any(k => k.Slot.Name == env.Slot))
        {
            var run = supervisor.Slot(env.Slot);
            if (run.Active)
            {
                var scope = new EnvironmentScope(env, env.Slot, env.Path, env.LeaseOwner);
                EnvironmentBinding.Claim(supervisor, scope, owner, forRemoval: true);
                var stopped = await supervisor.StopServicesAsync(env.LeaseOwner, null, cancellationToken, env.Slot);
                if (stopped.Stopped.Count + stopped.Killed.Count > 0)
                {
                    stoppedAny = true;
                    notes.Add($"stopped the lane stack '{env.Slot}': {string.Join(", ", stopped.Stopped.Concat(stopped.Killed).Distinct())}");
                }
            }
        }

        if (checkedProcesses && stoppedAny)
        {
            // What the stopped services leave behind (a child that outlived its service) would make the cmdlet fail halfway.
            await CheckProcessesAsync(config, env, notes, afterStop: true, cancellationToken);
        }

        if (supervisor.Leases.Find(env.Slot) is { } own && own.Current() != null)
        {
            own.Release(env.LeaseOwner, force: false);
            notes.Add($"released the lease of the lane stack '{env.Slot}' ({env.LeaseOwner})");
        }

        // Read while the worktrees still exist: which repository holds each feature branch.
        var branchTargets = await LaneBranches.TargetsAsync(env);
        var call = $"Remove-OctoEnvironment -{caps.RemoveNameParameter} {PwshRunner.Quote(name)} -Json";
        var (success, exitCode, command, data, tail) = await RunAsync(config, call, "Remove-OctoEnvironment", cancellationToken);
        List<SlotLeftover>? leftovers = null;
        SlotDataDrop? drop = null;
        List<LaneBranch>? branches = null;
        if (success)
        {
            var known = supervisor.Registry.Known().FirstOrDefault(k => k.Slot.Name == env.Slot);
            // The lane is gone once the cmdlet succeeded: whatever fails from here on (ForgetSlot refuses a slot that still
            // runs services, a store throws) is reported in the answer, never as an error of lane_remove (AB#9673).
            try
            {
                if (known.Slot != null && known.Origin == "created" && keepData)
                {
                    // The tenant databases the slot's system database registers are facts kept with the retired index.
                    var tenantDatabases = await TenantDatabasesAsync(config, known.Slot, cancellationToken);
                    if (tenantDatabases == null)
                    {
                        notes.Add("MongoDB did not answer: the tenant databases of the lane stack are listed generically.");
                    }

                    leftovers = SlotCleanup.Leftovers(config, known.Slot, supervisor.StateDirectory, tenantDatabases);
                    supervisor.ForgetSlot(env.Slot, tenantDatabases);
                    notes.Add($"Removed the lane stack '{env.Slot}' (ports +{known.Slot.PortOffset}, prefix {known.Slot.Prefix}) and kept its data (keepData): its name is " +
                              $"free, its index {known.Slot.Index} is retired, so no new stack finds the data. admin_slot_drop_data(owner, index={known.Slot.Index}) " +
                              "drops it later and frees the index; leftovers lists it with the commands to drop it by hand.");
                    // AB#9384: the lane's secret files never stay with the kept data (the data drop deletes them itself).
                    var secrets = SlotDataCleanup.DeleteLaneSecrets(env.Path);
                    leftovers.AddRange(secrets.Leftovers);
                    if (secrets.Dropped.Count + secrets.Failed.Count + secrets.Notes.Count > 0)
                    {
                        notes.Add("Lane secret files: " + string.Join("; ", secrets.Dropped.Select(d => $"removed {d}").Concat(secrets.Failed.Select(f => $"not removed: {f}"))
                            .Concat(secrets.Notes)) + ".");
                    }
                }
                else if (known.Slot != null && known.Origin == "created")
                {
                    // Retired first: no new stack takes the index while its data is dropped. Freed when every step succeeded.
                    supervisor.ForgetSlot(env.Slot);
                    drop = await cleanup.DropRemovedAsync(known.Slot.Index, env.Path, cancellationToken);
                    leftovers = drop.Leftovers?.ToList();
                    notes.Add($"Removed the lane stack '{env.Slot}' (ports +{known.Slot.PortOffset}, prefix {known.Slot.Prefix}); its name is free. {drop.Summary()}");
                }
                else if (known.Slot != null)
                {
                    notes.Add($"Slot '{env.Slot}' is configured in devstack.yaml; it stays, and so does its data.");
                }
            }
            catch (Exception e) when (e is not OperationCanceledException && known.Slot != null)
            {
                // What stays is listed as for keepData; the index stays retired when it was retired already.
                logger?.LogWarning(e, "After removing lane {Env}, the clean-up of its stack {Slot} failed", name, env.Slot);
                leftovers = SlotCleanup.Leftovers(config, known.Slot, supervisor.StateDirectory);
                if (keepData || drop == null)
                {
                    // AB#9384: the secret files go (or are listed) also when the step before them failed - with keepData, and when the
                    // data drop (which deletes them itself) never ran because ForgetSlot threw.
                    var secrets = SlotDataCleanup.DeleteLaneSecrets(env.Path);
                    leftovers.AddRange(secrets.Leftovers);
                    notes.AddRange(secrets.Failed.Select(f => $"Lane secret file not removed: {f}"));
                }

                var retired = supervisor.State.RetiredSlots().ContainsKey(known.Slot.Index);
                notes.Add($"Removed the lane '{name}', but {(retired ? "dropping the data of" : "cleaning up")} its stack '{env.Slot}' (ports +{known.Slot.PortOffset}, " +
                          $"prefix {known.Slot.Prefix}) failed ({SecretMask.MaskValue(e.Message)}): " +
                          (retired
                              ? $"index {known.Slot.Index} stays retired; admin_slot_drop_data(owner, index={known.Slot.Index}) tries again."
                              : $"the slot is still known (stack_list) and its data is not dropped; stop what still runs in it (stack_stop(owner, slot=\"{env.Slot}\")) " +
                                "and tell the developer - leftovers lists the data with the commands."));
            }

            // The cmdlet listed what was left in the folder before the daemon removed the lane's secret files (and with
            // them the folder): only what is still there stays in the list.
            PruneLeftOver(data, env.Path);
            branches = await LaneBranches.CleanAsync(branchTargets, keepBranches);
            if (BranchNote(branches) is { } branchNote)
            {
                notes.Add(branchNote);
            }
        }

        logger?.LogInformation("{Owner} removed lane {Env}: {Result}", owner, name, success ? "ok" : $"failed ({exitCode})");
        return new EnvironmentCommandResult(success, exitCode, command, null, data, notes, success ? null : tail)
        {
            Leftovers = leftovers, DataDrop = drop, Branches = branches is { Count: > 0 } ? branches : null
        };
    }

    /// <summary>Drops the entries of Remove-OctoEnvironment's leftOver (names in the lane folder) that no longer exist.</summary>
    internal static void PruneLeftOver(JsonNode? data, string laneFolder)
    {
        if (data is not JsonObject obj || obj["leftOver"] is not JsonArray leftOver)
        {
            return;
        }

        var folder = BuildPlanner.Str(obj["path"]) ?? laneFolder;
        var still = leftOver.Select(BuildPlanner.Str).OfType<string>()
            .Where(n => Path.Exists(Path.Combine(folder, n)))
            .Select(n => (JsonNode?)JsonValue.Create(n)).ToArray();
        obj["leftOver"] = new JsonArray(still);
    }

    /// <summary>One note for the branches: which were deleted, which stay and why to look at 'branches'.</summary>
    private static string? BranchNote(IReadOnlyList<LaneBranch> branches)
    {
        if (branches.Count == 0)
        {
            return null;
        }

        var deleted = branches.Where(b => b.Deleted).Select(b => $"{b.Branch} in {b.RepoPath}").ToList();
        var kept = branches.Where(b => !b.Deleted).Select(b => $"{b.Branch} in {b.RepoPath}").ToList();
        return string.Join(" ", new[]
        {
            deleted.Count > 0 ? $"Deleted the feature branch(es) without commits of their own: {string.Join(", ", deleted)}." : null,
            kept.Count > 0 ? $"Kept the feature branch(es) {string.Join(", ", kept)}; branches says why and how to delete them after the merge." : null
        }.OfType<string>());
    }

    /// <summary>
    ///     Asks octo-tools which processes hold files below the lane folder and below its in-place worktrees, and refuses the
    ///     removal (throws) when one of them is not the lane stack's own - or, <paramref name="afterStop"/>, when anything is
    ///     still there. False (with a note) when the check itself failed: the removal goes on as without it.
    /// </summary>
    private async Task<bool> CheckProcessesAsync(DevStackConfig config, EnvironmentInfo env, List<string> notes, bool afterStop, CancellationToken cancellationToken)
    {
        // In-place worktrees stay (Remove-OctoEnvironment only unregisters them): their processes are reported, they never refuse.
        var inPlace = (env.Manifest?.Repos ?? []).Select(r => r.Path).Where(p => p.Length > 0 && Directory.Exists(p) && !PathScope.IsUnder(p, env.Path))
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        List<FolderProcess> found;
        try
        {
            var result = await pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), BuildPlanner.RootPrelude(ServicePlanner.RootPath(config)) +
                                                                                   LaneProcesses.Script([env.Path, .. inPlace]),
                new PwshRunOptions { Timeout = TimeSpan.FromMinutes(3) }, cancellationToken);
            found = LaneProcesses.Parse(result);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            notes.Add($"Could not check which processes hold files below the lane ({e.Message.TrimEnd('.')}); Remove-OctoEnvironment fails with \"Access denied\" " +
                      "on Windows when one does.");
            return false;
        }

        var services = supervisor.Runs.SelectMany(r => r.LiveServices().Select(s => (r.Slot.Name, s.Service, s.Pid, s.StartedBy))).ToList();
        var own = services.Count == 0 ? [] : LaneProcesses.OwnProcesses(services, (processLinks ?? ProcessTree.Links)());
        var check = LaneProcesses.Classify(found, env.Path, env.Slot, own);
        if (LaneProcesses.Refusal(env.Name, env.Path, check, afterStop) is { } refusal)
        {
            logger?.LogInformation("lane_remove of {Env} refused: {Count} process(es) hold files below it", env.Name,
                check.Foreign.Count + check.OtherStacks.Count + (afterStop ? check.LaneStack.Count : 0));
            throw new InvalidOperationException(refusal);
        }

        if (!afterStop && check.ForeignInPlace.Count > 0)
        {
            notes.Add($"Processes below the in-place worktrees {string.Join(", ", inPlace)} keep running (the worktrees stay, Remove-OctoEnvironment only unregisters " +
                      $"them): {string.Join("; ", check.ForeignInPlace.Select(p => p.ToString()))}");
        }

        return true;
    }

    private async Task<(bool Success, int ExitCode, string Command, JsonNode? Data, string Tail)> RunAsync(DevStackConfig config, string call, string cmdlet,
        CancellationToken cancellationToken)
    {
        var result = await pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), BuildPlanner.RootPrelude(ServicePlanner.RootPath(config)) + call,
            new PwshRunOptions { Timeout = CommandTimeout }, cancellationToken);
        var json = PwshRunner.ExtractOctoJson(result.Output, cmdlet);
        var data = json?["data"];
        // Success from the cmdlet's own JSON AND the exit code.
        var success = result.ExitCode == 0 && !result.TimedOut && data is JsonObject obj && BuildPlanner.Bool(obj["success"]) != false &&
                      BuildPlanner.Str(obj["error"]) == null;
        // pwsh may exit 0 although the cmdlet refused (success=false in its JSON): the answer's exit code reflects the refusal.
        var exitCode = success || result.ExitCode != 0 ? result.ExitCode
            : data is JsonObject d && BuildPlanner.Num(d["exitCode"]) is { } inner && inner != 0 ? (int)inner : 1;
        return (success, exitCode, call, data?.DeepClone(), PwshRunner.Tail(result.Output, 40));
    }

    /// <summary>The tenant databases registered in the slot's system database (as stack_verify reads them), or null when MongoDB does not answer.</summary>
    private async Task<IReadOnlyList<string>?> TenantDatabasesAsync(DevStackConfig config, SlotInfo slot, CancellationToken cancellationToken)
    {
        var rows = SlotDeriver.Apply(ProfileResolver.Materialize(config, null, null), slot, SlotDeriver.SlotDirectory(supervisor.StateDirectory, slot)).Rows;
        var systemDb = SlotCleanup.SystemDatabaseName(rows.FirstOrDefault(r => r.Id == "systemDatabase")?.Value ?? $"OctoSystem_{slot.Prefix}");
        try
        {
            var tenants = await (inventory ?? (c => new LocalInfraInventory(c)))(config).TenantsAsync(systemDb, cancellationToken);
            return tenants.Where(t => t.Database.Length > 0).Select(t => t.Database).Distinct().Order(StringComparer.Ordinal).ToList();
        }
        catch (Exception e) when (e is MongoDB.Driver.MongoException or TimeoutException or InvalidOperationException)
        {
            return null;
        }
    }

    private void CheckName(string name)
    {
        if (name == SlotInfo.DefaultName || !SlotRules.IsValidName(name))
        {
            throw new ArgumentException($"Invalid lane name '{name}': lowercase letters, digits and '-' (it names the lane's stack slot), not 'default'.");
        }

        if (supervisor.Registry.Known().Any(k => k.Slot.Name == name))
        {
            throw new ArgumentException($"A slot '{name}' exists already (stack_list); a lane's stack slot is named after it, so pick another name.");
        }
    }

    private static void RequireOwner(string owner)
    {
        if (string.IsNullOrWhiteSpace(owner))
        {
            throw new ArgumentException("owner is required.");
        }
    }
}
