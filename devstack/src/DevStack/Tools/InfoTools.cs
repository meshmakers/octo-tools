using System.ComponentModel;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

public sealed record InfraStatusResult(bool Success, int ExitCode, JsonNode? Data, string? OutputTail);

/// <summary>The workspace (base lanes, lanes, worktrees) and the kind infrastructure.</summary>
[McpServerToolType]
public sealed class InfoTools(ConfigStore store)
{
    [McpServerTool(Name = "workspace_list", ReadOnly = true)]
    [Description("Lists the workspace below rootPath: the base lane (isBaseLane; the checkout every lane starts from), other base lane folders " +
                 "(folders with Octo.User.props) and the lanes (lane = its name, base = its base lane), each with the git worktrees in it (wt-* " +
                 "folders, .claude/worktrees): repo, branch, which configured services run from that repo, and for which configurations it " +
                 "has a bin folder. A lane's worktree runs in the shared stack with overrides.<service>.source = 'lane:<name>'; another " +
                 "worktree with its relativeToBaseLane as source. Read-only.")]
    public List<CheckoutInfo> Workspace() => ToolGuard.Run(() => CheckoutDiscovery.Discover(store.Load()));

    [McpServerTool(Name = "infra_status", ReadOnly = true)]
    [Description("Shows the status of the local kind infrastructure every stack shares (MongoDB, CrateDB, RabbitMQ pods, Helm releases, host " +
                 "ports) via Get-OctoKubernetesStatus -SkipS3Probe -Json. The infrastructure itself is not managed by this server. Read-only.")]
    public Task<InfraStatusResult> Infra(
        [Description("Return the full pod objects instead of name/phase/ready/restarts/images (large).")] bool full = false,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            var config = store.Load();
            var result = await PwshRunner.RunAsync(ServicePlanner.OctoToolsPath(config), "Get-OctoKubernetesStatus -SkipS3Probe -Json", null,
                TimeSpan.FromMinutes(2), cancellationToken);
            var json = PwshRunner.ExtractOctoJson(result.Output);
            var data = json?["data"]?.DeepClone();
            if (data is JsonObject obj && !full)
            {
                SummarizePods(obj);
            }

            return new InfraStatusResult(result.ExitCode == 0 && json != null, result.ExitCode, data,
                json == null ? PwshRunner.Tail(result.Output, 40) : null);
        });

    /// <summary>Replaces the full pod objects (~80 KB) by name, phase, ready, restarts and image per pod.</summary>
    internal static void SummarizePods(JsonObject data)
    {
        if (data["pods"] is not JsonObject pods)
        {
            return;
        }

        var summary = new JsonObject();
        foreach (var (ns, list) in pods)
        {
            var rows = new JsonArray();
            foreach (var pod in list as JsonArray ?? [])
            {
                var statuses = pod?["status"]?["containerStatuses"] as JsonArray ?? [];
                rows.Add(new JsonObject
                {
                    ["name"] = pod?["metadata"]?["name"]?.GetValue<string>(),
                    ["phase"] = pod?["status"]?["phase"]?.GetValue<string>(),
                    ["ready"] = statuses.Count > 0 && statuses.All(c => c?["ready"]?.GetValue<bool>() == true),
                    ["restarts"] = statuses.Sum(c => c?["restartCount"]?.GetValue<int>() ?? 0),
                    ["images"] = new JsonArray(statuses.Select(c => (JsonNode?)JsonValue.Create(c?["image"]?.GetValue<string>())).ToArray())
                });
            }

            summary[ns] = rows;
        }

        data["pods"] = summary;
    }
}
