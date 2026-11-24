using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     A lane being removed starts nothing, also through a start that passed the tool's check before the mark or a source a
///     stack kept (AB#9673); a lane that cannot get its slot is taken away again, and a failed stack_start gives back the
///     lease it took (AB#9676).
/// </summary>
public sealed partial class EnvironmentTests
{
    private string[] LanePaths(string folder) => [folder, Path.Combine(folder, "octo-a")];

    [Fact]
    public async Task A_start_in_the_lane_stack_that_passed_the_tools_check_before_the_mark_starts_nothing()
    {
        var (supervisor, _, _) = CreateSupervisor();
        var folder = Env("ab1-one", ["octo-a"]);
        supervisor.Slot("ab1-one", create: true); // a lane stack that has never run: lane_remove has nothing to stop
        using var removing = supervisor.Removals.Begin("ab1-one", "agent-a", "meshmakers-01", "ab1-one", LanePaths(folder));

        // What stack_start does after its own check passed: the start of the lane's slot itself.
        var start = () => supervisor.StartStackAsync("lane:ab1-one", new StartSpec { Slot = "ab1-one", Checkout = folder, Services = ["alpha"] }, null, false, false,
            TimeSpan.FromSeconds(1), Ct);
        await start.Should().ThrowAsync<InvalidOperationException>().WithMessage("*Lane 'ab1-one' is being removed by 'agent-a'*");
        var add = () => supervisor.StartServicesAsync("lane:ab1-one", ["alpha"], null, false, TimeSpan.FromSeconds(1), Ct, "ab1-one");
        await add.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*");
        supervisor.Slot("ab1-one").Pids().Should().BeEmpty("nothing was launched");
    }

    [Fact]
    public async Task Lane_remove_waits_for_a_start_in_progress_and_stops_what_it_launched()
    {
        // A service that never answers on its port: the start waits for its health while it holds the slot's gate.
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var port = TestPorts.Free();
        var store = _checkout.WriteConfig(Services + "\n  slow:\n    repo: octo-a\n    workingDirectory: .\n    command: pwsh\n" +
                                          "    args: [\"-NoProfile\", \"-NonInteractive\", \"-Command\", \"Start-Sleep 30\"]\n" +
                                          $"    ports: [{port}]");
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new Leasing.LeaseManager(), state, Microsoft.Extensions.Logging.Abstractions.NullLogger<StackSupervisor>.Instance,
            external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        var queue = new Builds.BuildQueue(store, supervisor, supervisor.Leases.Default, new DevStackPaths(_checkout.StateDirectory),
            Microsoft.Extensions.Logging.Abstractions.NullLogger<Builds.BuildQueue>.Instance, _fake, state, null,
            new Builds.BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50) }, () => Task.FromResult(ExternalSnapshot.Empty));
        var folder = Env("ab1-one", ["octo-a"]);
        RemoveLikeOctoTools(folder);

        // The start passed every check (the lane is not marked yet) and launches its service.
        var start = supervisor.StartStackAsync("lane:ab1-one", new StartSpec { Slot = "ab1-one", Checkout = folder, Services = ["slow"] }, null, false, true,
            TimeSpan.FromSeconds(4), Ct);
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (supervisor.Slot("ab1-one").Pids().Count == 0 && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20, Ct);
        }

        var launched = supervisor.Slot("ab1-one").Pids().Should().ContainSingle().Subject;

        // lane_remove marks the lane, waits until the start leaves the slot's gate, then stops the lane stack before the cmdlet.
        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);
        await start;

        result.Success.Should().BeTrue();
        result.Notes.Should().Contain(n => n.StartsWith("stopped the lane stack 'ab1-one'") && n.Contains("slow"));
        ProcessTree.IsAlive(launched).Should().BeFalse("the service the start launched is stopped before the folder goes");
        _fake.BuildCalls.Should().ContainSingle(c => c.StartsWith("Remove-OctoEnvironment", StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_restart_without_overrides_or_after_a_job_does_not_start_a_kept_source_of_a_lane_being_removed()
    {
        var (supervisor, _, _) = CreateSupervisor();
        var folder = Env("ab1-one", ["octo-a"]);
        // UC-A: the shared stack runs alpha from the lane's worktree; beta from the base lane.
        await supervisor.StartStackAsync("agent-1", new StartSpec
        {
            Services = ["alpha", "beta"], Overrides = new Dictionary<string, ServiceOverride> { ["alpha"] = new() { Source = "lane:ab1-one" } }
        }, null, false, false, TimeSpan.FromSeconds(1), Ct);
        var alpha = (await supervisor.StatusAsync()).Services.Single(s => s.Name == "alpha").Pid;

        using (supervisor.Removals.Begin("ab1-one", "agent-a", "meshmakers-01", "ab1-one", LanePaths(folder)))
        {
            // service_restart without overrides keeps the lane source: refused before anything stops.
            var restart = () => supervisor.RestartServicesAsync("agent-1", ["alpha"], null, false, TimeSpan.FromSeconds(1), Ct);
            await restart.Should().ThrowAsync<InvalidOperationException>().WithMessage("*Lane 'ab1-one' is being removed*");
            ProcessTree.IsAlive(alpha).Should().BeTrue("the refused restart stopped nothing");

            // The same source given as the plain folder of the lane's worktree.
            var byFolder = () => supervisor.RestartServicesAsync("agent-1", ["alpha"],
                new Dictionary<string, ServiceOverride> { ["alpha"] = new() { Source = Path.Combine(folder, "octo-a") } }, false, TimeSpan.FromSeconds(1), Ct);
            await byFolder.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*");
        }

        // A job stopped both; while the lane is being removed it ends: beta comes back, alpha stays stopped with a note.
        var stopped = await supervisor.StopForBuildAsync("agent-1", ["alpha", "beta"], Ct);
        stopped.Names.Should().BeEquivalentTo("alpha", "beta");
        using (supervisor.Removals.Begin("ab1-one", "agent-a", "meshmakers-01", "ab1-one", LanePaths(folder)))
        {
            var after = await supervisor.StartAfterBuildAsync("agent-1", stopped, Ct);

            after.NotStarted.Should().Equal("alpha");
            after.Notes.Should().Contain("Not started again after the job: alpha (lane 'ab1-one' is being removed).");
            var status = await supervisor.StatusAsync();
            status.Services.Should().ContainSingle(s => s.Name == "beta" && s.State != "exited");
            status.Services.Should().NotContain(s => s.Name == "alpha" && s.State != "exited");
        }

        await supervisor.StopServicesAsync("agent-1", null, Ct);
    }

    [Fact]
    public async Task Lane_remove_deletes_the_lanes_secret_files_also_when_retiring_its_slot_throws_without_keepData()
    {
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        supervisor.Slot("ab1-one", create: true);
        var secret = Path.Combine(folder, ".octo", SlotOperations.ClientSecretFileName);
        var credentials = Path.Combine(folder, ".octo", SlotOperations.CredentialsFileName);
        File.WriteAllText(secret, "x\n");
        File.WriteAllText(credentials, "{}");
        RemoveLikeOctoTools(folder);
        var remove = _fake.Build!;
        var stateFile = new DevStackPaths(_checkout.StateDirectory).StateFile;
        _fake.Build = async (body, a, b) =>
        {
            var answer = await remove(body, a, b);
            // The state file cannot be written any more: ForgetSlot throws when it retires the index, before the data drop.
            File.Delete(stateFile);
            Directory.CreateDirectory(stateFile);
            return answer;
        };

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", keepData: false, Ct);

        result.Success.Should().BeTrue("the lane is gone; the answer must say so");
        result.DataDrop.Should().BeNull("the drop never ran");
        result.Notes.Should().Contain(n => n.StartsWith("Removed the lane 'ab1-one', but") && n.Contains("failed"));
        File.Exists(secret).Should().BeFalse("AB#9384: the secrets go also when ForgetSlot threw before the data drop");
        File.Exists(credentials).Should().BeFalse();
    }

    [Fact]
    public async Task A_lane_whose_slot_cannot_be_reserved_is_taken_away_again_and_a_known_refusal_creates_nothing()
    {
        var (queue, supervisor, store) = CreateQueue();
        var a = _checkout.GitRepo("octo-a");
        var baseCommit = _checkout.Git(a, "rev-parse", "HEAD");
        var folder = Path.Combine(_checkout.Root, "wt-ab1-new");
        RemoveLikeOctoTools(folder);
        var remove = _fake.Build!;
        _fake.Build = (body, x, y) =>
        {
            if (!body.StartsWith("New-OctoEnvironment", StringComparison.Ordinal))
            {
                return remove(body, x, y);
            }

            _checkout.Git(a, "worktree", "add", "-q", "--no-track", "-b", "reimar/AB#1234_x", Path.Combine(folder, "octo-a"), baseCommit);
            Env("ab1-new", ["octo-a"], baseCommits: new Dictionary<string, string> { ["octo-a"] = baseCommit });
            // While New-OctoEnvironment runs, devstack.yaml gains a service on port 65500: no shifted index fits below 65535 any
            // more, so the reservation after the cmdlet fails.
            _checkout.WriteConfig(Services + "\n  high:\n    repo: octo-a\n    workingDirectory: .\n    command: pwsh\n    ports: [65500]");
            return Task.FromResult(FakePwsh.Ok("New-OctoEnvironment", """{"success":true,"name":"ab1-new"}"""));
        };
        var manager = Manager(queue, supervisor, store);

        var result = await manager.CreateAsync("agent-1", "ab1-new", ["octo-a"], null, null, false, Ct);

        result.Success.Should().BeFalse();
        result.Notes.Should().Contain(n => n.StartsWith("The lane's stack slot could not be reserved") && n.Contains("No free slot index"));
        result.Notes.Should().Contain("The lane was taken away again (Remove-OctoEnvironment).");
        _fake.BuildCalls.Should().ContainSingle(c => c.StartsWith("Remove-OctoEnvironment -env 'ab1-new'", StringComparison.Ordinal));
        Directory.Exists(folder).Should().BeFalse("no folder is left");
        _checkout.Git(a, "branch", "--list", "reimar/*").Should().BeEmpty("the fresh feature branch is deleted");
        supervisor.Registry.Known().Should().NotContain(k => k.Slot.Name == "ab1-new", "no slot is left");
        (await manager.ListAsync()).Should().NotContain(l => l.Name == "ab1-new");

        // While the refusal stands, lane_create refuses before New-OctoEnvironment makes anything.
        var again = () => manager.CreateAsync("agent-1", "ab1-new", ["octo-a"], null, null, false, Ct);
        await again.Should().ThrowAsync<InvalidOperationException>().WithMessage("*No free slot index for 'ab1-new'*");
        _fake.BuildCalls.Count(c => c.StartsWith("New-OctoEnvironment", StringComparison.Ordinal)).Should().Be(1);
    }

    [Fact]
    public async Task A_failed_stack_start_gives_back_the_lease_it_took_and_keeps_one_held_before()
    {
        var (supervisor, store, _) = CreateSupervisor();
        Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);

        // A lane start that fails: the lane's lease, taken for the call, goes again.
        var unknown = () => tools.Start("agent-b", lane: "ab1-one", services: ["nosuch"], waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-02",
            cancellationToken: Ct);
        await unknown.Should().ThrowAsync<ModelContextProtocol.McpException>().WithMessage("*nosuch*");
        supervisor.Leases.Find("ab1-one")?.Current().Should().BeNull("the failed start leaves no lease behind");

        // The shared stack: the same.
        var shared = () => tools.Start("agent-b", services: ["nosuch"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        await shared.Should().ThrowAsync<ModelContextProtocol.McpException>();
        supervisor.Leases.Default.Current().Should().BeNull();

        // A lease the lane held before the failing call stays.
        await tools.Start("agent-b", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        await supervisor.StopServicesAsync("lane:ab1-one", null, Ct, "ab1-one");
        await unknown.Should().ThrowAsync<ModelContextProtocol.McpException>();
        supervisor.Leases.Find("ab1-one")!.Current()!.Owner.Should().Be("lane:ab1-one");
    }
}
