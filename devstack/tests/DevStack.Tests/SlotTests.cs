using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>Stack slots with harmless pwsh processes in a temp lane - no OctoMesh service, no octo-tools.</summary>
public sealed class SlotTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly List<StackSupervisor> _supervisors = [];

    public void Dispose()
    {
        foreach (var supervisor in _supervisors)
        {
            foreach (var run in supervisor.Runs)
            {
                foreach (var pid in run.Pids().Where(ProcessTree.IsAlive))
                {
                    ProcessTree.TerminateAsync(pid, TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult();
                }
            }
        }

        _checkout.Dispose();
    }


    private const string Sleeper = """
                                     sleeper:
                                       repo: octo-a
                                       workingDirectory: .
                                       command: pwsh
                                       args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                   """;

    private (StackSupervisor Supervisor, LeaseManager Lease, StateStore State, ConfigStore Store) Create(string services = Sleeper, string extra = "",
        LaneClaims? claims = null)
    {
        _checkout.Repo("octo-a");
        var store = _checkout.WriteConfig(services, extra);
        var lease = new LeaseManager();
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, lease, state, NullLogger<StackSupervisor>.Instance, claims: claims,
            external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        return (supervisor, lease, state, store);
    }

    private static Task<StartResult> Start(StackSupervisor supervisor, string owner, string? slot, StartSpec? spec = null)
    {
        spec ??= new StartSpec();
        spec.Slot = slot;
        return supervisor.StartStackAsync(owner, spec, null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
    }

    /// <summary>A free port with room for slot offsets, never handed to another socket meanwhile (TestPorts).</summary>
    private static int FreePort() => TestPorts.Free();


    [Fact]
    public async Task Two_slots_run_side_by_side_and_stopping_one_leaves_the_other()
    {
        var (supervisor, _, state, _) = Create();

        var first = await Start(supervisor, "a", null);
        var second = await Start(supervisor, "b", "second");

        second.Status.Slot.Should().Be("second");
        var secondService = second.Status.Services.Single();
        secondService.LogFile.Should().Be(Path.Combine(_checkout.Lane, "logFiles", "second", "sleeper.log"), "other slots log into logFiles/<slot>");
        first.Status.Services.Single().LogFile.Should().Be(Path.Combine(_checkout.Lane, "logFiles", "sleeper.log"), "the default slot logs as before");
        second.Notes.Should().Contain(n => n.Contains("separate browser profile"));
        File.Exists(Path.Combine(_checkout.StateDirectory, "slots", "second", "octo-tools-installation.json")).Should().BeTrue();

        var overview = await supervisor.StatusAsync(includeLogTail: false);
        overview.Slots!.Select(s => (s.Name, s.Running, s.LeaseHolder)).Should().Contain([("default", true, "a"), ("second", true, "b")]);
        overview.Services.Should().ContainSingle("the top-level fields stay the default slot's");

        var stopped = await supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");
        stopped.Stopped.Should().Equal("sleeper");
        ProcessTree.IsAlive(secondService.Pid).Should().BeFalse();
        ProcessTree.IsAlive(first.Status.Services.Single().Pid).Should().BeTrue("the default slot keeps running");
        state.Load().StacksBySlot().Keys.Should().Equal("default");

        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Each_slot_has_its_own_lease_and_an_owner_may_hold_several()
    {
        var (supervisor, _, _, _) = Create();
        await Start(supervisor, "a", null);
        await Start(supervisor, "a", "second");

        supervisor.Leases.HeldBy("a").Should().Equal("default", "second");
        var ambiguous = () => supervisor.StopServicesAsync("a", null, CancellationToken.None);
        await ambiguous.Should().ThrowAsync<InvalidOperationException>().WithMessage("*holds the leases of the slots default, second*slot=<name>*");

        var other = () => supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");
        await other.Should().ThrowAsync<LeaseHeldException>().WithMessage("The stack of slot 'second' is held by 'a'*");

        supervisor.Leases.Get("second").Release("a", false);
        supervisor.SlotFor("a", null).Slot.Name.Should().Be("default", "with one lease left the owner's slot is implied");
        await supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_port_another_slot_uses_refuses_the_start_and_names_the_slot()
    {
        var port = FreePort();
        var (supervisor, _, _, _) = Create($"""
                                              web:
                                                repo: octo-a
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                                ports: [{port}]
                                            """);
        // A profile instance of the default slot sits on the port the slot 'second' shifts web to.
        await Start(supervisor, "a", null, new StartSpec
        {
            Instances = new Dictionary<string, ProfileInstance> { ["webB"] = new() { Of = "web", Ports = [port + 100] } }
        });

        var act = () => Start(supervisor, "b", "second");
        await act.Should().ThrowAsync<InvalidOperationException>().WithMessage($"*second/web would use port {port + 100}, which webB of the shared stack uses*");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Isolated_values_tenants_and_the_default_slots_data_names_are_refused()
    {
        var (supervisor, _, _, _) = Create("""
                                             adapter:
                                               repo: octo-a
                                               workingDirectory: .
                                               command: pwsh
                                               variables: { tenantId: t1 }
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--Adapter:DedicatedTenantId=${tenantId}"]
                                           """, """
                                                environment:
                                                  OCTO_SYSTEM__SYSTEMDATABASENAME: OctoSystem
                                                """);
        await Start(supervisor, "a", null);

        var sameTenant = () => Start(supervisor, "b", "second", new StartSpec { Services = ["adapter"] });
        await sameTenant.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("*second/adapter would serve tenant 't1', which adapter of the shared stack serves*overrides={\"adapter\": {\"variables\": {\"tenantId\"*");
        var nothingLeft = () => Start(supervisor, "b", "second");
        await nothingLeft.Should().ThrowAsync<InvalidOperationException>()
            .WithMessage("Nothing to start in the stack of slot 'second': adapter: it would serve tenant 't1', which adapter of the shared stack serves*");

        var t2 = new Dictionary<string, ServiceOverride> { ["adapter"] = new() { Variables = new() { ["tenantId"] = "t2" } } };
        var defaultName = () => Start(supervisor, "b", "second",
            new StartSpec { Overrides = t2, Environment = new() { ["OCTO_SYSTEM__SYSTEMDATABASENAME"] = "OctoSystem" } });
        await defaultName.Should().ThrowAsync<InvalidOperationException>().WithMessage("*OCTO_SYSTEM__SYSTEMDATABASENAME = 'OctoSystem'*the shared stack's value*");

        var second = await Start(supervisor, "b", "second", new StartSpec { Overrides = t2, Environment = new() { ["OCTO_SYSTEM__SYSTEMDATABASENAME"] = "Shared" } });
        second.Status.Services.Should().ContainSingle();

        var t3 = new Dictionary<string, ServiceOverride> { ["adapter"] = new() { Variables = new() { ["tenantId"] = "t3" } } };
        var shared = () => Start(supervisor, "c", "third", new StartSpec { Overrides = t3, Environment = new() { ["OCTO_SYSTEM__SYSTEMDATABASENAME"] = "Shared" } });
        await shared.Should().ThrowAsync<InvalidOperationException>().WithMessage("*OCTO_SYSTEM__SYSTEMDATABASENAME = 'Shared' in slot 'third' is also used by slot 'second'*");

        var third = await Start(supervisor, "c", "third", new StartSpec { Overrides = t3 });
        third.Status.Services.Should().ContainSingle("the derived OctoSystem_s2 is the slot's own");
        await supervisor.StopServicesAsync("c", null, CancellationToken.None, "third");
        await supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Frontends_stay_in_the_default_slot()
    {
        var (supervisor, _, _, _) = Create("""
                                             refineryStudio:
                                               repo: octo-a
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                           """ + "\n" + Sleeper);

        var explicitStart = () => Start(supervisor, "a", "second", new StartSpec { Services = ["refineryStudio", "sleeper"] });
        await explicitStart.Should().ThrowAsync<InvalidOperationException>().WithMessage("*refineryStudio*shared stack only*");
        var serviceStart = () => supervisor.StartServicesAsync("a", ["refineryStudio"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None, "second");
        await serviceStart.Should().ThrowAsync<InvalidOperationException>().WithMessage("*refineryStudio*shared stack only*");

        var all = await Start(supervisor, "a", "second");
        all.Status.Services.Select(s => s.Name).Should().Equal("sleeper");
        all.LeftOut.Should().ContainSingle().Which.Should().Match<LeftOutService>(l => l.Service == "refineryStudio" && l.Reason.Contains("shared stack only"));
        all.Notes.Should().Contain(n => n.StartsWith("Left out of the stack of slot 'second': refineryStudio (it runs in the shared stack only"));
        await supervisor.StopServicesAsync("a", null, CancellationToken.None, "second");
    }

    [Fact]
    public async Task A_lane_stack_start_of_every_service_leaves_out_every_adapter_of_a_tenant_another_stack_serves()
    {
        const string adapter = """
                                 {0}:
                                   repo: octo-a
                                   workingDirectory: .
                                   command: pwsh
                                   variables: { tenantId: t1 }
                                   args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--Adapter:DedicatedTenantId=${tenantId}"]
                               """;
        var (supervisor, _, _, _) = Create(adapter.Replace("{0}", "adapterA") + "\n" + adapter.Replace("{0}", "adapterB") + "\n" + Sleeper);
        await Start(supervisor, "a", null, new StartSpec { Services = ["adapterA"] });

        var second = await Start(supervisor, "b", "second");

        second.Status.Services.Select(s => s.Name).Should().Equal(["sleeper"], "both adapters of t1 stay out, the rest starts");
        second.LeftOut!.Select(l => l.Service).Should().BeEquivalentTo("adapterA", "adapterB");
        await supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_lane_stack_start_of_every_service_leaves_out_an_adapter_whose_tenant_another_stack_serves()
    {
        var (supervisor, _, _, _) = Create("""
                                             adapter:
                                               repo: octo-a
                                               workingDirectory: .
                                               command: pwsh
                                               variables: { tenantId: t1 }
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--Adapter:DedicatedTenantId=${tenantId}"]
                                           """ + "\n" + Sleeper);
        await Start(supervisor, "a", null, new StartSpec { Services = ["adapter"] });

        var second = await Start(supervisor, "b", "second");
        second.Status.Services.Select(s => s.Name).Should().Equal("sleeper");
        var leftOut = second.LeftOut.Should().ContainSingle().Which;
        leftOut.Service.Should().Be("adapter");
        leftOut.Reason.Should().Be("it would serve tenant 't1', which adapter of the shared stack serves - a tenant's database is shared by every stack");
        leftOut.Include.Should().Be(
            "Name the services and give adapter another tenant: stack_start(owner, slot=\"second\", services=['sleeper', 'adapter'], " +
            "overrides={\"adapter\": {\"variables\": {\"tenantId\": \"<another tenant>\"}}}).");
        second.Notes.Should().Contain(n => n.StartsWith("Left out of the stack of slot 'second': adapter (it would serve tenant 't1'"));
        await supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");

        var named = () => Start(supervisor, "b", "second", new StartSpec { Services = ["adapter", "sleeper"] });
        await named.Should().ThrowAsync<InvalidOperationException>("a start that names its services keeps the refusal").WithMessage("*serve tenant 't1'*");

        var t2 = new Dictionary<string, ServiceOverride> { ["adapter"] = new() { Variables = new() { ["tenantId"] = "t2" } } };
        var both = await Start(supervisor, "b", "second", new StartSpec { Services = ["adapter", "sleeper"], Overrides = t2 });
        both.Status.Services.Select(s => s.Name).Should().BeEquivalentTo("adapter", "sleeper");
        both.LeftOut.Should().BeNull();
        await supervisor.StopServicesAsync("b", null, CancellationToken.None, "second");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);

        var shared = await Start(supervisor, "a", null);
        shared.LeftOut.Should().BeNull("the shared stack leaves nothing out");
        shared.Status.Services.Should().HaveCount(2);
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_new_daemon_adopts_the_services_of_every_slot()
    {
        var (supervisor, _, state, store) = Create();
        var first = await Start(supervisor, "a", null);
        var second = await Start(supervisor, "b", "second");

        var next = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(next);
        next.Restore(state.Load());

        (await next.StatusAsync(false, "default")).Services.Single().Pid.Should().Be(first.Status.Services.Single().Pid);
        var adopted = (await next.StatusAsync(false, "second")).Services.Single();
        adopted.Pid.Should().Be(second.Status.Services.Single().Pid);
        adopted.Adopted.Should().BeTrue();
        next.Slot("second").IsolateKeys().Should().ContainKey("OCTO_SYSTEM__SYSTEMDATABASENAME", "an adopted slot still guards its data names");
        (await next.ExternalAsync()).Services.Should().BeEmpty("the pids of every slot are the daemon's own");

        await next.StopServicesAsync("b", null, CancellationToken.None, "second");
        await next.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_build_needs_the_lease_of_every_slot_whose_services_it_stops()
    {
        var fake = new FakePwsh
        {
            AllPlan = """{"dryRun":true,"lane":{"isolated":false},"packageCachesToPurge":["/c"],"repositories":[{"order":1,"repo":"octo-a","builder":"Invoke-Build"}]}"""
        };
        var (supervisor, lease, state, store) = Create();
        await Start(supervisor, "a", "second");
        lease.Require("b");
        var queue = new BuildQueue(store, supervisor, lease, new DevStackPaths(_checkout.StateDirectory), NullLogger<BuildQueue>.Instance, fake, state, null,
            new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50) }, () => Task.FromResult(ExternalSnapshot.Empty));

        var plan = await queue.PlanAsync(new BuildRequest { Owner = "b", Kind = BuildKind.Repo, Path = "octo-a", StopServices = true },
            TestContext.Current.CancellationToken);
        plan.Conflicts.Single().Service.Should().Be("second/sleeper");
        plan.Gates.LeaseSlots.Should().Equal("second");

        var repo = () => queue.EnqueueAsync(new BuildRequest { Owner = "b", Kind = BuildKind.Repo, Path = "octo-a", StopServices = true },
            TestContext.Current.CancellationToken);
        await repo.Should().ThrowAsync<LeaseHeldException>().WithMessage("The stack of slot 'second' is held by 'a'*");

        var all = () => queue.EnqueueAsync(new BuildRequest { Owner = "b", Kind = BuildKind.All, Confirm = true }, TestContext.Current.CancellationToken);
        await all.Should().ThrowAsync<LeaseHeldException>().WithMessage("*leases of the slots default, second*slot 'second' is held by 'a'*");
        supervisor.Leases.Get("second").Current()!.Owner.Should().Be("a", "a refused build takes no lease");
        lease.Current()!.Owner.Should().Be("b");
        fake.BuildCalls.Should().BeEmpty();

        await supervisor.StopServicesAsync("a", null, CancellationToken.None, "second");
    }

    [Fact]
    public async Task A_build_stops_and_restarts_the_services_of_a_slot_it_holds()
    {
        var fake = new FakePwsh();
        var (supervisor, lease, state, store) = Create();
        await Start(supervisor, "a", "second");
        var queue = new BuildQueue(store, supervisor, lease, new DevStackPaths(_checkout.StateDirectory), NullLogger<BuildQueue>.Instance, fake, state, null,
            new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50) }, () => Task.FromResult(ExternalSnapshot.Empty));

        var job = await queue.EnqueueAsync(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-a", StopServices = true, RestartServices = true },
            TestContext.Current.CancellationToken);
        var deadline = DateTime.UtcNow.AddSeconds(15);
        var status = queue.Get(job.Id);
        while (status.Times.FinishedAt == null && DateTime.UtcNow < deadline)
        {
            await Task.Delay(50, TestContext.Current.CancellationToken);
            status = queue.Get(job.Id);
        }

        status.State.Should().Be("succeeded");
        status.StoppedServices.Should().Equal("second/sleeper");
        status.Notes.Should().Contain(n => n.StartsWith("restarted second/sleeper"));
        (await supervisor.StatusAsync(false, "second")).Services.Should().ContainSingle(s => s.State != "exited");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None, "second");
    }

    [Fact]
    public async Task Every_slot_claims_its_own_file_and_a_lease_change_touches_only_its_claim()
    {
        var claims = new LaneClaims();
        var (supervisor, _, _, _) = Create(claims: claims);
        supervisor.Leases.Changed += (slot, info) => claims.OnLeaseChanged(LaneClaims.ResourceOf(slot), info);
        await Start(supervisor, "a", null);
        await Start(supervisor, "b", "second");

        claims.Read(_checkout.Lane)!.Session.Should().Be("a");
        var secondClaim = claims.Read(_checkout.Lane, "local-stack-second")!;
        secondClaim.Session.Should().Be("b");
        File.ReadAllText(secondClaim.File).Should().Contain("stack slot 'second'");
        var refused = () => claims.EnsureCanClaim(_checkout.Lane, "c", "local-stack-second");
        refused.Should().Throw<LaneClaimedException>().WithMessage("The local stack slot 'second' of*claimed by 'b'*");
        var all = () => claims.EnsureCanClaimAll(_checkout.Lane, "a");
        all.Should().Throw<LaneClaimedException>("a build of the whole lane needs every slot's claim").WithMessage("*slot 'second'*");

        supervisor.Leases.Get("second").Release("b", false);
        File.Exists(LaneClaims.PathOf(_checkout.Lane, "local-stack-second")).Should().BeFalse();
        File.Exists(LaneClaims.PathOf(_checkout.Lane)).Should().BeTrue("the default slot's claim is not touched");

        await supervisor.StopServicesAsync("c", null, CancellationToken.None, "second");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public void A_state_file_of_the_single_stack_daemon_loads_as_the_default_slot_and_round_trips()
    {
        var paths = new DevStackPaths(_checkout.StateDirectory);
        File.WriteAllText(paths.StateFile, """
                                           {
                                             "Stack": { "Checkout": "/lane", "Configuration": "DebugL", "StartedBy": "a", "Services": [ { "Name": "x", "Pid": 42 } ] },
                                             "Lease": { "Owner": "a", "AcquiredAt": "2026-11-09T10:00:00+01:00", "ExpiresAt": "2026-11-09T12:00:00+01:00" }
                                           }
                                           """);
        var store = new StateStore(paths);

        var loaded = store.Load();
        loaded.StacksBySlot().Should().ContainKey("default").WhoseValue.Services.Single().Pid.Should().Be(42);
        loaded.LeasesBySlot()["default"].Owner.Should().Be("a");

        store.SaveStack("second", new PersistedStack { Checkout = "/lane", Configuration = "DebugL", StartedBy = "b" });
        store.SaveLease("second", new LeaseInfo("b", null, DateTimeOffset.Now, DateTimeOffset.Now.AddHours(1)));
        store.SaveSlotIndex("second", 1);

        var json = JsonDocument.Parse(File.ReadAllText(paths.StateFile)).RootElement;
        json.GetProperty("Stack").GetProperty("StartedBy").GetString().Should().Be("a", "the legacy field is still written");
        json.GetProperty("Stacks").EnumerateObject().Select(p => p.Name).Should().BeEquivalentTo("default", "second");

        var again = new StateStore(paths).Load();
        again.StacksBySlot().Keys.Should().BeEquivalentTo("default", "second");
        again.LeasesBySlot()["second"].Owner.Should().Be("b");
        again.SlotIndices.Should().Contain("second", 1);

        new StateStore(paths).SaveStack(null);
        new StateStore(paths).Load().Stack.Should().BeNull("removing the default slot's stack clears the legacy field too");
    }

    [Fact]
    public void Created_slots_take_the_next_free_index_and_keep_it()
    {
        var (supervisor, _, state, _) = Create(extra: "slots:\n  second: { index: 1 }");
        supervisor.Registry.Resolve("second", false).Should().Be(new SlotInfo("second", 1, 100, "s1"));
        supervisor.Registry.Resolve("third", true).Should().Be(new SlotInfo("third", 2, 200, "s2"));
        supervisor.Registry.Resolve("fourth", true).Index.Should().Be(3);
        state.SlotIndices().Should().Contain("third", 2);
        supervisor.Registry.Resolve("third", true).Index.Should().Be(2, "an index is kept while its state exists");

        var unknown = () => supervisor.Registry.Resolve("fifth", false);
        unknown.Should().Throw<InvalidOperationException>().WithMessage("*Unknown slot 'fifth'*");
        supervisor.Registry.Resolve("thi", true).Index.Should().Be(4, "names that start alike are fine: no matching uses name prefixes");
    }

    [Fact]
    public void A_new_slot_skips_an_index_whose_ports_collide_instead_of_refusing_the_lane()
    {
        // AB#9676: as in the default configuration - index 7 moves the app on 4300 onto 5000, a configured slot holds index 8.
        var (supervisor, _, _, store) = Create("""
                                             api:
                                               repo: octo-a
                                               command: pwsh
                                               ports: [5000]
                                             app:
                                               repo: octo-a
                                               command: pwsh
                                               ports: [4300]
                                           """, "slots:\n  second: { index: 8 }");

        var indices = Enumerable.Range(1, 9).Select(i => supervisor.Registry.Resolve($"lane-{i}", true).Index).ToList();

        // Nine lanes, more than the eight the old allocator managed; the built-in services' ports rule out some indices too.
        indices.Should().HaveCount(9).And.OnlyHaveUniqueItems().And.BeInAscendingOrder();
        indices.Should().NotContain(7, "4300 + 700 = 5000 is the port of api").And.NotContain(8, "the configured slot 'second' holds it");
        indices.Should().Contain(i => i > 8);
        supervisor.Registry.Predict("lane-next").Slot.Index.Should().BeGreaterThan(indices.Max(), "lane_list predicts with the same rule");
        var disjoint = () => SlotRules.CheckPortsDisjoint(store.Load(), supervisor.Registry.Known().Select(k => k.Slot).ToList(), "test");
        disjoint.Should().NotThrow("every slot handed out keeps its ports apart");
    }

    [Fact]
    public void External_processes_get_the_slot_their_ports_point_to()
    {
        var service = new ServiceConfig { Ports = [5003, 5002] };
        var slots = new[] { SlotInfo.Default, new SlotInfo("second", 1, 100, "s1") };

        ExternalDetector.SlotHint(service, [5002, 5003], slots).Should().Be("default");
        ExternalDetector.SlotHint(service, [5103], slots).Should().Be("second");
        ExternalDetector.SlotHint(service, [5102, 5103], slots).Should().Be("second");
        ExternalDetector.SlotHint(service, [5303], slots).Should().Be("offset +300");
        ExternalDetector.SlotHint(service, [9999], slots).Should().BeNull();
        ExternalDetector.SlotHint(service, [], slots).Should().BeNull();
    }

    [Fact]
    public void A_profile_running_in_a_slot_matches_on_shifted_ports()
    {
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        var second = new SlotInfo("second", 1, 100, "s1");
        var expected = ProfileMatcher.ExpectedStack(config, "core-data-slot");
        var shifted = expected with
        {
            Services = expected.Services.Select(s => s with
            {
                Ports = s.Ports.Select(p => p + 100).ToList(),
                Args = s.Args.Select(a => a.StartsWith("--urls=") ? SlotDeriver.ShiftPorts(new DevStackConfig
                {
                    Services = { ["x"] = new ServiceConfig { Args = [a], Ports = [] } }
                }, 100).Services["x"].Args[0] : a).ToList()
            }).ToList()
        };

        ProfileMatcher.Compare(config, "core-data-slot", shifted, null, name => name == "second" ? second : null).Exact.Should().BeTrue();
        ProfileMatcher.Compare(config, "core-data-slot", shifted).Drift.Should().Contain(d => d.Kind == "ports", "without the slot the configured ports are expected");
    }

    [Fact]
    public void The_identity_overlay_and_the_installation_carry_the_shifted_ports()
    {
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        var second = new SlotInfo("second", 1, 100, "s1");
        var shifted = SlotDeriver.Apply(config, second, "/state/slots/second").Config;

        var overlay = SlotArtifacts.RenderOverlay(shifted, second, "/state/slots/second");
        overlay.Should().Contain("overlayName: local-dev-second")
            .And.Contain("https://localhost:5103/swagger/oauth2-redirect.html")
            .And.Contain("https://localhost:5117/swagger/oauth2-redirect.html")
            .And.Contain("http://localhost:4300/auth-callback")
            .And.Contain("http://localhost:5000/callback", "octo-cli's own callback is not a slot port")
            .And.NotContain("{");
        new YamlDotNet.Serialization.Deserializer().Deserialize<Dictionary<string, object>>(overlay)["clients"].As<List<object>>().Should().HaveCount(5, "the four of the template and the client of voestApp (system tenant)");

        var installation = SlotArtifacts.RenderInstallation(shifted, second);
        installation["name"]!.GetValue<string>().Should().Be("local-second");
        installation["services"]!["identity"]!.GetValue<string>().Should().Be("https://localhost:5103/");
        installation["services"]!["assets"]!.GetValue<string>().Should().Be("https://localhost:5101/");
        installation["services"]!["ai"]!.GetValue<string>().Should().Be("https://localhost:5119/");

        SlotArtifacts.ApplyCommand(second, "/state/slots/second/identity-overlay.yaml").Should()
            .Contain("octo-cli --context local-second_octosystem @args").And.Contain("Invoke-IdentityOverlay -OverlayFile '/state/slots/second/identity-overlay.yaml'");
    }

    [Fact]
    public async Task The_smoke_check_reports_an_issuer_mismatch()
    {
        var port = FreePort();
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        var serve = Task.Run(async () =>
        {
            for (var i = 0; i < 2; i++)
            {
                var context = await listener.GetContextAsync();
                var body = """{"issuer":"https://localhost:5103/","jwks_uri":"x"}"""u8.ToArray();
                context.Response.ContentType = "application/json";
                await context.Response.OutputStream.WriteAsync(body, TestContext.Current.CancellationToken);
                context.Response.Close();
            }
        }, TestContext.Current.CancellationToken);
        var url = $"http://127.0.0.1:{port}/.well-known/openid-configuration";

        (await SlotArtifacts.CheckIssuerAsync(url, "https://localhost:5103", TestContext.Current.CancellationToken)).Should().BeNull();
        var mismatch = await SlotArtifacts.CheckIssuerAsync(url, "https://localhost:5003", TestContext.Current.CancellationToken);
        mismatch.Should().Contain("issues tokens as 'https://localhost:5103/'").And.Contain("expect 'https://localhost:5003'");
        await serve;

        try
        {
            listener.Close();
        }
        catch (HttpListenerException)
        {
            // Closing looks the endpoint up again; another test may hold the freed port by now ("Address already in use").
        }

        // Port 1: nothing listens there (the stopped listener's ephemeral port may already serve another test).
        (await SlotArtifacts.CheckIssuerAsync("http://127.0.0.1:1/.well-known/openid-configuration", "x", TestContext.Current.CancellationToken))
            .Should().Contain("was not checked");
    }
}
