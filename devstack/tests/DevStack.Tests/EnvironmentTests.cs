using System.Diagnostics;
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
using ModelContextProtocol;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     Feature environments (&lt;rootPath&gt;/envs/&lt;env&gt;): discovery, the source chain environment -&gt; base, the binding to a
///     slot held by the environment, kind=env builds and their queue class, and the lane_create / lane_remove wrappers. Temp
///     folders, sleeping processes and <see cref="FakePwsh"/> only.
/// </summary>
public sealed partial class EnvironmentTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly FakePwsh _fake = new() { Capabilities = FakePwsh.EnvironmentParams };
    private readonly List<StackSupervisor> _supervisors = [];

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

    private const string Services = """
                                      alpha:
                                        repo: octo-a
                                        workingDirectory: .
                                        command: pwsh
                                        args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                        env: { WHERE: "${checkout}" }
                                      beta:
                                        repo: octo-b
                                        workingDirectory: .
                                        command: pwsh
                                        args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                    """;

    /// <summary>
    ///     An environment folder as New-OctoEnvironment leaves it (&lt;rootPath&gt;/wt-&lt;env&gt;): Octo.User.props, manifest, the
    ///     repos it holds; <paramref name="adopted"/> repos are listed with a path outside the folder (adopted in place).
    /// </summary>
    /// <param name="features">The repos with a feature branch (role feature); default: the first one.</param>
    /// <param name="baseCommits">The manifest's baseCommit per repo; default: abc123.</param>
    private string Env(string name, string[] repos, string? slot = null, int schemaVersion = 1, string? baseLane = "branches/main", string? manifestName = null,
        Dictionary<string, string>? adopted = null, string[]? features = null, Dictionary<string, string>? baseCommits = null)
    {
        features ??= [repos[0]];
        var folder = Path.Combine(_checkout.Root, "wt-" + name);
        Directory.CreateDirectory(Path.Combine(folder, ".octo"));
        File.WriteAllText(Path.Combine(folder, "Octo.User.props"), "<Project />");
        adopted ??= [];
        foreach (var repo in repos)
        {
            var path = adopted.GetValueOrDefault(repo) ?? Path.Combine(folder, repo);
            Directory.CreateDirectory(path);
            File.WriteAllText(Path.Combine(path, repo + ".sln"), "");
        }

        var manifest = new
        {
            schemaVersion,
            name = manifestName ?? name,
            workItem = "AB#1234",
            @base = baseLane,
            created = "2026-11-09T09:00:00+01:00",
            owner = "reimar/AB#1234_x",
            repos = repos.Select(r => new
            {
                name = r, role = features.Contains(r) ? "feature" : "consumer", path = adopted.GetValueOrDefault(r) ?? Path.Combine(folder, r),
                branch = features.Contains(r) ? "reimar/AB#1234_x" : null, baseCommit = baseCommits?.GetValueOrDefault(r) ?? "abc123",
                baseRef = features.Contains(r) ? "origin/main" : "HEAD"
            }),
            slot
        };
        File.WriteAllText(EnvironmentDiscovery.ManifestPath(folder), JsonSerializer.Serialize(manifest, JsonSerializerOptions.Web));
        return folder;
    }

    private (StackSupervisor Supervisor, ConfigStore Store, StateStore State) CreateSupervisor()
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig(Services);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        return (supervisor, store, state);
    }

    private (BuildQueue Queue, StackSupervisor Supervisor, ConfigStore Store) CreateQueue()
    {
        var (supervisor, store, state) = CreateSupervisor();
        var paths = new DevStackPaths(_checkout.StateDirectory);
        var queue = new BuildQueue(store, supervisor, supervisor.Leases.Default, paths, NullLogger<BuildQueue>.Instance, _fake, state, null,
            new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50) }, () => Task.FromResult(ExternalSnapshot.Empty));
        return (queue, supervisor, store);
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

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    // ---------- step 8: discovery ----------

    [Fact]
    public void Environments_are_wt_folders_with_a_manifest_and_broken_manifests_are_reported_not_thrown()
    {
        var store = _checkout.WriteConfig(Services);
        Env("ab1-ok", ["octo-a"]);
        Env("ab2-own-slot", ["octo-a"], slot: "ab2-slot");
        Env("ab3-future", ["octo-a"], schemaVersion: 2);
        Env("ab4-renamed", ["octo-a"], manifestName: "other");
        Env("ab5-nobase", ["octo-a"], baseLane: "branches/gone");
        Env("default", ["octo-a"]);
        Directory.CreateDirectory(Path.Combine(_checkout.Root, "wt-plain-lane"));
        File.WriteAllText(Path.Combine(_checkout.Root, "wt-plain-lane", "Octo.User.props"), "<Project />");

        var envs = EnvironmentDiscovery.Discover(store.Load());

        envs.Select(e => e.Name).Should().Equal("ab1-ok", "ab2-own-slot", "ab3-future", "ab4-renamed", "ab5-nobase", "default");
        var ok = envs[0];
        ok.Problem.Should().BeNull();
        ok.BasePath.Should().Be(_checkout.Lane);
        ok.Slot.Should().Be("ab1-ok", "the slot is named after the environment");
        ok.LeaseOwner.Should().Be("lane:ab1-ok");
        ok.Manifest!.Repos.Single().Should().Be(new EnvironmentRepo("octo-a", "feature", Path.Combine(ok.Path, "octo-a"), "reimar/AB#1234_x", "abc123", "origin/main"));
        envs[1].Slot.Should().Be("ab2-slot");
        envs[2].Problem.Should().Contain("schemaVersion 2");
        envs[3].Problem.Should().Contain("names 'other'").And.Contain("wt-ab4-renamed");
        envs[4].Problem.Should().Contain("does not exist");
        envs[5].Problem.Should().Contain("shared stack's slot");

        var unknown = () => EnvironmentDiscovery.Find(store.Load(), "nope");
        unknown.Should().Throw<InvalidOperationException>().WithMessage("*Unknown lane 'nope'*Known: ab1-ok, ab2-own-slot*");
        var broken = () => EnvironmentDiscovery.Find(store.Load(), "ab3-future");
        broken.Should().Throw<InvalidOperationException>().WithMessage("*cannot be used*schemaVersion*");
    }

    [Fact]
    public void Checkouts_list_shows_environments_as_lanes_with_their_base()
    {
        var store = _checkout.WriteConfig(Services);
        var env = Env("ab1-ok", ["octo-a"]);
        Directory.CreateDirectory(Path.Combine(_checkout.Root, "wt-plain-lane"));
        File.WriteAllText(Path.Combine(_checkout.Root, "wt-plain-lane", "Octo.User.props"), "<Project />");

        var lanes = CheckoutDiscovery.Discover(store.Load());

        lanes.Should().Contain(l => l.Path == _checkout.Lane && l.Environment == null);
        lanes.Should().Contain(l => l.RelativeToRoot == "wt-plain-lane" && l.Environment == null, "a wt-* lane without a manifest is a plain lane");
        var lane = lanes.Single(l => l.Path == env);
        lane.Environment.Should().Be("ab1-ok");
        lane.Base.Should().Be(_checkout.Lane);
        lane.RelativeToRoot.Should().Be("wt-ab1-ok");
    }

    // ---------- step 9: source chain ----------

    [Fact]
    public void An_environment_runs_its_own_repos_and_falls_back_to_the_base_for_the_others()
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig(Services);
        var env = Env("ab1-ok", ["octo-a"]);
        var config = store.Load();

        var context = ServicePlanner.CreateContext(config, "wt-ab1-ok", null);
        var alpha = ServicePlanner.Plan(config, context, "alpha", null, new Dictionary<string, string?>());
        var beta = ServicePlanner.Plan(config, context, "beta", null, new Dictionary<string, string?>());

        context.Environment.Should().Be("ab1-ok");
        context.Base.Should().Be(_checkout.Lane);
        alpha.RepoPath.Should().Be(Path.Combine(env, "octo-a"), "the environment holds octo-a");
        beta.RepoPath.Should().Be(Path.Combine(_checkout.Lane, "octo-b"), "octo-b comes from the base lane");
        beta.Source.Should().BeNull("the chain is no override");
        alpha.Env["WHERE"].Should().Be(env, "${checkout} is the environment folder");
        alpha.LogFile.Should().Be(Path.Combine(env, "logFiles", "alpha.log"));

        var lane = ServicePlanner.CreateContext(config, null, null);
        lane.Environment.Should().BeNull();
        ServicePlanner.Plan(config, lane, "alpha", null, new Dictionary<string, string?>()).RepoPath.Should().Be(Path.Combine(_checkout.Lane, "octo-a"));
    }

    [Fact]
    public async Task A_repo_adopted_in_place_runs_and_builds_from_its_manifest_path()
    {
        var (queue, supervisor, store) = CreateQueue();
        var adopted = Path.Combine(_checkout.Root, "wt-main-octo-b");
        var env = Env("ab1-ok", ["octo-a", "octo-b"], adopted: new() { ["octo-b"] = adopted });
        Directory.CreateDirectory(Path.Combine(env, "octo-b")); // a stray folder of that name is not what the manifest says

        var context = ServicePlanner.CreateContext(store.Load(), "wt-ab1-ok", null);
        ServicePlanner.Plan(store.Load(), context, "beta", null, new Dictionary<string, string?>()).RepoPath.Should().Be(adopted);

        var job = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-b", Environment = "ab1-ok" });
        await WaitAsync(queue, job.Id);
        _fake.BuildCalls.Single().Should().StartWith($"Invoke-Build -repositoryPath '{adopted}'");

        _fake.Capabilities = FakePwsh.EnvironmentParams.Replace("\"DryRun\",\"EventsFile\",\"Json\"]", "\"EventsFile\",\"Json\"]");
        var (queue2, _, _) = CreateQueue();
        _fake.BuildOrder = ["octo-b", "octo-a"];
        var plan = await queue2.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-ok" });
        plan.Steps.Single().Repos.Select(r => (r.Repo, r.Path)).Should().Equal(("octo-b", adopted), ("octo-a", Path.Combine(env, "octo-a")));
        _ = supervisor;
    }

    // ---------- overrides.<service>.source = "lane:<name>" ----------

    [Fact]
    public void A_lane_source_is_the_lanes_worktree_of_the_services_repo_and_a_lane_without_it_is_refused_with_the_lanes_that_hold_it()
    {
        var (_, store, _) = CreateSupervisor();
        var adopted = Path.Combine(_checkout.Root, "octo-a", ".claude", "worktrees", "x");
        Env("ab1-one", ["octo-a"], adopted: new Dictionary<string, string> { ["octo-a"] = adopted });
        var two = Env("ab1-two", ["octo-a", "octo-b"]);
        var config = store.Load();
        var context = ServicePlanner.CreateContext(config, null, null);

        ServicePlanner.Plan(config, context, "alpha", new ServiceOverride { Source = "lane:ab1-one" }, new Dictionary<string, string?>())
            .RepoPath.Should().Be(adopted, "the manifest's path of the repo, also outside the lane folder");
        var beta = ServicePlanner.Plan(config, context, "beta", new ServiceOverride { Source = "lane:ab1-two" }, new Dictionary<string, string?>());
        beta.RepoPath.Should().Be(Path.Combine(two, "octo-b"));
        beta.Source.Should().Be(Path.Combine(two, "octo-b"));

        var missing = () => ServicePlanner.Plan(config, context, "beta", new ServiceOverride { Source = "lane:ab1-one" }, new Dictionary<string, string?>());
        missing.Should().Throw<InvalidOperationException>().WithMessage("Lane 'ab1-one' does not hold octo-b, the repo of service 'beta' (it holds octo-a). Lanes that hold octo-b: ab1-two.");
        var unknown = () => ServicePlanner.Plan(config, context, "beta", new ServiceOverride { Source = "lane:nope" }, new Dictionary<string, string?>());
        unknown.Should().Throw<InvalidOperationException>().WithMessage("Unknown lane 'nope'*Known: ab1-one, ab1-two; lane_create*");
    }

    [Fact]
    public async Task A_lanes_service_runs_in_the_shared_stack_and_switches_back()
    {
        var (supervisor, store, _) = CreateSupervisor();
        var lane = Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", services: ["alpha", "beta"], waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-07", cancellationToken: Ct);

        var restarted = await tools.ServiceRestart("agent-1", ["alpha"], overrides: new Dictionary<string, ServiceOverride>
        {
            ["alpha"] = new() { Source = "lane:ab1-one" }
        }, waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-07", cancellationToken: Ct);

        restarted.Status.Slot.Should().Be(SlotInfo.DefaultName, "the shared stack");
        restarted.Status.Services.Single(s => s.Name == "alpha").RepoPath.Should().Be(Path.Combine(lane, "octo-a"));
        restarted.Status.Services.Single(s => s.Name == "beta").RepoPath.Should().Be(Path.Combine(_checkout.Lane, "octo-b"), "the others keep the base lane's build");
        supervisor.Leases.Default.Current()!.Should().Match<LeaseInfo>(l => l.Owner == "agent-1" && l.Session == "meshmakers-07");

        var betaPid = restarted.Status.Services.Single(s => s.Name == "beta").Pid;
        ProcessTree.IsAlive(betaPid).Should().BeTrue();
        var refused = () => tools.ServiceRestart("agent-1", ["beta"], overrides: new Dictionary<string, ServiceOverride> { ["beta"] = new() { Source = "lane:ab1-one" } },
            waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        await refused.Should().ThrowAsync<McpException>().WithMessage("*does not hold octo-b*No lane holds octo-b*lane_add_repo*");
        (await tools.Status(includeLogTail: false)).Services.Single(s => s.Name == "beta").Pid.Should().Be(betaPid, "a refused source stops nothing");
        ProcessTree.IsAlive(betaPid).Should().BeTrue("the refusal came before anything was stopped - a stopped beta could keep its recorded pid");

        var back = await tools.ServiceRestart("agent-1", ["alpha"], overrides: new Dictionary<string, ServiceOverride> { ["alpha"] = new() },
            waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        back.Status.Services.Single(s => s.Name == "alpha").RepoPath.Should().Be(Path.Combine(_checkout.Lane, "octo-a"));

        await tools.Stop("agent-1", cancellationToken: Ct);
    }

    [Fact]
    public async Task An_environment_slot_logs_into_the_environment_and_runs_base_services_from_the_base()
    {
        var (supervisor, store, _) = CreateSupervisor();
        var env = Env("ab1-ok", ["octo-a"]);
        var tools = new StackTools(supervisor, store);

        var started = await tools.Start("agent-1", lane: "ab1-ok", waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);

        started.Status.Slot.Should().Be("ab1-ok");
        started.Status.Folder.Should().Be(env);
        started.Status.Lane.Should().Be("ab1-ok");
        started.Status.BaseLane.Should().Be(_checkout.Lane, "stack_status names the lane and its base lane");
        var alpha = started.Status.Services.Single(s => s.Name == "alpha");
        var beta = started.Status.Services.Single(s => s.Name == "beta");
        alpha.RepoPath.Should().Be(Path.Combine(env, "octo-a"));
        beta.RepoPath.Should().Be(Path.Combine(_checkout.Lane, "octo-b"));
        alpha.LogFile.Should().Be(Path.Combine(env, "logFiles", "alpha.log"), "an environment's folder is its own: no slot subfolder");
        started.Notes.Should().Contain(n => n.Contains("lease held by lane:ab1-ok") && n.Contains("agent-1"));

        var logs = await tools.Logs("beta", lane: "ab1-ok");
        logs.LogFile.Should().Be(Path.Combine(env, "logFiles", "beta.log"));

        await tools.Stop("agent-1", lane: "ab1-ok", cancellationToken: Ct);
    }

    [Fact]
    public async Task A_lane_stacks_services_name_the_calling_owner_and_session_while_the_lane_holds_the_lease()
    {
        var (supervisor, store, _) = CreateSupervisor();
        Env("ab1-ok", ["octo-a"]);
        var tools = new StackTools(supervisor, store);

        var started = await tools.Start("reimar/AB#1_a", lane: "ab1-ok", waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-07", cancellationToken: Ct);

        started.Status.StartedBy.Should().Be("reimar/AB#1_a", "the stack was started by the caller");
        started.Status.Services.Should().OnlyContain(s => s.StartedBy == "reimar/AB#1_a" && s.StartedBySession == "meshmakers-07" && s.StartedVia == "stack_start");
        supervisor.Leases.Get("ab1-ok").Current()!.Owner.Should().Be("lane:ab1-ok", "the lease stays the lane's");

        var restarted = await tools.ServiceRestart("reimar/AB#2_b", ["alpha"], lane: "ab1-ok", overrides: new Dictionary<string, ServiceOverride> { ["alpha"] = new() },
            waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-08", cancellationToken: Ct);
        restarted.Status.Services.Single(s => s.Name == "alpha").Should().Match<ServiceStatus>(s =>
            s.StartedBy == "reimar/AB#2_b" && s.StartedBySession == "meshmakers-08" && s.StartedVia == "service_restart");
        restarted.Status.Services.Single(s => s.Name == "beta").StartedBy.Should().Be("reimar/AB#1_a");

        var bounced = await tools.ServiceRestart("reimar/AB#3_c", ["alpha"], lane: "ab1-ok", waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        bounced.Status.Services.Single(s => s.Name == "alpha").StartedBy.Should().Be("reimar/AB#2_b", "a restart that keeps the overrides keeps who chose them");

        await tools.Stop("reimar/AB#1_a", lane: "ab1-ok", cancellationToken: Ct);
    }

    // ---------- step 10: binding ----------

    [Fact]
    public async Task The_environment_holds_its_slot_lease_so_every_session_of_the_feature_shares_it()
    {
        var (supervisor, store, state) = CreateSupervisor();
        Env("ab1-ok", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        await new StackTools(supervisor, store).Start("other", slot: "second", services: ["beta"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);

        await tools.Start("agent-1", lane: "ab1-ok", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);

        var lease = supervisor.Leases.Get("ab1-ok").Current()!;
        lease.Owner.Should().Be("lane:ab1-ok");
        lease.Purpose.Should().Contain("agent-1", "the calling session is kept for audit");
        state.SlotIndices()["ab1-ok"].Should().Be(2, "created on the first start with the next free index");

        // A second session of the feature works on the same slot through the environment's lease.
        var restarted = await tools.ServiceRestart("agent-2", ["alpha"], waitForHealthy: false, timeoutSeconds: 1, lane: "ab1-ok", cancellationToken: Ct);
        restarted.Status.Services.Should().ContainSingle(s => s.Name == "alpha" && s.State != "exited");
        supervisor.Leases.Get("ab1-ok").Current()!.Purpose.Should().Contain("agent-2");

        // A session acting without env does not hold it.
        var foreign = () => tools.Stop("agent-1", slot: "ab1-ok", cancellationToken: Ct);
        await foreign.Should().ThrowAsync<McpException>().WithMessage("*held by 'lane:ab1-ok'*");

        var mismatch = () => tools.Stop("agent-1", slot: "second", lane: "ab1-ok", cancellationToken: Ct);
        await mismatch.Should().ThrowAsync<McpException>().WithMessage("*runs in slot 'ab1-ok'*");

        await tools.Stop("agent-2", lane: "ab1-ok", cancellationToken: Ct);
        await tools.Stop("other", slot: "second", cancellationToken: Ct);
    }

    [Fact]
    public async Task Service_start_with_env_and_no_running_stack_starts_from_the_environment()
    {
        var (supervisor, store, _) = CreateSupervisor();
        var env = Env("ab1-ok", ["octo-a"]);
        var tools = new StackTools(supervisor, store);

        var started = await tools.ServiceStart("agent-1", ["alpha"], waitForHealthy: false, timeoutSeconds: 1, lane: "ab1-ok", cancellationToken: Ct);

        started.Status.Folder.Should().Be(env, "the slot of an environment defaults to the environment's folder");
        started.Status.Services.Single().RepoPath.Should().Be(Path.Combine(env, "octo-a"));
        await tools.Stop("agent-1", lane: "ab1-ok", cancellationToken: Ct);
    }

    // ---------- step 11: kind=env builds and queue classes ----------

    [Fact]
    public async Task An_environment_build_calls_Invoke_BuildEnvironment_and_publishes_into_the_environment_feed()
    {
        var (queue, _, _) = CreateQueue();
        var env = Env("ab1-ok", ["octo-a", "octo-b"]);
        _fake.EnvPlan = $$"""{"dryRun":true,"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(env, "octo-a"))}}},{"repo":"octo-b","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(env, "octo-b"))}}}]}""";
        _fake.Build = (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":2");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoDone", "\"repo\":\"octo-a\",\"index\":1,\"count\":2,\"success\":true,\"seconds\":3,\"buildSeconds\":3");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoStart", "\"repo\":\"octo-b\",\"index\":2,\"count\":2");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoDone", "\"repo\":\"octo-b\",\"index\":2,\"count\":2,\"success\":true,\"seconds\":4,\"buildSeconds\":4");
            return Task.FromResult(FakePwsh.Ok("Invoke-BuildEnvironment",
                """{"success":true,"exitCode":0,"repositories":[{"repo":"octo-a","success":true,"buildSeconds":3},{"repo":"octo-b","success":true,"buildSeconds":4}]}"""));
        };

        var plan = await queue.Plan(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok" });
        plan.Steps.Single().Repos.Select(r => r.Repo).Should().Equal("octo-a", "octo-b");
        plan.Lane!.Feed.Should().Be(Path.Combine(env, "nuget"));
        plan.Warnings.Should().Contain(w => w.Contains("verifyTests=true"));
        plan.Gates.Lease.Should().BeFalse("nothing of the environment runs");

        var job = await queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok", VerifyTests = true });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Kind.Should().Be("lane");
        done.Progress!.Repos!.Select(r => (r.Repo, r.State)).Should().Equal(("octo-a", "done"), ("octo-b", "done"));
        _fake.BuildCalls.Single().Should().StartWith("Invoke-BuildEnvironment -env 'ab1-ok' -verifyTests -Json -EventsFile ");
    }

    /// <summary>The capabilities of an octo-tools with AB#8831: -refreshCatalogs, -skipPackageCacheSeed, Initialize-OctoEnvironmentPackageCache.</summary>
    private static string FastFirstBuildParams(string from)
    {
        var caps = JsonNode.Parse(from)!.AsObject();
        foreach (var cmdlet in new[] { "Invoke-Build", "Invoke-BuildRange", "Invoke-BuildAll", "Invoke-BuildEnvironment" })
        {
            caps[cmdlet]!.AsArray().Add("refreshCatalogs");
        }

        caps["New-OctoEnvironment"]!.AsArray().Add("skipPackageCacheSeed");
        caps["Initialize-OctoEnvironmentPackageCache"] = new JsonArray("env", "source");
        return caps.ToJsonString();
    }

    [Fact]
    public async Task A_build_shows_where_the_steps_spent_their_time_and_how_the_catalogs_were_read()
    {
        var (queue, _, _) = CreateQueue();
        var env = Env("ab1-ok", ["octo-a"]);
        _fake.EnvPlan = $$"""{"dryRun":true,"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(env, "octo-a"))}}}]}""";
        var old = () => queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok", RefreshCatalogs = true });
        (await old.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*no -refreshCatalogs*AB#8831*");

        _fake.Capabilities = FastFirstBuildParams(_fake.Capabilities);
        var (queue2, _, _) = CreateQueue();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":1");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "phase", "\"repo\":\"octo-a\",\"phase\":\"catalogs\"");
            await release.Task;
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoDone",
                "\"repo\":\"octo-a\",\"index\":1,\"count\":1,\"success\":true,\"seconds\":140,\"buildSeconds\":131.24,\"testSeconds\":8,\"catalogSeconds\":120.04,\"restoreSeconds\":3.1,\"compileSeconds\":8.1,\"testRestoreSeconds\":2");
            return FakePwsh.Ok("Invoke-BuildEnvironment",
                """{"success":true,"exitCode":0,"catalogs":{"mode":"refreshed","usable":true,"seconds":120.04,"detail":null,"repo":"octo-a"},"repositories":[{"repo":"octo-a","success":true,"buildSeconds":131.24,"catalogSeconds":120.04,"restoreSeconds":3.1,"compileSeconds":8.1,"testRestoreSeconds":2}]}""");
        };

        var job = await queue2.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok", RefreshCatalogs = true });
        var reading = await WaitAsync(queue2, job.Id, s => s.Progress?.Phase == "catalogs");
        reading.Progress!.Repos!.Single().Phase.Should().Be("catalogs");
        reading.Catalogs.Should().BeNull("the cmdlet reports it with the result");
        release.SetResult();
        var done = await WaitAsync(queue2, job.Id);

        _fake.BuildCalls.Last().Should().StartWith("Invoke-BuildEnvironment -env 'ab1-ok' -refreshCatalogs -Json -EventsFile ");
        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Progress!.Repos!.Single().Should().BeEquivalentTo(new
        {
            Repo = "octo-a", State = "done", BuildSeconds = 131.2, TestSeconds = 8.0, CatalogSeconds = 120.0, RestoreSeconds = 3.1, CompileSeconds = 8.1, TestRestoreSeconds = 2.0
        });
        done.Catalogs.Should().Be("refreshed: the remote CK catalogs were read once for this run (120 s, triggered by octo-a)");
        BuildQueue.CatalogsOf(JsonNode.Parse("""{"catalogs":{"mode":"unavailable","seconds":0,"detail":"api.github.com timed out","repo":null}}""") as JsonObject)
            .Should().Be("unavailable: the remote CK catalogs could not be reached; the build used the local copy - api.github.com timed out");
        BuildQueue.CatalogsOf(JsonNode.Parse("""{"success":true}""") as JsonObject).Should().BeNull("an older octo-tools reports none");
    }

    [Fact]
    public async Task Env_create_and_env_seed_cache_report_the_package_cache_in_one_sentence()
    {
        var (oldQueue, oldSupervisor, oldStore) = CreateQueue();
        Env("ab0-old", ["octo-a"]);
        var noSwitch = () => Manager(oldQueue, oldSupervisor, oldStore).CreateAsync("a", "ab1-new", ["octo-a"], null, null, false, Ct, skipPackageCacheSeed: true);
        (await noSwitch.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*no -skipPackageCacheSeed*");
        var noCmdlet = () => Manager(oldQueue, oldSupervisor, oldStore).SeedCacheAsync("a", "ab0-old", false, Ct);
        (await noCmdlet.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*Initialize-OctoEnvironmentPackageCache*AB#8831*");

        _fake.Capabilities = FastFirstBuildParams(_fake.Capabilities);
        var (queue, supervisor, store) = CreateQueue();
        var manager = Manager(queue, supervisor, store);
        const string cache =
            """{"source":"/home/u/.nuget/packages","target":"/x/wt-ab1-new/.nuget-packages","method":"clone","packages":2065,"alreadyPresent":0,"skippedLocalBuilds":37,"skippedIncomplete":0,"sizeBytes":20293720474,"seconds":26.72,"errors":[],"dryRun":false}""";
        _fake.Build = (body, _, _) =>
        {
            if (body.StartsWith("Initialize-OctoEnvironmentPackageCache", StringComparison.Ordinal))
            {
                return Task.FromResult(FakePwsh.Ok("Initialize-OctoEnvironmentPackageCache", cache.Replace("\"packages\":2065", "\"success\":true,\"packages\":12").Replace("\"alreadyPresent\":0", "\"alreadyPresent\":2053")));
            }

            Env("ab1-new", ["octo-a"]);
            return Task.FromResult(FakePwsh.Ok("New-OctoEnvironment", $$"""{"success":true,"name":"ab1-new","packageCache":{{cache}}}"""));
        };

        var created = await manager.CreateAsync("agent-1", "ab1-new", ["octo-a"], null, null, false, Ct, skipPackageCacheSeed: true);

        created.Success.Should().BeTrue();
        _fake.BuildCalls.Last().Should().Be("New-OctoEnvironment -env 'ab1-new' -repos @('octo-a') -owner 'agent-1' -skipPackageCacheSeed -Json");
        created.Notes[0].Should().Be("Package cache: 2065 package version(s), 18.9 GiB cloned from /home/u/.nuget/packages in 26.7 s (37 local builds left out).");
        created.Data!.AsObject().ContainsKey("packageCache").Should().BeFalse("the note says it; the block would double the answer");

        var seeded = await manager.SeedCacheAsync("agent-1", "ab0-old", false, Ct);

        seeded.Success.Should().BeTrue();
        _fake.BuildCalls.Last().Should().Be("Initialize-OctoEnvironmentPackageCache -env 'ab0-old' -Json");
        seeded.Notes.Single().Should().Be("Package cache: 12 package version(s), 18.9 GiB cloned from /home/u/.nuget/packages in 26.7 s (2053 already there, 37 local builds left out).");
        await manager.SeedCacheAsync("agent-1", "ab0-old", true, Ct);
        _fake.Calls.Last().Body.Should().EndWith("Initialize-OctoEnvironmentPackageCache -env 'ab0-old' -WhatIf -Json");
        var unknown = () => manager.SeedCacheAsync("agent-1", "nope", false, Ct);
        await unknown.Should().ThrowAsync<ArgumentException>().WithMessage("*no lane 'nope'*");
        EnvironmentManager.PackageCacheNote(JsonNode.Parse("""{"source":"/s","method":null,"packages":0,"skipped":"-skipPackageCacheSeed"}""") as JsonObject)
            .Should().Be("Package cache: not filled (-skipPackageCacheSeed); admin_lane_seed_cache fills it later.");
    }

    [Fact]
    public async Task Without_the_cmdlet_kind_env_says_octo_tools_is_too_old()
    {
        _fake.Capabilities = FakePwsh.WorktreeParams;
        var (queue, _, _) = CreateQueue();
        Env("ab1-ok", ["octo-a"]);

        var start = () => queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok" });

        await start.Should().ThrowAsync<InvalidOperationException>().WithMessage("*Invoke-BuildEnvironment*too old*");
        _fake.BuildCalls.Should().BeEmpty();
    }

    [Fact]
    public async Task Requests_that_do_not_fit_an_environment_are_refused()
    {
        var (queue, _, _) = CreateQueue();
        Env("ab1-ok", ["octo-a"]);

        var noEnv = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env });
        await noEnv.Should().ThrowAsync<ArgumentException>().WithMessage("*lane=<name>*");
        var range = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Range, From = "octo-a", Environment = "ab1-ok" });
        await range.Should().ThrowAsync<ArgumentException>().WithMessage("*built with lane_build*");
        var privateFeed = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-a", Environment = "ab1-ok", Packages = PackageMode.Private });
        await privateFeed.Should().ThrowAsync<ArgumentException>().WithMessage("*own feed*");
        var sync = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-a", SyncMain = true });
        await sync.Should().ThrowAsync<ArgumentException>().WithMessage("*applies to lane_build only*");
    }

    [Fact]
    public async Task A_repo_build_with_env_resolves_the_path_in_the_environment()
    {
        var (queue, _, _) = CreateQueue();
        var env = Env("ab1-ok", ["octo-a"]);

        var job = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-a", Environment = "ab1-ok" });
        await WaitAsync(queue, job.Id);

        _fake.BuildCalls.Single().Should().StartWith($"Invoke-Build -repositoryPath '{Path.Combine(env, "octo-a")}'");
    }

    [Fact]
    public async Task A_finished_repo_build_of_an_environment_is_gone_when_its_repo_was_removed_while_the_environment_stays()
    {
        // AB#8915: the manifest still exists, the repository folder does not; an adopted repo outside the folder is judged by
        // the environment's manifest, not by the lane its folder lies in.
        var (queue, _, _) = CreateQueue();
        var adopted = Path.Combine(_checkout.Root, "wt-main-octo-b");
        var env = Env("ab1-ok", ["octo-a", "octo-b"], adopted: new() { ["octo-b"] = adopted });

        var own = await WaitAsync(queue, (await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-a", Environment = "ab1-ok" })).Id);
        var outside = await WaitAsync(queue, (await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-b", Environment = "ab1-ok" })).Id);
        own.Gone.Should().BeNull();
        outside.Gone.Should().BeNull("the adopted repo and the environment exist");

        Directory.Delete(Path.Combine(env, "octo-a"), recursive: true);

        queue.Get(own.Id).Gone.Should().Be($"repository {Path.Combine(env, "octo-a")} of lane ab1-ok no longer exists");
        queue.Get(outside.Id).Gone.Should().BeNull();
        File.Delete(EnvironmentDiscovery.ManifestPath(env));
        queue.Get(outside.Id).Gone.Should().Be($"lane ab1-ok no longer exists ({env})");
    }

    [Fact]
    public async Task Environment_builds_run_in_parallel_one_per_environment_and_at_most_two()
    {
        var (queue, _, _) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        Env("ab2-two", ["octo-a"]);
        Env("ab3-three", ["octo-a"]);
        var release = new TaskCompletionSource();
        var running = 0;
        var peak = 0;
        _fake.Build = async (body, _, _) =>
        {
            var now = Interlocked.Increment(ref running);
            InterlockedMax(ref peak, now);
            await release.Task;
            Interlocked.Decrement(ref running);
            return FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[]}""");
        };

        BuildRequest Request(string name) => new() { Owner = "a", Kind = BuildKind.Env, Environment = name };
        var one = await queue.Enqueue(Request("ab1-one"));
        one.State.Should().Be("running", "build_start reports the real state of a job that started at once");
        var oneAgain = await queue.Enqueue(Request("ab1-one"));
        var two = await queue.Enqueue(Request("ab2-two"));
        var three = await queue.Enqueue(Request("ab3-three"));

        await WaitAsync(queue, two.Id, s => s.State == "running");
        queue.Get(one.Id).State.Should().Be("running");
        queue.Get(oneAgain.Id).State.Should().Be("queued", "one build per environment");
        await Task.Delay(200, Ct);
        queue.Get(three.Id).State.Should().Be("queued", "at most two environment builds at once");

        release.SetResult();
        foreach (var id in new[] { one.Id, oneAgain.Id, two.Id, three.Id })
        {
            var finished = await WaitAsync(queue, id);
            finished.State.Should().Be("succeeded", finished.Outcome?.Summary + " | " + string.Join("; ", finished.Notes));
        }

        peak.Should().Be(BuildQueue.MaxParallelEnvironmentBuilds);
    }

    [Fact]
    public async Task A_lane_build_runs_alone_and_holds_back_the_environment_builds_queued_after_it()
    {
        var (queue, _, _) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        Env("ab2-two", ["octo-a"]);
        var gates = new Dictionary<string, TaskCompletionSource>
        {
            ["Invoke-Build"] = new(), ["Invoke-BuildEnvironment"] = new()
        };
        _fake.Build = async (body, _, _) =>
        {
            var command = FakePwsh.Command(body);
            await gates[command].Task;
            return FakePwsh.Ok(command, """{"success":true,"exitCode":0,"repositories":[]}""");
        };

        var envFirst = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        await WaitAsync(queue, envFirst.Id, s => s.State == "running");
        var lane = await queue.Enqueue(new BuildRequest { Owner = "b", Kind = BuildKind.Repo, Path = "octo-a" });
        var envAfter = await queue.Enqueue(new BuildRequest { Owner = "c", Kind = BuildKind.Env, Environment = "ab2-two" });

        await Task.Delay(200, Ct);
        queue.Get(lane.Id).State.Should().Be("queued", "a lane build waits for the running environment build");
        queue.Get(envAfter.Id).State.Should().Be("queued", "nothing overtakes a waiting lane build");

        gates["Invoke-BuildEnvironment"].SetResult();
        await WaitAsync(queue, lane.Id, s => s.State == "running");
        queue.Get(envAfter.Id).State.Should().Be("queued", "an environment build does not run next to a lane build");

        gates["Invoke-Build"].SetResult();
        (await WaitAsync(queue, envAfter.Id)).State.Should().Be("succeeded");
    }

    // ---------- worktree builds (WP-C) ----------

    /// <summary>A plain git worktree of a lane repo, as git worktree add leaves it: a .git file and the repo's solution.</summary>
    private string Worktree(string name, string repo)
    {
        var path = Path.Combine(_checkout.Lane, name);
        Directory.CreateDirectory(path);
        File.WriteAllText(Path.Combine(path, ".git"), "gitdir: " + Path.Combine(_checkout.Lane, repo, ".git", "worktrees", name));
        File.WriteAllText(Path.Combine(path, repo + ".sln"), "");
        return path;
    }

    /// <summary>A fake whose build calls wait for the gate of the folder they build (or of their command), counting how many run at once.</summary>
    private (Dictionary<string, TaskCompletionSource> Gates, Func<int> Peak) Gated(params string[] keys)
    {
        var gates = keys.ToDictionary(k => k, _ => new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
        var sync = new Lock();
        var running = 0;
        var peak = 0;
        _fake.Build = async (body, _, _) =>
        {
            lock (sync)
            {
                peak = Math.Max(peak, ++running);
            }

            var command = FakePwsh.Command(body);
            // The folder's quoted path starts the argument (a build.ps1 step names '<folder>/build.ps1').
            var key = keys.FirstOrDefault(k => body.Contains($"'{k}'", StringComparison.Ordinal) || body.Contains($"'{Path.Combine(k, "build.ps1")}'", StringComparison.Ordinal)) ?? command;
            await gates[key].Task;
            lock (sync)
            {
                running--;
            }

            return FakePwsh.Ok(command, """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        return (gates, () => peak);
    }

    [Fact]
    public async Task Worktree_builds_run_next_to_each_other_at_most_two_at_once_and_next_to_lane_builds()
    {
        var (queue, _, _) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var w1 = Worktree("wt-1-octo-a", "octo-a");
        var w2 = Worktree("wt-2-octo-b", "octo-b");
        var w3 = Worktree("wt-3-octo-a", "octo-a");
        var (gates, peak) = Gated(w1, w2, w3, "Invoke-BuildEnvironment");

        var one = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = w1 });
        var two = await queue.Enqueue(new BuildRequest { Owner = "b", Kind = BuildKind.Repo, Path = "wt-2-octo-b" });
        var three = await queue.Enqueue(new BuildRequest { Owner = "c", Kind = BuildKind.Repo, Path = w3 });
        var oneAgain = await queue.Enqueue(new BuildRequest { Owner = "d", Kind = BuildKind.Repo, Path = w1 });
        var lane = await queue.Enqueue(new BuildRequest { Owner = "e", Kind = BuildKind.Env, Environment = "ab1-one" });

        try
        {
            foreach (var id in new[] { one.Id, two.Id, lane.Id })
            {
                await WaitAsync(queue, id, s => s.State == "running");
            }

            await Task.Delay(200, Ct);
            queue.Get(three.Id).Queue!.WaitingFor.Should().StartWith("at most 2 worktree builds run at once").And.Contain(one.Id).And.Contain(two.Id);
            queue.Get(oneAgain.Id).Queue!.WaitingFor.Should().StartWith($"one build per worktree; waiting for {one.Id} (repo ");

            gates[w1].SetResult();
            await WaitAsync(queue, three.Id, s => s.State == "running");
            gates[w2].SetResult();
            gates[w3].SetResult();
            gates["Invoke-BuildEnvironment"].SetResult();
            foreach (var id in new[] { one.Id, two.Id, three.Id, oneAgain.Id, lane.Id })
            {
                (await WaitAsync(queue, id)).State.Should().Be("succeeded");
            }

            peak().Should().Be(BuildQueue.MaxParallelWorktreeBuilds + 1, "two worktree builds and the lane build ran at once");
        }
        finally
        {
            // A failed assertion must not leave builds blocked on their gates while the fixture removes the checkout.
            foreach (var gate in gates.Values)
            {
                gate.TrySetResult();
            }

            foreach (var id in new[] { one.Id, two.Id, three.Id, oneAgain.Id, lane.Id })
            {
                await WaitAsync(queue, id);
            }
        }
    }

    [Fact]
    public async Task A_base_lane_build_still_runs_alone_and_holds_back_the_worktree_builds_queued_after_it()
    {
        var (queue, _, _) = CreateQueue();
        var w1 = Worktree("wt-1-octo-a", "octo-a");
        var w2 = Worktree("wt-2-octo-b", "octo-b");
        var laneRepo = Path.Combine(_checkout.Lane, "octo-b");
        var script = Worktree("wt-4-octo-b", "octo-b");
        File.WriteAllText(Path.Combine(script, "build.ps1"), "");
        var (gates, _) = Gated(w1, w2, laneRepo, script);

        var one = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = w1 });
        await WaitAsync(queue, one.Id, s => s.State == "running");
        var baseBuild = await queue.Enqueue(new BuildRequest { Owner = "b", Kind = BuildKind.Repo, Path = "octo-b" });
        var two = await queue.Enqueue(new BuildRequest { Owner = "c", Kind = BuildKind.Repo, Path = w2 });

        await Task.Delay(200, Ct);
        queue.Get(baseBuild.Id).Queue!.WaitingFor.Should().StartWith("a base lane build runs alone; waiting for").And.Contain(one.Id);
        queue.Get(two.Id).Queue!.WaitingFor.Should().StartWith($"queued behind the base lane build {baseBuild.Id}");

        gates[w1].SetResult();
        await WaitAsync(queue, baseBuild.Id, s => s.State == "running");
        queue.Get(two.Id).Queue!.WaitingFor.Should().StartWith($"waiting for the base lane build {baseBuild.Id}");
        gates[laneRepo].SetResult();
        gates[w2].SetResult();
        (await WaitAsync(queue, two.Id)).State.Should().Be("succeeded");

        // A worktree with a build.ps1 may build its sibling repositories of the lane: it stays a base lane build.
        gates[w1] = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var again = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = w1 });
        await WaitAsync(queue, again.Id, s => s.State == "running");
        var scripted = await queue.Enqueue(new BuildRequest { Owner = "d", Kind = BuildKind.Repo, Path = script });
        await Task.Delay(200, Ct);
        queue.Get(scripted.Id).Queue!.WaitingFor.Should().StartWith("a base lane build runs alone");
        gates[w1].SetResult();
        gates[script].SetResult();
        await WaitAsync(queue, scripted.Id);
    }

    [Fact]
    public async Task A_worktree_build_waits_for_a_lane_build_that_builds_the_same_worktree()
    {
        var (queue, _, _) = CreateQueue();
        var worktree = Worktree("wt-9-octo-a", "octo-a");
        Env("ab1-one", ["octo-a"], adopted: new Dictionary<string, string> { ["octo-a"] = worktree });
        _fake.EnvPlan = $$"""{"dryRun":true,"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(worktree)}}}]}""";
        var (gates, peak) = Gated(worktree, "Invoke-BuildEnvironment");

        var lane = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        await WaitAsync(queue, lane.Id, s => s.State == "running");
        var build = await queue.Enqueue(new BuildRequest { Owner = "b", Kind = BuildKind.Repo, Path = worktree });

        await Task.Delay(200, Ct);
        queue.Get(build.Id).Queue!.WaitingFor.Should().Contain(lane.Id).And.Contain("two jobs never work on one folder at once");

        gates["Invoke-BuildEnvironment"].SetResult();
        gates[worktree].SetResult();
        (await WaitAsync(queue, build.Id)).State.Should().Be("succeeded");
        peak().Should().Be(1);
    }

    // ---------- lane tests (WP-C) ----------

    [Fact]
    public async Task A_lane_test_stops_the_lane_stacks_services_of_the_tested_repo_with_the_lane_lease_and_the_shared_stacks_with_the_callers()
    {
        _fake.Capabilities = FakePwsh.TestParams;
        var (queue, supervisor, store) = CreateQueue();
        var env = Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha", "beta"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        // UC-A: the shared stack runs the lane's build of alpha.
        await supervisor.StartStackAsync("main-agent", new StartSpec { Services = ["alpha"], Overrides = new() { ["alpha"] = new ServiceOverride { Source = "lane:ab1-one" } } },
            null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);
        var sharedPid = (await supervisor.StatusAsync(false)).Services.Single().Pid;
        var lanePid = (await tools.Status(includeLogTail: false, lane: "ab1-one")).Services.Single(s => s.Name == "alpha").Pid;
        string? during = null;
        _fake.Build = async (_, _, _) =>
        {
            during = (await tools.Status(includeLogTail: false, lane: "ab1-one")).Services.Single(s => s.Name == "alpha").State;
            return FakePwsh.Ok("Invoke-OctoTestRun", """{"success":true,"exitCode":0,"projects":[{"project":"A.Tests","state":"passed","success":true,"total":1,"passed":1,"failed":0,"skipped":0,"durationSeconds":1,"failedTests":[]}]}""");
        };

        // main-agent holds the shared stack's lease, so its lane test stops the shared stack's alpha too (F5).
        var queued = await queue.Enqueue(new BuildRequest { Owner = "main-agent", Kind = BuildKind.Test, Repo = "octo-a", Environment = "ab1-one" });
        var done = await WaitAsync(queue, queued.Id);

        queued.StoppedServices.Should().BeEquivalentTo("ab1-one/alpha", "alpha");
        queued.Notes.Should().Contain(n => n.StartsWith("The run stops alpha of the lane stack of ab1-one first"));
        queued.Notes.Should().Contain(n => n.StartsWith("The run stops alpha of the shared stack first (with the shared stack's lease of the caller"));
        queued.Notes.Should().NotContain(n => n.Contains("not stopped"), "no other lane stack runs it");
        during.Should().Be("stopped-for-build");
        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Notes.Should().Contain("restarted alpha, ab1-one/alpha", "the shared stack's first, as they were stopped");
        var alpha = (await tools.Status(includeLogTail: false, lane: "ab1-one")).Services.Single(s => s.Name == "alpha");
        alpha.Pid.Should().NotBe(lanePid);
        alpha.RepoPath.Should().Be(Path.Combine(env, "octo-a"), "alpha comes back with its source, the lane's repo");
        var shared = (await supervisor.StatusAsync(false)).Services.Single();
        shared.Pid.Should().NotBe(sharedPid, "the shared stack's alpha ran the lane's repo too: stopped and started again");
        shared.RepoPath.Should().Be(Path.Combine(env, "octo-a"), "with its source lane:ab1-one");
        supervisor.Leases.Get("ab1-one").Current()!.Owner.Should().Be("lane:ab1-one");
        supervisor.Leases.Default.Current()!.Owner.Should().Be("main-agent", "the shared stack's lease is the caller's, never the lane's");
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
        await supervisor.StopServicesAsync("main-agent", null, CancellationToken.None);
    }

    // ---------- where a service runs from (status page, WP-H) ----------

    [Fact]
    public async Task Services_say_where_they_run_from_and_a_lane_names_its_services_in_the_shared_stack()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha", "beta"], waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-07",
            cancellationToken: Ct);
        // UC-A: the shared stack runs the lane's build of alpha and the base lane's beta.
        await supervisor.StartStackAsync("main-agent", new StartSpec { Services = ["alpha", "beta"], Overrides = new() { ["alpha"] = new ServiceOverride { Source = "lane:ab1-one" } } },
            null, false, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        var shared = await tools.Status(includeLogTail: false);
        shared.Services.Single(s => s.Name == "alpha").RunsFrom.Should().Be("lane:ab1-one", "the lane's build runs in the shared stack");
        shared.Services.Single(s => s.Name == "beta").RunsFrom.Should().Be("base lane");
        var own = await tools.Status(includeLogTail: false, lane: "ab1-one");
        own.Services.Single(s => s.Name == "alpha").RunsFrom.Should().Be("lane:ab1-one", "the lane holds octo-a");
        own.Services.Single(s => s.Name == "beta").RunsFrom.Should().Be("base lane", "services of repos the lane does not hold run from the base lane");

        // The one-line rows of the lane stacks (stack_status slots, stack_list, the status page) say the same, with who started them.
        var row = shared.Slots!.Single(s => s.Name == "ab1-one").Services.Single(s => s.Name == "alpha");
        row.Should().BeEquivalentTo(new { RunsFrom = "lane:ab1-one", StartedBy = "agent-1", StartedBySession = "meshmakers-07", StartedVia = "stack_start" });
        row.StartedAt.Should().NotBeNull();
        var json = JsonSerializer.SerializeToNode(row, McpJsonUtilities.DefaultOptions)!.AsObject();
        json["runsFrom"]!.GetValue<string>().Should().Be("lane:ab1-one");

        // lane_list: the shared stack's services that run the lane's build, and the lane's lease with its idle time.
        var lane = (await Manager(queue, supervisor, store).ListAsync()).Single();
        lane.InSharedStack.Should().Equal("alpha");
        lane.Lease!.Owner.Should().Be("lane:ab1-one");
        lane.Lease.Session.Should().Be("meshmakers-07");
        lane.Lease.Purpose.Should().Contain("last change by agent-1");
        lane.Lease.IdleMinutes.Should().Be(0);
        lane.Lease.LastActivityAt.Should().NotBeNull();

        await supervisor.StopServicesAsync("main-agent", null, CancellationToken.None);
        (await Manager(queue, supervisor, store).ListAsync()).Single().InSharedStack.Should().BeNull("nothing of the shared stack runs the lane's build any more");
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public void Runs_from_names_the_lane_whose_worktree_a_folder_is_else_the_base_lane_else_the_folder()
    {
        var store = _checkout.WriteConfig(Services);
        var one = Env("ab1-one", ["octo-a"]);
        var lanes = EnvironmentDiscovery.Discover(store.Load());

        LaneSource.RunsFrom(Path.Combine(one, "octo-a"), _checkout.Lane, lanes).Should().Be("lane:ab1-one");
        LaneSource.RunsFrom(Path.Combine(one, "octo-a") + Path.DirectorySeparatorChar, null, lanes).Should().Be("lane:ab1-one", "a trailing separator is the same folder");
        LaneSource.RunsFrom(Path.Combine(_checkout.Lane, "octo-b"), _checkout.Lane, lanes).Should().Be("base lane");
        var elsewhere = Path.Combine(_checkout.Root, "other", "octo-b");
        LaneSource.RunsFrom(elsewhere, _checkout.Lane, lanes).Should().Be(elsewhere, "a source override with a folder");
        LaneSource.RunsFrom(Path.Combine(one, "octo-b"), _checkout.Lane, lanes).Should().Be(Path.Combine(one, "octo-b"), "only the manifest's repos are the lane's");
    }

    [Fact]
    public async Task An_environment_sync_is_refused_while_a_range_build_of_the_base_lane_runs_or_waits()
    {
        var (queue, supervisor, _) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        _fake.RangePlan = $$"""{"whatIf":true,"lane":{"isolated":false},"packageCaches":[],"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(_checkout.Lane, "octo-a"))}}}]}""";
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            var command = FakePwsh.Command(body);
            if (command == "Invoke-BuildRange")
            {
                await release.Task;
            }

            return FakePwsh.Ok(command, """{"success":true,"exitCode":0,"repositories":[]}""");
        };

        var range = await queue.Enqueue(new BuildRequest { Owner = "main-agent", Kind = BuildKind.Range, From = "octo-a", Publish = true });
        await WaitAsync(queue, range.Id, s => s.State == "running");

        var sync = () => queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one", SyncMain = true });
        await sync.Should().ThrowAsync<InvalidOperationException>().WithMessage($"*syncMain refused*{range.Id}*running*");

        var plain = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        plain.State.Should().Be("queued", "without syncMain it waits for the lane build");

        release.SetResult();
        await WaitAsync(queue, plain.Id);
        var later = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one", SyncMain = true });
        (await WaitAsync(queue, later.Id)).State.Should().Be("succeeded");
        _fake.BuildCalls.Last().Should().StartWith("Invoke-BuildEnvironment -env 'ab1-one' -syncMain -Json");
        supervisor.Leases.Default.Current()!.Owner.Should().Be("main-agent");
    }

    [Fact]
    public async Task An_environment_build_stops_the_environment_services_with_the_environment_lease()
    {
        var (queue, supervisor, store) = CreateQueue();
        var env = Env("ab1-one", ["octo-a"]);
        _fake.EnvPlan = $$"""{"dryRun":true,"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(env, "octo-a"))}}}]}""";
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha", "beta"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);

        var plan = await queue.Plan(new BuildRequest { Owner = "agent-2", Kind = BuildKind.Env, Environment = "ab1-one" });
        plan.Conflicts.Should().ContainSingle(c => c.Service == "ab1-one/alpha", "beta runs from the base lane, the build does not touch it");
        plan.Gates.LeaseSlots.Should().Equal("ab1-one");
        plan.Gates.Unmet.Should().ContainSingle(u => u.StartsWith("stopServices=true"), "agent-2 acts for the environment, which holds the lease");

        var job = await queue.Enqueue(new BuildRequest { Owner = "agent-2", Kind = BuildKind.Env, Environment = "ab1-one", StopServices = true, RestartServices = true });
        var done = await WaitAsync(queue, job.Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.StoppedServices.Should().Equal("ab1-one/alpha");
        done.Notes.Should().Contain(n => n.StartsWith("restarted"));
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public async Task A_range_build_of_the_base_lane_needs_the_environment_lease_when_the_environment_runs_base_binaries()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        _fake.RangePlan = $$"""{"whatIf":true,"lane":{"isolated":false},"packageCaches":[],"repositories":[{"repo":"octo-b","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(_checkout.Lane, "octo-b"))}}}]}""";
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["beta"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);

        var plan = await queue.Plan(new BuildRequest { Owner = "main-agent", Kind = BuildKind.Range, From = "octo-b", Publish = true, StopServices = true });

        plan.Conflicts.Should().ContainSingle(c => c.Service == "ab1-one/beta" && c.Slot == "ab1-one", "beta runs main's binaries in the environment slot");
        plan.Gates.LeaseSlots.Should().Equal("default", "ab1-one");
        plan.Gates.Unmet.Should().Contain(u => u.Contains("slot 'ab1-one'") && u.Contains("lane:ab1-one"));
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public async Task Private_feed_builds_carry_the_deprecation_warning()
    {
        var (queue, _, _) = CreateQueue();

        var plan = await queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-a", Packages = PackageMode.Private });

        plan.Warnings[0].Should().Be(BuildPlanner.PrivateDeprecation);
    }

    // ---------- step 12: lane_create / lane_remove ----------

    /// <summary>Tests never read the real MongoDB: lane_remove(keepData)'s tenant lookup goes to this inventory.</summary>
    private readonly FakeInventory _inventory = new();

    /// <summary>Tests never drop real data: lane_remove's data drop goes to these stores.</summary>
    private readonly FakeSlotData _data = new();

    private EnvironmentManager Manager(BuildQueue queue, StackSupervisor supervisor, ConfigStore store,
        Func<IEnumerable<(int Pid, int ParentPid)>>? processLinks = null) =>
        new(store, supervisor, queue, _fake, new SlotDataCleanup(store, supervisor, _data.Stores), inventory: _ => _inventory, processLinks: processLinks);

    [Fact]
    public async Task Env_create_calls_New_OctoEnvironment_with_the_probed_parameters()
    {
        var (queue, supervisor, store) = CreateQueue();
        _fake.Build = (body, _, _) =>
        {
            Env("ab1-new", ["octo-a"]);
            return Task.FromResult(FakePwsh.Ok("New-OctoEnvironment", """{"success":true,"name":"ab1-new"}"""));
        };

        var result = await Manager(queue, supervisor, store).CreateAsync("agent-1", "ab1-new", ["octo-a"], "AB#1234", "reimar/AB#1234_x", true, Ct);

        result.Success.Should().BeTrue();
        _fake.BuildCalls.Single().Should().Be("New-OctoEnvironment -env 'ab1-new' -repos @('octo-a') -workItem 'AB#1234' -branchName 'reimar/AB#1234_x' -addAffected -owner 'agent-1' -Json");
        _fake.Calls.Last().Body.Should().StartWith("$global:rootPath = ", "the cmdlet resolves envs/ against the daemon's rootPath");
        result.Environment!.Slot.Should().Be("ab1-new");
        result.Notes.Should().Contain(n => n.Contains("lane_build(owner, lane="));
    }

    [Fact]
    public async Task Env_create_refuses_names_and_octo_tools_that_do_not_fit()
    {
        var (queue, supervisor, store) = CreateQueue();
        var manager = Manager(queue, supervisor, store);

        var bad = () => manager.CreateAsync("a", "Bad_Name", [], null, null, false, Ct);
        await bad.Should().ThrowAsync<ArgumentException>().WithMessage("*Invalid lane name*");

        supervisor.Slot("ab1", create: true);
        var taken = () => manager.CreateAsync("a", "ab1", [], null, null, false, Ct);
        await taken.Should().ThrowAsync<ArgumentException>().WithMessage("*slot 'ab1' exists already*");

        _fake.Capabilities = FakePwsh.WorktreeParams;
        var (queue2, supervisor2, store2) = CreateQueue();
        var old = () => Manager(queue2, supervisor2, store2).CreateAsync("a", "ab2-x", [], null, null, false, Ct);
        await old.Should().ThrowAsync<InvalidOperationException>().WithMessage("*New-OctoEnvironment*too old*");
        _fake.BuildCalls.Should().BeEmpty();
    }

    [Fact]
    public async Task Lane_remove_with_keepData_stops_the_lane_stack_releases_the_lease_and_retires_the_index_with_its_leftovers()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        var started = await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var pid = started.Status.Services.Single().Pid;
        var order = new List<string>();
        _fake.Build = (body, _, _) =>
        {
            order.Add($"alive={ProcessTree.IsAlive(pid)} lease={supervisor.Leases.Get("ab1-one").Current()?.Owner ?? "free"}");
            return Task.FromResult(FakePwsh.Ok("Remove-OctoEnvironment", """{"success":true,"removed":true}"""));
        };

        _inventory.Tenants["octosystem_s1"] = [new InventoryTenant("isotest", "isotest_s1", true, "octosystem_s1")];
        _data.Mongo.Databases.AddRange(["octosystem_s1", "isotest_s1"]);
        _data.OctoCli.Installations.Add("local-ab1-one");
        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", keepData: true, Ct);

        result.Success.Should().BeTrue();
        order.Should().Equal("alive=False lease=free");
        _fake.BuildCalls.Single().Should().Be("Remove-OctoEnvironment -env 'ab1-one' -Json");
        result.Notes.Should().Contain(n => n.StartsWith("stopped the lane stack 'ab1-one'")).And.Contain(n => n.StartsWith("released the lease"));

        // keepData: the slot is gone from stack_list, its index is retired with the leftovers, nothing is dropped.
        (await supervisor.SummariesAsync()).Should().NotContain(s => s.Name == "ab1-one");
        supervisor.Registry.Known().Should().NotContain(k => k.Slot.Name == "ab1-one");
        var persisted = new StateStore(new DevStackPaths(_checkout.StateDirectory)).Load();
        persisted.SlotIndices.Should().NotContainKey("ab1-one");
        persisted.RetiredSlots!.Should().ContainKey(1).WhoseValue.Leftovers.Should().BeNull("only the facts are stored");
        supervisor.RetiredSlots()[1].Leftovers.Should().Contain(l => l.Name == "octosystem_s1");
        result.Notes.Should().Contain(n => n.Contains("index 1 is retired") && n.Contains("admin_slot_drop_data(owner, index=1)"));
        // The services lowercase the system database (OctoSystem_s1 -> octosystem_s1); mongosh authenticates and prompts for the password.
        result.Leftovers!.Should().Contain(l => l.Name == "octosystem_s1" && l.Drop!.Contains("getSiblingDB('octosystem_s1').dropDatabase()") &&
                                                l.Drop.Contains("-u octo-system-admin --authenticationDatabase admin -p --eval"));
        result.Leftovers.Should().NotContain(l => l.Drop != null && l.Drop.Contains("OctoSystem_s1"));
        result.Leftovers.Should().Contain(l => l.Drop != null && l.Drop.Contains("getSiblingDB('s1-OctoSystemJobs')") && l.Drop.Contains("-u octo-system-admin"));
        result.Leftovers.Should().Contain(l => l.Name == "s1" && l.Drop!.Contains("s1-OctoSystemJobs"));
        result.Leftovers.Should().Contain(l => l.Name == "local-s1");
        result.Leftovers.Should().Contain(l => l.Name.StartsWith("local-ab1-one"));
        result.Leftovers.Should().Contain(l => l.Name == "isotest_s1" && l.Drop!.Contains("getSiblingDB('isotest_s1').dropDatabase()"),
            "the tenant databases the slot's system database registers are named");
        result.Leftovers.Should().NotContain(l => l.Name == "<tenant>");
        supervisor.RetiredSlots()[1].Leftovers!.Should().Contain(l => l.Name == "isotest_s1", "kept as a fact with the retired index");
        _fake.BuildCalls.Should().ContainSingle("nothing drops data");
        _data.Mongo.Dropped.Should().BeEmpty();
        _data.OctoCli.Removed.Should().BeEmpty();
        result.Leftovers.Should().Contain(l => l.Name == "s1" && l.Drop!.Contains("rabbitmqctl delete_queue") && l.Drop.Contains("kind-kind"));
        result.Leftovers.Should().Contain(l => l.Name == "s1" && l.Drop!.Contains("information_schema.tables") && l.Drop.Contains("DROP TABLE"));

        // A later environment with the same name gets a fresh slot on a never-used index, so it finds no old data.
        Env("ab1-one", ["octo-a"]);
        var again = await tools.Start("agent-3", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        again.Status.Services.Should().ContainSingle(s => s.State != "exited");
        (await supervisor.SummariesAsync()).Should().ContainSingle(s => s.Name == "ab1-one" && s.Index == 2 && s.Running);
        await tools.Stop("agent-3", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public async Task A_retired_index_is_freed_only_by_slot_forget_with_confirmation_and_nothing_running_on_it()
    {
        // The shifted port (index 1: +100) is a free port outside the OS ephemeral ranges (macOS 49152+, Linux 32768+): an
        // ephemeral one may be handed to another test's socket right after the listener stops.
        System.Net.Sockets.TcpListener listener;
        int shifted;
        while (true)
        {
            shifted = Random.Shared.Next(20000, 30000);
            listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, shifted);
            try
            {
                listener.Start();
                break;
            }
            catch (System.Net.Sockets.SocketException)
            {
                // taken: try another
            }
        }

        var store = _checkout.WriteConfig($$"""
                                            alpha:
                                              repo: octo-a
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                              ports: [{{shifted - 100}}]
                                          """);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        var slots = new SlotTools(supervisor, store, new SlotDataCleanup(store, supervisor, new FakeSlotData().Stores));

        slots.Retired().Should().ContainKey(1).WhoseValue.Name.Should().Be("ab1-one");
        supervisor.Slot("ab2-two", create: true).Slot.Index.Should().Be(2, "a retired index is never handed out");
        var unconfirmed = () => slots.Forget("agent", 1);
        await unconfirmed.Should().ThrowAsync<McpException>().WithMessage("*confirmDataDropped=true*");
        var unknown = () => slots.Forget("agent", 7, confirmDataDropped: true);
        await unknown.Should().ThrowAsync<McpException>().WithMessage("*not retired*Retired: 1*");

        var busy = () => slots.Forget("agent", 1, confirmDataDropped: true);
        await busy.Should().ThrowAsync<McpException>().WithMessage($"*still runs on the ports of index 1 ({shifted})*");
        listener.Stop();
        listener.Dispose();
        // The closed port may still answer for a moment (a connection of the probe in the backlog); wait until it does not.
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (await Probes.IsPortOpenAsync(shifted, TimeSpan.FromMilliseconds(200)) && DateTime.UtcNow < deadline)
        {
            await Task.Delay(100, Ct);
        }

        (await slots.Forget("agent", 1, confirmDataDropped: true, cancellationToken: Ct)).Name.Should().Be("ab1-one");
        state.Load().RetiredSlots.Should().BeNull();
        slots.Retired().Should().BeEmpty();
    }

    [Fact]
    public async Task New_slots_take_the_lowest_index_that_is_neither_in_use_nor_retired()
    {
        var (supervisor, store, _) = CreateSupervisor();
        var slots = new SlotTools(supervisor, store, new SlotDataCleanup(store, supervisor, new FakeSlotData().Stores));

        supervisor.Slot("e1", create: true).Slot.Index.Should().Be(1);
        supervisor.Slot("e2", create: true).Slot.Index.Should().Be(2);
        supervisor.ForgetSlot("e1"); // env_remove: index 1 is retired
        supervisor.Slot("e3", create: true).Slot.Index.Should().Be(3, "1 is retired, 2 in use");

        await slots.Forget("agent", 1, confirmDataDropped: true, cancellationToken: Ct);
        var e4 = supervisor.Slot("e4", create: true).Slot;
        e4.Index.Should().Be(1, "the forgotten index is the lowest free one");
        e4.PortOffset.Should().Be(100);

        supervisor.ForgetSlot("e2");
        supervisor.Slot("e5", create: true).Slot.Index.Should().Be(4, "2 is retired now, 1 and 3 in use");
    }

    [Fact]
    public async Task A_profile_of_the_base_lane_started_in_an_environment_shows_no_checkout_drift()
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig(Services, """
                                                    profiles:
                                                      both:
                                                        checkout: branches/main
                                                        services: [alpha, beta]
                                                    """);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);

        var started = await tools.Start("agent-1", profile: "both", lane: "ab1-one", waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var status = await tools.Status(includeLogTail: false, lane: "ab1-one");

        started.Status.Services.Single(s => s.Name == "alpha").RepoPath.Should().Be(Path.Combine(_checkout.Root, "wt-ab1-one", "octo-a"));
        status.Profile!.Profile.Should().Be("both");
        status.Profile.Drift.Should().BeEmpty("the environment is the profile's lane plus its own repos");
        status.Profile.Exact.Should().BeTrue();
        var summary = ProfileTools.Summaries(store.Load(), await supervisor.StatusAsync(includeLogTail: false)).Single(p => p.Name == "both");
        summary.ActiveIn.Should().Be("slot:ab1-one");
        summary.RunsFrom.Should().Be("branches/main + wt-ab1-one: octo-a", "the status page shows the effective sources");
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public async Task The_state_file_records_every_running_environment_build()
    {
        var (queue, _, _) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        Env("ab2-two", ["octo-a"]);
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            await release.Task;
            return FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[]}""");
        };

        var one = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        var two = await queue.Enqueue(new BuildRequest { Owner = "b", Kind = BuildKind.Env, Environment = "ab2-two" });
        await WaitAsync(queue, two.Id, s => s.State == "running");
        await WaitAsync(queue, one.Id, s => s.State == "running");
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (state.Load().RunningBuilds().Count < 2 && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20, Ct);
        }

        state.Load().RunningBuilds().Select(b => b.Id).Should().Equal(one.Id, two.Id);
        state.Load().RunningBuilds().Should().OnlyContain(b => b.Pid == Environment.ProcessId, "the fake reports its own pid as the pwsh pid");

        release.SetResult();
        await WaitAsync(queue, one.Id);
        await WaitAsync(queue, two.Id);
        deadline = DateTime.UtcNow.AddSeconds(5);
        while (state.Load().RunningBuilds().Count > 0 && DateTime.UtcNow < deadline)
        {
            await Task.Delay(20, Ct);
        }

        state.Load().RunningBuilds().Should().BeEmpty();
    }

    [Fact]
    public async Task Forgetting_a_slot_is_refused_while_it_runs_and_for_the_default_slot()
    {
        var (supervisor, store, _) = CreateSupervisor();
        Env("ab1-one", ["octo-a"]);
        await new StackTools(supervisor, store).Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1,
            cancellationToken: Ct);

        var running = () => supervisor.ForgetSlot("ab1-one");
        running.Should().Throw<InvalidOperationException>().WithMessage("*still runs*");
        var defaultSlot = () => supervisor.ForgetSlot("default");
        defaultSlot.Should().Throw<InvalidOperationException>().WithMessage("*is the shared stack*");
        supervisor.ForgetSlot("never-created").Should().BeNull();

        await new StackTools(supervisor, store).Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
        supervisor.ForgetSlot("ab1-one")!.Index.Should().Be(1);
    }

    [Fact]
    public async Task A_refused_env_remove_reports_a_non_zero_exit_code()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Remove-OctoEnvironment",
            """{"success":false,"exitCode":1,"error":"octo-a has uncommitted changes"}"""));

        var result = await Manager(queue, supervisor, store).RemoveAsync("a", "ab1-one", false, Ct);

        result.Success.Should().BeFalse();
        result.ExitCode.Should().Be(1, "pwsh exited 0, but the cmdlet refused");
        supervisor.RetiredSlots().Should().BeEmpty("nothing is retired when the cmdlet refused");
    }

    [Fact]
    public async Task Env_remove_is_refused_while_a_build_of_the_environment_waits_or_another_session_holds_its_slot()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            await release.Task;
            return FakePwsh.Ok(FakePwsh.Command(body), """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        var manager = Manager(queue, supervisor, store);

        var job = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        var busy = () => manager.RemoveAsync("a", "ab1-one", false, Ct);
        await busy.Should().ThrowAsync<InvalidOperationException>().WithMessage($"*{job.Id}*");
        release.SetResult();
        await WaitAsync(queue, job.Id);

        supervisor.Leases.Get("ab1-one").Require("someone-else");
        var held = () => manager.RemoveAsync("a", "ab1-one", false, Ct);
        await held.Should().ThrowAsync<LeaseHeldException>().WithMessage("*held by 'someone-else'*");
        _fake.BuildCalls.Should().NotContain(c => c.StartsWith("Remove-OctoEnvironment", StringComparison.Ordinal));
    }

    // ---------- env_add_repo, env_sync, env_affected, env_list(env) ----------

    [Fact]
    public async Task Env_add_repo_adds_or_adopts_a_worktree_and_is_refused_while_a_service_of_the_repo_runs_in_the_slot()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var adopted = Path.Combine(_checkout.Root, "wt-main-octo-b");
        Directory.CreateDirectory(adopted);
        _fake.Build = (body, _, _) => Task.FromResult(FakePwsh.Ok(FakePwsh.Command(body), """{"success":true}"""));
        var manager = Manager(queue, supervisor, store);

        (await manager.AddRepoAsync("agent-1", "ab1-one", "octo-b", null, "consumer", true, false, Ct)).Success.Should().BeTrue();
        (await manager.AddRepoAsync("agent-1", "ab1-one", null, "wt-main-octo-b", null, false, true, Ct)).Success.Should().BeTrue();
        _fake.BuildCalls.Should().Equal(
            "Add-OctoEnvironmentRepo -env 'ab1-one' -repo 'octo-b' -role 'consumer' -addAffected -Json",
            $"Add-OctoEnvironmentRepo -env 'ab1-one' -path '{adopted}' -inPlace -Json");

        var both = () => manager.AddRepoAsync("a", "ab1-one", "octo-b", "wt-main-octo-b", null, false, false, Ct);
        await both.Should().ThrowAsync<ArgumentException>().WithMessage("*either repo*");

        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["beta"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var running = () => manager.AddRepoAsync("agent-1", "ab1-one", "octo-b", null, null, false, false, Ct);
        await running.Should().ThrowAsync<InvalidOperationException>().WithMessage("*beta of octo-b run(s) in the stack of lane*stop them first*lane=*");
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
        _fake.BuildCalls.Should().HaveCount(2);
    }

    [Fact]
    public async Task Env_sync_is_refused_while_the_base_lane_or_the_environment_builds()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        _fake.RangePlan = $$"""{"whatIf":true,"lane":{"isolated":false},"packageCaches":[],"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(_checkout.Lane, "octo-a"))}}}]}""";
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            var command = FakePwsh.Command(body);
            if (command is "Invoke-BuildRange" or "Invoke-BuildEnvironment")
            {
                await release.Task;
            }

            return FakePwsh.Ok(command, """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        var manager = Manager(queue, supervisor, store);

        var range = await queue.Enqueue(new BuildRequest { Owner = "main-agent", Kind = BuildKind.Range, From = "octo-a", Publish = true });
        var whileMain = () => manager.SyncAsync("a", "ab1-one", Ct);
        await whileMain.Should().ThrowAsync<InvalidOperationException>().WithMessage($"*lane_sync refused*{range.Id}*");
        var build = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
        release.SetResult();
        await WaitAsync(queue, range.Id);
        await WaitAsync(queue, build.Id);

        (await manager.SyncAsync("a", "ab1-one", Ct)).Success.Should().BeTrue();
        _fake.BuildCalls.Last().Should().Be("Sync-OctoEnvironment -env 'ab1-one' -Json");
    }

    [Fact]
    public async Task Env_affected_and_env_list_with_env_call_the_read_only_cmdlets()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        _fake.Build = (body, _, _) => Task.FromResult(FakePwsh.Command(body) == "Get-OctoEnvironment"
            ? FakePwsh.Ok("Get-OctoEnvironment", """{"name":"ab1-one","repos":[{"name":"octo-a","exists":true,"dirty":true,"unpushed":2}]}""")
            : FakePwsh.Ok("Get-OctoAffectedRepos", """{"affected":["octo-b"]}"""));
        var manager = Manager(queue, supervisor, store);

        var affected = await manager.AffectedAsync("ab1-one", "octo-b", Ct);
        affected.Data!["affected"]![0]!.GetValue<string>().Should().Be("octo-b");
        var row = (await manager.ListAsync("ab1-one", Ct)).Single();
        row.Details!["repos"]![0]!["dirty"]!.GetValue<bool>().Should().BeTrue();
        _fake.BuildCalls.Should().Equal("Get-OctoAffectedRepos -env 'ab1-one' -target 'octo-b' -Json", "Get-OctoEnvironment -env 'ab1-one' -Json");

        _fake.Capabilities = FakePwsh.WorktreeParams;
        var (queue2, supervisor2, store2) = CreateQueue();
        var old = (await Manager(queue2, supervisor2, store2).ListAsync("ab1-one", Ct)).Single();
        old.Details.Should().BeNull();
        old.DetailsProblem.Should().Contain("too old");
        var oldAffected = () => Manager(queue2, supervisor2, store2).AffectedAsync("ab1-one", null, Ct);
        await oldAffected.Should().ThrowAsync<InvalidOperationException>().WithMessage("*Get-OctoAffectedRepos*too old*");
    }

    // ---------- live smoke test findings ----------

    [Fact]
    public async Task A_service_a_build_stopped_stays_in_the_stack_and_service_restart_starts_it()
    {
        var (queue, supervisor, store) = CreateQueue();
        var env = Env("ab1-one", ["octo-a"]);
        _fake.EnvPlan = $$"""{"dryRun":true,"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(env, "octo-a"))}}}]}""";
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha", "beta"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);

        var job = await queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-one", StopServices = true });
        (await WaitAsync(queue, job.Id)).StoppedServices.Should().Equal("ab1-one/alpha");

        var status = await tools.Status(includeLogTail: false, lane: "ab1-one");
        status.Services.Should().Contain(s => s.Name == "alpha" && s.State == "stopped-for-build");
        var restarted = await tools.ServiceRestart("agent-1", ["alpha"], waitForHealthy: false, timeoutSeconds: 1, lane: "ab1-one", cancellationToken: Ct);
        restarted.Status.Services.Should().ContainSingle(s => s.Name == "alpha" && s.State != "exited" && s.State != "stopped-for-build");
        restarted.Status.Services.Single(s => s.Name == "alpha").RepoPath.Should().Be(Path.Combine(env, "octo-a"));
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public async Task The_claim_of_an_environment_slot_lives_in_the_base_lane()
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig(Services);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var lease = new LeaseManager();
        var leases = new LeaseRegistry(lease);
        var claims = new LaneClaims { CurrentLease = lease.Current };
        claims.CurrentLeaseOf = resource => leases.All.FirstOrDefault(l => LaneClaims.ResourceOf(l.Slot) == resource)?.Current();
        leases.Changed += (slot, info) => claims.OnLeaseChanged(LaneClaims.ResourceOf(slot), info);
        var supervisor = new StackSupervisor(store, lease, state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store), claims: claims,
            leases: leases);
        _supervisors.Add(supervisor);
        var env = Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);

        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        File.Exists(LaneClaims.PathOf(_checkout.Lane, "local-stack-ab1-one")).Should().BeTrue("claims live in the base lane");
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
        supervisor.Leases.Get("ab1-one").Release("lane:ab1-one", force: false);

        Directory.Exists(Path.Combine(env, ".octo", "claims")).Should().BeFalse("nothing is written into the environment folder");
        File.Exists(LaneClaims.PathOf(_checkout.Lane, "local-stack-ab1-one")).Should().BeFalse();
    }

    [Fact]
    public async Task Stack_stop_of_an_environment_that_never_ran_is_a_no_op_and_hints_name_the_environment()
    {
        var (supervisor, store, _) = CreateSupervisor();
        Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);

        var stopped = await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
        stopped.Stopped.Should().BeEmpty();
        stopped.Note.Should().Contain("not running");

        var restart = () => tools.ServiceRestart("agent-1", ["alpha"], lane: "ab1-one", cancellationToken: Ct);
        await restart.Should().ThrowAsync<McpException>().WithMessage("*stack_start(owner, lane=\"ab1-one\")*");
    }

    [Fact]
    public void Service_logs_are_capped_and_long_lines_cut()
    {
        var lines = Enumerable.Range(0, 50).Select(i => i % 10 == 0 ? new string('x', 30_000) : $"line {i}").ToList();

        var (text, count, note) = StackTools.Cap(lines, 5_000);

        text.Length.Should().BeLessThanOrEqualTo(5_000);
        text.Should().EndWith("line 49");
        text.Should().Contain("... [cut 28000 chars]");
        count.Should().BeLessThan(50);
        note.Should().Contain("cut").And.Contain("older line(s) left out");
    }

    [Fact]
    public void Slot_names_that_start_alike_are_fine_and_cleanup_commands_match_exact_prefixes()
    {
        var store = _checkout.WriteConfig(Services);
        var (supervisor, _, _) = (new StackSupervisor(store, new LeaseManager(), new StateStore(new DevStackPaths(_checkout.StateDirectory)),
            NullLogger<StackSupervisor>.Instance), 0, 0);
        _supervisors.Add(supervisor);

        supervisor.Slot("ab8700-smoke", create: true).Slot.Index.Should().Be(1);
        supervisor.Slot("ab8700-smoke2", create: true).Slot.Index.Should().Be(2);

        var leftovers = SlotCleanup.Leftovers(store.Load(), new SlotInfo("ab8700-smoke", 1, 100, "s1"), _checkout.StateDirectory);
        leftovers.Should().Contain(l => l.Drop != null && l.Drop.Contains("grep '^s1-'"));
        leftovers.Should().Contain(l => l.Drop != null && l.Drop.Contains("LIKE '\\''s1\\\\_%'\\''") && l.Drop.Contains("localhost:4301"));
    }

    [Fact]
    public void Https_ports_are_read_from_the_urls_argument()
    {
        Probes.HttpsPorts(["x.dll", "--urls=https://0.0.0.0:5003;http://0.0.0.0:5002"]).Should().Equal(5003);
        Probes.HttpsPorts(["--urls=http://0.0.0.0:5000"]).Should().BeEmpty();
    }

    // ---------- retest findings ----------

    [Fact]
    public void Retired_slots_show_drop_commands_generated_from_the_stored_facts()
    {
        var store = _checkout.WriteConfig(Services);
        var paths = new DevStackPaths(_checkout.StateDirectory);
        Directory.CreateDirectory(_checkout.StateDirectory);
        // A state file of an earlier version with stored, too broad commands.
        File.WriteAllText(paths.StateFile, """
            {"RetiredSlots":{"2":{"Name":"ab2-old","Prefix":"s2","PortOffset":200,"RetiredAt":"2026-11-10T01:00:00+01:00",
              "Leftovers":[{"Kind":"x","Name":"s2","Drop":"grep '^s2' | LIKE 's2%'"}]}}}
            """);
        var state = new StateStore(paths);
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance);
        _supervisors.Add(supervisor);

        var leftovers = new SlotTools(supervisor, store, new SlotDataCleanup(store, supervisor, new FakeSlotData().Stores)).Retired()[2].Leftovers!;

        leftovers.Should().Contain(l => l.Name == "octosystem_s2");
        leftovers.Should().Contain(l => l.Drop != null && l.Drop.Contains("grep '^s2-'"));
        leftovers.Should().NotContain(l => l.Drop != null && l.Drop.Contains("grep '^s2' "));
        leftovers.Should().Contain(l => l.Drop != null && l.Drop.Contains("s2\\\\_%"));
    }

    [Fact]
    public async Task A_build_reports_the_services_it_will_stop_and_clears_the_refusal_of_its_target()
    {
        var (queue, supervisor, store) = CreateQueue();
        var env = Env("ab1-one", ["octo-a"]);
        _fake.EnvPlan = $$"""{"dryRun":true,"repositories":[{"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(env, "octo-a"))}}}]}""";
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            await release.Task;
            return FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var blocker = await queue.Enqueue(new BuildRequest { Owner = "x", Kind = BuildKind.Repo, Path = "octo-b" }); // keeps the env build queued

        var refused = () => queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-one" });
        await refused.Should().ThrowAsync<InvalidOperationException>().WithMessage("*stopServices=true*");
        queue.Refusals().Should().ContainSingle(r => r.Target == "ab1-one");

        var retry = await queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-one", StopServices = true });
        retry.StoppedServices.Should().Equal(["ab1-one/alpha"], "the answer names what the build is going to stop");
        queue.Refusals().Should().BeEmpty("a later build of the same target replaces the refusal");

        release.SetResult();
        await WaitAsync(queue, blocker.Id);
        (await WaitAsync(queue, retry.Id)).StoppedServices.Should().Equal("ab1-one/alpha");
    }

    [Fact]
    public async Task Env_create_returns_the_manifest_once()
    {
        var (queue, supervisor, store) = CreateQueue();
        _fake.Build = (_, _, _) =>
        {
            Env("ab1-new", ["octo-a"]);
            return Task.FromResult(FakePwsh.Ok("New-OctoEnvironment", """{"success":true,"name":"ab1-new","manifest":{"name":"ab1-new"}}"""));
        };

        var result = await Manager(queue, supervisor, store).CreateAsync("a", "ab1-new", ["octo-a"], null, null, false, Ct);

        result.Environment.Should().NotBeNull();
        result.Data!["manifest"].Should().BeNull();
        result.Data["name"]!.GetValue<string>().Should().Be("ab1-new");
    }

    [Fact]
    public void Service_logs_count_the_serialized_size()
    {
        var lines = Enumerable.Range(0, 400).Select(i => $"{{\"cmd\":\"find\",\"filter\":{{\"x\":{i}}}}}").ToList();

        var (text, _, _) = StackTools.Cap(lines, 5_000);

        var answer = JsonSerializer.Serialize(JsonSerializer.Serialize(new { text }));
        answer.Length.Should().BeLessThan(5_300, "maxChars bounds what the MCP client receives, escapes included");
    }

    [Fact]
    public void Leftover_names_follow_the_services_normalization()
    {
        SlotCleanup.SystemDatabaseName(" OctoSystem_S2 ").Should().Be("octosystem_s2");
        SlotCleanup.HangfireDatabaseName("s2").Should().Be("s2-OctoSystemJobs");
        SlotCleanup.SchemaPrefix("S-2").Should().Be("s2");
    }

    [Fact]
    public void A_killed_service_is_explained_from_its_log_after_the_stop_signal()
    {
        var log = Path.Combine(_checkout.Root, "svc.log");
        File.WriteAllText(log, "before the stop\n");
        var offset = new FileInfo(log).Length;
        File.AppendAllText(log, "info: Microsoft.Hosting.Lifetime[0] Application is shutting down...\nwaiting for Hangfire server to stop\n");

        var note = SlotRun.KilledNote("assetRepoServices", log, offset, TimeSpan.FromSeconds(15));

        note.Should().Contain("assetRepoServices did not exit within 15 s").And.Contain("its host was shutting down")
            .And.Contain("waiting for Hangfire server to stop").And.NotContain("before the stop").And.Contain("stopTimeoutSeconds");
        SlotRun.KilledNote("x", log, new FileInfo(log).Length, TimeSpan.FromSeconds(15)).Should().Contain("wrote nothing");
    }

    // ---------- isolation test follow-ups ----------

    [Fact]
    public void A_lease_renewal_keeps_the_requested_ttl()
    {
        var lease = new LeaseManager();
        lease.Require("a", "long work", TimeSpan.FromMinutes(720));

        var renewed = lease.Require("a"); // e.g. the stack_start after lease_acquire(ttlMinutes=720)

        (renewed.ExpiresAt - DateTimeOffset.Now).TotalMinutes.Should().BeGreaterThan(700);
        renewed.TtlMinutes.Should().Be(720);
        lease.Require("a", ttl: TimeSpan.FromMinutes(30)).TtlMinutes.Should().Be(30, "an explicit TTL still wins");
    }

    [Fact]
    public async Task Env_create_reserves_the_slot_and_env_list_shows_reserved_or_predicted_slots()
    {
        var (queue, supervisor, store) = CreateQueue();
        supervisor.Slot("other", create: true); // index 1
        _fake.Build = (_, _, _) =>
        {
            Env("ab1-new", ["octo-a"]);
            return Task.FromResult(FakePwsh.Ok("New-OctoEnvironment", """{"success":true}"""));
        };
        var manager = Manager(queue, supervisor, store);

        var created = await manager.CreateAsync("a", "ab1-new", ["octo-a"], null, null, false, Ct);
        Env("ab2-outside", ["octo-a"]); // created by octo-tools without the daemon

        created.Environment!.SlotInfo.Should().Be(new EnvironmentSlot("ab1-new", 2, 200, "s2", true));
        created.Notes.Should().Contain(n => n.Contains("index 2, ports +200, prefix s2"));
        var rows = await manager.ListAsync();
        rows.Single(r => r.Name == "ab2-outside").SlotInfo.Should().Be(new EnvironmentSlot("ab2-outside", 3, 300, "s3", false), "predicted, not reserved");
        supervisor.Registry.Known().Should().NotContain(k => k.Slot.Name == "ab2-outside");
    }

    private const string IdentityService = """
                                             identityServices:
                                               repo: octo-a
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--urls=https://0.0.0.0:5003;http://0.0.0.0:5002"]
                                               ports: [5003, 5002]
                                               enabled: false
                                           """;

    private sealed class FakeHttp(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public List<(string Url, string Body)> Requests { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add((request.RequestUri!.ToString(), request.Content == null ? "" : await request.Content.ReadAsStringAsync(cancellationToken)));
            return answer(request);
        }
    }

    private (SlotOperations Ops, StackSupervisor Supervisor, ConfigStore Store) Ops(FakeHttp? http = null, string? octoToolsConfig = null, PreStartChecks? checks = null,
        ISlotInventory? inventory = null)
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig(Services + "\n" + IdentityService);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        return (new SlotOperations(store, supervisor, _fake, http, octoToolsConfig, checks, inventory == null ? null : _ => inventory), supervisor, store);
    }

    [Fact]
    public async Task Bootstrap_admin_posts_to_the_slot_identity_and_keeps_the_password_in_an_owner_only_file()
    {
        var http = new FakeHttp(_ => new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent("""{"success":true}""") });
        var (ops, supervisor, _) = Ops(http);
        var env = Env("ab1-one", ["octo-a"]);

        var result = await ops.BootstrapAdminAsync("agent-1", "ab1-one", null, null, Ct);

        result.Status.Should().Be("created");
        result.Url.Should().Be("https://localhost:5103/octosystem/api/setup/create-admin", "the identity https port shifted by the slot's +100");
        result.CredentialsFile.Should().Be(Path.Combine(env, ".octo", SlotOperations.CredentialsFileName));
        var stored = JsonDocument.Parse(File.ReadAllText(result.CredentialsFile!)).RootElement;
        var password = stored.GetProperty("password").GetString()!;
        password.Length.Should().Be(24);
        JsonSerializer.Serialize(result).Should().NotContain(password, "the password never leaves the file");
        var sent = JsonDocument.Parse(http.Requests.Single().Body).RootElement;
        sent.GetProperty("password").GetString().Should().Be(password);
        sent.GetProperty("confirmPassword").GetString().Should().Be(password);
        if (!OperatingSystem.IsWindows())
        {
            File.GetUnixFileMode(result.CredentialsFile!).Should().Be(UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }

        supervisor.Leases.Get("ab1-one").Current()!.Owner.Should().Be("lane:ab1-one");
        (await ops.BootstrapAdminAsync("agent-1", "ab1-one", null, null, Ct)).Status.Should().Be("credentialsFileExists");
        http.Requests.Should().HaveCount(1, "an existing credentials file is never overwritten");
    }

    [Fact]
    public async Task Bootstrap_admin_on_a_set_up_system_database_changes_nothing()
    {
        var http = new FakeHttp(_ => new HttpResponseMessage(System.Net.HttpStatusCode.NotFound));
        var (ops, _, _) = Ops(http);
        var env = Env("ab1-one", ["octo-a"]);

        var result = await ops.BootstrapAdminAsync("agent-1", "ab1-one", null, "x@y.z", Ct);

        result.Status.Should().Be("alreadySetUp");
        result.Email.Should().BeNull("nothing was created, so the answer names no admin");
        File.Exists(Path.Combine(env, ".octo", SlotOperations.CredentialsFileName)).Should().BeFalse();
    }

    [Fact]
    public async Task Register_octo_cli_merges_the_installation_with_a_backup_and_registers_contexts_without_switching()
    {
        var config = Path.Combine(_checkout.Root, "octo-tools-config", "installations.json");
        Directory.CreateDirectory(Path.GetDirectoryName(config)!);
        File.WriteAllText(config, """{"registry":{"url":"x"},"installations":[{"name":"local"},{"name":"local-ab1-one","services":{"identity":"old"}}]}""");
        var (ops, _, _) = Ops(octoToolsConfig: config);
        Env("ab1-one", ["octo-a"]);
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Register-OctoCliContext", """{"success":true}"""));

        var result = await ops.RegisterOctoCliAsync("agent-1", "ab1-one", null, ["octosystem", "meshtest"], false, Ct);

        result.Success.Should().BeTrue();
        result.Replaced.Should().BeTrue();
        result.Contexts.Should().Equal("local-ab1-one_octosystem", "local-ab1-one_meshtest");
        File.Exists(result.Backup!).Should().BeTrue();
        var merged = JsonNode.Parse(File.ReadAllText(config))!;
        merged["registry"]!["url"]!.GetValue<string>().Should().Be("x", "other keys stay");
        merged["installations"]!.AsArray().Select(i => i!["name"]!.GetValue<string>()).Should().Equal("local", "local-ab1-one");
        merged["installations"]![1]!["services"]!.ToJsonString().Should().Contain("5103", "the entry carries the shifted URLs");
        var call = _fake.Calls.Last();
        FakePwsh.Strip(call.Body).Should().Be("Register-OctoCliContext -Installation 'local-ab1-one' -TenantId @('octosystem','meshtest') -NoSwitch -NoLogin -Json");
        call.Options.Environment!["OCTO_TOOLS_CONFIG"].Should().Be(config);
    }

    /// <summary>Answers Register-OctoCliContext with success and the slot_login script with <paramref name="marker"/>.</summary>
    private void LoginFake(Func<string, string> marker) =>
        _fake.Build = (body, _, _) => Task.FromResult(body.Contains("LogInClientCredentials", StringComparison.Ordinal)
            ? new PwshResult(0, "octo-cli noise\n" + PwshRunner.Marker + " " + marker(body) + "\n", false, false)
            : FakePwsh.Ok("Register-OctoCliContext", """{"success":true}"""));

    private (SlotOperations Ops, string Folder, string Config) LoginSetup(bool admin = true)
    {
        var config = Path.Combine(_checkout.Root, "octo-tools-config", "installations.json");
        var (ops, _, _) = Ops(octoToolsConfig: config);
        var folder = Path.Combine(Env("ab1-one", ["octo-a"]), ".octo");
        if (admin)
        {
            File.WriteAllText(Path.Combine(folder, SlotOperations.CredentialsFileName), """{"email":"admin@ab1-one.local","password":"Pw-Very-Secret-123!"}""");
        }

        return (ops, folder, config);
    }

    [Fact]
    public async Task Slot_login_creates_the_client_once_keeps_the_secret_in_an_owner_only_file_and_logs_the_contexts_in()
    {
        var (ops, folder, config) = LoginSetup();
        LoginFake(body => body.Contains("if ($true) {")
            ? """{"created":true,"step":"done","error":null,"contexts":[{"name":"local-ab1-one_octosystem","loggedIn":true},{"name":"local-ab1-one_meshtest","loggedIn":true}]}"""
            : """{"created":false,"step":"done","error":null,"contexts":[{"name":"local-ab1-one_octosystem","loggedIn":true}]}""");

        var result = await ops.LoginAsync("agent-1", "ab1-one", null, ["MeshTest"], false, Ct);

        result.Success.Should().BeTrue();
        result.Created.Should().BeTrue();
        result.ClientId.Should().Be("devstack-ab1-one");
        result.Contexts.Select(c => c.Name).Should().Equal("local-ab1-one_octosystem", "local-ab1-one_meshtest");
        result.SecretFile.Should().Be(Path.Combine(folder, SlotOperations.ClientSecretFileName));
        var secret = File.ReadAllText(result.SecretFile).Trim();
        Convert.FromBase64String(secret).Length.Should().Be(32);
        if (!OperatingSystem.IsWindows())
        {
            File.GetUnixFileMode(result.SecretFile).Should().Be(UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }

        JsonSerializer.Serialize(result).Should().NotContain(secret, "the secret never leaves the file");
        result.Shell.Should().Contain("export OCTO_CLI_CLIENT_ID=devstack-ab1-one").And.Contain(l => l.Contains(result.SecretFile));
        FakePwsh.Strip(_fake.Calls[^2].Body).Should()
            .Be("Register-OctoCliContext -Installation 'local-ab1-one' -TenantId @('octosystem','meshtest') -NoSwitch -NoLogin -Json", "the system tenant comes first");
        var (script, options) = _fake.Calls[^1];
        script.Should().NotContain(secret).And.NotContain("Pw-Very-Secret-123!", "both are read from their files inside the script");
        options.Environment.Should().Equal(new Dictionary<string, string?> { ["OCTO_TOOLS_CONFIG"] = config },
            "no secret travels through the process environment of the script itself; the config file is for registering the system context again");
        script.Should().Contain("if ($true) {").And.Contain("'-c', 'LogIn', '--context', $systemContext")
            .And.Contain("-RedirectStandardOutput $log -NoNewWindow", "the device login opens no console window on Windows")
            .And.Contain("https://localhost:5103/octosystem/api/auth/login").And.Contain("https://localhost:5103/connect/deviceverification")
            .And.Contain("'AddClientCredentialsClient', '-id', $clientId").And.Contain("'-apic'")
            .And.Contain("'AddClientToRole', '-id', $clientId, '-r', 'TenantManagement'")
            .And.Contain("foreach ($context in @('local-ab1-one_octosystem', 'local-ab1-one_meshtest'))")
            .And.Contain("'LogInClientCredentials', '--context', $context");
        script.Should().NotContain("UseContext", "the active context never changes").And.NotContain("-s ", "no secret on a command line");

        // The next call (expired token, slot restart): only the login, the secret stays.
        var again = await ops.LoginAsync("agent-1", "ab1-one", null, [], false, Ct);

        again.Created.Should().BeFalse();
        File.ReadAllText(result.SecretFile).Trim().Should().Be(secret);
        _fake.Calls[^1].Body.Should().Contain("if ($false) {").And.Contain("foreach ($context in @('local-ab1-one_octosystem'))");
    }

    [Fact]
    public async Task Slot_login_that_creates_no_client_leaves_no_secret_file_and_renew_keeps_the_old_one()
    {
        var (ops, folder, _) = LoginSetup();
        var file = Path.Combine(folder, SlotOperations.ClientSecretFileName);
        LoginFake(_ => """{"created":false,"step":"adminLogin","error":"The admin of the credentials file cannot sign in at the slot's identity service: wrong e-mail or password.","contexts":[]}""");

        var failed = await ops.LoginAsync("agent-1", "ab1-one", null, [], false, Ct);

        failed.Success.Should().BeFalse();
        failed.Notes.Should().Contain(n => n.StartsWith("Failed at step 'adminLogin'") && n.Contains("cannot sign in"));
        File.Exists(file).Should().BeFalse("a secret no client was created with would make the next call skip the creation");

        // renew that fails: the secret of the existing client comes back.
        File.WriteAllText(file, "old-secret\n");
        var renew = await ops.LoginAsync("agent-1", "ab1-one", null, [], true, Ct);

        renew.Success.Should().BeFalse();
        File.ReadAllText(file).Should().Be("old-secret\n");
        _fake.Calls[^1].Body.Should().Contain("DeleteClient -id $clientId -y --context $systemContext").And.NotContain("old-secret");

        // A context that cannot log in with an existing secret: the answer says what to do.
        LoginFake(_ => """{"created":false,"step":"done","error":null,"contexts":[{"name":"local-ab1-one_octosystem","loggedIn":false,"note":"octo-cli -c LogInClientCredentials failed (exit 253): invalid_client"}]}""");
        var stale = await ops.LoginAsync("agent-1", "ab1-one", null, [], false, Ct);

        stale.Success.Should().BeFalse();
        stale.Contexts.Single().Note.Should().Contain("invalid_client");
        stale.Notes.Should().Contain(n => n.Contains("stack_setup(owner, lane=\"ab1-one\", steps=[\"login\"], renew=true)"));
        File.ReadAllText(file).Should().Be("old-secret\n");
    }

    [Fact]
    public async Task Slot_login_refuses_the_default_slot_and_a_slot_without_admin_credentials()
    {
        var (ops, folder, _) = LoginSetup(admin: false);

        var defaultSlot = () => ops.LoginAsync("agent-1", null, "default", [], false, Ct);
        await defaultSlot.Should().ThrowAsync<ArgumentException>().WithMessage("*shared stack*is not set up by the daemon*");

        var noAdmin = () => ops.LoginAsync("agent-1", "ab1-one", null, [], false, Ct);
        await noAdmin.Should().ThrowAsync<InvalidOperationException>().WithMessage("*the admin step writes it*stack_setup(owner, lane=\"ab1-one\", steps=[\"login\"])*");
        var badTenant = () => ops.LoginAsync("agent-1", "ab1-one", null, ["a'; rm"], false, Ct);
        await badTenant.Should().ThrowAsync<ArgumentException>().WithMessage("*no tenant id*");
        _fake.Calls.Should().BeEmpty("nothing ran");
        File.Exists(Path.Combine(folder, SlotOperations.ClientSecretFileName)).Should().BeFalse();
    }

    [Fact]
    public async Task Apply_overlay_needs_the_slot_context_and_calls_Invoke_IdentityOverlay()
    {
        var contexts = Path.Combine(_checkout.Root, "contexts.json");
        File.WriteAllText(contexts, """{"Contexts":{}}""");
        var (ops, _, _) = Ops(checks: new PreStartChecks([], contexts));
        Env("ab1-one", ["octo-a"]);

        var missing = () => ops.ApplyOverlayAsync("agent-1", "ab1-one", null, Ct);
        await missing.Should().ThrowAsync<InvalidOperationException>().WithMessage("*no octo-cli context local-ab1-one_octosystem*stack_setup(owner, lane=\"ab1-one\")*");

        File.WriteAllText(contexts, """{"Contexts":{"local-ab1-one_octosystem":{}}}""");
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-IdentityOverlay", """{"summary":{"failed":0}}"""));
        var result = await ops.ApplyOverlayAsync("agent-1", "ab1-one", null, Ct);

        result.Success.Should().BeTrue();
        _fake.BuildCalls.Last().Should().StartWith("function global:octo-cli-slot-ab1-one").And.Contain("Invoke-IdentityOverlay -OverlayFile")
            .And.NotContain("Import-Module", "profile.ps1 imports the module")
            .And.Contain("octo-cli --context local-ab1-one_octosystem").And.Contain("identity-overlay.yaml");
    }

    [Fact]
    public async Task Service_env_shows_the_launch_environment_with_secrets_masked()
    {
        var (ops, supervisor, store) = Ops();
        Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1,
            envVars: new Dictionary<string, string?> { ["OCTO_SYSTEM__ADMINUSERPASSWORD"] = "hunter2", ["PLAIN"] = "visible" }, cancellationToken: Ct);

        var result = ops.ServiceEnv("ab1-one", null, "alpha");

        result.Source.Should().Be("launch");
        result.EnvVars["PLAIN"].Should().Be("visible");
        result.EnvVars["OCTO_SYSTEM__ADMINUSERPASSWORD"].Should().NotBe("hunter2");
        JsonSerializer.Serialize(result).Should().NotContain("hunter2");
        result.EnvVars["OCTO_SYSTEM__SYSTEMDATABASENAME"].Should().Be("OctoSystem_s1", "the slot's derived values are part of it");
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
        SlotOperations.ParseEnviron("A=1\0B=x=y\0\0").Should().Equal(new Dictionary<string, string?> { ["A"] = "1", ["B"] = "x=y" });
    }

    [Fact]
    public void Stack_status_flags_a_service_whose_loaded_entry_assembly_is_elsewhere()
    {
        ServiceStatus Svc(string name, int pid, string repo) => new(name, "healthy", true, null, pid, null, repo, repo, "dotnet", ["X.dll"], "/l", [], DateTimeOffset.Now,
            null, null, false, null);
        var status = new StackStatus(true, "/c", "DebugL", null, null, new LeaseSnapshot(null, []), [Svc("a", 11, "/env/octo-a"), Svc("b", 12, "/env/octo-b")], [],
            ExternalSnapshot.Empty);

        var checkedStatus = StackTools.WithEntryAssemblies(status, _ => new Dictionary<int, string?>
        {
            [11] = "/env/octo-a/bin/DebugL/net10.0/X.dll", [12] = "/main/octo-b/bin/DebugL/net10.0/X.dll"
        });

        checkedStatus.Services[0].EntryAssemblyProblem.Should().BeNull();
        checkedStatus.Services[1].EntryAssemblyProblem.Should().Contain("not a file below /env/octo-b");
        EntryAssemblies.ParseLsofPaths("p11\nfcwd\nn/env\nftxt\nn/env/octo-a/X.dll\np12\nn/x/Y.dll\n")[11].Should().Contain("/env/octo-a/X.dll");
        EntryAssemblies.DllOf(["Meshmakers.Octo.X.dll", "--urls=x"]).Should().Be("Meshmakers.Octo.X.dll");
    }

    private sealed class FakeInventory : ISlotInventory
    {
        public Dictionary<string, List<InventoryTenant>> Tenants { get; } = new();
        public List<string> Databases { get; } = [];
        public List<InventoryQueue> Queues { get; } = [];
        public List<string> Schemas { get; } = [];

        public Task<IReadOnlyList<string>> DatabasesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(Databases);

        public Task<IReadOnlyList<InventoryTenant>> TenantsAsync(string systemDatabase, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<InventoryTenant>>(Tenants.GetValueOrDefault(systemDatabase) ?? []);

        public Task<IReadOnlyList<InventoryQueue>> QueuesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<InventoryQueue>>(Queues);

        public Task<IReadOnlyList<string>> CrateSchemasAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<string>>(Schemas);
    }

    [Fact]
    public async Task Slot_verify_compares_derived_names_and_warns_about_shared_tenant_databases()
    {
        var inventory = new FakeInventory();
        inventory.Databases.AddRange(["octosystem", "octosystem_s1", "meshtest", "isotest_s1", "legacy"]);
        inventory.Tenants["octosystem_s1"] =
        [
            new InventoryTenant("isotest", "isotest_s1", true, "octosystem_s1"),
            new InventoryTenant("meshtest", "meshtest", true, "octosystem"),
            new InventoryTenant("legacy", "legacy", true, null)
        ];
        inventory.Tenants["octosystem"] = [new InventoryTenant("meshtest", "meshtest", true, "octosystem")];
        inventory.Queues.AddRange([
            new InventoryQueue("s1-octo::bot::x", 1, [new InventoryConsumer("Meshmakers.Octo.Backend.BotServices", 4242, "pod-1")]),
            new InventoryQueue("s1-octo::bot::y", 1, [new InventoryConsumer("Meshmakers.Octo.Backend.AssetRepositoryServices", 777, System.Net.Dns.GetHostName())]),
            new InventoryQueue("s10-octo::y", 1, [new InventoryConsumer("Other", 1, null)]),
            new InventoryQueue("default-hangfire", 1, [new InventoryConsumer("Z", 2, null)])
        ]);
        inventory.Schemas.AddRange(["s1_isotest", "s10_x", "meshtest"]);
        var (ops, _, _) = Ops(inventory: inventory);
        Env("ab1-one", ["octo-a"]);

        var result = await ops.VerifyAsync("ab1-one", null, Ct);

        result.SystemDatabase.Should().Be("octosystem_s1");
        result.SystemDatabaseExists.Should().BeTrue();
        result.Queues.Should().Be(2, "s10- is another slot's prefix");
        result.ConsumerConnections.Should().Equal(new VerifyConsumer("Meshmakers.Octo.Backend.AssetRepositoryServices", 777, System.Net.Dns.GetHostName(), null),
            new VerifyConsumer("Meshmakers.Octo.Backend.BotServices", 4242, "pod-1", null));
        result.Warnings.Should().Contain(w => w.Contains("pid 777") && w.Contains("is no service of lane stack 'ab1-one'"), "a process on this machine the slot did not start");
        result.Ok.Should().BeFalse("a warning is no clean verdict");
        result.Lane.Should().Be("ab1-one");
        var json = JsonSerializer.SerializeToNode(result, ModelContextProtocol.McpJsonUtilities.DefaultOptions)!.AsObject();
        json.First().Key.Should().Be("ok", "the verdict comes first");
        json["ok"]!.GetValue<bool>().Should().BeFalse();
        result.Warnings.Should().NotContain(w => w.Contains("pid 4242"), "a pod's consumer is not a host process");
        result.CrateSchemas.Should().Equal("s1_isotest");
        result.Warnings.Should().Contain(w => w.Contains("'meshtest' is registered in octosystem_s1 and in octosystem (slot 'default')"));
        result.Warnings.Should().Contain(w => w.Contains("'meshtest' is owned by octosystem"));
        result.Warnings.Should().Contain(w => w.Contains("'legacy' has no ownership marker"));
        result.Unreachable.Should().BeNull();

        // The default slot is verified with its configured names (read-only), its schemas are the unprefixed ones.
        inventory.Tenants["octosystem"] = [new InventoryTenant("meshtest", "meshtest", true, "octosystem")];
        var main = await ops.VerifyAsync(null, "default", Ct);
        main.SystemDatabase.Should().Be("octosystem");
        main.InstancePrefix.Should().Be("default");
        main.Queues.Should().Be(1);
        main.CrateSchemas.Should().Equal("meshtest");
        var mutating = () => ops.BootstrapAdminAsync("a", null, "default", null, Ct);
        await mutating.Should().ThrowAsync<ArgumentException>().WithMessage("*shared stack*is not set up by the daemon*");
    }

    [Fact]
    public void The_processes_of_a_slot_are_the_recorded_pids_and_everything_below_them()
    {
        // Windows: the daemon records cmd.exe (10), RabbitMQ reports its dotnet child (11); 12 is a grandchild, 20 a stranger.
        var links = new[] { (10, 1), (11, 10), (12, 11), (20, 1), (30, 20) };

        SlotVerifier.OwnProcesses([("asset", 10)], links).Should().Equal(new Dictionary<int, string> { [10] = "asset", [11] = "asset", [12] = "asset" });
        SlotVerifier.OwnProcesses([("asset", 10), ("bot", 20)], links).Should().Equal(new Dictionary<int, string>
        {
            [10] = "asset", [11] = "asset", [12] = "asset", [20] = "bot", [30] = "bot"
        });
        SlotVerifier.OwnProcesses([("asset", 11)], links).Keys.Should().BeEquivalentTo([11, 12], "a parent is no own process");
        SlotVerifier.OwnProcesses([("asset", 42)], links).Keys.Should().BeEquivalentTo([42], "macOS/Linux: /bin/sh -c exec is the service itself, gone or not");
        SlotVerifier.OwnProcesses([], links).Should().BeEmpty();
    }

    [Fact]
    public void Stack_status_names_the_service_process_below_the_recorded_wrapper_and_leaves_stopped_services_alone()
    {
        var status = new StackStatus(true, null, null, null, null, new LeaseSnapshot(null, []),
            [Service("asset", 10, "healthy"), Service("bot", 20, "exited"), Service("platform", 30, "starting")], [], ExternalSnapshot.Empty);

        // cmd.exe 10 runs dotnet 11 (which runs 12); 20 exited, its pid has a child now; 30 has no child yet.
        var result = StackTools.WithServiceProcesses(status, [(11, 10), (12, 11), (21, 20)]);

        result.Services.Select(s => (s.Name, s.Pid, s.ProcessId)).Should().Equal(("asset", 10, 11), ("bot", 20, null), ("platform", 30, null));
        var json = JsonSerializer.SerializeToNode(result.Services[0], ModelContextProtocol.McpJsonUtilities.DefaultOptions)!.AsObject();
        json["pid"]!.GetValue<int>().Should().Be(10);
        json["processId"]!.GetValue<int>().Should().Be(11);
        JsonSerializer.SerializeToNode(result.Services[2], ModelContextProtocol.McpJsonUtilities.DefaultOptions)!.AsObject().ContainsKey("processId").Should().BeFalse();
        if (!OperatingSystem.IsWindows())
        {
            StackTools.WithServiceProcesses(status).Should().BeSameAs(status, "macOS/Linux: the recorded pid is the service");
        }

        // The status page: the rows of the lane stacks get it too (cmd.exe 40 runs dotnet 41; 50 was stopped for a build).
        var lane = new SlotSummary("ab1-one", 1, 100, "s1", "lane", true, null, null, "lane:ab1-one", null, 1, 1,
            [new SlotServiceRow("alpha", "healthy", 40, [], null), new SlotServiceRow("beta", "stopped-for-build", 50, [], null)], null, null);
        var withSlots = StackTools.WithServiceProcesses(status with { Services = [], Slots = [lane] }, [(41, 40), (51, 50)]);
        withSlots.Slots!.Single().Services.Select(s => (s.Name, s.ProcessId)).Should().Equal(("alpha", 41), ("beta", null));

        static ServiceStatus Service(string name, int pid, string state) =>
            new(name, state, state == "healthy", null, pid, null, "/r", "/r", "dotnet", [], "/log", [], DateTimeOffset.Now, null, null, false, null);
    }

    [Fact]
    public async Task Slot_verify_counts_the_child_of_a_recorded_service_as_the_slots_own_consumer()
    {
        var inventory = new FakeInventory();
        inventory.Databases.Add("octosystem_s1");
        var host = System.Net.Dns.GetHostName();
        var (_, supervisor, store) = Ops(inventory: inventory);
        Env("ab1-one", ["octo-a"]);
        await supervisor.StartStackAsync("lane:ab1-one", new StartSpec { Slot = "ab1-one", Checkout = "wt-ab1-one", Services = ["alpha"] }, null, false, false,
            TimeSpan.FromSeconds(1), Ct);
        var recorded = supervisor.Slot("ab1-one").Pids().Single();
        var child = recorded + 100_000;
        inventory.Queues.Add(new InventoryQueue("s1-octo::a", 1, [new InventoryConsumer("Meshmakers.Octo.Backend.A", child, host)]));
        inventory.Queues.Add(new InventoryQueue("s1-octo::b", 1, [new InventoryConsumer("Meshmakers.Octo.Backend.Stranger", child + 1, host)]));
        var ops = new SlotOperations(store, supervisor, _fake, inventory: _ => inventory, processLinks: () => [(child, recorded)]);

        var result = await ops.VerifyAsync("ab1-one", null, Ct);

        result.Warnings.Should().NotContain(w => w.Contains($"pid {child} "), "the broker reports the child of the recorded cmd.exe wrapper on Windows");
        result.Warnings.Should().Contain(w => w.Contains($"pid {child + 1} ") && w.Contains("is no service of lane stack 'ab1-one'"));
        result.ConsumerConnections.Should().Equal(new VerifyConsumer("Meshmakers.Octo.Backend.A", child, host, "alpha"),
            new VerifyConsumer("Meshmakers.Octo.Backend.Stranger", child + 1, host, null));
        await supervisor.StopServicesAsync("lane:ab1-one", null, Ct, slot: "ab1-one");
    }

    [Fact]
    public void Masking_decides_by_the_last_key_segment_and_stays_safe_for_earlier_ones()
    {
        SecretMask.Mask("OCTO_BOT__SECRETSWEEP__BACKUPSTORAGEPATH", "/Users/x/.local/state/s").Should().Be("/Users/x/.local/state/s");
        SecretMask.Mask("OCTO_SYSTEM__ADMINUSERPASSWORD", "x").Should().Be(SecretMask.Masked);
        SecretMask.Mask("CLAUDE_CODE_MESSAGING_TOKEN", "abc").Should().Be(SecretMask.Masked);
        SecretMask.Mask("OCTO_SECRETS__VALUE", "not a path").Should().Be(SecretMask.Masked, "a secret word in an earlier segment masks a non-path value");
        SecretMask.Mask("OCTO_MONGO__CONNECTION", "mongodb://u:p@h").Should().Be("mongodb://***@h");
    }

    [Fact]
    public void The_ps_environment_of_a_process_is_parsed_after_its_command_line()
    {
        var command = "dotnet X.dll --urls=http://0.0.0.0:5200;https://0.0.0.0:5201";
        var env = SlotOperations.ParsePsEnvironment(command + " PATH=/usr/bin:/bin OCTO_A__TOKEN=t0k MULTI=a b c NoDefaultCurrentDirectoryInExePath=1\n", command);

        env.Should().Equal(new Dictionary<string, string?>
        {
            ["PATH"] = "/usr/bin:/bin", ["OCTO_A__TOKEN"] = "t0k", ["MULTI"] = "a b c", ["NoDefaultCurrentDirectoryInExePath"] = "1"
        });
        SlotOperations.ParsePsEnvironment("other command A=1", command).Should().BeEmpty("the command line must match");
    }

    // ---------- configuration inspector ----------

    [Fact]
    public async Task The_configuration_inspector_never_contains_a_secret_value()
    {
        const string Secret = "S3cr3t-Value-4711";
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig($$"""
                                              alpha:
                                                repo: octo-a
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--ApiKey={{Secret}}", "--Mongo=mongodb://u:{{Secret}}@h"]
                                                env: { OCTO_X__CLIENTSECRET: "{{Secret}}", OCTO_X__CONNECTIONSTRING: "mongodb://u:{{Secret}}@h" }
                                                announceEnv: { OCTO_Y__TOKEN: "{{Secret}}" }
                                            """, $$"""
                                                   environment:
                                                     OCTO_SYSTEM__ADMINUSERPASSWORD: "{{Secret}}"
                                                     LICENSE_KEY: "{{Secret}}"
                                                   profiles:
                                                     base:
                                                       services: [alpha]
                                                       environment: { OCTO_BASE__PASSWORD: "{{Secret}}" }
                                                     child:
                                                       extends: base
                                                       overrides:
                                                         alpha: { env: { OCTO_Z__SECRET: "{{Secret}}" }, extraArgs: ["--Token={{Secret}}"] }
                                                       instances:
                                                         alpha2: { of: alpha, ports: [5990], env: { OCTO_I__APIKEY: "{{Secret}}" } }
                                                   """);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        Env("ab1-one", ["octo-a"]);
        await new StackTools(supervisor, store).Start("agent-1", profile: "child", lane: "ab1-one", waitForHealthy: false, timeoutSeconds: 1,
            envVars: new Dictionary<string, string?> { ["OCTO_RUN__PASSWORD"] = Secret }, cancellationToken: Ct);
        var ops = new SlotOperations(store, supervisor, _fake);

        var inspection = await Meshmakers.Octo.DevStack.Ui.ConfigInspector.BuildAsync(store, supervisor, ops);
        var json = JsonSerializer.Serialize(inspection, JsonSerializerOptions.Web);

        inspection.Running.Should().NotBeEmpty("a running service with secrets in its environment is part of the check");
        inspection.Profiles.Should().HaveCount(2);
        json.Should().NotContain(Secret, "no view of the inspector may carry a secret value");
        json.Should().Contain("***");

        await new StackTools(supervisor, store).Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public async Task The_inspector_marks_a_running_value_that_differs_from_the_slot_derivation()
    {
        var (ops, supervisor, store) = Ops();
        Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1,
            envVars: new Dictionary<string, string?> { ["OCTO_SYSTEM__SYSTEMDATABASENAME"] = "WrongDb" }, cancellationToken: Ct);

        var inspection = await Meshmakers.Octo.DevStack.Ui.ConfigInspector.BuildAsync(store, supervisor, ops);

        var running = inspection.Running.Single(r => r.Service.Service == "alpha");
        running.Slot.Should().Be("ab1-one");
        running.Differences.Should().ContainSingle(d => d.Key == "OCTO_SYSTEM__SYSTEMDATABASENAME" && d.Actual == "WrongDb" && d.Expected == "OctoSystem_s1" &&
                                                        d.ExpectedFrom == "slot ab1-one (systemDatabase)");
        inspection.Slots.Should().Contain(s => s.Name == "ab1-one" && s.State == "running" && s.Derived["systemDatabase"] == "OctoSystem_s1");
        inspection.Environments.Should().ContainSingle(e => e.Name == "ab1-one");
        inspection.Services.Single(s => s.Definition.Name == "alpha").WorkingDirectory.Should().Be(Path.Combine(_checkout.Lane, "octo-a"));
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public void The_status_page_script_renders_text_only()
    {
        var root = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(root, "Octo.DevStack.sln")))
        {
            root = Path.GetDirectoryName(root)!;
        }

        var ui = Path.Combine(root, "src", "DevStack", "Ui");
        var js = File.ReadAllText(Path.Combine(ui, "app.js"));
        js.Should().NotContain("innerHTML").And.NotContain("outerHTML").And.NotContain("insertAdjacentHTML").And.NotContain("document.write");
        // Nothing else turns text into markup or code either.
        js.Should().NotContain("DOMParser").And.NotContain("createContextualFragment").And.NotContain("eval(").And.NotContain("new Function")
            .And.NotContain("srcdoc").And.NotContain("javascript:");
    }

    [Fact]
    public void The_status_page_is_read_only_and_loads_nothing_from_outside()
    {
        var root = AppContext.BaseDirectory;
        while (!File.Exists(Path.Combine(root, "Octo.DevStack.sln")))
        {
            root = Path.GetDirectoryName(root)!;
        }

        var ui = Path.Combine(root, "src", "DevStack", "Ui");
        var js = File.ReadAllText(Path.Combine(ui, "app.js"));
        var html = File.ReadAllText(Path.Combine(ui, "index.html"));
        var css = File.ReadAllText(Path.Combine(ui, "app.css"));

        // The page only reads: every request is a plain GET of the daemon's own endpoints.
        js.Should().NotContain("method:").And.NotContain("XMLHttpRequest").And.NotContain("sendBeacon").And.NotContain("WebSocket");
        System.Text.RegularExpressions.Regex.Matches(js, @"fetch\(\s*[`""]([^`""$?]*)").Select(m => m.Groups[1].Value)
            .Should().NotBeEmpty().And.OnlyContain(url => url.StartsWith("/api/", StringComparison.Ordinal));
        html.Should().NotContain("<form").And.NotContain("method=");

        // Nothing from outside the daemon, nothing inline (the Content-Security-Policy would block it anyway).
        foreach (var text in new[] { js, html, css })
        {
            text.Should().NotContain("https://").And.NotContain("@import");
            System.Text.RegularExpressions.Regex.IsMatch(text, @"http://(?!www\.w3\.org/2000/svg)").Should().BeFalse();
        }

        css.Should().NotContain("url(");
        html.Should().NotContain("<style").And.NotContain("style=").And.NotContain("onclick").And.NotContain("onload");
        System.Text.RegularExpressions.Regex.IsMatch(html, @"<script(?![^>]*\bsrc=""/ui/app\.js"")").Should().BeFalse();
    }

    [Fact]
    public async Task A_build_taken_over_from_before_a_daemon_restart_holds_back_only_its_own_environment()
    {
        Env("ab1-one", ["octo-a"]);
        Env("ab2-two", ["octo-a"]);
        var (supervisor, store, state) = CreateSupervisor();
        var paths = new DevStackPaths(_checkout.StateDirectory);
        // A build of environment ab1-one that an older daemon (no job files) left running: its pid in the state file.
        var old = TestProcess.StartSleep(30);
        try
        {
            state.SaveBuild(new PersistedBuild
            {
                Id = "b3-104847", Owner = "reimar/AB#1_x", Kind = "env", Target = "ab1-one", Pid = old.Id, StartedAt = DateTimeOffset.Now.AddMinutes(-20),
                LogFile = Path.Combine(paths.BuildLogDirectory, "b3-104847.log")
            });
            var queue = new BuildQueue(store, supervisor, supervisor.Leases.Default, paths, NullLogger<BuildQueue>.Instance, _fake, state, null,
                new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50), IsBuildProcess = ProcessTree.IsAlive },
                () => Task.FromResult(ExternalSnapshot.Empty));
            _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[]}"""));
            queue.Get("b3-104847").Should().BeEquivalentTo(new { State = "running", Env = "ab1-one" });

            // Another environment builds next to it; its own environment waits for it (one build per environment).
            var other = await queue.Enqueue(new BuildRequest { Owner = "b", Kind = BuildKind.Env, Environment = "ab2-two" });
            (await WaitAsync(queue, other.Id)).State.Should().Be("succeeded");
            var same = await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-one" });
            same.State.Should().Be("queued");
            same.Queue!.WaitingFor.Should().Contain("one build or test run per lane").And.Contain("b3-104847");
            queue.ActiveFor("ab1-one").Select(b => b.Id).Should().Equal("b3-104847", same.Id);

            // Its owner (or any session of its environment) ends it; then the waiting build runs.
            queue.Cancel("b3-104847", "a", env: "ab1-one");
            (await WaitAsync(queue, "b3-104847")).State.Should().Be("canceled");
            (await WaitAsync(queue, same.Id)).State.Should().Be("succeeded");
            await old.WaitForExitAsync(Ct);
        }
        finally
        {
            if (!old.HasExited)
            {
                old.Kill();
            }
        }
    }

    // ---------- only what changed (AB#8814) ----------

    [Fact]
    public async Task An_environment_build_passes_repos_and_skip_and_shows_what_was_skipped_and_why()
    {
        _fake.Capabilities = FakePwsh.NarrowParams;
        var folder = Env("ab1-ok", ["octo-a", "octo-b", "octo-c"]);
        _fake.EnvPlan = $$"""
                          {"dryRun":true,"repositories":[
                            {"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(folder, "octo-a"))}},"action":"build","reason":"sourcesChanged","detail":"src/A/X.cs is newer than the last build"},
                            {"repo":"octo-b","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(folder, "octo-b"))}},"action":"skip","reason":"unchanged","detail":"built at 10:02, nothing changed since"},
                            {"repo":"octo-c","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(folder, "octo-c"))}},"action":"skip","reason":"excluded","detail":"-skip"}]}
                          """;
        _fake.Build = (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "plan",
                "\"repos\":[{\"repo\":\"octo-a\",\"mode\":\"dotnet\",\"action\":\"build\",\"reason\":\"sourcesChanged\"},{\"repo\":\"octo-b\",\"mode\":\"dotnet\",\"action\":\"skip\",\"reason\":\"unchanged\"},{\"repo\":\"octo-c\",\"mode\":\"dotnet\",\"action\":\"skip\",\"reason\":\"excluded\"}],\"count\":3");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":3");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoDone",
                "\"repo\":\"octo-a\",\"index\":1,\"count\":3,\"success\":true,\"status\":\"built\",\"reason\":\"sourcesChanged\",\"seconds\":12,\"buildSeconds\":10,\"testSeconds\":0,\"packageSeconds\":2,\"copied\":3,\"purged\":3,\"logFile\":null");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoSkipped", "\"repo\":\"octo-b\",\"index\":2,\"count\":3,\"reason\":\"unchanged\",\"detail\":\"built at 10:02, nothing changed since\"");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoSkipped", "\"repo\":\"octo-c\",\"index\":3,\"count\":3,\"reason\":\"excluded\",\"detail\":\"-skip\"");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "done", "\"success\":true,\"failedRepo\":null,\"failedStep\":null,\"elapsedSeconds\":13");
            return Task.FromResult(FakePwsh.Ok("Invoke-BuildEnvironment",
                """{"success":true,"exitCode":0,"skipUnchanged":true,"builtCount":1,"skippedCount":2,"repositories":[{"repo":"octo-a","success":true,"status":"built","reason":"sourcesChanged","buildSeconds":10,"testCompileSeconds":0,"packageSeconds":2,"copiedCount":3,"purged":["a","b","c"]},{"repo":"octo-b","success":true,"status":"skipped","reason":"unchanged","detail":"built at 10:02, nothing changed since"},{"repo":"octo-c","success":true,"status":"skipped","reason":"excluded","detail":"-skip"}],"staleWarnings":[{"repo":"octo-c","skipReason":"excluded","changed":true,"message":"octo-c was excluded although octo-a, which it consumes, was built: its packages are older than octo-a's."}],"notBuilt":[]}"""));
        };
        var (queue, _, _) = CreateQueue();
        var request = new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok", Repos = ["octo-a", " b "], Skip = ["octo-c"], BuildUnchanged = true };

        var plan = await queue.Plan(request);
        plan.Steps.Single().Command.Should().StartWith("Invoke-BuildEnvironment -env 'ab1-ok' -repos 'octo-a','b' -skip 'octo-c' -buildUnchanged -Json");
        plan.Steps.Single().Repos.Select(r => (r.Repo, r.Action, r.Reason)).Should()
            .Equal(("octo-a", "build", "sourcesChanged"), ("octo-b", "skip", "unchanged"), ("octo-c", "skip", "excluded"));
        plan.Steps.Single().Repos[1].Detail.Should().Be("built at 10:02, nothing changed since");
        plan.Steps.Single().Repos[0].Stale.Should().BeNull("the cmdlet's prediction replaces the bin-vs-source check");

        var done = await WaitAsync(queue, (await queue.Enqueue(request)).Id);

        done.State.Should().Be("succeeded", done.Outcome?.Summary);
        done.Outcome!.Summary.Should().Be("1 repo(s) built, 2 skipped (1 unchanged, 1 excluded); test projects NOT compiled and no test ran " +
                                          "(verifyTests=true compiles them, lane_test / base_test run them)");
        done.Progress!.Repos!.Select(r => r.Tests).Should().Equal("notCompiled", null, null);
        done.Progress!.Repos!.Select(r => (r.Repo, r.State, r.Reason)).Should()
            .Equal(("octo-a", "done", "sourcesChanged"), ("octo-b", "skipped", "unchanged"), ("octo-c", "skipped", "excluded"));
        done.Progress.Repos![1].Should().BeEquivalentTo(new { Seconds = (double?)null, BuildSeconds = (double?)null, Copied = (int?)null });
        done.Progress.Should().BeEquivalentTo(new { RepoIndex = 3, RepoCount = 3 });
        done.Progress.Totals.Should().Be(new BuildPhaseSeconds(10, 0, 2, null), "a skipped repo adds no time");
        done.Notes.Should().Contain("stale: octo-c was excluded although octo-a, which it consumes, was built: its packages are older than octo-a's.");
    }

    [Fact]
    public async Task A_repo_skipped_while_the_build_runs_counts_as_passed_in_the_progress()
    {
        _fake.Capabilities = FakePwsh.NarrowParams;
        Env("ab1-ok", ["octo-a", "octo-b"]);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoSkipped", "\"repo\":\"octo-a\",\"index\":1,\"count\":2,\"reason\":\"unchanged\",\"detail\":null");
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoStart", "\"repo\":\"octo-b\",\"index\":2,\"count\":2");
            await release.Task;
            return FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        var (queue, _, _) = CreateQueue();

        var job = await queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok" });
        var running = await WaitAsync(queue, job.Id, s => s.Progress?.Current != null);

        running.Progress!.Current!.Repo.Should().Be("octo-b");
        running.Progress.Should().BeEquivalentTo(new { RepoIndex = 2, RepoCount = 2 });
        running.Progress.Repos!.Select(r => (r.Repo, r.State, r.Reason)).Should().Equal(("octo-a", "skipped", "unchanged"), ("octo-b", "building", null));
        release.SetResult();
        await WaitAsync(queue, job.Id);
    }

    // ---------- live output, and whether tests ran (AB#8833) ----------

    [Fact]
    public async Task A_running_build_shows_the_log_of_the_repo_that_builds_and_says_that_tests_only_compiled()
    {
        var folder = Env("ab1-ok", ["octo-a", "octo-b"]);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _fake.Build = async (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoStart", "\"repo\":\"octo-a\",\"index\":1,\"count\":2");
            // dotnet writes into the repo's own log; the job log gets nothing while the cmdlet works.
            File.WriteAllText(Path.Combine(folder, "octo-a", "Invoke-Build.log"),
                "Restoring https://user:pw@feed.example/v3/index.json\n" + string.Join("\n", Enumerable.Range(1, 30).Select(i => $"  Compiling Project{i}")) + "\n" + new string('x', 900) + "\n");
            await release.Task;
            FakePwsh.Event(events, "Invoke-BuildEnvironment", "repoDone", "\"repo\":\"octo-a\",\"index\":1,\"count\":2,\"success\":true,\"seconds\":5,\"buildSeconds\":3,\"testSeconds\":2,\"packageSeconds\":0,\"copied\":0,\"purged\":0,\"logFile\":null");
            return FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[{"repo":"octo-a","success":true,"buildSeconds":3,"testCompileSeconds":2},{"repo":"octo-b","success":true,"buildSeconds":1,"testCompileSeconds":1}]}""");
        };
        var (queue, _, _) = CreateQueue();

        var job = await queue.Enqueue(new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok", VerifyTests = true });
        await WaitAsync(queue, job.Id, s => s.Progress?.Current != null);

        queue.Get(job.Id).Live.Should().BeNull("the compact status carries no output unless asked");
        var live = queue.Get(job.Id, live: 5).Live!;
        live.Should().BeEquivalentTo(new { Selected = "octo-a", Source = "live", Truncated = true });
        live.Lines.Should().HaveCount(5);
        live.Lines[^1].Should().HaveLength(404, "a long line is cut for the status").And.EndWith(" ...");
        live.Lines[0].Should().Be("  Compiling Project27");

        // The status page asks without a repo: the daemon picks the repo that builds; "@job" is the job log.
        var auto = queue.Output(job.Id, null, 100);
        auto.Log.Selected.Should().Be("octo-a");
        auto.Log.Lines[0].Should().Be("Restoring https://***@feed.example/v3/index.json");
        auto.Repos.Single(r => r.Repo == "octo-a").HasLog.Should().BeTrue();
        queue.Output(job.Id, "@job").Log.Should().BeEquivalentTo(new { Selected = (string?)null, Source = "job" });

        release.SetResult();
        var done = await WaitAsync(queue, job.Id);
        done.Outcome!.Summary.Should().Be("2 repo(s) built; test projects compiled, no test ran (lane_test / base_test run them)");
        done.Progress!.Repos!.Select(r => (r.Repo, r.Tests, r.TestSeconds)).Should().Equal(("octo-a", "compiled", 2), ("octo-b", "compiled", 1));
        // After the build the kept log of a repo is still there for live=N.
        queue.Get(job.Id, "octo-a", live: 3).Live.Should().BeEquivalentTo(new { Selected = "octo-a", Source = "kept" });
        queue.Get(job.Id, live: 3).Live!.Source.Should().Be("job");
    }

    // ---------- parallel environment builds (AB#8814) ----------

    [Fact]
    public async Task A_parallel_environment_build_shows_every_repo_that_builds_and_counts_by_start_order()
    {
        _fake.Capabilities = FakePwsh.ParallelParams;
        var folder = Env("ab1-ok", ["octo-a", "octo-b", "octo-c", "octo-d"]);
        _fake.EnvPlan = $$"""
                          {"dryRun":true,"parallel":true,"maxParallel":3,"repositories":[
                            {"repo":"octo-a","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(folder, "octo-a"))}},"action":"build","reason":"sourcesChanged","dependsOn":[]},
                            {"repo":"octo-b","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(folder, "octo-b"))}},"action":"build","reason":"sourcesChanged","dependsOn":[]},
                            {"repo":"octo-c","mode":"dotnet","path":{{JsonSerializer.Serialize(Path.Combine(folder, "octo-c"))}},"action":"build","reason":"upstreamBuilt","dependsOn":["octo-a","octo-b"]},
                            {"repo":"octo-d","mode":"script","path":{{JsonSerializer.Serialize(Path.Combine(folder, "octo-d"))}},"action":"skip","reason":"unchanged","dependsOn":["octo-c"],"exclusive":true}]}
                          """;
        var first = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void E(string events, string name, string fields) => FakePwsh.Event(events, "Invoke-BuildEnvironment", name, fields);
        _fake.Build = async (body, _, _) =>
        {
            var events = FakePwsh.EventsFile(body)!;
            E(events, "plan", "\"repos\":[{\"repo\":\"octo-a\",\"mode\":\"dotnet\",\"dependsOn\":[]},{\"repo\":\"octo-b\",\"mode\":\"dotnet\",\"dependsOn\":[]},{\"repo\":\"octo-c\",\"mode\":\"dotnet\",\"dependsOn\":[\"octo-a\",\"octo-b\"]},{\"repo\":\"octo-d\",\"mode\":\"script\"}],\"count\":4,\"parallel\":true,\"maxParallel\":3");
            // octo-b starts first, octo-a second: the index is the start order, not the plan order.
            E(events, "repoStart", "\"repo\":\"octo-b\",\"index\":1,\"count\":4");
            E(events, "repoStart", "\"repo\":\"octo-a\",\"index\":2,\"count\":4");
            E(events, "phase", "\"repo\":\"octo-a\",\"phase\":\"packages\"");
            await first.Task;
            E(events, "repoDone", "\"repo\":\"octo-a\",\"index\":2,\"count\":4,\"success\":true,\"status\":\"built\",\"seconds\":6,\"buildSeconds\":5,\"testSeconds\":0,\"packageSeconds\":1,\"copied\":1,\"purged\":1,\"logFile\":null");
            E(events, "repoDone", "\"repo\":\"octo-b\",\"index\":1,\"count\":4,\"success\":false,\"status\":\"failed\",\"seconds\":8,\"buildSeconds\":8,\"testSeconds\":0,\"packageSeconds\":0,\"copied\":0,\"purged\":0,\"logFile\":null");
            E(events, "repoSkipped", "\"repo\":\"octo-d\",\"index\":3,\"count\":4,\"reason\":\"unchanged\",\"detail\":null");
            await second.Task;
            E(events, "done", "\"success\":false,\"failedRepo\":\"octo-b\",\"failedStep\":\"build\",\"elapsedSeconds\":9");
            return FakePwsh.Ok("Invoke-BuildEnvironment",
                """{"success":false,"exitCode":1,"parallel":true,"maxParallel":3,"failedRepo":"octo-b","failedRepos":["octo-b","octo-c"],"failedStep":"build","repositories":[{"repo":"octo-a","success":true,"status":"built","buildSeconds":5,"testCompileSeconds":0,"packageSeconds":1,"copiedCount":1,"purged":["x"]},{"repo":"octo-b","success":false,"status":"failed","buildSeconds":8},{"repo":"octo-c","success":false,"status":"failed","buildSeconds":1},{"repo":"octo-d","success":true,"status":"skipped","reason":"unchanged"}],"notBuilt":[]}""",
                exitCode: 1);
        };
        var (queue, _, _) = CreateQueue();
        var request = new BuildRequest { Owner = "agent-1", Kind = BuildKind.Env, Environment = "ab1-ok", MaxParallel = 3 };

        var plan = await queue.Plan(request);
        plan.Steps.Single().Command.Should().StartWith("Invoke-BuildEnvironment -env 'ab1-ok' -maxParallel 3 -Json");
        plan.Steps.Single().Repos.Single(r => r.Repo == "octo-c").DependsOn.Should().Equal("octo-a", "octo-b");
        plan.Steps.Single().Repos.Single(r => r.Repo == "octo-d").Exclusive.Should().BeTrue();
        plan.Steps.Single().Repos.Single(r => r.Repo == "octo-a").DependsOn.Should().BeNull("an empty list is left out");
        plan.Warnings.Should().Contain(w => w.Contains("Up to 3 independent repos"));

        var job = await queue.Enqueue(request);
        var running = await WaitAsync(queue, job.Id, s => s.Progress?.Running?.Count == 2);

        running.Progress!.Running!.Select(r => (r.Repo, r.Phase)).Should().Equal(("octo-b", "build"), ("octo-a", "packages"));
        running.Progress.Current!.Repo.Should().Be("octo-b", "the repo that started first");
        running.Progress.Should().BeEquivalentTo(new { RepoIndex = 2, RepoCount = 4, MaxParallel = 3 });
        running.Progress.Repos!.Select(r => (r.Repo, r.State)).Should().Equal(("octo-a", "building"), ("octo-b", "building"), ("octo-c", "pending"), ("octo-d", "pending"));

        first.SetResult();
        var later = await WaitAsync(queue, job.Id, s => s.Progress?.Repos?.Count(r => r.State == "skipped") == 1);
        later.Progress!.Should().BeEquivalentTo(new { RepoIndex = 3, RepoCount = 4 });
        later.Progress.Running.Should().BeNull("nothing builds right now");

        second.SetResult();
        var done = await WaitAsync(queue, job.Id);
        done.State.Should().Be("failed");
        done.Outcome!.FailedRepo.Should().Be("octo-b");
        done.Outcome.FailedRepos.Should().Equal("octo-b", "octo-c");
        done.Outcome.Summary.Should().Be("build failed in octo-b, octo-c (build)");
        done.Progress!.Repos!.Select(r => (r.Repo, r.State)).Should().Equal(("octo-a", "done"), ("octo-b", "failed"), ("octo-c", "failed"), ("octo-d", "skipped"));
        done.Progress.Totals.Should().Be(new BuildPhaseSeconds(14, 0, 1, "octo-b (8 s)"));
    }

    [Fact]
    public async Task MaxParallel_needs_an_octo_tools_with_it_and_a_sensible_value()
    {
        _fake.Capabilities = FakePwsh.NarrowParams;
        Env("ab1-ok", ["octo-a"]);
        var (queue, _, _) = CreateQueue();

        var old = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-ok", MaxParallel = 2 });
        (await old.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*no Invoke-BuildEnvironment -maxParallel*AB#8814*");
        var tooMany = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-ok", MaxParallel = 17 });
        await tooMany.Should().ThrowAsync<ArgumentException>().WithMessage("*between 1 and 16*");
        var range = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Range, From = "octo-a", MaxParallel = 2 });
        await range.Should().ThrowAsync<ArgumentException>().WithMessage("*apply to lane_build only*");
    }

    [Fact]
    public async Task Repos_and_skip_need_an_octo_tools_with_them_and_apply_to_environment_builds_only()
    {
        Env("ab1-ok", ["octo-a"]);
        var (queue, _, _) = CreateQueue(); // FakePwsh.EnvironmentParams: Invoke-BuildEnvironment without -repos / -skip

        var old = () => queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-ok", Skip = ["octo-a"] });
        (await old.Should().ThrowAsync<InvalidOperationException>()).WithMessage("*no Invoke-BuildEnvironment -repos / -skip / -buildUnchanged*AB#8814*");
        var unchanged = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-ok", BuildUnchanged = true });
        await unchanged.Should().ThrowAsync<InvalidOperationException>().WithMessage("*AB#8814*");
        var repo = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Repo, Path = "octo-a", Repos = ["octo-a"] });
        await repo.Should().ThrowAsync<ArgumentException>().WithMessage("*apply to lane_build only*");

        // Without them an environment build works as before.
        _fake.Build = (_, _, _) => Task.FromResult(FakePwsh.Ok("Invoke-BuildEnvironment", """{"success":true,"exitCode":0,"repositories":[]}"""));
        (await WaitAsync(queue, (await queue.Enqueue(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-ok" })).Id)).State.Should().Be("succeeded");
    }

    [Fact]
    public async Task An_app_in_an_environment_needs_the_repos_its_build_uses_as_siblings()
    {
        _checkout.Repo("octo-a");
        _checkout.Repo("octo-b");
        var store = _checkout.WriteConfig(Services + """

                                                       app:
                                                         repo: my-app
                                                         workingDirectory: .
                                                         command: pwsh
                                                         args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                                         enabled: false
                                                         requiresRepos: [octo-frontend-libraries]
                                                     """);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        _fake.Capabilities = FakePwsh.NarrowParams;
        var queue = new BuildQueue(store, supervisor, supervisor.Leases.Default, new DevStackPaths(_checkout.StateDirectory), NullLogger<BuildQueue>.Instance, _fake,
            state, null, new BuildQueueOptions { PollInterval = TimeSpan.FromMilliseconds(50) }, () => Task.FromResult(ExternalSnapshot.Empty));
        Env("ab1-app", ["my-app", "octo-a"]);
        Env("ab2-both", ["my-app", "octo-frontend-libraries"]);

        var alone = () => queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-app" });
        (await alone.Should().ThrowAsync<InvalidOperationException>())
            .WithMessage("*holds my-app without octo-frontend-libraries*lane_add_repo(lane=\"ab1-app\", repo=\"octo-frontend-libraries\", role=\"consumer\")*skip=[\"my-app\"]*");

        (await queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab1-app", Skip = ["my-app"] })).Steps.Should().ContainSingle();
        (await queue.Plan(new BuildRequest { Owner = "a", Kind = BuildKind.Env, Environment = "ab2-both" })).Steps.Should().ContainSingle();
    }

    private static void InterlockedMax(ref int target, int value)
    {
        int current;
        do
        {
            current = target;
            if (value <= current)
            {
                return;
            }
        } while (Interlocked.CompareExchange(ref target, value, current) != current);
    }
}
