using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The production default since AB#9377: a devstack.yaml without rootPath, octoToolsPath and defaultCheckout, the folders
///     from the workspace octo-tools describes. Every path that copies or re-reads a config (profile instances, slots,
///     builds) must hand the workspace on - the other tests write the folders into the file and would not notice.
/// </summary>
public sealed class WorkspaceConfigTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly List<StackSupervisor> _supervisors = [];
    private readonly int _adapterPort = TestPorts.Free();
    private readonly int _instancePort = TestPorts.Free();

    public void Dispose()
    {
        foreach (var run in _supervisors.SelectMany(s => s.Runs))
        {
            foreach (var pid in run.Pids().Where(ProcessTree.IsAlive))
            {
                ProcessTree.TerminateAsync(pid, TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult();
            }
        }

        _checkout.Dispose();
    }

    private string Services => $$"""
                                   sleeper:
                                     repo: tools
                                     workingDirectory: .
                                     command: pwsh
                                     args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                   meshAdapter:
                                     repo: tools
                                     workingDirectory: .
                                     command: pwsh
                                     variables: { tenantId: t1 }
                                     args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--tenant=${tenantId}"]
                                     ports: [{{_adapterPort}}]
                                 profiles:
                                   two:
                                     services: [sleeper, meshAdapter]
                                     instances:
                                       meshAdapterB:
                                         of: meshAdapter
                                         ports: [{{_instancePort}}]
                                         variables: { tenantId: t2 }
                                 """;

    private (StackSupervisor Supervisor, ConfigStore Store) Create()
    {
        _checkout.Repo("tools");
        _checkout.Repo("octo-a");
        var store = _checkout.WriteWorkspaceConfig(Services);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        return (supervisor, store);
    }

    [Fact]
    public void The_file_has_no_folders_and_the_config_has_the_workspace_ones()
    {
        var (_, store) = Create();
        var config = store.Load();

        File.ReadAllText(store.ConfigPath).Should().NotContainAny("rootPath", "octoToolsPath", "defaultCheckout");
        config.RootPath.Should().Be(_checkout.Root);
        config.DefaultCheckout.Should().Be("branches/main");
        ServicePlanner.OctoToolsPath(config).Should().Be(Path.Combine(_checkout.Root, "octo-tools"));
        ServicePlanner.FolderProblems(config).Should().BeEmpty();
    }

    [Fact]
    public async Task A_stack_starts_in_the_workspace_lane()
    {
        var (supervisor, _) = Create();

        var result = await supervisor.StartServicesAsync("a", ["sleeper"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        result.Status.BaseLane.Should().Be(_checkout.Lane);
        result.Status.Services.Single().WorkingDirectory.Should().Be(Path.Combine(_checkout.Lane, "tools"));
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_profile_instance_is_materialized_with_the_workspace_folders()
    {
        var (supervisor, _) = Create();

        var result = await supervisor.StartStackAsync("a", null, "two", false, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        result.Status.Services.Select(s => s.Name).Should().BeEquivalentTo("sleeper", "meshAdapter", "meshAdapterB");
        var instance = result.Status.Services.Single(s => s.Name == "meshAdapterB");
        instance.WorkingDirectory.Should().Be(Path.Combine(_checkout.Lane, "tools"));
        instance.Args.Should().Contain("--tenant=t2");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_second_slot_starts_with_the_workspace_folders()
    {
        var (supervisor, _) = Create();

        var result = await supervisor.StartStackAsync("b", new StartSpec { Slot = "second", Services = ["sleeper"] }, null, false, false, TimeSpan.FromSeconds(1),
            CancellationToken.None);

        result.Status.Slot.Should().Be("second");
        var service = result.Status.Services.Single();
        service.WorkingDirectory.Should().Be(Path.Combine(_checkout.Lane, "tools"));
        service.LogFile.Should().Be(Path.Combine(_checkout.Lane, "logFiles", "second", "sleeper.log"));
        await supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");
    }

    [Fact]
    public async Task A_build_runs_in_the_workspace_lane()
    {
        var (supervisor, store) = Create();
        var fake = new FakePwsh();
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var state = new StateStore(paths);
        state.Load();
        var queue = new BuildQueue(store, supervisor, supervisor.Leases.Default, paths, NullLogger<BuildQueue>.Instance, fake, state, null,
            new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50) }, () => Task.FromResult(ExternalSnapshot.Empty));

        var job = await queue.EnqueueAsync(new BuildRequest { Owner = "s1", Kind = BuildKind.Repo, Path = "octo-a" }, TestContext.Current.CancellationToken);
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (queue.Get(job.Id).Times.FinishedAt == null && DateTime.UtcNow < deadline)
        {
            await Task.Delay(30, TestContext.Current.CancellationToken);
        }

        queue.Get(job.Id).State.Should().Be("succeeded", queue.Get(job.Id).Outcome?.Summary);
        fake.BuildCalls.Single().Should().StartWith($"Invoke-Build -repositoryPath '{Path.Combine(_checkout.Lane, "octo-a")}'");
    }

    [Fact]
    public void The_octoToolsPath_of_the_file_is_not_read_once_the_daemon_asked_octo_tools()
    {
        File.WriteAllText(_checkout.ConfigPath, "octoToolsPath: /stale/octo-tools\nservices:\n  a: { repo: r, args: [x] }\n");

        // Asked, but octo-tools did not answer: nothing is guessed, not even from the file.
        var unanswered = new ConfigStore(_checkout.ConfigPath) { WorkspaceInfo = WorkspaceResolver.Unanswered(Path.Combine(_checkout.Root, "octo-tools"), "no answer") };
        unanswered.Load().OctoToolsPath.Should().BeEmpty();

        // Asked and answered: the octo-tools it asked.
        var answered = new ConfigStore(_checkout.ConfigPath) { WorkspaceInfo = _checkout.Workspace() };
        answered.Load().OctoToolsPath.Should().Be(Path.Combine(_checkout.Root, "octo-tools"));

        // Not asked (a store of a test) reads the file, and a value assigned in code reads back.
        var notAsked = new ConfigStore(_checkout.ConfigPath).Load();
        notAsked.OctoToolsPath.Should().Be("/stale/octo-tools");
        unanswered.Load().Should().Match<DevStackConfig>(c => SetAndRead(c) == "/assigned");
    }

    private static string SetAndRead(DevStackConfig config)
    {
        config.OctoToolsPath = "/assigned";
        return config.OctoToolsPath;
    }
}
