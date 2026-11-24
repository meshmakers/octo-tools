using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     Data a removed lane stack leaves behind, with the command to drop it by hand: what lane_remove(keepData=true) kept, what
///     a step of the data drop could not drop, or what the daemon does not drop itself (S3 artifacts).
/// </summary>
public sealed record SlotLeftover(
    string Kind,
    string Name,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Drop);

/// <summary>What stays of a slot whose index is retired: the values of its isolate rows and its folders, with drop commands.</summary>
public static partial class SlotCleanup
{
    /// <summary>The MongoDB admin of the kind infrastructure; mongosh prompts for the password (-p without a value), it is never printed.</summary>
    public const string MongoAdminUser = "octo-system-admin";

    /// <summary>
    ///     The system database as MongoDB holds it: the services normalize the configured name with Trim().ToLowerInvariant()
    ///     (TenantContext.NormalizeDatabaseName), so OctoSystem_s2 is octosystem_s2 - names are case-sensitive in a drop.
    /// </summary>
    public static string SystemDatabaseName(string configured) => configured.Trim().ToLowerInvariant();

    /// <summary>The bot's Hangfire database: "&lt;instancePrefix&gt;-OctoSystemJobs", used as configured (BotServices Program.cs).</summary>
    public static string HangfireDatabaseName(string instancePrefix) => $"{instancePrefix}-OctoSystemJobs";

    /// <summary>The CrateDB schema prefix as TenantSchema uses it: non-alphanumeric characters removed, lowercase.</summary>
    public static string SchemaPrefix(string configured) => NonAlphanumeric().Replace(configured, "").ToLowerInvariant();

    [System.Text.RegularExpressions.GeneratedRegex("[^a-zA-Z0-9]")]
    private static partial System.Text.RegularExpressions.Regex NonAlphanumeric();

    internal static string DropMongo(string database) =>
        $"mongosh \"mongodb://localhost:27017/?directConnection=true\" -u {MongoAdminUser} --authenticationDatabase admin -p " +
        $"--eval \"db.getSiblingDB('{database}').dropDatabase()\"";

    /// <summary>The RabbitMQ queues and exchanges named &lt;prefix&gt;-..., deleted inside the broker's pod.</summary>
    internal static string DropRabbit(string prefix) =>
        $"kubectl --context {KindContext} -n octo-infra exec deploy/rabbitmq -- sh -c " +
        $"\"rabbitmqctl list_queues -q --no-table-headers name | grep '^{prefix}-' | xargs -r -I{{}} rabbitmqctl delete_queue {{}}; " +
        $"rabbitmqctl list_exchanges -q --no-table-headers name | grep '^{prefix}-' | xargs -r -I{{}} rabbitmqadmin delete exchange name={{}}\"";

    /// <summary>The CrateDB tables and views of the schemas &lt;schemaPrefix&gt;_&lt;tenant&gt;.</summary>
    internal static string DropCrate(string schemaPrefix) =>
        // Schemas are <prefix>_<tenant>; '\_' keeps LIKE from treating '_' as a wildcard (s1 must not match s10).
        $$"""curl -s -X POST http://localhost:4301/_sql -H 'Content-Type: application/json' -d '{"stmt":"SELECT table_schema, table_name, table_type FROM information_schema.tables WHERE table_schema LIKE '\''{{schemaPrefix}}\\_%'\''"}' """ +
        """- then for each row, views first: curl -s -X POST http://localhost:4301/_sql -H 'Content-Type: application/json' -d '{"stmt":"DROP VIEW \"<schema>\".\"<table>\""}' """ +
        """for table_type VIEW, '{"stmt":"DROP TABLE \"<schema>\".\"<table>\""}' for the others""";

    /// <summary>The artifacts of the local S3 store with the slot's prefix; the credential is only in the kind cluster's secret.</summary>
    internal static string DropS3(string prefix) =>
        $"aws --endpoint-url http://localhost:8333 s3 rm s3://octo-artifacts/{prefix}/ --recursive " +
        $"(credentials: kubectl --context {KindContext} -n octo-infra get secret seaweedfs-s3 -o yaml)";

    /// <summary>
    ///     The S3 artifacts of a slot as a leftover: the daemon never looks into the store (its credential needs kubectl), so it
    ///     cannot tell whether there are any; listing them blocks nothing.
    /// </summary>
    internal static SlotLeftover S3Leftover(string prefix) =>
        new($"Artifacts in the local S3 store below the prefix {prefix}/, if there are any - not checked (the store's credential needs kubectl); " +
            "this blocks nothing", prefix, DropS3(prefix));

    /// <summary>The octo-tools installation entry and the octo-cli contexts of a slot.</summary>
    internal static string DropOctoCli(string installation) =>
        $"remove the entry '{installation}' from installations[] of ~/.config/octo-tools/installations.json; octo-cli -c RemoveContext -n {installation}_<tenant> for each of its contexts";

    /// <summary>The kubectl context of the local kind cluster (Install-OctoKubernetes, cluster name "kind").</summary>
    public const string KindContext = "kind-kind";

    /// <summary>
    ///     The slot's data names as its derivation renders them (system database, Hangfire database, RabbitMQ and CrateDB
    ///     prefixes, artifact prefix, its state folder, octo-cli installation and contexts) with drop commands.
    /// </summary>
    /// <param name="tenantDatabases">The tenant databases the slot's system database registers; null: unknown (listed generically).</param>
    /// <param name="nameInUse">
    ///     A stack or lane of the slot's name exists again (with another index): the names that follow the slot's name - its
    ///     state folder, octo-cli installation and contexts - are that one's now, so no command removes them.
    /// </param>
    public static List<SlotLeftover> Leftovers(DevStackConfig config, SlotInfo slot, string stateDirectory, IReadOnlyList<string>? tenantDatabases = null,
        bool nameInUse = false)
    {
        var slotDir = SlotDeriver.SlotDirectory(stateDirectory, slot);
        var result = new List<SlotLeftover>();
        IReadOnlyList<SlotDerivedRow> rows;
        try
        {
            rows = SlotDeriver.Apply(config, slot, slotDir, null, null).Rows;
        }
        catch (InvalidOperationException)
        {
            rows = [];
        }

        foreach (var row in rows.Where(r => r.Isolate))
        {
            if (row.Value == slotDir || row.Value.StartsWith(slotDir + Path.DirectorySeparatorChar, StringComparison.Ordinal) || row.Value.StartsWith(slotDir + "/", StringComparison.Ordinal))
            {
                continue; // folders below the slot folder: one entry for the folder
            }

            result.Add(row.Id switch
            {
                "systemDatabase" => new SlotLeftover("MongoDB system database", SystemDatabaseName(row.Value), DropMongo(SystemDatabaseName(row.Value))),
                "instancePrefix" => new SlotLeftover($"RabbitMQ queues and exchanges named <prefix>-..., and the bot's Hangfire database {HangfireDatabaseName(row.Value)}", row.Value,
                    DropRabbit(row.Value) + "; " + DropMongo(HangfireDatabaseName(row.Value))),
                "streamDataSchema" => new SlotLeftover("CrateDB tables in the schemas <prefix>_<tenant> (CrateDB HTTP on localhost:4301, the kind host port)",
                    SchemaPrefix(row.Value), DropCrate(SchemaPrefix(row.Value))),
                // AB#8797: the slot's tenant databases are listed one by one below (registered in its system database).
                "tenantDatabasePrefix" => new SlotLeftover("Tenant databases created with the slot's prefix (<prefix><tenant>); the registered ones are listed below",
                    row.Value, null),
                "artifactStorage" => S3Leftover(row.Value),
                _ => new SlotLeftover(row.Id, row.Value, null)
            });
        }

        var installation = SlotArtifacts.InstallationName(slot);
        if (nameInUse)
        {
            result.Add(new SlotLeftover($"Slot folder and octo-cli installation and contexts: a stack or lane '{slot.Name}' exists again and they are its own now - nothing to drop",
                $"{slotDir}; {installation}, {installation}_<tenant>", null));
        }
        else
        {
            if (Directory.Exists(slotDir))
            {
                foreach (var dir in Directory.GetDirectories(slotDir).Order(StringComparer.Ordinal))
                {
                    result.Add(new SlotLeftover("Folder of the slot", dir, $"rm -rf '{dir}'"));
                }

                result.Add(new SlotLeftover("Slot folder (identity overlay, octo-cli installation entry, the folders above)", slotDir, $"rm -rf '{slotDir}'"));
            }

            result.Add(new SlotLeftover("octo-cli installation and contexts", $"{installation}, {installation}_<tenant>", DropOctoCli(installation)));
        }
        if (tenantDatabases == null)
        {
            result.Add(new SlotLeftover("Tenant databases of the slot's tenants (shared by name with every slot)", "<tenant>",
                "only when no other slot uses the tenant: octo-cli -c DeleteTenant through the slot's context, or drop the tenant database"));
        }
        else
        {
            result.AddRange(tenantDatabases.Select(db => new SlotLeftover("Tenant database (registered in the slot's system database; drop only when no other slot uses it)",
                db, DropMongo(db))));
        }
        return result;
    }
}
