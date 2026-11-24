using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>One store of the data drop: what was dropped (at most 20 names, <see cref="Count"/> all of them), what was kept or failed.</summary>
/// <param name="Store">mongodb, rabbitmq, cratedb, octoCli, files, s3.</param>
/// <param name="Status">
///     dropped (something was dropped, nothing failed), nothing (nothing to drop), kept (left on purpose, see the leftovers),
///     unchecked (the daemon cannot look into the store, S3: listed in the leftovers, blocks nothing), failed.
/// </param>
public sealed record SlotDataStep(string Store, string Status, int Count, IReadOnlyList<string> Dropped, string Summary);

/// <summary>
///     The data drop of a removed lane stack (lane_remove, admin_slot_drop_data): every store's step, and what remains with the
///     command to drop it by hand. Complete = no step failed; then the slot index is freed.
/// </summary>
public sealed record SlotDataDrop(
    string Slot,
    int Index,
    string Prefix,
    bool Complete,
    bool IndexFreed,
    IReadOnlyList<SlotDataStep> Steps,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<SlotLeftover>? Leftovers)
{
    /// <summary>The note of the answer: every step in a few words, and what happened to the index.</summary>
    public string Summary() =>
        $"Data of slot '{Slot}' (index {Index}, prefix {Prefix}): " + string.Join("; ", Steps.Select(s => $"{s.Store} {s.Status}{(s.Count > 0 ? $" ({s.Count})" : "")}")) + ". " +
        (IndexFreed
            ? $"Index {Index} is free again."
            : $"Index {Index} stays retired (a step failed, see leftovers): admin_slot_drop_data(owner, index={Index}) tries again.");
}

/// <summary>
///     Drops the data of a lane stack whose lane is gone: the system database, the tenant databases it owns and the bot's
///     Hangfire database (MongoDB), the queues and exchanges with its prefix (RabbitMQ), the tables of its schemas (CrateDB),
///     its octo-cli installation entry and contexts, its state folder and the lane's secret files. S3 artifacts are listed
///     only (their credential lives in the kind cluster). Every store sits behind a seam (<see cref="SlotDataStores"/>).
///     The slot's index is retired before (StackSupervisor.ForgetSlot) and freed only when every step succeeded.
/// </summary>
public sealed class SlotDataCleanup(ConfigStore store, StackSupervisor supervisor, SlotDataStores stores, ILogger<SlotDataCleanup>? logger = null)
{
    private const int MaxNames = 20;

    /// <summary>One drop at a time: two could pick the same index.</summary>
    private readonly SemaphoreSlim _gate = new(1, 1);

    /// <summary>lane_remove: the data of the slot just removed (its index is retired already); <paramref name="laneFolder"/> held the secret files.</summary>
    public async Task<SlotDataDrop> DropRemovedAsync(int index, string? laneFolder, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var retired = Retired(index);
            return await DropLockedAsync(store.Load(), index, retired, laneFolder, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    ///     admin_slot_drop_data: the data of an index retired earlier (a lane removed with keepData, or before the daemon dropped
    ///     data itself). Refused while a stack uses the index or anything listens on its shifted ports.
    /// </summary>
    public async Task<SlotDataDrop> DropRetiredAsync(string owner, int index, string? session, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(owner))
        {
            throw new ArgumentException("owner is required.");
        }

        await _gate.WaitAsync(cancellationToken);
        try
        {
            var retired = Retired(index);
            if (supervisor.Registry.Known().FirstOrDefault(k => k.Slot.Index == index).Slot is { } slot)
            {
                throw new InvalidOperationException($"Stack '{slot.Name}' uses index {index}.");
            }

            var open = await supervisor.OpenPortsAsync(retired.PortOffset);
            if (open.Count > 0)
            {
                throw new InvalidOperationException($"Something still runs on the ports of index {index} ({string.Join(", ", open)}); stop it first - it may still use the data.");
            }

            var config = store.Load();
            var root = ServicePlanner.RootPath(config);
            logger?.LogInformation("{Owner} ({Session}) drops the data of retired index {Index} (slot {Slot})", owner, session ?? "no session", index, retired.Name);
            return await DropLockedAsync(config, index, retired, root.Length > 0 ? EnvironmentDiscovery.FolderOf(root, retired.Name) : null, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    /// <summary>
    ///     admin_slot_forget: frees a retired index without dropping anything, under the same gate as the drops - a drop that is
    ///     still working on the names of that index must end before a new stack can get it.
    /// </summary>
    public async Task<RetiredSlot> ForgetAsync(int index, bool confirmDataDropped, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            return await supervisor.ForgetRetiredIndexAsync(index, confirmDataDropped);
        }
        finally
        {
            _gate.Release();
        }
    }

    private RetiredSlot Retired(int index) =>
        supervisor.State.RetiredSlots().GetValueOrDefault(index)
        ?? throw new InvalidOperationException(
            $"Index {index} is not retired. Retired: {(supervisor.State.RetiredSlots().Count == 0 ? "none" : string.Join(", ", supervisor.State.RetiredSlots().Keys.Order()))}.");

    private async Task<SlotDataDrop> DropLockedAsync(DevStackConfig config, int index, RetiredSlot retired, string? laneFolder, CancellationToken cancellationToken)
    {
        var slot = new SlotInfo(retired.Name, index, retired.PortOffset, retired.Prefix);
        if (slot.IsDefault || string.IsNullOrWhiteSpace(slot.Prefix))
        {
            throw new InvalidOperationException($"Index {index} has no slot prefix; the data of the shared stack is never dropped.");
        }

        // A stack or lane of the same name exists again (a new index): the names that follow the slot's name (state folder,
        // octo-cli installation and contexts, lane folder) are its own now. Asked again right before each step that removes
        // such a name, so one created while the stores were dropped is seen.
        var rows = Rows(config, slot);
        var run = new Run(config, slot, rows ?? [], () => supervisor.NameInUse(config, slot.Name));
        if (rows == null)
        {
            // The names of the stores cannot be derived (a bad slotDerivations row or configuration): nothing can be checked, so
            // the index must stay retired - an empty answer would look like "nothing to drop" and free it.
            foreach (var storeName in new[] { "mongodb", "rabbitmq", "cratedb" })
            {
                run.Fail(storeName, "Not checked: the slot's names could not be derived from the configuration (slotDerivations); fix it and " +
                                    $"call admin_slot_drop_data(owner, index={index}).", retired.TenantDatabases ?? []);
            }
        }
        else
        {
            await MongoAsync(run, retired.TenantDatabases ?? [], cancellationToken);
            await RabbitAsync(run, cancellationToken);
            await CrateAsync(run, cancellationToken);
        }

        await OctoCliAsync(run, cancellationToken);
        Files(run, laneFolder);
        if (run.Rows.TryGetValue("artifactStorage", out var artifacts))
        {
            run.Step("s3", "unchecked", [],
                $"Not checked: the daemon did not look whether the local S3 store holds artifacts below the prefix {artifacts}/ (the store's credential " +
                "is only in the kind cluster, kubectl). Any there stay until the leftovers command drops them; this blocks nothing - the index is freed all the same.");
            run.Leftovers.Add(SlotCleanup.S3Leftover(artifacts));
        }

        var complete = run.Steps.All(s => s.Status != "failed");
        if (complete)
        {
            supervisor.FreeRetiredIndex(index);
        }
        else
        {
            // The facts the next attempt needs once the system database is gone; the commands are generated when read.
            supervisor.State.UpdateRetiredSlot(index, run.RemainingTenants.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList());
        }

        var result = new SlotDataDrop(slot.Name, index, slot.Prefix, complete, complete, run.Steps, run.Leftovers.Count > 0 ? run.Leftovers : null);
        logger?.LogInformation("{Summary}", result.Summary());
        return result;
    }

    /// <summary>The slot's derivation rows (tests replace it to make the derivation fail; null: <see cref="SlotDeriver"/>).</summary>
    internal Func<DevStackConfig, SlotInfo, string, IReadOnlyList<SlotDerivedRow>>? Derive { get; set; }

    private static IReadOnlyList<SlotDerivedRow> DeriveRows(DevStackConfig config, SlotInfo slot, string slotDir) =>
        SlotDeriver.Apply(ProfileResolver.Materialize(config, null, null), slot, slotDir).Rows;

    /// <summary>
    ///     The slot's derived values by row id (systemDatabase, instancePrefix, streamDataSchema, tenantDatabasePrefix,
    ///     artifactStorage, ...); null when the configuration cannot derive them (a missing row only means that store is not isolated).
    /// </summary>
    private Dictionary<string, string>? Rows(DevStackConfig config, SlotInfo slot)
    {
        try
        {
            // Only isolated rows name the slot's own data: a row without isolate may name what another stack uses too (the
            // start-time collision check looks at isolated rows only, so the drop does the same).
            return (Derive ?? DeriveRows)(config, slot, SlotDeriver.SlotDirectory(supervisor.StateDirectory, slot))
                .Where(r => r.Isolate).GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First().Value);
        }
        catch (InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>The system databases of the other stacks (the shared stack's and every known slot's), lowercased: never dropped, their tenants never either.</summary>
    private HashSet<string> OtherSystemDatabases(DevStackConfig config, SlotInfo slot)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            SlotCleanup.SystemDatabaseName(config.Environment.GetValueOrDefault("OCTO_SYSTEM__SYSTEMDATABASENAME") ?? "OctoSystem")
        };
        foreach (var (other, _) in supervisor.Registry.Known().Where(k => !k.Slot.IsDefault && k.Slot.Index != slot.Index))
        {
            if (Rows(config, other) is { } rows && rows.TryGetValue("systemDatabase", out var db))
            {
                result.Add(SlotCleanup.SystemDatabaseName(db));
            }
        }

        return result;
    }

    private static bool IsMongoError(Exception e) => e is MongoDB.Driver.MongoException or TimeoutException or InvalidOperationException;

    private static bool IsHttpError(Exception e, CancellationToken cancellationToken) =>
        e is HttpRequestException or JsonException || (e is TaskCanceledException && !cancellationToken.IsCancellationRequested);

    private static string Short(Exception e) => Common.SecretMask.MaskValue(e.Message.Split('\n')[0].Trim().TrimEnd('.'));

    private async Task MongoAsync(Run run, IReadOnlyList<string> recordedTenants, CancellationToken cancellationToken)
    {
        if (!run.Rows.TryGetValue("systemDatabase", out var configured))
        {
            // No own system database, but an own instance prefix: the bot's Hangfire database <prefix>-OctoSystemJobs is still
            // the slot's and must not stay for the next slot of that index.
            if (run.Rows.TryGetValue("instancePrefix", out var onlyPrefix) && onlyPrefix.Length > 0 && onlyPrefix != "default")
            {
                await HangfireOnlyAsync(run, SlotCleanup.HangfireDatabaseName(onlyPrefix), cancellationToken);
                return;
            }

            run.Step("mongodb", "nothing", [], "The configuration derives no system database for slots (no systemDatabase row).");
            return;
        }

        var systemDb = SlotCleanup.SystemDatabaseName(configured);
        var hangfire = run.Rows.TryGetValue("instancePrefix", out var instance) && instance.Length > 0 ? SlotCleanup.HangfireDatabaseName(instance) : null;
        // A database without an ownership marker counts as the slot's by its name only when the prefix ends in a separator
        // (the default "<prefix>_"): a bare "s1" would also match the databases "s10_..." of index 10.
        var tenantPrefix = run.Rows.GetValueOrDefault("tenantDatabasePrefix")?.Trim().ToLowerInvariant() ?? "";
        if (tenantPrefix.Length > 0 && char.IsLetterOrDigit(tenantPrefix[^1]))
        {
            tenantPrefix = "";
        }
        var others = OtherSystemDatabases(run.Config, run.Slot);
        if (others.Contains(systemDb))
        {
            run.Fail("mongodb", $"Not dropped: {systemDb} is also the system database of another stack.", recordedTenants,
                new SlotLeftover("MongoDB system database (shared with another stack)", systemDb, null));
            return;
        }

        var mongo = stores.Mongo(run.Config);
        IReadOnlyList<string> databases;
        var candidates = new List<string>();
        var kept = new List<(string Database, string Why)>();
        string? actualSystem;
        try
        {
            databases = await mongo.DatabasesAsync(cancellationToken);
            string? Actual(string? name) => name == null ? null : databases.FirstOrDefault(d => string.Equals(d, name, StringComparison.OrdinalIgnoreCase));
            actualSystem = Actual(systemDb);
            var registered = actualSystem == null ? [] : (await mongo.TenantsAsync(actualSystem, cancellationToken)).Select(t => t.Database).Where(d => d.Length > 0).ToList();
            var elsewhere = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var other in others.Select(Actual).OfType<string>())
            {
                elsewhere.UnionWith((await mongo.TenantsAsync(other, cancellationToken)).Select(t => t.Database));
            }

            var names = registered.Concat(recordedTenants)
                .Concat(tenantPrefix.Length > 0 ? databases.Where(d => d.StartsWith(tenantPrefix, StringComparison.OrdinalIgnoreCase)) : [])
                .Select(Actual).OfType<string>()
                .Where(d => !string.Equals(d, systemDb, StringComparison.OrdinalIgnoreCase) && !string.Equals(d, hangfire, StringComparison.OrdinalIgnoreCase) &&
                            !others.Contains(d))
                .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.Ordinal).ToList();
            foreach (var db in names)
            {
                if (elsewhere.Contains(db))
                {
                    kept.Add((db, "registered in another stack's system database"));
                    continue;
                }

                var owner = await mongo.OwnerAsync(db, cancellationToken);
                var prefixed = tenantPrefix.Length > 0 && db.StartsWith(tenantPrefix, StringComparison.OrdinalIgnoreCase);
                if (owner != null ? string.Equals(owner, systemDb, StringComparison.OrdinalIgnoreCase) : prefixed)
                {
                    candidates.Add(db);
                }
                else
                {
                    kept.Add((db, owner != null ? $"owned by {owner}" : "no ownership marker and not named with the slot's prefix: another stack may use it"));
                }
            }

            if (Actual(hangfire) is { } jobs)
            {
                candidates.Add(jobs);
            }

            if (actualSystem != null)
            {
                candidates.Add(actualSystem); // last: it registers the tenants
            }
        }
        catch (Exception e) when (IsMongoError(e))
        {
            // The tenant databases' owners could not be read: listed without a drop command (another stack may use them).
            run.Fail("mongodb", $"MongoDB did not answer ({Short(e)}); nothing was dropped.", recordedTenants,
                new[] { systemDb, hangfire }.OfType<string>().Select(db => new SlotLeftover("MongoDB database of the slot", db, SlotCleanup.DropMongo(db)))
                    .Concat(recordedTenants.Select(db => new SlotLeftover(
                        "Tenant database recorded for the slot; its owner was not checked - drop it only when no other stack registers it", db, null)))
                    .ToArray());
            return;
        }

        var dropped = new List<string>();
        var failed = new List<(string Database, string Why)>();
        foreach (var db in candidates)
        {
            if (db == actualSystem && failed.Count > 0)
            {
                // It registers the tenants whose drop failed: without it a later attempt could no longer find them.
                failed.Add((db, "kept while a tenant database it registers could not be dropped"));
                continue;
            }

            try
            {
                await mongo.DropDatabaseAsync(db, cancellationToken);
                dropped.Add(db);
            }
            catch (Exception e) when (IsMongoError(e))
            {
                failed.Add((db, Short(e)));
            }
        }

        foreach (var (db, why) in kept)
        {
            // Not established as the slot's: no drop command (another stack may own it).
            run.Leftovers.Add(new SlotLeftover($"Tenant database, kept ({why})", db, null));
        }

        foreach (var (db, why) in failed)
        {
            run.Leftovers.Add(new SlotLeftover($"MongoDB database of the slot, drop failed ({why})", db, SlotCleanup.DropMongo(db)));
        }

        // Tenant databases that remain: kept with the retired index when it stays (the system database may be gone by then).
        run.RemainingTenants.AddRange(failed.Select(f => f.Database)
            .Where(d => !string.Equals(d, actualSystem, StringComparison.Ordinal) && !string.Equals(d, hangfire, StringComparison.OrdinalIgnoreCase))
            .Concat(kept.Select(k => k.Database)));

        var summary = (dropped.Count > 0 ? $"Dropped {dropped.Count} database(s): {string.Join(", ", dropped)}." : "No database of the slot exists.") +
                      (kept.Count > 0 ? $" Kept {kept.Count}: {string.Join("; ", kept.Select(k => $"{k.Database} ({k.Why})"))}." : "") +
                      (failed.Count > 0 ? $" Failed: {string.Join("; ", failed.Select(f => $"{f.Database} ({f.Why})"))}." : "");
        run.Step("mongodb", failed.Count > 0 ? "failed" : dropped.Count > 0 ? "dropped" : kept.Count > 0 ? "kept" : "nothing", dropped, summary);
    }

    /// <summary>MongoDB without an isolated system database: only the slot's Hangfire database is its own.</summary>
    private async Task HangfireOnlyAsync(Run run, string hangfire, CancellationToken cancellationToken)
    {
        var mongo = stores.Mongo(run.Config);
        try
        {
            var actual = (await mongo.DatabasesAsync(cancellationToken)).FirstOrDefault(d => string.Equals(d, hangfire, StringComparison.OrdinalIgnoreCase));
            if (actual == null)
            {
                run.Step("mongodb", "nothing", [], $"No system database of its own (no systemDatabase row); no Hangfire database {hangfire} exists.");
                return;
            }

            await mongo.DropDatabaseAsync(actual, cancellationToken);
            run.Step("mongodb", "dropped", [actual], $"Dropped the Hangfire database {actual} (no system database of its own: no systemDatabase row).");
        }
        catch (Exception e) when (IsMongoError(e))
        {
            run.Fail("mongodb", $"MongoDB did not answer or refused the drop of {hangfire} ({Short(e)}).", [],
                new SlotLeftover("Hangfire database of the slot", hangfire, SlotCleanup.DropMongo(hangfire)));
        }
    }

    private async Task RabbitAsync(Run run, CancellationToken cancellationToken)
    {
        if (!run.Rows.TryGetValue("instancePrefix", out var prefix) || prefix.Length == 0 || prefix == "default")
        {
            run.Step("rabbitmq", "nothing", [], "The configuration derives no instance prefix of its own for slots (no instancePrefix row).");
            return;
        }

        var rabbit = stores.Rabbit(run.Config);
        List<BrokerObject> queues, exchanges;
        try
        {
            queues = (await rabbit.QueuesAsync(cancellationToken)).Where(q => q.Name.StartsWith(prefix + "-", StringComparison.Ordinal)).ToList();
            exchanges = (await rabbit.ExchangesAsync(cancellationToken)).Where(x => x.Name.StartsWith(prefix + "-", StringComparison.Ordinal)).ToList();
        }
        catch (Exception e) when (IsHttpError(e, cancellationToken))
        {
            run.Fail("rabbitmq", $"The RabbitMQ management API did not answer ({Short(e)}); nothing was deleted.", [],
                new SlotLeftover("RabbitMQ queues and exchanges named <prefix>-...", prefix, SlotCleanup.DropRabbit(prefix)));
            return;
        }

        var dropped = new List<string>();
        var failed = new List<string>();
        foreach (var (item, queue) in queues.Select(q => (q, true)).Concat(exchanges.Select(x => (x, false))))
        {
            try
            {
                await (queue ? rabbit.DeleteQueueAsync(item, cancellationToken) : rabbit.DeleteExchangeAsync(item, cancellationToken));
                dropped.Add($"{(queue ? "queue" : "exchange")} {item.Name}");
            }
            catch (Exception e) when (IsHttpError(e, cancellationToken))
            {
                failed.Add($"{(queue ? "queue" : "exchange")} {item.Name} ({Short(e)})");
            }
        }

        if (failed.Count > 0)
        {
            run.Leftovers.Add(new SlotLeftover($"RabbitMQ queues and exchanges named <prefix>-..., {failed.Count} not deleted", prefix, SlotCleanup.DropRabbit(prefix)));
        }

        var deletedQueues = dropped.Count(d => d.StartsWith("queue ", StringComparison.Ordinal));
        var summary = dropped.Count > 0
            ? $"Deleted {deletedQueues} queue(s) and {dropped.Count - deletedQueues} exchange(s) named {prefix}-...."
            : $"No queue or exchange named {prefix}-... exists.";
        run.Step("rabbitmq", failed.Count > 0 ? "failed" : dropped.Count > 0 ? "dropped" : "nothing", dropped,
            summary + (failed.Count > 0 ? $" Failed: {string.Join("; ", failed.Take(5))}{(failed.Count > 5 ? $" and {failed.Count - 5} more" : "")}." : ""));
    }

    private async Task CrateAsync(Run run, CancellationToken cancellationToken)
    {
        var prefix = run.Rows.TryGetValue("streamDataSchema", out var configured) ? SlotCleanup.SchemaPrefix(configured) : "";
        if (prefix.Length == 0)
        {
            run.Step("cratedb", "nothing", [], "The configuration derives no schema prefix for slots (no streamDataSchema row).");
            return;
        }

        var crate = stores.Crate(run.Config);
        List<CrateRelation> relations;
        try
        {
            // Schemas are <prefix>_<tenant>: s1_ never matches s10_. Views first, they may read the tables.
            relations = (await crate.RelationsAsync(cancellationToken)).Where(r => r.Schema.StartsWith(prefix + "_", StringComparison.Ordinal))
                .OrderBy(r => r.View ? 0 : 1).ThenBy(r => r.ToString(), StringComparer.Ordinal).ToList();
        }
        catch (Exception e) when (IsHttpError(e, cancellationToken))
        {
            run.Fail("cratedb", $"CrateDB did not answer ({Short(e)}); nothing was dropped.", [],
                new SlotLeftover("CrateDB tables in the schemas <prefix>_<tenant>", prefix, SlotCleanup.DropCrate(prefix)));
            return;
        }

        var dropped = new List<string>();
        var failed = new List<string>();
        foreach (var relation in relations)
        {
            try
            {
                await crate.DropAsync(relation, cancellationToken);
                dropped.Add(relation.ToString());
            }
            catch (Exception e) when (IsHttpError(e, cancellationToken))
            {
                failed.Add($"{relation} ({Short(e)})");
            }
        }

        if (failed.Count > 0)
        {
            run.Leftovers.Add(new SlotLeftover($"CrateDB tables in the schemas <prefix>_<tenant>, {failed.Count} not dropped", prefix, SlotCleanup.DropCrate(prefix)));
        }

        var schemas = relations.Select(r => r.Schema).Distinct().Count();
        run.Step("cratedb", failed.Count > 0 ? "failed" : dropped.Count > 0 ? "dropped" : "nothing", dropped,
            (dropped.Count > 0 ? $"Dropped {dropped.Count} table(s) and view(s) in {schemas} schema(s) {prefix}_<tenant>." : $"No schema {prefix}_<tenant> exists.") +
            (failed.Count > 0 ? $" Failed: {string.Join("; ", failed.Take(5))}{(failed.Count > 5 ? $" and {failed.Count - 5} more" : "")}." : ""));
    }

    private async Task OctoCliAsync(Run run, CancellationToken cancellationToken)
    {
        var installation = SlotArtifacts.InstallationName(run.Slot);
        if (run.NameInUse)
        {
            run.Step("octoCli", "kept", [], $"A stack or lane '{run.Slot.Name}' exists again: the installation {installation} and its contexts are its own now.");
            return;
        }

        var cli = stores.OctoCli(run.Config);
        var dropped = new List<string>();
        var failed = new List<string>();
        try
        {
            var (removed, file, backup) = cli.RemoveInstallation(installation);
            if (removed)
            {
                dropped.Add($"installation {installation} ({file}{(backup != null ? $", backup {backup}" : "")})");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            failed.Add($"installation {installation} ({Short(e)})");
        }

        try
        {
            // Installation names have no '_' (slot names are [a-z0-9-]): local-ab1_ never matches a context of local-ab1-x.
            var contexts = (cli.Contexts() ?? []).Where(c => c.StartsWith(installation + "_", StringComparison.OrdinalIgnoreCase)).Order(StringComparer.Ordinal).ToList();
            if (contexts.Count > 0)
            {
                foreach (var (context, error) in await cli.RemoveContextsAsync(contexts, cancellationToken))
                {
                    if (error == null)
                    {
                        dropped.Add($"context {context}");
                    }
                    else
                    {
                        failed.Add($"context {context} ({error})");
                    }
                }
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException)
        {
            failed.Add($"contexts {installation}_<tenant> ({Short(e)})");
        }

        if (failed.Count > 0)
        {
            run.Leftovers.Add(new SlotLeftover("octo-cli installation and contexts, not all removed", $"{installation}, {installation}_<tenant>", SlotCleanup.DropOctoCli(installation)));
        }

        run.Step("octoCli", failed.Count > 0 ? "failed" : dropped.Count > 0 ? "dropped" : "nothing", dropped,
            (dropped.Count > 0 ? $"Removed {string.Join(", ", dropped)}." : $"No installation {installation} and no context {installation}_<tenant> exist.") +
            (failed.Count > 0 ? $" Failed: {string.Join("; ", failed)}." : ""));
    }

    private void Files(Run run, string? laneFolder)
    {
        var dropped = new List<string>();
        var failed = new List<string>();
        var notes = new List<string>();
        var slotDir = SlotDeriver.SlotDirectory(supervisor.StateDirectory, run.Slot);
        if (run.NameInUse)
        {
            notes.Add($"the state folder {slotDir} belongs to the stack '{run.Slot.Name}' that exists again");
        }
        else if (Directory.Exists(slotDir))
        {
            try
            {
                DeleteTree(slotDir);
                dropped.Add($"state folder {slotDir}");
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                failed.Add($"state folder {slotDir} ({Short(e)})");
                run.Leftovers.Add(new SlotLeftover("Slot folder (logs, identity overlay, octo-cli installation entry, service files)", slotDir, $"rm -rf '{slotDir}'"));
            }
        }

        if (laneFolder != null)
        {
            var secrets = DeleteLaneSecrets(laneFolder);
            dropped.AddRange(secrets.Dropped);
            failed.AddRange(secrets.Failed);
            notes.AddRange(secrets.Notes);
            run.Leftovers.AddRange(secrets.Leftovers);
        }

        run.Step("files", failed.Count > 0 ? "failed" : dropped.Count > 0 ? "dropped" : "nothing", dropped,
            (dropped.Count > 0 ? $"Removed {string.Join(", ", dropped)}." : "No folder or secret file of the slot exists.") +
            (failed.Count > 0 ? $" Failed: {string.Join("; ", failed)}." : "") + (notes.Count > 0 ? $" Note: {string.Join("; ", notes)}." : ""));
    }

    /// <summary>What <see cref="DeleteLaneSecrets"/> did: removed, failed (each with its leftover), notes.</summary>
    internal sealed record LaneSecrets(List<string> Dropped, List<string> Failed, List<string> Notes, List<SlotLeftover> Leftovers);

    /// <summary>
    ///     Deletes the lane stack's secret files (<c>.octo/admin-credentials.json</c>, <c>.octo/octo-cli-client.secret</c>) of a
    ///     removed lane and then its folder when nothing else is left in it - Remove-OctoEnvironment leaves the folder while they
    ///     are in it. Used by the data drop and by lane_remove with keepData (AB#9384): the secrets never stay with the data. A
    ///     folder that is a lane again is left alone; a lane folder or .octo that is a link is never followed (failed, listed).
    /// </summary>
    internal static LaneSecrets DeleteLaneSecrets(string laneFolder)
    {
        var result = new LaneSecrets([], [], [], []);
        if (!Directory.Exists(laneFolder))
        {
            return result;
        }

        var octo = Path.Combine(laneFolder, ".octo");
        if (File.Exists(EnvironmentDiscovery.ManifestPath(laneFolder)))
        {
            result.Notes.Add($"{laneFolder} is a lane (again): its files are left alone");
            return result;
        }

        if (new DirectoryInfo(laneFolder).LinkTarget != null || Directory.Exists(octo) && new DirectoryInfo(octo).LinkTarget != null)
        {
            // A link would lead the deletion into another folder (another lane's secret files): never followed.
            result.Failed.Add($"{laneFolder} or its .octo folder is a link; the secret files below it were not touched");
            result.Leftovers.Add(new SlotLeftover("Secret files of the lane stack behind a link (check where it points before deleting anything)", octo, null));
            return result;
        }

        foreach (var file in new[] { SlotOperations.CredentialsFileName, SlotOperations.ClientSecretFileName }.Select(f => Path.Combine(octo, f)))
        {
            try
            {
                if (File.Exists(file))
                {
                    File.Delete(file);
                    result.Dropped.Add($"secret file {file}");
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                result.Failed.Add($"{file} ({Short(e)})");
                result.Leftovers.Add(new SlotLeftover("Secret file of the lane stack (owner-only)", file, $"rm '{file}'"));
            }
        }

        try
        {
            if (PruneEmpty(laneFolder))
            {
                result.Dropped.Add($"empty lane folder {laneFolder}");
            }
            else
            {
                result.Notes.Add($"{laneFolder} still holds files the daemon does not own; they stay");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            result.Notes.Add($"the empty folders of {laneFolder} stay ({Short(e)})");
        }

        return result;
    }

    /// <summary>Deletes a folder with everything in it; read-only files (Windows) are made writable first. Links are removed, never followed.</summary>
    internal static void DeleteTree(string folder)
    {
        if (new DirectoryInfo(folder).LinkTarget != null)
        {
            // The folder itself is a link: only the link goes, nothing in its target is read or changed.
            Directory.Delete(folder);
            return;
        }

        foreach (var entry in new DirectoryInfo(folder).EnumerateFileSystemInfos("*",
                     new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }))
        {
            if (entry is FileInfo { IsReadOnly: true } file)
            {
                file.IsReadOnly = false;
            }
        }

        Directory.Delete(folder, recursive: true);
    }

    /// <summary>Deletes the empty folders below <paramref name="folder"/> and the folder itself when it is empty then; true when it is gone. Links are never entered.</summary>
    internal static bool PruneEmpty(string folder)
    {
        var info = new DirectoryInfo(folder);
        if (info.LinkTarget != null)
        {
            return false;
        }

        foreach (var sub in info.GetDirectories())
        {
            PruneEmpty(sub.FullName);
        }

        if (info.EnumerateFileSystemInfos().Any())
        {
            return false;
        }

        info.Delete();
        return true;
    }

    /// <summary>The state of one drop: the slot, its rows, the steps so far and what remains.</summary>
    private sealed class Run(DevStackConfig config, SlotInfo slot, IReadOnlyDictionary<string, string> rows, Func<bool> nameInUse)
    {
        public DevStackConfig Config => config;
        public SlotInfo Slot => slot;
        public IReadOnlyDictionary<string, string> Rows => rows;
        /// <summary>Asked anew on every read: a stack or lane of the slot's name created while the stores were dropped is seen.</summary>
        public bool NameInUse => nameInUse();
        public List<SlotDataStep> Steps { get; } = [];
        public List<SlotLeftover> Leftovers { get; } = [];
        public List<string> RemainingTenants { get; } = [];

        public void Step(string store, string status, IReadOnlyList<string> dropped, string summary) =>
            Steps.Add(new SlotDataStep(store, status, dropped.Count, dropped.Take(MaxNames).Concat(dropped.Count > MaxNames ? [$"... and {dropped.Count - MaxNames} more"] : []).ToList(),
                summary));

        public void Fail(string store, string summary, IReadOnlyList<string> remainingTenants, params SlotLeftover[] leftovers)
        {
            Steps.Add(new SlotDataStep(store, "failed", 0, [], summary));
            Leftovers.AddRange(leftovers);
            RemainingTenants.AddRange(remainingTenants);
        }
    }
}
