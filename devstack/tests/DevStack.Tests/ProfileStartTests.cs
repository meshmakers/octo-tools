using System.Net;
using System.Net.Sockets;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>Profile starts with harmless processes (sleep, sh) in a temp lane - no OctoMesh service, no pwsh.</summary>
public sealed class ProfileStartTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly int _adapterPort = FreePort();
    private readonly int _instancePort = FreePort();

    public void Dispose() => _checkout.Dispose();


    /// <summary>A free port with room for slot offsets, never handed to another socket meanwhile (TestPorts).</summary>
    private static int FreePort() => TestPorts.Free();


    private (StackSupervisor Supervisor, LeaseManager Lease, StateStore State, LaneClaims Claims) Create(PreStartChecks? checks = null, string profiles = "")
    {
        _checkout.Repo("tools");
        var store = _checkout.WriteConfig($$"""
                                             web:
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
                                               instances:
                                                 meshAdapterB:
                                                   of: meshAdapter
                                                   ports: [{{_instancePort}}]
                                                   variables: { tenantId: t2 }
                                             webOnly:
                                               description: just the web service
                                               services: [web]
                                             tenant:
                                               services: [web, meshAdapter]
                                               settings: { meshAdapter: { tenantId: fromProfile }, systemDatabase: Db1 }
                                           {{profiles}}
                                           """);
        var lease = new LeaseManager();
        var claims = new LaneClaims();
        lease.Changed += claims.OnLeaseChanged;
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        var supervisor = new StackSupervisor(store, lease, state, NullLogger<StackSupervisor>.Instance, claims: claims, checks: checks);
        return (supervisor, lease, state, claims);
    }

    private static Task<StartResult> Start(StackSupervisor supervisor, string? profile, StartSpec? adhoc = null, bool replace = false, string owner = "a") =>
        supervisor.StartStackAsync(owner, adhoc, profile, replace, false, TimeSpan.FromSeconds(1), CancellationToken.None);

    [Fact]
    public async Task Start_by_profile_runs_an_instance_on_its_own_ports_and_status_names_the_profile()
    {
        var (supervisor, _, _, _) = Create();

        var result = await Start(supervisor, "two");

        result.Status.Services.Select(s => s.Name).Should().BeEquivalentTo("web", "meshAdapter", "meshAdapterB");
        var instance = result.Status.Services.Single(s => s.Name == "meshAdapterB");
        instance.Args.Should().Contain("--tenant=t2");
        instance.Ports.Should().Equal(_instancePort);
        instance.LogFile.Should().EndWith("meshAdapterB.log");
        result.Status.Services.Single(s => s.Name == "meshAdapter").Args.Should().Contain("--tenant=t1");
        result.Status.Profile!.Profile.Should().Be("two");
        result.Status.Profile.Exact.Should().BeTrue(string.Join("; ", result.Status.Profile.Drift.Select(d => d.Detail)));
        result.Status.Instances.Should().Contain("meshAdapterB", "meshAdapter");

        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Restart_of_an_instance_rematerializes_it_and_a_new_daemon_adopts_it_with_its_profile()
    {
        var (supervisor, _, state, _) = Create();
        await Start(supervisor, "two");

        var restarted = await supervisor.RestartServicesAsync("a", ["meshAdapterB"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var instance = restarted.Status.Services.Single(s => s.Name == "meshAdapterB");
        instance.Args.Should().Contain("--tenant=t2");
        instance.Ports.Should().Equal(_instancePort);

        state.Load().Stack!.Profile.Should().Be("two");
        var next = new StackSupervisor(new ConfigStore(_checkout.ConfigPath), new LeaseManager(), state, NullLogger<StackSupervisor>.Instance);
        next.Restore(state.Load().Stack);
        (await next.StatusAsync()).Profile!.Profile.Should().Be("two");
        var again = await next.RestartServicesAsync("a", ["meshAdapterB"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        again.Status.Services.Single(s => s.Name == "meshAdapterB").Args.Should().Contain("--tenant=t2");

        await next.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Replace_switches_the_running_stack_to_another_profile()
    {
        var (supervisor, _, _, _) = Create();
        var first = await Start(supervisor, "two");
        var oldPids = first.Status.Services.Select(s => s.Pid).ToList();

        var refused = () => Start(supervisor, "webOnly");
        (await refused.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*already running*replace=true*");

        var switched = await Start(supervisor, "webOnly", replace: true);
        switched.Status.Services.Select(s => s.Name).Should().Equal("web");
        switched.Status.Profile!.Profile.Should().Be("webOnly");
        switched.Notes.Should().Contain(n => n.StartsWith("Replaced the running stack"));
        oldPids.Should().OnlyContain(pid => !ProcessTree.IsAlive(pid));

        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_profile_start_needs_the_lease()
    {
        var (supervisor, lease, _, _) = Create();
        lease.Require("someone-else");

        var act = () => Start(supervisor, "webOnly", owner: "a");
        await act.Should().ThrowAsync<LeaseHeldException>();
        (await supervisor.StatusAsync()).Running.Should().BeFalse();
    }

    [Fact]
    public async Task Adhoc_arguments_win_over_the_profile_and_settings_reach_the_process()
    {
        var (supervisor, _, _, _) = Create();

        var result = await Start(supervisor, "tenant", new StartSpec
        {
            Overrides = new() { ["meshAdapter"] = new ServiceOverride { Variables = new() { ["tenantId"] = "adhoc" } } }
        });
        result.Status.Services.Single(s => s.Name == "meshAdapter").Args.Should().Contain("--tenant=adhoc");
        result.Status.Profile!.Exact.Should().BeFalse("the ad-hoc tenant differs from the profile");
        result.Status.Profile.Drift.Should().ContainSingle(d => d.Kind == "args");
        supervisor.Capture()!.RequestEnv.Should().Contain("OCTO_SYSTEM__SYSTEMDATABASENAME", "Db1");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);

        var fewer = await Start(supervisor, "tenant", new StartSpec { Services = ["web"] });
        fewer.Status.Services.Select(s => s.Name).Should().Equal("web");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Start_claims_the_lane_and_a_foreign_claim_blocks_it()
    {
        var (supervisor, lease, _, claims) = Create();
        await Start(supervisor, "webOnly");
        claims.Read(_checkout.Lane)!.Session.Should().Be("a");

        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
        lease.Release("a", false);
        File.Exists(LaneClaims.PathOf(_checkout.Lane)).Should().BeFalse("releasing the lease removes the claim");

        File.WriteAllText(LaneClaims.PathOf(_checkout.Lane), "# Claim\n- Session: daidalos-integrate\n");
        var act = () => Start(supervisor, "webOnly");
        (await act.Should().ThrowAsync<LaneClaimedException>()).WithMessage("*daidalos-integrate*");
        (await supervisor.StatusAsync()).Running.Should().BeFalse();
    }

    [Fact]
    public async Task Unreachable_infrastructure_warns_or_fails_with_requireInfra()
    {
        var closed = FreePort();
        var (supervisor, _, _, _) = Create(new PreStartChecks([("MongoDB", closed)], Path.Combine(_checkout.Root, "no-contexts.json")));

        var warned = await Start(supervisor, "webOnly");
        warned.Warnings.Should().Contain(w => w.Contains($"MongoDB (127.0.0.1:{closed})") && w.Contains("docker start kind-control-plane") && w.Contains("Install-OctoKubernetes"));
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);

        var act = () => Start(supervisor, "webOnly", new StartSpec { RequireInfra = true });
        (await act.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*requireInfra*");
        (await supervisor.StatusAsync()).Running.Should().BeFalse();
    }

    [Fact]
    public async Task A_missing_local_S3_store_is_a_note_not_a_warning_and_requireInfra_does_not_refuse_it()
    {
        // The S3 store is optional (Start-Octo: the bot uses the file system without it); a kind cluster created before
        // it existed has none. MongoDB answers here, the S3 store does not.
        using var mongo = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        mongo.Start();
        var closedS3 = FreePort();
        var checks = new PreStartChecks([("MongoDB", ((System.Net.IPEndPoint)mongo.LocalEndpoint).Port)], Path.Combine(_checkout.Root, "no-contexts.json"), closedS3);
        var (supervisor, _, _, _) = Create(checks, "envProviders:\n  s3Store: { script: \"@{}\", whenServices: [web] }");
        // The provider runs in pwsh with octo-tools' profile: an empty octo-tools folder, so nothing of it is loaded.
        Directory.CreateDirectory(Path.Combine(_checkout.Root, "octo-tools"));

        var result = await Start(supervisor, "webOnly", new StartSpec { RequireInfra = true });

        result.Status.Running.Should().BeTrue("the store is optional, so requireInfra does not refuse the start");
        result.Warnings.Should().NotContain(w => w.Contains("kind infrastructure"));
        result.Notes.Should().Contain(n => n.Contains($"No local S3 store answers on 127.0.0.1:{closedS3}") && n.Contains("file system") &&
                                           n.Contains("Install-OctoKubernetesS3Store"));
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task Start_reports_whether_octo_cli_has_a_context_for_the_adapter_tenant()
    {
        var contexts = Path.Combine(_checkout.Root, "contexts.json");
        File.WriteAllText(contexts, """{ "ActiveContext": "local", "Contexts": { "local_t1": { "Authentication": { "AccessToken": "never-read" } } } }""");
        var (supervisor, _, _, _) = Create(new PreStartChecks([], contexts));

        var result = await Start(supervisor, "two");
        result.Notes.Should().Contain(n => n.Contains("octo-cli context local_t1 exists"));
        result.Notes.Should().Contain(n => n.Contains("no octo-cli context local_t2") && n.Contains("Register-OctoCliContext"));
        result.Notes.Should().NotContain(n => n.Contains("never-read"));
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }

    [Fact]
    public async Task A_stack_kept_by_a_build_stays_the_current_stack_and_survives_a_daemon_restart()
    {
        var (supervisor, lease, state, _) = Create();
        await Start(supervisor, "two");
        var stopped = await supervisor.StopForBuildAsync("a", ["web", "meshAdapter", "meshAdapterB"], CancellationToken.None);
        stopped.Names.Should().HaveCount(3);
        (await supervisor.StatusAsync(false)).Running.Should().BeFalse();

        // The state file keeps the stack without services; a new daemon restores it with its profile.
        state.Load().Stack!.Profile.Should().Be("two");
        var restarted = new StackSupervisor(new ConfigStore(_checkout.ConfigPath), lease, new StateStore(new DevStackPaths(_checkout.StateDirectory)),
            NullLogger<StackSupervisor>.Instance);
        restarted.Restore(new StateStore(new DevStackPaths(_checkout.StateDirectory)).Load().Stack);
        restarted.Capture().Should().BeNull("no service runs");

        // A service_start uses the kept stack: the instance of the profile still exists.
        var result = await supervisor.StartServicesAsync("a", ["meshAdapterB"], null, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        result.Status.Services.Should().ContainSingle(s => s.Name == "meshAdapterB" && s.Ports.Contains(_instancePort));
        result.Status.Profile!.Profile.Should().Be("two");
        await supervisor.StopServicesAsync("a", null, CancellationToken.None);
    }
}
