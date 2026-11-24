using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>
///     The agent view of the server (<c>/mcp?view=agent</c>): every tool except the admin_* ones, which change devstack.yaml,
///     profiles and slots for every session and need the developer's go, and except the developer's own tools and prompts
///     (dashboard_open and the prompt dashboard: the status page in the developer's browser). A session registered with that
///     URL neither lists nor calls them; <c>/mcp</c> serves everything.
/// </summary>
internal static class AgentView
{
    public const string AdminPrefix = "admin_";

    /// <summary>Tools for the developer only: they change no stack (no owner, no lease) and an agent has no use for them.</summary>
    public static readonly IReadOnlySet<string> DeveloperTools = new HashSet<string>(StringComparer.Ordinal) { DashboardTools.Name };

    /// <summary>Prompts (slash commands of Claude Code) for the developer only.</summary>
    public static readonly IReadOnlySet<string> DeveloperPrompts = new HashSet<string>(StringComparer.Ordinal) { DashboardPrompts.Name };

    /// <summary>The request asks for the agent view: <c>?view=agent</c>.</summary>
    public static bool Requested(IQueryCollection query) => string.Equals(query["view"].ToString(), "agent", StringComparison.OrdinalIgnoreCase);

    public static bool IsAdmin(string tool) => tool.StartsWith(AdminPrefix, StringComparison.Ordinal);

    /// <summary>Whether the agent view leaves the tool out: an admin tool or a developer tool.</summary>
    public static bool IsHidden(string tool) => IsAdmin(tool) || DeveloperTools.Contains(tool);

    /// <summary>A new collection with the tools of <paramref name="all"/> the agent view serves (the shared collection is not changed).</summary>
    public static McpServerPrimitiveCollection<McpServerTool> Without(IEnumerable<McpServerTool> all)
    {
        var view = new McpServerPrimitiveCollection<McpServerTool>();
        foreach (var tool in all.Where(t => !IsHidden(t.ProtocolTool.Name)))
        {
            view.Add(tool);
        }

        return view;
    }

    /// <summary>A new collection with the prompts of <paramref name="all"/> the agent view serves.</summary>
    public static McpServerPrimitiveCollection<McpServerPrompt> WithoutDeveloperPrompts(IEnumerable<McpServerPrompt> all)
    {
        var view = new McpServerPrimitiveCollection<McpServerPrompt>();
        foreach (var prompt in all.Where(p => !DeveloperPrompts.Contains(p.ProtocolPrompt.Name)))
        {
            view.Add(prompt);
        }

        return view;
    }

    /// <summary>HttpServerTransportOptions.ConfigureSessionOptions: the agent view for a request that asks for it.</summary>
    public static Task Configure(HttpContext context, McpServerOptions options, CancellationToken cancellationToken)
    {
        if (Requested(context.Request.Query))
        {
            if (options.ToolCollection is { } tools)
            {
                options.ToolCollection = Without(tools);
            }

            if (options.PromptCollection is { } prompts)
            {
                options.PromptCollection = WithoutDeveloperPrompts(prompts);
            }
        }

        return Task.CompletedTask;
    }
}
