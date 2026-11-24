using System.ComponentModel;
using Meshmakers.Octo.DevStack.Builds;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>Jobs of the build queue: builds of the base lane and of lanes through the octo-tools cmdlets, and the job tools.</summary>
[McpServerToolType]
public sealed class BuildTools(BuildQueue queue)
{
    private const string KindDescription =
        "'repo' (Invoke-Build of one folder: a repo of the base lane or a worktree, whole solution incl. tests), 'range' (Invoke-BuildRange over " +
        "a slice of the base lane's build order; refreshes the base lane's 999.0.0 packages for every session - library changes), 'all' " +
        "(Invoke-BuildAll: full reset of the base lane, 30-90 min) or 'profile' (the stale repos and worktrees of a profile's services, one " +
        "Invoke-Build each).";

    private const string PathDescription =
        "kind=repo: folder to build - repo name in the base lane ('octo-mesh-adapter'), worktree ('wt-8625-octo-mesh-adapter') or absolute path.";

    private const string BaseLaneDescription =
        "The base lane folder, relative to rootPath (default: the configured base lane, e.g. 'branches/main').";

    private const string ReposDescription =
        "Build only these repos of the lane (exact name or without 'octo-'); the others are skipped as notSelected. " +
        "Default: every repo that changed since its last build.";

    private const string SkipDescription = "Repos of the lane to leave out (exact name or without 'octo-'); an unknown name is refused.";

    private const string RefreshCatalogsDescription =
        "Every CK compile of the build reads the remote CK catalogs again (-refreshCatalogs). Default: they are read at most once per run " +
        "(job_status 'catalogs' says how); only for a model published elsewhere minutes ago. Needs octo-tools AB#8831.";

    private const string BuildUnchangedDescription =
        "Build also the repos that did not change since their last build (by default they are skipped as unchanged).";

    private const string VerifyTestsDescription =
        "Also COMPILE the test projects. It runs no test - a green build with verifyTests says the tests compile, nothing more; " +
        "run them with lane_test / base_test.";

    private const string IncludeTestsDescription =
        "Build the test projects as part of the build (instead of only compiling them with verifyTests). It runs no test either.";

    private const string MaxParallelDescription =
        "How many independent repos of the lane build at the same time (1-16; default: the cmdlet's, 2; 1 = one after the other).";

    private const string LaneDescription =
        "Lane (lane_list): the build works in <rootPath>/wt-<lane> (repo paths resolve there, packages stay in its own feed); the lane " +
        "holds the leases its services need, owner is recorded.";

    private const string StopServicesDescription =
        "Stop octo-devstack's services that run out of the build target first (needs the stack's lease; a lane's: any session of the lane).";

    private const string RestartServicesDescription =
        "Start the services the build stopped again after a successful build (a canceled build restarts them always).";

    [McpServerTool(Name = "build_plan", ReadOnly = true)]
    [Description("Shows what a base_build or lane_build would do, without queueing it: the build order with the mode per repo " +
                 "(dotnet/script/frontend/zenon/none), for a lane the predicted action per repo (build | skip) with its reason (unchanged, " +
                 "notSelected, excluded, sourcesChanged, packagesChanged, upstreamBuilt, librariesBuilt, neverBuilt, ...) and detail, stale " +
                 "flags (newest source vs bin/<configuration>), conflicts with running services (own and external, with who started them and " +
                 "how to stop them), warnings and the gates it needs (lease, publish, confirm, stopServices, stopExternal; 'unmet' lists what " +
                 "the given arguments still lack). Runs the cmdlets' -WhatIf/-DryRun. Read-only, no lease.")]
    public Task<BuildPlanResult> Plan(
        [Description("A base lane build: " + KindDescription + " Or 'lane' (lane_build). Default: 'lane' when lane is given, else 'repo'.")]
        string? kind = null,
        [Description("The calling owner (to check the lease gate); optional.")] string? owner = null,
        [Description(LaneDescription + " Plans a lane_build.")] string? lane = null,
        [Description(PathDescription)] string? path = null,
        [Description(BaseLaneDescription)] string? baseLane = null,
        [Description("kind=range: first repo of the slice.")] string? from = null,
        [Description("kind=range: last repo of the slice (default: from).")] string? to = null,
        [Description("kind=range: repos to add from outside the slice.")] List<string>? include = null,
        [Description("kind=range: repos to leave out.")] List<string>? exclude = null,
        [Description("kind=profile: the profile whose services' repos are built.")] string? profile = null,
        [Description("Build configuration (default: the profile's or the config default, usually DebugL).")] string? configuration = null,
        [Description("'lane' (default: the base lane's feed), 'private' (deprecated: per-session feed and cache - use a lane) or 'publish' (range into the base lane's nuget).")]
        string packages = "lane",
        [Description("kind=range: build repos from other folders (worktrees), keyed by repo name.")] Dictionary<string, string>? repoPaths = null,
        [Description("kind=profile: false builds every repo of the profile, not only the stale ones.")] bool onlyStale = true,
        [Description(VerifyTestsDescription + " Default: true for a lane (as lane_build), else false.")] bool? verifyTests = null,
        [Description(IncludeTestsDescription)] bool includeTests = false,
        [Description("Gate check: you would pass stopServices=true.")] bool stopServices = false,
        [Description("Gate check: you would pass publish=true.")] bool publish = false,
        [Description("Gate check: you would pass confirm=true.")] bool confirm = false,
        [Description("Gate check: you would pass stopExternal=true.")] bool stopExternal = false,
        [Description("Lane: refresh the lane's snapshot of the base lane's packages and catalogs first.")] bool syncMain = false,
        [Description(ReposDescription)] List<string>? repos = null,
        [Description(SkipDescription)] List<string>? skip = null,
        [Description(BuildUnchangedDescription)] bool buildUnchanged = false,
        [Description(MaxParallelDescription)] int? maxParallel = null,
        [Description(RefreshCatalogsDescription)] bool refreshCatalogs = false,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            var forLane = !string.IsNullOrWhiteSpace(lane);
            var request = Request(owner ?? "build_plan", ParseKind(kind ?? (forLane ? "lane" : "repo"), allowLane: true), path, baseLane, from, to, include, exclude, profile,
                configuration, packages, repoPaths, onlyStale, verifyTests ?? forLane, includeTests, stopServices, false, false, publish, confirm, stopExternal, lane,
                syncMain) with
            {
                Repos = repos ?? [], Skip = skip ?? [], BuildUnchanged = buildUnchanged, MaxParallel = maxParallel, RefreshCatalogs = refreshCatalogs
            };
            return await queue.PlanAsync(request, cancellationToken);
        });

    [McpServerTool(Name = "base_build")]
    [Description("Builds in the base lane (the checkout every lane starts from and every service of a repo a lane does not hold runs from) " +
                 "as a queued job; returns the job at once - wait with job_status(id, waitSeconds). kind=repo builds one folder (a repo or a " +
                 "worktree; no lease); kind=range rebuilds a slice of the build order and changes the base lane's 999.0.0 packages for EVERY " +
                 "session: it needs the shared stack's lease and publish=true - only with the developer's go (a lane builds its library changes " +
                 "into its own feed with lane_build instead); kind=all (Invoke-BuildAll, 30-90 min, resets the base lane's packages) needs the " +
                 "lease (and the lane claim) and confirm=true - only when the developer asks for it - stops octo-devstack's services of the " +
                 "base lane first and refuses while processes octo-devstack did not start run there (stopExternal=true stops non-interactive " +
                 "Start-Octo stacks with Stop-Octo); kind=profile builds the stale repos of a profile's services. A build whose target holds " +
                 "octo-devstack's running services needs stopServices=true and the lease (restartServices=true starts them again). Base lane " +
                 "builds run one at a time (they share the base lane's nuget folder and package caches) - except kind=repo of a plain git " +
                 "worktree (a folder with a .git file that is no repo folder of the base lane or of a lane, built with Invoke-Build): it never " +
                 "writes the base lane's feed, so such builds run next to each other (one per worktree, at most 2) and next to lane builds. " +
                 "kind=repo of a worktree below <repo>/.claude/worktrees/ is refused (its Directory.Build.props imports the main checkout's: " +
                 "NU5118) - move it into a lane with lane_add_repo(path) and build it with lane_build. Range, all and profile refuse a base " +
                 "lane that holds no repository (no folder named octo-* or mm-*). Check build_plan first. dryRun=true returns the plan and " +
                 "queues nothing.")]
    public Task<object> BaseBuild(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(KindDescription)] string kind = "repo",
        [Description(PathDescription)] string? path = null,
        [Description(BaseLaneDescription)] string? baseLane = null,
        [Description("kind=range: first repo of the slice, e.g. 'octo-construction-kit-engine'.")] string? from = null,
        [Description("kind=range: last repo of the slice (default: from).")] string? to = null,
        [Description("kind=range: repos to add from outside the slice.")] List<string>? include = null,
        [Description("kind=range: repos to leave out.")] List<string>? exclude = null,
        [Description("kind=profile: the profile whose services' repos are built.")] string? profile = null,
        [Description("Build configuration (default: the profile's or the config default, usually DebugL).")] string? configuration = null,
        [Description("'lane' (default: the base lane's feed), 'private' (deprecated - use a lane: range into a feed of this owner; repo/profile " +
                     "builds restore from it) or 'publish' (range into the base lane's nuget).")]
        string packages = "lane",
        [Description("kind=range: build repos from other folders (worktrees), keyed by repo name; needs a newer octo-tools.")] Dictionary<string, string>? repoPaths = null,
        [Description("kind=profile: false builds every repo of the profile, not only the stale ones.")] bool onlyStale = true,
        [Description(VerifyTestsDescription)] bool verifyTests = false,
        [Description(IncludeTestsDescription)] bool includeTests = false,
        [Description(StopServicesDescription)] bool stopServices = false,
        [Description(RestartServicesDescription)] bool restartServices = false,
        [Description("kind=repo: build although octo-devstack's own services run out of the target (their binaries get replaced under them).")]
        bool ignoreRunningServices = false,
        [Description("kind=range: required - confirms that the base lane's nuget folder and package caches change for every session (the developer's go).")]
        bool publish = false,
        [Description("kind=all: required - confirms the full reset of the base lane's packages (only when the developer asks for it).")] bool confirm = false,
        [Description("kind=all: stop non-interactive Start-Octo stacks in the base lane with Stop-Octo (other external processes still refuse).")]
        bool stopExternal = false,
        [Description(RefreshCatalogsDescription)] bool refreshCatalogs = false,
        [Description("Return the plan and queue nothing.")] bool dryRun = false,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, null);
            var request = Request(owner, ParseKind(kind, allowLane: false), path, baseLane, from, to, include, exclude, profile, configuration, packages, repoPaths,
                onlyStale, verifyTests, includeTests, stopServices, restartServices, ignoreRunningServices, publish, confirm, stopExternal, null, false) with
            {
                RefreshCatalogs = refreshCatalogs
            };
            return dryRun ? (object)await queue.PlanAsync(request, cancellationToken) : await queue.EnqueueAsync(request, cancellationToken);
        });

    [McpServerTool(Name = "lane_build")]
    [Description("Builds a lane (octo-tools Invoke-BuildEnvironment) into its own feed as a queued job: its feature repos and the consumer " +
                 "repos rebuilt against them, with the test projects compiled (verifyTests=true by default; no test runs - lane_test runs " +
                 "them). Only the repos that changed since their last build are built (job_status shows the others as skipped with the " +
                 "reason; notes starting with 'stale:' name what a skipped repo may leave outdated); repos / skip narrow it, buildUnchanged=true " +
                 "builds everything. Returns the job at once - wait with job_status(id, waitSeconds). Lane builds run next to each other (one " +
                 "per lane, at most 2) and need no developer's go; nothing changes for the base lane or other lanes. When services of the " +
                 "lane's stack run from a repo it builds, pass stopServices=true (restartServices=true starts them again). syncMain=true first " +
                 "refreshes the lane's snapshot of the base lane's packages (refused while a range/all build of the base lane runs or waits). " +
                 "dryRun=true returns the plan (as build_plan) and queues nothing.")]
    public Task<object> LaneBuild(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(LaneDescription)] string lane,
        [Description(ReposDescription)] List<string>? repos = null,
        [Description(SkipDescription)] List<string>? skip = null,
        [Description(VerifyTestsDescription + " Default true.")] bool verifyTests = true,
        [Description("Refresh the lane's snapshot of the base lane's packages and catalogs first (refused while a range/all build of the base lane runs or waits).")]
        bool syncMain = false,
        [Description(StopServicesDescription)] bool stopServices = false,
        [Description(RestartServicesDescription)] bool restartServices = false,
        [Description(BuildUnchangedDescription)] bool buildUnchanged = false,
        [Description(IncludeTestsDescription)] bool includeTests = false,
        [Description(MaxParallelDescription)] int? maxParallel = null,
        [Description(RefreshCatalogsDescription)] bool refreshCatalogs = false,
        [Description("Return the plan and queue nothing.")] bool dryRun = false,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            var request = Request(owner, BuildKind.Env, null, null, null, null, null, null, null, null, "lane", null, true, verifyTests, includeTests, stopServices,
                restartServices, false, false, false, false, lane, syncMain) with
            {
                Repos = repos ?? [], Skip = skip ?? [], BuildUnchanged = buildUnchanged, MaxParallel = maxParallel, RefreshCatalogs = refreshCatalogs
            };
            return dryRun ? (object)await queue.PlanAsync(request, cancellationToken) : await queue.EnqueueAsync(request, cancellationToken);
        });

    [McpServerTool(Name = "job_status", ReadOnly = true)]
    [Description("Shows a job - a build (base_build, lane_build) or a test run (base_test, lane_test) - in a compact shape (normally < 2 KB); " +
                 "waitSeconds=N waits until the job ends or N seconds passed (max 900) and then answers, with timedOut saying which " +
                 "happened - wait this way instead of polling. state queued|running|succeeded|failed|canceled, success, kind " +
                 "repo|range|all|profile|lane|test, lane, queue position and what a queued job waits for, times (local) with elapsedSeconds " +
                 "and etaSeconds, progress (phase stopping|catalogs|build|tests|packages|restarting, or lock while a test run waits for the " +
                 "docker test lock; repoIndex/repoCount, repos and current.repo for a build - a test run counts and lists its test projects " +
                 "instead: projectIndex/projectCount, projects, current.project; running - every repo that builds now when a lane build runs several at once, " +
                 "maxParallel - per repo its state (a repo a lane build did not build is skipped, with reason unchanged | notSelected | " +
                 "excluded | nothingToBuild) and seconds / buildSeconds / testSeconds / packageSeconds, with octo-tools AB#8831 also " +
                 "catalogSeconds, restoreSeconds, compileSeconds and testRestoreSeconds - totals per phase and the slowest repo), catalogs " +
                 "(how the remote CK catalogs were read), outcome (failedRepo, failedStep, summary, hint), diagnostics (error/warning counts " +
                 "and up to 20 parsed errors per repo: file, line, col, code, message, project), stopped services, notes and log paths. " +
                 "repo=X returns up to 100 errors of that repo. A BUILD NEVER RUNS TESTS: per built repo 'tests' says notCompiled or compiled. " +
                 "A test run has 'tests': total/passed/failed/skipped, lockWait (who holds the docker test lock), and per test project (failed " +
                 "ones first) its state (pending|running|passed|failed|error|noTests|noMatch|skipped|notRun; noMatch = the filter matched " +
                 "nothing there, a success; noTests = no test ran without a filter, a failure), runner (vstest|mtp|ng), counts, seconds, " +
                 "buildReason (why the run compiled the project first), and the failed tests by full name with the first error message and stack frame (20 per project; project=X " +
                 "lists all, moreFailed counts the rest), run-level errors; passedListed / includePassed=true for a run started with " +
                 "includePassed; tests.docker (the cmdlet's Docker check) and tests.dockerWarning (the daemon's look at the Docker VM). " +
                 "live=N adds the last N lines of the output (field 'live') of the repo or test project that runs now, or of repo/project=X " +
                 "(also afterwards). Jobs survive a daemon restart: a running one goes on and is re-attached (a note says so), a queued one " +
                 "keeps its place, finished ones stay answerable (the last 50, 14 days). evidence: what the job ran on - per repository it covers " +
                 "(a build's plan repos, a test run's tested repository) its path and, at the start and at the end of the job, head (full SHA), " +
                 "branch, clean at that point in time (git status: untracked files count, ignored ones do not; changes counts the entries) and " +
                 "fingerprint (the changed files' names and content); unchanged = the same head and the same changed files at start and end - " +
                 "per repository, and for the whole job once it ended (a comparison of those two points: an edit after the end is not covered; an uncommitted edit " +
                 "made before the job is fine; one made while it ran is not). A job with more than ten repositories lists only those that are " +
                 "not fine (omitted counts the rest; repo=X or include=['raw'] shows them). Read-only.")]
    public Task<BuildStatus> Status(
        [Description("Job id from base_build, lane_build, base_test or lane_test.")] string id,
        [Description("Seconds to wait for the job to end before answering (0-900, default 0 = answer at once).")] int waitSeconds = 0,
        [Description("A build: only this repo - its progress row and up to 100 of its errors.")] string? repo = null,
        [Description("A test run: only this test project, with all its failed tests.")] string? project = null,
        [Description("Only state, outcome and diagnostics.")] bool errorsOnly = false,
        [Description("'raw' adds the cmdlets' -Json documents and the output tail.")] List<string>? include = null,
        [Description("With include=['raw']: number of output lines (default 40).")] int tailLines = 40,
        [Description("Add the last N lines (max 200) of the output: of the repo or test project that runs now, or of repo/project=X.")] int live = 0,
        [Description("A test run started with includePassed: return the names of the passed tests (passedTests per project); combine with project=X.")]
        bool includePassed = false,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            if (repo != null && project != null)
            {
                throw new ArgumentException("Pass repo (a build's repo) or project (a test run's project), not both.");
            }

            return await WaitAsync(queue, id, waitSeconds, () => queue.Get(id, repo ?? project, errorsOnly,
                include?.Contains("raw", StringComparer.OrdinalIgnoreCase) == true, Math.Clamp(tailLines, 0, 2000), live, includePassed), cancellationToken);
        });

    /// <summary>
    ///     job_status(waitSeconds): waits until the job ends or the time is up, then the normal answer; timedOut says which (null
    ///     without a wait). Polls the job state once a second.
    /// </summary>
    internal static async Task<BuildStatus> WaitAsync(BuildQueue queue, string id, int waitSeconds, Func<BuildStatus> answer, CancellationToken cancellationToken,
        TimeSpan? pollInterval = null)
    {
        var wait = TimeSpan.FromSeconds(Math.Clamp(waitSeconds, 0, 900));
        if (wait == TimeSpan.Zero)
        {
            return answer();
        }

        var waited = System.Diagnostics.Stopwatch.StartNew(); // monotonic: a clock set back must not stretch the wait
        var poll = pollInterval ?? TimeSpan.FromSeconds(1);
        while (!BuildStatus.IsFinal(queue.Get(id, errorsOnly: true).State))
        {
            var left = wait - waited.Elapsed;
            if (left <= TimeSpan.Zero)
            {
                return answer() with { TimedOut = true };
            }

            await Task.Delay(left < poll ? left : poll, cancellationToken);
        }

        return answer() with { TimedOut = false };
    }

    [McpServerTool(Name = "job_list", ReadOnly = true)]
    [Description("Lists all jobs - builds and test runs - the daemon knows, newest first, in the compact job_status shape: this run's and those " +
                 "of earlier daemon runs (the last 50 finished ones, 14 days; a job that ran across a restart is 'running' with a note). A " +
                 "finished job whose lane or base lane folder no longer exists carries 'gone' with the reason: history, not a current failure " +
                 "(the status page hides it by default). Read-only.")]
    public List<BuildStatus> List() => queue.List();

    [McpServerTool(Name = "job_cancel", Destructive = true)]
    [Description("Cancels your own queued or running job (build or test run) - also one that was re-attached after a daemon restart: the process " +
                 "tree the daemon started is terminated (its pid is verified first) and services the build stopped are started again. Any " +
                 "session of a lane may cancel the lane's jobs (pass lane). A canceled range/all build may leave the base lane's nuget folder " +
                 "partially updated.")]
    public BuildStatus Cancel(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description("Job id.")] string id,
        [Description("The lane of the job: any session of it may cancel the lane's jobs.")] string? lane = null,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(() =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return queue.Cancel(id, owner, lane);
        });

    private static BuildKind ParseKind(string kind, bool allowLane) => kind.ToLowerInvariant() switch
    {
        "repo" => BuildKind.Repo,
        "range" => BuildKind.Range,
        "all" => BuildKind.All,
        "profile" => BuildKind.Profile,
        "lane" when allowLane => BuildKind.Env,
        "lane" or "env" => throw new ArgumentException("A lane builds with lane_build(owner, lane, ...), not with base_build."),
        "test" => throw new ArgumentException("Tests run with base_test / lane_test (repo, project, filter, rerunFailed), not as a build."),
        _ => throw new ArgumentException($"kind must be 'repo', 'range', 'all' or 'profile'{(allowLane ? " or 'lane'" : "")}, not '{kind}'.")
    };

    private static BuildRequest Request(string owner, BuildKind kind, string? path, string? checkout, string? from, string? to, List<string>? include,
        List<string>? exclude, string? profile, string? configuration, string packages, Dictionary<string, string>? repoPaths, bool onlyStale,
        bool verifyTests, bool includeTests, bool stopServices, bool restartServices, bool ignoreRunningServices, bool publish, bool confirm,
        bool stopExternal, string? lane, bool syncMain) =>
        new()
        {
            Owner = owner,
            Environment = string.IsNullOrWhiteSpace(lane) ? null : lane.Trim(),
            SyncMain = syncMain,
            Kind = kind,
            Path = path,
            Checkout = checkout,
            From = from,
            To = to,
            Include = include ?? [],
            Exclude = exclude ?? [],
            Profile = profile,
            Configuration = configuration,
            Packages = packages.ToLowerInvariant() switch
            {
                "lane" => PackageMode.Lane,
                "private" => PackageMode.Private,
                "publish" => PackageMode.Publish,
                _ => throw new ArgumentException($"packages must be 'lane', 'private' or 'publish', not '{packages}'.")
            },
            RepoPaths = repoPaths ?? new Dictionary<string, string>(),
            OnlyStale = onlyStale,
            VerifyTests = verifyTests,
            IncludeTests = includeTests,
            StopServices = stopServices,
            RestartServices = restartServices,
            IgnoreRunningServices = ignoreRunningServices,
            Publish = publish,
            Confirm = confirm,
            StopExternal = stopExternal
        };
}
