using System.ComponentModel;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Builds;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>Test runs through octo-tools' Invoke-OctoTestRun, as jobs of the build queue.</summary>
[McpServerToolType]
public sealed class TestTools(BuildQueue queue)
{
    private const string RunDetails =
        "All test projects of the repository or the ones in 'project', optionally with a 'filter', or only the tests that failed last time " +
        "(rerunFailed=true). Slow tests (octo-tools AB#9829): a run without filter and rerunFailed leaves out the tests with trait " +
        "Category=Performance or Category=Stress, as CI does (they run in the performance pipelines) - includeSlow=true runs them too; a " +
        "filter or rerunFailed runs what it names. Frontend tests too: an Angular workspace of the repository with a 'test' script is a test project named after " +
        "its folder; it runs ng test headless, 'filter' is then a regular expression over suite and test names, and a failed test is named " +
        "'<spec file> :: <test name>'. Returns a job at once - wait with job_status(id, waitSeconds); job_status lists the failed tests by " +
        "name. No full rebuild: a project whose build is current runs with --no-build, otherwise dotnet test builds it incrementally " +
        "(buildReason says which and why). The run is a job of the build queue. Services of its target stack that run from the tested " +
        "repository are stopped before the run and started again afterwards with their source, also after a failed or canceled run - " +
        "Invoke-OctoTestRun rebuilds the project of a running service, which fails with MSB3027 on Windows; the queued answer lists them in " +
        "stoppedServices, and while the run goes on no service starts from the repository. A lane test also stops the shared stack's services " +
        "that run the lane's repository (source 'lane:<name>', UC-A) with the caller's lease of the shared stack, taken when free; when another " +
        "session holds it the run is refused before a job exists, naming the services, the holder and the way out. Services of other lane " +
        "stacks that run from it are only named in a note. job_status 'evidence' records the repository's head and whether its work tree was clean at the start and the end. " +
        "Projects that start containers (Testcontainers) run one at a time on this machine: the run waits for the docker test lock and " +
        "job_status says who holds it (test_lock). Before them the cmdlet compares the Docker engine's free memory with a minimum and " +
        "refuses by default (failedStep docker, those projects notRun), and it limits the CPUs of the containers the tests start; " +
        "dockerCheck, minDockerFreeMemoryGiB, dockerCpus and dockerMemory change that. When the Docker VM is below the configured dockerVm " +
        "limits while the kind cluster runs in it, the answer carries a note. Runners: a project runs with VSTest, Microsoft.Testing.Platform " +
        "(mtp: TUnit, xunit.v3) or ng; 'filter' is passed as given, in the form of that runner and never translated - a project whose runner " +
        "cannot take the given form is not started (state noMatch, its note names the form it takes). With a filter a project in which " +
        "nothing matched is noMatch (a success); the run fails only when nothing matched anywhere. Without a filter a project that runs no " +
        "test is noTests and fails the run. Asking for the same run again while it waits or runs adds nothing: the existing job comes back " +
        "with a note. Cancel with job_cancel; it survives a daemon restart. Needs an octo-tools checkout with Invoke-OctoTestRun (AB#8813).";

    private const string RepoDescription = "The repository whose tests run: folder name ('octo-construction-kit-engine') or the name without 'octo-'. (A unique part of the name reaches the cmdlet too, but then the run stops no service running from it and its evidence names no repository.)";

    private const string ProjectDescription = "Test projects: csproj name, path relative to the repo, or a unique part of the name. Default: all test projects.";

    private const string FilterDescription =
        "Test filter in the language of the project's runner: VSTest (and MSTest/NUnit) an expression such as 'FullyQualifiedName~RtEntityTests' " +
        "or 'Category!=Slow'; TUnit and xunit.v3 on Microsoft.Testing.Platform a tree filter such as '/*/*/RtEntityTests/*' (starts with '/').";

    private const string IncludeSlowDescription =
        "Also run the slow tests (trait Category=Performance or Category=Stress: wall-clock budget and memory-pressure tests, e.g. " +
        "DownsamplingManyIdsPerformanceTests, about 17 min) that a run without filter and rerunFailed leaves out by default. Needs octo-tools AB#9829.";

    private const string RerunFailedDescription =
        "Run only the tests that failed in the last result of each selected project (projects without failed tests are skipped).";

    [McpServerTool(Name = "lane_test")]
    [Description("Runs the tests of one repository of a lane (its worktree, with the lane's feed and cache) with Invoke-OctoTestRun as a queued " +
                 "job - after lane_build. It waits for a build or test run of the same lane; next to the running build of its lane a test run " +
                 "starts as soon as that build is through with the repository and what it depends on, if the run builds nothing itself (every " +
                 "project noBuild; it then runs with -build Never and says so in a note) - otherwise queue.waitingFor names the project that " +
                 "would build and why (lane_build verifyTests=true compiles test projects). Its target stack is the lane stack, whose lease " +
                 "the lane holds - plus the shared stack's services that run the lane's repository. " + RunDetails)]
    public Task<BuildStatus> LaneTest(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description("Lane (lane_list): its worktree of the repo is tested, with the lane's feed and cache.")] string lane,
        [Description(RepoDescription)] string repo,
        [Description(ProjectDescription)] List<string>? project = null,
        [Description(FilterDescription)] string? filter = null,
        [Description(RerunFailedDescription)] bool rerunFailed = false,
        [Description("Build configuration (default: the config default, usually DebugL).")] string? configuration = null,
        [Description("Keep the names of the passed tests too (job_status includePassed=true shows them). Needs octo-tools AB#8832.")] bool includePassed = false,
        [Description("With includePassed: at most this many names per project (default 200, max 2000).")] int? maxPassed = null,
        [Description("refuse (the cmdlet's default) | warn | off: what a run with projects that start containers does when the Docker engine has less " +
                     "free memory than minDockerFreeMemoryGiB. Needs octo-tools AB#8835.")]
        string? dockerCheck = null,
        [Description("Free memory the Docker engine must have before Docker projects start (cmdlet default 3).")] double? minDockerFreeMemoryGiB = null,
        [Description("CPU limit for every container the tests start (cmdlet default 4).")] double? dockerCpus = null,
        [Description(DockerMemoryDescription)] string? dockerMemory = null,
        [Description(StackTools.SessionDescription)] string? session = null,
        [Description(IncludeSlowDescription)] bool includeSlow = false,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return await queue.EnqueueAsync(Request(owner, repo, string.IsNullOrWhiteSpace(lane) ? throw new ArgumentException("lane is required (lane_list).") : lane.Trim(),
                null, project, filter, rerunFailed, includeSlow, configuration, includePassed, maxPassed, dockerCheck, minDockerFreeMemoryGiB, dockerCpus, dockerMemory), cancellationToken);
        });

    [McpServerTool(Name = "base_test")]
    [Description("Runs the tests of one repository of the base lane (or of another base lane folder) with Invoke-OctoTestRun as a queued job. " +
                 "A folder that holds no repository (no folder named octo-* or mm-*, e.g. a removed worktree or the worktree of a single repo) is " +
                 "refused before a job is created; a lane's worktree is tested with lane_test. It waits for a build or test run of the same base " +
                 "lane and for an exclusive base lane build. Its target stack is the shared stack: stopping its services needs the shared " +
                 "stack's lease, taken when it is free; when another session holds it the run is refused before it is queued, naming the " +
                 "services and the holder. " + RunDetails)]
    public Task<BuildStatus> BaseTest(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(RepoDescription)] string repo,
        [Description("The base lane folder, relative to rootPath (default: the configured base lane, e.g. 'branches/main').")] string? baseLane = null,
        [Description(ProjectDescription)] List<string>? project = null,
        [Description(FilterDescription)] string? filter = null,
        [Description(RerunFailedDescription)] bool rerunFailed = false,
        [Description("Build configuration (default: the config default, usually DebugL).")] string? configuration = null,
        [Description("Keep the names of the passed tests too (job_status includePassed=true shows them). Needs octo-tools AB#8832.")] bool includePassed = false,
        [Description("With includePassed: at most this many names per project (default 200, max 2000).")] int? maxPassed = null,
        [Description("refuse (the cmdlet's default) | warn | off: what a run with projects that start containers does when the Docker engine has less " +
                     "free memory than minDockerFreeMemoryGiB. Needs octo-tools AB#8835.")]
        string? dockerCheck = null,
        [Description("Free memory the Docker engine must have before Docker projects start (cmdlet default 3).")] double? minDockerFreeMemoryGiB = null,
        [Description("CPU limit for every container the tests start (cmdlet default 4).")] double? dockerCpus = null,
        [Description(DockerMemoryDescription)] string? dockerMemory = null,
        [Description(StackTools.SessionDescription)] string? session = null,
        [Description(IncludeSlowDescription)] bool includeSlow = false,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, null);
            return await queue.EnqueueAsync(Request(owner, repo, null, baseLane, project, filter, rerunFailed, includeSlow, configuration, includePassed, maxPassed, dockerCheck,
                minDockerFreeMemoryGiB, dockerCpus, dockerMemory), cancellationToken);
        });

    private const string DockerMemoryDescription =
        "Opt-in memory limit for every container the tests start, e.g. '4g'; the cmdlet sets none by default ('0' sets none too). Unsafe for " +
        "MongoDB: it is set after the container started, when mongod has already sized its cache to the whole Docker VM, and mongod is then " +
        "OOM-killed (exit 137).";

    private static BuildRequest Request(string owner, string repo, string? lane, string? baseLane, List<string>? project, string? filter, bool rerunFailed,
        bool includeSlow, string? configuration, bool includePassed, int? maxPassed, string? dockerCheck, double? minDockerFreeMemoryGiB, double? dockerCpus, string? dockerMemory) =>
        new()
        {
            Owner = owner,
            Kind = BuildKind.Test,
            Repo = repo,
            Environment = lane,
            Checkout = baseLane,
            Projects = project ?? [],
            Filter = filter,
            RerunFailed = rerunFailed,
            IncludeSlow = includeSlow,
            Configuration = configuration,
            IncludePassed = includePassed,
            MaxPassed = maxPassed,
            DockerCheck = dockerCheck,
            MinDockerFreeMemoryGiB = minDockerFreeMemoryGiB,
            DockerCpus = dockerCpus,
            DockerMemory = dockerMemory
        };

    [McpServerTool(Name = "test_lock", ReadOnly = true)]
    [Description("Shows who holds the machine-wide docker test lock (Get-OctoTestLock): locked, stale (its owner process is gone; the next run " +
                 "replaces it), and the owner - pid, since, heldSeconds, command, baseLane, lane, repo, projects. " +
                 "Test runs that start containers wait for it; a suite started by hand takes the same lock. Read-only.")]
    public Task<JsonNode> Lock(CancellationToken cancellationToken = default) => ToolGuard.Run(async () => await queue.TestLockAsync(cancellationToken));
}
