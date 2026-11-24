using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using MongoDB.Bson;
using MongoDB.Driver;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>A RabbitMQ queue or exchange: the virtual host it lives in and its name.</summary>
public sealed record BrokerObject(string Vhost, string Name);

/// <summary>A CrateDB table or view.</summary>
public sealed record CrateRelation(string Schema, string Name, bool View)
{
    public override string ToString() => $"{Schema}.{Name}";
}

/// <summary>The databases of the local MongoDB, as the data drop of a lane stack sees them (the seam its tests replace).</summary>
public interface IMongoSlotData
{
    Task<IReadOnlyList<string>> DatabasesAsync(CancellationToken cancellationToken);

    /// <summary>The tenants a system database registers (RtEntity_SystemTenant), with their ownership markers; empty without that database.</summary>
    Task<IReadOnlyList<InventoryTenant>> TenantsAsync(string systemDatabase, CancellationToken cancellationToken);

    /// <summary>The system database named by a database's ownership marker (AB#4945), or null without one.</summary>
    Task<string?> OwnerAsync(string database, CancellationToken cancellationToken);

    Task DropDatabaseAsync(string database, CancellationToken cancellationToken);
}

/// <summary>The queues and exchanges of the local RabbitMQ (management API).</summary>
public interface IRabbitSlotData
{
    Task<IReadOnlyList<BrokerObject>> QueuesAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<BrokerObject>> ExchangesAsync(CancellationToken cancellationToken);

    /// <summary>Deletes a queue; one that is gone already counts as deleted.</summary>
    Task DeleteQueueAsync(BrokerObject queue, CancellationToken cancellationToken);

    /// <summary>Deletes an exchange; one that is gone already counts as deleted.</summary>
    Task DeleteExchangeAsync(BrokerObject exchange, CancellationToken cancellationToken);
}

/// <summary>The tables and views of the local CrateDB (HTTP endpoint).</summary>
public interface ICrateSlotData
{
    Task<IReadOnlyList<CrateRelation>> RelationsAsync(CancellationToken cancellationToken);

    Task DropAsync(CrateRelation relation, CancellationToken cancellationToken);
}

/// <summary>octo-cli's contexts and the octo-tools installation entries.</summary>
public interface IOctoCliSlotData
{
    /// <summary>The names of octo-cli's contexts (names only, never their content); null when there is no contexts file.</summary>
    IReadOnlyList<string>? Contexts();

    /// <summary>Removes contexts with octo-cli -c RemoveContext; per context null (removed) or why it failed.</summary>
    Task<IReadOnlyDictionary<string, string?>> RemoveContextsAsync(IReadOnlyList<string> names, CancellationToken cancellationToken);

    /// <summary>Removes an installation entry from installations.json (a backup copy first); Removed=false when there was none.</summary>
    (bool Removed, string File, string? Backup) RemoveInstallation(string name);
}

/// <summary>The stores the data drop of a lane stack works on; tests pass fakes, the daemon <see cref="Local"/>.</summary>
public sealed record SlotDataStores(
    Func<DevStackConfig, IMongoSlotData> Mongo,
    Func<DevStackConfig, IRabbitSlotData> Rabbit,
    Func<DevStackConfig, ICrateSlotData> Crate,
    Func<DevStackConfig, IOctoCliSlotData> OctoCli)
{
    /// <param name="installationsFile">The octo-tools config file the setup registers the installation in (<see cref="SlotOperations.OctoToolsConfigFile"/>).</param>
    /// <param name="contextsFile">octo-cli's contexts file (<see cref="PreStartChecks.ContextsFile"/>).</param>
    public static SlotDataStores Local(IPwshRunner pwsh, Func<string> installationsFile, Func<string> contextsFile) =>
        new(c => new LocalMongoSlotData(c), _ => new LocalRabbitSlotData(), _ => new LocalCrateSlotData(),
            c => new LocalOctoCliSlotData(c, pwsh, installationsFile(), contextsFile()));
}

/// <summary>The local MongoDB (<see cref="LocalInfra.Mongo"/>).</summary>
public sealed class LocalMongoSlotData(DevStackConfig config) : IMongoSlotData
{
    private readonly MongoClient _client = LocalInfra.Mongo(config);

    public Task<IReadOnlyList<string>> DatabasesAsync(CancellationToken cancellationToken) => new LocalInfraInventory(config).DatabasesAsync(cancellationToken);

    public Task<IReadOnlyList<InventoryTenant>> TenantsAsync(string systemDatabase, CancellationToken cancellationToken) =>
        new LocalInfraInventory(config).TenantsAsync(systemDatabase, cancellationToken);

    public async Task<string?> OwnerAsync(string database, CancellationToken cancellationToken)
    {
        var marker = await _client.GetDatabase(database).GetCollection<BsonDocument>("tenant_ownership")
            .Find(Builders<BsonDocument>.Filter.Eq("_id", "owner")).FirstOrDefaultAsync(cancellationToken);
        return marker?.GetValue("ownerSystemDatabaseName", BsonNull.Value) is { IsString: true } owner ? owner.AsString : null;
    }

    public Task DropDatabaseAsync(string database, CancellationToken cancellationToken) => _client.DropDatabaseAsync(database, cancellationToken);
}

/// <summary>The local RabbitMQ management API (<see cref="LocalInfra.RabbitManagementUrl"/>).</summary>
public sealed class LocalRabbitSlotData : IRabbitSlotData
{
    public Task<IReadOnlyList<BrokerObject>> QueuesAsync(CancellationToken cancellationToken) => ListAsync("api/queues?columns=name,vhost", cancellationToken);

    public Task<IReadOnlyList<BrokerObject>> ExchangesAsync(CancellationToken cancellationToken) => ListAsync("api/exchanges?columns=name,vhost", cancellationToken);

    public Task DeleteQueueAsync(BrokerObject queue, CancellationToken cancellationToken) => DeleteAsync("queues", queue, cancellationToken);

    public Task DeleteExchangeAsync(BrokerObject exchange, CancellationToken cancellationToken) => DeleteAsync("exchanges", exchange, cancellationToken);

    private static async Task<IReadOnlyList<BrokerObject>> ListAsync(string path, CancellationToken cancellationToken)
    {
        using var request = LocalInfra.RabbitRequest(HttpMethod.Get, path);
        using var response = await LocalInfra.Http.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        var list = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken)) as JsonArray ?? [];
        return list.OfType<JsonObject>()
            .Select(o => new BrokerObject(BuildPlanner.Str(o["vhost"]) ?? "/", BuildPlanner.Str(o["name"]) ?? ""))
            .Where(o => o.Name.Length > 0).ToList();
    }

    private static async Task DeleteAsync(string kind, BrokerObject item, CancellationToken cancellationToken)
    {
        using var request = LocalInfra.RabbitRequest(HttpMethod.Delete, $"api/{kind}/{Uri.EscapeDataString(item.Vhost)}/{Uri.EscapeDataString(item.Name)}");
        using var response = await LocalInfra.Http.SendAsync(request, cancellationToken);
        if (response.StatusCode != System.Net.HttpStatusCode.NotFound)
        {
            response.EnsureSuccessStatusCode();
        }
    }
}

/// <summary>The local CrateDB HTTP endpoint (<see cref="LocalInfra.CrateSqlUrl"/>).</summary>
public sealed class LocalCrateSlotData : ICrateSlotData
{
    public async Task<IReadOnlyList<CrateRelation>> RelationsAsync(CancellationToken cancellationToken)
    {
        var json = await SqlAsync("SELECT table_schema, table_name, table_type FROM information_schema.tables", cancellationToken);
        return (json?["rows"] as JsonArray ?? []).OfType<JsonArray>()
            .Select(r => new CrateRelation(BuildPlanner.Str(r[0]) ?? "", BuildPlanner.Str(r[1]) ?? "", string.Equals(BuildPlanner.Str(r[2]), "VIEW", StringComparison.OrdinalIgnoreCase)))
            .Where(r => r.Schema.Length > 0 && r.Name.Length > 0).ToList();
    }

    public Task DropAsync(CrateRelation relation, CancellationToken cancellationToken) =>
        SqlAsync(DropStatement(relation), cancellationToken);

    /// <summary>DROP TABLE / DROP VIEW with quoted identifiers (a '"' inside a name is doubled).</summary>
    internal static string DropStatement(CrateRelation relation) =>
        $"DROP {(relation.View ? "VIEW" : "TABLE")} IF EXISTS {Identifier(relation.Schema)}.{Identifier(relation.Name)}";

    private static string Identifier(string name) => "\"" + name.Replace("\"", "\"\"") + "\"";

    private static async Task<JsonNode?> SqlAsync(string statement, CancellationToken cancellationToken)
    {
        var body = JsonSerializer.Serialize(new { stmt = statement });
        using var response = await LocalInfra.Http.PostAsync(LocalInfra.CrateSqlUrl, new StringContent(body, Encoding.UTF8, "application/json"), cancellationToken);
        var text = await response.Content.ReadAsStringAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var message = JsonNode.Parse(text)?["error"]?["message"]?.GetValue<string>() ?? text;
            throw new HttpRequestException($"CrateDB answered {(int)response.StatusCode}: {(message.Length > 300 ? message[..300] + " ..." : message)}");
        }

        return JsonNode.Parse(text);
    }
}

/// <summary>
///     octo-cli's contexts (names read from its contexts file; removed with octo-cli -c RemoveContext, the way octo-cli owns them)
///     and the installation entries of the octo-tools config file (the same file and backup rule as the setup's octoCli step).
/// </summary>
public sealed class LocalOctoCliSlotData(DevStackConfig config, IPwshRunner pwsh, string installationsFile, string contextsFile) : IOctoCliSlotData
{
    public IReadOnlyList<string>? Contexts()
    {
        if (!File.Exists(contextsFile))
        {
            return null;
        }

        using var document = JsonDocument.Parse(SharedFile.ReadAllText(contextsFile));
        return document.RootElement.TryGetProperty("Contexts", out var contexts) && contexts.ValueKind == JsonValueKind.Object
            ? contexts.EnumerateObject().Select(p => p.Name).ToList()
            : [];
    }

    public async Task<IReadOnlyDictionary<string, string?>> RemoveContextsAsync(IReadOnlyList<string> names, CancellationToken cancellationToken)
    {
        var result = await pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), RemoveContextsScript(names), new PwshRunOptions { Timeout = TimeSpan.FromMinutes(2) },
            cancellationToken);
        return ParseRemoveContexts(names, result);
    }

    /// <summary>One pwsh run: octo-cli -c RemoveContext -n &lt;name&gt; per context; the marker line holds { name, error } per context.</summary>
    internal static string RemoveContextsScript(IReadOnlyList<string> names) =>
        $$"""
          $__r = @()
          foreach ($__n in @({{string.Join(", ", names.Select(PwshRunner.Quote))}})) {
              try {
                  $__out = & octo-cli -c RemoveContext -n $__n 2>&1 | Out-String
                  if ($LASTEXITCODE -eq 0) { $__r += [ordered]@{ name = $__n; error = $null } }
                  else { $__r += [ordered]@{ name = $__n; error = "exit $($LASTEXITCODE): " + (($__out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 2 | ForEach-Object { $_.Trim() }) -join ' | ') } }
              }
              catch { $__r += [ordered]@{ name = $__n; error = $_.Exception.Message } }
          }
          '{{PwshRunner.Marker}}' + (ConvertTo-Json -InputObject @($__r) -Compress -Depth 3)
          """;

    internal static IReadOnlyDictionary<string, string?> ParseRemoveContexts(IReadOnlyList<string> names, PwshResult result)
    {
        JsonNode? marker = null;
        try
        {
            marker = PwshRunner.ExtractMarker(result.Output);
        }
        catch (JsonException)
        {
            // No readable result: every context failed, with the output's last line.
        }

        var answers = (marker as JsonArray ?? []).OfType<JsonObject>()
            .Where(o => BuildPlanner.Str(o["name"]) != null)
            .GroupBy(o => BuildPlanner.Str(o["name"])!, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => BuildPlanner.Str(g.Last()["error"]), StringComparer.Ordinal);
        var why = marker is JsonArray
            ? "the removal did not report on this context"
            : $"octo-cli gave no result (exit {result.ExitCode}{(result.TimedOut ? ", timed out" : "")}): " +
              PwshErrors.Summary(result.Output);
        return names.ToDictionary(n => n, n => answers.TryGetValue(n, out var error) ? error is { Length: > 0 } ? SecretMask.MaskValue(error) : null : SecretMask.MaskValue(why),
            StringComparer.Ordinal);
    }

    public (bool Removed, string File, string? Backup) RemoveInstallation(string name)
    {
        var (removed, backup) = RemoveInstallation(installationsFile, name);
        return (removed, installationsFile, backup);
    }

    /// <summary>
    ///     Removes the entry <paramref name="name"/> from installations[] (the counterpart of <see cref="SlotOperations.MergeInstallation"/>):
    ///     a backup copy first, the rest of the file as it was. Nothing is written when there is no such entry.
    /// </summary>
    internal static (bool Removed, string? Backup) RemoveInstallation(string file, string name)
    {
        lock (SlotOperations.InstallationsFileLock)
        {
            return RemoveInstallationLocked(file, name);
        }
    }

    private static (bool Removed, string? Backup) RemoveInstallationLocked(string file, string name)
    {
        if (!File.Exists(file))
        {
            return (false, null);
        }

        var root = JsonNode.Parse(SharedFile.ReadAllText(file), documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip }) as JsonObject
                   ?? throw new InvalidOperationException($"{file} is not a JSON object; nothing was changed.");
        if (root["installations"] is not JsonArray list)
        {
            return (false, null);
        }

        var matches = list.Where(n => n?["name"] is JsonValue v && v.GetValueKind() == JsonValueKind.String && v.GetValue<string>() == name).ToList();
        if (matches.Count == 0)
        {
            return (false, null);
        }

        var backup = SlotOperations.BackupName(file);
        File.Copy(file, backup, overwrite: false);
        foreach (var match in matches)
        {
            list.Remove(match);
        }

        var temp = file + ".tmp";
        File.WriteAllText(temp, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        if (!OperatingSystem.IsWindows())
        {
            File.SetUnixFileMode(temp, File.GetUnixFileMode(file));
        }

        SharedFile.Replace(temp, file);
        return (true, backup);
    }
}
