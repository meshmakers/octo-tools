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
///     Builds across a daemon restart: a second <see cref="BuildQueue"/> on the same state folder stands for the next
///     daemon run (the first one lets go of its jobs with <c>Abandon</c>, as a dead process would). Detached steps are
///     pwsh scripts that wait for a gate file, started through the real <see cref="DetachedBuildLauncher"/>; no octo-tools,
///     no dotnet, no real lane.
/// </summary>
public sealed class BuildRestartTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly FakePwsh _fake = new();
    private readonly List<int> _pids = [];
    private readonly List<Process> _processes = [];

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        foreach (var pid in _pids.Where(ProcessTree.IsAlive))
        {
            ProcessTree.TerminateAsync(pid, TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult();
        }

        foreach (var p in _processes.Where(p => !p.HasExited))
        {
            p.Kill();
        }

        _checkout.Dispose();
    }

    /// <summary>
    ///     A build step as a pwsh script: writes plan and repoStart, waits for the gate file, then writes repoDone and done,
    ///     prints the cmdlet's -Json document and exits - through the real detached launcher of each OS.
    /// </summary>
    private sealed class ScriptLauncher(string gate, List<int> pids) : IBuildLauncher
    {
        public string Gate { get; } = gate;
        public int ExitCode { get; set; }
        public bool Success { get; set; } = true;
        public List<LaunchedBuild> Started { get; } = [];

        public LaunchedBuild Start(BuildLaunch launch)
        {
            var events = FakePwsh.EventsFile(launch.Body) ?? throw new InvalidOperationException("the step has no -EventsFile");
            var repo = launch.Body.Contains("octo-b", StringComparison.Ordinal) ? "octo-b" : "octo-a";
            var ok = Success ? "true" : "false";
            var start = Line("plan", $"\"repos\":[{{\"repo\":\"{repo}\",\"mode\":\"dotnet\"}}],\"count\":1") + "\n" +
                        Line("repoStart", $"\"repo\":\"{repo}\",\"index\":1,\"count\":1");
            var end = Line("repoDone", $"\"repo\":\"{repo}\",\"index\":1,\"count\":1,\"success\":{ok},\"seconds\":3,\"buildSeconds\":2,\"testSeconds\":0,\"packageSeconds\":1,\"copied\":0,\"purged\":0,\"logFile\":null") +
                      "\n" + Line("done", $"\"success\":{ok},\"failedRepo\":{(Success ? "null" : $"\"{repo}\"")},\"failedStep\":{(Success ? "null" : "\"build\"")},\"elapsedSeconds\":3");
            var json = FakePwsh.Ok("Invoke-Build", $$"""{"success":{{ok}},"exitCode":{{ExitCode}}}""").Output.Trim();
            var launcher = new DetachedBuildLauncher(_ => TestProcess.PwshCommand(StepScript(events, start, end, json)));
            var launched = launcher.Start(launch);
            lock (Started)
            {
                Started.Add(launched);
                pids.Add(launched.Pid);
            }

            return launched;
        }

        /// <summary>
        ///     The step. The values are literals in the command, one line each (a newline would end the cmd.exe line of the
        ///     Windows wrapper).
        /// </summary>
        private string StepScript(string events, string start, string end, string json)
        {
            static IEnumerable<string> Lines(string text) => text.Split('\n', StringSplitOptions.RemoveEmptyEntries);
            string Append(string line) => $"[IO.File]::AppendAllText({TestProcess.PwshLiteral(events)}, {TestProcess.PwshLiteral(line)} + [char]10)";
            return string.Join("; ", [
                ..Lines(start).Select(Append),
                $"while (-not [IO.File]::Exists({TestProcess.PwshLiteral(Gate)})) {{ Start-Sleep -Milliseconds 50 }}",
                ..Lines(end).Select(Append),
                ..Lines(json).Select(l => $"[Console]::Out.WriteLine({TestProcess.PwshLiteral(l.TrimEnd('\r'))})"),
                $"exit {ExitCode}"
            ]);
        }

        private static string Line(string name, string fields) =>
            $$"""{"schemaVersion":1,"ts":"{{DateTimeOffset.UtcNow:O}}","command":"Invoke-Build","event":"{{name}}",{{fields}}}""";
    }

    private string Gate => Path.Combine(_checkout.Root, "gate");

    private ScriptLauncher Launcher() => new(Gate, _pids);

    private BuildQueue Create(IBuildLauncher? launcher = null, FakePwsh? fake = null, BuildQueueOptions? options = null) => CreateAll(launcher, fake, options).Queue;

    private (BuildQueue Queue, StateStore State, LeaseManager Lease) CreateAll(IBuildLauncher? launcher = null, FakePwsh? fake = null, BuildQueueOptions? options = null)
    {
        var (queue, state, lease, _) = CreateWithSupervisor(launcher, fake, options);
        return (queue, state, lease);
    }

    /// <summary>A queue and its supervisor on the state folder (alpha runs from octo-a, sleeper from a repo that does not exist).</summary>
    private (BuildQueue Queue, StateStore State, LeaseManager Lease, StackSupervisor Supervisor) CreateWithSupervisor(IBuildLauncher? launcher = null,
        FakePwsh? fake = null, BuildQueueOptions? options = null)
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
                                          """);
        var lease = new LeaseManager();
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var state = new StateStore(paths);
        state.Load();
        var supervisor = new StackSupervisor(store, lease, state, NullLogger<StackSupervisor>.Instance);
        // As the daemon starts: the stacks of the state file are adopted before the build queue restores its jobs.
        supervisor.Restore(state.Load());
        var queue = new BuildQueue(store, supervisor, lease, paths, NullLogger<BuildQueue>.Instance, fake ?? _fake, state, null,
            options ?? new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(30) }, () => Task.FromResult(ExternalSnapshot.Empty), launcher: launcher);
        return (queue, state, lease, supervisor);
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
                throw new TimeoutException($"build {id} stays {status.State}: {status.Outcome?.Summary} | {string.Join("; ", status.Notes)}");
            }

            await Task.Delay(20, Ct);
        }
    }

    private static async Task UntilAsync(Func<bool> condition, string what)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException(what);
            }

            await Task.Delay(20, Ct);
        }
    }

    /// <summary>
    ///     Until the step's process is started, has written its repoStart event and its pid is in the job file - only then
    ///     does the next queue on this state folder know the process (the events can be there before the pid is written).
    /// </summary>
    private async Task RunningAsync(BuildQueue queue, string id, ScriptLauncher launcher)
    {
        await WaitAsync(queue, id, s => s.Progress?.Current != null);
        var jobFile = BuildFile(id + ".job.json");
        await UntilAsync(() =>
        {
            int pid;
            lock (launcher.Started)
            {
                if (launcher.Started.Count == 0)
                {
                    return false;
                }

                pid = launcher.Started[^1].Pid;
            }

            try
            {
                return File.Exists(jobFile) && File.ReadAllText(jobFile).Contains($"\"Pid\": {pid}", StringComparison.Ordinal);
            }
            catch (IOException)
            {
                return false; // being replaced right now
            }
        }, "the job file never recorded the pid of the started process");
    }

    private static BuildRequest Repo(string name, string owner = "s1") => new() { Owner = owner, Kind = BuildKind.Repo, Path = name };

    private string BuildFile(string name) => Path.Combine(_checkout.StateDirectory, "builds", name);

    // ---------- detached steps ----------

    [Fact]
    public async Task A_detached_step_leaves_its_output_in_the_job_log_and_its_exit_code_in_the_marker()
    {
        var log = Path.Combine(_checkout.Root, "builds", "x.log");
        var exit = Path.Combine(_checkout.Root, "builds", "x.1.exit");
        var launcher = new DetachedBuildLauncher(_ => TestProcess.PwshCommand(
            "[Console]::Out.WriteLine('out'); [Console]::Error.WriteLine('err'); Start-Sleep -Milliseconds 500; exit 7"));

        var launched = launcher.Start(new BuildLaunch(_checkout.Root, "", log, exit, new Dictionary<string, string?>()));
        await launched.Process!.WaitForExitAsync(Ct);

        BuildStepFiles.ReadExit(exit).Should().Be(7);
        File.ReadAllText(log).Should().Contain("out").And.Contain("err");
        launched.ProcessStart.Should().NotBeNull();
    }

    [Fact]
    public void The_Windows_wrapper_moves_the_exit_code_into_the_marker_and_expands_nothing_of_the_script()
    {
        var arguments = DetachedBuildLauncher.WindowsWrapperArguments("pwsh", ["-Command", "Invoke-Build -Json '100%'"], @"C:\state\builds\b1.log", @"C:\state\builds\b1.1.exit");

        arguments.Should().StartWith("/d /v:off /s /c \"").And.EndWith(
            " & call echo %^ERRORLEVEL%>\"C:\\state\\builds\\b1.1.exit.tmp\" & move /y \"C:\\state\\builds\\b1.1.exit.tmp\" \"C:\\state\\builds\\b1.1.exit\" >NUL\"");
        arguments.Should().Contain(">>\"C:\\state\\builds\\b1.log\" 2>&1 & call");
        arguments.Should().Contain("100^%", "the script's percent sign is escaped; only the wrapper's ERRORLEVEL is expanded");
        var act = () => DetachedBuildLauncher.WindowsWrapperArguments("pwsh", [], @"C:\l.log", @"C:\%TEMP%\x.exit");
        act.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public async Task A_detached_build_succeeds_by_its_json_and_its_exit_marker()
    {
        var launcher = Launcher();
        var queue = Create(launcher);
        File.WriteAllText(Gate, "");

        var job = await queue.EnqueueAsync(Repo("octo-a"), Ct);
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be("octo-a built; test projects compiled, no test ran (lane_test / base_test run them)");
        done.Progress!.Repos!.Should().ContainSingle().Which.Should().Be(new BuildRepoProgress("octo-a", "done", 2, 0, 0, 0, 3, 1, Tests: "compiled"));
        BuildStepFiles.ReadExit(BuildFile(job.Id + ".1.exit")).Should().Be(0);
        File.Exists(BuildFile(job.Id + ".job.json")).Should().BeTrue();
        BuildJobStore.Deserialize(File.ReadAllText(BuildFile(job.Id + ".job.json")))!.Files.Should()
            .Contain(BuildFile(job.Id + ".1.ps1"), "the step script is one of the job's files and goes when the job is forgotten");
    }

    [Fact]
    public async Task A_detached_build_fails_when_the_exit_code_is_not_zero_although_the_json_says_success()
    {
        var launcher = Launcher();
        launcher.ExitCode = 3;
        var queue = Create(launcher);
        File.WriteAllText(Gate, "");

        var done = await WaitAsync(queue, (await queue.EnqueueAsync(Repo("octo-a"), Ct)).Id);

        done.State.Should().Be("failed");
        done.Outcome!.Summary.Should().Contain("exited with 3");
    }

    // ---------- restart while a build runs ----------

    [Fact]
    public async Task A_running_build_is_reattached_after_a_restart_and_finishes_with_its_result()
    {
        var launcher = Launcher();
        var first = Create(launcher);
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        await RunningAsync(first, job.Id, launcher);
        var pid = launcher.Started.Single().Pid;
        first.Abandon();

        var (second, state, _) = CreateAll(launcher);

        var running = second.Get(job.Id);
        running.State.Should().Be("running");
        running.Notes.Should().Contain(n => n.Contains("re-attached after the daemon restart") && n.Contains($"pid {pid}"));
        running.Progress!.Current!.Repo.Should().Be("octo-a");
        second.Active().Should().ContainSingle().Which.Should().BeEquivalentTo(new { Id = job.Id, State = "running", Pid = (int?)pid, SurvivesRestart = true });
        state.Load().RunningBuilds().Should().ContainSingle(b => b.Id == job.Id && b.Pid == pid);

        // The queue rules hold for it: a lane build runs alone, so the next one waits and says for what.
        var next = await second.EnqueueAsync(Repo("octo-b", "s2"), Ct);
        next.State.Should().Be("queued");
        next.Queue!.WaitingFor.Should().Contain(job.Id).And.Contain("s1");

        File.WriteAllText(Gate, "");
        var done = await WaitAsync(second, job.Id);
        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be("octo-a built; test projects compiled, no test ran (lane_test / base_test run them)");
        done.Progress!.Repos!.Single().Seconds.Should().Be(3);
        (await WaitAsync(second, next.Id)).State.Should().Be("succeeded");
        ProcessTree.IsAlive(pid).Should().BeFalse();
    }

    [Fact]
    public async Task A_build_that_ended_while_the_daemon_was_down_gets_its_result_from_marker_log_and_events()
    {
        var launcher = Launcher();
        var first = Create(launcher);
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        await RunningAsync(first, job.Id, launcher);
        first.Abandon();
        File.WriteAllText(Gate, "");
        await UntilAsync(() => File.Exists(BuildFile(job.Id + ".1.exit")), "the build never wrote its exit marker");

        var second = Create(launcher);
        var done = await WaitAsync(second, job.Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be("octo-a built; test projects compiled, no test ran (lane_test / base_test run them)");
        done.Notes.Should().Contain(n => n.Contains("had ended meanwhile"));
        second.Active().Should().BeEmpty();
    }

    [Fact]
    public async Task A_build_killed_while_the_daemon_was_down_fails_as_lost_and_blocks_nothing()
    {
        var launcher = Launcher();
        var first = Create(launcher);
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        await RunningAsync(first, job.Id, launcher);
        first.Abandon();
        await ProcessTree.TerminateAsync(launcher.Started.Single().Pid, TimeSpan.FromSeconds(2), Ct);

        var second = Create(launcher);
        var done = await WaitAsync(second, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.FailedStep.Should().Be("lost");
        done.Outcome.FailedRepo.Should().Be("octo-a");
        done.Outcome.Summary.Should().Contain("without a result");
        File.WriteAllText(Gate, "");
        (await WaitAsync(second, (await second.EnqueueAsync(Repo("octo-b"), Ct)).Id)).State.Should().Be("succeeded");
    }

    [Fact]
    public async Task A_reattached_build_is_canceled_by_its_owner_only()
    {
        var launcher = Launcher();
        var first = Create(launcher);
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        await RunningAsync(first, job.Id, launcher);
        var pid = launcher.Started.Single().Pid;
        first.Abandon();
        var second = Create(launcher);

        var foreign = () => second.Cancel(job.Id, "someone-else");
        foreign.Should().Throw<InvalidOperationException>().WithMessage("*belongs to 's1'*");
        ProcessTree.IsAlive(pid).Should().BeTrue();

        second.Cancel(job.Id, "s1");
        var done = await WaitAsync(second, job.Id);

        done.State.Should().Be("canceled");
        ProcessTree.IsAlive(pid).Should().BeFalse("build_cancel terminates the process tree the daemon started");
        File.Exists(BuildFile(job.Id + ".1.exit")).Should().BeFalse("a terminated wrapper leaves no marker");
    }

    [Fact]
    public async Task A_recorded_pid_that_now_is_another_process_is_not_taken_for_the_build()
    {
        var launcher = Launcher();
        var first = Create(launcher);
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        await RunningAsync(first, job.Id, launcher);
        first.Abandon();
        await ProcessTree.TerminateAsync(launcher.Started.Single().Pid, TimeSpan.FromSeconds(2), Ct);
        // The job file now names a pid of a process that is not the build (pid reuse): a sleeping bystander.
        var bystander = TestProcess.StartSleep(30);
        _processes.Add(bystander);
        var file = BuildFile(job.Id + ".job.json");
        File.WriteAllText(file, File.ReadAllText(file).Replace($"\"Pid\": {launcher.Started.Single().Pid}", $"\"Pid\": {bystander.Id}"));

        var second = Create(launcher);
        var done = await WaitAsync(second, job.Id);

        done.State.Should().Be("failed");
        done.Outcome!.FailedStep.Should().Be("lost");
        bystander.HasExited.Should().BeFalse("a process the daemon did not start is never signalled");
    }

    // ---------- WP-C: evidence and the services of a test run across a restart ----------

    [Fact]
    public async Task The_evidence_of_a_job_is_in_its_job_file_and_the_next_daemon_reads_the_end()
    {
        var repo = _checkout.GitRepo("octo-a");
        var head = _checkout.Git(repo, "rev-parse", "HEAD");
        File.WriteAllText(Path.Combine(repo, "edit.txt"), "the session's edit before the job");
        var launcher = Launcher();
        var first = Create(launcher);
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        await RunningAsync(first, job.Id, launcher);
        var start = first.Get(job.Id).Evidence!.Repos.Single().Start!;
        start.Should().Match<BuildRepoState>(s => s.Head == head && s.Clean == false && s.Changes == 1 && s.Fingerprint != null);
        first.Get(job.Id).Evidence!.Repos.Single().Should().Be(new BuildRepoEvidence("octo-a", repo, start, null));
        first.Abandon();
        File.WriteAllText(Path.Combine(repo, "edit.txt"), "the work tree changes while the daemon is down");

        var second = Create(launcher);
        second.Get(job.Id).Evidence!.Repos.Single().Start.Should().Be(start, "the start, fingerprint included, comes from the job file");
        File.WriteAllText(Gate, "");
        var done = await WaitAsync(second, job.Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Evidence!.Unchanged.Should().BeFalse("the edit changed while the job ran");
        done.Evidence.Repos.Single().Should().BeEquivalentTo(new
        {
            Start = start, End = new { Head = head, Branch = "main", Clean = false, Changes = 1 }, Unchanged = (bool?)false
        });
        done.Evidence.Repos.Single().End!.Fingerprint.Should().NotBe(start.Fingerprint);
        second.Abandon();
        BuildJobStore.Deserialize(File.ReadAllText(BuildFile(job.Id + ".job.json")))!.Evidence.Should().Equal(done.Evidence!.Repos);
        Create().Get(job.Id).Evidence.Should().BeEquivalentTo(done.Evidence, "a finished job answers with its evidence after the next restart too");
    }

    /// <summary>
    ///     A detached Invoke-OctoTestRun step as a pwsh script (every OS, through its real launcher): waits for the gate file,
    ///     prints the cmdlet's -Json document of one passed project and exits 0. It writes no events.
    /// </summary>
    private sealed class TestRunLauncher(string gate, List<int> pids) : IBuildLauncher
    {
        public List<int> Started { get; } = [];

        public LaunchedBuild Start(BuildLaunch launch)
        {
            var json = FakePwsh.Ok("Invoke-OctoTestRun",
                """{"success":true,"exitCode":0,"projects":[{"project":"A.Tests","state":"passed","success":true,"total":1,"passed":1,"failed":0,"skipped":0,"durationSeconds":1,"failedTests":[]}]}""").Output.Trim();
            var script = string.Join("; ", [
                $"while (-not [IO.File]::Exists({TestProcess.PwshLiteral(gate)})) {{ Start-Sleep -Milliseconds 50 }}",
                ..json.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => $"[Console]::Out.WriteLine({TestProcess.PwshLiteral(l.TrimEnd('\r'))})"),
                "exit 0"
            ]);
            var launched = new DetachedBuildLauncher(_ => TestProcess.PwshCommand(script)).Start(launch);
            lock (Started)
            {
                Started.Add(launched.Pid);
                pids.Add(launched.Pid);
            }

            return launched;
        }
    }

    [Fact]
    public async Task Services_a_test_run_stopped_stay_in_the_stack_across_a_restart_and_the_next_daemon_starts_them_again()
    {
        var launcher = new TestRunLauncher(Gate, _pids);
        var fake = new FakePwsh { Capabilities = FakePwsh.TestParams };
        var (first, _, _, firstSupervisor) = CreateWithSupervisor(launcher, fake);
        await firstSupervisor.StartStackAsync("s1", new StartSpec { Services = ["alpha"] }, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var before = (await firstSupervisor.StatusAsync(false)).Services.Single();
        _pids.Add(before.Pid);

        var job = await first.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Test, Repo = "octo-a" }, Ct);
        await UntilAsync(() =>
        {
            int pid;
            lock (launcher.Started)
            {
                if (launcher.Started.Count == 0)
                {
                    return false;
                }

                pid = launcher.Started[0];
            }

            try
            {
                return File.ReadAllText(BuildFile(job.Id + ".job.json")).Contains($"\"Pid\": {pid}", StringComparison.Ordinal);
            }
            catch (IOException)
            {
                return false;
            }
        }, "the test run never started its step");
        first.Get(job.Id).StoppedServices.Should().Equal("alpha");
        first.Abandon();

        var (second, _, _, secondSupervisor) = CreateWithSupervisor(launcher, fake);
        (await secondSupervisor.StatusAsync(false)).Services.Single().State.Should().Be("stopped-for-build", "the next daemon keeps it in the stack");
        File.WriteAllText(Gate, "");
        var done = await WaitAsync(second, job.Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Notes.Should().Contain(n => n.Contains("re-attached after the daemon restart")).And.Contain("restarted alpha");
        var after = (await secondSupervisor.StatusAsync(false)).Services.Single();
        _pids.Add(after.Pid);
        after.State.Should().NotBe("stopped-for-build");
        after.Pid.Should().NotBe(before.Pid);
        after.RepoPath.Should().Be(Path.Combine(_checkout.Lane, "octo-a"));
    }

    // ---------- queue and history across a restart ----------

    [Fact]
    public async Task Queued_builds_are_restored_in_their_order()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            await release.Task;
            return FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0}""");
        };
        var first = Create();
        var a = await first.EnqueueAsync(Repo("octo-a", "s1"), Ct);
        var b = await first.EnqueueAsync(Repo("octo-b", "s2"), Ct);
        var c = await first.EnqueueAsync(Repo("octo-a", "s3"), Ct);
        await WaitAsync(first, a.Id, s => s.State == "running");
        first.Abandon();

        var order = new List<string>();
        var fake = new FakePwsh
        {
            Build = (body, _, _) =>
            {
                lock (order)
                {
                    order.Add(body.Contains("octo-b", StringComparison.Ordinal) ? "octo-b" : "octo-a");
                }

                return Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0}"""));
            }
        };
        var second = Create(fake: fake);

        foreach (var id in new[] { a.Id, b.Id, c.Id })
        {
            (await WaitAsync(second, id)).State.Should().Be("succeeded");
        }

        order.Should().Equal("octo-a", "octo-b", "octo-a");
        second.List().Select(j => j.Owner).Should().Equal("s3", "s2", "s1");
        var later = await second.EnqueueAsync(Repo("octo-b", "s4"), Ct);
        later.Id.Should().StartWith("b4-", "the job numbers go on after a restart");
        release.SetResult();
    }

    [Fact]
    public async Task Finished_builds_of_an_earlier_run_still_answer_build_status_and_build_list()
    {
        _fake.Build = (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-Build", "repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":1");
            FakePwsh.Event(events, "Invoke-Build", "repoDone",
                "\"repo\":\"octo-a\",\"index\":1,\"count\":1,\"success\":true,\"seconds\":9,\"buildSeconds\":7,\"testSeconds\":1,\"packageSeconds\":1,\"copied\":2,\"purged\":0,\"logFile\":null");
            return Task.FromResult(FakePwsh.Ok("Invoke-Build", """{"success":true,"exitCode":0}"""));
        };
        var first = Create();
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        var before = await WaitAsync(first, job.Id);
        var canceled = await first.EnqueueAsync(Repo("octo-b"), Ct);
        await WaitAsync(first, canceled.Id);
        first.Abandon();

        var second = Create();

        var after = second.Get(job.Id);
        after.Should().BeEquivalentTo(before, o => o.Excluding(s => s.Times));
        after.Times.FinishedAt.Should().Be(before.Times.FinishedAt);
        after.Progress!.Repos!.Single().Should().Be(new BuildRepoProgress("octo-a", "done", 7, 1, 2, 0, 9, 1, Tests: "compiled"));
        second.List().Select(j => j.Id).Should().Equal(canceled.Id, job.Id);
        var unknown = () => second.Get("b99-000000");
        unknown.Should().Throw<InvalidOperationException>().WithMessage("*keeps the last 50 finished jobs*");
    }

    [Fact]
    public async Task A_job_file_reads_back_as_it_was_written()
    {
        var queue = Create();
        var job = await queue.EnqueueAsync(Repo("octo-a"), Ct);
        await WaitAsync(queue, job.Id);
        queue.Abandon();
        var text = File.ReadAllText(BuildFile(job.Id + ".job.json"));

        var record = BuildJobStore.Deserialize(text)!;

        BuildJobStore.Serialize(record).Should().Be(text);
        record.Plan!.Steps.Single().Script.Should().StartWith("Invoke-Build -repositoryPath");
        record.Request.Owner.Should().Be("s1");
    }

    /// <summary>
    ///     A detached build.ps1 repo step as a pwsh script (every OS, through its real launcher): waits for the gate file,
    ///     prints the step's own -Json document (command octo-devstack-repo-build) and exits 0. It writes no build events,
    ///     like the real step. The document's lines are literals, one per line (a newline would end the cmd.exe line).
    /// </summary>
    private sealed class RepoScriptLauncher(string gate, List<int> pids) : IBuildLauncher
    {
        public List<int> Started { get; } = [];

        public LaunchedBuild Start(BuildLaunch launch)
        {
            var json = FakePwsh.Ok(BuildPlanner.RepoScriptCommand, """{"success":true,"exitCode":0,"mode":"script","detail":"build.ps1"}""").Output.Trim();
            var script = string.Join("; ", [
                $"while (-not [IO.File]::Exists({TestProcess.PwshLiteral(gate)})) {{ Start-Sleep -Milliseconds 50 }}",
                ..json.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => $"[Console]::Out.WriteLine({TestProcess.PwshLiteral(l.TrimEnd('\r'))})"),
                "exit 0"
            ]);
            var launcher = new DetachedBuildLauncher(_ => TestProcess.PwshCommand(script));
            var launched = launcher.Start(launch);
            lock (Started)
            {
                Started.Add(launched.Pid);
                pids.Add(launched.Pid);
            }

            return launched;
        }
    }

    [Fact]
    public async Task A_build_ps1_step_that_ended_while_the_daemon_was_down_is_judged_by_its_own_result_command()
    {
        // The restored step must read the octo-devstack-repo-build document, not Invoke-Build's (StepSpec.ResultCommand, AB#9417).
        File.WriteAllText(Path.Combine(_checkout.Repo("octo-a"), "build.ps1"), "exit 0");
        var launcher = new RepoScriptLauncher(Gate, _pids);
        var first = Create(launcher);
        var job = await first.EnqueueAsync(Repo("octo-a"), Ct);
        var jobFile = BuildFile(job.Id + ".job.json");
        await UntilAsync(() =>
        {
            int pid;
            lock (launcher.Started)
            {
                if (launcher.Started.Count == 0)
                {
                    return false;
                }

                pid = launcher.Started[^1];
            }

            try
            {
                return File.Exists(jobFile) && File.ReadAllText(jobFile).Contains($"\"Pid\": {pid}", StringComparison.Ordinal);
            }
            catch (IOException)
            {
                return false; // being replaced right now
            }
        }, "the job file never recorded the pid of the started process");
        first.Abandon();
        File.WriteAllText(Gate, "");
        await UntilAsync(() => File.Exists(BuildFile(job.Id + ".1.exit")), "the step never wrote its exit marker");

        var second = Create(launcher);
        var done = await WaitAsync(second, job.Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be("octo-a built (mode script)");
        done.Notes.Should().Contain(n => n.Contains("had ended meanwhile"));
        second.Active().Should().BeEmpty();
    }

    [Fact]
    public void An_unreadable_job_file_is_set_aside_and_the_others_are_restored()
    {
        Directory.CreateDirectory(BuildFile(""));
        File.WriteAllText(BuildFile("b1-000000.job.json"), "{ not json");

        var queue = Create();

        queue.List().Should().BeEmpty();
        File.Exists(BuildFile("b1-000000.job.json.corrupt")).Should().BeTrue();
    }

    // ---------- builds of a daemon version without job files ----------

    private (Process Process, string Events) LegacyBuild(string id, string kind, string target, bool withEvents = true)
    {
        var process = TestProcess.StartSleep(30);
        _processes.Add(process);
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var events = BuildFile(id + ".1.events.jsonl");
        if (withEvents)
        {
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "plan", "\"repos\":[{\"repo\":\"octo-a\",\"mode\":\"dotnet\"}],\"count\":1");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":1");
        }

        new StateStore(paths).SaveBuild(new PersistedBuild
            { Id = id, Owner = "s0", Kind = kind, Target = target, Pid = process.Id, StartedAt = DateTimeOffset.Now.AddMinutes(-5), LogFile = BuildFile(id + ".log") });
        return (process, events);
    }

    private static BuildQueueOptions LegacyOptions => new() { PollInterval = TimeSpan.FromMilliseconds(30), IsBuildProcess = ProcessTree.IsAlive };

    [Fact]
    public async Task A_build_of_an_older_daemon_is_adopted_as_a_running_job_its_owner_can_cancel()
    {
        var (process, _) = LegacyBuild("b3-104847", "env", "ab8797");

        var queue = Create(options: LegacyOptions);

        var adopted = queue.Get("b3-104847");
        adopted.State.Should().Be("running");
        adopted.Env.Should().Be("ab8797");
        adopted.Owner.Should().Be("s0");
        adopted.Progress!.Current!.Repo.Should().Be("octo-a");
        adopted.Notes.Should().Contain(n => n.Contains("re-attached") && n.Contains("without exit markers"));

        // It counts as a running environment build: a lane build waits for it instead of being refused.
        var lane = await queue.EnqueueAsync(Repo("octo-b", "s1"), Ct);
        lane.State.Should().Be("queued");
        lane.Queue!.WaitingFor.Should().Contain("b3-104847");
        var later = await queue.EnqueueAsync(Repo("octo-a", "s1"), Ct);
        later.Id.Should().StartWith("b5-", "the adopted job keeps its number");

        var foreign = () => queue.Cancel("b3-104847", "s1");
        foreign.Should().Throw<InvalidOperationException>();
        queue.Cancel("b3-104847", "someone", env: "ab8797").State.Should().Be("running", "any session of the environment may cancel it; the kill follows");
        (await WaitAsync(queue, "b3-104847")).State.Should().Be("canceled");
        await process.WaitForExitAsync(Ct);
        (await WaitAsync(queue, lane.Id)).State.Should().Be("succeeded");
    }

    [Fact]
    public async Task An_adopted_build_that_ends_gets_its_result_from_its_done_event()
    {
        var (process, events) = LegacyBuild("b2-090000", "env", "ab1");
        var queue = Create(options: LegacyOptions);
        queue.Get("b2-090000").State.Should().Be("running");

        FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoDone",
            "\"repo\":\"octo-a\",\"index\":1,\"count\":1,\"success\":true,\"seconds\":40,\"buildSeconds\":30,\"testSeconds\":0,\"packageSeconds\":10,\"copied\":3,\"purged\":1,\"logFile\":null");
        FakePwsh.Event(events, "Invoke-BuildEnvironment", "done", "\"success\":true,\"failedRepo\":null,\"failedStep\":null,\"elapsedSeconds\":41");
        process.Kill();
        var done = await WaitAsync(queue, "b2-090000");

        done.State.Should().Be("succeeded");
        done.Outcome!.Summary.Should().Be("1 repo(s) built (the process left no exit code; result from its build events)");
        done.Progress!.Totals.Should().Be(new BuildPhaseSeconds(30, 0, 10, null));
    }

    [Fact]
    public async Task An_adopted_build_that_was_gone_at_the_start_or_ends_without_events_is_reported_as_lost()
    {
        var (process, _) = LegacyBuild("b2-090000", "range", "branches/main: a -> b", withEvents: false);
        process.Kill();
        await process.WaitForExitAsync(Ct);

        var queue = Create(options: LegacyOptions);
        var done = await WaitAsync(queue, "b2-090000");

        done.State.Should().Be("failed");
        done.Outcome!.FailedStep.Should().Be("lost");
        done.Env.Should().BeNull();
        (await WaitAsync(queue, (await queue.EnqueueAsync(Repo("octo-a"), Ct)).Id)).State.Should().Be("succeeded");
    }

    // ---------- output ----------

    [Fact]
    public async Task The_output_of_a_build_lists_repos_with_errors_first_and_keeps_their_logs_masked()
    {
        var logA = Path.Combine(_checkout.Lane, "octo-a", "Invoke-Build.log");
        var logB = Path.Combine(_checkout.Lane, "octo-b", "Invoke-Build.log");
        _fake.BuildOrder = ["octo-a", "octo-b"];
        _fake.RangePlan = """{"whatIf":true,"lane":{"isolated":false},"packageCaches":["/cache"],"repositories":[{"repo":"octo-a","mode":"dotnet"},{"repo":"octo-b","mode":"dotnet"}]}""";
        _fake.Build = (body, _, _) =>
        {
            File.WriteAllText(logA, "restoring from https://user:topsecret@feed.example/v3/index.json\nBuild succeeded.\n    1 Warning(s)\n    0 Error(s)\n");
            File.WriteAllText(logB, "/x/Foo.cs(3,5): error CS1002: ; expected [/x/Foo.csproj]\n    0 Warning(s)\n    1 Error(s)\n");
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-BuildRange", "repoDone",
                $"\"repo\":\"octo-a\",\"index\":1,\"count\":2,\"success\":true,\"seconds\":5,\"buildSeconds\":4,\"testSeconds\":0,\"packageSeconds\":1,\"copied\":1,\"purged\":0,\"logFile\":{JsonSerializer.Serialize(logA)}");
            FakePwsh.Event(events, "Invoke-BuildRange", "repoDone",
                $"\"repo\":\"octo-b\",\"index\":2,\"count\":2,\"success\":false,\"seconds\":2,\"buildSeconds\":2,\"testSeconds\":0,\"packageSeconds\":0,\"copied\":0,\"purged\":0,\"logFile\":{JsonSerializer.Serialize(logB)}");
            return Task.FromResult(FakePwsh.Ok("Invoke-BuildRange", """{"success":false,"failedRepo":"octo-b","failedStep":"build","repositories":[],"notBuilt":[]}""", exitCode: 1));
        };
        var (first, _, lease) = CreateAll();
        lease.Require("s1");
        var job = await first.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Range, From = "octo-a", To = "octo-b", Publish = true }, Ct);
        (await WaitAsync(first, job.Id)).State.Should().Be("failed");
        File.Delete(logA);
        File.Delete(logB);
        first.Abandon();

        // After a restart, with the repos' own logs gone.
        var queue = Create();
        var output = queue.Output(job.Id);

        output.Repos.Select(r => r.Repo).Should().Equal("octo-b", "octo-a");
        output.Repos[0].Should().BeEquivalentTo(new { State = "failed", ErrorCount = 1, HasLog = true, BuildSeconds = 2.0 });
        output.Repos[0].Errors.Single().Code.Should().Be("CS1002");
        output.Repos[1].Should().BeEquivalentTo(new { State = "done", ErrorCount = 0, WarningCount = 1, HasLog = true, PackageSeconds = 1.0 });
        output.Log.Source.Should().Be("job");

        var repo = queue.Output(job.Id, "octo-a");
        repo.Log.Selected.Should().Be("octo-a");
        repo.Log.Source.Should().Be("kept");
        string.Join('\n', repo.Log.Lines).Should().Contain("https://***@feed.example").And.NotContain("topsecret");
        queue.Get(job.Id).Logs.PerRepo!.Keys.Should().Equal(["octo-b"], "build_status stays compact: only the failed repos' logs");
    }
}
