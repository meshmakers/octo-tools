using FluentAssertions;
using Meshmakers.Octo.DevStack.Tools;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using ModelContextProtocol.Client;
using ModelContextProtocol.Protocol;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The MCP server as a client sees it, over the streamable HTTP transport of <see cref="McpSurface"/> (the one Program.cs
///     registers) on a loopback port of its own: prompts/list and prompts/get of the dashboard command, and the agent view
///     (/mcp?view=agent) without the admin and developer tools and prompts. Only lists and the prompt are asked for: no tool runs.
/// </summary>
public sealed class McpSurfaceTests
{
    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    [Fact]
    public async Task Prompts_list_has_the_dashboard_command_and_the_agent_view_lists_neither_it_nor_the_admin_and_developer_tools()
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        builder.Logging.ClearProviders();
        builder.Services.AddDevStackMcp();
        await using var app = builder.Build();
        app.MapMcp("/mcp");
        await app.StartAsync(Ct);
        var address = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single().TrimEnd('/');

        await using (var full = await ConnectAsync($"{address}/mcp"))
        {
            var dashboard = (await full.ListPromptsAsync(cancellationToken: Ct)).Should().ContainSingle(p => p.Name == "dashboard").Subject;
            dashboard.Description.Should().Contain("status page");
            dashboard.ProtocolPrompt.Arguments!.Select(a => (a.Name, a.Required == true)).Should().Equal(("view", false), ("lane", false));

            var asked = await full.GetPromptAsync("dashboard", new Dictionary<string, object?> { ["view"] = "lanes", ["lane"] = "ab1-one" }, cancellationToken: Ct);
            var text = asked.Messages.Should().ContainSingle().Which.Content.Should().BeOfType<TextContentBlock>().Subject.Text;
            text.Should().Contain("dashboard_open").And.Contain("view=\"lanes\"").And.Contain("lane=\"ab1-one\"").And.Contain("url");
            var bare = await full.GetPromptAsync("dashboard", cancellationToken: Ct);
            bare.Messages.Single().Content.Should().BeOfType<TextContentBlock>().Which.Text.Should().Contain("dashboard_open of the octo-devstack server without arguments");

            var tools = (await full.ListToolsAsync(cancellationToken: Ct)).Select(t => t.Name).ToList();
            tools.Should().BeEquivalentTo(Meshmakers.Octo.DevStack.Ui.ToolBridge.All.Select(t => t.Name), "/mcp serves every tool");
        }

        await using (var agent = await ConnectAsync($"{address}/mcp?view=agent"))
        {
            (await agent.ListPromptsAsync(cancellationToken: Ct)).Select(p => p.Name).Should().NotContain("dashboard", "the agent view has no dashboard_open to call");
            var tools = (await agent.ListToolsAsync(cancellationToken: Ct)).Select(t => t.Name).ToList();
            tools.Should().Contain(["lane_build", "stack_status", "job_status", "lease_acquire"]).And.NotContain("dashboard_open")
                .And.NotContain(n => n.StartsWith("admin_"));
            tools.Should().HaveCount(Meshmakers.Octo.DevStack.Ui.ToolBridge.All.Count(t => !AgentView.IsHidden(t.Name)));
        }

        await app.StopAsync(Ct);
    }

    private static async Task<McpClient> ConnectAsync(string endpoint) =>
        await McpClient.CreateAsync(new HttpClientTransport(new HttpClientTransportOptions { Endpoint = new Uri(endpoint), TransportMode = HttpTransportMode.StreamableHttp }),
            cancellationToken: Ct);
}
