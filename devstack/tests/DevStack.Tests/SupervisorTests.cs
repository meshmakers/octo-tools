using System.Net;
using System.Net.Sockets;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>Runs real, harmless processes (sleep, sh, echo) - no OctoMesh service, no pwsh.</summary>
public sealed class SupervisorTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    private (StackSupervisor Supervisor, LeaseManager Lease, StateStore State) Create(string servicesYaml)
    {
        _checkout.Repo("tools");
        var store = _checkout.WriteConfig(servicesYaml);
        var lease = new LeaseManager();
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        var supervisor = new StackSupervisor(store, lease, state, NullLogger<StackSupervisor>.Instance);
        return (supervisor, lease, state);
    }


    [Fact]
    public async Task Starts_reports_and_stops_a_service()
    {
        var (supervisor, _, state) = Create("""
                                              sleeper:
                                                repo: tools
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            """);

        var result = await supervisor.StartStackAsync("tester", null, null, false, waitForHealthy: true,
            TimeSpan.FromSeconds(5), CancellationToken.None);

        var service = result.Status.Services.Should().ContainSingle().Subject;
        service.Name.Should().Be("sleeper");
        service.State.Should().Be("healthy", "a service without ports is healthy while alive");
        ProcessTree.IsAlive(service.Pid).Should().BeTrue();
        result.Status.BaseLane.Should().Be(_checkout.Lane);
        result.Status.Lease.Holder!.Owner.Should().Be("tester");
        state.Load().Stack!.Services.Should().ContainSingle(s => s.Pid == service.Pid);
        TestProcess.ReadLog(service.LogFile).Should().Contain("# octo-devstack").And.Contain(TestProcess.SleepCommand(30));

        var stop = await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
        stop.Stopped.Should().Equal("sleeper");
        stop.Status.Running.Should().BeFalse();
        ProcessTree.IsAlive(service.Pid).Should().BeFalse();
        state.Load().Stack.Should().BeNull();
    }

    /// <summary>Blocks only the one repository folder; any other path it is asked about passes.</summary>
    private sealed class Guard(BuildGuardHit hit, string repoPath) : IBuildGuard
    {
        public BuildGuardHit? Blocking(string path) => PathScope.SamePath(path, repoPath) ? hit : null;
    }

    [Fact]
    public async Task A_service_does_not_start_from_a_folder_a_job_works_on_and_the_refusal_says_which_job_and_how_to_wait()
    {
        var (supervisor, _, _) = Create("""
                                          sleeper:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        """);
        Task Start() => supervisor.StartStackAsync("tester", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        var tools = Path.Combine(_checkout.Lane, "tools");
        supervisor.BuildGuard = new Guard(new BuildGuardHit("b7", "alice", "branches/main: octo-a..octo-b"), tools);
        (await FluentActions.Awaiting(Start).Should().ThrowAsync<InvalidOperationException>()).Which.Message.Should()
            .Be($"sleeper runs out of {Path.Combine(_checkout.Lane, "tools")}, which job b7 (a build of alice: branches/main: octo-a..octo-b) is working on. " +
                "Wait for the job to end (job_status(\"b7\", waitSeconds=600)) and start sleeper afterwards.");

        supervisor.BuildGuard = new Guard(new BuildGuardHit("t3", "bob", "ab1: tests of tools") { TestRun = true }, tools);
        (await FluentActions.Awaiting(Start).Should().ThrowAsync<InvalidOperationException>()).Which.Message.Should()
            .Contain("which job t3 (a test run of bob: ab1: tests of tools) is working on - the run stopped the services of that repository")
            .And.Contain("job_status(\"t3\", waitSeconds=600)");
    }

    [Fact]
    public async Task Arguments_reach_the_process_verbatim_and_env_is_applied()
    {
        // Through each OS's launcher: /bin/sh exec on macOS/Linux, the cmd.exe log wrapper on Windows (cmd metacharacters,
        // %variables% and quotes must reach the program unchanged there).
        string[] values = ["a b", "it's", "$HOME", "%PATH%", "x&y^z|w", "q\"uote", "(p)<r>!"];
        _checkout.Repo("tools");
        File.WriteAllText(Path.Combine(_checkout.Lane, "tools", "echo.ps1"),
            "Write-Output ('[' + ($args -join '] [') + '] [' + $env:GREETING + ']'); exit 7");
        string[] args = ["-NoProfile", "-File", "echo.ps1", .. values];
        var (supervisor, _, _) = Create($$"""
                                          echo:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: {{System.Text.Json.JsonSerializer.Serialize(args)}}
                                            env: { GREETING: "hi ${service}" }
                                        """);

        var result = await supervisor.StartStackAsync("tester", null, null, false, waitForHealthy: false,
            TimeSpan.FromSeconds(1), CancellationToken.None);
        var service = result.Status.Services.Single();
        SpinWait.SpinUntil(() => !ProcessTree.IsAlive(service.Pid), 10000);
        await Task.Delay(500, TestContext.Current.CancellationToken);

        var log = TestProcess.ReadLog(service.LogFile);
        log.Should().Contain("[a b] [it's] [$HOME] [%PATH%] [x&y^z|w] [q\"uote] [(p)<r>!] [hi echo]");
        log.Should().StartWith("# octo-devstack", "the daemon writes the header line before the wrapper appends");
        (await supervisor.StatusAsync()).Services.Single().ExitCode.Should().Be(7, "the service's exit code reaches the daemon (through cmd.exe on Windows)");
    }

    [Fact]
    public async Task Crashed_service_is_reported_with_exit_code_and_log_tail_and_the_rest_keeps_running()
    {
        var (supervisor, _, _) = Create("""
                                          crasher:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Write-Output boom-from-crasher; exit 3"]
                                          sleeper:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        """);

        await supervisor.StartStackAsync("tester", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        // Until the crasher's exit is seen (a slow pwsh start takes longer than any fixed wait), bounded.
        StackStatus status;
        var deadline = DateTime.UtcNow.AddSeconds(15);
        do
        {
            await Task.Delay(100, TestContext.Current.CancellationToken);
            status = await supervisor.StatusAsync();
        } while (status.Services.Single(s => s.Name == "crasher").State != "exited" && DateTime.UtcNow < deadline);

        var crasher = status.Services.Single(s => s.Name == "crasher");
        crasher.State.Should().Be("exited");
        crasher.ExitCode.Should().Be(3);
        crasher.LogTail.Should().Contain("boom-from-crasher");
        status.Services.Single(s => s.Name == "sleeper").State.Should().Be("healthy");
        status.Running.Should().BeTrue();

        // A crashed service can be started again without stopping the stack.
        var again = await supervisor.StartServicesAsync("tester", ["crasher"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        again.Status.Services.Should().Contain(s => s.Name == "crasher");

        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    [Fact]
    public async Task Port_in_use_refuses_the_start_and_names_the_holder()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var (supervisor, _, _) = Create($"""
                                           web:
                                             repo: tools
                                             workingDirectory: .
                                             command: pwsh
                                             args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                             ports: [{port}]
                                         """);

        var act = () => supervisor.StartStackAsync("tester", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var error = await act.Should().ThrowAsync<InvalidOperationException>();
        error.WithMessage($"*port {port} is in use*");
        error.WithMessage($"*pid {Environment.ProcessId}*", "lsof, /proc on Linux without it, the TCP table on Windows: each names the process holding the port");

        (await supervisor.StatusAsync()).Running.Should().BeFalse();
    }

    [Fact]
    public async Task Missing_binary_fails_unless_the_service_is_optional()
    {
        var (supervisor, _, _) = Create("""
                                          required:
                                            repo: octo-required
                                            args: [Required.dll]
                                          extra:
                                            repo: octo-extra
                                            optional: true
                                            args: [Extra.dll]
                                          sleeper:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        """);

        var act = () => supervisor.StartStackAsync("tester", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        (await act.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*Not built for DebugL: required*");

        var result = await supervisor.StartStackAsync("tester", new StartSpec { Exclude = ["required"] }, null, false, false, TimeSpan.FromSeconds(1),
            CancellationToken.None);
        result.Skipped.Should().ContainSingle(s => s.StartsWith("extra:"));
        result.Status.Services.Select(s => s.Name).Should().Equal("sleeper");
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    [Fact]
    public async Task Other_session_cannot_change_the_stack_while_it_holds_no_lease()
    {
        var (supervisor, lease, _) = Create("""
                                              sleeper:
                                                repo: tools
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            """);
        await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        var act = () => supervisor.StopServicesAsync("b", null, CancellationToken.None);
        await act.Should().ThrowAsync<LeaseHeldException>();

        var second = () => supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        (await second.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*already running*");

        lease.Release("a", false);
        await supervisor.StopServicesAsync("b", null, CancellationToken.None);
    }

    [Fact]
    public async Task Restart_switches_a_service_to_a_worktree_and_back()
    {
        var (supervisor, _, _) = Create("""
                                          sleeper:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        """);
        var worktree = _checkout.Repo("wt-1-tools");
        await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        var switched = await supervisor.RestartServicesAsync("a", ["sleeper"],
            new Dictionary<string, ServiceOverride> { ["sleeper"] = new() { Source = "wt-1-tools" } }, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        switched.Status.Services.Single().Source.Should().Be(worktree);
        switched.Status.Services.Single().WorkingDirectory.Should().Be(worktree);

        var kept = await supervisor.RestartServicesAsync("a", ["sleeper"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        kept.Status.Services.Single().Source.Should().Be(worktree, "a restart without overrides keeps the previous ones");

        var back = await supervisor.RestartServicesAsync("a", ["sleeper"],
            new Dictionary<string, ServiceOverride> { ["sleeper"] = new() }, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        back.Status.Services.Single().Source.Should().BeNull();

        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Every_service_names_who_started_or_overrode_it_also_after_a_build_and_a_daemon_restart()
    {
        // The shared stack (UC-A): a started the stack, b runs its worktree of one service in it. A build conflict or a
        // question about that service is for b, not for a.
        var (supervisor, lease, state) = Create("""
                                                  sleeper:
                                                    repo: tools
                                                    workingDirectory: .
                                                    command: pwsh
                                                    args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                                  other:
                                                    repo: tools
                                                    workingDirectory: .
                                                    command: pwsh
                                                    args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                                """);
        _checkout.Repo("wt-1-tools");
        await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        lease.Release("a", false);

        await supervisor.RestartServicesAsync("b", ["sleeper"],
            new Dictionary<string, ServiceOverride> { ["sleeper"] = new() { Source = "wt-1-tools" } }, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var status = (await supervisor.RestartServicesAsync("b", ["other"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None)).Status;

        status.StartedBy.Should().Be("a", "the stack's starter stays");
        Origin(status, "sleeper").Should().Be(("b", "service_restart"));
        Origin(status, "other").Should().Be(("a", "stack_start"), "a restart without overrides changes nothing about what runs");

        // A build stops the service and starts it again: it still runs what b chose.
        var stopped = await supervisor.StopForBuildAsync("b", ["sleeper"], CancellationToken.None);
        Origin(await supervisor.StatusAsync(false), "sleeper").Should().Be(("b", "service_restart"), "stopped for the build");
        Origin((await supervisor.StartAfterBuildAsync("b", stopped, CancellationToken.None)).Status, "sleeper").Should().Be(("b", "service_restart"));

        state.Load().Stack!.Services.Single(s => s.Name == "sleeper").Should().Match<PersistedService>(s => s.StartedBy == "b" && s.StartedVia == "service_restart");
        var next = new StackSupervisor(new ConfigStore(_checkout.ConfigPath), new LeaseManager(), state, NullLogger<StackSupervisor>.Instance);
        next.Restore(state.Load().Stack);
        var adopted = await next.StatusAsync(false);
        Origin(adopted, "sleeper").Should().Be(("b", "service_restart"));
        Origin(adopted, "other").Should().Be(("a", "stack_start"));

        SlotRun.OriginOf(new PersistedService { Name = "x" }, "a").Should().Be(new ServiceOrigin("a", "stack_start"),
            "a state file of an older daemon has no starter per service: the stack's starter");
        await next.StopServicesAsync("b", null, CancellationToken.None);
    }

    private static (string?, string?) Origin(StackStatus status, string service) =>
        status.Services.Single(s => s.Name == service) is var s ? (s.StartedBy, s.StartedVia) : default;

    [Fact]
    public async Task A_new_daemon_adopts_running_services_from_the_state_file()
    {
        var (supervisor, _, state) = Create("""
                                              sleeper:
                                                repo: tools
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            """);
        var started = await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var pid = started.Status.Services.Single().Pid;

        var next = new StackSupervisor(new ConfigStore(_checkout.ConfigPath), new LeaseManager(), state, NullLogger<StackSupervisor>.Instance);
        next.Restore(state.Load().Stack);
        var status = await next.StatusAsync();
        var adopted = status.Services.Should().ContainSingle().Subject;
        adopted.Pid.Should().Be(pid);
        adopted.Adopted.Should().BeTrue();
        status.BaseLane.Should().Be(_checkout.Lane);
        status.Lane.Should().BeNull("the shared stack is no lane's");

        await next.StopServicesAsync("a", null, CancellationToken.None);
        ProcessTree.IsAlive(pid).Should().BeFalse();
    }

    [Fact]
    public async Task A_new_daemon_knows_the_services_a_running_build_stopped()
    {
        // Builds survive a daemon restart, and so must what they stopped: shown as stopped-for-build, and service_restart
        // starts it before the build ends, as it did before the restart.
        var (supervisor, _, state) = Create("""
                                              sleeper:
                                                repo: tools
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            """);
        await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        await supervisor.StopForBuildAsync("a", ["sleeper"], CancellationToken.None);
        state.Load().Stack!.StoppedForBuild.Should().ContainSingle(s => s.Name == "sleeper");

        var next = new StackSupervisor(new ConfigStore(_checkout.ConfigPath), new LeaseManager(), state, NullLogger<StackSupervisor>.Instance);
        next.Restore(state.Load().Stack);
        var status = await next.StatusAsync(includeLogTail: false);
        status.Services.Should().ContainSingle().Which.State.Should().Be("stopped-for-build");

        var restarted = await next.RestartServicesAsync("a", ["sleeper"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        restarted.Status.Services.Should().ContainSingle().Which.State.Should().NotBe("stopped-for-build");
        state.Load().Stack!.StoppedForBuild.Should().BeEmpty("it runs again");
        await next.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_service_a_build_stopped_starts_once_when_it_is_named_twice()
    {
        // It keeps its override (here env), so service_start rebuilds it from that - also when the name is repeated.
        var (supervisor, _, _) = Create("""
                                          sleeper:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        """);
        var spec = new StartSpec { Overrides = new() { ["sleeper"] = new ServiceOverride { Env = new() { ["DEVSTACK_TEST"] = "1" } } } };
        await supervisor.StartStackAsync("a", spec, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        await supervisor.StopForBuildAsync("a", ["sleeper"], CancellationToken.None);

        var started = await supervisor.StartServicesAsync("a", ["sleeper", "sleeper"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        started.Status.Services.Should().ContainSingle().Which.State.Should().NotBe("stopped-for-build");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_pid_with_another_start_time_is_not_adopted()
    {
        var (supervisor, _, state) = Create("""
                                              sleeper:
                                                repo: tools
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            """);
        var started = await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var pid = started.Status.Services.Single().Pid;
        var persisted = state.Load().Stack!;
        persisted.Services.Single().ProcessStartTime.Should().NotBeNull("the launch records the OS start time");

        // As if the service had died and the OS had given its pid to a process started an hour later.
        persisted.Services.Single().ProcessStartTime = persisted.Services.Single().ProcessStartTime!.Value.AddHours(-1);
        var next = new StackSupervisor(new ConfigStore(_checkout.ConfigPath), new LeaseManager(), state, NullLogger<StackSupervisor>.Instance);
        next.Restore(persisted);

        (await next.StatusAsync()).Services.Should().BeEmpty();
        ProcessTree.IsAlive(pid).Should().BeTrue("a process that is not the service is never stopped");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_service_that_exits_during_the_health_wait_is_reported_as_exited_not_as_a_timeout()
    {
        // A port nobody opens: the crasher is never healthy, so the wait ends by its exit (without ports a live process
        // counts as healthy at once, before a slow-starting pwsh has exited).
        var port = TestPorts.Free();

        var (supervisor, _, _) = Create($"""
                                          crasher:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Write-Output boom-from-crasher; exit 3"]
                                            ports: [{port}]
                                          sleeper:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        """);

        var watch = System.Diagnostics.Stopwatch.StartNew();
        var result = await supervisor.StartStackAsync("tester", null, null, false, waitForHealthy: true, TimeSpan.FromSeconds(20), CancellationToken.None);

        result.Warnings.Should().ContainSingle(w => w.Contains("crasher") && w.Contains("exited"));
        result.Warnings.Should().NotContain(w => w.Contains("not healthy within"));
        watch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(15), "an exit ends the wait for that service");
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    private static int FreePort() => TestPorts.Free();


    [Fact]
    public async Task A_service_is_not_started_when_its_startAfter_dependency_exits_and_neither_are_its_own_dependents()
    {
        // AB#8951: in a fresh slot the asset repository started next to identity and exited without the system database.
        var (supervisor, _, _) = Create($"""
                                          identity:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Write-Output boom-from-crasher; exit 3"]
                                            ports: [{FreePort()}]
                                          asset:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            startAfter: [identity]
                                          adapter:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            startAfter: [asset]
                                          independent:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        """);

        var result = await supervisor.StartStackAsync("tester", null, null, false, waitForHealthy: false, TimeSpan.FromSeconds(20), CancellationToken.None);

        result.Warnings.Should().Contain(w => w.StartsWith("asset not started") && w.Contains("identity, which has exited (exit code 3)") &&
                                              w.Contains("service_logs identity"));
        result.Warnings.Should().Contain(w => w.StartsWith("adapter not started") && w.Contains("asset, which did not start"));
        var status = await supervisor.StatusAsync(includeLogTail: false);
        status.Services.Select(s => s.Name).Should().NotContain(["asset", "adapter"]);
        status.Services.Should().Contain(s => s.Name == "independent" && s.State != "exited", "services without the failed dependency still start");
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_service_is_not_started_when_its_requested_startAfter_dependency_is_skipped_as_not_built()
    {
        var (supervisor, _, _) = Create("""
                                          identity:
                                            repo: not-built
                                            optional: true
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                          asset:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            startAfter: [identity]
                                        """);

        var result = await supervisor.StartStackAsync("tester", null, null, false, waitForHealthy: false, TimeSpan.FromSeconds(5), CancellationToken.None);

        result.Skipped.Should().ContainSingle(s => s.Contains("identity"));
        result.Warnings.Should().ContainSingle(w => w.StartsWith("asset not started") && w.Contains("identity, which did not start"));
        (await supervisor.StatusAsync(includeLogTail: false)).Services.Should().BeEmpty();
    }

    [Fact]
    public async Task A_dependency_that_got_healthy_and_exited_while_another_was_awaited_holds_the_service_back()
    {
        // first: no ports, so healthy at once while alive; it exits after 1 s, while the wait goes on for second.
        var (supervisor, _, _) = Create($"""
                                          first:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 1; exit 4"]
                                          second:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            ports: [{FreePort()}]
                                          dependent:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            startAfter: [first, second]
                                        """);

        var watch = System.Diagnostics.Stopwatch.StartNew();
        var result = await supervisor.StartStackAsync("tester", null, null, false, waitForHealthy: false, TimeSpan.FromSeconds(20), CancellationToken.None);

        watch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(12), "an exited dependency ends the wait without waiting out the other one");
        result.Warnings.Should().ContainSingle(w => w.StartsWith("dependent not started") && w.Contains("first, which has exited (exit code 4)"));
        (await supervisor.StatusAsync(includeLogTail: false)).Services.Select(s => s.Name).Should().NotContain("dependent");
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_service_is_not_started_when_its_startAfter_dependency_is_not_healthy_within_the_timeout()
    {
        // A port nobody opens: the dependency runs but never gets healthy.
        var (supervisor, _, _) = Create($"""
                                          identity:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            ports: [{FreePort()}]
                                          asset:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            startAfter: [identity]
                                        """);

        var watch = System.Diagnostics.Stopwatch.StartNew();
        var result = await supervisor.StartStackAsync("tester", null, null, false, waitForHealthy: false, TimeSpan.FromSeconds(2), CancellationToken.None);

        watch.Elapsed.Should().BeGreaterThan(TimeSpan.FromSeconds(1.5), "the dependent waits for the dependency up to the timeout");
        result.Warnings.Should().ContainSingle(w => w.StartsWith("asset not started") && w.Contains("identity, which was not healthy within 2 s"));
        var status = await supervisor.StatusAsync(includeLogTail: false);
        status.Services.Select(s => s.Name).Should().Equal("identity");
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_service_starts_after_its_startAfter_dependency_is_healthy_when_both_are_started_together()
    {
        // No ports: a live process counts as healthy, so the dependent starts and nothing is reported.
        var (supervisor, _, _) = Create("""
                                          identity:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                          asset:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            startAfter: [identity]
                                        """);

        var result = await supervisor.StartServicesAsync("tester", ["asset", "identity"], null, false, TimeSpan.FromSeconds(10), CancellationToken.None);

        result.Warnings.Should().BeEmpty();
        (await supervisor.StatusAsync(includeLogTail: false)).Services.Select(s => s.Name).Should().BeEquivalentTo(["identity", "asset"]);
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    private const string DependencyChain = """
                                             identity:
                                               repo: tools
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                             asset:
                                               repo: tools
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                               startAfter: [identity]
                                             controller:
                                               repo: tools
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                               startAfter: [identity, asset]
                                             platform:
                                               repo: tools
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                               startAfter: [identity]
                                           """;

    [Fact]
    public async Task A_start_that_names_its_services_brings_their_startAfter_dependencies_and_says_so()
    {
        var (supervisor, _, _) = Create(DependencyChain);

        var result = await supervisor.StartStackAsync("tester", new StartSpec { Services = ["controller"] }, null, false, false, TimeSpan.FromSeconds(10),
            CancellationToken.None);

        result.Added!.Select(a => (a.Service, a.Because)).Should().Equal(("identity", "controller, asset start after it"), ("asset", "controller starts after it"));
        result.Notes.Should().Contain(n => n.StartsWith("Added identity (controller, asset start after it), asset (controller starts after it): a named service brings"));
        result.Warnings.Should().BeEmpty();
        (await supervisor.StatusAsync(includeLogTail: false)).Services.Select(s => s.Name).Should().Equal(["identity", "asset", "controller"], "in startAfter order");

        // The dependency runs already: nothing is added (the shared stack's usual case).
        var more = await supervisor.StartServicesAsync("tester", ["platform"], null, false, TimeSpan.FromSeconds(10), CancellationToken.None);
        more.Added.Should().BeNull();
        more.Notes.Should().NotContain(n => n.StartsWith("Added"));
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);

        // Without a running stack service_start starts one with the named services and what they wait for.
        var fresh = await supervisor.StartServicesAsync("tester", ["platform"], null, false, TimeSpan.FromSeconds(10), CancellationToken.None);
        fresh.Added!.Should().ContainSingle().Which.Should().Be(new AddedService("identity", "platform starts after it"));
        (await supervisor.StatusAsync(includeLogTail: false)).Services.Select(s => s.Name).Should().Equal("identity", "platform");
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_dependency_the_start_excludes_or_a_build_stopped_is_not_added_and_the_note_says_why()
    {
        var (supervisor, _, _) = Create(DependencyChain);

        var excluded = await supervisor.StartStackAsync("tester", new StartSpec { Services = ["platform", "asset"], Exclude = ["identity"] }, null, false, false,
            TimeSpan.FromSeconds(10), CancellationToken.None);
        excluded.Added.Should().BeNull();
        excluded.Notes.Should().Contain("identity (platform, asset start after it) was not added: the start excludes it; the services after it start without waiting for it.");
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);

        await supervisor.StartStackAsync("tester", new StartSpec { Services = ["identity"] }, null, false, false, TimeSpan.FromSeconds(10), CancellationToken.None);
        await supervisor.StopForBuildAsync("tester", ["identity"], CancellationToken.None);
        var afterBuild = await supervisor.StartServicesAsync("tester", ["platform"], null, false, TimeSpan.FromSeconds(10), CancellationToken.None);
        afterBuild.Added.Should().BeNull("the build that stopped identity starts it again");
        afterBuild.Notes.Should().Contain(n => n.StartsWith("identity (platform starts after it) was not added: a build or test run stopped it"));
        await supervisor.StopServicesAsync("tester", null, CancellationToken.None);
    }

    [Fact]
    public void The_missing_dependencies_follow_startAfter_through_added_services_and_stop_at_a_refused_one()
    {
        var config = ConfigStore.Parse("""
                                       services:
                                         a: { repo: r, args: [x] }
                                         b: { repo: r, args: [x], startAfter: [a] }
                                         c: { repo: r, args: [x], startAfter: [b] }
                                         d: { repo: r, args: [x], startAfter: [c, a] }
                                       """);

        var (added, notAdded) = SlotRun.MissingDependencies(config, ["d"], new HashSet<string>(), _ => null);
        added.Select(x => x.Service).Should().Equal("c", "a", "b");
        added.Single(x => x.Service == "a").Because.Should().Be("d, b start after it");
        notAdded.Should().BeEmpty();

        SlotRun.MissingDependencies(config, ["d"], new HashSet<string> { "c", "a" }, _ => null).Added.Should().BeEmpty("what runs is not added");
        SlotRun.MissingDependencies(config, ["c", "b"], new HashSet<string>(), _ => null).Added.Select(x => x.Service).Should().Equal("a");

        var refused = SlotRun.MissingDependencies(config, ["d"], new HashSet<string>(), s => s == "c" ? "it runs in the shared stack only" : null);
        refused.Added.Select(x => x.Service).Should().Equal("a");
        refused.NotAdded.Should().Equal("c (d starts after it) was not added: it runs in the shared stack only");
    }

    [Fact]
    public async Task Stop_terminates_the_whole_process_tree()
    {
        // A child of the service's own (Windows: it shares the service's console through -NoNewWindow, so the CTRL_BREAK
        // reaches it too; macOS/Linux: it is in the service's process tree).
        var (supervisor, _, _) = Create($$"""
                                          parent:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: {{TestProcess.ShellArgs(
                                                "$p = Start-Process pwsh -ArgumentList '-NoProfile','-Command','Start-Sleep 30' -NoNewWindow -PassThru; " +
                                                "Write-Output \"child=$($p.Id)\"; Wait-Process -Id $p.Id")}}
                                        """);
        var started = await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var service = started.Status.Services.Single();
        int child = 0;
        SpinWait.SpinUntil(() =>
        {
            var line = TestProcess.ReadLog(service.LogFile).Split('\n').Select(l => l.TrimEnd('\r')).FirstOrDefault(l => l.StartsWith("child="));
            return line != null && int.TryParse(line[6..], out child);
        }, 10000).Should().BeTrue();
        ProcessTree.IsAlive(child).Should().BeTrue();

        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
        SpinWait.SpinUntil(() => !ProcessTree.IsAlive(child), 3000).Should().BeTrue("the child of the service must not survive");
    }

    [Fact]
    public async Task Build_of_a_folder_with_a_running_service_is_refused_without_stopServices()
    {
        var (supervisor, lease, _) = Create("""
                                              sleeper:
                                                repo: tools
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            """);
        await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var queue = new BuildQueue(new ConfigStore(_checkout.ConfigPath), supervisor, lease, new DevStackPaths(_checkout.StateDirectory),
            NullLogger<BuildQueue>.Instance, new FakePwsh(), external: () => Task.FromResult(ExternalSnapshot.Empty));

        var act = () => queue.EnqueueAsync(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "tools" });
        await act.Should().ThrowAsync<InvalidOperationException>().WithMessage("*stopServices=true*sleeper*");

        var other = () => queue.EnqueueAsync(new BuildRequest { Owner = "b", Kind = BuildKind.Repo, Path = "tools", StopServices = true });
        await other.Should().ThrowAsync<LeaseHeldException>("stopping services needs the stack lease");

        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_restart_after_a_build_waits_for_startAfter_dependencies_with_a_real_timeout()
    {
        var port = TestPorts.Free();

        // The dependency opens its port only after 2 s; with the old 1 s wait the dependent started too early.
        var (supervisor, _, _) = Create($$"""
                                          dep:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: {{TestProcess.ShellArgs(
                                                $"Start-Sleep 2; $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, {port}); $l.Start(); Start-Sleep 60")}}
                                            ports: [{{port}}]
                                          dependent:
                                            repo: tools
                                            workingDirectory: .
                                            command: pwsh
                                            args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            startAfter: [dep]
                                        """);
        await supervisor.StartStackAsync("a", null, null, false, false, TimeSpan.FromSeconds(10), CancellationToken.None);
        var stopped = await supervisor.StopForBuildAsync("a", ["dep", "dependent"], CancellationToken.None);

        var watch = System.Diagnostics.Stopwatch.StartNew();
        var result = await supervisor.StartAfterBuildAsync("a", stopped, CancellationToken.None);

        result.Warnings.Should().NotContain(w => w.Contains("not healthy"));
        watch.Elapsed.Should().BeGreaterThan(TimeSpan.FromSeconds(1.5));
        StackSupervisor.RestartDependencyTimeout.Should().Be(TimeSpan.FromSeconds(180));
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }
}
