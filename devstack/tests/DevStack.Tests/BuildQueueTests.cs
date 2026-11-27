using System.Diagnostics;
using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The build queue against <see cref="FakePwsh"/>: no octo-tools, no dotnet, no real lane or NuGet folder. Services are
///     sleeping pwsh processes (Start-Sleep) in a temp lane.
/// </summary>
internal static class BuildQueueTestExtensions
{
    public static Task<BuildStatus> Enqueue(this BuildQueue queue, BuildRequest request) => queue.EnqueueAsync(request, TestContext.Current.CancellationToken);

    public static Task<BuildPlanResult> Plan(this BuildQueue queue, BuildRequest request) => queue.PlanAsync(request, TestContext.Current.CancellationToken);
}

public sealed class BuildQueueTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly FakePwsh _fake = new();
    private readonly List<Process> _processes = [];
    private ExternalSnapshot _external = ExternalSnapshot.Empty;

    public void Dispose()
    {
        foreach (var p in _processes.Where(p => !p.HasExited))
        {
            p.Kill();
        }

        _checkout.Dispose();
    }


    private const string Services = """
                                      sleeper:
                                        repo: octo-a
                                        workingDirectory: .
                                        command: pwsh
                                        args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                    """;

    private (BuildQueue Queue, StackSupervisor Supervisor, LeaseManager Lease, StateStore State) Create(string services = Services, string extra = "",
        BuildQueueOptions? options = null)
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig(services, extra);
        var lease = new LeaseManager();
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var state = new StateStore(paths);
        state.Load();
        var supervisor = new StackSupervisor(store, lease, state, NullLogger<StackSupervisor>.Instance);
        var queue = new BuildQueue(store, supervisor, lease, paths, NullLogger<BuildQueue>.Instance, _fake, state, null,
            options ?? new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50) }, () => Task.FromResult(_external));
        return (queue, supervisor, lease, state);
    }

    private static async Task<BuildStatus> WaitAsync(BuildQueue queue, string id, Func<BuildStatus, bool>? until = null)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (true)
        {
            var status = queue.Get(id);
            if (until?.Invoke(status) ?? status.Times.FinishedAt != null)
            {
                return status;
            }

            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException($"build {id} stays {status.State}");
            }

            await Task.Delay(20);
        }
    }

    private Process Sleep()
    {
        var p = TestProcess.StartSleep(30);
        _processes.Add(p);
        return p;
    }

    [Fact]
    public void A_repo_reported_done_in_which_nothing_could_be_built_is_skipped_and_names_the_repo_that_built_it()
    {
        var libraries = _checkout.Repo("octo-frontend-libraries"); // no solution, no build.ps1: octo-tools says "No solution file found"
        var studio = _checkout.Repo("octo-frontend-refinery-studio");
        File.WriteAllText(Path.Combine(studio, "build.ps1"), "Push-Location ../octo-frontend-libraries; npm run build; Pop-Location");
        var service = _checkout.Repo("octo-a");
        File.WriteAllText(Path.Combine(service, "octo-a.sln"), "");
        var lonely = _checkout.Repo("octo-docs");
        File.Delete(Path.Combine(libraries, "octo-frontend-libraries.sln"));
        File.Delete(Path.Combine(lonely, "octo-docs.sln"));
        var events = new StepEvents();
        foreach (var name in new[] { "octo-frontend-libraries", "octo-frontend-refinery-studio", "octo-a", "octo-docs" })
        {
            events.Repo(name).State = "done";
        }

        var spec = new StepSpec
        {
            Kind = BuildKind.All, Target = "all", Script = "Invoke-BuildAll", HistoryLane = "", Timeout = TimeSpan.FromHours(1),
            Repos = [new PlanRepo("octo-frontend-libraries", "dotnet", libraries), new PlanRepo("octo-frontend-refinery-studio", "script", studio),
                new PlanRepo("octo-a", "dotnet", service), new PlanRepo("octo-docs", "none", lonely)]
        };

        BuildQueue.MarkNothingBuilt(events, spec);

        events.Repo("octo-frontend-libraries").Should().Match<RepoRun>(r => r.State == "skipped" && r.Reason == "nothingToBuild" &&
                                                                            r.Detail == "built by octo-frontend-refinery-studio (its build.ps1 builds ../octo-frontend-libraries)");
        events.Repo("octo-docs").Should().Match<RepoRun>(r => r.State == "skipped" && r.Detail!.Contains("nothing was built"));
        events.Repo("octo-frontend-refinery-studio").State.Should().Be("done");
        events.Repo("octo-a").State.Should().Be("done");

        // A builder that failed built nothing: no "built by".
        var failed = new StepEvents();
        failed.Repo("octo-frontend-libraries").State = "done";
        failed.Repo("octo-frontend-refinery-studio").State = "failed";
        BuildQueue.MarkNothingBuilt(failed, spec);
        failed.Repo("octo-frontend-libraries").Detail.Should().Contain("nothing was built");
    }

    // ---------- job_status(waitSeconds) ----------

    [Fact]
    public async Task Job_status_says_when_the_external_scan_failed_and_the_job_ran_without_it()
    {
        // AB#9556: the scan of processes outside octo-devstack failed (ExternalDetector.ScanAsync turns that into a warning).
        var (queue, _, _, _) = Create();
        _external = ExternalSnapshot.Empty with
        {
            Warning = "Processes outside octo-devstack are unknown: the scan failed (ArgumentException: An item with the same key has already been added. Key: 10444)."
        };
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0,"logFile":"/x"}"""));
        var tools = new Tools.BuildTools(queue);

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await tools.Status(job.Id, waitSeconds: 30, cancellationToken: TestContext.Current.CancellationToken);

        done.State.Should().Be("succeeded", "the failed scan does not fail the job");
        done.Notes.Should().ContainSingle(n => n.StartsWith("Processes outside octo-devstack are unknown: the scan failed", StringComparison.Ordinal) &&
                                               n.Contains("Key: 10444") && n.EndsWith("The job runs without that check.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task Job_status_names_the_processes_the_external_scan_left_out_and_the_job_ran_without_checking_them()
    {
        // AB#9924: the scan left out processes it could not analyse; the others are known, so there is no scan warning.
        var (queue, _, _, _) = Create();
        _external = ExternalSnapshot.Empty with { Skipped = [new ExternalSkipped(22832, "zenDBSrv.exe", "ArgumentException"), new ExternalSkipped(901, "probe.exe", "IOException")] };
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0,"logFile":"/x"}"""));
        var tools = new Tools.BuildTools(queue);

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await tools.Status(job.Id, waitSeconds: 30, cancellationToken: TestContext.Current.CancellationToken);

        done.State.Should().Be("succeeded");
        done.Notes.Should().ContainSingle(n => n.Contains("pid 22832 (zenDBSrv.exe, ArgumentException)") && n.Contains("pid 901 (probe.exe, IOException)") &&
                                               n.EndsWith("The job runs without checking them.", StringComparison.Ordinal),
            "the plan names each process left out once, though the conflicts are checked again right before the job runs");
    }

    [Fact]
    public async Task The_plan_warning_of_processes_left_out_carries_no_part_of_their_arguments()
    {
        // AB#9924: command lines whose program, read as one token, would carry an argument (WindowsSupportTests has the shapes).
        var (queue, _, _, _) = Create();
        var commands = WindowsSupportTests.MarkerCommandLines;
        _external = ExternalSnapshot.Empty with
        {
            Skipped = commands.Select((c, i) => ExternalDetector.Skip(new ExternalDetector.PsRow(910 + i, 0, TimeSpan.Zero, c), new IOException("x"))).ToList()
        };
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0,"logFile":"/x"}"""));
        var tools = new Tools.BuildTools(queue);

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await tools.Status(job.Id, waitSeconds: 30, cancellationToken: TestContext.Current.CancellationToken);

        var warning = done.Notes.Should().ContainSingle(n => n.StartsWith("The scan of processes outside octo-devstack left out", StringComparison.Ordinal)).Subject;
        warning.Should().Contain("pid 910 (prog.exe, IOException)").And.Contain($"pid {909 + commands.Length} (prog.exe, IOException)").And.NotContain("MARKER");
    }

    [Fact]
    public async Task Job_status_waits_until_the_job_ends_or_the_time_is_up()
    {
        var (queue, _, _, _) = Create();
        var release = new TaskCompletionSource();
        _fake.Build = async (_, _, _) =>
        {
            await release.Task;
            return FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0,"logFile":"/x"}""");
        };
        var tools = new Tools.BuildTools(queue);
        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });

        (await tools.Status(job.Id, cancellationToken: TestContext.Current.CancellationToken)).TimedOut.Should().BeNull("without waitSeconds it answers at once");
        var started = DateTime.UtcNow;
        var timedOut = await tools.Status(job.Id, waitSeconds: 1, cancellationToken: TestContext.Current.CancellationToken);
        timedOut.TimedOut.Should().BeTrue();
        BuildStatus.IsFinal(timedOut.State).Should().BeFalse();
        (DateTime.UtcNow - started).Should().BeGreaterThan(TimeSpan.FromMilliseconds(900));

        var waiting = tools.Status(job.Id, waitSeconds: 60, errorsOnly: true, cancellationToken: TestContext.Current.CancellationToken);
        release.SetResult();
        var done = await waiting;
        done.TimedOut.Should().BeFalse();
        done.State.Should().Be("succeeded");
        done.Progress.Should().BeNull("the answer is the normal one for the given arguments (errorsOnly)");

        var unknown = () => tools.Status("b0-nope", waitSeconds: 5, cancellationToken: TestContext.Current.CancellationToken);
        await unknown.Should().ThrowAsync<ModelContextProtocol.McpException>().WithMessage("Unknown job 'b0-nope'*job_list*");
    }

    // ---------- repo builds ----------

    [Fact]
    public async Task A_repo_build_follows_the_events_file_and_records_its_duration()
    {
        var (queue, _, _, _) = Create();
        _fake.Build = (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-Build", "plan", """ "repos":[{"repo":"octo-a","mode":"dotnet"}],"count":1 """.Trim());
            FakePwsh.Event(events, "Invoke-Build", "repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":1");
            FakePwsh.Event(events, "Invoke-Build", "repoDone",
                "\"repo\":\"octo-a\",\"index\":1,\"count\":1,\"success\":true,\"seconds\":12.3,\"buildSeconds\":12,\"testSeconds\":0,\"packageSeconds\":0,\"copied\":0,\"purged\":0,\"logFile\":null");
            FakePwsh.Event(events, "Invoke-Build", "done", "\"success\":true,\"failedRepo\":null,\"failedStep\":null,\"elapsedSeconds\":12.4");
            return Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0,"logFile":"/x"}"""));
        };

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded");
        done.Success.Should().BeTrue();
        done.Progress!.Source.Should().Be("events");
        done.Progress.Repos.Should().ContainSingle().Which.Should().Be(new BuildRepoProgress("octo-a", "done", 12, 0, 0, 0, 12.3, 0, Tests: "compiled"));
        done.Progress.Totals.Should().Be(new BuildPhaseSeconds(12, 0, 0, null));
        done.Times.StartedAt!.Value.Offset.Should().Be(DateTimeOffset.Now.Offset, "times are local");
        _fake.BuildCalls.Single().Should().StartWith($"Invoke-Build -repositoryPath '{Path.Combine(_checkout.Lane, "octo-a")}' -configuration 'DebugL' -Json -EventsFile ");
        new BuildHistory(new DevStackPaths(_checkout.StateDirectory)).Estimate(_checkout.Lane, "octo-a", "DebugL").Should().Be(12.3);
        JsonSerializer.Serialize(done, JsonSerializerOptions.Web).Length.Should().BeLessThan(2048);
    }

    [Fact]
    public async Task A_failed_repo_build_snapshots_the_errors_of_its_log()
    {
        var (queue, _, _, _) = Create();
        var repo = Path.Combine(_checkout.Lane, "octo-a");
        _fake.Build = (_, _, _) =>
        {
            File.WriteAllText(Path.Combine(repo, "Invoke-Build.log"),
                $"{repo}/src/X.cs(3,9): error CS0246: The type or namespace name 'Foo' could not be found [{repo}/src/X.csproj]\n" +
                $"{repo}/src/X.cs(3,9): error CS0246: The type or namespace name 'Foo' could not be found [{repo}/src/X.csproj]\n    1 Error(s)\n");
            return Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":false,"exitCode":1}"""));
        };

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await WaitAsync(queue, job.Id);
        File.Delete(Path.Combine(repo, "Invoke-Build.log")); // the next build deletes it; the job keeps its copy

        done.State.Should().Be("failed");
        done.Outcome!.FailedRepo.Should().Be("octo-a");
        done.Outcome.Hint.Should().Contain("repo=");
        done.Diagnostics!.ErrorCount.Should().Be(1);
        done.Diagnostics.Errors.Should().ContainSingle().Which.Code.Should().Be("CS0246");
        File.Exists(done.Logs.PerRepo!["octo-a"]).Should().BeTrue();
        done.Logs.PerRepo["octo-a"].Should().StartWith(_checkout.StateDirectory);
        queue.Get(job.Id, repo: "octo-a").Diagnostics!.Errors.Should().ContainSingle();
        queue.Get(job.Id).Raw.Should().BeNull("raw needs include=['raw']");
    }

    [Fact]
    public async Task Success_needs_the_json_success_and_exit_code_zero()
    {
        var (queue, _, _, _) = Create();
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0}""", exitCode: 1));

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.Summary.Should().Contain("exited with 1");
        queue.Get(job.Id, raw: true).Raw!.Results.Should().ContainSingle();
    }

    [Fact]
    public async Task Without_events_support_progress_comes_from_the_logs()
    {
        _fake.Capabilities = FakePwsh.MainParams;
        var (queue, _, _, _) = Create();
        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().NotContain("-EventsFile");
        done.Progress!.Source.Should().Be("logs");
        done.State.Should().Be("succeeded");
    }

    [Fact]
    public async Task An_idle_build_reports_the_idle_timeout()
    {
        var (queue, _, _, _) = Create();
        _fake.Build = (_, options, _) =>
        {
            options.IdleTimeout.Should().Be(TimeSpan.FromMinutes(20));
            options.Timeout.Should().Be(TimeSpan.FromMinutes(45));
            return Task.FromResult(new PwshResult(-1, "", false, false, IdleTimedOut: true));
        };

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        var done = await WaitAsync(queue, job.Id);

        done.Outcome!.FailedStep.Should().Be("timeout");
        done.Outcome.Summary.Should().Contain("no output");
    }

    // ---------- build mode of a repo (AB#9417) ----------

    [Fact]
    public async Task A_repo_with_a_build_script_is_built_with_it_like_Invoke_BuildAll_does()
    {
        var (queue, _, _, _) = Create();
        var studio = Path.Combine(_checkout.Lane, "octo-frontend-refinery-studio");
        Directory.CreateDirectory(studio);
        File.WriteAllText(Path.Combine(studio, "build.ps1"), "exit 0");
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok(BuildPlanner.RepoScriptCommand, """{"success":true,"exitCode":0,"mode":"script"}"""));

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-refinery-studio" });
        plan.Steps.Single().Repos.Single().Mode.Should().Be("script", "build_plan shows the mode");

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-refinery-studio" });
        var done = await WaitAsync(queue, job.Id);

        var call = _fake.BuildCalls.Single();
        call.Should().Contain($"& {PwshRunner.Quote(Path.Combine(studio, "build.ps1"))} -configuration 'DebugL'").And.NotContain("Invoke-Build ")
            .And.NotContain("-EventsFile", "only Invoke-Build writes build events");
        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be("octo-frontend-refinery-studio built (mode script)");
    }

    /// <summary>
    ///     AB#9464 (macOS, daemon under the LaunchAgent): the studio's build.ps1 failed in the libraries' prebuild
    ///     (TELERIK_LICENSE not set), and build_status showed MSB1003 from an Invoke-Build.log an earlier Invoke-Build of
    ///     the repo had left behind. The failed step's own output is the cause.
    /// </summary>
    [Theory]
    [InlineData(-86400)]
    [InlineData(0)]
    public async Task A_failed_build_script_reports_its_own_error_not_an_old_Invoke_Build_log(int logAgeSeconds)
    {
        var (queue, _, _, _) = Create();
        var studio = Path.Combine(_checkout.Lane, "octo-frontend-refinery-studio");
        Directory.CreateDirectory(studio);
        File.WriteAllText(Path.Combine(studio, "build.ps1"), "exit 1");
        var stale = Path.Combine(studio, "Invoke-Build.log");
        File.WriteAllText(stale, "MSBUILD : error MSB1003: Specify a project or solution file. The current working directory does not contain a project or solution file.\n");
        // A day old, or written just before this step (a quick retry): a build.ps1 step never writes it, so it is never this build's.
        File.SetLastWriteTime(stale, DateTime.Now.AddSeconds(logAgeSeconds));
        const string output = "> prebuild\n> npm run setup-license\n" +
                              "\u001b[31m╔════════════════════════════════════════════════════════════════╗\u001b[0m\n" +
                              "\u001b[31m║  ERROR: TELERIK_LICENSE environment variable is not set!       ║\u001b[0m\n" +
                              "\u001b[31m║  3. Add it to your shell profile (~/.zshrc or ~/.bashrc)       ║\u001b[0m\n" +
                              "\u001b[31m╚════════════════════════════════════════════════════════════════╝\u001b[0m\n" +
                              "npm error Lifecycle script `prebuild` failed with error:\nnpm error code 1\n";
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok(BuildPlanner.RepoScriptCommand,
            """{"success":false,"exitCode":1,"mode":"script","detail":"build.ps1"}""", exitCode: 1, before: output));

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-refinery-studio" });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.Summary.Should().Be("build failed in octo-frontend-refinery-studio (build): ERROR: TELERIK_LICENSE environment variable is not set!");
        var errors = queue.Get(job.Id, repo: "octo-frontend-refinery-studio").Diagnostics!.Errors;
        errors.Select(e => e.Message).Should().Equal("ERROR: TELERIK_LICENSE environment variable is not set!",
            "npm error Lifecycle script `prebuild` failed with error:", "npm error code 1");
        errors.Should().OnlyContain(e => e.Code == "script", "the step's own output, not the old dotnet log");
    }

    [Fact]
    public async Task A_running_build_script_step_shows_no_progress_from_an_old_Invoke_Build_log()
    {
        // The live read of a step without events: a build.ps1 step writes no Invoke-Build.log, so one written just before
        // it started (an earlier Invoke-Build) is never shown as this step's progress.
        var (queue, _, _, _) = Create();
        var studio = Path.Combine(_checkout.Lane, "octo-frontend-refinery-studio");
        Directory.CreateDirectory(studio);
        File.WriteAllText(Path.Combine(studio, "build.ps1"), "exit 0");
        File.WriteAllText(Path.Combine(studio, "Invoke-Build.log"), "MSBUILD : error MSB1003: Specify a project or solution file.\n");
        var running = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (_, _, _) =>
        {
            running.TrySetResult();
            await release.Task;
            return FakePwsh.Ok(BuildPlanner.RepoScriptCommand, """{"success":true,"exitCode":0,"mode":"script","detail":"build.ps1"}""");
        };

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-refinery-studio" });
        await running.Task.WaitAsync(TimeSpan.FromSeconds(15), TestContext.Current.CancellationToken);
        BuildStatus live;
        try
        {
            live = queue.Get(job.Id, repo: "octo-frontend-refinery-studio");
        }
        finally
        {
            release.TrySetResult();
        }

        live.State.Should().Be("running");
        live.Progress!.Repos!.Single().State.Should().Be("pending", "the old log is no sign that this step started building");
        live.Diagnostics?.Errors.Should().BeNullOrEmpty("its MSB1003 belongs to another build");
        (await WaitAsync(queue, job.Id)).State.Should().Be("succeeded");
    }

    [Fact]
    public async Task A_failed_Invoke_Publish_reports_the_errors_of_the_Invoke_Build_log_it_wrote()
    {
        // Frontend mode: Invoke-Publish deletes <repo>/Invoke-Build.log and writes dotnet restore/publish into it, so that
        // log is this step's - unlike a build.ps1 step, which writes none.
        var (queue, _, _, _) = Create();
        var panel = Path.Combine(_checkout.Lane, "octo-frontend-admin-panel");
        Directory.CreateDirectory(panel);
        File.WriteAllText(Path.Combine(panel, "AdminPanel.sln"), "");
        _fake.Build = (_, _, _) =>
        {
            File.WriteAllText(Path.Combine(panel, "Invoke-Build.log"),
                $"{panel}/src/A.cs(3,9): error CS0246: The type or namespace name 'Foo' could not be found [{panel}/AdminPanel.csproj]\n");
            return Task.FromResult(FakePwsh.Ok("Invoke-Publish", """{"success":false,"exitCode":1}""", exitCode: 1));
        };

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-admin-panel" });
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().StartWith("Invoke-Publish ", "a frontend repo with a solution builds in frontend mode");
        done.State.Should().Be("failed");
        queue.Get(job.Id, repo: "octo-frontend-admin-panel").Diagnostics!.Errors.Should().ContainSingle().Which.Code.Should().Be("CS0246");
        done.Outcome!.Summary.Should().EndWith(": The type or namespace name 'Foo' could not be found");
    }

    [Fact]
    public async Task A_build_script_that_ends_without_its_result_document_names_its_repo_and_error()
    {
        // build.ps1 ended with a terminating error: the step printed no -Json document of its own.
        var (queue, _, _, _) = Create();
        var studio = Path.Combine(_checkout.Lane, "octo-frontend-refinery-studio");
        Directory.CreateDirectory(studio);
        File.WriteAllText(Path.Combine(studio, "build.ps1"), "exit 1");
        _fake.Build = (_, _, _) => Task.FromResult(new PwshResult(1,
            "> prebuild\nERROR: TELERIK_LICENSE environment variable is not set!\nException: C:\\x\\build.ps1:3\nLine |\n   3 |  throw 'stopped'\n     | stopped\n",
            false, false));

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-refinery-studio" });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.Summary.Should().Contain("printed no -Json result").And.EndWith(": ERROR: TELERIK_LICENSE environment variable is not set!");
        queue.Get(job.Id, repo: "octo-frontend-refinery-studio").Diagnostics!.Errors.Select(e => e.Message).Should()
            .Equal(["ERROR: TELERIK_LICENSE environment variable is not set!"], "pwsh 7 prints a throw as 'Exception:' with the line, no error word");
    }

    [Fact]
    public async Task A_repo_without_solution_and_build_script_has_nothing_to_build_and_succeeds()
    {
        var (queue, _, _, _) = Create();
        Directory.CreateDirectory(Path.Combine(_checkout.Lane, "octo-frontend-libraries", "src", "frontend-libraries"));
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok(BuildPlanner.RepoScriptCommand,
            """{"success":true,"exitCode":0,"mode":"none","detail":"no solution file and no build.ps1 in the repository root: nothing to build (Invoke-BuildAll skips it too)"}"""));

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-libraries" });
        plan.Steps.Single().Repos.Single().Mode.Should().Be("none");

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-libraries" });
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().NotContain("Invoke-Build ", "dotnet on a folder without a solution fails with MSB1003");
        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be(
            "octo-frontend-libraries: no solution file and no build.ps1 in the repository root: nothing to build (Invoke-BuildAll skips it too)");
        plan.Warnings.Should().Contain("octo-frontend-libraries has no solution and no build.ps1: nothing to build, as in Invoke-BuildAll.");
    }

    [Theory]
    [InlineData("build.ps1", "octo-frontend-refinery-studio", BuildPlanner.RepoScriptCommand)]
    [InlineData(null, "octo-frontend-libraries", BuildPlanner.RepoScriptCommand)]
    [InlineData("AdminPanel.sln", "octo-frontend-admin-panel", "Invoke-Publish")]
    public async Task RefreshCatalogs_is_not_appended_to_a_repo_step_with_its_own_result_command(string? file, string name, string command)
    {
        var (queue, _, _, _) = Create();
        var caps = System.Text.Json.Nodes.JsonNode.Parse(_fake.Capabilities)!.AsObject();
        foreach (var cmdlet in new[] { "Invoke-Build", "Invoke-BuildRange", "Invoke-BuildAll" })
        {
            caps[cmdlet]!.AsArray().Add("refreshCatalogs");
        }

        _fake.Capabilities = caps.ToJsonString();
        var repo = Path.Combine(_checkout.Lane, name);
        Directory.CreateDirectory(repo);
        if (file != null)
        {
            File.WriteAllText(Path.Combine(repo, file), file.EndsWith(".ps1", StringComparison.Ordinal) ? "exit 0" : "");
        }

        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok(command, """{"success":true,"exitCode":0}"""));
        var request = new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = name, RefreshCatalogs = true };

        var plan = await queue.Plan(request);
        var job = await queue.Enqueue(request);
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().NotContain("-refreshCatalogs", "neither build.ps1, ConvertTo-Json nor Invoke-Publish takes it");
        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        plan.Warnings.Should().Contain(w => w.StartsWith(name, StringComparison.Ordinal) && w.EndsWith("; refreshCatalogs does not apply to it.", StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_profile_build_plan_shows_the_mode_a_build_ps1_repo_is_built_in()
    {
        var (queue, _, _, _) = Create("""
                                        studio:
                                          repo: octo-a
                                          args: [A.dll]
                                      """, "profiles:\n  p1:\n    services: [studio]\n");
        File.WriteAllText(Path.Combine(_checkout.Lane, "octo-a", "build.ps1"), "exit 0");

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Profile, Profile = "p1", OnlyStale = false });

        plan.Steps.Single().Repos.Single().Mode.Should().Be("script", "build_plan shows the mode the step builds in, not dotnet");
    }

    [Fact]
    public async Task A_frontend_repo_with_a_solution_is_published_and_judged_by_the_Invoke_Publish_result()
    {
        var (queue, _, _, _) = Create();
        var panel = Path.Combine(_checkout.Lane, "octo-frontend-admin-panel");
        Directory.CreateDirectory(panel);
        File.WriteAllText(Path.Combine(panel, "AdminPanel.sln"), "");
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-Publish", """{"success":true,"exitCode":0}"""));

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-frontend-admin-panel" });
        var done = await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().StartWith($"Invoke-Publish -repositoryPath {PwshRunner.Quote(panel)} -configuration 'DebugL' -Json");
        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be("octo-frontend-admin-panel built (mode frontend)");
    }

    [Fact]
    public void The_script_of_a_build_ps1_repo_runs_the_script_and_prints_its_exit_code_as_the_result()
    {
        var repo = Path.Combine(_checkout.Root, "scripted", "octo-frontend-refinery-studio");

        var script = BuildPlanner.NonDotnetRepoScript("script", repo, "DebugL");

        script.Should().StartWith($"$global:LASTEXITCODE = 0; & {PwshRunner.Quote(Path.Combine(repo, "build.ps1"))} -configuration 'DebugL' | Out-Host; ")
            .And.Contain($"command = '{BuildPlanner.RepoScriptCommand}'")
            .And.Contain("success = ($code -eq 0); exitCode = $code; mode = 'script'")
            .And.Contain($"repositoryPath = {PwshRunner.Quote(repo)}")
            .And.EndWith("| ConvertTo-Json -Depth 4 -Compress; exit $code");
    }

    [Fact]
    public void The_script_of_a_nothing_to_build_repo_prints_a_successful_result_and_runs_nothing()
    {
        var repo = Path.Combine(_checkout.Root, "scripted", "octo-frontend-libraries");

        var script = BuildPlanner.NonDotnetRepoScript("none", repo, "DebugL");

        script.Should().StartWith("[ordered]@{ schemaVersion = 1; ").And.Contain("success = $true; exitCode = 0; mode = 'none'")
            .And.EndWith("| ConvertTo-Json -Depth 4 -Compress").And.NotContain("build.ps1'").And.NotContain("exit ");
    }

    /// <summary>
    ///     The generated script runs in a real pwsh (-NoProfile, no octo-tools), like every test process (AB#9377): it proves
    ///     that the generated PowerShell parses and that its -Json document is the one the queue reads.
    /// </summary>
    [Theory]
    [InlineData("script", 0)]
    [InlineData("script", 3)]
    [InlineData("none", 0)]
    public async Task The_script_of_a_build_ps1_or_nothing_to_build_repo_prints_a_result_the_queue_reads(string mode, int exitCode)
    {
        // A real pwsh, like every test process (AB#9377): the generated script, no octo-tools.
        var repo = Path.Combine(_checkout.Root, "scripted", "octo-frontend-refinery-studio");
        Directory.CreateDirectory(repo);
        File.WriteAllText(Path.Combine(repo, "build.ps1"), $"param([string]$configuration)\nWrite-Output \"building $configuration\"\nexit {exitCode}\n");
        var script = BuildPlanner.NonDotnetRepoScript(mode, repo, "DebugL");

        var psi = TestProcess.Script(script);
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;

        var result = await PwshRunner.RunProcessAsync(psi, new PwshRunOptions { Timeout = TimeSpan.FromMinutes(1) }, CancellationToken.None);

        var data = PwshRunner.ExtractOctoJson(result.Output, BuildPlanner.RepoScriptCommand)?["data"];
        data.Should().NotBeNull(result.Output);
        BuildPlanner.Bool(data!["success"]).Should().Be(exitCode == 0);
        result.ExitCode.Should().Be(exitCode);
        if (mode == "script")
        {
            result.Output.Should().Contain("building DebugL", "the script's output stays in the log");
        }
    }

    [Theory]
    [InlineData("build.ps1", "octo-frontend-refinery-studio", "script")]
    [InlineData(null, "octo-frontend-libraries", "none")]
    [InlineData("Studio.sln", "octo-frontend-admin-panel", "frontend")]
    [InlineData("Identity.sln", "octo-identity-services", "dotnet")]
    [InlineData("Tool.csproj", "octo-tool", "dotnet")]
    [InlineData("Plug.slnx", "octo-plug-zenon", "dotnet")]
    public void The_build_mode_follows_the_files_in_the_repository_root(string? file, string name, string mode)
    {
        var path = Path.Combine(_checkout.Root, "modes", name);
        Directory.CreateDirectory(path);
        if (file != null)
        {
            File.WriteAllText(Path.Combine(path, file), "");
        }

        BuildPlanner.RepoBuildMode(path, name).Should().Be(mode);
    }

    // ---------- conflicts ----------

    [Fact]
    public async Task A_service_in_a_nested_worktree_does_not_block_the_lane_repo_build()
    {
        var (queue, supervisor, _, _) = Create();
        var worktree = Path.Combine(_checkout.Lane, "octo-a", ".claude", "worktrees", "agent-1");
        Directory.CreateDirectory(worktree);
        File.WriteAllText(Path.Combine(worktree, ".git"), "gitdir: /x/.git/worktrees/agent-1");
        await supervisor.StartStackAsync("s1", new StartSpec { Overrides = new() { ["sleeper"] = new ServiceOverride { Source = worktree } } }, null, false, false,
            TimeSpan.FromSeconds(1), CancellationToken.None);

        var job = await queue.Enqueue(new BuildRequest { Owner = "s2", Kind = BuildKind.Repo, Path = "octo-a" });

        (await WaitAsync(queue, job.Id)).State.Should().Be("succeeded");
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_repo_build_of_a_worktree_nested_in_a_repository_is_refused_with_the_reason_and_the_way_out()
    {
        var (queue, _, _, _) = Create();
        var nested = Path.Combine(_checkout.Lane, "octo-a", ".claude", "worktrees", "agent-1");
        Directory.CreateDirectory(nested);
        File.WriteAllText(Path.Combine(nested, ".git"), "gitdir: " + Path.Combine(_checkout.Lane, "octo-a", ".git", "worktrees", "agent-1"));
        File.WriteAllText(Path.Combine(nested, "octo-a.sln"), "");

        var build = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = nested });
        var plan = () => queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = nested });

        var refused = await build.Should().ThrowAsync<InvalidOperationException>();
        refused.Which.Message.Should().Contain("NU5118").And.Contain(Path.Combine(_checkout.Lane, "octo-a", "Directory.Build.props"))
            .And.Contain($"lane_add_repo with path=\"{nested}\"").And.Contain("lane_build");
        await plan.Should().ThrowAsync<InvalidOperationException>().WithMessage("*NU5118*");
        queue.List().Should().BeEmpty();
        _fake.BuildCalls.Should().BeEmpty();
        BuildPlanner.NestedWorktreeRepo(nested).Should().Be(Path.Combine(_checkout.Lane, "octo-a"));
        BuildPlanner.NestedWorktreeRepo(Path.Combine(nested, "src")).Should().Be(Path.Combine(_checkout.Lane, "octo-a"));
        BuildPlanner.NestedWorktreeRepo(Path.Combine(_checkout.Lane, "octo-a", ".claude", "worktrees")).Should().BeNull("the worktrees folder itself is no worktree");
        BuildPlanner.NestedWorktreeRepo(Path.Combine(_checkout.Lane, "wt-1-octo-a")).Should().BeNull();
    }

    [Fact]
    public async Task Own_services_under_the_target_need_stopServices_and_the_lease_and_come_back_with_their_override()
    {
        var (queue, supervisor, lease, _) = Create();
        var worktree = Path.Combine(_checkout.Lane, "wt-1-octo-a");
        Directory.CreateDirectory(worktree);
        File.WriteAllText(Path.Combine(worktree, ".git"), "gitdir: /x/octo-a/.git/worktrees/wt-1");
        File.WriteAllText(Path.Combine(worktree, "octo-a.sln"), "");
        await supervisor.StartStackAsync("s1", new StartSpec { Overrides = new() { ["sleeper"] = new ServiceOverride { Source = "wt-1-octo-a" } } }, null,
            false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var firstPid = (await supervisor.StatusAsync(false)).Services.Single().Pid;

        var refused = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "wt-1-octo-a" });
        await refused.Should().ThrowAsync<InvalidOperationException>().WithMessage("*stopServices=true*sleeper*");
        var foreignOwner = () => queue.Enqueue(new BuildRequest { Owner = "s2", Kind = BuildKind.Repo, Path = "wt-1-octo-a", StopServices = true });
        await foreignOwner.Should().ThrowAsync<LeaseHeldException>();
        queue.Refusals().Should().ContainSingle("s2 passed stopServices: its refusal is about the lease, not the service")
            .Which.Should().Match<BuildRefusal>(r => r.Owner == "s1" && r.Conflicts.Single().Service == "sleeper");

        var job = await queue.Enqueue(new BuildRequest
            { Owner = "s1", Kind = BuildKind.Repo, Path = "wt-1-octo-a", StopServices = true, RestartServices = true });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded");
        done.StoppedServices.Should().Equal("sleeper");
        done.Notes.Should().Contain(n => n.StartsWith("restarted sleeper"));
        var after = (await supervisor.StatusAsync(false)).Services.Single();
        after.Pid.Should().NotBe(firstPid);
        after.RepoPath.Should().Be(worktree, "the worktree override survives the build");
        lease.Snapshot().Holder!.Owner.Should().Be("s1");
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);
    }

    [Fact]
    public async Task External_processes_in_the_target_refuse_the_build_with_their_stop_hint()
    {
        var (queue, _, _, _) = Create();
        _external = External(Sleep().Id, Path.Combine(_checkout.Lane, "octo-a"), nonInteractive: false);

        var act = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });

        await act.Should().ThrowAsync<InvalidOperationException>().WithMessage("*not by octo-devstack*press a key*");
        _fake.BuildCalls.Should().BeEmpty();
    }

    [Fact]
    public async Task Services_that_appear_while_the_build_is_queued_fail_it_before_it_runs()
    {
        var (queue, supervisor, _, _) = Create();
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            if (body.Contains("octo-b", StringComparison.Ordinal))
            {
                await release.Task;
            }

            return FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0}""");
        };

        var blocker = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-b" });
        await WaitAsync(queue, blocker.Id, b => b.State == "running");
        var queued = await queue.Enqueue(new BuildRequest { Owner = "s2", Kind = BuildKind.Repo, Path = "octo-a" });
        queue.Get(queued.Id).Queue!.Position.Should().Be(1);
        await supervisor.StartStackAsync("s1", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        release.SetResult();

        (await WaitAsync(queue, blocker.Id)).State.Should().Be("succeeded");
        var failed = await WaitAsync(queue, queued.Id);
        failed.State.Should().Be("failed");
        failed.Outcome!.FailedStep.Should().Be("preflight");
        failed.Outcome.Summary.Should().Contain("while the build was queued");
        _fake.BuildCalls.Should().ContainSingle();
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);
    }

    // ---------- range ----------

    // JsonSerializer, not interpolation: Windows paths carry backslashes that JSON must escape.
    private string RangePlan(params string[] repos) => System.Text.Json.JsonSerializer.Serialize(new
    {
        whatIf = true,
        lane = new { isolated = true },
        packageCaches = new[] { $"{_checkout.Lane}/.nuget-packages" },
        repositories = repos.Select(r => new { repo = r, mode = "dotnet", path = Path.Combine(_checkout.Lane, r) }),
        staleGlobalCache = Array.Empty<string>()
    });

    [Fact]
    public async Task A_range_build_needs_the_lease_and_publish()
    {
        var (queue, _, lease, _) = Create();
        _fake.RangePlan = RangePlan("octo-a", "octo-b");
        lease.Require("other");

        var noLease = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", To = "octo-b", Publish = true });
        await noLease.Should().ThrowAsync<LeaseHeldException>();
        lease.Release("other", false);
        var noPublish = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", To = "octo-b" });
        await noPublish.Should().ThrowAsync<InvalidOperationException>().WithMessage("*publish=true*");

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", To = "octo-b" });
        plan.Gates.Lease.Should().BeTrue();
        plan.Gates.Publish.Should().BeTrue();
        plan.Steps.Single().Repos.Select(r => r.Repo).Should().Equal("octo-a", "octo-b");
        plan.Lane!.Isolated.Should().BeTrue();
        plan.Warnings.Should().Contain(w => w.Contains("every session"));
        _fake.BuildCalls.Should().BeEmpty("build_plan runs only -WhatIf");

        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-BuildRange",
            """{"success":false,"failedRepo":"octo-b","failedStep":"build","hint":null,"repositories":[{"repo":"octo-a","success":true,"buildSeconds":30,"testCompileSeconds":0,"packageSeconds":2,"copiedCount":4,"purged":["x"]},{"repo":"octo-b","success":false,"buildSeconds":5,"testCompileSeconds":0,"packageSeconds":0,"copiedCount":0,"purged":[]}],"notBuilt":[]}"""));
        _fake.Capabilities = FakePwsh.MainParams; // no events: the JSON fills in the repos
        var fresh = Create();
        var job = await fresh.Queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", To = "octo-b", Publish = true });
        var done = await WaitAsync(fresh.Queue, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.FailedRepo.Should().Be("octo-b");
        done.Progress!.Repos!.Should().Equal(new BuildRepoProgress("octo-a", "done", 30, 0, 4, 1, 32, 2, Tests: "notCompiled"), new BuildRepoProgress("octo-b", "failed", 5, 0, 0, 0, 5, 0, Tests: "notCompiled"));
        done.Progress.Totals.Should().Be(new BuildPhaseSeconds(35, 0, 2, "octo-a (32 s)"));
        _fake.BuildCalls.Last().Should().StartWith("Invoke-BuildRange -branch 'branches/main' -from 'octo-a' -configuration 'DebugL' -to 'octo-b'")
            .And.NotContain("ignoreRunningServices");
    }

    [Theory]
    [InlineData(BuildKind.Range)]
    [InlineData(BuildKind.All)]
    public async Task A_lane_build_in_a_lane_without_repositories_is_refused_before_a_job_exists(BuildKind kind)
    {
        // AB#8915: a removed worktree's folder (or the worktree of one repo) is no lane; the cmdlet would fail at once.
        var lane = Path.Combine(_checkout.Root, "branches", "worktrees", "octo-sdk-x");
        Directory.CreateDirectory(Path.Combine(lane, "src"));
        var (queue, _, _, _) = Create();
        _fake.RangePlan = RangePlan("octo-a");

        var plan = () => queue.Plan(new BuildRequest { Owner = "s1", Kind = kind, From = "octo-a", Checkout = "branches/worktrees/octo-sdk-x", Publish = true, Confirm = true });
        var start = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = kind, From = "octo-a", Checkout = "branches/worktrees/octo-sdk-x", Publish = true, Confirm = true });

        (await plan.Should().ThrowAsync<ArgumentException>()).Which.Message.Should().Contain(lane).And.Contain("holds no repository").And.Contain("lane_build");
        (await start.Should().ThrowAsync<ArgumentException>()).Which.Message.Should().Contain($"kind={kind.ToString().ToLowerInvariant()} refused");
        queue.List().Should().BeEmpty();
        _fake.BuildCalls.Should().BeEmpty();
    }

    [Fact]
    public async Task A_finished_repo_build_whose_worktree_was_removed_is_marked_gone()
    {
        var (queue, _, _, _) = Create();
        var worktree = Path.Combine(_checkout.Root, "wt-lane", "octo-a");
        Directory.CreateDirectory(worktree);
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0,"logFile":"/x"}"""));
        var done = await WaitAsync(queue, (await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = worktree })).Id);
        done.Gone.Should().BeNull();

        Directory.Delete(worktree, recursive: true);

        queue.List().Single().Gone.Should().Be($"folder {worktree} no longer exists");
    }

    [Fact]
    public async Task Range_conflicts_come_from_the_plan_repos_not_the_whole_lane()
    {
        var (queue, supervisor, lease, _) = Create();
        lease.Require("s1");
        await supervisor.StartStackAsync("s1", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None); // sleeper in octo-a
        _fake.RangePlan = RangePlan("octo-b");

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-b" });
        plan.Conflicts.Should().BeEmpty("octo-a is not in the range");

        _fake.RangePlan = RangePlan("octo-a", "octo-b");
        plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", To = "octo-b", Publish = true });
        plan.Conflicts.Should().ContainSingle().Which.Should().Match<BuildConflict>(c => c.Service == "sleeper" && c.Kind == "own" && c.StartedBy.Contains("s1"));
        plan.Gates.Unmet.Should().ContainSingle().Which.Should().Contain("stopServices=true");
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_conflict_names_who_started_or_overrode_the_service_not_who_started_the_stack()
    {
        var (queue, supervisor, lease, _) = Create();
        lease.Require("s1");
        await supervisor.StartStackAsync("s1", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None); // sleeper in octo-a
        lease.Release("s1", false);
        // s2 runs the same service with other arguments (a worktree would be outside the range's repos).
        await supervisor.RestartServicesAsync("s2", ["sleeper"],
            new Dictionary<string, ServiceOverride> { ["sleeper"] = new() { Args = ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 31"] } }, false,
            TimeSpan.FromSeconds(1), CancellationToken.None);
        _fake.RangePlan = RangePlan("octo-a");

        var plan = await queue.Plan(new BuildRequest { Owner = "s3", Kind = BuildKind.Range, From = "octo-a", Publish = true });

        plan.Conflicts.Should().ContainSingle().Which.StartedBy.Should().Be("s2 (octo-devstack service_restart)");
        BuildPlanner.OwnStarter(null, "s1", "second").Should().Be("s1 (octo-devstack, the stack's starter, slot second)", "a service of an older state file");
        await supervisor.StopServicesAsync("s2", null, CancellationToken.None);
    }

    [Fact]
    public async Task Canceling_a_range_build_restarts_the_stopped_services_and_warns_about_the_lane_nuget()
    {
        var (queue, supervisor, lease, _) = Create();
        lease.Require("s1");
        await supervisor.StartStackAsync("s1", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        _fake.RangePlan = RangePlan("octo-a");
        var started = new TaskCompletionSource();
        _fake.Build = async (_, _, token) =>
        {
            started.SetResult();
            try
            {
                await Task.Delay(Timeout.Infinite, token);
            }
            catch (OperationCanceledException)
            {
            }

            return new PwshResult(-1, "", false, true);
        };

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", Publish = true, StopServices = true });
        await started.Task;
        (await supervisor.StatusAsync(false)).Running.Should().BeFalse("the build stopped the sleeper");
        queue.Cancel(job.Id, "s1");
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("canceled");
        done.Notes.Should().Contain(n => n.Contains("partially updated")).And.Contain(n => n.StartsWith("restarted sleeper"));
        (await supervisor.StatusAsync(false)).Services.Should().ContainSingle(s => s.Name == "sleeper" && s.State != "exited");
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);
    }

    [Fact]
    public async Task Private_packages_are_refused_without_feedPath_and_isolated_with_it()
    {
        _fake.Capabilities = FakePwsh.MainParams;
        var (queue, _, lease, _) = Create();
        lease.Require("s1");
        _fake.RangePlan = RangePlan("octo-a");

        var act = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", Publish = true, Packages = PackageMode.Private });
        await act.Should().ThrowAsync<InvalidOperationException>().WithMessage("*-feedPath*");

        _fake.Capabilities = FakePwsh.WorktreeParams;
        var fresh = Create();
        fresh.Lease.Require("s1");
        var job = await fresh.Queue.Enqueue(new BuildRequest
            { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", Publish = true, Packages = PackageMode.Private });
        var done = await WaitAsync(fresh.Queue, job.Id);

        var feed = Path.Combine(_checkout.StateDirectory, "feeds", "s1", "nuget");
        var cache = Path.Combine(_checkout.StateDirectory, "feeds", "s1", "packages");
        done.Lane!.Feed.Should().Be(feed);
        var call = _fake.Calls.Last(c => FakePwsh.Strip(c.Body).StartsWith("Invoke-BuildRange", StringComparison.Ordinal) && !c.Body.Contains("-WhatIf"));
        call.Body.Should().Contain($"-feedPath '{feed}'")
            .And.Contain($"'RestoreSources' = '{feed};https://api.nuget.org/v3/index.json'")
            .And.Contain($"'RestorePackagesPath' = '{cache}'");
        call.Options.Environment!["NUGET_PACKAGES"].Should().Be(cache);

        // A consumer worktree restores from the same feed.
        var consumer = await fresh.Queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-b", Packages = PackageMode.Private });
        await WaitAsync(fresh.Queue, consumer.Id);
        _fake.BuildCalls.Last().Should().Contain("-msbuildProperties @{ 'RestoreSources' = ").And.Contain(cache);
    }

    // ---------- all ----------

    private string AllPlan() =>
        """{"dryRun":true,"lane":{"isolated":false},"packageCachesToPurge":["/c"],"repositories":[{"order":1,"repo":"octo-a","builder":"Invoke-Build"},{"order":2,"repo":"octo-b","builder":"build.ps1"}]}""";

    [Fact]
    public async Task Build_all_needs_confirm_and_is_refused_on_Windows_without_a_lane_scoped_kill()
    {
        _fake.Capabilities = FakePwsh.MainParams;
        _fake.AllPlan = AllPlan();
        var (queue, _, _, _) = Create(options: new BuildQueueOptions { IsWindows = true });
        var windows = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.All, Confirm = true });
        await windows.Should().ThrowAsync<InvalidOperationException>().WithMessage("*Windows*");

        _fake.Capabilities = FakePwsh.WorktreeParams;
        var fresh = Create();
        var noConfirm = () => fresh.Queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.All });
        await noConfirm.Should().ThrowAsync<InvalidOperationException>().WithMessage("*confirm=true*");

        var plan = await fresh.Queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.All });
        plan.Warnings.Should().Contain(w => w.Contains("wipes") && w.Contains("30-90 min"));
        plan.Steps.Single().Command.Should().Contain("-skipKill");
        plan.Steps.Single().Repos.Select(r => r.Mode).Should().Equal("dotnet", "script");
    }

    [Fact]
    public async Task Build_all_stops_own_services_and_non_interactive_Start_Octo_with_stopExternal()
    {
        _fake.AllPlan = AllPlan();
        var (queue, supervisor, lease, _) = Create();
        lease.Require("s1");
        await supervisor.StartStackAsync("s1", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var startOcto = Sleep();
        _external = External(startOcto.Id, Path.Combine(_checkout.Lane, "octo-b"), nonInteractive: true);
        _fake.Build = (body, _, _) =>
        {
            if (body.StartsWith("Stop-Octo", StringComparison.Ordinal))
            {
                startOcto.Kill();
                startOcto.WaitForExit();
                _external = ExternalSnapshot.Empty;
                return Task.FromResult(new PwshResult(0, "", false, false));
            }

            return Task.FromResult(FakePwsh.Ok("Invoke-BuildAll",
                """{"repositories":[{"repo":"octo-a","success":true,"durationSeconds":10}],"summary":{"total":2,"succeeded":2,"failed":0}}"""));
        };

        var noConfirm = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.All, StopExternal = true });
        await noConfirm.Should().ThrowAsync<InvalidOperationException>().WithMessage("*confirm=true*");
        queue.Refusals().Should().BeEmpty("kind=all stops its own services and stopExternal the Start-Octo stack: they are not the reason");

        var refused = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.All, Confirm = true });
        await refused.Should().ThrowAsync<InvalidOperationException>().WithMessage("*stopExternal=true*");
        queue.Refusals().Single().Conflicts.Should().ContainSingle().Which.Kind.Should().Be("external", "the own sleeper does not block kind=all");

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.All, Confirm = true, StopExternal = true, RestartServices = true });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded");
        done.StoppedServices.Should().Equal("sleeper");
        _fake.BuildCalls.Should().Contain("Stop-Octo -branch 'branches/main'");
        _fake.BuildCalls.Last().Should().StartWith("Invoke-BuildAll -branch 'branches/main' -configuration 'DebugL' -skipKill -Json");
        done.Notes.Should().Contain(n => n.StartsWith("restarted sleeper"));
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);
    }

    private ExternalSnapshot External(int pid, string repoPath, bool nonInteractive)
    {
        var origin = new ExternalOrigin("start-octo", "Start-Octo, started by a Claude Code session (session abcd1234)", 1, "Start-Octo", "branches/main",
            "DebugL", nonInteractive, null, nonInteractive ? "Stop-Octo -branch branches/main" : "press a key in the terminal that runs Start-Octo");
        var service = new ExternalService("sleeper", pid, [], "sleep", repoPath, _checkout.Lane, repoPath, null, "DebugL", null, false, null, null, "g1");
        return new ExternalSnapshot([service], [new ExternalGroup("g1", origin, _checkout.Lane, "DebugL", ["sleeper"], null)]);
    }

    // ---------- profile ----------

    [Fact]
    public async Task A_profile_build_runs_the_stale_repos_of_its_services_in_build_order()
    {
        var services = """
                         first:
                           repo: octo-b
                           args: [B.dll]
                         second:
                           repo: octo-a
                           args: [A.dll]
                         web:
                           repo: octo-a
                           command: npm
                           args: [start]
                       """;
        var (queue, _, _, _) = Create(services, "profiles:\n  p1:\n    services: [first, second, web]\n");
        _fake.BuildOrder = ["octo-a", "octo-b"];
        var upToDate = Path.Combine(_checkout.Lane, "octo-b");
        File.WriteAllText(Path.Combine(upToDate, "B.cs"), "");
        File.SetLastWriteTimeUtc(Path.Combine(upToDate, "B.cs"), DateTime.UtcNow.AddHours(-1));
        Directory.CreateDirectory(Path.Combine(upToDate, "bin", "DebugL"));
        File.WriteAllText(Path.Combine(upToDate, "bin", "DebugL", "B.dll"), "");

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Profile, Profile = "p1" });
        plan.Steps.Should().ContainSingle().Which.Target.Should().EndWith("octo-a");
        plan.Warnings.Should().Contain(w => w.Contains("web") && w.Contains("not a .NET service"));
        plan.Gates.Lease.Should().BeFalse();

        var all = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Profile, Profile = "p1", OnlyStale = false });
        all.Steps.Select(s => Path.GetFileName(s.Target)).Should().Equal("octo-a", "octo-b");

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Profile, Profile = "p1", OnlyStale = false });
        var done = await WaitAsync(queue, job.Id);
        done.State.Should().Be("succeeded");
        done.Progress!.RepoCount.Should().Be(2);
        done.Outcome!.Summary.Should().Be("2 builds succeeded");
    }

    // ---------- state file of an older daemon (restart behaviour: BuildRestartTests) ----------

    [Fact]
    public void A_state_file_of_an_older_daemon_with_one_build_is_read()
    {
        var paths = new DevStackPaths(_checkout.StateDirectory);
        Directory.CreateDirectory(_checkout.StateDirectory);
        File.WriteAllText(paths.StateFile, """{"Build":{"Id":"b1-old","Owner":"s0","Kind":"range","Target":"x","Pid":1,"StartedAt":"2026-11-09T10:00:00+01:00","LogFile":"/l"}}""");

        new StateStore(paths).Load().RunningBuilds().Should().ContainSingle(b => b.Id == "b1-old");
    }

    // ---------- review findings ----------

    /// <summary>Lets the fake block a build until the test releases it.</summary>
    private TaskCompletionSource BlockBuildsOf(string marker)
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, token) =>
        {
            if (body.Contains(marker, StringComparison.Ordinal) && !body.StartsWith("Stop-Octo", StringComparison.Ordinal))
            {
                await release.Task.WaitAsync(token).ContinueWith(_ => { }, CancellationToken.None);
                if (token.IsCancellationRequested)
                {
                    return new PwshResult(-1, "", false, true);
                }
            }

            var command = FakePwsh.Command(body);
            return command == "Invoke-BuildAll"
                ? FakePwsh.Ok(command, """{"summary":{"failed":0}}""")
                : FakePwsh.Ok(command, """{"success":true,"exitCode":0}""");
        };
        return release;
    }

    [Fact]
    public async Task A_running_build_blocks_starting_services_from_its_repos_and_a_range_from_its_lane()
    {
        var (queue, supervisor, lease, _) = Create();
        var release = BlockBuildsOf("octo-a");
        var job = await queue.Enqueue(new BuildRequest { Owner = "s2", Kind = BuildKind.Repo, Path = "octo-a" });
        await WaitAsync(queue, job.Id, b => b.State == "running");

        var start = () => supervisor.StartStackAsync("s1", null, null, false, false, TimeSpan.FromSeconds(1), TestContext.Current.CancellationToken);
        await start.Should().ThrowAsync<InvalidOperationException>().WithMessage($"*sleeper*job {job.Id} (a build of s2*job_status(\"{job.Id}\", waitSeconds=50)*");
        release.SetResult();
        (await WaitAsync(queue, job.Id)).State.Should().Be("succeeded");
        await start(); // free again
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);

        // A range build owns the whole lane: the sleeper (octo-a) is outside the range octo-b but inside the lane.
        _fake.RangePlan = RangePlan("octo-b");
        var rangeRelease = BlockBuildsOf("octo-b");
        var range = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-b", Publish = true });
        await WaitAsync(queue, range.Id, b => b.State == "running");
        await start.Should().ThrowAsync<InvalidOperationException>().WithMessage($"*job {range.Id} (a build of s1*");
        rangeRelease.SetResult();
        (await WaitAsync(queue, range.Id)).State.Should().Be("succeeded");
        lease.Release("s1", false);
    }

    [Fact]
    public async Task A_queued_job_fails_when_its_owner_lost_the_lease_and_a_running_job_pins_it()
    {
        var (queue, _, lease, _) = Create();
        _fake.RangePlan = RangePlan("octo-a");
        var release = BlockBuildsOf("octo-b");
        var blocker = await queue.Enqueue(new BuildRequest { Owner = "s0", Kind = BuildKind.Repo, Path = "octo-b" });
        await WaitAsync(queue, blocker.Id, b => b.State == "running");

        var range = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", Publish = true });
        lease.Release("s1", false);
        lease.Require("s2");
        release.SetResult();
        var failed = await WaitAsync(queue, range.Id);

        failed.State.Should().Be("failed");
        failed.Outcome!.FailedStep.Should().Be("preflight");
        failed.Outcome.Summary.Should().Contain("no longer holds the stack lease").And.Contain("s2");
        _fake.BuildCalls.Should().NotContain(c => c.StartsWith("Invoke-BuildRange", StringComparison.Ordinal) && !c.Contains("-WhatIf"));

        // While a lease-requiring job runs, its owner's lease is pinned.
        lease.Release("s2", false);
        var pinRelease = BlockBuildsOf("octo-a");
        var pinned = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", Publish = true });
        await WaitAsync(queue, pinned.Id, b => b.State == "running");
        lease.IsPinned("s1").Should().BeTrue();
        pinRelease.SetResult();
        await WaitAsync(queue, pinned.Id);
        lease.IsPinned("s1").Should().BeFalse();
    }

    [Fact]
    public async Task Only_the_steps_own_cmdlet_document_counts_as_its_result()
    {
        var (queue, _, lease, _) = Create();
        lease.Require("s1");
        _fake.RangePlan = RangePlan("octo-a");
        // Invoke-BuildRange crashed after a nested Invoke-Build printed its own successful -Json document.
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0}"""));

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", Publish = true });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.Summary.Should().Contain("Invoke-BuildRange printed no -Json result");
        PwshRunner.ExtractOctoJson(FakePwsh.Ok("Invoke-Build", "{}").Output, "Invoke-BuildRange").Should().BeNull();
        PwshRunner.ExtractOctoJson(FakePwsh.Ok("Invoke-Build", "{}").Output, "Invoke-Build").Should().NotBeNull();
    }

    [Fact]
    public async Task Jobs_run_strictly_in_enqueue_order_and_positions_follow_it()
    {
        var (queue, _, _, _) = Create();
        _checkout.Repo("octo-c");
        var order = new List<string>();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            lock (order)
            {
                order.Add(Path.GetFileName(body.Split('\'')[1]));
            }

            await release.Task;
            return FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0}""");
        };

        var first = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        await WaitAsync(queue, first.Id, b => b.State == "running");
        var ids = new List<string>();
        foreach (var repo in new[] { "octo-b", "octo-c", "octo-b", "octo-c" })
        {
            ids.Add((await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = repo })).Id);
        }

        ids.Select(id => queue.Get(id).Queue!.Position).Should().Equal(1, 2, 3, 4);
        queue.Cancel(ids[1], "s1").State.Should().Be("canceled");
        queue.Get(ids[2]).Queue!.Position.Should().Be(2);
        release.SetResult();
        foreach (var id in ids)
        {
            await WaitAsync(queue, id);
        }

        order.Should().Equal("octo-a", "octo-b", "octo-b", "octo-c");
    }

    [Fact]
    public async Task Cancel_while_services_are_being_stopped_finishes_the_stop_and_restarts_them()
    {
        // Ignores the graceful stop (SIGTERM; CTRL_BREAK on Windows): the stop takes stopTimeoutSeconds (3 s) and ends with a kill.
        var ready = Path.Combine(_checkout.Root, "stubborn.ready");
        var (queue, supervisor, _, _) = Create($$"""
                                                 stubborn:
                                                   repo: octo-a
                                                   workingDirectory: .
                                                   command: pwsh
                                                   args: {{TestProcess.ShellArgs(TestProcess.StubbornScript(ready))}}
                                               """);
        await supervisor.StartStackAsync("s1", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var firstPid = (await supervisor.StatusAsync(false)).Services.Single().Pid;
        SpinWait.SpinUntil(() => File.Exists(ready), 30_000).Should().BeTrue("the script ignores the stop only once its handler is in place");

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a", StopServices = true });
        await WaitAsync(queue, job.Id, b => b.Progress?.Phase == "stopping");
        queue.Cancel(job.Id, "s1");
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("canceled");
        done.StoppedServices.Should().Equal("stubborn");
        done.Notes.Should().Contain(n => n.StartsWith("restarted stubborn"));
        ProcessTree.IsAlive(firstPid).Should().BeFalse();
        var after = (await supervisor.StatusAsync(false)).Services.Single();
        after.Pid.Should().NotBe(firstPid);
        after.State.Should().NotBe("exited");
        _fake.BuildCalls.Should().BeEmpty("nothing was built after the cancel");
        await supervisor.StopServicesAsync("s1", null, CancellationToken.None);
    }

    [Fact]
    public async Task An_external_service_of_a_plan_repo_with_unknown_working_directory_counts_as_a_conflict()
    {
        var (queue, _, _, _) = Create();
        var unknown = External(Sleep().Id, Path.Combine(_checkout.Lane, "octo-a"), nonInteractive: true);
        _external = unknown with { Services = [unknown.Services[0] with { RepoPath = null, WorkingDirectory = null }] };

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        plan.Conflicts.Should().ContainSingle().Which.StartedBy.Should().Contain("could not determine where pid");
        var act = () => queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        await act.Should().ThrowAsync<InvalidOperationException>().WithMessage("*could not determine*");

        (await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-b" })).Conflicts.Should()
            .BeEmpty("the sleeper's configured repo is octo-a");
    }

    [Fact]
    public async Task On_Windows_plans_see_external_processes_and_kind_all_needs_skipKill_and_a_lane_scoped_kill()
    {
        _fake.AllPlan = AllPlan();
        var (queue, _, _, _) = Create(options: new BuildQueueOptions { IsWindows = true });

        var plan = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" });
        plan.Warnings.Should().NotContain(w => w.Contains("cannot see processes"), "the Windows scan sees processes the daemon did not start");
        var all = await queue.Plan(new BuildRequest { Owner = "s1", Kind = BuildKind.All });
        all.Steps.Single().Command.Should().Contain("-skipKill");

        _fake.Capabilities = FakePwsh.MainParams;
        var (old, _, _, _) = Create(options: new BuildQueueOptions { IsWindows = true });
        var refused = () => old.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.All, Confirm = true });
        await refused.Should().ThrowAsync<InvalidOperationException>().WithMessage("*refused on Windows*-skipKill*-branchRootPath*");
    }

    [Fact]
    public async Task Every_build_related_call_sets_octo_tools_root_to_the_daemons_rootPath()
    {
        // profile.ps1 of an octo-tools worktree sets $rootPath to .../octo-tools/.claude/worktrees, and the cmdlets resolve
        // -branch against it: the daemon must set its own rootPath first.
        var (queue, _, lease, _) = Create();
        lease.Require("s1");
        _fake.RangePlan = RangePlan("octo-a");

        var job = await queue.Enqueue(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", Publish = true });
        await WaitAsync(queue, job.Id);

        var prelude = $"$global:rootPath = '{_checkout.Root}'; $Global:ROOTPATH = '{_checkout.Root}'; $env:ROOTPATH = '{_checkout.Root}'\n";
        var buildCalls = _fake.Calls.Where(c => !c.Body.Contains("Get-Command", StringComparison.Ordinal)).ToList();
        buildCalls.Should().HaveCountGreaterThan(1).And.OnlyContain(c => c.Body.StartsWith(prelude, StringComparison.Ordinal));
        buildCalls.Should().Contain(c => c.Body.Contains("-WhatIf")).And.Contain(c => c.Body.Contains("-EventsFile"));
    }

    [Fact]
    public void The_private_feed_mirrors_the_lane_feed_and_keeps_packages_built_into_it()
    {
        var laneNuget = Path.Combine(_checkout.Lane, "nuget");
        var feed = Path.Combine(_checkout.StateDirectory, "feeds", "s1", "nuget");
        Directory.CreateDirectory(laneNuget);
        File.WriteAllText(Path.Combine(laneNuget, "Meshmakers.A.999.0.0.nupkg"), "lane-a-1");
        File.WriteAllText(Path.Combine(laneNuget, "Meshmakers.B.999.0.0.nupkg"), "lane-b-1");

        PrivateFeed.Sync(feed, laneNuget).Should().Be(new PrivateFeed.SyncResult(2, 0, 0));
        PrivateFeed.OwnPackages(feed).Should().BeEmpty();

        // A is built into the private feed; the lane gets newer A and B.
        File.WriteAllText(Path.Combine(feed, "Meshmakers.A.999.0.0.nupkg"), "private-a");
        File.WriteAllText(Path.Combine(laneNuget, "Meshmakers.A.999.0.0.nupkg"), "lane-a-2");
        File.WriteAllText(Path.Combine(laneNuget, "Meshmakers.B.999.0.0.nupkg"), "lane-b-2");
        PrivateFeed.OwnPackages(feed).Should().Equal("Meshmakers.A.999.0.0.nupkg");

        PrivateFeed.Sync(feed, laneNuget).Should().Be(new PrivateFeed.SyncResult(0, 1, 1));
        File.ReadAllText(Path.Combine(feed, "Meshmakers.A.999.0.0.nupkg")).Should().Be("private-a", "a privately built package wins");
        File.ReadAllText(Path.Combine(feed, "Meshmakers.B.999.0.0.nupkg")).Should().Be("lane-b-2", "a mirrored package follows the lane");
        PrivateFeed.Sync(feed, laneNuget).Should().Be(new PrivateFeed.SyncResult(0, 0, 1));
    }

    [Fact]
    public void Extracted_packages_that_differ_from_the_private_feed_are_purged_from_the_private_cache()
    {
        var feed = Path.Combine(_checkout.StateDirectory, "feeds", "s1", "nuget");
        var cache = Path.Combine(_checkout.StateDirectory, "feeds", "s1", "packages");
        Directory.CreateDirectory(feed);
        File.WriteAllText(Path.Combine(feed, "Meshmakers.Smoke.Hub.999.0.0.nupkg"), "rebuilt");
        File.WriteAllText(Path.Combine(feed, "Meshmakers.Same.999.0.0.nupkg"), "same");
        var stale = Path.Combine(cache, "meshmakers.smoke.hub", "999.0.0");
        var current = Path.Combine(cache, "meshmakers.same", "999.0.0");
        Directory.CreateDirectory(stale);
        Directory.CreateDirectory(current);
        File.WriteAllText(Path.Combine(stale, "meshmakers.smoke.hub.999.0.0.nupkg"), "old build");
        File.WriteAllText(Path.Combine(current, "meshmakers.same.999.0.0.nupkg"), "same");

        PrivateFeed.PurgeStaleCache(feed, cache).Should().Equal("meshmakers.smoke.hub/999.0.0");

        Directory.Exists(stale).Should().BeFalse();
        Directory.Exists(current).Should().BeTrue();
    }
}
