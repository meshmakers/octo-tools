using System.Text.Json;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     Checks around a stack start that look outside the stack: the kind infrastructure ports, and whether octo-cli has a
///     context for the mesh adapter's tenant. Both only report; nothing is changed.
/// </summary>
public sealed class PreStartChecks(IReadOnlyList<(string Name, int Port)>? infraPorts = null, string? octoCliContextsFile = null, int? s3StorePort = null)
{
    /// <summary>Host ports of the kind infrastructure (kubernetes/kind-cluster.yaml of octo-tools).</summary>
    public static readonly (string Name, int Port)[] KindInfra = [("MongoDB", 27017), ("RabbitMQ", 5672), ("CrateDB", 4301)];

    /// <summary>The local S3 store (Install-OctoKubernetesS3Store); optional - without it the bot uses the file system.</summary>
    public static readonly (string Name, int Port) S3Store = ("S3 store", 8333);

    /// <summary>The node container of the kind cluster Install-OctoKubernetes creates by default (cluster name "kind").</summary>
    public const string KindNodeContainer = "kind-control-plane";

    public IReadOnlyList<(string Name, int Port)> InfraPorts { get; } = infraPorts ?? KindInfra;

    public int S3StorePort { get; } = s3StorePort ?? S3Store.Port;

    /// <summary>octo-cli keeps its contexts in $OCTO_CLI_HOME/.octo-cli/contexts.json (default: the home folder).</summary>
    public string ContextsFile { get; } = octoCliContextsFile ?? Path.Combine(
        Environment.GetEnvironmentVariable("OCTO_CLI_HOME") is { Length: > 0 } home ? home : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".octo-cli", "contexts.json");

    /// <summary>The infrastructure endpoints that do not answer (MongoDB, RabbitMQ, CrateDB).</summary>
    public async Task<List<string>> UnreachableInfraAsync()
    {
        var results = await Task.WhenAll(InfraPorts.Select(async t => (t.Name, t.Port, Open: await Probes.IsPortOpenAsync(t.Port, TimeSpan.FromMilliseconds(500)))));
        return results.Where(r => !r.Open).Select(r => $"{r.Name} (127.0.0.1:{r.Port})").ToList();
    }

    /// <summary>Whether the optional local S3 store answers.</summary>
    public Task<bool> S3StoreAnswersAsync() => Probes.IsPortOpenAsync(S3StorePort, TimeSpan.FromMilliseconds(500));

    /// <summary>True/false when the contexts file could be read; null when there is none or it is unreadable. Reads names only.</summary>
    public bool? HasOctoCliContext(string name)
    {
        try
        {
            if (!File.Exists(ContextsFile))
            {
                return null;
            }

            using var document = JsonDocument.Parse(File.ReadAllText(ContextsFile));
            if (!document.RootElement.TryGetProperty("Contexts", out var contexts) || contexts.ValueKind != JsonValueKind.Object)
            {
                return false;
            }

            return contexts.EnumerateObject().Any(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
