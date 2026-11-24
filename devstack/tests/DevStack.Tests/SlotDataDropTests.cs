using System.Text.Json;
using System.Text.Json.Nodes;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The data drop of a removed lane stack against fake stores (<see cref="FakeSlotData"/>): what is dropped, what another
///     stack keeps, what follows a name that is in use again; the local octo-cli store on temp files; the process check's
///     sorting. No database, broker, ~/.octo-cli or installations.json is touched.
/// </summary>
public sealed class SlotDataDropTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly FakeSlotData _data = new();

    public void Dispose() => _checkout.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private (StackSupervisor Supervisor, SlotDataCleanup Cleanup, ConfigStore Store) Create()
    {
        var store = _checkout.WriteConfig("""
                                            alpha:
                                              repo: octo-a
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                          """);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        return (supervisor, new SlotDataCleanup(store, supervisor, _data.Stores), store);
    }

    [Fact]
    public async Task What_another_stack_registers_or_owns_is_kept_and_other_prefixes_are_never_touched()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.Slot("other", create: true).Slot.Prefix.Should().Be("s2");
        supervisor.ForgetSlot("ab1-one"); // lane_remove(keepData=true) before: index 1 retired
        var mongo = _data.Mongo;
        mongo.Databases.AddRange(["octosystem", "octosystem_s1", "octosystem_s2", "s1_meshtest", "s1_orphan", "s1_shared", "s1_foreign", "meshtest", "s10_meshtest",
            "s1-OctoSystemJobs", "s10-OctoSystemJobs"]);
        mongo.Tenants["octosystem_s1"] = [new InventoryTenant("meshtest", "s1_meshtest", true, "octosystem_s1"), new InventoryTenant("legacy", "meshtest", true, null)];
        mongo.Tenants["octosystem_s2"] = [new InventoryTenant("shared", "s1_shared", true, null)];
        mongo.Owners["s1_meshtest"] = "octosystem_s1";
        mongo.Owners["s1_foreign"] = "octosystem_s2";
        _data.Rabbit.Queues.AddRange([new BrokerObject("/", "s1-a"), new BrokerObject("/", "s10-a"), new BrokerObject("/", "default-a"), new BrokerObject("/", "s1-b")]);
        _data.Rabbit.Exchanges.AddRange([new BrokerObject("/", "s1-a"), new BrokerObject("/", "MassTransit:Fault"), new BrokerObject("/", "s10-a")]);
        _data.Crate.Relations.AddRange([new CrateRelation("s1_meshtest", "t", false), new CrateRelation("s1_meshtest", "v", true), new CrateRelation("s10_x", "t", false),
            new CrateRelation("doc", "t", false)]);
        _data.OctoCli.ContextNames = ["local-ab1-one_octosystem", "local-ab1-one_meshtest", "local-ab1-one-x_octosystem", "local_octosystem"];
        _data.OctoCli.Installations.AddRange(["local-ab1-one", "local-ab1-one-x"]);

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        drop.Complete.Should().BeTrue("kept databases are not the slot's own names: they do not hold the index back");
        drop.IndexFreed.Should().BeTrue();
        mongo.Dropped.Should().Equal("s1_meshtest", "s1_orphan", "s1-OctoSystemJobs", "octosystem_s1");
        mongo.Databases.Should().Equal("octosystem", "octosystem_s2", "s1_shared", "s1_foreign", "meshtest", "s10_meshtest", "s10-OctoSystemJobs");
        var kept = drop.Leftovers!.Where(l => l.Kind.StartsWith("Tenant database, kept", StringComparison.Ordinal)).ToDictionary(l => l.Name, l => l.Kind);
        kept.Should().HaveCount(3);
        kept["s1_shared"].Should().Contain("registered in another stack's system database");
        kept["s1_foreign"].Should().Contain("owned by octosystem_s2");
        kept["meshtest"].Should().Contain("no ownership marker");
        drop.Steps.Single(s => s.Store == "mongodb").Summary.Should().Contain("Dropped 4 database(s)").And.Contain("Kept 3");
        _data.Rabbit.Deleted.Should().Equal("queue s1-a", "queue s1-b", "exchange s1-a");
        _data.Crate.Dropped.Should().Equal(["s1_meshtest.v", "s1_meshtest.t"], "views first");
        _data.OctoCli.Removed.Should().Equal("installation local-ab1-one", "context local-ab1-one_meshtest", "context local-ab1-one_octosystem");
        _data.OctoCli.Installations.Should().Equal("local-ab1-one-x");
        supervisor.State.RetiredSlots().Should().BeEmpty();
        supervisor.Registry.Known().Should().Contain(k => k.Slot.Name == "other" && k.Slot.Index == 2);
    }

    [Fact]
    public async Task Names_that_follow_the_slot_name_are_left_alone_when_a_lane_of_that_name_exists_again()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        // A new lane of the same name: its stack gets index 2, the same state folder, installation and lane folder names.
        var folder = EnvironmentDiscovery.FolderOf(_checkout.Root, "ab1-one");
        Directory.CreateDirectory(Path.Combine(folder, ".octo"));
        File.WriteAllText(EnvironmentDiscovery.ManifestPath(folder),
            """{"schemaVersion":1,"name":"ab1-one","base":"branches/main","created":"2026-11-20T09:00:00+01:00","repos":[]}""");
        var secret = Path.Combine(folder, ".octo", SlotOperations.ClientSecretFileName);
        File.WriteAllText(secret, "x\n");
        var newSlot = supervisor.Slot("ab1-one", create: true).Slot;
        newSlot.Index.Should().Be(2);
        var stateFolder = SlotDeriver.SlotDirectory(supervisor.StateDirectory, newSlot);
        Directory.CreateDirectory(stateFolder);
        _data.Mongo.Databases.AddRange(["octosystem_s1", "octosystem_s2"]);
        _data.OctoCli.ContextNames = ["local-ab1-one_octosystem"];
        _data.OctoCli.Installations.Add("local-ab1-one");
        var listed = supervisor.RetiredSlots()[1].Leftovers!;
        listed.Should().NotContain(l => l.Drop != null && (l.Drop.Contains(stateFolder) || l.Drop.Contains("RemoveContext")),
            "admin_slot_retired offers no command for what the new lane of that name owns");
        listed.Should().Contain(l => l.Kind.Contains("exists again") && l.Drop == null);

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, "meshmakers-07", Ct);

        drop.Complete.Should().BeTrue();
        _data.Mongo.Dropped.Should().Equal(["octosystem_s1"], "the index's own names are dropped");
        drop.Steps.Single(s => s.Store == "octoCli").Status.Should().Be("kept");
        _data.OctoCli.Removed.Should().BeEmpty();
        Directory.Exists(stateFolder).Should().BeTrue();
        File.Exists(secret).Should().BeTrue();
        drop.Steps.Single(s => s.Store == "files").Summary.Should().Contain("is a lane (again)").And.Contain("exists again");
    }

    [Fact]
    public async Task An_unreachable_store_fails_its_step_with_the_commands_and_the_other_steps_still_run()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one", ["isotest"]);
        _data.Mongo.Unreachable = true;
        _data.Crate.Unreachable = true;
        _data.Rabbit.Queues.Add(new BrokerObject("/", "s1-a"));

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        drop.Complete.Should().BeFalse();
        drop.IndexFreed.Should().BeFalse();
        drop.Steps.Select(s => (s.Store, s.Status)).Should().Equal(("mongodb", "failed"), ("rabbitmq", "dropped"), ("cratedb", "failed"), ("octoCli", "nothing"),
            ("files", "nothing"), ("s3", "unchecked"));
        drop.Steps[0].Summary.Should().Contain("MongoDB did not answer");
        drop.Leftovers!.Should().Contain(l => l.Name == "octosystem_s1" && l.Drop!.Contains("-u octo-system-admin --authenticationDatabase admin -p --eval"))
            .And.Contain(l => l.Name == "s1-OctoSystemJobs").And.Contain(l => l.Name == "isotest")
            .And.Contain(l => l.Name == "s1" && l.Drop!.Contains("information_schema.tables"));
        drop.Summary().Should().Contain("Index 1 stays retired");
        supervisor.State.RetiredSlots()[1].TenantDatabases.Should().Equal("isotest");
    }

    [Fact]
    public async Task A_configuration_that_cannot_derive_the_slots_names_fails_the_stores_and_keeps_the_index_retired()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one", ["isotest"]);
        _data.Mongo.Databases.AddRange(["octosystem_s1", "s1_meshtest"]);
        cleanup.Derive = (_, _, _) => throw new InvalidOperationException("Unknown placeholder '{nope}'");

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        drop.Steps.Where(s => s.Store is "mongodb" or "rabbitmq" or "cratedb").Should().OnlyContain(s => s.Status == "failed" && s.Summary.Contains("could not be derived"))
            .And.HaveCount(3, "an empty derivation must not read as 'nothing to drop'");
        drop.Complete.Should().BeFalse();
        drop.IndexFreed.Should().BeFalse();
        _data.Mongo.Dropped.Should().BeEmpty();
        supervisor.State.RetiredSlots().Should().ContainKey(1);
        supervisor.State.RetiredSlots()[1].TenantDatabases.Should().Equal("isotest");
    }

    [Fact]
    public async Task A_failed_tenant_drop_keeps_the_system_database_that_registers_it_and_kept_databases_get_no_drop_command()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        var mongo = _data.Mongo;
        mongo.Databases.AddRange(["octosystem_s1", "isotest", "s1_foreign"]);
        mongo.Tenants["octosystem_s1"] = [new InventoryTenant("isotest", "isotest", true, "octosystem_s1"), new InventoryTenant("f", "s1_foreign", true, null)];
        mongo.Owners["isotest"] = "octosystem_s1";
        mongo.Owners["s1_foreign"] = "octosystem_s9";
        mongo.FailDrop.Add("isotest");

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        mongo.Dropped.Should().BeEmpty("the system database stays while a tenant it registers could not be dropped");
        mongo.Databases.Should().Contain("octosystem_s1");
        drop.Steps.Single(s => s.Store == "mongodb").Status.Should().Be("failed");
        drop.IndexFreed.Should().BeFalse();
        supervisor.State.RetiredSlots()[1].TenantDatabases.Should().Contain("isotest", "the next attempt still finds it");
        drop.Leftovers!.Single(l => l.Name == "s1_foreign").Drop.Should().BeNull("a database another stack owns gets no drop command");
        drop.Leftovers!.Single(l => l.Name == "isotest").Drop.Should().NotBeNull("a confirmed target whose drop failed keeps its command");

        mongo.FailDrop.Clear();
        var again = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);
        mongo.Dropped.Should().Equal("isotest", "octosystem_s1");
        again.IndexFreed.Should().BeTrue();
    }

    [Fact]
    public async Task A_tenant_prefix_without_a_separator_never_matches_unmarked_databases_of_other_indices()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        cleanup.Derive = (_, _, _) => [new SlotDerivedRow("systemDatabase", [], "OctoSystem_s1", null, true), new SlotDerivedRow("tenantDatabasePrefix", [], "s1", null, true)];
        _data.Mongo.Databases.AddRange(["octosystem_s1", "s1meshtest", "s10_x"]);

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        _data.Mongo.Dropped.Should().Equal(["octosystem_s1"], "without a marker, 's1' alone could be the start of 's10_x'");
        drop.Complete.Should().BeTrue();
    }

    [Fact]
    public async Task Only_isolated_derivation_rows_name_data_the_drop_may_delete()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        // A streamDataSchema override without isolate may name what another stack uses: the drop leaves it alone.
        cleanup.Derive = (_, _, _) => [new SlotDerivedRow("streamDataSchema", [], "shared", null, false)];
        _data.Crate.Relations.Add(new CrateRelation("shared_meshtest", "t", false));

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        _data.Crate.Dropped.Should().BeEmpty();
        drop.Steps.Single(s => s.Store == "cratedb").Status.Should().Be("nothing");
    }

    [Fact]
    public async Task Without_an_own_system_database_the_slots_Hangfire_database_is_still_dropped()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        cleanup.Derive = (_, _, _) => [new SlotDerivedRow("instancePrefix", [], "s1", null, true)];
        _data.Mongo.Databases.AddRange(["octosystem", "s1-OctoSystemJobs", "default-OctoSystemJobs"]);

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        _data.Mongo.Dropped.Should().Equal("s1-OctoSystemJobs");
        drop.Steps.Single(s => s.Store == "mongodb").Status.Should().Be("dropped");
    }

    [Fact]
    public void Two_writes_of_installations_json_within_one_second_keep_both_backups()
    {
        var file = Path.Combine(_checkout.Root, "octo-tools-config", "installations.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, """{ "installations": [] }""");

        var first = SlotOperations.MergeInstallation(file, new JsonObject { ["name"] = "local-a" }).Backup;
        var second = SlotOperations.MergeInstallation(file, new JsonObject { ["name"] = "local-b" }).Backup;

        second.Should().NotBe(first);
        File.ReadAllText(first!).Should().Contain("\"installations\": []", "the copy of the original file stays");
    }

    [Fact]
    public async Task Secret_files_behind_a_linked_octo_folder_are_not_touched_and_a_linked_state_folder_loses_only_the_link()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        var other = Path.Combine(_checkout.Root, "other-lane-octo");
        Directory.CreateDirectory(other);
        var foreignSecret = Path.Combine(other, SlotOperations.ClientSecretFileName);
        File.WriteAllText(foreignSecret, "x\n");
        var folder = EnvironmentDiscovery.FolderOf(_checkout.Root, "ab1-one");
        Directory.CreateDirectory(folder);
        Directory.CreateSymbolicLink(Path.Combine(folder, ".octo"), other);

        var drop = await cleanup.DropRetiredAsync("agent-1", 1, null, Ct);

        File.Exists(foreignSecret).Should().BeTrue("the link is never followed");
        drop.Steps.Single(s => s.Store == "files").Status.Should().Be("failed");
        drop.IndexFreed.Should().BeFalse();

        var target = Path.Combine(_checkout.Root, "state-target");
        Directory.CreateDirectory(target);
        var kept = Path.Combine(target, "kept.txt");
        File.WriteAllText(kept, "x");
        var link = Path.Combine(_checkout.Root, "state-link");
        Directory.CreateSymbolicLink(link, target);
        SlotDataCleanup.DeleteTree(link);
        Directory.Exists(link).Should().BeFalse();
        File.Exists(kept).Should().BeTrue("only the link goes");
    }

    [Fact]
    public async Task Admin_slot_forget_waits_for_a_running_drop_of_the_same_index()
    {
        var (supervisor, cleanup, _) = Create();
        supervisor.Slot("ab1-one", create: true);
        supervisor.ForgetSlot("ab1-one");
        var entered = new TaskCompletionSource();
        var release = new TaskCompletionSource();
        cleanup.Derive = (_, _, _) =>
        {
            entered.TrySetResult(); // the drop holds the gate now
            release.Task.Wait(TimeSpan.FromSeconds(10), Ct);
            return [];
        };

        var drop = Task.Run(() => cleanup.DropRetiredAsync("agent-1", 1, null, Ct), Ct);
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(10), Ct);
        var forget = cleanup.ForgetAsync(1, confirmDataDropped: true, Ct);
        await Task.Delay(200, Ct);
        forget.IsCompleted.Should().BeFalse("the forget waits for the drop's gate");

        release.SetResult();
        (await drop).IndexFreed.Should().BeTrue();
        await FluentActions.Awaiting(() => forget).Should().ThrowAsync<InvalidOperationException>().WithMessage("*Index 1 is not retired*",
            "the drop freed it already; the forget sees that instead of freeing an index a drop still works on");
    }

    [Fact]
    public async Task Admin_slot_drop_data_needs_an_owner_and_a_retired_index()
    {
        var (supervisor, cleanup, _) = Create();
        var noOwner = () => cleanup.DropRetiredAsync(" ", 1, null, Ct);
        await noOwner.Should().ThrowAsync<ArgumentException>().WithMessage("*owner*");
        var notRetired = () => cleanup.DropRetiredAsync("agent-1", 1, null, Ct);
        await notRetired.Should().ThrowAsync<InvalidOperationException>().WithMessage("*Index 1 is not retired*Retired: none*");
        supervisor.Slot("ab1-one", create: true);
        _data.Mongo.Dropped.Should().BeEmpty();
    }

    // ---------- the local octo-cli store (temp files, FakePwsh) ----------

    [Fact]
    public void The_installation_entry_is_removed_from_installations_json_after_a_backup_and_nothing_else_changes()
    {
        var file = Path.Combine(_checkout.Root, "octo-tools-config", "installations.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        const string original = """
                                {
                                  // the developer's own comment
                                  "rancher": { "url": "https://rancher.example" },
                                  "installations": [ { "name": "local", "services": {} }, { "name": "local-ab1-one", "services": {} } ]
                                }
                                """;
        File.WriteAllText(file, original);

        var (removed, backup) = LocalOctoCliSlotData.RemoveInstallation(file, "local-ab1-one");

        removed.Should().BeTrue();
        File.ReadAllText(backup!).Should().Be(original);
        var root = JsonNode.Parse(File.ReadAllText(file))!;
        root["installations"]!.AsArray().Select(i => i!["name"]!.GetValue<string>()).Should().Equal("local");
        root["rancher"]!["url"]!.GetValue<string>().Should().Be("https://rancher.example");

        var again = LocalOctoCliSlotData.RemoveInstallation(file, "local-ab1-one");
        again.Removed.Should().BeFalse();
        again.Backup.Should().BeNull("nothing is written when there is no such entry");
        LocalOctoCliSlotData.RemoveInstallation(Path.Combine(_checkout.Root, "missing.json"), "local-ab1-one").Removed.Should().BeFalse();
    }

    [Fact]
    public async Task Setups_and_drops_of_different_slots_never_lose_each_others_installation_entries()
    {
        var file = Path.Combine(_checkout.Root, "octo-tools-config", "installations.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, """{ "installations": [ { "name": "gone-0" }, { "name": "gone-1" }, { "name": "gone-2" }, { "name": "gone-3" } ] }""");

        var writers = Enumerable.Range(0, 16).Select(i => Task.Run(() =>
        {
            if (i < 4)
            {
                LocalOctoCliSlotData.RemoveInstallation(file, $"gone-{i}");
            }
            else
            {
                SlotOperations.MergeInstallation(file, new JsonObject { ["name"] = $"local-s{i}" });
            }
        }, Ct));
        await Task.WhenAll(writers);

        JsonNode.Parse(File.ReadAllText(file))!["installations"]!.AsArray().Select(i => i!["name"]!.GetValue<string>()).Order()
            .Should().Equal(Enumerable.Range(4, 12).Select(i => $"local-s{i}").Order(), "every read-modify-replace holds the one lock");
    }

    [Fact]
    public async Task The_local_store_client_takes_no_proxy_and_follows_no_redirect()
    {
        LocalInfra.Handler().UseProxy.Should().BeFalse();
        var port = TestPorts.Free();
        using var listener = new System.Net.HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        var serve = Task.Run(async () =>
        {
            var context = await listener.GetContextAsync();
            context.Response.StatusCode = 307;
            context.Response.RedirectLocation = "http://example.invalid/api/queues/x";
            context.Response.Close();
        }, Ct);

        using var http = new HttpClient(LocalInfra.Handler());
        using var response = await http.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"http://127.0.0.1:{port}/api/queues/x"), Ct);

        ((int)response.StatusCode).Should().Be(307, "the DELETE is not sent anywhere else; the status check reports it as a failure");
        await serve;
    }

    [Fact]
    public async Task Contexts_are_read_by_name_only_and_removed_with_octo_cli_RemoveContext()
    {
        var contexts = Path.Combine(_checkout.Root, ".octo-cli", "contexts.json");
        Directory.CreateDirectory(Path.GetDirectoryName(contexts)!);
        File.WriteAllText(contexts, """{"ActiveContext":"local_octosystem","Contexts":{"local_octosystem":{"Token":"t"},"local-ab1-one_octosystem":{"Token":"u"}}}""");
        var fake = new FakePwsh();
        string? script = null;
        fake.Build = (body, _, _) =>
        {
            script = body;
            return Task.FromResult(new PwshResult(0, PwshRunner.Marker + """[{"name":"local-ab1-one_octosystem","error":null},{"name":"x'y","error":"exit 1: Context 'x'y' does not exist."}]""" + "\n",
                false, false));
        };
        var config = Create().Store.Load();
        var store = new LocalOctoCliSlotData(config, fake, Path.Combine(_checkout.Root, "installations.json"), contexts);

        store.Contexts().Should().Equal("local_octosystem", "local-ab1-one_octosystem");
        var result = await store.RemoveContextsAsync(["local-ab1-one_octosystem", "x'y", "missing"], Ct);

        script.Should().Contain("& octo-cli -c RemoveContext -n $__n").And.Contain("'x''y'").And.Contain(PwshRunner.Marker);
        result["local-ab1-one_octosystem"].Should().BeNull();
        result["x'y"].Should().Contain("does not exist");
        result["missing"].Should().Contain("did not report");
        fake.Build = (_, _, _) => Task.FromResult(new PwshResult(1, "octo-cli: The term 'octo-cli' is not recognized\n", false, false));
        (await store.RemoveContextsAsync(["a"], Ct))["a"].Should().Contain("octo-cli gave no result (exit 1)").And.Contain("not recognized");
        new LocalOctoCliSlotData(config, fake, "", Path.Combine(_checkout.Root, "none.json")).Contexts().Should().BeNull();
    }

    [Fact]
    public void CrateDB_identifiers_are_quoted_in_a_drop()
    {
        LocalCrateSlotData.DropStatement(new CrateRelation("s1_meshtest", "stream\"data", false)).Should().Be("DROP TABLE IF EXISTS \"s1_meshtest\".\"stream\"\"data\"");
        LocalCrateSlotData.DropStatement(new CrateRelation("s1_meshtest", "v", true)).Should().Be("DROP VIEW IF EXISTS \"s1_meshtest\".\"v\"");
    }

    [Fact]
    public void Pruning_removes_empty_folders_only()
    {
        var lane = Path.Combine(_checkout.Root, "wt-gone");
        Directory.CreateDirectory(Path.Combine(lane, ".octo", "claims"));
        Directory.CreateDirectory(Path.Combine(lane, "notes"));
        File.WriteAllText(Path.Combine(lane, "notes", "keep.md"), "mine");

        SlotDataCleanup.PruneEmpty(lane).Should().BeFalse();
        Directory.Exists(Path.Combine(lane, ".octo")).Should().BeFalse();
        File.Exists(Path.Combine(lane, "notes", "keep.md")).Should().BeTrue();

        File.Delete(Path.Combine(lane, "notes", "keep.md"));
        SlotDataCleanup.PruneEmpty(lane).Should().BeTrue();
        Directory.Exists(lane).Should().BeFalse();
    }

    // ---------- the process check of lane_remove ----------

    [Fact]
    public void Processes_below_a_lane_are_sorted_into_its_stack_other_stacks_foreign_and_in_place()
    {
        var lane = Path.Combine(_checkout.Root, "wt-ab1");
        var inPlace = Path.Combine(_checkout.Root, "octo-b", ".claude", "worktrees", "x");
        var own = LaneProcesses.OwnProcesses(
            [("ab1", "alpha", 10, "agent-1"), (SlotInfo.DefaultName, "beta", 20, "agent-2"), (SlotInfo.DefaultName, "gamma", 30, null)],
            [(11, 10), (21, 20), (99, 1)]);
        own.Keys.Should().BeEquivalentTo([10, 11, 20, 21, 30], "a service's descendants are its own (Windows records the cmd.exe wrapper)");
        var found = new List<FolderProcess>
        {
            new(11, "dotnet", "module", lane), new(20, "cmd", "cwd", lane), new(21, "dotnet", "commandLine", lane), new(30, "dotnet", "module", inPlace),
            new(500, "dotnet", "module", lane) { StartedAt = new DateTimeOffset(2026, 11, 20, 10, 31, 2, TimeSpan.Zero) }, new(600, "pwsh", "cwd", inPlace),
            new(700, "bash", "cwd", inPlace), new(700, "bash", "cwd", lane)
        };

        var check = LaneProcesses.Classify(found, lane, "ab1", own);

        check.LaneStack.Select(o => o.Process.Pid).Should().Equal(11);
        check.OtherStacks.Select(o => (o.Service, o.Process.Pid)).Should().Equal([("beta", 20)], "one line per service, a service below an in-place worktree only stays");
        check.Foreign.Select(p => p.Pid).Should().Equal(500, 700);
        check.ForeignInPlace.Select(p => p.Pid).Should().Equal(600);

        var before = LaneProcesses.Refusal("ab1", lane, check, afterStop: false)!;
        before.Should().Contain("service beta of the shared stack").And.Contain("started by agent-2").And.Contain("pid 500 dotnet, started ")
            .And.Contain("pid 700 bash").And.Contain("dotnet build-server shutdown").And.Contain("close the shells").And.Contain("nothing was changed")
            .And.NotContain("pid 11 ").And.NotContain("pid 600");
        LaneProcesses.Refusal("ab1", lane, check, afterStop: true)!.Should().Contain("pid 11 dotnet").And.Contain("did not end with the stack")
            .And.Contain("the lane stack is stopped now");
        LaneProcesses.Refusal("ab1", lane, check with { OtherStacks = [], Foreign = [] }, afterStop: false).Should().BeNull("the lane stack's own services are stopped");
    }

    [Fact]
    public void The_process_scan_asks_octo_tools_for_every_folder_and_reads_pid_name_and_reason_only()
    {
        var script = LaneProcesses.Script(["C:\\dev\\wt-ab1", "/home/o'brien/octo-b"]);
        script.Should().Contain("Get-OctoProcessesUnderFolder -path $__f").And.Contain("'C:\\dev\\wt-ab1'").And.Contain("'/home/o''brien/octo-b'")
            .And.Contain("-ne $PID").And.Contain("Update-TypeData -TypeName System.Diagnostics.Process -MemberName CommandLine");
        script.Should().Contain("'@@DEVSTACK@@' + (ConvertTo-Json -InputObject @($__r)").And.Contain("folder = $__f; pid = [int]$__p.pid; name = [string]$__p.name; reason = [string]$__p.reason }",
            "only folder, pid, name and reason leave the pwsh process - never a command line");

        var started = new DateTimeOffset(2026, 11, 20, 9, 0, 0, TimeSpan.FromHours(1));
        var parsed = LaneProcesses.Parse(new PwshResult(0, "noise\n" + PwshRunner.Marker +
                                                         """[{"folder":"/x","pid":42,"name":"dotnet","reason":"module"},{"folder":"/x","pid":0,"name":"?","reason":"cwd"}]""" + "\n",
            false, false), pid => pid == 42 ? started : null);
        parsed.Should().ContainSingle().Which.Should().Be(new FolderProcess(42, "dotnet", "module", "/x") { StartedAt = started });
        LaneProcesses.Parse(new PwshResult(0, PwshRunner.Marker + "[]\n", false, false)).Should().BeEmpty();

        var failed = () => LaneProcesses.Parse(new PwshResult(1, "Get-OctoProcessesUnderFolder: not recognized\n", false, false));
        failed.Should().Throw<InvalidOperationException>().WithMessage("*no result (exit 1)*not recognized*");
        var garbled = () => LaneProcesses.Parse(new PwshResult(0, PwshRunner.Marker + "{oops\n", false, false));
        garbled.Should().Throw<InvalidOperationException>().WithMessage("*no readable result*");
        JsonSerializer.Serialize(parsed[0]).Should().NotContainAny("command", "Command");
    }
}
