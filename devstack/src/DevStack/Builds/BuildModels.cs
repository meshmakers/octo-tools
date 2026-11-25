using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     The compact state of a job - a build or a test run (normally below 2 KB). Raw cmdlet JSON and the output tail only with
///     include=["raw"]. Times are local time. lane: the lane the job builds or tests in (its queue class); packages: where the
///     build restores from and publishes to.
///     gone (finished jobs only, AB#8915): why the place the job ran in no longer exists - its lane was removed, its folder
///     was deleted or holds no repository any more; such a job is history, not a current failure.
/// </summary>
public sealed record BuildStatus(
    string Id,
    string Owner,
    string State,
    bool? Success,
    string Kind,
    string Target,
    string Configuration,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [property: JsonPropertyName("packages")]
    BuildLane? Lane,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildQueueInfo? Queue,
    BuildTimes Times,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildProgress? Progress,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildOutcome? Outcome,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildDiagnostics? Diagnostics,
    IReadOnlyList<string> StoppedServices,
    IReadOnlyList<string> Notes,
    BuildLogs Logs,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildRaw? Raw = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [property: JsonPropertyName("lane")]
    string? Env = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildTests? Tests = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildLogText? Live = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Catalogs = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Gone = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildEvidence? Evidence = null)
{
    /// <summary>job_status(waitSeconds): true when the time was up before the job ended, false when it ended; null without a wait.</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? TimedOut { get; init; }

    /// <summary>The states of a job that ended.</summary>
    public static bool IsFinal(string state) => state is "succeeded" or "failed" or "canceled";

    /// <summary>
    ///     The kind as tools show it: repo | range | all | profile (base lane builds), lane (a lane's build), test (a test run).
    ///     Internally and in the job files a lane build is still <see cref="BuildKind.Env"/> ("env").
    /// </summary>
    public static string ShownKind(string kind) => kind == "env" ? "lane" : kind;
}

/// <summary>
///     What a job ran on, so a verify gate can accept the job instead of a second plain build or test run: per repository the
///     job covers (a build's plan repos, a test run's tested repository) its work tree, HEAD and whether the work tree was
///     clean, read with git when the job started and when it ended. unchanged: every repository had the same HEAD and the same
///     changed files (same names, same content) at both points (it compares those two points: a later edit is not covered); an uncommitted
///     edit made before the job is the normal flow and does not count against it (null while the job runs). omitted: how many
///     repositories of a job with more than ten the compact status leaves out because they are fine - unchanged, or while
///     the job runs read at the start (repo=X or include=["raw"] lists them).
/// </summary>
public sealed record BuildEvidence(
    bool? Unchanged,
    IReadOnlyList<BuildRepoEvidence> Repos,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Omitted = null);

/// <summary>
///     One repository of a job's evidence: start and end are its work tree when the job started and when it ended (end is
///     missing while the job runs); clean belongs to each point in time. unchanged: the same HEAD at start and end and the
///     same changed files with the same content (fingerprint), whether clean or not.
/// </summary>
public sealed record BuildRepoEvidence(
    string Repo,
    string Path,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildRepoState? Start,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildRepoState? End)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? Unchanged => End == null ? null : Same(Start, End);

    /// <summary>Both read by git, on the same HEAD, with the same changes: both clean, or the same fingerprint (a dirty state without one is unknown).</summary>
    private static bool Same(BuildRepoState? start, BuildRepoState end) =>
        start is { Head: { } head, Clean: { } startClean, Error: null } && end is { Clean: { } endClean, Error: null } && end.Head == head &&
        (startClean && endClean || !startClean && !endClean && start.Fingerprint != null && start.Fingerprint == end.Fingerprint);
}

/// <summary>
///     A work tree as git saw it: head = the full SHA of HEAD (null without a commit or when git could not tell), branch
///     (null: detached), clean = git status --porcelain lists nothing (untracked files count, ignored ones do not), changes =
///     how many entries it lists, fingerprint = a hash of those entries and of the content of the files they name (only
///     when not clean), error = why git could not tell.
/// </summary>
public sealed record BuildRepoState(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Head,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Branch,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? Clean,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Changes = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Error = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Fingerprint = null);

/// <summary>
///     The tests of a test run (kind test): totals, the test projects (failed ones first) and, while the run waits for the
///     machine-wide docker test lock, who holds it. dockerWarning: a project starts containers and the Docker VM is small
///     while the kind cluster runs in it (AB#8835).
/// </summary>
public sealed record BuildTests(
    int Total,
    int Passed,
    int Failed,
    int Skipped,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? LockWait,
    IReadOnlyList<BuildTestProject> Projects,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? DockerWarning = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildTestDocker? Docker = null);

/// <summary>
///     What the cmdlet's Docker check found before the Docker projects of a test run (octo-tools AB#8835): check
///     ok|warned|refused|unavailable|off, the engine's free memory against the minimum, the biggest containers, the limits
///     put on the test containers and how many containers got them.
/// </summary>
public sealed record BuildTestDocker(
    string Check,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? FreeGiB,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? MinFreeGiB,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? MemoryGiB,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? UsedGiB,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? Cpus,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? Containers,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Limits,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Limited,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? LimitFailed,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Message);

/// <summary>
///     state: pending | running | passed | failed | error | noTests | skipped | notRun. failedTests: at most 20 in the compact
///     status (moreFailed says how many are left out; project=X lists all the cmdlet reported). errors: run-level errors
///     (broken build, crashed test host).
/// </summary>
public sealed record BuildTestProject(
    string Project,
    string State,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Total,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Passed,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Failed,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Skipped,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? Seconds,
    IReadOnlyList<BuildFailedTest> FailedTests,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? MoreFailed = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? Errors = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? BuildReason = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? Docker = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Note = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Runner = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? PassedTests = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    bool? PassedTruncated = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? PassedListed = null,
    // octo-tools AB#9829: the slow test categories the run left out of this project (null when none).
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? ExcludedCategories = null);

/// <summary>name: &lt;class&gt;.&lt;method&gt;; message: the first error message; stackFrame: the first stack line.</summary>
public sealed record BuildFailedTest(
    string Name,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Message,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? StackFrame);

/// <summary>
///     Package isolation of the build (JSON "packages"): path = the folder whose nuget feed and caches the build uses (the base
///     lane or the lane); an isolated folder restores into its own cache; feed = private feed of packages=private.
/// </summary>
public sealed record BuildLane(
    string? Path,
    bool? Isolated,
    IReadOnlyList<string> Caches,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Feed);

/// <summary>waitingFor: why the job has not started (the builds it waits for, by the queue rules).</summary>
public sealed record BuildQueueInfo(
    int Position,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? WaitingFor = null);

public sealed record BuildTimes(
    DateTimeOffset QueuedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DateTimeOffset? StartedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DateTimeOffset? FinishedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? ElapsedSeconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? EtaSeconds);

/// <summary>
///     Where a running (or finished) job is. phase: stopping | build | tests | packages | restarting, for a test run tests |
///     lock (it waits for the machine-wide docker test lock); its rows are the test projects, so a test run has
///     projectIndex / projectCount / projects (rows and current with project) where a build has repoIndex / repoCount / repos
///     (rows and current with repo). An environment build may build independent repos at the same time (maxParallel): running
///     lists every repo that builds now with its seconds and phase, current is the first of them, repoIndex counts the repos
///     started or skipped so far. source: events (the cmdlet's -EventsFile) or logs (polling each repo's Invoke-Build.log,
///     older octo-tools).
/// </summary>
public sealed record BuildProgress(
    string Phase,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? RepoIndex,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? RepoCount,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildCurrentRepo? Current,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<BuildRepoProgress>? Repos,
    string Source,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    BuildPhaseSeconds? Totals = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<BuildCurrentRepo>? Running = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? MaxParallel = null)
{
    /// <summary>A test run: how many test projects started or ended so far (a build: <see cref="RepoIndex"/>).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? ProjectIndex { get; init; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? ProjectCount { get; init; }

    /// <summary>A test run: the rows of its test projects (a build: <see cref="Repos"/>).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<BuildRepoProgress>? Projects { get; init; }

    /// <summary>The rows whatever they are (repos of a build, test projects of a test run).</summary>
    [JsonIgnore]
    public IReadOnlyList<BuildRepoProgress> Rows => Repos ?? Projects ?? [];
}

/// <summary>Seconds per phase, summed over the repos that reported them (build includes restore).</summary>
public sealed record BuildPhaseSeconds(
    double Build,
    double Tests,
    double Packages,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Slowest);

/// <summary>The repo that builds now (repo), or the test project that runs now (project).</summary>
public sealed record BuildCurrentRepo(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Repo,
    double Seconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Phase = null)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [JsonPropertyOrder(-1)]
    public string? Project { get; init; }

    /// <summary>What the repo's build (the test project) usually takes: the median of its last durations in every lane (job_stats).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? TypicalSeconds { get; init; }

    /// <summary>Beyond this many seconds it is overdue (twice p90, at least median + 120 s; absent below three durations).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? LimitSeconds { get; init; }

    /// <summary>true once seconds passed limitSeconds: it runs far longer than usual and probably hangs (absent otherwise).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? Overdue { get; init; }
}

/// <summary>
///     state: pending | building | done | failed | skipped. seconds = the repo's whole time; build/test/packageSeconds its
///     phases (from the cmdlet's repoDone event); phase = where a building repo is (restore | build | tests | packages | purge).
///     reason (environment builds): why a repo was skipped (unchanged, notSelected, excluded, nothingToBuild) or built
///     (sourcesChanged, packagesChanged, neverBuilt, ...). tests (a built repo of a build): notCompiled | compiled - a build
///     never runs a test, lane_test / base_test do. catalog/restore/compileSeconds are parts of buildSeconds (the read of the remote CK
///     catalogs on the repo that triggered it, dotnet restore, the compile), testRestoreSeconds a part of testSeconds
///     (octo-tools AB#8831; absent with an older octo-tools). A row of a test run names its test project (project, no repo).
/// </summary>
public sealed record BuildRepoProgress(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Repo,
    string State,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? BuildSeconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? TestSeconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Copied,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Purged,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? Seconds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? PackageSeconds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Phase = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Reason = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Tests = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? CatalogSeconds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? RestoreSeconds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? CompileSeconds = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? TestRestoreSeconds = null)
{
    /// <summary>A test run's row: the test project (then <see cref="Repo"/> is null).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    [JsonPropertyOrder(-1)]
    public string? Project { get; init; }

    /// <summary>The repo or the test project.</summary>
    [JsonIgnore]
    public string Name => Repo ?? Project ?? "";
}

public sealed record BuildOutcome(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? FailedRepo,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? FailedStep,
    string Summary,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Hint)
{
    /// <summary>Every repo that failed when a parallel build had more than one (failedRepo is the first).</summary>
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyList<string>? FailedRepos { get; init; }
}

public sealed record BuildDiagnostics(int ErrorCount, int WarningCount, IReadOnlyList<BuildError> Errors);

public sealed record BuildError(
    string Repo,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? File,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Line,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Col,
    string Code,
    string Message,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Project);

/// <summary>job = the daemon's log of the run; perRepo = the repos' Invoke-Build.log (failed ones copied into the state folder).</summary>
public sealed record BuildLogs(
    string Job,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyDictionary<string, string>? PerRepo);

public sealed record BuildRaw(IReadOnlyList<JsonObject> Results, string? OutputTail);

/// <summary>
///     The output of a build for the status page: every repo with its state, phase seconds and the errors of its log
///     (repos with errors first), and one text - the log of <c>Selected</c> (a repo) or, without one, the job's own log.
///     Kept in the state folder, so it is there after the build ended and after a daemon restart. URI credentials are masked.
/// </summary>
public sealed record BuildOutput(string Id, string State, IReadOnlyList<BuildRepoOutput> Repos, BuildLogText Log);

public sealed record BuildRepoOutput(
    string Repo,
    string State,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Phase,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? Seconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? BuildSeconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? TestSeconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? PackageSeconds,
    int ErrorCount,
    int WarningCount,
    IReadOnlyList<BuildError> Errors,
    bool HasLog);

/// <summary>
///     selected: the repo (or test project) the text belongs to (null: the job log). source: kept (state folder) | live (the
///     repo's Invoke-Build.log or the test project's log, still being written) | job | none.
/// </summary>
public sealed record BuildLogText(
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Selected,
    string Source,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Path,
    IReadOnlyList<string> Lines,
    bool Truncated);
