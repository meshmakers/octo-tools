using FluentAssertions;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;
using Meshmakers.Octo.DevStack.Ui;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The HTTP API and MCP read the same things: every read endpoint of the status page has a tool, every read-only tool is
///     GET /api/tools/{name}, and the page's attention list is built by the daemon (stack_attention returns the same list).
/// </summary>
public sealed class ApiParityTests : IDisposable
{
    /// <summary>The tools that return what an /api route returns. A new route needs a row here, and a tool if none fits.</summary>
    private static readonly Dictionary<string, string[]> Equivalents = new()
    {
        ["/api/overview"] = ["stack_status", "stack_attention", "job_list", "job_refusals", "profile_list", "stack_list", "lane_list", "config_get"],
        ["/api/logs/{service}"] = ["service_logs"],
        ["/api/config"] = ["admin_config_inspect"],
        ["/api/daemon"] = ["daemon_status"],
        ["/api/builds/{id}/output"] = ["job_output"],
        ["/api/builds/{id}"] = ["job_status"]
    };

    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    [Fact]
    public async Task Every_api_route_has_a_read_only_tool()
    {
        var builder = WebApplication.CreateBuilder();
        // The endpoints' services are only looked at (parameter inference), never created.
        foreach (var type in new[]
                 {
                     typeof(StackSupervisor), typeof(BuildQueue), typeof(ConfigStore), typeof(EnvironmentManager), typeof(SlotOperations),
                     typeof(DaemonJournal), typeof(LeaseRegistry), typeof(DockerVm)
                 })
        {
            builder.Services.AddSingleton(type, _ => throw new InvalidOperationException("not created in this test"));
        }

        await using var app = builder.Build();
        app.MapStatusUi();
        var routes = ((IEndpointRouteBuilder)app).DataSources.SelectMany(d => d.Endpoints).OfType<RouteEndpoint>()
            .Select(e => e.RoutePattern.RawText!).Where(r => r.StartsWith("/api/", StringComparison.Ordinal) && !r.StartsWith("/api/tools", StringComparison.Ordinal))
            .ToList();

        routes.Should().BeEquivalentTo(Equivalents.Keys, "every read endpoint of the status page names the tools that return the same");
        var readOnly = ToolBridge.All.Where(t => t.ReadOnly).Select(t => t.Name).ToList();
        foreach (var (route, tools) in Equivalents)
        {
            readOnly.Should().Contain(tools, $"{route} is read-only, so are its tools");
        }
    }

    [Fact]
    public void Every_read_only_tool_is_a_get_endpoint_and_changing_tools_stay_mcp_only()
    {
        var list = ToolBridge.List();

        list.Tools.Select(t => t.Name).Should().BeEquivalentTo(ToolBridge.All.Where(t => t.ReadOnly).Select(t => t.Name));
        list.Tools.Should().Contain(t => t.Name == "stack_attention" && t.Url == "/api/tools/stack_attention");
        list.McpOnly.Should().Contain(["stack_start", "base_build", "lane_build", "lease_acquire", "base_test", "lane_test"]).And.NotContain("stack_status");
        list.Tools.Single(t => t.Name == "job_status").Parameters.Should().Contain(p => p.Name == "id" && p.Required)
            .And.Contain(p => p.Name == "live" && !p.Required && p.Type == "integer")
            .And.Contain(p => p.Name == "waitSeconds" && !p.Required && p.Type == "integer");
    }

    [Fact]
    public void Every_parameter_of_a_read_only_tool_can_come_from_a_query_string()
    {
        foreach (var tool in ToolBridge.All.Where(t => t.ReadOnly))
        {
            tool.Method.ReturnType.Should().NotBe(typeof(void), tool.Name);
            foreach (var p in ToolBridge.Parameters(tool))
            {
                p.Type.Should().NotBe("object", $"{tool.Name}.{p.Name} needs a converter in ToolBridge");
            }
        }
    }

    [Fact]
    public void Query_values_bind_like_mcp_arguments()
    {
        var status = Tool("job_status");
        var args = ToolBridge.Bind(status, new Dictionary<string, string[]>
        {
            ["id"] = ["b1"], ["live"] = ["20"], ["errorsOnly"] = ["true"], ["include"] = ["raw,other"]
        }, CancellationToken.None);
        args.Should().BeEquivalentTo(new object?[] { "b1", 0, null, null, true, new List<string> { "raw", "other" }, 40, 20, false, CancellationToken.None },
            o => o.WithStrictOrdering());

        ToolBridge.Bind(status, new Dictionary<string, string[]> { ["id"] = ["b1"], ["include"] = ["raw", "x"] }, CancellationToken.None)[5]
            .Should().BeEquivalentTo(new List<string> { "raw", "x" }, "a repeated argument is a list");
        ToolBridge.Bind(status, new Dictionary<string, string[]> { ["id"] = ["b1"], ["include"] = ["[\"raw\"]"] }, CancellationToken.None)[5]
            .Should().BeEquivalentTo(new List<string> { "raw" }, "a JSON array is a list");

        var missing = () => ToolBridge.Bind(status, new Dictionary<string, string[]>(), CancellationToken.None);
        missing.Should().Throw<ArgumentException>().WithMessage("*'id' is required*");
        var unknown = () => ToolBridge.Bind(status, new Dictionary<string, string[]> { ["id"] = ["b1"], ["jobId"] = ["x"] }, CancellationToken.None);
        unknown.Should().Throw<ArgumentException>().WithMessage("*jobId*");
        var wrongType = () => ToolBridge.Bind(status, new Dictionary<string, string[]> { ["id"] = ["b1"], ["live"] = ["many"] }, CancellationToken.None);
        wrongType.Should().Throw<ArgumentException>().WithMessage("*'live' must be a integer*");

        var map = ToolBridge.Bind(Tool("build_plan"), new Dictionary<string, string[]> { ["kind"] = ["repo"], ["repoPaths"] = ["{\"octo-sdk\":\"/wt/octo-sdk\"}"] },
            CancellationToken.None);
        map.OfType<Dictionary<string, string>>().Should().ContainSingle().Which.Should().Contain("octo-sdk", "/wt/octo-sdk", "a map is a JSON object");
    }

    [Fact]
    public async Task A_bridged_call_runs_the_tool_with_its_services()
    {
        var store = _checkout.WriteConfig("""
                                            web:
                                              repo: tools
                                              args: ["Web.dll", "--Octo:ApiKey=s3cret"]
                                          """);
        await using var services = new ServiceCollection().AddSingleton(store).AddLogging().BuildServiceProvider();

        var result = await ToolBridge.InvokeAsync(Tool("config_get"), services, []);

        var view = result.Should().BeOfType<ConfigView>().Subject;
        view.Services.Should().Contain(s => s.Name == "web");
        System.Text.Json.JsonSerializer.Serialize(view).Should().NotContain("s3cret", "the tool masks, and the bridge returns what the tool returns");
    }

    // ---------- attention ----------

    [Fact]
    public void A_failed_test_run_stays_until_a_newer_run_of_the_same_target_succeeds()
    {
        var failed = Build("b2", "test", "branches/main: tests of octo-identity-services", "failed", "1 of 1195 test(s) failed in IdentityServices.IntegrationTests");
        var envRun = Build("b3", "test", "ab8949: tests of octo-identity-services", "succeeded", "2818 test(s) passed in 5 project(s)");

        var items = Attention.Of(Overview(builds: [envRun, failed]));

        var item = items.Should().ContainSingle().Subject;
        item.Should().BeEquivalentTo(new { Level = "stop", Kind = "test", BuildId = "b2", Href = "#/builds/b2" });
        item.Text.Should().Be("branches/main: tests of octo-identity-services failed: 1 of 1195 test(s) failed in IdentityServices.IntegrationTests",
            "a test run is not called a build");
        item.Hint.Should().Contain("job_status(id=\"b2\")");

        var rerun = Build("b4", "test", "branches/main: tests of octo-identity-services", "succeeded", "1195 test(s) passed in 1 project(s)");
        Attention.Of(Overview(builds: [rerun, envRun, failed])).Should().BeEmpty();
    }

    [Fact]
    public void Failed_builds_say_build_and_runs_of_removed_checkouts_are_history()
    {
        var build = Build("b5", "repo", "/root/branches/main/octo-sdk", "failed", "build failed in octo-sdk");
        var gone = Build("b6", "test", "wt-old: tests of octo-sdk", "failed", "x") with { Gone = "environment removed" };

        var items = Attention.Of(Overview(builds: [build, gone]));

        items.Should().ContainSingle().Which.Text.Should().Be("Build of branches/main/octo-sdk failed: build failed in octo-sdk");
    }

    [Fact]
    public void A_failed_repo_build_clears_once_a_later_range_or_all_build_of_its_lane_built_that_repo()
    {
        const string main = "/root/branches/main";
        var failed = LaneBuild("b10", "repo", $"{main}/octo-identity-services", "failed", main, "octo-identity-services", ("octo-identity-services", "failed"));
        var earlier = LaneBuild("b9", "range", "branches/main: octo-sdk -> octo-identity-services", "succeeded", main, null,
            ("octo-sdk", "done"), ("octo-identity-services", "done"));
        var otherLane = LaneBuild("b11", "range", "wt-x: octo-identity-services -> octo-identity-services", "succeeded", "/root/wt-x", null, ("octo-identity-services", "done"));
        var notBuilt = LaneBuild("b12", "range", "branches/main: octo-sdk -> octo-identity-services", "failed", main, "octo-sdk",
            ("octo-sdk", "failed"), ("octo-identity-services", "pending"));

        var items = Attention.Of(Overview(builds: [notBuilt, otherLane, failed, earlier]));
        items.Select(i => i.BuildId).Should().BeEquivalentTo(["b12", "b10"], "an earlier build, another lane and a range that did not get to the repo change nothing");
        items.Single(i => i.BuildId == "b10").Hint.Should().Contain("or a later range or all build of the lane builds octo-identity-services");

        // A later range of the lane that built it - even one that failed afterwards in another repo, which is its own entry.
        var rebuilt = LaneBuild("b13", "range", "branches/main: octo-identity-services -> octo-mcp-service", "failed", main, "octo-mcp-service",
            ("octo-identity-services", "done"), ("octo-mcp-service", "failed"));
        Attention.Of(Overview(builds: [rebuilt, notBuilt, otherLane, failed, earlier])).Select(i => i.BuildId).Should().BeEquivalentTo(["b13", "b12"]);

        // A worktree's build is no build of the lane's folder: a range of the lane does not clear it.
        var worktree = LaneBuild("b14", "repo", $"{main}/octo-identity-services/.claude/worktrees/x", "failed", main, "x", ("octo-identity-services", "failed"));
        Attention.RebuiltLater(worktree, [rebuilt, worktree]).Should().BeFalse();
    }

    [Fact]
    public void A_failed_all_build_clears_once_later_builds_of_the_lane_built_every_repo_it_failed_in()
    {
        // b4 on 2026-11-20: Invoke-BuildAll of the flat root failed in octo-construction-kit, a range of just that repo built it.
        var all = LaneBuild("b4", "all", ".: all", "failed", "/root", "octo-construction-kit", ("mm-common", "done"), ("octo-construction-kit", "failed"));
        var range = LaneBuild("b7", "range", ".: octo-construction-kit -> octo-construction-kit", "succeeded", "/root", null, ("octo-construction-kit", "done"));
        Attention.Of(Overview(builds: [all])).Should().ContainSingle().Which.BuildId.Should().Be("b4");
        Attention.Of(Overview(builds: [range, all])).Should().BeEmpty();

        // Two repos failed in parallel: both must be built again, by one later build or by several.
        var two = all with { Outcome = new BuildOutcome("octo-construction-kit", "build", "build failed", null) { FailedRepos = ["octo-construction-kit", "octo-plug-zenon"] } };
        Attention.Of(Overview(builds: [range, two])).Should().ContainSingle().Which.BuildId.Should().Be("b4");
        var zenon = LaneBuild("b8", "range", ".: octo-plug-zenon -> octo-plug-zenon", "succeeded", "/root", null, ("octo-plug-zenon", "done"));
        Attention.Of(Overview(builds: [zenon, range, two])).Should().BeEmpty();
        Attention.RebuiltLater(two, [range, two, zenon]).Should().BeFalse("a build before the failed one does not count");

        // A failure without a repository (preflight) is only cleared by a newer build of the same target.
        var preflight = LaneBuild("b5", "all", ".: all", "failed", "/root", null, ("mm-common", "pending")) with
        {
            Outcome = new BuildOutcome(null, "preflight", "the lease is no longer held", null)
        };
        Attention.Of(Overview(builds: [range, preflight])).Should().ContainSingle().Which.BuildId.Should().Be("b5");
    }

    [Fact]
    public void Services_come_before_foreign_processes_and_name_their_slot()
    {
        var exited = new ServiceStatus("identity", "exited", false, null, 7, null, "/r", "/r", "dotnet", [], "/l", [], DateTimeOffset.Now, null, 3, false, null);
        var origin = new ExternalOrigin("start-octo", "Start-Octo", 1, null, "main", "DebugL", true, null, null);
        var external = new ExternalService("web", 42, [5000], "dotnet Web.dll", null, null, null, null, null, null, true, null, null, "g1");
        var second = new SlotSummary("second", 1, 100, "s1", "configured", true, null, null, null, null, 0, 1,
            [new SlotServiceRow("asset", "unhealthy", 9, [], null)], null, null);

        var items = Attention.Of(Overview(
            services: [exited], slots: [second],
            external: new ExternalSnapshot([external], [new ExternalGroup("g1", origin, null, null, ["web"], null)])));

        items.Select(i => i.Text).Should().Equal(
            "identity exited (exit code 3, ).",
            "second/asset is not answering.",
            "web on 5000 runs outside octo-devstack (Start-Octo).");
        items[0].Hint.Should().Be("service_logs(service=\"identity\") shows its log.");
        items[1].Hint.Should().Be("service_logs(service=\"asset\", slot=\"second\") shows its log.");
    }

    private static ToolBridge.ToolMethod Tool(string name) => ToolBridge.All.Single(t => t.Name == name);

    private static BuildStatus Build(string id, string kind, string target, string state, string summary) =>
        new(id, "a", state, state == "succeeded", kind, target, "DebugL", null, null, new BuildTimes(DateTimeOffset.Now, null, null, null, null), null,
            new BuildOutcome(null, null, summary, null), null, [], [], new BuildLogs("/log", null));

    /// <summary>A build of a lane with the state of each repository it planned (newest first in a list, as build_list).</summary>
    private static BuildStatus LaneBuild(string id, string kind, string target, string state, string lane, string? failedRepo, params (string Repo, string State)[] repos) =>
        Build(id, kind, target, state, failedRepo == null ? "built" : $"build failed in {failedRepo}") with
        {
            Lane = new BuildLane(lane, null, [], null),
            Progress = new BuildProgress("build", repos.Length, repos.Length, null, repos.Select(r => new BuildRepoProgress(r.Repo, r.State, null, null, null, null)).ToList(),
                "events"),
            Outcome = new BuildOutcome(failedRepo, failedRepo == null ? null : "build", failedRepo == null ? "built" : $"build failed in {failedRepo}", null)
        };

    private static Overview Overview(IReadOnlyList<BuildStatus>? builds = null, IReadOnlyList<ServiceStatus>? services = null,
        IReadOnlyList<SlotSummary>? slots = null, ExternalSnapshot? external = null) =>
        new(new StackStatus(services is { Count: > 0 }, null, null, null, null, new LeaseSnapshot(null, []), services ?? [], [], external ?? ExternalSnapshot.Empty),
            "/root", "/root/branches/main", "DebugL", "/cfg", "/home/u", [], builds ?? [], [], [], slots ?? [], []);
}
