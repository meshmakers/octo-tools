using System.Reflection;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;
using ModelContextProtocol;

namespace Meshmakers.Octo.DevStack.Ui;

public sealed record ConfiguredService(string Name, string? Description, bool Enabled, IReadOnlyList<int> Ports, string Repo)
{
    /// <summary>Runs in the default slot only; the board of the status page leaves its place empty in every other slot.</summary>
    public bool Exclusive { get; init; }
}

public sealed record Overview(
    StackStatus Stack,
    string RootPath,
    string BaseLane,
    string DefaultConfiguration,
    string ConfigPath,
    string Home,
    IReadOnlyList<ConfiguredService> Configured,
    IReadOnlyList<BuildStatus> Builds,
    IReadOnlyList<BuildRefusal> BuildRefusals,
    IReadOnlyList<ProfileSummary> Profiles,
    IReadOnlyList<SlotSummary> Slots,
    [property: System.Text.Json.Serialization.JsonPropertyName("lanes")] IReadOnlyList<EnvironmentRow> Environments)
{
    /// <summary>What needs attention, worst first (<see cref="Ui.Attention"/>); the same list as stack_attention.</summary>
    public IReadOnlyList<AttentionItem> Attention { get; init; } = [];

    /// <summary>The overview of the status page; stack_attention builds the same one.</summary>
    public static async Task<Overview> BuildAsync(StackSupervisor supervisor, BuildQueue builds, ConfigStore store, EnvironmentManager environments)
    {
        var config = store.Load();
        // Like stack_status: the entry assembly each service of the shared stack really loaded (one lsof call; not on Windows) and,
        // on Windows, every service's own process below its cmd.exe wrapper (one process snapshot), also in the lane stacks' rows.
        var status = StackTools.WithServiceProcesses(StackTools.WithEntryAssemblies(await supervisor.StatusAsync()));
        var overview = new Overview(
            status.Masked(),
            ServicePlanner.RootPath(config),
            config.DefaultCheckout,
            config.Configuration,
            store.ConfigPath,
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            config.Services.Select(s => new ConfiguredService(s.Key, s.Value.Description, s.Value.Enabled, s.Value.Ports, s.Value.Repo)
                { Exclusive = SlotRules.IsExclusive(config, s.Key) }).ToList(),
            builds.List(),
            builds.Refusals(),
            ProfileTools.Summaries(config, status),
            status.Slots ?? [],
            await environments.ListAsync());
        return overview with { Attention = Ui.Attention.Of(overview) };
    }
}

/// <summary>
///     The read-only status page at / and its JSON endpoints. Changing the stack stays with the MCP tools (lease). Every read
///     endpoint here has an MCP tool (StatusPageTools and the others; ApiParityTests holds the table), and every read-only tool
///     is GET /api/tools/{name} (<see cref="ToolBridge"/>).
/// </summary>
public static class UiEndpoints
{
    private static readonly Dictionary<string, string> ContentTypes = new()
    {
        ["index.html"] = "text/html; charset=utf-8",
        ["app.css"] = "text/css; charset=utf-8",
        ["app.js"] = "text/javascript; charset=utf-8"
    };

    // Everything the page loads comes from the daemon itself; no inline script, no external fonts.
    private const string Csp = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

    public static void MapStatusUi(this WebApplication app)
    {
        app.MapGet("/", () => Asset("index.html"));
        app.MapGet("/ui/{file}", (string file) => ContentTypes.ContainsKey(file) && file != "index.html" ? Asset(file) : Results.NotFound());

        app.MapGet("/api/overview", (StackSupervisor supervisor, BuildQueue builds, ConfigStore store, EnvironmentManager environments) =>
            Overview.BuildAsync(supervisor, builds, store, environments));

        // slot: the stack slot of the service (an environment's slot is named after it); without it the default slot.
        app.MapGet("/api/logs/{service}", async (string service, int? lines, string? grep, bool? previous, int? pid, string? slot, StackSupervisor supervisor,
            ConfigStore store) =>
        {
            try
            {
                return Results.Ok(await new StackTools(supervisor, store).Logs(service, lines: Math.Clamp(lines ?? 300, 1, 5000), grep: grep, previous: previous ?? false,
                    pid: pid, slot: string.IsNullOrWhiteSpace(slot) ? null : slot, maxChars: 200_000));
            }
            catch (McpException e)
            {
                return Results.NotFound(new { error = e.Message });
            }
            catch (ArgumentException e)
            {
                return Results.BadRequest(new { error = e.Message });
            }
        });

        // The configuration inspector of the status page: read-only, secret-looking values masked (service_env rules).
        app.MapGet("/api/config", async (ConfigStore store, StackSupervisor supervisor, SlotOperations operations) =>
            Results.Ok(await ConfigInspector.BuildAsync(store, supervisor, operations)));

        // The daemon itself: version, whether a restart is safe now (no build runs or waits), the last starts and stops.
        // Stop-/Start-OctoDevStackDaemon (octo-tools) read restart.safe before they stop it.
        app.MapGet("/api/daemon", (DaemonJournal journal, BuildQueue builds, Leasing.LeaseRegistry leases, Runtime.DockerVm docker) =>
            Results.Ok(journal.Status(builds, leases, docker)));

        // The output of a build: its repos (errors first) and the log of one repo, or the job log.
        app.MapGet("/api/builds/{id}/output", (string id, string? repo, int? lines, BuildQueue builds) =>
        {
            try
            {
                return Results.Ok(builds.Output(id, string.IsNullOrWhiteSpace(repo) ? null : repo, lines ?? 400));
            }
            catch (InvalidOperationException e)
            {
                return Results.NotFound(new { error = e.Message });
            }
        });

        app.MapGet("/api/builds/{id}", (string id, BuildQueue builds) =>
        {
            try
            {
                return Results.Ok(builds.Get(id, raw: true, tailLines: 120));
            }
            catch (InvalidOperationException e)
            {
                return Results.NotFound(new { error = e.Message });
            }
        });

        // Every read-only MCP tool as GET /api/tools/{name}.
        app.MapToolBridge();

        app.Use(async (context, next) =>
        {
            context.Response.Headers.ContentSecurityPolicy = Csp;
            context.Response.Headers.XContentTypeOptions = "nosniff";
            context.Response.Headers["Referrer-Policy"] = "no-referrer";
            await next();
        });
    }

    private static IResult Asset(string file)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("ui/" + file);
        if (stream == null)
        {
            return Results.NotFound();
        }

        using var reader = new StreamReader(stream);
        return Results.Text(reader.ReadToEnd(), ContentTypes[file]);
    }
}
