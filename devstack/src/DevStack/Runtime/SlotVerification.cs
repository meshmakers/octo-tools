using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Configuration;
using MongoDB.Bson;
using MongoDB.Driver;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>A tenant of a system database: its registry row and the ownership marker in its database (AB#4945).</summary>
public sealed record InventoryTenant(string TenantId, string Database, bool DatabaseExists, string? OwnerSystemDatabase);

/// <summary>A consumer connection as the broker sees it: MassTransit's connection name (the service assembly), process id and host.</summary>
public sealed record InventoryConsumer(string Connection, int? ProcessId, string? Host)
{
    public override string ToString() => $"{Connection} (pid {(ProcessId?.ToString() ?? "?")}{(Host != null ? $" on {Host}" : "")})";
}

/// <summary>A RabbitMQ queue with its consumers and the connections consuming it.</summary>
public sealed record InventoryQueue(string Name, int Consumers, IReadOnlyList<InventoryConsumer> ConsumerConnections);

/// <summary>What exists in the local infrastructure - read-only; the seam stack_verify tests replace.</summary>
public interface ISlotInventory
{
    Task<IReadOnlyList<string>> DatabasesAsync(CancellationToken cancellationToken);

    /// <summary>The tenants registered in a system database (RtEntity_SystemTenant), with their ownership markers.</summary>
    Task<IReadOnlyList<InventoryTenant>> TenantsAsync(string systemDatabase, CancellationToken cancellationToken);

    Task<IReadOnlyList<InventoryQueue>> QueuesAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<string>> CrateSchemasAsync(CancellationToken cancellationToken);
}

/// <summary>The kind infrastructure as the host sees it (<see cref="LocalInfra"/>); read-only.</summary>
public sealed class LocalInfraInventory(DevStackConfig config) : ISlotInventory
{
    private MongoClient Mongo() => LocalInfra.Mongo(config);

    public async Task<IReadOnlyList<string>> DatabasesAsync(CancellationToken cancellationToken) =>
        await (await Mongo().ListDatabaseNamesAsync(cancellationToken)).ToListAsync(cancellationToken);

    public async Task<IReadOnlyList<InventoryTenant>> TenantsAsync(string systemDatabase, CancellationToken cancellationToken)
    {
        var client = Mongo();
        var databases = (await (await client.ListDatabaseNamesAsync(cancellationToken)).ToListAsync(cancellationToken)).ToHashSet();
        if (!databases.Contains(systemDatabase))
        {
            return [];
        }

        var rows = await client.GetDatabase(systemDatabase).GetCollection<BsonDocument>("RtEntity_SystemTenant")
            .Find(FilterDefinition<BsonDocument>.Empty).ToListAsync(cancellationToken);
        var result = new List<InventoryTenant>();
        foreach (var row in rows)
        {
            var attributes = row.GetValue("attributes", new BsonDocument()).AsBsonDocument;
            var tenant = attributes.GetValue("tenantId", BsonNull.Value).IsString ? attributes["tenantId"].AsString : "?";
            var database = attributes.GetValue("databaseName", BsonNull.Value).IsString ? attributes["databaseName"].AsString.Trim().ToLowerInvariant() : "";
            string? owner = null;
            if (database.Length > 0 && databases.Contains(database))
            {
                var marker = await client.GetDatabase(database).GetCollection<BsonDocument>("tenant_ownership")
                    .Find(Builders<BsonDocument>.Filter.Eq("_id", "owner")).FirstOrDefaultAsync(cancellationToken);
                owner = marker?.GetValue("ownerSystemDatabaseName", BsonNull.Value) is { IsString: true } o ? o.AsString : null;
            }

            result.Add(new InventoryTenant(tenant, database, databases.Contains(database), owner));
        }

        return result;
    }

    public async Task<IReadOnlyList<InventoryQueue>> QueuesAsync(CancellationToken cancellationToken)
    {
        var queues = await GetRabbitAsync("api/queues?columns=name,consumers", cancellationToken) as JsonArray ?? [];
        var consumers = await GetRabbitAsync("api/consumers", cancellationToken) as JsonArray ?? [];
        var connections = new Dictionary<string, InventoryConsumer>();
        foreach (var c in await GetRabbitAsync("api/connections?columns=name,client_properties", cancellationToken) as JsonArray ?? [])
        {
            if (c?["name"]?.GetValue<string>() is { } name)
            {
                var properties = c["client_properties"];
                connections[name] = new InventoryConsumer(properties?["connection_name"]?.GetValue<string>() ?? name,
                    int.TryParse(properties?["process_id"]?.ToString(), out var pid) ? pid : null, properties?["hostname"]?.GetValue<string>());
            }
        }

        var byQueue = consumers.OfType<JsonObject>()
            .GroupBy(c => c["queue"]?["name"]?.GetValue<string>() ?? "")
            .ToDictionary(g => g.Key, g => g.Select(c => c["channel_details"]?["connection_name"]?.GetValue<string>() ?? "")
                .Select(n => connections.GetValueOrDefault(n) ?? new InventoryConsumer(n, null, null)).Distinct().ToList());
        return queues.OfType<JsonObject>().Select(q =>
        {
            var name = q["name"]?.GetValue<string>() ?? "";
            return new InventoryQueue(name, q["consumers"]?.GetValue<int>() ?? 0, byQueue.GetValueOrDefault(name) ?? []);
        }).ToList();
    }

    private static async Task<JsonNode?> GetRabbitAsync(string path, CancellationToken cancellationToken)
    {
        using var request = LocalInfra.RabbitRequest(HttpMethod.Get, path);
        using var response = await LocalInfra.Http.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        return JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
    }

    public async Task<IReadOnlyList<string>> CrateSchemasAsync(CancellationToken cancellationToken)
    {
        using var response = await LocalInfra.Http.PostAsync(LocalInfra.CrateSqlUrl,
            new StringContent("""{"stmt":"SELECT DISTINCT table_schema FROM information_schema.tables"}""", Encoding.UTF8, "application/json"), cancellationToken);
        response.EnsureSuccessStatusCode();
        var json = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
        return (json?["rows"] as JsonArray ?? []).Select(r => r?[0]?.GetValue<string>() ?? "").Where(s => s.Length > 0).ToList();
    }
}

/// <summary>
///     A consumer of the stack's queues: MassTransit's connection name, the pid of the process that opened it and its host, and
///     the stack's service that process belongs to (null: none of the stack's - another host, or a stranger the warnings name).
///     On Windows the pid is the service's own process below the cmd.exe wrapper stack_status records as pid (its processId).
/// </summary>
public sealed record VerifyConsumer(
    string Connection,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? ProcessId,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Host,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Service);

/// <summary>stack_verify: the stack's derived data names against what exists, and the warnings; ok is the verdict.</summary>
public sealed record SlotVerifyResult(
    string Slot,
    string SystemDatabase,
    bool SystemDatabaseExists,
    IReadOnlyList<InventoryTenant> Tenants,
    string InstancePrefix,
    int Queues,
    int Consumers,
    IReadOnlyList<VerifyConsumer> ConsumerConnections,
    string SchemaPrefix,
    IReadOnlyList<string> CrateSchemas,
    IReadOnlyList<string> Warnings,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? Unreachable)
{
    /// <summary>The verdict: no warning, and every store (MongoDB, RabbitMQ, CrateDB) answered. Comes first in the result.</summary>
    [JsonPropertyOrder(-1)]
    public bool Ok => Warnings.Count == 0 && Unreachable is not { Count: > 0 };

    /// <summary>The lane whose stack was verified; null for the shared stack and a slot of no lane.</summary>
    [JsonPropertyOrder(-1)]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Lane { get; init; }
}

/// <summary>Compares a slot's derived data names (system database, RabbitMQ and CrateDB prefixes) with the local infrastructure.</summary>
public static class SlotVerifier
{
    /// <summary>
    ///     The processes that are the slot's own services: the pids the daemon recorded and every process below them. The
    ///     broker reports the pid of the process that opened the connection, which is not always the recorded one: on Windows
    ///     the daemon records the <c>cmd.exe /s /c</c> wrapper (ProcessLauncher) and RabbitMQ sees its dotnet child; on
    ///     macOS/Linux <c>/bin/sh -c exec</c> becomes the service, so both are the same pid.
    /// </summary>
    /// <param name="recorded">The slot's services with their pids as the daemon started them.</param>
    /// <param name="links">(pid, parent pid) of every process (<see cref="Common.ProcessTree.Links"/>).</param>
    /// <returns>Every own process with the service it belongs to.</returns>
    public static Dictionary<int, string> OwnProcesses(IEnumerable<(string Service, int Pid)> recorded, IEnumerable<(int Pid, int ParentPid)> links)
    {
        var all = links.ToList();
        var own = new Dictionary<int, string>();
        foreach (var (service, pid) in recorded.Where(r => r.Pid > 0))
        {
            foreach (var p in Common.ProcessTree.DescendantsOf(pid, all))
            {
                own.TryAdd(p, service);
            }
        }

        return own;
    }

    /// <param name="own">
    ///     The pids of the slot's own services and their child processes, with the service (<see cref="OwnProcesses"/>): a
    ///     consumer on this machine with another pid consumes the slot's queues by mistake.
    /// </param>
    /// <param name="otherSchemaPrefixes">The schema prefixes of the other slots (the default slot's schemas are unprefixed).</param>
    public static async Task<SlotVerifyResult> VerifyAsync(DevStackConfig config, SlotTarget target, IReadOnlyList<(string Slot, string SystemDatabase)> allSlots,
        ISlotInventory inventory, CancellationToken cancellationToken, IReadOnlyDictionary<int, string>? own = null, IReadOnlyCollection<string>? otherSchemaPrefixes = null)
    {
        var systemDb = SlotCleanup.SystemDatabaseName(target.SystemDatabase(config));
        var prefix = target.Row("instancePrefix");
        var schemaPrefix = SlotCleanup.SchemaPrefix(target.Row("streamDataSchema"));
        var warnings = new List<string>();
        var unreachable = new List<string>();

        IReadOnlyList<string> databases = [];
        IReadOnlyList<InventoryTenant> tenants = [];
        try
        {
            databases = await inventory.DatabasesAsync(cancellationToken);
            tenants = await inventory.TenantsAsync(systemDb, cancellationToken);
            // A tenant database registered in another slot's system database too: both stacks would write into it.
            foreach (var (slot, other) in allSlots.Where(s => s.Slot != target.Slot.Name))
            {
                var otherDb = SlotCleanup.SystemDatabaseName(other);
                if (otherDb == systemDb || !databases.Contains(otherDb))
                {
                    continue;
                }

                var shared = (await inventory.TenantsAsync(otherDb, cancellationToken)).Select(t => t.Database).Intersect(tenants.Select(t => t.Database)).ToList();
                foreach (var db in shared)
                {
                    warnings.Add($"Tenant database '{db}' is registered in {systemDb} and in {otherDb} (slot '{slot}'): both stacks use the same data.");
                }
            }

            foreach (var t in tenants)
            {
                if (!t.DatabaseExists)
                {
                    warnings.Add($"Tenant '{t.TenantId}': its database '{t.Database}' does not exist.");
                }
                else if (t.OwnerSystemDatabase == null)
                {
                    warnings.Add($"Tenant '{t.TenantId}': its database '{t.Database}' has no ownership marker (created before AB#4945); another instance could attach it.");
                }
                else if (t.OwnerSystemDatabase != systemDb)
                {
                    warnings.Add($"Tenant '{t.TenantId}': its database '{t.Database}' is owned by {t.OwnerSystemDatabase}, not by {systemDb}.");
                }
            }
        }
        catch (Exception e) when (e is MongoException or TimeoutException or InvalidOperationException)
        {
            unreachable.Add($"MongoDB: {e.Message}");
        }

        IReadOnlyList<InventoryQueue> queues = [];
        try
        {
            queues = (await inventory.QueuesAsync(cancellationToken)).Where(q => q.Name.StartsWith(prefix + "-", StringComparison.Ordinal)).ToList();
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            unreachable.Add($"RabbitMQ management: {e.Message}");
        }

        IReadOnlyList<string> schemas = [];
        try
        {
            var all = await inventory.CrateSchemasAsync(cancellationToken);
            schemas = (schemaPrefix.Length > 0
                    ? all.Where(s => s.StartsWith(schemaPrefix + "_", StringComparison.Ordinal))
                    : all.Where(s => s is not ("sys" or "information_schema" or "pg_catalog" or "blob" or "doc") &&
                                     !System.Text.RegularExpressions.Regex.IsMatch(s, @"^s[0-9]+_") && // a slot's s<n>_ schemas, also of removed slots
                                     !(otherSchemaPrefixes ?? []).Any(p => p.Length > 0 && s.StartsWith(p + "_", StringComparison.Ordinal))))
                .Order(StringComparer.Ordinal).ToList();
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            unreachable.Add($"CrateDB: {e.Message}");
        }

        if (unreachable.Count == 0 && !databases.Contains(systemDb))
        {
            warnings.Add($"The system database {systemDb} does not exist yet (the slot never ran, or it was dropped).");
        }

        var consumers = queues.SelectMany(q => q.ConsumerConnections).Distinct().ToList();
        var localHost = System.Net.Dns.GetHostName().Split('.')[0];
        bool Local(InventoryConsumer c) => c.Host != null && string.Equals(c.Host.Split('.')[0], localHost, StringComparison.OrdinalIgnoreCase);
        string? ServiceOf(InventoryConsumer c) => own != null && c.ProcessId is { } pid && Local(c) ? own.GetValueOrDefault(pid) : null;
        if (own != null)
        {
            foreach (var c in consumers.Where(c => c.ProcessId is { } pid && !own.ContainsKey(pid) && Local(c)))
            {
                warnings.Add($"{c} on this machine consumes queues of prefix '{prefix}' but is no service of " +
                             $"{(target.Environment != null ? $"lane stack '{target.Environment}'" : target.Slot.IsDefault ? "the shared stack" : $"slot '{target.Slot.Name}'")}.");
            }
        }

        var connections = consumers.Select(c => new VerifyConsumer(c.Connection, c.ProcessId, c.Host, ServiceOf(c))).Distinct()
            .OrderBy(c => c.Connection, StringComparer.Ordinal).ThenBy(c => c.ProcessId).ToList();
        return new SlotVerifyResult(target.Slot.Name, systemDb, databases.Contains(systemDb), tenants, prefix, queues.Count, queues.Sum(q => q.Consumers),
            connections, schemaPrefix, schemas, warnings, unreachable.Count == 0 ? null : unreachable) { Lane = target.Environment };
    }
}
