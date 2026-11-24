namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>What the settings of a profile turn into.</summary>
public sealed record SettingsExpansion(
    Dictionary<string, string?> Env,
    Dictionary<string, Dictionary<string, string>> Variables,
    Dictionary<string, bool> EnvProviders);

/// <summary>
///     The one place that knows which configuration keys a logical profile setting fans out to. The services have no
///     shared section for broker, authority or instance prefix, so a setting is written into every section that holds
///     it. Keys follow the options classes of branches/main (read-only check, 2026-11-09):
///     Identity, AssetRepository, Bot, PlatformServices have BrokerHost/BrokerUser but no BrokerPort/BrokerVirtualHost;
///     CommunicationController, Reporting, Mcp, Ai and Adapter have both. AssetRepository calls its issuer 'Authority',
///     the adapter has IssuerUri (AdapterOptions) and AuthorityUrl (MeshAdapterConfiguration).
/// </summary>
public static class SettingsMap
{
    /// <summary>Configuration sections of the services that connect to the broker.</summary>
    public static readonly string[] BrokerSections =
        ["IDENTITY", "ASSETREPOSITORY", "BOT", "COMMUNICATIONCONTROLLER", "PLATFORMSERVICES", "REPORTING", "MCP", "AI", "ADAPTER"];

    /// <summary>Sections whose options have BrokerPort and BrokerVirtualHost.</summary>
    public static readonly string[] BrokerPortSections = ["COMMUNICATIONCONTROLLER", "REPORTING", "MCP", "AI", "ADAPTER"];

    public static readonly string[] AuthorityKeys =
    [
        "OCTO_IDENTITY__AUTHORITYURL",
        "OCTO_ASSETREPOSITORY__AUTHORITY",
        "OCTO_BOT__AUTHORITYURL",
        "OCTO_COMMUNICATIONCONTROLLER__AUTHORITYURL",
        "OCTO_PLATFORMSERVICES__AUTHORITYURL",
        "OCTO_REPORTING__AUTHORITYURL",
        "OCTO_MCP__AUTHORITYURL",
        "OCTO_AI__AUTHORITYURL",
        "OCTO_ADAPTER__AUTHORITYURL",
        "OCTO_ADAPTER__ISSUERURI"
    ];

    public const string MeshAdapterService = "meshAdapter";
    public const string S3Provider = "s3Store";

    private sealed record EnvRow(string Field, Func<ProfileSettings, string?> Value, string[] Keys);

    private static string? Bool(bool? value) => value?.ToString().ToLowerInvariant();

    private static string[] Keys(IEnumerable<string> sections, string key) => sections.Select(s => $"OCTO_{s}__{key}").ToArray();

    /// <summary>Settings that become environment variables: field, value, every key it is written to.</summary>
    private static readonly EnvRow[] EnvRows =
    [
        new("systemDatabase", s => s.SystemDatabase, ["OCTO_SYSTEM__SYSTEMDATABASENAME"]),
        new("mongo.host", s => s.Mongo?.Host, ["OCTO_SYSTEM__DATABASEHOST"]),
        new("mongo.directConnection", s => Bool(s.Mongo?.DirectConnection), ["OCTO_SYSTEM__USEDIRECTCONNECTION"]),
        new("mongo.replicaSet", s => s.Mongo?.ReplicaSet, ["OCTO_SYSTEM__REPLICASETNAME"]),
        new("broker.host", s => s.Broker?.Host, Keys(BrokerSections, "BROKERHOST")),
        new("broker.port", s => s.Broker?.Port?.ToString(), Keys(BrokerPortSections, "BROKERPORT")),
        new("broker.vhost", s => s.Broker?.Vhost, Keys(BrokerPortSections, "BROKERVIRTUALHOST")),
        new("broker.instancePrefix", s => s.Broker?.InstancePrefix, Keys(BrokerSections, "INSTANCEPREFIX")),
        new("authorityUrl", s => s.AuthorityUrl, AuthorityKeys),
        new("streamData.enabled", s => Bool(s.StreamData?.Enabled), ["OCTO_STREAMDATA__ENABLED"]),
        new("streamData.schemaInstancePrefix", s => s.StreamData?.SchemaInstancePrefix, ["OCTO_STREAMDATA__SCHEMAINSTANCEPREFIX"]),
        new("httpActivator.enabled", s => Bool(s.HttpActivator?.Enabled), ["OCTO_COMMUNICATIONCONTROLLER__ACTIVATORENABLED"]),
        new("httpActivator.addressTemplate", s => s.HttpActivator?.AddressTemplate, ["OCTO_COMMUNICATIONCONTROLLER__ACTIVATORWORKLOADADDRESSTEMPLATE"]),
        new("logLevel", s => s.LogLevel, ["OCTO_LOGGING__LOGLEVEL__DEFAULT"])
    ];

    /// <summary>
    ///     Shared key lists the slot derivation rows refer to as "@name" (devstack.default.yaml, slotDerivations), so a
    ///     section added here reaches the profile settings and the slots alike.
    /// </summary>
    public static readonly IReadOnlyDictionary<string, string[]> KeyLists = new Dictionary<string, string[]>(StringComparer.Ordinal)
    {
        ["instancePrefix"] = Keys(BrokerSections, "INSTANCEPREFIX"),
        ["authority"] = AuthorityKeys
    };

    /// <summary>Every environment key a field writes (for docs and tests).</summary>
    public static IReadOnlyDictionary<string, string[]> EnvKeys => EnvRows.ToDictionary(r => r.Field, r => r.Keys);

    public static SettingsExpansion Expand(ProfileSettings? settings)
    {
        var env = new Dictionary<string, string?>(StringComparer.Ordinal);
        var variables = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        var providers = new Dictionary<string, bool>(StringComparer.Ordinal);
        if (settings == null)
        {
            return new SettingsExpansion(env, variables, providers);
        }

        foreach (var row in EnvRows)
        {
            if (row.Value(settings) is { } value)
            {
                foreach (var key in row.Keys)
                {
                    env[key] = value;
                }
            }
        }

        // Start-Octo -httpActivator: the activator retries a waking workload for 90 s locally (the in-cluster default is 30).
        if (settings.HttpActivator?.Enabled == true)
        {
            env["OCTO_COMMUNICATIONCONTROLLER__ACTIVATORFORWARDRETRYSECONDS"] = "90";
        }

        switch (settings.ArtifactStorage)
        {
            case null:
                break;
            case "localS3":
                providers[S3Provider] = true;
                break;
            case "fileSystem":
                providers[S3Provider] = false;
                break;
            default:
                throw new InvalidOperationException($"settings.artifactStorage must be 'fileSystem' or 'localS3', not '{settings.ArtifactStorage}'.");
        }

        var adapter = new Dictionary<string, string>(StringComparer.Ordinal);
        if (settings.MeshAdapter?.TenantId is { } tenant)
        {
            adapter["tenantId"] = tenant;
        }

        if (settings.MeshAdapter?.AdapterRtId is { } rtId)
        {
            adapter["adapterId"] = rtId;
        }

        if (adapter.Count > 0)
        {
            variables[MeshAdapterService] = adapter;
        }

        return new SettingsExpansion(env, variables, providers);
    }
}
