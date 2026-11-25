using System.Text.Json;
using System.Text.Json.Nodes;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;
using Microsoft.Extensions.Logging.Abstractions;
using ModelContextProtocol;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     Test runs (test_run, kind test) as jobs of the build queue: the cmdlet call, its events and result, the queue
///     class, the docker test lock, and what survives a daemon restart. <see cref="FakePwsh"/> stands in for
///     Invoke-OctoTestRun; no dotnet test, no container, no real lane.
/// </summary>
public sealed class TestRunTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly FakePwsh _fake = new() { Capabilities = FakePwsh.TestParams };
    private readonly List<StackSupervisor> _supervisors = [];

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        foreach (var pid in _supervisors.SelectMany(s => s.Runs).SelectMany(r => r.Pids()).Where(ProcessTree.IsAlive))
        {
            ProcessTree.TerminateAsync(pid, TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult();
        }

        _checkout.Dispose();
    }

    [Fact]
    public void The_tested_folder_is_found_by_its_exact_name_or_octo_name_only_never_by_a_guessed_part()
    {
        var a = _checkout.Repo("octo-asset-repo-services");
        _checkout.Repo("logFiles");
        var lane = _checkout.Lane;

        BuildPlanner.TestFolderOf(null, lane, "octo-asset-repo-services").Should().Be(a);
        BuildPlanner.TestFolderOf(null, lane, "asset-repo-services").Should().Be(a, "the name without 'octo-'");
        BuildPlanner.TestFolderOf(null, lane, "asset-repo").Should().BeNull("a part could name another folder than the one the cmdlet tests");
        BuildPlanner.TestFolderOf(null, lane, "log").Should().BeNull();
        BuildPlanner.TestFolderOf(new Dictionary<string, string> { ["octo-asset-repo-services"] = a }, lane, "asset").Should().BeNull();
    }

    [Fact]
    public async Task A_test_run_whose_repo_is_only_a_part_of_a_name_warns_that_it_stops_nothing()
    {
        var queue = Create();

        var plan = await queue.Plan(Tests("oct"));

        plan.Warnings.Should().Contain(w => w.StartsWith("'oct' names no repository folder exactly", StringComparison.Ordinal) && w.Contains("stops no service"));
        (await queue.Plan(Tests("octo-a"))).Warnings.Should().NotContain(w => w.Contains("names no repository folder"));
    }

    /// <summary>The supervisor of the last <see cref="Create"/> (alpha runs from octo-a, beta from octo-b, sleeper from nothing that exists).</summary>
    private StackSupervisor Supervisor => _supervisors[^1];

    private BuildQueue Create(FakePwsh? fake = null, Func<ConfigStore, DockerVm>? docker = null, TimeSpan? probeRetry = null,
        IBuildLauncher? launcher = null, TimeSpan? idleTimeout = null, TimeSpan? testLogScanInterval = null)
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig("""
                                            sleeper:
                                              repo: octo-x
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            alpha:
                                              repo: octo-a
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            beta:
                                              repo: octo-b
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                          """);
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var state = new StateStore(paths);
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        return new BuildQueue(store, supervisor, supervisor.Leases.Default, paths, NullLogger<BuildQueue>.Instance, fake ?? _fake, state, null,
            new BuildQueueOptions
            {
                PollInterval = TimeSpan.FromMilliseconds(30), Docker = docker?.Invoke(store), EarlyRecheck = TimeSpan.FromMilliseconds(40),
                EarlyProbeRetry = probeRetry ?? TimeSpan.FromSeconds(60), IdleTimeout = idleTimeout ?? TimeSpan.FromMinutes(20),
                TestLogScanInterval = testLogScanInterval ?? TimeSpan.FromMilliseconds(50)
            }, () => Task.FromResult(ExternalSnapshot.Empty), launcher: launcher);
    }

    /// <summary>An environment folder with a manifest, as New-OctoEnvironment leaves it.</summary>
    private void Env(string name, params string[] repos)
    {
        var folder = Path.Combine(_checkout.Root, "wt-" + name);
        Directory.CreateDirectory(Path.Combine(folder, ".octo"));
        File.WriteAllText(Path.Combine(folder, "Octo.User.props"), "<Project />");
        foreach (var repo in repos)
        {
            Directory.CreateDirectory(Path.Combine(folder, repo));
        }

        var manifest = new
        {
            schemaVersion = 1, name, workItem = "AB#1234", @base = "branches/main", created = "2026-11-09T09:00:00+01:00", owner = "reimar/AB#1234_x",
            repos = repos.Select(r => new { name = r, role = "feature", path = Path.Combine(folder, r), branch = "reimar/AB#1234_x", baseCommit = "abc123" }),
            slot = (string?)null
        };
        File.WriteAllText(EnvironmentDiscovery.ManifestPath(folder), JsonSerializer.Serialize(manifest, JsonSerializerOptions.Web));
    }

    private static async Task<BuildStatus> WaitAsync(BuildQueue queue, string id, Func<BuildStatus, bool>? until = null)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (true)
        {
            var status = queue.Get(id);
            if (until?.Invoke(status) ?? status.Times.FinishedAt != null)
            {
                return status;
            }

            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException($"job {id} stays {status.State}: {status.Outcome?.Summary} | {string.Join("; ", status.Notes)}");
            }

            await Task.Delay(20, Ct);
        }
    }

    private static BuildRequest Tests(string repo, string? env = null, string owner = "s1") => new() { Owner = owner, Kind = BuildKind.Test, Repo = repo, Environment = env };

    private static void Event(string body, string name, string fields) => FakePwsh.Event(FakePwsh.EventsFile(body)!, "Invoke-OctoTestRun", name, fields);

    private const string Passed =
        """{"success":true,"exitCode":0,"repo":"octo-a","totals":{"total":3,"passed":3,"failed":0,"skipped":0},"projects":[{"project":"A.Tests","state":"passed","success":true,"total":3,"passed":3,"failed":0,"skipped":0,"durationSeconds":4.2,"failedTests":[]}]}""";

    /// <summary>Blocks the fake's test runs until released; the bodies of the calls that started are recorded.</summary>
    private (TaskCompletionSource Release, List<string> Started) Block(FakePwsh? fake = null)
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new List<string>();
        (fake ?? _fake).Build = async (body, _, _) =>
        {
            lock (started)
            {
                started.Add(body);
            }

            await release.Task;
            return FakePwsh.Ok(FakePwsh.Command(body), body.StartsWith("Invoke-OctoTestRun", StringComparison.Ordinal) ? Passed : """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        return (release, started);
    }

    // ---------- the call and its result ----------

    [Fact]
    public async Task A_test_run_calls_the_cmdlet_and_reports_the_failed_tests_by_name()
    {
        var failures = string.Join(",", Enumerable.Range(1, 25).Select(i =>
            $$"""{"name":"B.Tests.Orders.Test{{i}}","displayName":"Test{{i}}(x: 1)","outcome":"Failed","message":"Expected {{i}} but found 0 at https://user:pw@feed.example/x","stackFrame":"at B.Tests.Orders.Test{{i}}() in Orders.cs:line {{i}}","durationSeconds":0.1}"""));
        var logB = Path.Combine(_checkout.Root, "dotnet-test-b.log");
        _fake.Build = (body, _, _) =>
        {
            File.WriteAllText(logB, "  Failed Test1 [12 ms]\n  Error Message:\n   Expected 1 but found 0\n");
            Event(body, "plan", """ "repo":"octo-a","environment":null,"projects":[{"project":"A.Tests","docker":false,"noBuild":true,"buildReason":null,"skip":false},{"project":"B.Tests","docker":true,"noBuild":false,"buildReason":"source changed after the last build (src/B/Orders.cs)","skip":false}],"count":2 """.Trim());
            Event(body, "testProjectStart", "\"repo\":\"octo-a\",\"project\":\"A.Tests\",\"index\":1,\"count\":2,\"docker\":false,\"noBuild\":true");
            Event(body, "testProjectDone", "\"repo\":\"octo-a\",\"project\":\"A.Tests\",\"index\":1,\"count\":2,\"success\":true,\"state\":\"passed\",\"total\":40,\"passed\":39,\"failed\":0,\"skipped\":1,\"seconds\":6.5,\"trx\":[],\"logFile\":null");
            Event(body, "testProjectStart", "\"repo\":\"octo-a\",\"project\":\"B.Tests\",\"index\":2,\"count\":2,\"docker\":true,\"noBuild\":false");
            Event(body, "testProjectDone", $"\"repo\":\"octo-a\",\"project\":\"B.Tests\",\"index\":2,\"count\":2,\"success\":false,\"state\":\"failed\",\"total\":30,\"passed\":5,\"failed\":25,\"skipped\":0,\"seconds\":12,\"trx\":[],\"logFile\":{JsonSerializer.Serialize(logB)}");
            Event(body, "done", "\"success\":false,\"failedRepo\":\"octo-a\",\"failedProject\":\"B.Tests\",\"failedStep\":\"tests\",\"elapsedSeconds\":19,\"total\":70,\"passed\":44,\"failed\":25,\"skipped\":1");
            return Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
                $$"""{"success":false,"exitCode":1,"failedStep":"tests","failedProject":"B.Tests","repo":"octo-a","totals":{"total":70,"passed":44,"failed":25,"skipped":1},"projects":[{"project":"A.Tests","state":"passed","success":true,"docker":false,"total":40,"passed":39,"failed":0,"skipped":1,"durationSeconds":6.5,"failedTests":[]},{"project":"B.Tests","state":"failed","success":false,"docker":true,"buildReason":"source changed after the last build (src/B/Orders.cs)","total":30,"passed":5,"failed":25,"skipped":0,"durationSeconds":12,"failedTests":[{{failures}}],"truncated":false,"logFile":"{{logB.Replace("\\", "\\\\")}}"}]}""",
                exitCode: 1));
        };
        var queue = Create();

        var job = await queue.EnqueueAsync(new BuildRequest
        {
            Owner = "s1", Kind = BuildKind.Test, Repo = "octo-a", Projects = ["A.Tests", "B.Tests"], Filter = "Category!=Slow", RerunFailed = true
        }, Ct);
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().StartWith(
            "Invoke-OctoTestRun -branch 'branches/main' -repo 'octo-a' -project 'A.Tests','B.Tests' -filter 'Category!=Slow' -rerunFailed -Json -EventsFile ");
        done.Kind.Should().Be("test");
        done.Target.Should().Be("branches/main: tests of octo-a");
        done.State.Should().Be("failed");
        done.Outcome.Should().BeEquivalentTo(new { FailedRepo = "B.Tests", FailedStep = "tests", Summary = "25 of 70 test(s) failed in B.Tests" });
        done.Outcome!.Hint.Should().Contain("rerunFailed=true");
        done.Tests.Should().BeEquivalentTo(new { Total = 70, Passed = 44, Failed = 25, Skipped = 1, LockWait = (string?)null });
        done.Tests!.Projects.Select(p => p.Project).Should().Equal(["B.Tests", "A.Tests"], "failed projects first");
        var failed = done.Tests.Projects[0];
        failed.Should().BeEquivalentTo(new { State = "failed", Total = 30, Failed = 25, Seconds = 12.0, Docker = true, MoreFailed = 5, BuildReason = "source changed after the last build (src/B/Orders.cs)" });
        failed.FailedTests.Should().HaveCount(20, "the compact status lists 20 failed tests per project");
        failed.FailedTests[0].Should().Be(new BuildFailedTest("B.Tests.Orders.Test1", "Expected 1 but found 0 at https://***@feed.example/x", "at B.Tests.Orders.Test1() in Orders.cs:line 1"));
        done.Progress!.Projects!.Select(r => (r.Project, r.State)).Should().Equal(("A.Tests", "done"), ("B.Tests", "failed"));
        done.Progress.Repos.Should().BeNull("a test run's rows are test projects");
        var progressJson = JsonSerializer.SerializeToNode(done.Progress, ModelContextProtocol.McpJsonUtilities.DefaultOptions)!.AsObject();
        progressJson["projectCount"]!.GetValue<int>().Should().Be(2);
        var firstRow = progressJson["projects"]![0]!.AsObject();
        firstRow.First().Key.Should().Be("project", "the row is named first");
        firstRow["project"]!.GetValue<string>().Should().Be("A.Tests");
        firstRow.ContainsKey("repo").Should().BeFalse();
        progressJson.ContainsKey("repoCount").Should().BeFalse();
        progressJson.ContainsKey("repos").Should().BeFalse();

        queue.Get(job.Id, "B.Tests").Tests!.Projects.Single().FailedTests.Should().HaveCount(25, "project=X lists all of them");
        // The project's dotnet-test.log is kept like a repo's build log.
        queue.Output(job.Id, "B.Tests").Log.Should().BeEquivalentTo(new { Selected = "B.Tests", Source = "kept" });
    }

    [Fact]
    public async Task A_passed_run_of_an_environment_names_the_environment_and_counts_the_tests()
    {
        Env("ab1-one", "octo-a");
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun", Passed));
        var queue = Create();

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(Tests("octo-a", "ab1-one"), Ct)).Id);

        _fake.BuildCalls.Single().Should().StartWith("Invoke-OctoTestRun -env 'ab1-one' -repo 'octo-a' -Json");
        done.State.Should().Be("succeeded");
        done.Env.Should().Be("ab1-one");
        done.Outcome!.Summary.Should().Be("3 test(s) passed in 1 project(s)");
        done.Tests!.Projects.Single().Should().BeEquivalentTo(new { Project = "A.Tests", State = "passed", Total = 3, Seconds = 4.2 });
    }

    // ---------- usual durations ----------

    /// <summary>A run of octo-a whose projects end passed (A, 6.5 s), failed (B, 12 s) and noTests (C).</summary>
    private void ThreeProjects() =>
        _fake.Build = (body, _, _) =>
        {
            Event(body, "testProjectStart", "\"repo\":\"octo-a\",\"project\":\"A.Tests\",\"index\":1,\"count\":3,\"noBuild\":false");
            Event(body, "testProjectDone", "\"repo\":\"octo-a\",\"project\":\"A.Tests\",\"index\":1,\"count\":3,\"success\":true,\"state\":\"passed\",\"total\":4,\"passed\":4,\"failed\":0,\"skipped\":0,\"seconds\":6.5");
            Event(body, "testProjectDone", "\"repo\":\"octo-a\",\"project\":\"B.Tests\",\"index\":2,\"count\":3,\"success\":false,\"state\":\"failed\",\"total\":2,\"passed\":1,\"failed\":1,\"skipped\":0,\"seconds\":12");
            Event(body, "testProjectDone", "\"repo\":\"octo-a\",\"project\":\"C.Tests\",\"index\":3,\"count\":3,\"success\":false,\"state\":\"noTests\",\"total\":0,\"passed\":0,\"failed\":0,\"skipped\":0,\"seconds\":1");
            return Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
                """{"success":false,"exitCode":1,"repo":"octo-a","totals":{"total":6,"passed":5,"failed":1,"skipped":0},"projects":[{"project":"A.Tests","state":"passed","success":true,"total":4,"passed":4,"failed":0,"skipped":0,"durationSeconds":6.5,"failedTests":[]},{"project":"B.Tests","state":"failed","success":false,"total":2,"passed":1,"failed":1,"skipped":0,"durationSeconds":12,"failedTests":[]},{"project":"C.Tests","state":"noTests","success":false,"total":0,"passed":0,"failed":0,"skipped":0,"durationSeconds":1,"failedTests":[]}]}""",
                exitCode: 1));
        };

    [Fact]
    public async Task A_whole_test_run_records_what_its_projects_took_and_a_filtered_run_records_nothing()
    {
        ThreeProjects();
        var queue = Create();

        await WaitAsync(queue, (await queue.EnqueueAsync(Tests("octo-a"), Ct)).Id);
        await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Test, Repo = "octo-a", Filter = "Name~X" }, Ct)).Id);
        await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Test, Repo = "octo-a", RerunFailed = true }, Ct)).Id);

        var stats = queue.DurationStats("a");
        stats.Select(s => (s.Kind, s.Repo, s.Project, s.CompilesFirst, s.Samples, s.LastSeconds)).Should().BeEquivalentTo(
            [(DurationKind.Test, "octo-a", "B.Tests", (bool?)null, 1, 12.0), (DurationKind.Test, "octo-a", "A.Tests", (bool?)true, 1, 6.5)],
            "passed and failed projects count, a project without tests does not, and neither does a run of a filter or of the failed tests");
        queue.DurationStats("octo-b").Should().BeEmpty();
    }

    [Fact]
    public async Task A_test_project_that_runs_far_longer_than_usual_is_overdue()
    {
        var history = new BuildHistory(new DevStackPaths(_checkout.StateDirectory));
        foreach (var s in new[] { 10.0, 11, 12 })
        {
            history.RecordTest(_checkout.Lane, "octo-a", "A.Tests", false, "DebugL", s);
            history.RecordTest(_checkout.Lane, "octo-a", "A.Tests", true, "DebugL", s * 100);
        }

        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            // A.Tests started ten minutes ago on its last build; such runs usually take 11 s, their limit is 131 s.
            var ts = DateTimeOffset.UtcNow.AddMinutes(-10).ToString("O");
            File.AppendAllText(FakePwsh.EventsFile(body)!,
                $$"""{"schemaVersion":1,"ts":"{{ts}}","command":"Invoke-OctoTestRun","event":"testProjectStart","repo":"octo-a","project":"A.Tests","index":1,"count":2,"noBuild":true}""" + "\n");
            await release.Task;
            return FakePwsh.Ok("Invoke-OctoTestRun", Passed);
        };
        var queue = Create();
        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);

        var running = await WaitAsync(queue, job.Id, s => s.Progress?.Current != null);
        running.Progress!.Current.Should().BeEquivalentTo(new { Project = "A.Tests", TypicalSeconds = (double?)11, LimitSeconds = (double?)131, Overdue = (bool?)true });
        var json = JsonSerializer.SerializeToNode(running.Progress.Current, McpJsonUtilities.DefaultOptions)!.AsObject();
        json["overdue"]!.GetValue<bool>().Should().BeTrue();
        json["typicalSeconds"]!.GetValue<double>().Should().Be(11);

        release.SetResult();
        var done = await WaitAsync(queue, job.Id);
        done.Progress!.Current.Should().BeNull("a finished run has no current project");
    }

    // octo-tools AB#8832: runner per project, noMatch, noTests as a failure, the names of passed tests.
    private static readonly string GapsParams = FakePwsh.TestParams.Replace("\"rerunFailed\",", "\"rerunFailed\",\"includePassed\",\"maxPassed\",");

    [Fact]
    public async Task A_filter_that_matches_in_one_project_only_succeeds_and_names_runner_and_passed_tests_on_request()
    {
        GapsParams.Should().Contain("includePassed");
        _fake.Capabilities = GapsParams;
        _fake.Build = (body, _, _) =>
        {
            Event(body, "plan", "\"repo\":\"octo-a\",\"environment\":null,\"projects\":[{\"project\":\"A.Tests\",\"docker\":false,\"noBuild\":true,\"skip\":false},{\"project\":\"B.Tests\",\"docker\":false,\"noBuild\":true,\"skip\":false}],\"count\":2");
            Event(body, "testProjectDone", "\"repo\":\"octo-a\",\"project\":\"B.Tests\",\"index\":2,\"count\":2,\"success\":true,\"state\":\"noMatch\",\"total\":0,\"passed\":0,\"failed\":0,\"skipped\":0,\"seconds\":1");
            return Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
                """{"success":true,"exitCode":0,"repo":"octo-a","totals":{"total":2,"passed":2,"failed":0,"skipped":0},"projects":[{"project":"A.Tests","state":"passed","success":true,"runner":"vstest","total":2,"passed":2,"failed":0,"skipped":0,"durationSeconds":1.5,"failedTests":[],"passedTests":["A.X.One","A.X.Two"],"passedTruncated":true},{"project":"B.Tests","state":"noMatch","success":true,"runner":"mtp","note":"no test matched the filter","total":0,"passed":0,"failed":0,"skipped":0,"failedTests":[],"passedTests":[],"passedTruncated":false}]}"""));
        };
        var queue = Create();

        var job = await queue.EnqueueAsync(Tests("octo-a") with { Filter = "FullyQualifiedName~X", IncludePassed = true, MaxPassed = 50 }, Ct);
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().StartWith("Invoke-OctoTestRun -branch 'branches/main' -repo 'octo-a' -filter 'FullyQualifiedName~X' -includePassed -maxPassed 50 -Json");
        done.State.Should().Be("succeeded");
        done.Outcome!.Summary.Should().Be("2 test(s) passed in 1 project(s); the filter matched nothing in 1 project(s)");
        done.Tests!.Projects.Should().BeEquivalentTo(new object[]
        {
            new { Project = "A.Tests", State = "passed", Runner = "vstest", PassedListed = 2, PassedTruncated = true, PassedTests = (IReadOnlyList<string>?)null },
            new { Project = "B.Tests", State = "noMatch", Runner = "mtp", Note = "no test matched the filter", PassedListed = (int?)null }
        });
        done.Progress!.Projects.Should().OnlyContain(r => r.State == "done", "noMatch is a success");
        queue.Get(job.Id, includePassed: true).Tests!.Projects[0].PassedTests.Should().Equal("A.X.One", "A.X.Two");
    }

    [Fact]
    public async Task A_rebuild_because_octo_tools_missed_the_build_output_in_the_repositorys_bin_folder_is_explained()
    {
        // The repository builds into <repo>/bin/DebugL; octo-tools looks below <project>/bin/DebugL only.
        var output = Directory.CreateDirectory(Path.Combine(_checkout.Lane, "octo-a", "bin", "DebugL", "A.Tests", "net10.0")).FullName;
        File.WriteAllText(Path.Combine(output, "A.Tests.dll"), "");
        _fake.Build = (body, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
            """{"success":true,"exitCode":0,"repo":"octo-a","totals":{"total":2,"passed":2,"failed":0,"skipped":0},"projects":[""" +
            """{"project":"A.Tests","state":"passed","success":true,"buildReason":"no DebugL build output of A.Tests","total":1,"passed":1,"failed":0,"skipped":0,"failedTests":[]},""" +
            """{"project":"B.Tests","state":"passed","success":true,"buildReason":"no DebugL build output of B.Tests","total":1,"passed":1,"failed":0,"skipped":0,"failedTests":[]}]}"""));
        var queue = Create();

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(Tests("octo-a"), Ct)).Id);

        var a = done.Tests!.Projects.Single(p => p.Project == "A.Tests").BuildReason;
        a.Should().StartWith("no DebugL build output of A.Tests - the assembly exists in <repo>/bin/DebugL (this repository builds there), but octo-tools looks " +
                             "only below <project>/bin/DebugL, so a test run compiles the test projects itself (harmless", "read after the run: no claim about an earlier build");
        done.Tests.Projects.Single(p => p.Project == "B.Tests").BuildReason.Should().Be("no DebugL build output of B.Tests", "B.Tests.dll is nowhere: really not built");

        BuildQueue.ExplainBuildReasons([new BuildTestProject("A.Tests", "passed", 1, 1, 0, 0, 1, [], BuildReason: "source changed after the last build (x.cs)")],
                Path.Combine(_checkout.Lane, "octo-a"), "DebugL")
            .Single().BuildReason.Should().Be("source changed after the last build (x.cs)", "only a missing build output is explained");
    }

    [Fact]
    public async Task A_project_that_runs_no_test_without_a_filter_fails_the_run()
    {
        _fake.Capabilities = GapsParams;
        _fake.Build = (body, _, _) =>
        {
            Event(body, "plan", "\"repo\":\"octo-a\",\"environment\":null,\"projects\":[{\"project\":\"C.Tests\",\"docker\":false,\"noBuild\":true,\"skip\":false}],\"count\":1");
            Event(body, "testProjectDone", "\"repo\":\"octo-a\",\"project\":\"C.Tests\",\"index\":1,\"count\":1,\"success\":false,\"state\":\"noTests\",\"total\":0,\"passed\":0,\"failed\":0,\"skipped\":0,\"seconds\":1");
            return Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
                """{"success":false,"exitCode":1,"failedStep":"tests","failedProject":"C.Tests","repo":"octo-a","totals":{"total":0,"passed":0,"failed":0,"skipped":0},"projects":[{"project":"C.Tests","state":"noTests","success":false,"runner":"mtp","note":"the project ran no test","total":0,"passed":0,"failed":0,"skipped":0,"failedTests":[]}]}""", exitCode: 1));
        };
        var queue = Create();

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(Tests("octo-a"), Ct)).Id);

        done.State.Should().Be("failed");
        done.Outcome.Should().BeEquivalentTo(new { FailedStep = "tests", FailedRepo = "C.Tests", Summary = "no test ran in C.Tests" });
        done.Tests!.Projects.Single().Should().BeEquivalentTo(new { Project = "C.Tests", State = "noTests", Runner = "mtp", Note = "the project ran no test" });
        done.Progress!.Projects!.Single().State.Should().Be("failed");
    }

    [Fact]
    public async Task The_names_of_passed_tests_need_an_octo_tools_that_has_them()
    {
        var queue = Create();

        var run = () => queue.EnqueueAsync(Tests("octo-a") with { IncludePassed = true }, Ct);

        (await run.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*has no -includePassed*AB#8832*");
        // Without the parameter the older cmdlet is called as before.
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun", Passed));
        (await WaitAsync(queue, (await queue.EnqueueAsync(Tests("octo-a"), Ct)).Id)).Tests!.Projects.Single().Runner.Should().BeNull();
    }

    // octo-tools AB#8835: the Docker check and the container limits of Invoke-OctoTestRun.
    private static readonly string DockerParams = GapsParams.Replace("\"rerunFailed\",", "\"rerunFailed\",\"dockerCheck\",\"minDockerFreeMemoryGiB\",\"dockerCpus\",\"dockerMemory\",");

    [Fact]
    public async Task A_run_the_docker_check_refused_says_how_much_is_free_and_what_uses_it()
    {
        _fake.Capabilities = DockerParams;
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            Event(body, "plan", "\"repo\":\"octo-a\",\"environment\":null,\"projects\":[{\"project\":\"A.Tests\",\"docker\":true,\"runner\":\"mtp\",\"noBuild\":true,\"skip\":false}],\"count\":1");
            await release.Task;
            return FakePwsh.Ok("Invoke-OctoTestRun",
                """{"success":false,"exitCode":1,"failedStep":"docker","failedProject":null,"repo":"octo-a","totals":{"total":0,"passed":0,"failed":0,"skipped":0},"docker":{"required":true,"checked":true,"check":"refused","available":true,"memoryGiB":15.6,"cpus":16,"usedGiB":14.41,"freeGiB":1.19,"minFreeGiB":3,"containers":[{"name":"kind-control-plane","memoryGiB":6.12},{"name":"big-db","memoryGiB":5.5},{"name":"c3","memoryGiB":1},{"name":"c4","memoryGiB":0.5}],"message":"The Docker engine has 1.2 GiB free.","limits":{"cpus":2,"memory":"2g"},"limited":[]},"projects":[{"project":"A.Tests","state":"notRun","success":false,"runner":"mtp","docker":true,"failedTests":[]}]}""", exitCode: 1);
        };
        var queue = Create();

        var job = await queue.EnqueueAsync(Tests("octo-a") with { DockerCheck = "Refuse", MinDockerFreeMemoryGiB = 3, DockerCpus = 2, DockerMemory = "2g" }, Ct);
        var running = await WaitAsync(queue, job.Id, s => s.Tests?.Projects.Count > 0);
        running.Tests!.Projects.Single().Runner.Should().Be("mtp", "the plan event names the runner while the run goes on");
        running.Tests.Docker.Should().BeNull("the cmdlet reports its check with the result");
        release.SetResult();
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().StartWith("Invoke-OctoTestRun -branch 'branches/main' -repo 'octo-a' -dockerCheck Refuse -minDockerFreeMemoryGiB 3 -dockerCpus 2 -dockerMemory '2g' -Json");
        done.State.Should().Be("failed");
        done.Outcome!.FailedStep.Should().Be("docker");
        done.Outcome.Summary.Should().Be("not started: Docker has 1.2 GiB free, needs 3; biggest containers: kind-control-plane (6.1 GiB), big-db (5.5 GiB), c3 (1 GiB); " +
                                         "stop what is not needed, give Docker more memory, or pass dockerCheck=warn");
        done.Tests!.Docker.Should().BeEquivalentTo(new
        {
            Check = "refused", FreeGiB = 1.2, MinFreeGiB = 3.0, MemoryGiB = 15.6, UsedGiB = 14.4, Limits = "2 CPUs, 2g memory per test container", Limited = (int?)null
        });
        done.Tests.Projects.Single().State.Should().Be("notRun");
        done.Tests.DockerWarning.Should().BeNull();
    }

    [Fact]
    public async Task The_docker_parameters_need_an_octo_tools_that_has_them_and_are_checked()
    {
        var old = Create();
        var refused = () => old.EnqueueAsync(Tests("octo-a") with { DockerCheck = "warn" }, Ct);
        (await refused.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*no Docker check or container limits*AB#8835*");

        var queue = Create(new FakePwsh { Capabilities = DockerParams });
        var check = () => queue.EnqueueAsync(Tests("octo-a") with { DockerCheck = "maybe" }, Ct);
        await check.Should().ThrowAsync<ArgumentException>().WithMessage("dockerCheck is refuse, warn or off.");
        var memory = () => queue.EnqueueAsync(Tests("octo-a") with { DockerMemory = "4g; rm" }, Ct);
        await memory.Should().ThrowAsync<ArgumentException>().WithMessage("dockerMemory is a size*");
        BuildQueue.DockerOf(JsonNode.Parse("""{"docker":{"required":false,"check":"off"}}""") as JsonObject).Should().BeNull("a run without Docker projects shows no block");
        BuildQueue.DockerOf(JsonNode.Parse("""{"docker":{"required":true,"check":"ok","freeGiB":8.04,"minFreeGiB":3,"limits":{"cpus":4,"memory":"4g"},"limited":[{"id":"a","success":true},{"id":"b","success":false,"error":"x"}]}}""") as JsonObject)
            .Should().BeEquivalentTo(new { Check = "ok", FreeGiB = 8.0, Limits = "4 CPUs, 4g memory per test container", Limited = 2, LimitFailed = 1 });
    }

    [Fact]
    public async Task A_preflight_error_of_the_cmdlet_is_the_outcome()
    {
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
            """{"success":false,"exitCode":1,"error":"Repository 'nope' is not in branches/main.","failedStep":"preflight","repo":"nope","totals":{"total":0,"passed":0,"failed":0,"skipped":0},"projects":[]}""", exitCode: 1));
        var queue = Create();

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(Tests("nope"), Ct)).Id);

        done.State.Should().Be("failed");
        done.Outcome.Should().BeEquivalentTo(new { FailedStep = "preflight", Summary = "Repository 'nope' is not in branches/main." });
    }

    [Fact]
    public async Task Without_the_cmdlet_a_test_run_is_refused_with_where_it_comes_from()
    {
        var queue = Create(new FakePwsh { Capabilities = FakePwsh.EnvironmentParams });

        var run = () => queue.EnqueueAsync(Tests("octo-a"), Ct);
        (await run.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*has no Invoke-OctoTestRun*AB#8813*PR #39*");
        var noRepo = () => queue.EnqueueAsync(Tests(" "), Ct);
        await noRepo.Should().ThrowAsync<ArgumentException>().WithMessage("repo is required*");
        var tool = () => new TestTools(queue).Lock(Ct);
        (await tool.Should().ThrowAsync<McpException>()).WithMessage("*has no Get-OctoTestLock*");
        var viaBuild = () => new BuildTools(queue).BaseBuild("s1", kind: "test", cancellationToken: Ct);
        (await viaBuild.Should().ThrowAsync<McpException>()).WithMessage("*base_test*lane_test*");
    }

    // ---------- lanes without repositories, runs of removed places (AB#8915) ----------

    /// <summary>A second lane below rootPath (not the default one), with the given folders.</summary>
    private string Lane(string relative, params string[] folders)
    {
        var lane = Path.Combine(_checkout.Root, relative);
        Directory.CreateDirectory(lane);
        foreach (var folder in folders)
        {
            Directory.CreateDirectory(Path.Combine(lane, folder));
        }

        return lane;
    }

    [Fact]
    public async Task A_test_run_in_a_lane_without_repositories_is_refused_and_creates_no_job()
    {
        // The incident: a worktree of a single repo (src, tests - no octo-* folder) passed as the checkout.
        var lane = Lane(Path.Combine("branches", "worktrees", "octo-sdk-TDBINT"), "src", "tests");
        var queue = Create();

        var act = () => queue.EnqueueAsync(Tests("octo-sdk") with { Checkout = "branches/worktrees/octo-sdk-TDBINT" }, Ct);

        var error = (await act.Should().ThrowAsync<ArgumentException>()).Which.Message;
        error.Should().Contain(lane).And.Contain("holds no repository").And.Contain("lane_test").And.Contain("baseLane=branches/main").And.Contain("no job was created");
        queue.List().Should().BeEmpty();
        _fake.BuildCalls.Should().BeEmpty();
    }

    [Fact]
    public async Task A_test_run_of_a_consumer_app_named_exactly_is_accepted_in_a_lane_without_octo_folders()
    {
        // Invoke-OctoTestRun takes a git repository named exactly (energy-community, voest-app) in a lane too.
        Lane(Path.Combine("branches", "apps"), Path.Combine("energy-community", ".git"));
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun", Passed));
        var queue = Create();

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(Tests("energy-community") with { Checkout = "branches/apps" }, Ct)).Id);

        done.State.Should().Be("succeeded");
        done.Gone.Should().BeNull();
    }

    [Fact]
    public async Task A_finished_run_whose_checkout_was_removed_is_marked_gone_and_comes_back_when_it_exists_again()
    {
        var lane = Lane(Path.Combine("branches", "feature"), "octo-a");
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
            """{"success":false,"exitCode":1,"failedStep":"tests","failedProject":"A.Tests","projects":[{"project":"A.Tests","state":"failed","success":false,"total":1,"passed":0,"failed":1,"skipped":0,"durationSeconds":1,"failedTests":[]}]}""",
            exitCode: 1));
        var first = Create();
        var done = await WaitAsync(first, (await first.EnqueueAsync(Tests("octo-a") with { Checkout = "branches/feature" }, Ct)).Id);
        done.State.Should().Be("failed");
        done.Gone.Should().BeNull("the checkout still exists");

        Directory.Delete(lane, recursive: true);

        first.List().Single().Gone.Should().Be($"base lane {lane} no longer exists");
        first.Abandon();
        // Computed from the disk, not stored: the next daemon run says the same.
        var second = Create();
        second.Get(done.Id).Gone.Should().Be($"base lane {lane} no longer exists");
        Lane(Path.Combine("branches", "feature"));
        second.Get(done.Id).Gone.Should().Be($"base lane {lane} holds no repository any more");
        Lane(Path.Combine("branches", "feature"), "octo-a");
        second.Get(done.Id).Gone.Should().BeNull();
    }

    [Fact]
    public async Task A_lane_that_holds_only_developer_tools_is_no_lane_and_its_finished_runs_are_gone()
    {
        // The old flat root after the move to the lanes layout: the repositories went to branches/main, the developer tools
        // (octo-tools, octo-devstack, octo-claude-pm) and other folders stayed. Its old failed runs are history.
        var lane = Lane("flat", "octo-a", "octo-tools", "octo-devstack", "octo-claude-pm", "docs", Path.Combine("octo-devstack", ".git"));
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
            """{"success":false,"exitCode":1,"failedStep":"tests","failedProject":"A.Tests","projects":[{"project":"A.Tests","state":"failed","success":false,"total":1,"passed":0,"failed":1,"skipped":0,"durationSeconds":1,"failedTests":[]}]}""",
            exitCode: 1));
        var queue = Create();
        var done = await WaitAsync(queue, (await queue.EnqueueAsync(Tests("octo-a") with { Checkout = "flat" }, Ct)).Id);
        done.Gone.Should().BeNull("octo-a is still there");

        Directory.Delete(Path.Combine(lane, "octo-a"));

        queue.Get(done.Id).Gone.Should().Be($"base lane {lane} holds no repository any more");
        LaneRepositories.Holds(lane).Should().BeFalse("developer tools are no repositories of a lane");
        LaneRepositories.Holds(lane, "octo-devstack").Should().BeFalse("not even named exactly, as a consumer app would be");
        LaneRepositories.GoneReason(null, null, lane, "all", "flat: all").Should().Be($"base lane {lane} holds no repository any more");
        var refused = async () => await queue.EnqueueAsync(Tests("octo-tools") with { Checkout = "flat" }, Ct);
        (await refused.Should().ThrowAsync<ArgumentException>()).Which.Message.Should().Contain("holds no repository")
            .And.Contain("octo-claude-pm, octo-devstack, octo-tools");

        Lane("flat", "mm-common");
        queue.Get(done.Id).Gone.Should().BeNull("an mm-* folder is a repository");
    }

    [Fact]
    public async Task A_run_with_checkout_set_to_an_environment_folder_is_judged_by_the_environment_not_the_lane_rule()
    {
        // AB#8915: the environment's only repo is adopted outside its folder, so the folder holds no octo-* folder. The job
        // records the environment the checkout resolved to; a lane check would hide this real run as gone.
        Env("ab1-one");
        var folder = Path.Combine(_checkout.Root, "wt-ab1-one");
        var adopted = Path.Combine(_checkout.Root, "wt-main-octo-a");
        Directory.CreateDirectory(adopted);
        var manifest = new
        {
            schemaVersion = 1, name = "ab1-one", workItem = "AB#1234", @base = "branches/main", created = "2026-11-09T09:00:00+01:00", owner = "reimar/AB#1234_x",
            repos = new[] { new { name = "octo-a", role = "feature", path = adopted, branch = "reimar/AB#1234_x", baseCommit = "abc123" } },
            slot = (string?)null
        };
        File.WriteAllText(EnvironmentDiscovery.ManifestPath(folder), JsonSerializer.Serialize(manifest, JsonSerializerOptions.Web));
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun", Passed));
        var first = Create();

        var done = await WaitAsync(first, (await first.EnqueueAsync(Tests("octo-a") with { Checkout = "wt-ab1-one" }, Ct)).Id);

        done.State.Should().Be("succeeded");
        done.Gone.Should().BeNull("the environment exists, although its folder holds no octo-* folder");
        first.Abandon();
        var second = Create();
        second.Get(done.Id).Gone.Should().BeNull("the detected environment is kept in the job file");
        File.Delete(EnvironmentDiscovery.ManifestPath(folder));
        second.Get(done.Id).Gone.Should().Be($"lane ab1-one no longer exists ({folder})");
    }

    [Fact]
    public async Task A_finished_run_of_a_removed_environment_is_marked_gone_but_a_running_one_never()
    {
        Env("ab1-one", "octo-a");
        var (release, _) = Block();
        var queue = Create();
        var job = await queue.EnqueueAsync(Tests("octo-a", "ab1-one"), Ct);
        await WaitAsync(queue, job.Id, s => s.State == "running");
        var folder = Path.Combine(_checkout.Root, "wt-ab1-one");
        File.Delete(EnvironmentDiscovery.ManifestPath(folder));

        queue.Get(job.Id).Gone.Should().BeNull("a job that still runs is never history");
        release.SetResult();
        var done = await WaitAsync(queue, job.Id);

        done.Gone.Should().Be($"lane ab1-one no longer exists ({folder})");
        JsonSerializer.Serialize(done, JsonSerializerOptions.Web).Should().Contain("\"gone\":");
    }

    // ---------- the docker test lock ----------

    [Fact]
    public async Task A_run_that_waits_for_the_docker_test_lock_says_who_holds_it()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            Event(body, "plan", "\"repo\":\"octo-a\",\"environment\":null,\"projects\":[{\"project\":\"A.Tests\",\"docker\":true,\"noBuild\":true,\"skip\":false}],\"count\":1");
            Event(body, "lockWait",
                "\"path\":\"/state/docker-tests.lock\",\"timeoutSeconds\":1800,\"owner\":{\"pid\":4711,\"since\":\"2026-11-11T09:48:00Z\",\"heldSeconds\":120,\"command\":\"Invoke-OctoTestRun\",\"lane\":\"/x/wt-ab8797\",\"environment\":\"ab8797\",\"repo\":\"octo-b\",\"projects\":[\"B.Tests\"]}");
            await release.Task;
            Event(body, "lockAcquired", "\"path\":\"/state/docker-tests.lock\",\"waitedSeconds\":3");
            return FakePwsh.Ok("Invoke-OctoTestRun", Passed);
        };
        var queue = Create();

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        var waiting = await WaitAsync(queue, job.Id, s => s.Tests?.LockWait != null);

        waiting.State.Should().Be("running");
        waiting.Progress!.Phase.Should().Be("lock");
        waiting.Tests!.LockWait.Should().StartWith("waiting for the docker test lock held by Invoke-OctoTestRun of ab8797 octo-b (pid 4711, since ");
        waiting.Tests.Projects.Single().Should().BeEquivalentTo(new { Project = "A.Tests", State = "pending", Docker = true });

        release.SetResult();
        var done = await WaitAsync(queue, job.Id);
        done.State.Should().Be("succeeded");
        done.Tests!.LockWait.Should().BeNull();
    }

    [Fact]
    public async Task A_run_with_container_tests_on_a_small_docker_vm_next_to_kind_carries_a_warning()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            Event(body, "plan",
                "\"repo\":\"octo-a\",\"environment\":null,\"projects\":[{\"project\":\"A.Tests\",\"docker\":true,\"noBuild\":true,\"skip\":false}],\"count\":1");
            await release.Task;
            return FakePwsh.Ok("Invoke-OctoTestRun", Passed);
        };
        var queue = Create(docker: store => new DockerVm(store, arguments => arguments.StartsWith("info", StringComparison.Ordinal)
            ? (0, """{"NCPU":4,"MemTotal":8327528448,"OperatingSystem":"Docker Desktop"}""")
            : (0, "kindest/node:v1.33.1\n")));

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);

        job.Notes.Should().Contain(n => n.StartsWith("If this run includes test projects that start containers: The Docker VM has 7.8 GiB memory (below 12) and 4 CPUs (below 6)"));
        var running = await WaitAsync(queue, job.Id, s => s.Tests?.Projects.Count > 0);
        running.Tests!.DockerWarning.Should().Contain("kind cluster runs in it");

        release.SetResult();
        (await WaitAsync(queue, job.Id)).Tests!.DockerWarning.Should().BeNull("the run is over");
    }

    [Fact]
    public async Task A_running_test_project_shows_its_test_log()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            Event(body, "plan", "\"repo\":\"octo-a\",\"environment\":null,\"projects\":[{\"project\":\"A.Tests\",\"docker\":false,\"noBuild\":true,\"skip\":false}],\"count\":1");
            Event(body, "testProjectStart", "\"repo\":\"octo-a\",\"project\":\"A.Tests\",\"index\":1,\"count\":1,\"docker\":false,\"noBuild\":true");
            // The cmdlet names the log only in testProjectDone; it lies in the project's newest run folder.
            var run = Path.Combine(_checkout.Lane, "logFiles", "test-results", "octo-a", "A.Tests", "20261111-120000-000-1");
            Directory.CreateDirectory(run);
            File.WriteAllText(Path.Combine(run, "dotnet-test.log"), "Starting test execution\n  Passed A.Tests.X.One [3 ms]\n  Failed A.Tests.X.Two [5 ms]\n");
            await release.Task;
            return FakePwsh.Ok("Invoke-OctoTestRun", Passed);
        };
        var queue = Create();

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        await WaitAsync(queue, job.Id, s => s.Progress?.Current != null);

        var live = queue.Get(job.Id, live: 2).Live!;
        live.Should().BeEquivalentTo(new { Selected = "A.Tests", Source = "live" });
        live.Lines.Should().Equal("  Passed A.Tests.X.One [3 ms]", "  Failed A.Tests.X.Two [5 ms]");
        queue.Output(job.Id).Log.Selected.Should().Be("A.Tests");
        queue.Get(job.Id).Progress!.Projects!.Single().Tests.Should().BeNull("a test run has no 'tests compiled' flag");
        queue.Get(job.Id).Progress!.Current!.Project.Should().Be("A.Tests", "the test project that runs now");

        release.SetResult();
        await WaitAsync(queue, job.Id);
    }

    // ---------- idle watchdog (AB#9417) ----------

    /// <summary>
    ///     A detached test step as a pwsh script (every OS, through its real launcher): writes the plan event, then for
    ///     <paramref name="seconds"/> appends a line to the project's dotnet-test.log every 0.2 s (or stays silent), prints
    ///     nothing to the job log until the end, then prints the cmdlet's -Json document (literals, one per line) and exits 0.
    /// </summary>
    private sealed class QuietTestLauncher(string lane, double seconds, bool writeTestLog) : IBuildLauncher
    {
        public List<int> Pids { get; } = [];

        public LaunchedBuild Start(BuildLaunch launch)
        {
            var events = FakePwsh.EventsFile(launch.Body) ?? throw new InvalidOperationException("the step has no -EventsFile");
            var run = Path.Combine(lane, "logFiles", "test-results", "octo-a", "A.Tests", "20261119-140000-000-1");
            var plan = $$"""{"schemaVersion":1,"ts":"{{DateTimeOffset.UtcNow:O}}","command":"Invoke-OctoTestRun","event":"plan","repo":"octo-a","environment":null,"projects":[{"project":"A.Tests","docker":false,"noBuild":true,"skip":false}],"count":1}""";
            var json = FakePwsh.Ok("Invoke-OctoTestRun", Passed).Output.Trim();
            var steps = (int)Math.Ceiling(seconds / 0.2);
            var testLog = TestProcess.PwshLiteral(Path.Combine(run, "dotnet-test.log"));
            var write = writeTestLog ? $"[IO.File]::AppendAllText({testLog}, '  Passed A.Tests.X.T' + $i + [char]10); " : "";
            var script = string.Join("; ", [
                $"[IO.File]::AppendAllText({TestProcess.PwshLiteral(events)}, {TestProcess.PwshLiteral(plan)} + [char]10)",
                $"[void][IO.Directory]::CreateDirectory({TestProcess.PwshLiteral(run)})",
                $"for ($i = 0; $i -lt {steps}; $i++) {{ {write}Start-Sleep -Milliseconds 200 }}",
                ..json.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => $"[Console]::Out.WriteLine({TestProcess.PwshLiteral(l.TrimEnd('\r'))})"),
                "exit 0"
            ]);
            var launcher = new DetachedBuildLauncher(_ => TestProcess.PwshCommand(script));
            var launched = launcher.Start(launch);
            Pids.Add(launched.Pid);
            return launched;
        }
    }

    [Fact]
    public async Task A_quiet_test_run_that_writes_its_test_log_outlives_the_idle_timeout()
    {
        // 3 s of quiet are allowed, the run lasts 6 s: room for a slow pwsh start before its first write (the plan event).
        var launcher = new QuietTestLauncher(_checkout.Lane, 6, writeTestLog: true);
        var queue = Create(launcher: launcher, idleTimeout: TimeSpan.FromSeconds(3));

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded", "dotnet test writes only into the project's test log, and that counts as activity ({0})",
            done.Outcome?.Summary);
    }

    [Fact]
    public async Task A_test_log_write_after_the_cached_scan_keeps_the_run_alive()
    {
        // The throttled scan is never due again during the run: after the first scan every value is cached, so only the
        // forced scan before the idle decision sees the later writes (AB#9417).
        var launcher = new QuietTestLauncher(_checkout.Lane, 6, writeTestLog: true);
        var queue = Create(launcher: launcher, idleTimeout: TimeSpan.FromSeconds(3), testLogScanInterval: TimeSpan.FromHours(1));

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded", "the test log was written after the cached scan ({0})", done.Outcome?.Summary);
    }

    [Fact]
    public void The_test_log_scan_is_throttled_unless_forced()
    {
        var folder = Path.Combine(_checkout.Lane, "logFiles", "test-results", "octo-a");
        var activity = new BuildQueue.TestLogActivity(() => folder, DateTimeOffset.Now, TimeSpan.FromHours(1));

        activity.Last().Should().BeNull("nothing was written yet");

        var run = Path.Combine(folder, "A.Tests", "20261119-140000-000-1");
        Directory.CreateDirectory(run);
        File.WriteAllText(Path.Combine(run, "dotnet-test.log"), "  Passed A.Tests.X.One [3 ms]\n");

        activity.Last().Should().BeNull("the scan interval has not passed: the cached value counts");
        var forced = activity.Last(force: true);
        forced.Should().NotBeNull("a forced scan reads the folder now");
        activity.Last().Should().Be(forced, "the forced scan is the new cached value");
    }

    [Fact]
    public async Task A_really_silent_test_run_is_terminated_and_the_outcome_names_what_was_watched()
    {
        var launcher = new QuietTestLauncher(_checkout.Lane, 10, writeTestLog: false);
        var queue = Create(launcher: launcher, idleTimeout: TimeSpan.FromSeconds(1));

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.FailedStep.Should().Be("timeout");
        done.Outcome.Summary.Should().Be(
            $"no output, no test event and no write to the test logs under {Path.Combine(_checkout.Lane, "logFiles", "test-results", "octo-a")} " +
            "for 0 min; the test run was terminated", "the idle limit of this test is 1 s, printed in whole minutes");
    }

    [Fact]
    public async Task An_in_process_test_run_counts_its_test_log_writes_as_activity()
    {
        DateTimeOffset? activity = null;
        _fake.Build = (body, options, _) =>
        {
            Event(body, "plan", "\"repo\":\"octo-a\",\"environment\":null,\"projects\":[{\"project\":\"A.Tests\",\"docker\":false,\"noBuild\":true,\"skip\":false}],\"count\":1");
            var run = Path.Combine(_checkout.Lane, "logFiles", "test-results", "octo-a", "A.Tests", "20261119-140000-000-1");
            Directory.CreateDirectory(run);
            var log = Path.Combine(run, "dotnet-test.log");
            File.WriteAllText(log, "  Passed A.Tests.X.One [3 ms]\n");
            // Older than the events file: only the test log can make this the newest activity.
            File.SetLastWriteTime(FakePwsh.EventsFile(body)!, DateTime.Now.AddMinutes(-5));
            activity = options.LastActivity!(false);
            return Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun", Passed));
        };
        var queue = Create();

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        await WaitAsync(queue, job.Id);

        activity.Should().NotBeNull().And.BeCloseTo(DateTimeOffset.Now, TimeSpan.FromSeconds(30));
    }

    [Fact]
    public void Test_log_writes_are_read_from_the_run_folders_since_the_step_started_only()
    {
        var folder = Path.Combine(_checkout.Lane, "logFiles", "test-results", "octo-a");
        var since = DateTimeOffset.Now;

        BuildQueue.LastTestLogWrite(folder, since).Should().BeNull("there is no folder yet");

        var old = Path.Combine(folder, "A.Tests", "20261118-090000-000-1");
        Directory.CreateDirectory(old);
        File.WriteAllText(Path.Combine(old, "dotnet-test.log"), "x");
        File.SetLastWriteTime(Path.Combine(old, "dotnet-test.log"), DateTime.Now.AddHours(-1));
        Directory.SetLastWriteTime(old, DateTime.Now.AddHours(-1));
        Directory.SetCreationTime(old, DateTime.Now.AddHours(-1));
        BuildQueue.LastTestLogWrite(folder, since).Should().BeNull("a run folder of an earlier run does not count");

        var current = Path.Combine(folder, "B.Tests", "20261119-140000-000-1");
        Directory.CreateDirectory(current);
        File.WriteAllText(Path.Combine(current, "ng-test.log"), "y");
        BuildQueue.LastTestLogWrite(folder, since).Should().NotBeNull().And.BeOnOrAfter(since.AddSeconds(-2));
    }

    [Fact]
    public async Task The_test_lock_tool_returns_what_the_cmdlet_reports()
    {
        _fake.TestLock = """{"locked":true,"stale":false,"ownerAlive":true,"path":"/state/docker-tests.lock","owner":{"pid":4711,"lane":"/root/branches/main","environment":"ab8797","repo":"octo-b","heldSeconds":120}}""";
        var queue = Create();

        var lockState = await new TestTools(queue).Lock(Ct);

        lockState["locked"]!.GetValue<bool>().Should().BeTrue();
        lockState["owner"]!["lane"]!.GetValue<string>().Should().Be("ab8797", "octo-tools' environment is the lane");
        lockState["owner"]!["baseLane"]!.GetValue<string>().Should().Be("/root/branches/main", "octo-tools' lane is the base lane");
        lockState["owner"]!.AsObject().Select(p => p.Key).Should().Equal("pid", "baseLane", "lane", "repo", "heldSeconds");
        _fake.BuildCalls.Should().BeEmpty("reading the lock is no job");
    }

    // ---------- queue class ----------

    [Fact]
    public async Task A_test_run_shares_the_class_of_its_environment_and_is_not_counted_against_the_build_limit()
    {
        Env("ab1-one", "octo-a");
        Env("ab2-two", "octo-a");
        Env("ab3-three", "octo-a");
        var (release, started) = Block();
        var queue = Create();
        BuildRequest Build(string env) => new() { Owner = "b", Kind = BuildKind.Env, Environment = env };

        var buildOne = await queue.EnqueueAsync(Build("ab1-one"), Ct);
        var buildTwo = await queue.EnqueueAsync(Build("ab2-two"), Ct);
        await WaitAsync(queue, buildTwo.Id, s => s.State == "running");
        // Two environment builds run (the limit). A test run of a third environment starts next to them ...
        var testThree = await queue.EnqueueAsync(Tests("octo-a", "ab3-three"), Ct);
        await WaitAsync(queue, testThree.Id, s => s.State == "running");
        // ... a build of that environment waits for the limit, and a test run of a building environment waits for its build.
        var buildThree = await queue.EnqueueAsync(Build("ab3-three"), Ct);
        var testOne = await queue.EnqueueAsync(Tests("octo-a", "ab1-one"), Ct);
        await Task.Delay(150, Ct);

        queue.Get(buildThree.Id).State.Should().Be("queued");
        var waiting = queue.Get(testOne.Id);
        waiting.State.Should().Be("queued");
        waiting.Queue!.WaitingFor.Should().Contain("one build or test run per lane").And.Contain(buildOne.Id);
        queue.ActiveFor("ab1-one").Select(b => b.Id).Should().Equal(buildOne.Id, testOne.Id);
        lock (started)
        {
            started.Count(b => b.StartsWith("Invoke-OctoTestRun", StringComparison.Ordinal)).Should().Be(1);
        }

        release.SetResult();
        foreach (var id in new[] { buildOne.Id, buildTwo.Id, testThree.Id, buildThree.Id, testOne.Id })
        {
            (await WaitAsync(queue, id)).State.Should().Be("succeeded");
        }
    }

    /// <summary>An environment build of octo-a then octo-b (which depends on octo-a) that writes its events as the test lets it.</summary>
    private (TaskCompletionSource ADone, TaskCompletionSource Release, List<string> TestCalls) SteppedBuild()
    {
        var aDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var tests = new List<string>();
        _fake.Build = async (body, _, _) =>
        {
            if (body.StartsWith("Invoke-OctoTestRun", StringComparison.Ordinal))
            {
                lock (tests)
                {
                    tests.Add(body);
                }

                return FakePwsh.Ok("Invoke-OctoTestRun", Passed);
            }

            void Build(string name, string fields) => FakePwsh.Event(FakePwsh.EventsFile(body)!, "Invoke-BuildEnvironment", name, fields);
            Build("plan", "\"repos\":[{\"repo\":\"octo-a\",\"mode\":\"dotnet\",\"dependsOn\":[]},{\"repo\":\"octo-b\",\"mode\":\"dotnet\",\"dependsOn\":[\"octo-a\"]}],\"count\":2");
            Build("repoSkipped", "\"repo\":\"octo-b\",\"index\":2,\"count\":2,\"reason\":\"unchanged\"");
            Build("repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":2");
            await aDone.Task;
            Build("repoDone", "\"repo\":\"octo-a\",\"index\":1,\"count\":2,\"success\":true,\"seconds\":1");
            await release.Task;
            return FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        return (aDone, release, tests);
    }

    [Fact]
    public async Task A_test_of_a_repository_the_environment_build_is_through_with_starts_next_to_it_without_building()
    {
        Env("ab1-one", "octo-a", "octo-b");
        var (aDone, release, tests) = SteppedBuild();
        var queue = Create();
        var build = await queue.EnqueueAsync(new BuildRequest { Owner = "b", Kind = BuildKind.Env, Environment = "ab1-one" }, Ct);
        await WaitAsync(queue, build.Id, s => s.Progress?.Repos?.Any(r => r.State == "building") == true);

        // octo-b was skipped, but the build still works on octo-a, which octo-b depends on: its test waits.
        var test = await queue.EnqueueAsync(Tests("octo-b", "ab1-one"), Ct);
        await Task.Delay(200, Ct);
        var waiting = queue.Get(test.Id);
        waiting.State.Should().Be("queued");
        waiting.Queue!.WaitingFor.Should().Contain("one build or test run per lane").And.Contain(build.Id).And.NotContain("cannot start next to");
        _fake.Calls.Should().NotContain(c => c.Body.Contains("Invoke-OctoTestRun") && c.Body.Contains("-WhatIf"), "the cmdlet is asked only once the build is through with the repository");

        // octo-a is done: the test starts while the build goes on, and builds nothing.
        aDone.SetResult();
        var done = await WaitAsync(queue, test.Id);

        done.State.Should().Be("succeeded");
        queue.Get(build.Id).State.Should().Be("running");
        done.Notes.Should().Contain(n => n.StartsWith($"Started while build {build.Id} of the lane still runs") && n.Contains("-build Never"));
        lock (tests)
        {
            tests.Single().Should().StartWith("Invoke-OctoTestRun -env 'ab1-one' -repo 'octo-b' -build Never -Json");
        }

        // A second job of the environment waits as before (the build and nothing else may have company).
        release.SetResult();
        (await WaitAsync(queue, build.Id)).State.Should().Be("succeeded");
    }

    [Fact]
    public async Task A_test_that_would_build_waits_for_the_environment_build_and_says_why()
    {
        Env("ab1-one", "octo-a", "octo-b");
        var (aDone, release, tests) = SteppedBuild();
        _fake.TestPlan = """{"whatIf":true,"projects":[{"project":"A.Tests","docker":false,"noBuild":false,"buildReason":"no build output (bin/DebugL/net10.0/A.Tests.dll)","skip":null},{"project":"B.Tests","noBuild":true,"skip":null}]}""";
        var queue = Create(probeRetry: TimeSpan.FromMilliseconds(100));
        var build = await queue.EnqueueAsync(new BuildRequest { Owner = "b", Kind = BuildKind.Env, Environment = "ab1-one" }, Ct);
        await WaitAsync(queue, build.Id, s => s.Progress?.Repos?.Any(r => r.State == "building") == true);
        aDone.SetResult();

        var test = await queue.EnqueueAsync(Tests("octo-a", "ab1-one"), Ct);
        var waiting = await WaitAsync(queue, test.Id, s => s.Queue?.WaitingFor?.Contains("cannot start next to") == true);

        waiting.State.Should().Be("queued");
        waiting.Queue!.WaitingFor.Should().Contain(build.Id)
            .And.Contain("needs a build of A.Tests: no build output (bin/DebugL/net10.0/A.Tests.dll); pass verifyTests=true to lane_build to have test projects compiled");
        lock (tests)
        {
            tests.Should().BeEmpty();
        }

        // Asked again later (the developer compiled the tests meanwhile): now it may start.
        _fake.TestPlan = """{"whatIf":true,"projects":[{"project":"A.Tests","noBuild":true,"skip":null},{"project":"Old.Tests","noBuild":false,"skip":"no test of the filter"},{"project":"M.Tests","runner":"mtp","noBuild":false,"skip":null,"noMatch":"its runner takes a tree filter"}]}""";
        (await WaitAsync(queue, test.Id)).State.Should().Be("succeeded");
        queue.Get(build.Id).State.Should().Be("running");

        release.SetResult();
        (await WaitAsync(queue, build.Id)).State.Should().Be("succeeded");
    }

    [Fact]
    public async Task Test_runs_of_one_lane_run_one_after_the_other_and_a_lane_build_waits_for_them()
    {
        Env("ab1-one", "octo-a");
        var (release, started) = Block();
        var queue = Create();

        var first = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        await WaitAsync(queue, first.Id, s => s.State == "running");
        var second = await queue.EnqueueAsync(Tests("octo-b", owner: "s2"), Ct);
        // Another class: an environment's test run starts next to the lane's.
        var env = await queue.EnqueueAsync(Tests("octo-a", "ab1-one", "s3"), Ct);
        await WaitAsync(queue, env.Id, s => s.State == "running");
        var build = await queue.EnqueueAsync(new BuildRequest { Owner = "s4", Kind = BuildKind.Repo, Path = "octo-b" }, Ct);

        var waiting = queue.Get(second.Id);
        waiting.State.Should().Be("queued");
        waiting.Queue!.WaitingFor.Should().Contain("one test run of branches/main at a time").And.Contain(first.Id);
        queue.Get(build.Id).Queue!.WaitingFor.Should().Contain("a base lane build runs alone");

        release.SetResult();
        foreach (var id in new[] { first.Id, second.Id, env.Id, build.Id })
        {
            (await WaitAsync(queue, id)).State.Should().Be("succeeded");
        }

        lock (started)
        {
            started.Select(FakePwsh.Command).Should().Equal("Invoke-OctoTestRun", "Invoke-OctoTestRun", "Invoke-OctoTestRun", "Invoke-Build");
        }
    }

    [Fact]
    public async Task The_same_test_run_asked_for_again_returns_the_job_that_waits_or_runs()
    {
        var (release, started) = Block();
        var queue = Create();
        BuildRequest Request(string owner = "s1", string? filter = "Orders") => new()
        {
            Owner = owner, Kind = BuildKind.Test, Repo = "octo-a", Projects = ["B.Tests", "A.Tests"], Filter = filter
        };

        var first = await queue.EnqueueAsync(Request(), Ct);
        await WaitAsync(queue, first.Id, s => s.State == "running");
        // The same request, written a little differently.
        var again = await queue.EnqueueAsync(Request() with { Owner = " S1 ", Repo = "Octo-A ", Projects = ["a.tests", "B.Tests"] }, Ct);

        again.Id.Should().Be(first.Id);
        again.Notes.Should().ContainSingle(n => n.Contains($"already running as {first.Id}") && n.Contains("no second run was added"));
        queue.Get(first.Id).Notes.Should().BeEmpty("the note belongs to the answer, not to the job");

        // Another owner, another filter or another mode is another run.
        var other = await queue.EnqueueAsync(Request("s2"), Ct);
        var filtered = await queue.EnqueueAsync(Request(filter: "Billing"), Ct);
        var rerun = await queue.EnqueueAsync(Request() with { RerunFailed = true }, Ct);
        new[] { other.Id, filtered.Id, rerun.Id }.Should().OnlyHaveUniqueItems().And.NotContain(first.Id);
        // A queued one is recognised too.
        (await queue.EnqueueAsync(Request("s2"), Ct)).Id.Should().Be(other.Id);

        release.SetResult();
        foreach (var id in new[] { first.Id, other.Id, filtered.Id, rerun.Id })
        {
            await WaitAsync(queue, id);
        }

        // Once it ended, the same request is a new run.
        var fresh = await queue.EnqueueAsync(Request(), Ct);
        fresh.Id.Should().NotBe(first.Id);
        await WaitAsync(queue, fresh.Id);
        lock (started)
        {
            started.Should().HaveCount(5);
        }
    }

    // ---------- services that run from the tested repository ----------

    private async Task<int> StartAsync(string owner, params string[] services)
    {
        await Supervisor.StartStackAsync(owner, new StartSpec { Services = [..services] }, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        return (await Supervisor.StatusAsync(false)).Services.Single(s => s.Name == services[0]).Pid;
    }

    private async Task<ServiceStatus> ServiceAsync(string name) => (await Supervisor.StatusAsync(false)).Services.Single(s => s.Name == name);

    private const string FailedRun =
        """{"success":false,"exitCode":1,"failedStep":"tests","failedProject":"A.Tests","projects":[{"project":"A.Tests","state":"failed","success":false,"total":1,"passed":0,"failed":1,"skipped":0,"durationSeconds":1,"failedTests":[{"name":"A.Tests.X","message":"boom"}]}]}""";

    [Fact]
    public async Task A_base_test_stops_the_shared_stacks_services_of_the_tested_repository_and_starts_them_again_after_a_failed_run()
    {
        var queue = Create();
        var alphaPid = await StartAsync("s1", "alpha", "beta");
        var betaPid = (await ServiceAsync("beta")).Pid;
        ServiceStatus? during = null;
        string? guard = null;
        _fake.Build = async (_, _, _) =>
        {
            during = await ServiceAsync("alpha");
            try
            {
                await Supervisor.StartServicesAsync("s1", ["alpha"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);
            }
            catch (InvalidOperationException e)
            {
                guard = e.Message;
            }

            return FakePwsh.Ok("Invoke-OctoTestRun", FailedRun, exitCode: 1);
        };

        var queued = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        var done = await WaitAsync(queue, queued.Id);

        queued.StoppedServices.Should().Equal(["alpha"], "the answer names what the run is going to stop");
        queued.Notes.Should().Contain(n => n.StartsWith("The run stops alpha of the shared stack first") && n.Contains("MSB3027"));
        during!.State.Should().Be("stopped-for-build", "the tests ran while alpha was stopped");
        guard.Should().Contain("alpha runs out of").And.Contain(queued.Id, "nothing starts from the tested repository while the run goes on")
            .And.Contain($"which job {queued.Id} (a test run of s1:").And.Contain($"job_status(\"{queued.Id}\", waitSeconds=600)").And.NotContain("which build");
        done.State.Should().Be("failed");
        done.StoppedServices.Should().Equal("alpha");
        done.Notes.Should().Contain("restarted alpha", "a test run starts the services again whatever its result");
        var alpha = await ServiceAsync("alpha");
        alpha.Pid.Should().NotBe(alphaPid);
        alpha.State.Should().NotBe("stopped-for-build");
        alpha.RepoPath.Should().Be(Path.Combine(_checkout.Lane, "octo-a"));
        (await ServiceAsync("beta")).Pid.Should().Be(betaPid, "beta runs from another repository");
        Supervisor.Leases.Default.Current()!.Owner.Should().Be("s1");
    }

    [Fact]
    public async Task A_canceled_test_run_starts_the_services_it_stopped_again()
    {
        var queue = Create();
        await StartAsync("s1", "alpha");
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (_, _, ct) =>
        {
            started.TrySetResult();
            try
            {
                await Task.Delay(Timeout.Infinite, ct);
            }
            catch (OperationCanceledException)
            {
                // The daemon's cancel ends the run.
            }

            return new PwshResult(-1, "", false, true);
        };

        var job = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(20), Ct);
        (await ServiceAsync("alpha")).State.Should().Be("stopped-for-build");
        queue.Cancel(job.Id, "s1");
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("canceled");
        done.Notes.Should().Contain("restarted alpha");
        (await ServiceAsync("alpha")).State.Should().NotBe("stopped-for-build");
    }

    [Fact]
    public async Task A_test_run_that_must_stop_services_of_a_stack_another_session_holds_is_refused_naming_them_and_the_holder()
    {
        var queue = Create();
        await StartAsync("s2", "alpha");
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun", Passed));

        var run = () => queue.EnqueueAsync(Tests("octo-a", owner: "s1"), Ct);

        var refused = await run.Should().ThrowAsync<LeaseHeldException>();
        refused.Which.Message.Should().StartWith("Test run of octo-a refused, nothing was queued: it must stop alpha of the shared stack first")
            .And.Contain("MSB3027").And.Contain("held by 's2'");
        queue.List().Should().BeEmpty();
        _fake.BuildCalls.Should().BeEmpty();
        (await ServiceAsync("alpha")).State.Should().NotBe("stopped-for-build");

        // A repository nothing runs from needs no lease.
        var other = await WaitAsync(queue, (await queue.EnqueueAsync(Tests("octo-b", owner: "s1"), Ct)).Id);
        other.State.Should().Be("succeeded");
        other.StoppedServices.Should().BeEmpty();
        Supervisor.Leases.Default.Current()!.Owner.Should().Be("s2");
    }

    [Fact]
    public async Task A_lane_test_stops_the_lanes_service_in_the_shared_stack_with_the_callers_lease_or_is_refused_with_the_way_out()
    {
        var queue = Create();
        Env("ab1-one", "octo-a");
        var laneRepo = Path.Combine(_checkout.Root, "wt-ab1-one", "octo-a");
        // UC-A: s2 runs the lane's build of alpha in the shared stack.
        using (LeaseSession.Use("meshmakers-08", "s2"))
        {
            await Supervisor.StartStackAsync("s2", new StartSpec
            {
                Services = ["alpha", "beta"], Overrides = new Dictionary<string, ServiceOverride> { ["alpha"] = new() { Source = "lane:ab1-one" } }
            }, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        }

        (await ServiceAsync("alpha")).RepoPath.Should().Be(laneRepo);
        ServiceStatus? during = null;
        _fake.Build = async (_, _, _) =>
        {
            during = await ServiceAsync("alpha");
            return FakePwsh.Ok("Invoke-OctoTestRun", Passed);
        };

        // Another session holds the shared stack: refused before a job exists, with the services, the holder and the way out.
        var run = () => queue.EnqueueAsync(Tests("octo-a", "ab1-one", owner: "s1"), Ct);
        var refused = await run.Should().ThrowAsync<LeaseHeldException>();
        refused.Which.Message.Should().StartWith("Test run of octo-a refused, nothing was queued: it must stop alpha of the shared stack first")
            .And.Contain("MSB3027").And.Contain("held by 's2' (session meshmakers-08)")
            .And.Contain("service_restart(owner, session, services=[\"alpha\"], overrides={\"alpha\": {}})").And.Contain("lease_acquire(owner, session, waitSeconds)");
        queue.List().Should().BeEmpty();
        _fake.BuildCalls.Should().BeEmpty();
        (await ServiceAsync("alpha")).State.Should().NotBe("stopped-for-build");

        // The shared stack's lease is free: the run takes it for the caller (not for the lane), stops alpha and starts it again from the lane.
        Supervisor.Leases.Default.Release("s2", false);
        var queued = await queue.EnqueueAsync(Tests("octo-a", "ab1-one", owner: "s1"), Ct);
        var done = await WaitAsync(queue, queued.Id);

        queued.Notes.Should().Contain(n => n.StartsWith("The run stops alpha of the shared stack first (with the shared stack's lease of the caller"));
        during!.State.Should().Be("stopped-for-build", "the tests ran while the shared stack's alpha was stopped");
        done.State.Should().Be("succeeded");
        done.StoppedServices.Should().Equal("alpha");
        done.Notes.Should().Contain("restarted alpha");
        var alpha = await ServiceAsync("alpha");
        alpha.State.Should().NotBe("stopped-for-build");
        alpha.RepoPath.Should().Be(laneRepo, "it runs the lane's build again");
        Supervisor.Leases.Default.Current()!.Owner.Should().Be("s1", "the shared stack's lease is the caller's, never the lane's");
        Supervisor.Leases.Get("ab1-one").Current().Should().BeNull("the lane stack was not touched");
    }

    [Fact]
    public async Task A_service_that_started_while_the_test_run_waited_is_stopped_when_it_starts()
    {
        var (release, _) = Block();
        var queue = Create();
        var first = await queue.EnqueueAsync(Tests("octo-b"), Ct);
        await WaitAsync(queue, first.Id, s => s.State == "running");
        var second = await queue.EnqueueAsync(Tests("octo-a"), Ct);
        second.StoppedServices.Should().BeEmpty("nothing ran from octo-a when it was queued");

        await StartAsync("s1", "alpha");
        release.SetResult();
        var done = await WaitAsync(queue, second.Id);

        done.State.Should().Be("succeeded");
        done.StoppedServices.Should().Equal("alpha");
        done.Notes.Should().Contain("restarted alpha");
    }

    // ---------- restart ----------

    [Fact]
    public async Task The_tests_of_a_finished_run_are_still_there_after_a_daemon_restart()
    {
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
            """{"success":false,"exitCode":1,"failedStep":"tests","failedProject":"A.Tests","projects":[{"project":"A.Tests","state":"failed","success":false,"total":2,"passed":1,"failed":1,"skipped":0,"durationSeconds":1,"failedTests":[{"name":"A.Tests.X.Y","message":"boom","stackFrame":"at A.Tests.X.Y()"}],"errors":[]}]}""",
            exitCode: 1));
        var first = Create();
        var job = await first.EnqueueAsync(Tests("octo-a"), Ct);
        var before = await WaitAsync(first, job.Id);
        first.Abandon();

        var after = Create().Get(job.Id);

        after.Tests.Should().BeEquivalentTo(before.Tests);
        after.Tests!.Projects.Single().FailedTests.Single().Should().Be(new BuildFailedTest("A.Tests.X.Y", "boom", "at A.Tests.X.Y()"));
        after.Outcome!.Summary.Should().Be("1 of 2 test(s) failed in A.Tests");
        after.Kind.Should().Be("test");
    }

    [Fact]
    public async Task A_frontend_project_named_by_its_dotted_path_is_selected_and_keeps_its_log()
    {
        var log = Path.Combine(_checkout.Root, "ng-test.log");
        _fake.Build = (body, _, _) =>
        {
            File.WriteAllText(log, "Test Files  1 failed\n");
            Event(body, "testProjectDone", $"\"repo\":\"my-app\",\"project\":\"apps.web\",\"index\":1,\"count\":2,\"success\":false,\"state\":\"failed\",\"total\":2,\"passed\":1,\"failed\":1,\"skipped\":0,\"seconds\":3,\"trx\":[],\"logFile\":{JsonSerializer.Serialize(log)}");
            return Task.FromResult(FakePwsh.Ok("Invoke-OctoTestRun",
                """{"success":false,"exitCode":1,"failedStep":"tests","failedProject":"apps.web","projects":[{"project":"apps.web","state":"failed","success":false,"total":2,"passed":1,"failed":1,"skipped":0,"durationSeconds":3,"failedTests":[{"name":"src/app/a.spec.ts :: A > works","message":"expected 1 to be 2","stackFrame":"src/app/a.spec.ts:7:3"}]},{"project":"tools.web","state":"passed","success":true,"total":1,"passed":1,"failed":0,"skipped":0,"durationSeconds":1,"failedTests":[]}]}""",
                exitCode: 1));
        };
        var queue = Create();

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Test, Repo = "octo-a", Projects = ["apps.web"] }, Ct)).Id);

        _fake.BuildCalls.Single().Should().Contain("-project 'apps.web'");
        done.Tests!.Projects.Select(p => p.Project).Should().Equal("apps.web", "tools.web");
        queue.Get(done.Id, "APPS.WEB").Tests!.Projects.Single().FailedTests.Single().Name.Should().Be("src/app/a.spec.ts :: A > works");
        queue.Output(done.Id, "apps.web").Log.Should().BeEquivalentTo(new { Selected = "apps.web", Source = "kept" });
        Path.GetFileName(done.Logs.PerRepo!["apps.web"]).Should().Be($"{done.Id}.apps.web.log");
    }
}
