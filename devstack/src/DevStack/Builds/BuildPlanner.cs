using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Builds;

public enum BuildKind
{
    /// <summary>Invoke-Build of one repository folder (lane repo or worktree).</summary>
    Repo,

    /// <summary>Invoke-BuildRange over a slice of the lane's build order.</summary>
    Range,

    /// <summary>Invoke-BuildAll of a lane (full reset of its 999.0.0 packages).</summary>
    All,

    /// <summary>The stale repos and worktrees of a profile's services, one Invoke-Build each.</summary>
    Profile,

    /// <summary>Invoke-BuildEnvironment: the feature and consumer repos of a feature environment into its own feed.</summary>
    Env,

    /// <summary>Invoke-OctoTestRun: the tests of one repository of a base lane or a lane (base_test, lane_test).</summary>
    Test
}

/// <summary>lane: build against / into the lane (default). private: a per-session feed and cache. publish: range into the lane's nuget.</summary>
public enum PackageMode
{
    Lane,
    Private,
    Publish
}

public sealed record BuildRequest
{
    /// <summary>The calling session; with an environment it is recorded for audit, the environment holds the lease.</summary>
    public required string Owner { get; init; }

    /// <summary>The feature environment (env parameter): checkout, slot and lease holder come from it.</summary>
    public string? Environment { get; init; }

    /// <summary>kind=env: refresh the environment's snapshot of the base lane's packages and catalogs first (-syncMain).</summary>
    public bool SyncMain { get; init; }

    /// <summary>Who must hold the leases of the build: the environment ("env:&lt;name&gt;") or the owner.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public string LeaseOwner => Environment == null ? Owner : EnvironmentDiscovery.LeaseOwnerOf(Environment);

    /// <summary>
    ///     Who must hold the lease of <paramref name="slot"/> for this job: the shared stack's is the calling owner's (a lane job
    ///     that stops a shared-stack service running from the lane, UC-A, needs the caller's lease), every other slot's
    ///     <see cref="LeaseOwner"/> (a lane's own stack: the lane).
    /// </summary>
    public string LeaseOwnerFor(string slot) => slot == SlotInfo.DefaultName ? Owner : LeaseOwner;
    public BuildKind Kind { get; init; }
    public string? Path { get; init; }
    public string? Checkout { get; init; }
    public string? From { get; init; }
    public string? To { get; init; }
    public List<string> Include { get; init; } = [];
    public List<string> Exclude { get; init; } = [];

    /// <summary>Null: the profile's configuration (kind=profile) or the config default.</summary>
    public string? Configuration { get; init; }

    public bool VerifyTests { get; init; }
    public bool IncludeTests { get; init; }

    /// <summary>kind=env: build only these repos of the environment (and what must follow them); empty = all that changed.</summary>
    public List<string> Repos { get; init; } = [];

    /// <summary>kind=env: repos to leave out.</summary>
    public List<string> Skip { get; init; } = [];

    /// <summary>kind=env: build also the repos that did not change since their last build.</summary>
    public bool BuildUnchanged { get; init; }

    /// <summary>-refreshCatalogs (octo-tools AB#8831): every CK compile of the build reads the remote CK catalogs again instead of once per run.</summary>
    public bool RefreshCatalogs { get; init; }

    /// <summary>kind=env: how many independent repos build at the same time (null: the cmdlet's default, 2).</summary>
    public int? MaxParallel { get; init; }

    /// <summary>kind=test: the repository whose tests run (name forms of Invoke-OctoTestRun -repo).</summary>
    public string? Repo { get; init; }

    /// <summary>kind=test: test projects (csproj name, relative path or unique part); empty = all.</summary>
    public List<string> Projects { get; init; } = [];

    /// <summary>kind=test: a dotnet test --filter expression.</summary>
    public string? Filter { get; init; }

    /// <summary>kind=test: only the tests that failed in each project's last result.</summary>
    public bool RerunFailed { get; init; }

    /// <summary>kind=test: the result names the passed tests too (at most <see cref="MaxPassed"/> per project).</summary>
    public bool IncludePassed { get; init; }

    public int? MaxPassed { get; init; }

    /// <summary>kind=test (octo-tools AB#8835): refuse | warn | off - what a run with Docker projects does when Docker has too little free memory.</summary>
    public string? DockerCheck { get; init; }

    public double? MinDockerFreeMemoryGiB { get; init; }

    /// <summary>kind=test: limits for every container the tests start (cpus; memory such as 4g, "0" = none).</summary>
    public double? DockerCpus { get; init; }

    public string? DockerMemory { get; init; }

    public bool StopServices { get; init; }
    public bool RestartServices { get; init; }
    public bool IgnoreRunningServices { get; init; }
    public string? Profile { get; init; }
    public PackageMode Packages { get; init; } = PackageMode.Lane;
    public bool Publish { get; init; }
    public bool Confirm { get; init; }
    public bool StopExternal { get; init; }
    public bool OnlyStale { get; init; } = true;

    /// <summary>kind=range: repos built from another folder (a worktree), keyed by repo name.</summary>
    public Dictionary<string, string> RepoPaths { get; init; } = new();
}

public sealed record BuildPlanRepo(
    string Repo,
    string Mode,
    string Path,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    bool? Stale,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    string? StaleReason)
{
    /// <summary>kind=env: what the build would do with the repo (build | skip), why (unchanged, notSelected, excluded, sourcesChanged, upstreamBuilt, ...) and the cmdlet's detail.</summary>
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Action { get; init; }

    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Reason { get; init; }

    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Detail { get; init; }

    /// <summary>kind=env: the environment repos this one waits for when repos build in parallel.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<string>? DependsOn { get; init; }

    /// <summary>kind=env: the repo builds alone (build.ps1, frontend, zenon, a CK model).</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public bool? Exclusive { get; init; }
}

public sealed record BuildPlanStep(string Kind, string Target, string Command, IReadOnlyList<BuildPlanRepo> Repos);

/// <summary>A service process in a repository the build writes to. kind: own (octo-devstack's) | external.</summary>
public sealed record BuildConflict(
    string Repo,
    string Service,
    int Pid,
    string Kind,
    string StartedBy,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    string? StopHint,
    bool StoppableByDaemon,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    string? Branch = null)
{
    /// <summary>The stack slot of an own service (its Service is qualified "slot/name" outside the default slot); null for external ones.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Slot { get; init; }
}

/// <summary>What base_build / lane_build needs for this plan; unmet = what the given request still lacks.</summary>
public sealed record BuildGates(bool Lease, bool Publish, bool Confirm, bool StopServices, bool StopExternal, IReadOnlyList<string> Unmet)
{
    /// <summary>The stack slots whose lease the owner must hold (when Lease): the default slot, plus every slot with services in the build scope.</summary>
    public IReadOnlyList<string> LeaseSlots { get; init; } = [];
}

public sealed record BuildPlanResult(
    string Kind,
    string Target,
    string Configuration,
    [property: System.Text.Json.Serialization.JsonPropertyName("packages")]
    BuildLane? Lane,
    IReadOnlyList<BuildPlanStep> Steps,
    IReadOnlyList<BuildConflict> Conflicts,
    IReadOnlyList<string> Warnings,
    BuildGates Gates,
    IReadOnlyList<string> MissingCapabilities);

/// <summary>One cmdlet call of a job.</summary>
internal sealed class StepSpec
{
    public required BuildKind Kind { get; init; }
    public required string Target { get; init; }

    /// <summary>The cmdlet call without -EventsFile (appended at run time when supported).</summary>
    public required string Script { get; init; }

    public required IReadOnlyList<PlanRepo> Repos { get; init; }
    public required string HistoryLane { get; init; }
    public required TimeSpan Timeout { get; init; }
    public bool UsesEvents { get; init; }

    /// <summary>
    ///     The command whose -Json document is the step's result; null: the cmdlet of <see cref="Kind"/>. A repo step of a
    ///     build.ps1 or frontend repo names its own (AB#9417).
    /// </summary>
    public string? ResultCommand { get; init; }

    public Dictionary<string, string?> Environment { get; init; } = new();
}

/// <summary>Everything the queue needs to run a request.</summary>
internal sealed class PlannedBuild
{
    public required BuildRequest Request { get; init; }
    public required string Target { get; init; }
    public required string Configuration { get; init; }
    public string? Lane { get; init; }

    /// <summary>
    ///     The feature environment the job runs in: env= of the request, or the environment a checkout resolved to (its folder's
    ///     manifest). Kept in the job file; decides how a finished job is judged gone (AB#8915).
    /// </summary>
    public string? Environment { get; set; }

    /// <summary>The folder of <see cref="Environment"/> (where its manifest lives); kind=repo's lane may lie elsewhere (adopted in place).</summary>
    public string? EnvironmentPath { get; set; }

    public string? Branch { get; init; }
    public BuildLane? LaneInfo { get; init; }
    public required List<StepSpec> Steps { get; init; }
    public required List<string> Warnings { get; init; }
    public required BuildCapabilities Capabilities { get; init; }
    public List<BuildPlanRepo> PlanRepos { get; init; } = [];

    /// <summary>
    ///     kind=test: the folder of the tested repository (in the lane, or in the base lane for the shared stack). The services
    ///     of the target stack that run from it are stopped for the run; no service starts from it while the run goes on.
    /// </summary>
    public string? TestFolder { get; init; }

    /// <summary>kind=test: the slot of the target stack - the lane stack's of a lane test, the default slot (shared stack) otherwise.</summary>
    public string? TestSlot { get; init; }

    /// <summary>
    ///     kind=repo of a plain git worktree (not a repo folder of a lane or of the base lane, built with Invoke-Build, packages
    ///     from the lane): the folder. Such a build writes only into the worktree, restores from the lane's feed and publishes
    ///     nothing into it, so it runs next to other worktree builds and lane builds (<see cref="BuildQueue"/>).
    /// </summary>
    public string? Worktree { get; set; }

    /// <summary>Folders whose running services conflict (plan repos with a build mode; the tested repository of a test run).</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public IEnumerable<string> ConflictPaths =>
        Steps.SelectMany(s => s.Repos).Where(r => r.Mode != "none" && !(r.Action == "skip" && r.Reason is "notSelected" or "excluded")).Select(r => r.Path)
            .Concat(TestFolder == null ? [] : [TestFolder]).Distinct();

    /// <summary>
    ///     The repositories the job's evidence covers: the repos of the plan the job builds (not the ones it leaves out as not
    ///     selected or excluded - evidence names only what the job ran on), or the tested repository of a test run.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public IEnumerable<(string Repo, string Path)> EvidenceRepos =>
        Request.Kind == BuildKind.Test
            ? TestFolder == null ? [] : [(System.IO.Path.GetFileName(TestFolder.TrimEnd('/', '\\')), TestFolder)]
            : Steps.SelectMany(s => s.Repos).Where(r => !(r.Action == "skip" && r.Reason is "notSelected" or "excluded"))
                .Select(r => (r.Name, r.Path)).DistinctBy(r => PathScope.Normalize(r.Path), StringComparer.OrdinalIgnoreCase);
}

public sealed class BuildQueueOptions
{
    public TimeSpan RepoTimeout { get; init; } = TimeSpan.FromMinutes(45);
    public TimeSpan RangeTimeout { get; init; } = TimeSpan.FromHours(2);
    public TimeSpan AllTimeout { get; init; } = TimeSpan.FromHours(3);

    /// <summary>A test run, the wait for the machine-wide test lock included.</summary>
    public TimeSpan TestTimeout { get; init; } = TimeSpan.FromHours(3);
    public TimeSpan IdleTimeout { get; init; } = TimeSpan.FromMinutes(20);

    /// <summary>
    ///     How often the idle watchdog of a test run looks at its per-project test logs again (AB#9417): Invoke-OctoTestRun
    ///     writes the dotnet test and ng output only there, so these writes count as activity.
    /// </summary>
    public TimeSpan TestLogScanInterval { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan PlanTimeout { get; init; } = TimeSpan.FromMinutes(3);
    public TimeSpan ExternalStopTimeout { get; init; } = TimeSpan.FromMinutes(2);
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>How often a test run that waits behind its environment's build is looked at again (AB#8832).</summary>
    public TimeSpan EarlyRecheck { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>How long a "needs no build" answer of Invoke-OctoTestRun -WhatIf counts for an early start.</summary>
    public TimeSpan EarlyProbeValid { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>After this a "needs a build" answer is asked for again.</summary>
    public TimeSpan EarlyProbeRetry { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>The Docker VM size, for the warning of test runs that start containers (null: no check).</summary>
    public Runtime.DockerVm? Docker { get; init; }

    /// <summary>Overrides the OS check of kind=all (tests).</summary>
    public bool? IsWindows { get; init; }

    /// <summary>Whether a persisted pid is still the build's pwsh (default: alive and its command line names pwsh).</summary>
    public Func<int, bool>? IsBuildProcess { get; init; }
}

/// <summary>Turns a build request into cmdlet calls: dry-runs the cmdlets, finds conflicts, stale repos and the gates.</summary>
internal sealed class BuildPlanner(
    ConfigStore store,
    StackSupervisor supervisor,
    LeaseManager lease,
    DevStackPaths paths,
    IPwshRunner runner,
    BuildCapabilityCache capabilities,
    BuildQueueOptions options,
    Func<Task<ExternalSnapshot>> external)
{
    public const string NuGetOrg = "https://api.nuget.org/v3/index.json";

    /// <summary>The first warning (and job note) of every packages=private build.</summary>
    public const string PrivateDeprecation =
        "packages=private is deprecated: use a lane (lane_create, lane_build) - it has its own feed, cache, stack and lease.";

    private bool IsWindows => options.IsWindows ?? OperatingSystem.IsWindows();

    /// <summary>
    ///     octo-tools' profile.ps1 sets $rootPath (and ROOTPATH) to &lt;octo-tools&gt;/../.. - for an octo-tools worktree that is
    ///     .../octo-tools/.claude/worktrees - and the build cmdlets resolve -branch against it. The daemon passes -branch
    ///     relative to ITS rootPath, so every build-related call sets octo-tools' root to the daemon's first.
    /// </summary>
    public static string RootPrelude(string rootPath)
    {
        var root = PwshRunner.Quote(rootPath);
        return $"$global:rootPath = {root}; $Global:ROOTPATH = {root}; $env:ROOTPATH = {root}\n";
    }

    private string Rooted(string script) => RootPrelude(ServicePlanner.RootPath(store.Load())) + script;

    public async Task<PlannedBuild> PlanAsync(BuildRequest request, bool forPlanTool, CancellationToken cancellationToken)
    {
        var config = store.Load();
        var scope = Bind(config, request);
        supervisor.Removals.Refuse(scope?.Name); // AB#9673: no job on a lane that is being removed
        if (scope != null)
        {
            // A repo name of the manifest means its folder, which may lie outside the environment (adopted in place).
            var path = request.Kind == BuildKind.Repo && request.Path != null && scope.Environment.RepoPaths().TryGetValue(request.Path, out var own) ? own : request.Path;
            request = request with { Checkout = scope.Checkout, Path = path };
        }

        var octoTools = ServicePlanner.OctoToolsPath(config);
        var caps = await capabilities.GetAsync(octoTools, cancellationToken);
        if (request.RefreshCatalogs && request.Kind == BuildKind.Test)
        {
            throw new ArgumentException("refreshCatalogs applies to builds, not to a test run.");
        }

        if (request.RefreshCatalogs && !caps.RefreshCatalogs)
        {
            throw new InvalidOperationException(
                $"refreshCatalogs: the build cmdlets of the octo-tools in {octoTools} have no -refreshCatalogs (it comes with octo-tools AB#8831; without it " +
                "every CK compile reads the remote catalogs anyway). Leave refreshCatalogs out.");
        }

        if (request.Kind != BuildKind.Env && (request.Repos.Count > 0 || request.Skip.Count > 0 || request.BuildUnchanged || request.MaxParallel != null))
        {
            throw new ArgumentException("repos, skip, buildUnchanged and maxParallel apply to lane_build only (base_build kind=range: from/to/include/exclude).");
        }

        if (request.MaxParallel is < 1 or > 16)
        {
            throw new ArgumentException("maxParallel must be between 1 and 16 (1 = one repo after the other).");
        }

        var planned = request.Kind switch
        {
            BuildKind.Repo => await PlanRepoAsync(config, octoTools, caps, request, forPlanTool, cancellationToken),
            BuildKind.Range => await PlanRangeAsync(config, octoTools, caps, request, forPlanTool, cancellationToken),
            BuildKind.All => await PlanAllAsync(config, octoTools, caps, request, cancellationToken),
            BuildKind.Env => await PlanEnvAsync(config, octoTools, caps, request, scope!, forPlanTool, cancellationToken),
            BuildKind.Test => PlanTest(config, octoTools, caps, request, scope),
            _ => await PlanProfileAsync(config, octoTools, caps, request, forPlanTool, cancellationToken)
        };
        if (scope != null)
        {
            planned.Environment = scope.Name;
            planned.EnvironmentPath = scope.Checkout;
        }
        else if (DetectedEnvironment(config, request.Checkout, planned.Lane) is { } detected)
        {
            // checkout=<environment folder>: the job runs in that environment, whose repos may lie outside its folder.
            planned.Environment = detected.Name;
            planned.EnvironmentPath = detected.Path;
            supervisor.Removals.Refuse(detected.Name); // AB#9673: also a job that names the lane only by its folder
        }

        if (IsPlainWorktree(planned))
        {
            planned.Worktree = planned.Steps[0].Repos[0].Path;
        }

        return planned;
    }

    /// <summary>The environment a request without env= runs in: its checkout or its lane is an environment folder (manifest).</summary>
    private static EnvironmentInfo? DetectedEnvironment(DevStackConfig config, string? checkout, string? lane)
    {
        var root = ServicePlanner.RootPath(config);
        if (checkout != null)
        {
            try
            {
                if (EnvironmentDiscovery.OfCheckout(ServicePlanner.ResolveFolder(checkout, root, null, "base lane"), root) is { } env)
                {
                    return env;
                }
            }
            catch (InvalidOperationException)
            {
                // A checkout that does not resolve was refused by the plan already.
            }
        }

        return lane == null ? null : EnvironmentDiscovery.OfCheckout(lane, root);
    }

    /// <summary>
    ///     The environment of a request: kind=env needs one; range and all build a lane's shared packages and take none (an
    ///     environment's packages are built with kind=env); an environment has its own feed, so packages=private is refused.
    /// </summary>
    internal static EnvironmentScope? Bind(DevStackConfig config, BuildRequest request)
    {
        if (request.Kind == BuildKind.Env && string.IsNullOrWhiteSpace(request.Environment))
        {
            throw new ArgumentException("A lane build needs lane=<name> (lane_list).");
        }

        if (request.SyncMain && request.Kind != BuildKind.Env)
        {
            throw new ArgumentException("syncMain applies to lane_build only.");
        }

        if (string.IsNullOrWhiteSpace(request.Environment))
        {
            return null;
        }

        if (request.Kind is BuildKind.Range or BuildKind.All)
        {
            throw new ArgumentException($"kind={request.Kind.ToString().ToLowerInvariant()} builds the base lane's shared packages; a lane's repos are built with lane_build.");
        }

        if (request.Packages != PackageMode.Lane)
        {
            throw new ArgumentException("A lane restores from and publishes into its own feed (<rootPath>/wt-<lane>/nuget); leave packages out.");
        }

        return EnvironmentBinding.Resolve(config, request.Environment, null, request.Checkout);
    }

    // ---------- kinds ----------

    /// <summary>
    ///     A test run: one Invoke-OctoTestRun call for a repository of an environment or a lane. Nothing is dry-run here; the
    ///     cmdlet's plan event names the test projects. The services of the target stack (the environment's slot, else the
    ///     default slot) that run from the tested repository are stopped for the run - that needs the stack's lease, like a
    ///     build with stopServices - and started again after it (<see cref="BuildQueue"/>).
    /// </summary>
    private PlannedBuild PlanTest(DevStackConfig config, string octoTools, BuildCapabilities caps, BuildRequest request, EnvironmentScope? scope)
    {
        if (string.IsNullOrWhiteSpace(request.Repo))
        {
            throw new ArgumentException("repo is required for a test run (the repository whose tests run).");
        }

        if (!caps.Tests.Run)
        {
            throw new InvalidOperationException(TestCapabilities.Unavailable(caps, octoTools));
        }

        if (request.RerunFailed && !caps.Tests.RerunFailed)
        {
            throw new InvalidOperationException($"Invoke-OctoTestRun of the octo-tools in {octoTools} has no -rerunFailed.");
        }

        var root = ServicePlanner.RootPath(config);
        var context = scope == null ? ServicePlanner.CreateContext(config, request.Checkout, null) : null;
        var lane = scope?.Checkout ?? context!.Checkout;
        var branch = System.IO.Path.GetRelativePath(root, lane).Replace('\\', '/');
        var repo = request.Repo.Trim();
        if (context is { Environment: null })
        {
            // An environment checks its own repos (Invoke-OctoTestRun -env); a lane without any would fail in the cmdlet at once.
            LaneRepositories.Require(lane, config.DefaultCheckout, "base_test", repo);
        }

        var parts = new List<string>
        {
            "Invoke-OctoTestRun", scope != null ? $"-env {PwshRunner.Quote(scope.Name)}" : $"-branch {PwshRunner.Quote(branch)}", $"-repo {PwshRunner.Quote(repo)}"
        };
        var projects = request.Projects.Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p.Trim()).ToList();
        if (projects.Count > 0)
        {
            parts.Add($"-project {string.Join(",", projects.Select(PwshRunner.Quote))}");
        }

        if (!string.IsNullOrWhiteSpace(request.Filter))
        {
            parts.Add($"-filter {PwshRunner.Quote(request.Filter)}");
        }

        if (request.RerunFailed)
        {
            parts.Add("-rerunFailed");
        }

        if (request.IncludePassed)
        {
            if (!caps.Tests.IncludePassed)
            {
                throw new InvalidOperationException($"Invoke-OctoTestRun of the octo-tools in {octoTools} has no -includePassed (it comes with octo-tools AB#8832); leave includePassed out.");
            }

            parts.Add("-includePassed");
            if (request.MaxPassed is { } maxPassed)
            {
                parts.Add($"-maxPassed {Math.Clamp(maxPassed, 1, 2000)}");
            }
        }

        parts.AddRange(DockerArguments(request, caps, octoTools));
        var configuration = request.Configuration ?? config.Configuration;
        if (request.Configuration != null && !string.Equals(request.Configuration, config.Configuration, StringComparison.OrdinalIgnoreCase))
        {
            parts.Add($"-configuration {PwshRunner.Quote(configuration)}");
        }

        // The cmdlet resolves the name itself; the folder tells which services the run stops, and what the evidence covers.
        var folder = TestFolderOf(scope?.Environment.RepoPaths(), lane, repo);
        var slot = scope?.Slot ?? SlotInfo.DefaultName;
        var warnings = new List<string>();
        if (folder != null)
        {
            var running = supervisor.RunningInSlots([folder]);
            var stopSlots = scope == null ? new HashSet<string> { slot } : new HashSet<string> { slot, SlotInfo.DefaultName };
            foreach (var group in running.Where(r => stopSlots.Contains(r.Slot.Slot.Name)).GroupBy(r => r.Slot.Slot.Name).OrderBy(g => g.Key == slot ? 0 : 1))
            {
                var stack = group.Key == SlotInfo.DefaultName ? "the shared stack" : $"the lane stack of {scope?.Name ?? group.Key}";
                var lease = group.Key == SlotInfo.DefaultName && scope != null ? " (with the shared stack's lease of the caller, taken when free)" : "";
                warnings.Add($"The run stops {string.Join(", ", group.Select(r => r.Instance.Plan.Name).Distinct())} of {stack} first{lease} - they run from " +
                             $"{folder}, and Invoke-OctoTestRun rebuilds the project of a running service (MSB3027 on Windows) - and starts them again " +
                             "afterwards with their source, also after a failed or canceled run.");
            }

            if (running.Where(r => !stopSlots.Contains(r.Slot.Slot.Name)).Select(r => r.Slot.Qualify(r.Instance.Plan.Name)).Distinct().ToList() is { Count: > 0 } others)
            {
                warnings.Add($"{string.Join(", ", others)} of other lane stacks run from {folder} too and are not stopped: a test project built while they run " +
                             "replaces binaries under them and may fail with MSB3027 on Windows; stop them first (service_stop with their lane).");
            }
        }
        else
        {
            // The cmdlet may still find the repository by a part of its name; the daemon does not guess it.
            warnings.Add($"'{repo}' names no repository folder exactly (folder name or the name without 'octo-'): the run stops no service running from the " +
                         "tested repository (Invoke-OctoTestRun rebuilds the project of a running service - MSB3027 on Windows) and its evidence names no " +
                         "repository. Name the repository exactly to get both.");
        }

        var target = $"{scope?.Name ?? branch}: tests of {repo}";
        var step = new StepSpec
        {
            Kind = BuildKind.Test,
            Target = target,
            Script = string.Join(' ', parts) + " -Json",
            Repos = [],
            HistoryLane = "",
            Timeout = options.TestTimeout,
            UsesEvents = caps.Tests.Events
        };
        return new PlannedBuild
        {
            Request = request, Target = target, Configuration = configuration, Lane = lane, Branch = branch, Steps = [step], Warnings = warnings, Capabilities = caps,
            TestFolder = folder, TestSlot = slot
        };
    }

    /// <summary>
    ///     The folder of the repository a test run tests: the exact name or the name without 'octo-' - of the lane's manifest
    ///     (<paramref name="laneRepos"/>), else a folder of <paramref name="checkout"/>. Invoke-OctoTestRun also takes a part
    ///     that matches one repository only; the daemon does not guess that (its guess could name another folder than the one
    ///     the cmdlet tests): null then, so the run stops no service and its evidence names no repository.
    /// </summary>
    internal static string? TestFolderOf(IReadOnlyDictionary<string, string>? laneRepos, string checkout, string repo)
    {
        IReadOnlyDictionary<string, string> candidates;
        try
        {
            candidates = laneRepos ?? (Directory.Exists(checkout)
                ? Directory.EnumerateDirectories(checkout).ToDictionary(d => System.IO.Path.GetFileName(d), d => d, StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, string>());
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        foreach (var name in new[] { repo, "octo-" + repo })
        {
            if (candidates.TryGetValue(name, out var exact))
            {
                return exact;
            }
        }

        return null;
    }

    /// <summary>-dockerCheck / -minDockerFreeMemoryGiB / -dockerCpus / -dockerMemory of Invoke-OctoTestRun (octo-tools AB#8835), only what was asked for.</summary>
    internal static List<string> DockerArguments(BuildRequest request, BuildCapabilities caps, string octoTools)
    {
        var parts = new List<string>();
        var invariant = System.Globalization.CultureInfo.InvariantCulture;
        if (!string.IsNullOrWhiteSpace(request.DockerCheck))
        {
            var check = request.DockerCheck.Trim().ToLowerInvariant() switch
            {
                "refuse" => "Refuse", "warn" => "Warn", "off" => "Off",
                _ => throw new ArgumentException("dockerCheck is refuse, warn or off.")
            };
            parts.Add($"-dockerCheck {check}");
        }

        if (request.MinDockerFreeMemoryGiB is { } free)
        {
            parts.Add($"-minDockerFreeMemoryGiB {Math.Clamp(free, 0, 1024).ToString(invariant)}");
        }

        if (request.DockerCpus is { } cpus)
        {
            parts.Add($"-dockerCpus {Math.Clamp(cpus, 0, 512).ToString(invariant)}");
        }

        if (request.DockerMemory != null)
        {
            var memory = request.DockerMemory.Trim();
            if (memory.Length > 0 && !System.Text.RegularExpressions.Regex.IsMatch(memory, "^[0-9]+(\\.[0-9]+)?[bkmgBKMG]?$"))
            {
                throw new ArgumentException("dockerMemory is a size such as 4g or 512m; 0 or an empty text sets no limit.");
            }

            parts.Add($"-dockerMemory {PwshRunner.Quote(memory)}");
        }

        if (parts.Count > 0 && !caps.Tests.DockerCheck)
        {
            throw new InvalidOperationException(
                $"Invoke-OctoTestRun of the octo-tools in {octoTools} has no Docker check or container limits (they come with octo-tools AB#8835); " +
                "leave dockerCheck, minDockerFreeMemoryGiB, dockerCpus and dockerMemory out.");
        }

        return parts;
    }

    private async Task<PlannedBuild> PlanRepoAsync(DevStackConfig config, string octoTools, BuildCapabilities caps, BuildRequest request, bool forPlanTool,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.Path))
        {
            throw new ArgumentException("path is required for kind=repo (a repo folder in the base lane, a worktree, or absolute).");
        }

        if (request.Packages == PackageMode.Publish)
        {
            throw new ArgumentException("packages=publish applies to kind=range (Invoke-Build copies no packages); use packages=lane or private.");
        }

        var root = ServicePlanner.RootPath(config);
        var checkout = ServicePlanner.CreateContext(config, request.Checkout, null).Checkout;
        var target = ServicePlanner.ResolveFolder(request.Path, root, checkout, "build path");
        if (NestedWorktreeRepo(target) is { } nestedIn)
        {
            throw new InvalidOperationException(NestedWorktreeRefusal(target, nestedIn));
        }

        var configuration = request.Configuration ?? config.Configuration;
        var lane = PathScope.LaneOf(target);
        var warnings = new List<string>();
        var (properties, env, feed) = PackageSettings(request, caps, kindIsRange: false, lane, warnings);
        var step = RepoStep(target, configuration, lane, properties, env, caps);
        if (step.Repos[0].Mode != "dotnet")
        {
            warnings.Add((step.Repos[0].Mode == "none"
                             ? $"{step.Repos[0].Name} has no solution and no build.ps1: nothing to build, as in Invoke-BuildAll"
                             : $"{step.Repos[0].Name} is built in mode {step.Repos[0].Mode}, as Invoke-BuildAll builds it") +
                         (properties.Count > 0 ? "; packages=private and its MSBuild properties do not apply to it" : "") +
                         (request.RefreshCatalogs ? "; refreshCatalogs does not apply to it" : "") + ".");
        }

        var info = await LaneInfoFromDryRunAsync(octoTools, $"Invoke-Build -repositoryPath {PwshRunner.Quote(target)} -configuration {PwshRunner.Quote(configuration)} -DryRun -Json",
            env, lane, feed, cancellationToken);
        if (request.VerifyTests || request.IncludeTests)
        {
            warnings.Add("Invoke-Build builds the whole solution including the tests; verifyTests/includeTests change nothing for kind=repo.");
        }

        return new PlannedBuild
        {
            Request = request,
            Target = target,
            Configuration = configuration,
            Lane = lane,
            LaneInfo = info,
            Steps = [step],
            Warnings = warnings,
            Capabilities = caps,
            PlanRepos = step.Repos.Select(r => ToPlanRepo(r, configuration, forPlanTool)).ToList()
        };
    }

    private async Task<PlannedBuild> PlanRangeAsync(DevStackConfig config, string octoTools, BuildCapabilities caps, BuildRequest request, bool forPlanTool,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.From))
        {
            throw new ArgumentException("from is required for kind=range (first repo of the slice, e.g. octo-construction-kit-engine).");
        }

        if (request.IgnoreRunningServices)
        {
            throw new ArgumentException("ignoreRunningServices applies to kind=repo only; Invoke-BuildRange refuses running services on its own.");
        }

        var (lane, branch) = Lane(config, request.Checkout);
        LaneRepositories.Require(lane, config.DefaultCheckout, "base_build kind=range");
        var configuration = request.Configuration ?? config.Configuration;
        var warnings = new List<string>();
        var (properties, env, feed) = PackageSettings(request, caps, kindIsRange: true, lane, warnings);
        if (request.RepoPaths.Count > 0 && !caps.RangeRepoPaths)
        {
            throw new InvalidOperationException("repoPaths needs Invoke-BuildRange -repoPaths, which the octo-tools checkout of the daemon does not have yet.");
        }

        var parts = new List<string>
        {
            "Invoke-BuildRange",
            $"-branch {PwshRunner.Quote(branch)}",
            $"-from {PwshRunner.Quote(request.From)}",
            $"-configuration {PwshRunner.Quote(configuration)}"
        };
        if (!string.IsNullOrEmpty(request.To))
        {
            parts.Add($"-to {PwshRunner.Quote(request.To)}");
        }

        if (request.Include.Count > 0)
        {
            parts.Add($"-include @({string.Join(",", request.Include.Select(PwshRunner.Quote))})");
        }

        if (request.Exclude.Count > 0)
        {
            parts.Add($"-exclude @({string.Join(",", request.Exclude.Select(PwshRunner.Quote))})");
        }

        if (request.IncludeTests)
        {
            parts.Add("-includeTests");
        }
        else if (request.VerifyTests)
        {
            parts.Add("-verifyTests");
        }

        if (request.RepoPaths.Count > 0)
        {
            parts.Add($"-repoPaths {PwshRunner.Hashtable(request.RepoPaths.Select(p => KeyValuePair.Create(p.Key, ServicePlanner.ResolveFolder(p.Value, ServicePlanner.RootPath(config), lane, $"repoPaths.{p.Key}"))))}");
        }

        if (feed != null)
        {
            parts.Add($"-feedPath {PwshRunner.Quote(feed)}");
        }

        if (properties.Count > 0)
        {
            parts.Add($"-msbuildProperties {PwshRunner.Hashtable(properties)}");
        }

        // Never -ignoreRunningServices: the daemon stops its own services itself (stopServices), and the cmdlet's own
        // check must stay on for processes the daemon does not own (a Start-Octo stack of another session).
        var call = string.Join(' ', parts);
        var whatIf = await RunJsonAsync(octoTools, call + " -WhatIf -Json", env, cancellationToken);
        var data = whatIf?["data"] as JsonObject
                   ?? throw new InvalidOperationException("Invoke-BuildRange -WhatIf -Json printed no result; is octoToolsPath right?");
        if (data["error"]?.GetValue<string>() is { } error)
        {
            throw new InvalidOperationException($"Invoke-BuildRange refuses the range: {error}");
        }

        var repos = (data["repositories"] as JsonArray ?? [])
            .OfType<JsonObject>()
            .Select(r => new PlanRepo(Str(r["repo"]) ?? "?", Str(r["mode"]) ?? "dotnet", Str(r["path"]) ?? System.IO.Path.Combine(lane, Str(r["repo"]) ?? "")))
            .ToList();
        if (repos.Count == 0)
        {
            throw new InvalidOperationException($"Invoke-BuildRange plans no repository for {request.From} -> {request.To ?? request.From}.");
        }

        foreach (var stale in (data["staleGlobalCache"] as JsonArray ?? []).OfType<JsonObject>().Take(1))
        {
            warnings.Add($"{(data["staleGlobalCache"] as JsonArray)!.Count} package cache folder(s) differ from {lane}/nuget (e.g. {Str(stale["packageId"])}); " +
                         "Invoke-BuildRange reports them, -purgeStaleCache is not passed by octo-devstack.");
        }

        if (feed == null)
        {
            warnings.Add($"Copies the built 999.0.0 packages into {lane}/nuget and purges them from the base lane's package caches: every session sees them.");
        }

        var step = new StepSpec
        {
            Kind = BuildKind.Range,
            Target = $"{branch}: {request.From} -> {(string.IsNullOrEmpty(request.To) ? request.From : request.To)}",
            Script = call + " -Json",
            Repos = repos,
            HistoryLane = lane,
            Timeout = options.RangeTimeout,
            UsesEvents = caps.RangeEvents,
            Environment = env
        };
        var laneInfo = data["lane"] is JsonObject l
            ? new BuildLane(lane, Bool(l["isolated"]), Strings(data["packageCaches"]), feed)
            : new BuildLane(lane, null, Strings(data["packageCaches"]), feed);
        return new PlannedBuild
        {
            Request = request,
            Target = step.Target,
            Configuration = configuration,
            Lane = lane,
            Branch = branch,
            LaneInfo = laneInfo,
            Steps = [step],
            Warnings = warnings,
            Capabilities = caps,
            PlanRepos = repos.Select(r => ToPlanRepo(r, configuration, forPlanTool)).ToList()
        };
    }

    private async Task<PlannedBuild> PlanAllAsync(DevStackConfig config, string octoTools, BuildCapabilities caps, BuildRequest request,
        CancellationToken cancellationToken)
    {
        if (request.Packages == PackageMode.Private)
        {
            throw new ArgumentException("packages=private is not possible for kind=all: Invoke-BuildAll always resets the base lane's packages.");
        }

        if (request.IgnoreRunningServices)
        {
            throw new ArgumentException("ignoreRunningServices applies to kind=repo only.");
        }

        if (IsWindows && !(caps.KillDotnetLaneScoped && caps.AllSkipKill))
        {
            // Invoke-BuildAll runs Invoke-KillDotnet on Windows; without -skipKill and a lane-scoped Invoke-KillDotnet it
            // would kill every dotnet process of the machine (octo-devstack and the stacks of other lanes included).
            throw new InvalidOperationException("kind=all is refused on Windows while octo-tools lacks Invoke-BuildAll -skipKill and a lane-scoped " +
                                                "Invoke-KillDotnet -branchRootPath: Invoke-BuildAll would kill every dotnet process of the machine.");
        }

        var (lane, branch) = Lane(config, request.Checkout);
        LaneRepositories.Require(lane, config.DefaultCheckout, "base_build kind=all");
        var configuration = request.Configuration ?? config.Configuration;
        var call = $"Invoke-BuildAll -branch {PwshRunner.Quote(branch)} -configuration {PwshRunner.Quote(configuration)}";
        var warnings = new List<string>
        {
            $"Invoke-BuildAll builds every repo of the base lane {lane} (30-90 min) and, in DebugL, wipes {lane}/nuget and the meshmakers.*/999.0.0 folders " +
            "of the base lane's package caches (the ones it restores into; build_plan lists them from Invoke-BuildAll -DryRun)" +
            ": every session rebuilds against the new packages."
        };
        List<PlanRepo> repos;
        BuildLane? laneInfo = null;
        if (caps.AllDryRun)
        {
            var dry = await RunJsonAsync(octoTools, call + " -DryRun -Json", null, cancellationToken);
            var data = dry?["data"] as JsonObject ?? throw new InvalidOperationException("Invoke-BuildAll -DryRun -Json printed no result.");
            repos = (data["repositories"] as JsonArray ?? []).OfType<JsonObject>()
                .Select(r => new PlanRepo(Str(r["repo"]) ?? "?", ModeOfBuilder(Str(r["builder"])), System.IO.Path.Combine(lane, Str(r["repo"]) ?? "")))
                .ToList();
            laneInfo = new BuildLane(lane, Bool((data["lane"] as JsonObject)?["isolated"]), Strings(data["packageCachesToPurge"]), null);
        }
        else
        {
            repos = (await BuildOrderAsync(octoTools, lane, cancellationToken)).Select(r => new PlanRepo(r.Name, "dotnet", r.Path)).ToList();
        }

        if (caps.AllSkipKill)
        {
            call += " -skipKill"; // the daemon stops the lane's services itself before the build
        }

        var step = new StepSpec
        {
            Kind = BuildKind.All,
            Target = $"{branch}: all",
            Script = call + " -Json",
            Repos = repos,
            HistoryLane = lane,
            Timeout = options.AllTimeout,
            UsesEvents = caps.AllEvents
        };
        return new PlannedBuild
        {
            Request = request,
            Target = step.Target,
            Configuration = configuration,
            Lane = lane,
            Branch = branch,
            LaneInfo = laneInfo ?? new BuildLane(lane, null, [], null),
            Steps = [step],
            Warnings = warnings,
            Capabilities = caps,
            PlanRepos = repos.Select(r => new BuildPlanRepo(r.Name, r.Mode, r.Path, null, null)).ToList()
        };
    }

    private async Task<PlannedBuild> PlanProfileAsync(DevStackConfig config, string octoTools, BuildCapabilities caps, BuildRequest request, bool forPlanTool,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.Profile))
        {
            throw new ArgumentException("profile is required for kind=profile.");
        }

        if (request.Packages == PackageMode.Publish)
        {
            throw new ArgumentException("packages=publish applies to kind=range; a profile build compiles the services' repos with Invoke-Build.");
        }

        var resolved = ProfileResolver.Resolve(config, request.Profile, null);
        var configuration = request.Configuration ?? resolved.Configuration;
        var context = ServicePlanner.CreateContext(resolved.Config, request.Checkout ?? resolved.Checkout, configuration);
        var lane = context.Checkout;
        if (request.Environment == null && context.Environment == null)
        {
            LaneRepositories.Require(lane, config.DefaultCheckout, "base_build kind=profile");
        }

        var warnings = new List<string>();
        var targets = new List<(string Path, List<string> Services)>();
        foreach (var name in resolved.Services)
        {
            var plan = ServicePlanner.Plan(resolved.Config, context, name, resolved.Overrides.GetValueOrDefault(name), new Dictionary<string, string?>());
            if (plan.Args.FirstOrDefault()?.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) != true)
            {
                warnings.Add($"{name} is not a .NET service ({plan.Command}); a profile build leaves it out.");
                continue;
            }

            var entry = targets.FirstOrDefault(t => PathScope.SamePath(t.Path, plan.RepoPath));
            if (entry.Path == null)
            {
                targets.Add((plan.RepoPath, [name]));
            }
            else
            {
                entry.Services.Add(name);
            }
        }

        if (request.Environment != null)
        {
            // The base lane's repos are main-lane work: an environment's profile build compiles only what the environment holds.
            var own = EnvironmentDiscovery.OfCheckout(lane, ServicePlanner.RootPath(config))?.RepoPaths().Values.ToList() ?? [];
            var outside = targets.Where(t => !PathScope.IsUnder(t.Path, lane) && !own.Any(o => PathScope.SamePath(o, t.Path))).ToList();
            foreach (var t in outside)
            {
                warnings.Add($"{string.Join(", ", t.Services)} run(s) from the base lane ({t.Path}); a lane build leaves that repo out.");
                targets.Remove(t);
            }
        }

        var order = await BuildOrderAsync(octoTools, lane, cancellationToken);
        int Position(string path)
        {
            var name = PathScope.IsWorktree(path) ? CheckoutDiscovery.ReadWorktree(System.IO.Path.Combine(path, ".git")).Repo ?? System.IO.Path.GetFileName(path) : System.IO.Path.GetFileName(path);
            var index = order.FindIndex(o => string.Equals(o.Name, name, StringComparison.OrdinalIgnoreCase));
            // Lane repos first in build order, worktrees after the lane repo they belong to.
            return (index < 0 ? order.Count : index) * 2 + (PathScope.IsWorktree(path) ? 1 : 0);
        }

        var (properties, env, feed) = PackageSettings(request, caps, kindIsRange: false, lane, warnings);
        var steps = new List<StepSpec>();
        var planRepos = new List<BuildPlanRepo>();
        foreach (var (path, services) in targets.OrderBy(t => Position(t.Path)))
        {
            if (NestedWorktreeRepo(path) is { } nestedIn)
            {
                warnings.Add($"Left out ({string.Join(", ", services)}): {NestedWorktreeRefusal(path, nestedIn)}");
                continue;
            }

            var stale = StaleCheck.Check(path, configuration);
            var repoName = System.IO.Path.GetFileName(path);
            var step = RepoStep(path, configuration, PathScope.LaneOf(path), properties, env, caps);
            // The mode the step builds in (build.ps1, nothing to build, frontend; AB#9417), next to the stale state.
            planRepos.Add(new BuildPlanRepo(repoName, step.Repos[0].Mode, path, stale.Stale, $"{stale.Reason} ({string.Join(", ", services)})"));
            if (request.OnlyStale && !stale.Stale)
            {
                continue;
            }

            steps.Add(step);
        }

        if (steps.Count == 0)
        {
            warnings.Add($"Nothing to build: every repo of profile {request.Profile} is up to date for {configuration} (onlyStale=false builds them anyway).");
        }

        return new PlannedBuild
        {
            Request = request,
            Target = $"profile {request.Profile}",
            Configuration = configuration,
            Lane = lane,
            Branch = System.IO.Path.GetRelativePath(ServicePlanner.RootPath(config), lane),
            LaneInfo = new BuildLane(lane, null, [], feed),
            Steps = steps,
            Warnings = warnings,
            Capabilities = caps,
            PlanRepos = forPlanTool ? planRepos : planRepos.Where(p => steps.Any(s => PathScope.SamePath(s.Repos[0].Path, p.Path))).ToList()
        };
    }

    private async Task<PlannedBuild> PlanEnvAsync(DevStackConfig config, string octoTools, BuildCapabilities caps, BuildRequest request, EnvironmentScope scope,
        bool forPlanTool, CancellationToken cancellationToken)
    {
        var envCaps = caps.Environments;
        if (!envCaps.Build)
        {
            throw new InvalidOperationException($"lane_build needs the cmdlet {EnvironmentCapabilities.Unavailable(caps, "Invoke-BuildEnvironment -env")} ({octoTools}).");
        }

        if (request.IgnoreRunningServices)
        {
            throw new ArgumentException("ignoreRunningServices applies to kind=repo only.");
        }

        if (request.SyncMain && !envCaps.BuildSyncMain)
        {
            throw new InvalidOperationException($"syncMain needs Invoke-BuildEnvironment -syncMain: {EnvironmentCapabilities.TooOld}.");
        }

        if ((request.IncludeTests && !envCaps.BuildIncludeTests) || (request.VerifyTests && !request.IncludeTests && !envCaps.BuildVerifyTests))
        {
            throw new InvalidOperationException($"Invoke-BuildEnvironment of the daemon's octo-tools has no -{(request.IncludeTests ? "includeTests" : "verifyTests")}: " +
                                                $"{EnvironmentCapabilities.TooOld}.");
        }

        var lane = scope.Checkout;
        var configuration = request.Configuration ?? config.Configuration;
        var parts = new List<string> { "Invoke-BuildEnvironment", $"-env {PwshRunner.Quote(scope.Name)}" };
        if (request.Configuration != null && !string.Equals(request.Configuration, config.Configuration, StringComparison.OrdinalIgnoreCase))
        {
            parts.Add(envCaps.BuildConfiguration
                ? $"-configuration {PwshRunner.Quote(configuration)}"
                : throw new InvalidOperationException($"Invoke-BuildEnvironment takes no -configuration; it builds {config.Configuration}."));
        }

        if (request.SyncMain)
        {
            parts.Add("-syncMain");
        }

        if (request.IncludeTests)
        {
            parts.Add("-includeTests");
        }
        else if (request.VerifyTests)
        {
            parts.Add("-verifyTests");
        }

        static List<string> Names(List<string> values) => values.Where(v => !string.IsNullOrWhiteSpace(v)).Select(v => v.Trim()).ToList();
        var only = Names(request.Repos);
        var skip = Names(request.Skip);
        if ((only.Count > 0 && !envCaps.BuildRepos) || (skip.Count > 0 && !envCaps.BuildSkip) || (request.BuildUnchanged && !envCaps.BuildUnchanged))
        {
            throw new InvalidOperationException($"repos / skip / buildUnchanged: {EnvironmentCapabilities.SelectionTooOld} ({octoTools}).");
        }

        if (only.Count > 0)
        {
            parts.Add($"-repos {string.Join(",", only.Select(PwshRunner.Quote))}");
        }

        if (skip.Count > 0)
        {
            parts.Add($"-skip {string.Join(",", skip.Select(PwshRunner.Quote))}");
        }

        if (request.BuildUnchanged)
        {
            parts.Add("-buildUnchanged");
        }

        if (request.MaxParallel is { } maxParallel)
        {
            parts.Add(envCaps.BuildMaxParallel
                ? $"-maxParallel {maxParallel}"
                : throw new InvalidOperationException(
                    $"maxParallel: the octo-tools checkout of the daemon has no Invoke-BuildEnvironment -maxParallel; it comes with octo-tools AB#8814 (parallel lane builds) ({octoTools})."));
        }

        var call = string.Join(' ', parts);
        var warnings = new List<string>
        {
            $"Packages go into {System.IO.Path.Combine(lane, "nuget")} and the lane's cache only; nothing changes for the base lane {scope.Environment.BasePath}."
        };
        if (request.SyncMain)
        {
            warnings.Add($"syncMain: the lane's snapshot of {scope.Environment.BasePath}/nuget and the local catalogs is refreshed first; packages the lane built win.");
        }

        if (!request.VerifyTests && !request.IncludeTests)
        {
            warnings.Add("Test projects are not compiled: pass verifyTests=true (or includeTests=true) before a hand-off.");
        }

        List<PlanRepo> repos;
        if (envCaps.BuildDryRun)
        {
            var dry = await RunJsonAsync(octoTools, call + " -DryRun -Json", null, cancellationToken);
            var data = dry?["data"] as JsonObject ?? throw new InvalidOperationException("Invoke-BuildEnvironment -DryRun -Json printed no result.");
            if (Str(data["error"]) is { } error)
            {
                throw new InvalidOperationException($"Invoke-BuildEnvironment refuses the build: {error}");
            }

            repos = (data["repositories"] as JsonArray ?? []).OfType<JsonObject>()
                .Select(r => new PlanRepo(Str(r["repo"]) ?? "?", Str(r["mode"]) ?? ModeOfBuilder(Str(r["builder"])),
                    Str(r["path"]) ?? System.IO.Path.Combine(lane, Str(r["repo"]) ?? ""), Str(r["action"]), Str(r["reason"]), Str(r["detail"]))
                {
                    DependsOn = r["dependsOn"] is JsonArray depends ? Strings(depends) : null, Exclusive = Bool(r["exclusive"])
                })
                .ToList();
            if (Bool(data["parallel"]) == true && Num(data["maxParallel"]) is > 1 and var parallel)
            {
                warnings.Add($"Up to {parallel:0} independent repos of the lane build at the same time (maxParallel=1 builds one after the other).");
            }
            if (repos.Count > 0 && repos.All(r => r.Action == "skip"))
            {
                warnings.Add("Nothing would be built: every repo of the lane is unchanged since its last build, not selected or excluded " +
                             "(buildUnchanged=true builds them anyway).");
            }
        }
        else
        {
            // The manifest's repos (their paths may lie outside the environment folder) in the base lane's build order.
            var order = scope.Environment.BasePath == null ? [] : await BuildOrderAsync(octoTools, scope.Environment.BasePath, cancellationToken);
            repos = (scope.Environment.Manifest?.Repos ?? [])
                .OrderBy(r => order.FindIndex(o => string.Equals(o.Name, r.Name, StringComparison.OrdinalIgnoreCase)) is var i && i < 0 ? int.MaxValue : i)
                .Select(r => new PlanRepo(r.Name, "dotnet", r.Path)).ToList();
        }

        if (repos.Count == 0)
        {
            repos = (scope.Environment.Manifest?.Repos ?? []).Select(r => new PlanRepo(r.Name, "dotnet", r.Path)).ToList();
        }

        if (repos.Count == 0)
        {
            throw new InvalidOperationException($"Lane '{scope.Name}' holds no repo to build; add one with lane_add_repo.");
        }

        // A repo whose build uses sibling repositories (an app's build.ps1 builds ../octo-frontend-libraries and installs its
        // dist): they must be in the environment too - the base lane's folder is not next to the environment's worktree.
        var inEnvironment = scope.Environment.RepoPaths().Keys.ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, service) in config.Services.Where(s => s.Value.RequiresRepos.Count > 0 && inEnvironment.Contains(s.Value.Repo)))
        {
            var built = repos.FirstOrDefault(r => string.Equals(r.Name, service.Repo, StringComparison.OrdinalIgnoreCase));
            var missing = service.RequiresRepos.Where(r => !inEnvironment.Contains(r)).ToList();
            if (missing.Count == 0 || built is { Action: "skip", Reason: "notSelected" or "excluded" } ||
                skip.Any(s => string.Equals(s, service.Repo, StringComparison.OrdinalIgnoreCase)))
            {
                continue;
            }

            throw new InvalidOperationException(
                $"Lane '{scope.Name}' holds {service.Repo} without {string.Join(", ", missing)}, which its build needs as a sibling folder " +
                $"(service '{name}', requiresRepos). Add it: lane_add_repo(lane=\"{scope.Name}\", repo=\"{missing[0]}\", role=\"consumer\") - or leave the " +
                $"app out of this build with skip=[\"{service.Repo}\"].");
        }

        var step = new StepSpec
        {
            Kind = BuildKind.Env,
            Target = scope.Name,
            Script = call + " -Json",
            Repos = repos,
            HistoryLane = lane,
            Timeout = options.RangeTimeout,
            UsesEvents = envCaps.BuildEvents
        };
        return new PlannedBuild
        {
            Request = request,
            Target = step.Target,
            Configuration = configuration,
            Lane = lane,
            Branch = System.IO.Path.GetRelativePath(ServicePlanner.RootPath(config), lane).Replace('\\', '/'),
            LaneInfo = new BuildLane(lane, true, [System.IO.Path.Combine(lane, ".nuget-packages")], System.IO.Path.Combine(lane, "nuget")),
            Steps = [step],
            Warnings = warnings,
            Capabilities = caps,
            PlanRepos = repos.Select(r => ToPlanRepo(r, configuration, forPlanTool)).ToList()
        };
    }

    // ---------- shared pieces ----------

    /// <summary>
    ///     The repository a folder below <c>&lt;repo&gt;/.claude/worktrees/&lt;name&gt;</c> is nested in (the part before
    ///     .claude), or null for any other folder.
    /// </summary>
    internal static string? NestedWorktreeRepo(string folder)
    {
        var parts = System.IO.Path.GetFullPath(folder).TrimEnd('/', '\\').Split('/', '\\');
        for (var i = parts.Length - 3; i >= 1; i--)
        {
            if (string.Equals(parts[i], ".claude", StringComparison.OrdinalIgnoreCase) && string.Equals(parts[i + 1], "worktrees", StringComparison.OrdinalIgnoreCase))
            {
                var repo = string.Join(System.IO.Path.DirectorySeparatorChar, parts[..i]);
                return repo.Length == 0 || repo.EndsWith(':') ? repo + System.IO.Path.DirectorySeparatorChar : repo;
            }
        }

        return null;
    }

    /// <summary>Why a build of a nested worktree is refused, and the way out.</summary>
    internal static string NestedWorktreeRefusal(string worktree, string repo) =>
        $"{worktree} is a worktree below {System.IO.Path.Combine(repo, ".claude", "worktrees")}: it is not built. The OctoMesh repos' " +
        "Directory.Build.props imports the next Directory.Build.props above the repository, which for a nested worktree is the main checkout's " +
        $"({System.IO.Path.Combine(repo, "Directory.Build.props")}), and the pack then fails with NU5118 (README.md added twice). " +
        $"Move it into a lane: lane_add_repo with path=\"{worktree}\" moves the worktree into the lane (inPlace=false); build it there with lane_build.";

    /// <summary>
    ///     Whether a kind=repo plan builds a plain git worktree that may run next to other builds: a folder with a .git file
    ///     (a worktree) that is neither a repo folder of the base lane (&lt;lane&gt;/&lt;repo&gt;) nor of a lane (environment),
    ///     built with Invoke-Build (mode dotnet) or with nothing to build, packages from the lane (no private feed). Such a
    ///     build restores from the lane's feed and into its cache (NuGet extracts a package under its own lock), writes its bin,
    ///     obj and packages into the worktree, and publishes a CK model into the lane's local catalog (under the catalog's own
    ///     index lock) - it never writes the lane's feed or purges its cache, which is what range and all builds do. A build.ps1
    ///     or frontend step may build sibling repositories of the lane (refinery studio builds ../octo-frontend-libraries), so
    ///     it stays exclusive.
    /// </summary>
    internal static bool IsPlainWorktree(PlannedBuild planned)
    {
        if (planned.Request is not { Kind: BuildKind.Repo, Environment: null, Packages: PackageMode.Lane } || planned.Environment != null ||
            planned.Steps is not [{ Repos: [var repo] }] || repo.Mode is not ("dotnet" or "none") || !PathScope.IsWorktree(repo.Path))
        {
            return false;
        }

        var parent = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(repo.Path).TrimEnd('/', '\\'));
        var laneRepo = parent != null && planned.Lane != null && PathScope.SamePath(parent, planned.Lane) &&
                       string.Equals(System.IO.Path.GetFileName(repo.Path.TrimEnd('/', '\\')), repo.Name, StringComparison.OrdinalIgnoreCase);
        return !laneRepo;
    }

    private StepSpec RepoStep(string target, string configuration, string? lane, List<KeyValuePair<string, string>> properties,
        Dictionary<string, string?> env, BuildCapabilities caps)
    {
        var name = PathScope.IsWorktree(target)
            ? CheckoutDiscovery.ReadWorktree(System.IO.Path.Combine(target, ".git")).Repo ?? System.IO.Path.GetFileName(target)
            : System.IO.Path.GetFileName(target);
        var mode = RepoBuildMode(target, name);
        if (mode != "dotnet")
        {
            // Invoke-Build runs dotnet on the folder, which fails with MSB1003 on a repo without a solution (AB#9417):
            // such a repo is built the way Invoke-BuildAll's Compile-Repo builds it.
            return new StepSpec
            {
                Kind = BuildKind.Repo,
                Target = target,
                Script = NonDotnetRepoScript(mode, target, configuration),
                Repos = [new PlanRepo(name, mode, target)],
                HistoryLane = lane ?? target,
                Timeout = options.RepoTimeout,
                UsesEvents = false,
                ResultCommand = mode == "frontend" ? "Invoke-Publish" : RepoScriptCommand,
                Environment = env
            };
        }

        var script = $"Invoke-Build -repositoryPath {PwshRunner.Quote(target)} -configuration {PwshRunner.Quote(configuration)}";
        if (properties.Count > 0)
        {
            script += $" -msbuildProperties {PwshRunner.Hashtable(properties)}";
        }

        return new StepSpec
        {
            Kind = BuildKind.Repo,
            Target = target,
            Script = script + " -Json",
            Repos = [new PlanRepo(name, "dotnet", target)],
            HistoryLane = lane ?? target,
            Timeout = options.RepoTimeout,
            UsesEvents = caps.BuildEvents,
            Environment = env
        };
    }

    /// <summary>The command of the -Json document a build.ps1 or nothing-to-build repo step prints itself.</summary>
    internal const string RepoScriptCommand = "octo-devstack-repo-build";

    /// <summary>
    ///     The build mode of one repository, as octo-tools decides it for Invoke-BuildAll (Get-RepoBuilder) and
    ///     Invoke-BuildRange (Get-OctoRepoBuildMode): a build.ps1 in the root runs that script ('script', e.g.
    ///     octo-frontend-refinery-studio, whose script also builds ../octo-frontend-libraries); without a .sln/.slnx in the
    ///     root (nor a project file, which Invoke-Build takes as well) there is nothing to build ('none', e.g. octo-frontend-libraries); a solution of a repo named *frontend* is
    ///     published ('frontend', Invoke-Publish); every other repo is 'dotnet' (Invoke-Build). octo-plug-zenon repos stay
    ///     'dotnet' here: Invoke-BuildZenonPlug builds a Windows service and has no -Json result.
    /// </summary>
    internal static string RepoBuildMode(string path, string name)
    {
        if (File.Exists(System.IO.Path.Combine(path, "build.ps1")))
        {
            return "script";
        }

        // A project file in the root is built by Invoke-Build as before (dotnet takes it without a solution).
        var hasSolution = Directory.Exists(path) && Directory.EnumerateFiles(path)
            .Any(f => System.IO.Path.GetExtension(f) is ".sln" or ".slnx" or ".csproj" or ".fsproj");
        if (!hasSolution)
        {
            return "none";
        }

        return name.Contains("frontend", StringComparison.OrdinalIgnoreCase) ? "frontend" : "dotnet";
    }

    /// <summary>The pwsh of a repo step in mode script, frontend or none; script and none print their own -Json document.</summary>
    internal static string NonDotnetRepoScript(string mode, string target, string configuration)
    {
        var quotedTarget = PwshRunner.Quote(target);
        var quotedConfiguration = PwshRunner.Quote(configuration);
        if (mode == "frontend")
        {
            return $"Invoke-Publish -repositoryPath {quotedTarget} -configuration {quotedConfiguration} -Json";
        }

        string Document(string success, string exitCode, string detail) =>
            $"[ordered]@{{ schemaVersion = 1; command = '{RepoScriptCommand}'; data = [ordered]@{{ success = {success}; exitCode = {exitCode}; " +
            $"mode = '{mode}'; repositoryPath = {quotedTarget}; detail = {detail} }} }} | ConvertTo-Json -Depth 4 -Compress";

        if (mode == "script")
        {
            var buildScript = PwshRunner.Quote(System.IO.Path.Combine(target, "build.ps1"));
            // Like Compile-Repo: everything the script writes goes to the host, its exit code decides.
            return $"$global:LASTEXITCODE = 0; & {buildScript} -configuration {quotedConfiguration} | Out-Host; $code = $global:LASTEXITCODE; " +
                   Document("($code -eq 0)", "$code", "'build.ps1'") + "; exit $code";
        }

        return Document("$true", "0", "'no solution file and no build.ps1 in the repository root: nothing to build (Invoke-BuildAll skips it too)'");
    }

    /// <summary>packages=private: the session's feed and cache under the state folder, as -feedPath, global properties and NUGET_PACKAGES.</summary>
    private (List<KeyValuePair<string, string>> Properties, Dictionary<string, string?> Env, string? Feed) PackageSettings(BuildRequest request,
        BuildCapabilities caps, bool kindIsRange, string? lane, List<string> warnings)
    {
        var properties = new List<KeyValuePair<string, string>>();
        var env = new Dictionary<string, string?>();
        if (request.Packages != PackageMode.Private)
        {
            return (properties, env, null);
        }

        if (kindIsRange && !caps.RangeFeedPath)
        {
            throw new InvalidOperationException("packages=private needs Invoke-BuildRange -feedPath, which the octo-tools checkout of the daemon does not have " +
                                                "yet. Use packages=publish or update octo-tools (git pull in its checkout).");
        }

        if ((kindIsRange && !caps.RangeMsbuildProperties) || (!kindIsRange && !caps.BuildMsbuildProperties))
        {
            throw new InvalidOperationException("packages=private needs -msbuildProperties on the build cmdlet, which the octo-tools checkout of the daemon lacks.");
        }

        warnings.Add(PrivateDeprecation);
        var (feed, cache) = PrivateFeedOf(request.Owner);
        Directory.CreateDirectory(feed);
        Directory.CreateDirectory(cache);
        if (!kindIsRange && PrivateFeed.OwnPackages(feed).Count == 0)
        {
            warnings.Add($"The private feed of {request.Owner} ({feed}) holds no package of its own yet; build the library range with packages=private first.");
        }

        if (lane != null)
        {
            warnings.Add($"The base lane's packages ({System.IO.Path.Combine(lane, "nuget")}) are mirrored into the private feed before each step; packages built into it win.");
        }

        // The private feed is the only local source: NuGet takes the first source that answers, not the first listed, so the
        // lane feed must not be a second source of the same id and version.
        var sources = string.Join(';', feed, NuGetOrg);
        // Repos with their own <RestoreSources> and lanes whose Octo.User.props sets RestorePackagesPath ignore the
        // environment: global properties win over both.
        properties.Add(KeyValuePair.Create("RestoreSources", sources));
        properties.Add(KeyValuePair.Create("RestorePackagesPath", cache));
        env["NUGET_PACKAGES"] = cache;
        return (properties, env, feed);
    }

    public (string Feed, string Cache) PrivateFeedOf(string owner)
    {
        var folder = System.IO.Path.Combine(paths.StateDirectory, "feeds", PathScope.Slug(owner));
        return (System.IO.Path.Combine(folder, "nuget"), System.IO.Path.Combine(folder, "packages"));
    }

    private static (string Lane, string Branch) Lane(DevStackConfig config, string? checkout)
    {
        var root = ServicePlanner.RootPath(config);
        var lane = ServicePlanner.CreateContext(config, checkout, null).Checkout;
        // '/' on every OS: the cmdlets take both, and plans and messages read the same.
        var branch = System.IO.Path.GetRelativePath(root, lane).Replace('\\', '/');
        if (branch.StartsWith("..", StringComparison.Ordinal))
        {
            throw new ArgumentException($"Base lane {lane} is not below rootPath {root}; the build cmdlets need -branch relative to it.");
        }

        return (lane, branch);
    }

    private async Task<BuildLane?> LaneInfoFromDryRunAsync(string octoTools, string script, Dictionary<string, string?> env, string? lane, string? feed,
        CancellationToken cancellationToken)
    {
        var dry = await RunJsonAsync(octoTools, script, env, cancellationToken);
        if (dry?["data"] is not JsonObject data)
        {
            return lane == null ? null : new BuildLane(lane, null, [], feed);
        }

        var environment = data["environment"] as JsonObject;
        var caches = new List<string>();
        if (env.GetValueOrDefault("NUGET_PACKAGES") is { } own)
        {
            caches.Add(own);
        }
        else if (Str(environment?["NUGET_PACKAGES"]) is { } cache)
        {
            caches.Add(cache);
        }

        return new BuildLane(Str(data["laneRoot"]) ?? lane, Bool(data["isolated"]), caches, feed);
    }

    private async Task<JsonObject?> RunJsonAsync(string octoTools, string script, Dictionary<string, string?>? env, CancellationToken cancellationToken)
    {
        var result = await runner.RunAsync(octoTools, Rooted(script), new PwshRunOptions { Timeout = options.PlanTimeout, Environment = env }, cancellationToken);
        return PwshRunner.ExtractOctoJson(result.Output);
    }

    /// <summary>Get-OctoBuildOrder of a lane as (name, path); empty when octo-tools does not answer.</summary>
    private async Task<List<(string Name, string Path)>> BuildOrderAsync(string octoTools, string lane, CancellationToken cancellationToken)
    {
        var body = $"$__order = @(Get-OctoBuildOrder -branchRootPath {PwshRunner.Quote(lane)} | ForEach-Object {{ [ordered]@{{ name = $_.Name; path = $_.Path }} }})\n" +
                   $"Write-Output ('{PwshRunner.Marker}' + (ConvertTo-Json -InputObject $__order -Compress -Depth 3))";
        var result = await runner.RunAsync(octoTools, Rooted(body), new PwshRunOptions { Timeout = options.PlanTimeout }, cancellationToken);
        try
        {
            return (PwshRunner.ExtractMarker(result.Output) as JsonArray ?? [])
                .OfType<JsonObject>()
                .Select(o => (Str(o["name"]) ?? "", Str(o["path"]) ?? ""))
                .Where(o => o.Item1.Length > 0)
                .ToList();
        }
        catch (System.Text.Json.JsonException)
        {
            return [];
        }
    }

    private BuildPlanRepo ToPlanRepo(PlanRepo repo, string configuration, bool withStale)
    {
        // An environment build with a prediction (AB#8814) says itself what it builds and why; the bin-vs-source check is the older answer.
        if (!withStale || repo.Mode != "dotnet" || repo.Action != null)
        {
            return new BuildPlanRepo(repo.Name, repo.Mode, repo.Path, null, null)
            {
                Action = repo.Action, Reason = repo.Reason, Detail = repo.Detail, DependsOn = repo.DependsOn is { Count: > 0 } ? repo.DependsOn : null,
                Exclusive = repo.Exclusive == true ? true : null
            };
        }

        var stale = StaleCheck.Check(repo.Path, configuration);
        return new BuildPlanRepo(repo.Name, repo.Mode, repo.Path, stale.Stale, stale.Reason);
    }

    // ---------- conflicts and gates ----------

    public async Task<List<BuildConflict>> ConflictsAsync(PlannedBuild planned)
    {
        if (planned.Request.Kind == BuildKind.Test)
        {
            // A test run stops the services of its target stack that run from the tested repository (no flag, no external
            // check) - a lane test also those of the shared stack (a lane's service run there with source lane:<name>, UC-A);
            // services of other lane stacks there get a plan warning.
            var stops = StopSlotsOfTest(planned);
            return planned.TestFolder is { } folder
                ? supervisor.RunningInSlots([folder]).Where(r => stops.Contains(r.Slot.Slot.Name))
                    .Select(r => OwnConflict(r.Slot, r.Instance, folder)).ToList()
                : [];
        }

        var conflicts = new List<BuildConflict>();
        var repos = planned.ConflictPaths.ToList();
        foreach (var (slot, instance) in supervisor.RunningInSlots(repos))
        {
            conflicts.Add(OwnConflict(slot, instance, repos.First(r => PathScope.IsInRepo(instance.Plan.RepoPath, r))));
        }

        var snapshot = await external();
        if (snapshot.Warning is { } unknown)
        {
            var warning = unknown + " The job runs without that check.";
            lock (planned.Warnings)
            {
                if (!planned.Warnings.Contains(warning))
                {
                    planned.Warnings.Add(warning);
                }
            }
        }

        var config = store.Load();
        var planRepos = planned.Steps.SelectMany(s => s.Repos).Where(r => r.Mode != "none").ToList();
        foreach (var service in snapshot.Services)
        {
            string? repoName;
            string startedBy;
            var origin = snapshot.Groups.FirstOrDefault(g => g.Key == service.Group)?.Origin;
            var who = origin?.Description ?? "a process octo-devstack did not start";
            if (service.RepoPath != null)
            {
                var repo = repos.FirstOrDefault(r => PathScope.IsInRepo(service.RepoPath, r));
                if (repo == null)
                {
                    continue;
                }

                repoName = System.IO.Path.GetFileName(repo);
                startedBy = who;
            }
            else
            {
                // Where it runs from is unknown (no working directory from lsof): be conservative and count it when its
                // service's repo is part of the plan.
                var configured = config.Services.GetValueOrDefault(service.Service)?.Repo;
                var match = configured == null ? null : planRepos.FirstOrDefault(r => string.Equals(r.Name, configured, StringComparison.OrdinalIgnoreCase));
                if (match == null)
                {
                    continue;
                }

                repoName = match.Name;
                startedBy = $"{who}; could not determine where pid {service.Pid} runs from";
            }

            var stoppable = origin is { Kind: "start-octo", NonInteractive: true };
            conflicts.Add(new BuildConflict(repoName, service.Service, service.Pid, "external", startedBy, origin?.StopHint, stoppable, origin?.Branch));
        }

        return conflicts;
    }

    private BuildConflict OwnConflict(SlotRun slot, ServiceInstance instance, string repo) =>
        new(System.IO.Path.GetFileName(repo.TrimEnd('/', '\\')), slot.Qualify(instance.Plan.Name), instance.Pid, "own",
            OwnStarter(instance.Origin, slot.StackOwner, slot.Slot.IsDefault ? null : slot.Slot.Name),
            $"service_stop {instance.Plan.Name}{(slot.Slot.IsDefault ? "" : EnvironmentBinding.OfSlot(store.Load(), slot.Slot.Name) is { } env ? $" lane={env.Name}" : $" slot={slot.Slot.Name}")}", true)
        {
            Slot = slot.Slot.Name
        };

    /// <summary>
    ///     Who started an own service, for a conflict: the session that started or overrode that service (its
    ///     <see cref="ServiceOrigin"/>) - in a shared stack often another one than the stack's starter - and with which call,
    ///     e.g. "alice (octo-devstack service_restart, slot second)". Without an origin (not known): the stack's starter.
    /// </summary>
    internal static string OwnStarter(ServiceOrigin? origin, string? stackOwner, string? slot)
    {
        var where = slot == null ? "" : $", slot {slot}";
        return origin != null ? $"{origin.Owner} (octo-devstack {origin.Via}{(origin.Session != null ? $", session {origin.Session}" : "")}{where})" : $"{stackOwner ?? "unknown"} (octo-devstack, the stack's starter{where})";
    }

    /// <summary>The stacks a test run stops its services in: the target stack, and for a lane test the shared stack as well.</summary>
    internal static HashSet<string> StopSlotsOfTest(PlannedBuild planned) =>
        planned.Request.Environment == null ? [planned.TestSlot ?? SlotInfo.DefaultName] : [planned.TestSlot ?? SlotInfo.DefaultName, SlotInfo.DefaultName];

    public BuildGates Gates(PlannedBuild planned, IReadOnlyList<BuildConflict> conflicts)
    {
        var request = planned.Request;
        var own = conflicts.Any(c => c.Kind == "own");
        var foreign = conflicts.Where(c => c.Kind == "external").ToList();
        var ignoring = request.Kind == BuildKind.Repo && request.IgnoreRunningServices;
        // Range and all change the base lane's packages for every session; otherwise only stopping services needs the lease.
        var needsLease = request.Kind is BuildKind.Range or BuildKind.All || (own && !ignoring) || (request.Kind == BuildKind.Profile && request.RestartServices);
        var needsPublish = request.Kind == BuildKind.Range;
        var needsConfirm = request.Kind == BuildKind.All;
        // kind=all and test runs stop their own services without a flag (a test run only those of its target stack).
        var needsStop = own && request.Kind is not (BuildKind.All or BuildKind.Test) && !ignoring;
        var needsStopExternal = request.Kind == BuildKind.All && foreign.Count > 0;

        var unmet = new List<string>();
        var leaseSlots = needsLease ? LeaseSlots(planned, conflicts, own && !ignoring) : [];
        foreach (var slot in leaseSlots)
        {
            var holder = (slot == SlotInfo.DefaultName ? lease : supervisor.Leases.Get(slot)).Snapshot().Holder;
            if (holder == null || !string.Equals(holder.Owner, request.LeaseOwnerFor(slot), StringComparison.OrdinalIgnoreCase))
            {
                var which = slot == SlotInfo.DefaultName ? "the stack lease" : $"the stack lease of slot '{slot}'";
                unmet.Add(holder == null ? $"{which} (free; the build takes it)" : $"{which} (held by {holder.Owner})");
            }
        }

        if (needsPublish && !request.Publish)
        {
            unmet.Add("publish=true (a range build changes the base lane's nuget folder and package caches for every session)");
        }

        if (needsConfirm && !request.Confirm)
        {
            unmet.Add("confirm=true (Invoke-BuildAll resets the base lane's packages and takes 30-90 min)");
        }

        if (needsStop && !request.StopServices)
        {
            unmet.Add($"stopServices=true ({string.Join(", ", conflicts.Where(c => c.Kind == "own").Select(c => c.Service))} run out of the build target)");
        }

        if (foreign.Count > 0)
        {
            var blocking = request.Kind == BuildKind.All && request.StopExternal ? foreign.Where(f => !f.StoppableByDaemon).ToList() : foreign;
            foreach (var f in blocking.GroupBy(f => f.StartedBy))
            {
                var hint = f.First().StopHint;
                unmet.Add($"stop {string.Join(", ", f.Select(x => $"{x.Service} (pid {x.Pid})"))} first - started by {f.Key}, not by octo-devstack" +
                          (hint != null ? $"; stop: {hint}" : "") +
                          (request.Kind == BuildKind.All && f.All(x => x.StoppableByDaemon) ? "; or pass stopExternal=true" : ""));
            }
        }

        return new BuildGates(needsLease, needsPublish, needsConfirm, needsStop, needsStopExternal, unmet) { LeaseSlots = leaseSlots };
    }

    /// <summary>
    ///     The slots whose lease a build needs: range and all the default slot (they change the lane for every session); the
    ///     slots of the own services the build stops; kind=all every slot that runs from the lane.
    /// </summary>
    private List<string> LeaseSlots(PlannedBuild planned, IReadOnlyList<BuildConflict> conflicts, bool stopsOwn)
    {
        var slots = new List<string>();
        var kind = planned.Request.Kind;
        if (kind is BuildKind.Range or BuildKind.All)
        {
            slots.Add(SlotInfo.DefaultName);
        }

        if (stopsOwn || kind == BuildKind.All)
        {
            slots.AddRange(conflicts.Where(c => c.Kind == "own" && c.Slot != null).Select(c => c.Slot!));
        }

        if (kind == BuildKind.All && planned.Lane != null)
        {
            slots.AddRange(supervisor.SlotsInLane(planned.Lane).Select(r => r.Slot.Name));
        }

        if (slots.Count == 0)
        {
            slots.Add(SlotInfo.DefaultName);
        }

        return slots.Distinct().OrderBy(s => s == SlotInfo.DefaultName ? 0 : 1).ThenBy(s => s, StringComparer.Ordinal).ToList();
    }

    internal static string? Str(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.String ? v.GetValue<string>() : null;

    /// <summary>Invoke-BuildAll -DryRun names the builder; the plan and the events use the mode of Invoke-BuildRange.</summary>
    internal static string ModeOfBuilder(string? builder) => builder switch
    {
        null or "Invoke-Build" => "dotnet",
        "build.ps1" => "script",
        "Invoke-Publish" => "frontend",
        "Invoke-BuildZenonPlug" => "zenon",
        "none" => "none",
        _ => builder
    };

    internal static bool? Bool(JsonNode? node) => node is JsonValue v
        ? v.GetValueKind() switch
        {
            System.Text.Json.JsonValueKind.True => true,
            System.Text.Json.JsonValueKind.False => false,
            _ => null
        }
        : null;

    internal static double? Num(JsonNode? node) =>
        node is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.Number ? v.GetValue<double>() : null;

    private static List<string> Strings(JsonNode? node) => node switch
    {
        JsonArray a => a.Select(Str).Where(s => s != null).Select(s => s!).ToList(),
        JsonValue => Str(node) is { } s ? [s] : [],
        _ => []
    };
}

/// <summary>Whether a repo's build output is older than its sources: newest source file vs newest file in bin/&lt;configuration&gt;.</summary>
internal static class StaleCheck
{
    private static readonly HashSet<string> SkipDirectories = new(StringComparer.OrdinalIgnoreCase)
        { "bin", "obj", "node_modules", ".git", ".claude", ".idea", ".vs", ".octo", "dist", "TestResults", "logFiles", ".angular" };

    private static readonly HashSet<string> SourceExtensions = new(StringComparer.OrdinalIgnoreCase)
        { ".cs", ".csproj", ".props", ".targets", ".sln", ".slnx", ".json", ".yaml", ".yml", ".resx", ".razor", ".graphql", ".proto" };

    private const int MaxFiles = 200_000;

    public sealed record Result(bool Stale, string Reason, DateTimeOffset? NewestSource, DateTimeOffset? NewestOutput);

    public static Result Check(string repo, string configuration)
    {
        var output = Path.Combine(repo, "bin", configuration);
        var newestOutput = Newest(output, _ => true, skipDirectories: false);
        if (newestOutput == null)
        {
            return new Result(true, $"not built for {configuration}", null, null);
        }

        var newestSource = Newest(repo, f => SourceExtensions.Contains(Path.GetExtension(f)), skipDirectories: true);
        if (newestSource == null)
        {
            return new Result(false, "no sources found", null, newestOutput);
        }

        return newestSource > newestOutput
            ? new Result(true, $"sources changed {newestSource.Value.ToLocalTime():yyyy-MM-dd HH:mm}, output {newestOutput.Value.ToLocalTime():yyyy-MM-dd HH:mm}", newestSource, newestOutput)
            : new Result(false, $"output {newestOutput.Value.ToLocalTime():yyyy-MM-dd HH:mm} is newer than the sources", newestSource, newestOutput);
    }

    private static DateTimeOffset? Newest(string folder, Func<string, bool> include, bool skipDirectories)
    {
        if (!Directory.Exists(folder))
        {
            return null;
        }

        DateTime? newest = null;
        var count = 0;
        var pending = new Stack<string>();
        pending.Push(folder);
        while (pending.Count > 0 && count < MaxFiles)
        {
            var current = pending.Pop();
            try
            {
                foreach (var file in Directory.EnumerateFiles(current))
                {
                    count++;
                    if (!include(file))
                    {
                        continue;
                    }

                    var written = File.GetLastWriteTimeUtc(file);
                    if (newest == null || written > newest)
                    {
                        newest = written;
                    }
                }

                foreach (var dir in Directory.EnumerateDirectories(current))
                {
                    var name = Path.GetFileName(dir);
                    if (skipDirectories && (SkipDirectories.Contains(name) || File.Exists(Path.Combine(dir, ".git"))))
                    {
                        continue;
                    }

                    pending.Push(dir);
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Unreadable folder: skip it.
            }
        }

        return newest == null ? null : new DateTimeOffset(newest.Value, TimeSpan.Zero);
    }
}
