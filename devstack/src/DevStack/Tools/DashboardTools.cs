using System.ComponentModel;
using System.Text.Json;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Ui;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>
///     The status page for the developer: dashboard_open opens it in the developer's browser. A developer tool - it changes no
///     stack, so it takes no owner and no lease, and the agent view does not list it (<see cref="AgentView"/>).
/// </summary>
[McpServerToolType]
public sealed class DashboardTools(Dashboard dashboard, ConfigStore store)
{
    public const string Name = "dashboard_open";

    [McpServerTool(Name = Name, Destructive = false, Idempotent = true, OpenWorld = false)]
    [Description("Opens the status page of octo-devstack (the dashboard) in the developer's default browser on this machine - for the developer: " +
                 "call it only when the developer asks to see the dashboard or the status page (the /mcp__octo-devstack__dashboard command). " +
                 "view: stack (default: the shared stack and the lane stacks, what needs attention), lanes (every lane with its repos, lane " +
                 "stack, setup and jobs), builds (the jobs: builds and test runs), profiles or config; lane (lane_list) jumps to that lane in " +
                 "the lanes view (with view=stack to its lane stack). Only the daemon's own page is opened. Answers url, opened and a note: " +
                 "when opened is false (no desktop session, no display, xdg-open missing, a daemon started with --no-browser) give the " +
                 "developer the url to open by hand. Changes nothing.")]
    public DashboardOpenResult Open(
        [Description("The view: stack (default), lanes, builds, profiles or config.")] string? view = null,
        [Description("A lane (lane_list) to show: its place in the lanes view, or with view=stack its lane stack.")] string? lane = null) =>
        ToolGuard.Run(() => dashboard.Open(view, lane, EnvironmentDiscovery.Discover(store.Load())));
}

/// <summary>
///     The MCP prompt <c>dashboard</c>: Claude Code shows it as the slash command <c>/mcp__octo-devstack__dashboard [view] [lane]</c>.
///     It asks the assistant to call dashboard_open and to give the developer the URL. Not in the agent view (<see cref="AgentView"/>).
/// </summary>
[McpServerPromptType]
public static class DashboardPrompts
{
    public const string Name = "dashboard";

    [McpServerPrompt(Name = Name)]
    [Description("Opens the octo-devstack status page (the dashboard) in your browser: the shared stack and the lane stacks, the lanes, the " +
                 "jobs, the profiles or the configuration.")]
    public static string Dashboard(
        [Description("The view: stack (default), lanes, builds, profiles or config.")] string? view = null,
        [Description("A lane to show (lane_list), in the lanes view.")] string? lane = null)
    {
        // The arguments are the developer's own words: passed on quoted, as JSON strings, never as instructions.
        var arguments = new List<string>();
        if (!string.IsNullOrWhiteSpace(view))
        {
            arguments.Add($"view={JsonSerializer.Serialize(view.Trim())}");
        }

        if (!string.IsNullOrWhiteSpace(lane))
        {
            arguments.Add($"lane={JsonSerializer.Serialize(lane.Trim())}");
        }

        return "The developer wants to see the octo-devstack status page (the dashboard). Call the MCP tool " +
               $"{DashboardTools.Name} of the octo-devstack server{(arguments.Count == 0 ? " without arguments" : $" with {string.Join(" and ", arguments)}")}, " +
               "nothing else. Then give the developer the url from its answer as a link in one short line. If opened is false, say in one " +
               "line that no browser opened and why (note), and that they can open the url by hand. If the tool refuses the arguments, " +
               "say what it allows.";
    }
}
