using System.ComponentModel;
using Meshmakers.Octo.DevStack.Runtime;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>What a new machine still lacks (AB#9377).</summary>
[McpServerToolType]
public sealed class SetupTools(SetupCheck check)
{
    [McpServerTool(Name = "setup_check", ReadOnly = true)]
    [Description("Checks what this machine still needs for the dev stacks, each with the command that fixes it: octo-tools (found, new enough " +
                 "to describe the workspace), the base lane, installations.json, pwsh, the .NET 10 SDK, lsof (macOS; Linux reads /proc " +
                 "without it), the trusted ASP.NET dev certificate, Docker, the kind infrastructure (MongoDB, RabbitMQ, CrateDB), octo-cli " +
                 "contexts, whether octo-cli resolves on the daemon's own PATH (the daemon's process environment, not yours: a lane stack's " +
                 "setup runs it), stale paths (checkout and repository folders the daemon's state or a lane's manifest still names but that no longer exist - a moved " +
                 "checkout) and the Claude Code registration of this daemon. state: ok, warn (works with less), fail (does not work), info. " +
                 "ok = nothing fails. Read-only; run it on a new machine first, and when stack_start or stack_setup fails for no visible reason.")]
    public Task<SetupReport> Check() => check.RunAsync();
}
