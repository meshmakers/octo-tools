using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>
///     The MCP server of the daemon in one place (Program.cs and the protocol test use it): server info and instructions, the
///     streamable HTTP transport with the agent view (<c>/mcp?view=agent</c>, <see cref="AgentView"/>), every tool and prompt of
///     this assembly, and the call-tool filter that names binding errors (<see cref="ArgumentErrors"/>).
/// </summary>
internal static class McpSurface
{
    public static IMcpServerBuilder AddDevStackMcp(this IServiceCollection services) =>
        services.AddMcpServer(options =>
            {
                options.ServerInfo = new() { Name = "octo-devstack", Version = typeof(McpSurface).Assembly.GetName().Version?.ToString() ?? "0.0.0" };
                options.ServerInstructions = ServerInstructions.Text;
            })
            .WithHttpTransport(transport => transport.ConfigureSessionOptions = AgentView.Configure)
            .WithToolsFromAssembly(typeof(McpSurface).Assembly)
            .WithPromptsFromAssembly(typeof(McpSurface).Assembly)
            .WithRequestFilters(filters => filters.AddCallToolFilter(ArgumentErrors.Filter));
}
