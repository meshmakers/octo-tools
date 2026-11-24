using System.Text;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

public sealed record EnvProviderResult(Dictionary<string, string?> Env, List<string> Ran, List<string> Warnings);

/// <summary>Runs the env providers of a start in one pwsh session with the octo-tools profile.</summary>
public static class EnvProviderRunner
{
    public static List<string> Applicable(DevStackConfig config, IReadOnlyCollection<string> services) =>
        config.EnvProviders
            .Where(p => p.Value.Enabled && !string.IsNullOrWhiteSpace(p.Value.Script) &&
                        (p.Value.WhenServices.Count == 0 || p.Value.WhenServices.Any(services.Contains)))
            .Select(p => p.Key).ToList();

    public static string BuildBody(DevStackConfig config, IReadOnlyList<string> providers)
    {
        var body = new StringBuilder();
        body.AppendLine("$__result = [ordered]@{}");
        body.AppendLine("$__errors = [ordered]@{}");
        foreach (var name in providers)
        {
            var quoted = PwshRunner.Quote(name);
            body.AppendLine("try {");
            // Cmdlets inside a provider may emit other objects; the provider's result is its last hashtable.
            body.AppendLine($"  $__value = @(& {{\n{config.EnvProviders[name].Script}\n}}) | Where-Object {{ $_ -is [System.Collections.IDictionary] }} | Select-Object -Last 1");
            body.AppendLine($"  $__result[{quoted}] = $__value");
            body.AppendLine($"}} catch {{ $__errors[{quoted}] = $_.Exception.Message }}");
        }

        body.AppendLine(
            $"Write-Output ('{PwshRunner.Marker}' + (@{{ env = $__result; errors = $__errors }} | ConvertTo-Json -Compress -Depth 6))");
        return body.ToString();
    }

    public static async Task<EnvProviderResult> RunAsync(DevStackConfig config, IReadOnlyCollection<string> services, CancellationToken cancellationToken)
    {
        var providers = Applicable(config, services);
        var env = new Dictionary<string, string?>(StringComparer.Ordinal);
        var warnings = new List<string>();
        if (providers.Count == 0)
        {
            return new EnvProviderResult(env, providers, warnings);
        }

        var result = await PwshRunner.RunAsync(ServicePlanner.OctoToolsPath(config), BuildBody(config, providers), null,
            TimeSpan.FromMinutes(2), cancellationToken);
        JsonNode? parsed;
        try
        {
            parsed = PwshRunner.ExtractMarker(result.Output);
        }
        catch (System.Text.Json.JsonException e)
        {
            throw new InvalidOperationException($"Env providers returned invalid JSON: {e.Message}");
        }

        if (parsed == null)
        {
            throw new InvalidOperationException(
                $"Env providers ({string.Join(", ", providers)}) failed (exit {result.ExitCode}{(result.TimedOut ? ", timed out" : "")}). " +
                $"Is pwsh on PATH and octoToolsPath right? Output:\n{PwshRunner.Tail(result.Output, 20)}");
        }

        foreach (var (provider, errorNode) in parsed["errors"]?.AsObject() ?? [])
        {
            warnings.Add($"env provider '{provider}' failed: {errorNode}");
        }

        foreach (var (provider, valueNode) in parsed["env"]?.AsObject() ?? [])
        {
            if (valueNode is not JsonObject values)
            {
                if (valueNode != null)
                {
                    warnings.Add($"env provider '{provider}' did not return a hashtable; ignored.");
                }

                continue;
            }

            foreach (var (key, value) in values)
            {
                env[key] = value?.ToString();
            }
        }

        return new EnvProviderResult(env, providers, warnings);
    }
}
