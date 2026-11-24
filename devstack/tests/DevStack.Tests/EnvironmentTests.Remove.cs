using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     lane_remove leaves nothing behind (WP-D): the process check before anything changes (Get-OctoProcessesUnderFolder faked
///     through <see cref="FakePwsh.FolderProcesses"/>), and the data drop after the folder is gone (<see cref="FakeSlotData"/>).
/// </summary>
public sealed partial class EnvironmentTests
{
    private static string Row(string folder, int pid, string name, string reason) =>
        $$"""{"folder":{{JsonSerializer.Serialize(folder)}},"pid":{{pid}},"name":"{{name}}","reason":"{{reason}}"}""";

    /// <summary>
    ///     Remove-OctoEnvironment as octo-tools does it: the worktrees go (git worktree remove for real ones, keeping their
    ///     branches), what the lane owns goes, a file it does not own keeps the folder and is named in leftOver.
    /// </summary>
    private void RemoveLikeOctoTools(string folder)
    {
        _fake.Build = (body, _, _) =>
        {
            var leftOver = new List<string>();
            if (body.StartsWith("Remove-OctoEnvironment", StringComparison.Ordinal))
            {
                foreach (var dir in Directory.GetDirectories(folder).Where(d => Path.GetFileName(d) != ".octo"))
                {
                    if (File.Exists(Path.Combine(dir, ".git")))
                    {
                        // From the repository that owns it, as the cmdlet does (a process cannot remove its own working directory on Windows).
                        var main = Path.GetDirectoryName(Path.GetFullPath(Path.Combine(dir, _checkout.Git(dir, "rev-parse", "--git-common-dir"))))!;
                        _checkout.Git(main, "worktree", "remove", "--force", dir);
                    }
                    else
                    {
                        Directory.Delete(dir, recursive: true);
                    }
                }

                File.Delete(Path.Combine(folder, "Octo.User.props"));
                File.Delete(EnvironmentDiscovery.ManifestPath(folder));
                leftOver = Directory.Exists(folder) ? Directory.GetFileSystemEntries(folder).Select(Path.GetFileName).OfType<string>().ToList() : [];
            }

            return Task.FromResult(FakePwsh.Ok(FakePwsh.Command(body),
                JsonSerializer.Serialize(new { success = true, removed = true, path = folder, leftOver }, JsonSerializerOptions.Web)));
        };
    }

    [Fact]
    public async Task Lane_remove_deletes_a_feature_branch_without_commits_and_keeps_one_with_commits_with_the_command()
    {
        var (queue, supervisor, store) = CreateQueue();
        var a = _checkout.GitRepo("octo-a");
        var b = _checkout.GitRepo("octo-b");
        var baseCommits = new Dictionary<string, string> { ["octo-a"] = _checkout.Git(a, "rev-parse", "HEAD"), ["octo-b"] = _checkout.Git(b, "rev-parse", "HEAD") };
        var folder = Path.Combine(_checkout.Root, "wt-ab1-one");
        foreach (var (repo, path) in new[] { ("octo-a", a), ("octo-b", b) })
        {
            _checkout.Git(path, "worktree", "add", "-q", "--no-track", "-b", "reimar/AB#1234_x", Path.Combine(folder, repo), baseCommits[repo]);
        }

        File.WriteAllText(Path.Combine(folder, "octo-b", "work.txt"), "the lane's work");
        _checkout.Git(Path.Combine(folder, "octo-b"), "add", "work.txt");
        _checkout.Git(Path.Combine(folder, "octo-b"), "commit", "-q", "-m", "work");
        Env("ab1-one", ["octo-a", "octo-b"], features: ["octo-a", "octo-b"], baseCommits: baseCommits);
        RemoveLikeOctoTools(folder);

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);

        result.Success.Should().BeTrue();
        var empty = result.Branches!.Single(x => x.Repo == "octo-a");
        // git names the repository by its real path (macOS: /var is a link to /private/var, and the temp folder lies below it).
        var owner = _checkout.Git(a, "rev-parse", "--show-toplevel");
        empty.Should().Match<LaneBranch>(x => x.Deleted && x.Branch == "reimar/AB#1234_x" && PathScope.SamePath(x.RepoPath, owner) && x.Delete == null);
        empty.Reason.Should().StartWith("it held no commit beyond its base commit");
        _checkout.Git(a, "branch", "--list", "reimar/*").Should().BeEmpty("a branch that holds nothing is deleted in the repository that owns it");
        var work = result.Branches!.Single(x => x.Repo == "octo-b");
        work.Deleted.Should().BeFalse();
        work.Reason.Should().StartWith("it holds 1 commit(s) beyond its base commit").And.Contain("once they are merged");
        work.Delete.Should().Be($"git -C '{work.RepoPath}' branch -D 'reimar/AB#1234_x'", "in single quotes a shell expands nothing");
        _checkout.Git(b, "branch", "--list", "reimar/*").Should().Contain("reimar/AB#1234_x", "a branch with commits stays");
        _checkout.Git(a, "branch", "--show-current").Should().Be("main", "the base branch stays");
        result.Notes.Should().Contain(n => n.StartsWith("Deleted the feature branch(es) without commits of their own: reimar/AB#1234_x in ") &&
                                          n.Contains("Kept the feature branch(es) reimar/AB#1234_x in "));
        _ = supervisor;
    }

    [Fact]
    public async Task Lane_remove_with_keepBranches_keeps_every_branch_and_never_touches_the_base_branch_or_one_checked_out_elsewhere()
    {
        var (queue, supervisor, store) = CreateQueue();
        var a = _checkout.GitRepo("octo-a");
        var head = _checkout.Git(a, "rev-parse", "HEAD");
        var folder = Path.Combine(_checkout.Root, "wt-ab1-one");
        _checkout.Git(a, "worktree", "add", "-q", "--no-track", "-b", "reimar/AB#1234_x", Path.Combine(folder, "octo-a"), head);
        Env("ab1-one", ["octo-a"], baseCommits: new Dictionary<string, string> { ["octo-a"] = head });
        RemoveLikeOctoTools(folder);

        var kept = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct, keepBranches: true);

        kept.Branches!.Single().Should().Match<LaneBranch>(x => !x.Deleted && x.Reason.Contains("keepBranches=true") && x.Delete != null);
        _checkout.Git(a, "branch", "--list", "reimar/*").Should().Contain("reimar/AB#1234_x");

        // The same branch checked out in another worktree (another session works on it): never deleted.
        var other = Path.Combine(_checkout.Root, "elsewhere");
        _checkout.Git(a, "worktree", "add", "-q", other, "reimar/AB#1234_x");
        var targets = new List<LaneBranches.Target> { new("octo-a", "reimar/AB#1234_x", head, "origin/main", a), new("octo-a", "main", head, "origin/main", a) };
        var cleaned = await LaneBranches.CleanAsync(targets, keepAll: false);
        cleaned[0].Should().Match<LaneBranch>(x => !x.Deleted && x.Reason.StartsWith("it is checked out in ") && x.Delete == null);
        cleaned[1].Should().Match<LaneBranch>(x => !x.Deleted && x.Reason.StartsWith("it is the base branch"));
        _checkout.Git(a, "branch", "--list").Should().Contain("main").And.Contain("reimar/AB#1234_x");

        // A branch whose ref is gone already is not reported.
        _checkout.Git(a, "worktree", "remove", "--force", other);
        _checkout.Git(a, "branch", "-D", "reimar/AB#1234_x");
        (await LaneBranches.CleanAsync([targets[0]], keepAll: false)).Should().BeEmpty();
        _ = supervisor;
    }

    [Fact]
    public async Task Lane_remove_drops_the_lane_stack_data_and_frees_the_slot_index()
    {
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        var slot = supervisor.Slot("ab1-one", create: true).Slot; // reserved as lane_create does: index 1, prefix s1
        var slotDir = SlotDeriver.SlotDirectory(supervisor.StateDirectory, slot);
        Directory.CreateDirectory(Path.Combine(slotDir, "bot", "scratch"));
        File.WriteAllText(Path.Combine(slotDir, "stack-setup.json"), "{}");
        File.WriteAllText(Path.Combine(folder, ".octo", SlotOperations.CredentialsFileName), "{}");
        File.WriteAllText(Path.Combine(folder, ".octo", SlotOperations.ClientSecretFileName), "x\n");
        Directory.CreateDirectory(Path.Combine(folder, ".octo", "claims"));
        RemoveLikeOctoTools(folder);
        _data.Mongo.Databases.AddRange(["octosystem", "octosystem_s1", "s1_meshtest", "s1-OctoSystemJobs", "meshtest", "s10_meshtest"]);
        _data.Mongo.Tenants["octosystem_s1"] = [new InventoryTenant("meshtest", "s1_meshtest", true, "octosystem_s1")];
        _data.Mongo.Owners["s1_meshtest"] = "octosystem_s1";
        _data.Rabbit.Queues.AddRange([new BrokerObject("/", "s1-bot-jobs"), new BrokerObject("/", "default-bot-jobs"), new BrokerObject("/", "s10-bot-jobs")]);
        _data.Rabbit.Exchanges.Add(new BrokerObject("/", "s1-bot-jobs"));
        _data.Crate.Relations.AddRange([new CrateRelation("s1_meshtest", "streamdata", false), new CrateRelation("meshtest", "streamdata", false)]);
        _data.OctoCli.ContextNames = ["local_octosystem", "local-ab1-one_octosystem"];
        _data.OctoCli.Installations.AddRange(["local", "local-ab1-one"]);

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);

        result.Success.Should().BeTrue();
        var drop = result.DataDrop!;
        drop.Steps.Select(s => (s.Store, s.Status)).Should().Equal(("mongodb", "dropped"), ("rabbitmq", "dropped"), ("cratedb", "dropped"), ("octoCli", "dropped"),
            ("files", "dropped"), ("s3", "unchecked"));
        drop.Complete.Should().BeTrue();
        drop.IndexFreed.Should().BeTrue();
        _data.Mongo.Dropped.Should().Equal(["s1_meshtest", "s1-OctoSystemJobs", "octosystem_s1"], "the system database goes last: it registers the tenants");
        _data.Mongo.Databases.Should().Equal("octosystem", "meshtest", "s10_meshtest");
        _data.Rabbit.Deleted.Should().Equal("queue s1-bot-jobs", "exchange s1-bot-jobs");
        _data.Crate.Dropped.Should().Equal("s1_meshtest.streamdata");
        _data.OctoCli.Removed.Should().Equal("installation local-ab1-one", "context local-ab1-one_octosystem");
        _data.OctoCli.Installations.Should().Equal("local");
        Directory.Exists(slotDir).Should().BeFalse("the slot's state folder is dropped");
        Directory.Exists(folder).Should().BeFalse("the secret files were all that kept the lane folder");
        result.Data!["leftOver"]!.AsArray().Should().BeEmpty("the cmdlet's [\".octo\"] is gone: the files step removed it");
        var s3 = result.Leftovers!.Should().ContainSingle().Which;
        s3.Name.Should().Be("local-s1", "S3 artifacts are only listed");
        s3.Kind.Should().Contain("below the prefix local-s1/").And.Contain("not checked").And.Contain("kubectl").And.Contain("blocks nothing");
        drop.Steps.Single(s => s.Store == "s3").Summary.Should().StartWith("Not checked: the daemon did not look whether the local S3 store holds artifacts below the prefix local-s1/")
            .And.Contain("this blocks nothing");
        result.Branches.Should().BeNull("the lane's folders are no git worktrees");
        supervisor.RetiredSlots().Should().BeEmpty("every step succeeded");
        result.Notes.Should().Contain(n => n.Contains("Index 1 is free again"));
        result.Notes.Should().Contain(n => n.Contains("Not checked which processes") && n.Contains("has no Get-OctoProcessesUnderFolder -path"),
            "this octo-tools has no process scan");
        supervisor.Slot("ab2-two", create: true).Slot.Index.Should().Be(1, "a freed index is handed out again");
    }

    [Fact]
    public async Task Lane_remove_with_a_failed_step_keeps_the_index_retired_and_admin_slot_drop_data_finishes_it()
    {
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        supervisor.Slot("ab1-one", create: true);
        RemoveLikeOctoTools(folder);
        _data.Mongo.Databases.AddRange(["octosystem_s1", "isotest"]);
        // A tenant created before AB#8797 (no prefix) but owned by the slot: only the system database names it.
        _data.Mongo.Tenants["octosystem_s1"] = [new InventoryTenant("isotest", "isotest", true, "octosystem_s1")];
        _data.Mongo.Owners["isotest"] = "octosystem_s1";
        _data.Mongo.FailDrop.Add("isotest");
        _data.Rabbit.Unreachable = true;

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);

        result.Success.Should().BeTrue("the lane is gone; only its data is not");
        result.DataDrop!.Complete.Should().BeFalse();
        result.DataDrop.Steps.Single(s => s.Store == "mongodb").Status.Should().Be("failed");
        result.DataDrop.Steps.Single(s => s.Store == "rabbitmq").Summary.Should().Contain("did not answer");
        result.Leftovers!.Should().Contain(l => l.Name == "isotest" && l.Drop!.Contains("getSiblingDB('isotest')"))
            .And.Contain(l => l.Name == "s1" && l.Drop!.Contains("rabbitmqctl delete_queue"));
        result.Notes.Should().Contain(n => n.Contains("Index 1 stays retired") && n.Contains("admin_slot_drop_data(owner, index=1)"));
        supervisor.RetiredSlots()[1].TenantDatabases.Should().Equal(["isotest"], "recorded with the retired index as well");
        _data.Mongo.Databases.Should().Equal(["octosystem_s1", "isotest"], "the system database stays while a tenant it registers could not be dropped");

        _data.Mongo.FailDrop.Clear();
        _data.Rabbit.Unreachable = false;
        _data.Rabbit.Queues.Add(new BrokerObject("/", "s1-bot-jobs"));
        var tools = new SlotTools(supervisor, store, new SlotDataCleanup(store, supervisor, _data.Stores));
        var again = await tools.DropData("agent-3", 1, "meshmakers-07", Ct);

        again.Complete.Should().BeTrue();
        again.IndexFreed.Should().BeTrue();
        _data.Mongo.Dropped.Should().Equal("isotest", "octosystem_s1");
        _data.Rabbit.Deleted.Should().Equal("queue s1-bot-jobs");
        tools.Retired().Should().BeEmpty();
        var gone = () => tools.DropData("agent-3", 1, cancellationToken: Ct);
        await gone.Should().ThrowAsync<ModelContextProtocol.McpException>().WithMessage("*Index 1 is not retired*");
    }

    [Fact]
    public async Task Lane_remove_is_refused_while_a_process_the_daemon_did_not_start_holds_files_below_the_lane()
    {
        _fake.Capabilities = FakePwsh.ProcessParams;
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        var started = await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var own = started.Status.Services.Single().Pid;
        var foreign = Environment.ProcessId; // the test host: no service of the daemon, e.g. an MSBuild node of a plain dotnet build
        _fake.FolderProcesses = _ => $"[{Row(folder, own, "pwsh", "commandLine")},{Row(folder, foreign, "dotnet", "module")}]";
        RemoveLikeOctoTools(folder);

        var remove = () => Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);

        var refused = (await remove.Should().ThrowAsync<InvalidOperationException>()).Which.Message;
        refused.Should().Contain($"pid {foreign} dotnet, started ").And.Contain("(module)").And.Contain("dotnet build-server shutdown")
            .And.Contain("nothing was changed").And.Contain("lane_remove again").And.NotContain($"pid {own} ");
        ProcessTree.IsAlive(own).Should().BeTrue("a refusal changes nothing: the lane stack still runs");
        supervisor.Leases.Get("ab1-one").Current()!.Owner.Should().Be("lane:ab1-one");
        _fake.BuildCalls.Should().NotContain(c => c.StartsWith("Remove-OctoEnvironment", StringComparison.Ordinal));
        _fake.Calls.Select(c => FakePwsh.Strip(c.Body)).Should().ContainSingle(b => b.Contains("Get-OctoProcessesUnderFolder -path"))
            .Which.Should().Contain(PwshRunner.Quote(folder)).And.Contain("$PID");
        _data.Mongo.Dropped.Should().BeEmpty();
        await tools.Stop("agent-1", lane: "ab1-one", cancellationToken: Ct);
    }

    [Fact]
    public async Task Lane_remove_stops_the_lane_stack_checks_again_and_only_reports_processes_of_in_place_worktrees()
    {
        _fake.Capabilities = FakePwsh.ProcessParams;
        var (queue, supervisor, store) = CreateQueue();
        var inPlace = Path.Combine(_checkout.Root, "octo-b", ".claude", "worktrees", "x");
        var folder = Env("ab1-one", ["octo-a", "octo-b"], adopted: new Dictionary<string, string> { ["octo-b"] = inPlace });
        var tools = new StackTools(supervisor, store);
        var started = await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var own = started.Status.Services.Single().Pid;
        var foreign = Environment.ProcessId;
        var scans = new List<string>();
        _fake.FolderProcesses = body =>
        {
            scans.Add(body);
            var rows = new List<string> { Row(inPlace, foreign, "Rider.Backend", "module") };
            if (ProcessTree.IsAlive(own))
            {
                rows.Add(Row(folder, own, "pwsh", "cwd"));
            }

            return "[" + string.Join(",", rows) + "]";
        };
        RemoveLikeOctoTools(folder);

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);

        result.Success.Should().BeTrue();
        scans.Should().HaveCount(2, "once before anything changes, once after the lane stack stopped");
        scans[0].Should().Contain(PwshRunner.Quote(folder)).And.Contain(PwshRunner.Quote(inPlace));
        ProcessTree.IsAlive(own).Should().BeFalse("the lane stack's own service is stopped");
        result.Notes.Should().Contain(n => n.StartsWith("stopped the lane stack 'ab1-one'"));
        result.Notes.Should().Contain(n => n.Contains("in-place worktrees") && n.Contains($"pid {foreign} Rider.Backend") && n.Contains("keep running"));
        result.DataDrop!.Complete.Should().BeTrue();
    }

    [Fact]
    public async Task Lane_remove_is_refused_while_another_stack_runs_the_lanes_build_or_a_process_outlives_the_lane_stack()
    {
        _fake.Capabilities = FakePwsh.ProcessParams;
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        var tools = new StackTools(supervisor, store);
        var shared = await tools.Start("agent-1", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var sharedPid = shared.Status.Services.Single().Pid;
        _fake.FolderProcesses = _ => $"[{Row(folder, sharedPid, "dotnet", "module")}]";
        RemoveLikeOctoTools(folder);
        var manager = Manager(queue, supervisor, store);

        var other = () => manager.RemoveAsync("agent-2", "ab1-one", false, Ct);
        (await other.Should().ThrowAsync<InvalidOperationException>()).Which.Message.Should()
            .Contain("service alpha of the shared stack").And.Contain("started by agent-1").And.Contain("service_stop");
        ProcessTree.IsAlive(sharedPid).Should().BeTrue("lane_remove never stops another stack's service");
        await tools.Stop("agent-1", cancellationToken: Ct);

        // A process that is still there after the lane stack stopped (a child that outlived its service) refuses too.
        var started = await tools.Start("agent-1", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        var own = started.Status.Services.Single().Pid;
        var calls = 0;
        _fake.FolderProcesses = _ => ++calls == 1 ? $"[{Row(folder, own, "pwsh", "cwd")}]" : $"[{Row(folder, Environment.ProcessId, "node", "cwd")}]";
        var outlived = () => manager.RemoveAsync("agent-2", "ab1-one", false, Ct);
        (await outlived.Should().ThrowAsync<InvalidOperationException>()).Which.Message.Should()
            .Contain("the lane stack is stopped now").And.Contain($"pid {Environment.ProcessId} node").And.Contain("close the shells, IDEs or sessions");
        ProcessTree.IsAlive(own).Should().BeFalse();
        _fake.BuildCalls.Should().NotContain(c => c.StartsWith("Remove-OctoEnvironment", StringComparison.Ordinal));
        Directory.Exists(folder).Should().BeTrue();
    }

    [Fact]
    public async Task While_a_lane_is_removed_other_sessions_start_nothing_on_it_and_after_a_failed_removal_it_is_usable_again()
    {
        var (queue, supervisor, store) = CreateQueue();
        Env("ab1-one", ["octo-a"]);
        var entered = new TaskCompletionSource();
        var release = new TaskCompletionSource();
        _fake.Build = async (body, _, _) =>
        {
            if (body.StartsWith("Remove-OctoEnvironment", StringComparison.Ordinal))
            {
                entered.TrySetResult();
                await release.Task;
                return new PwshResult(1, "Remove-OctoEnvironment: worktree octo-a has unpushed commits\n", false, false); // the cmdlet refuses
            }

            return FakePwsh.Ok(FakePwsh.Command(body), """{"success":true,"exitCode":0,"repositories":[]}""");
        };
        var manager = Manager(queue, supervisor, store);
        var tools = new StackTools(supervisor, store);

        // Session A removes the lane; the cmdlet is still working.
        Task<EnvironmentCommandResult> removal;
        using (LeaseSession.Use("meshmakers-01", "agent-a"))
        {
            removal = manager.RemoveAsync("agent-a", "ab1-one", false, Ct);
        }

        await entered.Task.WaitAsync(TimeSpan.FromSeconds(10), Ct);
        (await manager.ListAsync()).Single(l => l.Name == "ab1-one").Removing.Should().Match<LaneRemoval>(r => r.Owner == "agent-a" && r.Session == "meshmakers-01");

        // Session B: a stack start, a build and a test run of the lane are refused, naming who removes it.
        var start = () => tools.Start("agent-b", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-02", cancellationToken: Ct);
        await start.Should().ThrowAsync<ModelContextProtocol.McpException>().WithMessage("*Lane 'ab1-one' is being removed by 'agent-a' (session meshmakers-01)*");
        var build = () => queue.Enqueue(new BuildRequest { Owner = "agent-b", Kind = BuildKind.Env, Environment = "ab1-one" });
        await build.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*");
        var test = () => queue.Enqueue(new BuildRequest { Owner = "agent-b", Kind = BuildKind.Test, Repo = "octo-a", Environment = "ab1-one" });
        await test.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*");
        var second = () => manager.RemoveAsync("agent-b", "ab1-one", false, Ct);
        await second.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*");
        // Also the calls that name the lane another way, or change it without a job.
        var byFolder = () => queue.Enqueue(new BuildRequest { Owner = "agent-b", Kind = BuildKind.Repo, Path = "octo-a", Checkout = "wt-ab1-one" });
        await byFolder.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*", "checkout=<lane folder> is the lane too");
        var bySlot = () => tools.Start("agent-b", slot: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, cancellationToken: Ct);
        await bySlot.Should().ThrowAsync<ModelContextProtocol.McpException>().WithMessage("*is being removed*", "the lane's slot without lane=");
        var sync = () => manager.SyncAsync("agent-b", "ab1-one", Ct);
        await sync.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*");
        var seed = () => manager.SeedCacheAsync("agent-b", "ab1-one", false, Ct);
        await seed.Should().ThrowAsync<InvalidOperationException>().WithMessage("*is being removed*");

        // The cmdlet fails: the mark goes, the lane is usable again.
        release.SetResult();
        (await removal).Success.Should().BeFalse();
        (await manager.ListAsync()).Single(l => l.Name == "ab1-one").Removing.Should().BeNull();
        var again = await queue.Enqueue(new BuildRequest { Owner = "agent-b", Kind = BuildKind.Env, Environment = "ab1-one" });
        (await WaitAsync(queue, again.Id)).State.Should().Be("succeeded");
        var started = await tools.Start("agent-b", lane: "ab1-one", services: ["alpha"], waitForHealthy: false, timeoutSeconds: 1, session: "meshmakers-02", cancellationToken: Ct);
        started.Status.Services.Should().ContainSingle(s => s.Name == "alpha");
        await supervisor.StopServicesAsync("lane:ab1-one", null, Ct, "ab1-one");
    }

    [Fact]
    public void A_removal_mark_refuses_a_second_removal_and_ends_once()
    {
        var removals = new LaneRemovals();
        var mark = removals.Begin("ab1-one", "agent-a", null);
        var again = () => removals.Begin("AB1-ONE", "agent-b", "meshmakers-02");
        again.Should().Throw<InvalidOperationException>().WithMessage("*being removed by 'agent-a'*");
        mark.Dispose();
        removals.Of("ab1-one").Should().BeNull();
        using var next = removals.Begin("ab1-one", "agent-b", null);
        mark.Dispose(); // an old mark ending twice never ends a newer one
        removals.Of("ab1-one")!.Owner.Should().Be("agent-b");

        // The slot is part of the mark: a slot-only call is refused also when the lane's manifest is gone already.
        using var withSlot = removals.Begin("ab2-two", "agent-c", null, slot: "ab2-slot");
        var bySlot = () => removals.RefuseSlot("ab2-slot");
        bySlot.Should().Throw<InvalidOperationException>().WithMessage("*Lane 'ab2-two' is being removed*");
        removals.RefuseSlot("other-slot");
    }

    [Fact]
    public async Task A_start_with_a_lane_source_of_a_lane_that_is_being_removed_is_refused_before_anything_stops()
    {
        var (supervisor, _, _) = CreateSupervisor();
        Env("ab1-one", ["octo-a"]);
        using var removing = supervisor.Removals.Begin("ab1-one", "agent-a", "meshmakers-01", "ab1-one");

        // The same overrides a saved profile supplies (profile instances and settings resolve to them).
        var start = () => supervisor.StartStackAsync("agent-b", new StartSpec
        {
            Services = ["alpha"], Overrides = new Dictionary<string, ServiceOverride> { ["alpha"] = new() { Source = "lane:ab1-one" } }
        }, null, false, false, TimeSpan.FromSeconds(1), Ct);

        await start.Should().ThrowAsync<InvalidOperationException>().WithMessage("*Lane 'ab1-one' is being removed by 'agent-a'*");
        (await supervisor.StatusAsync()).Services.Should().BeEmpty("nothing started");
    }

    [Fact]
    public async Task Lane_remove_with_keepData_deletes_the_lanes_secret_files_and_its_empty_folder()
    {
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        supervisor.Slot("ab1-one", create: true);
        Directory.CreateDirectory(Path.Combine(folder, ".octo"));
        var secret = Path.Combine(folder, ".octo", SlotOperations.ClientSecretFileName);
        var credentials = Path.Combine(folder, ".octo", SlotOperations.CredentialsFileName);
        File.WriteAllText(secret, "x\n");
        File.WriteAllText(credentials, "{}");
        RemoveLikeOctoTools(folder);

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", keepData: true, Ct);

        result.Success.Should().BeTrue();
        File.Exists(secret).Should().BeFalse("AB#9384: the secrets never stay with the kept data");
        File.Exists(credentials).Should().BeFalse();
        Directory.Exists(folder).Should().BeFalse("nothing else was left in it");
        result.Notes.Should().Contain(n => n.StartsWith("Lane secret files: removed secret file", StringComparison.Ordinal));
        supervisor.RetiredSlots().Should().ContainKey(1, "the data is kept");
    }

    [Fact]
    public async Task A_data_drop_that_throws_after_the_removal_is_a_note_and_the_index_stays_retired()
    {
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        supervisor.Slot("ab1-one", create: true);
        RemoveLikeOctoTools(folder);
        _data.Mongo.Unexpected = new NotSupportedException("the driver does not support this server");

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);

        result.Success.Should().BeTrue("the lane is gone; the answer must say so");
        result.DataDrop.Should().BeNull();
        result.Notes.Should().Contain(n => n.Contains("dropping the data of its stack") && n.Contains("failed") && n.Contains("does not support") && n.Contains("admin_slot_drop_data(owner, index=1)"));
        result.Leftovers.Should().Contain(l => l.Name == "octosystem_s1");
        supervisor.RetiredSlots().Should().ContainKey(1);
    }

    [Fact]
    public async Task A_process_check_that_fails_is_a_note_and_the_removal_goes_on()
    {
        _fake.Capabilities = FakePwsh.ProcessParams;
        var (queue, supervisor, store) = CreateQueue();
        var folder = Env("ab1-one", ["octo-a"]);
        _fake.FolderProcesses = _ => "{not json";
        RemoveLikeOctoTools(folder);

        var result = await Manager(queue, supervisor, store).RemoveAsync("agent-2", "ab1-one", false, Ct);

        result.Success.Should().BeTrue();
        result.Notes.Should().Contain(n => n.StartsWith("Could not check which processes hold files below the lane") && n.Contains("Access denied"));
    }
}
