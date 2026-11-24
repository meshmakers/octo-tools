using System.ComponentModel;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Tools;
using Meshmakers.Octo.DevStack.Ui;
using ModelContextProtocol;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The agent-facing tool surface speaks the octo-claude-pm vocabulary (docs/claude-pm-integration.md): lane, base lane,
///     shared stack, lane stack, job, envVars - and none of the old names.
/// </summary>
public sealed class ToolSurfaceTests
{
    private static IEnumerable<ToolBridge.ToolMethod> Tools => ToolBridge.All;

    private static readonly string[] OldNames =
    [
        "env_list", "env_create", "env_add_repo", "env_sync", "env_affected", "env_remove", "env_seed_cache", "env_set", "build_start", "build_status",
        "build_list", "build_cancel", "build_output", "build_refusals", "test_run", "test_status", "checkouts_list", "profile_save", "profile_delete",
        "config_inspect", "config_set_defaults", "config_import_defaults", "service_define", "service_remove", "slot_list", "slot_verify",
        "slot_bootstrap_admin", "slot_register_octo_cli", "slot_login", "slot_apply_overlay", "slot_retired", "slot_forget"
    ];

    [Fact]
    public void The_tools_are_the_target_surface()
    {
        Tools.Select(t => t.Name).Should().BeEquivalentTo(
            "lane_list", "lane_create", "lane_add_repo", "lane_sync", "lane_affected", "lane_build", "lane_test", "lane_remove",
            "base_build", "base_test",
            "job_status", "job_list", "job_cancel", "job_output", "job_refusals", "build_plan",
            "stack_status", "stack_start", "stack_stop", "stack_attention", "stack_list", "stack_setup", "stack_verify",
            "service_start", "service_stop", "service_restart", "service_logs", "service_env",
            "lease_status", "lease_acquire", "lease_release",
            "workspace_list",
            "profile_list", "profile_get", "config_get", "daemon_status", "setup_check", "infra_status", "test_lock",
            "admin_profile_save", "admin_profile_delete", "admin_config_inspect", "admin_config_set_defaults", "admin_config_import_defaults",
            "admin_service_define", "admin_service_remove", "admin_envvar_set", "admin_lane_seed_cache", "admin_slot_retired", "admin_slot_forget",
            "admin_slot_drop_data",
            "dashboard_open");
    }

    [Fact]
    public void The_prompts_are_the_dashboard_command_with_optional_view_and_lane()
    {
        var prompts = typeof(ToolBridge).Assembly.GetTypes()
            .Where(t => t.GetCustomAttribute<ModelContextProtocol.Server.McpServerPromptTypeAttribute>() != null)
            .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Static | BindingFlags.Instance | BindingFlags.DeclaredOnly))
            .Select(m => (Method: m, Attribute: m.GetCustomAttribute<ModelContextProtocol.Server.McpServerPromptAttribute>()))
            .Where(x => x.Attribute != null)
            .ToList();

        var dashboard = prompts.Should().ContainSingle("Claude Code shows each prompt as a slash command: /mcp__octo-devstack__dashboard").Subject;
        dashboard.Attribute!.Name.Should().Be("dashboard");
        dashboard.Method.GetParameters().Select(p => (p.Name, p.HasDefaultValue)).Should().Equal(("view", true), ("lane", true));
        AgentView.DeveloperPrompts.Should().BeEquivalentTo(["dashboard"], "the agent view has no dashboard_open to call");
    }

    [Fact]
    public void No_parameter_names_a_lane_env_or_checkout_and_every_changing_tool_takes_owner_and_session()
    {
        // A developer tool (dashboard_open) changes no stack: no owner, no lease - and it is not in the agent view.
        AgentView.DeveloperTools.Should().BeEquivalentTo(["dashboard_open"]);
        foreach (var tool in Tools)
        {
            var names = ToolBridge.Parameters(tool).Select(p => p.Name).ToList();
            names.Should().NotContain(["env", "environment", "checkout", "defaultCheckout"], $"{tool.Name}: a lane is 'lane', environment variables are 'envVars'");
            if (!tool.ReadOnly && !AgentView.DeveloperTools.Contains(tool.Name))
            {
                names.Should().Contain(["owner", "session"], $"{tool.Name} changes state");
            }
        }
    }

    [Fact]
    public void Descriptions_and_instructions_name_no_old_tool_and_say_first_what_a_tool_is_for()
    {
        var texts = new List<(string Where, string Text)> { ("server instructions", ServerInstructions.Text) };
        foreach (var tool in ToolBridge.All)
        {
            texts.Add((tool.Name, tool.Method.GetCustomAttribute<DescriptionAttribute>()!.Description));
            texts.AddRange(ToolBridge.Parameters(tool).Where(p => p.Description != null).Select(p => ($"{tool.Name}.{p.Name}", p.Description!)));
        }

        texts.AddRange(typeof(ServiceOverride).GetProperties().Select(p => ($"overrides.{p.Name}", p.GetCustomAttribute<DescriptionAttribute>()?.Description ?? "")));
        var old = new Regex($@"\b({string.Join('|', OldNames)})\b");
        foreach (var (where, text) in texts)
        {
            old.Matches(text).Select(m => m.Value).Should().BeEmpty($"{where} uses the new tool names");
            Regex.IsMatch(text, @"\b(env|environment)=").Should().BeFalse($"{where}: a lane is passed as lane=<name>");
        }

        foreach (var tool in Tools)
        {
            var description = tool.Method.GetCustomAttribute<DescriptionAttribute>()!.Description;
            Regex.IsMatch(description, @"^(Admin(: | \(the developer's go\): )[a-z]|[A-Z][a-z]+s )").Should()
                .BeTrue($"{tool.Name} starts with what it is for ('Shows ...', 'Builds ...', 'Admin: ...'): {description[..Math.Min(60, description.Length)]}");
        }
    }

    [Fact]
    public void Environment_variables_of_an_override_are_envVars_and_a_lane_is_lane_in_results()
    {
        var json = JsonSerializer.Serialize(new ServiceOverride { Env = new Dictionary<string, string?> { ["A"] = "1" } }, McpJsonUtilities.DefaultOptions);
        json.Should().Contain("\"envVars\"").And.NotContain("\"env\"");
        JsonSerializer.Deserialize<ServiceOverride>("""{"envVars":{"B":"2"}}""", McpJsonUtilities.DefaultOptions)!.Env.Should().ContainKey("B");

        var status = new Builds.BuildStatus("b1", "o", "running", null, "lane", "ab1", "DebugL", new Builds.BuildLane("/wt-ab1", true, [], null), null,
            new Builds.BuildTimes(DateTimeOffset.Now, null, null, null, null), null, null, null, [], [], new Builds.BuildLogs("/log", null), Env: "ab1");
        var node = JsonSerializer.SerializeToNode(status, McpJsonUtilities.DefaultOptions)!.AsObject();
        node["lane"]!.GetValue<string>().Should().Be("ab1");
        node["packages"]!["path"]!.GetValue<string>().Should().Be("/wt-ab1");
        node.ContainsKey("env").Should().BeFalse();
    }

    /// <summary>
    ///     Every field of every tool result, as the MCP client receives it (property names of the MCP JSON options), walked
    ///     through records, lists and dictionary values: none names a checkout, a feature environment or a slot by an old word.
    ///     A profile as written (<see cref="Profile"/>: admin_config_inspect asWritten, admin_profile_save) keeps the devstack.yaml
    ///     keys checkout and environment.
    /// </summary>
    [Fact]
    public void No_result_field_names_a_checkout_an_environment_or_env()
    {
        var options = McpJsonUtilities.DefaultOptions;
        var bad = new Regex(@"^(env|envs)$|checkout|environment|defaultSlot", RegexOptions.IgnoreCase);
        // The tools that return object: a job (BuildStatus) or, with dryRun, a plan.
        var returned = new[] { typeof(Builds.BuildStatus), typeof(Builds.BuildPlanResult) };
        var found = new List<string>();
        var seen = new HashSet<Type>();

        void Walk(Type type, string path)
        {
            type = Nullable.GetUnderlyingType(type) ?? type;
            if (type.IsGenericType && type.GetGenericTypeDefinition() is var d && (d == typeof(Task<>) || d == typeof(ValueTask<>)))
            {
                Walk(type.GetGenericArguments()[0], path);
                return;
            }

            if (type.IsPrimitive || type.IsEnum || type == typeof(string) || type == typeof(object) || type == typeof(DateTimeOffset) ||
                type == typeof(DateTime) || type == typeof(TimeSpan) || type == typeof(decimal) || type == typeof(Guid) || type == typeof(Profile) ||
                type.Namespace?.StartsWith("System.Text.Json", StringComparison.Ordinal) == true || !seen.Add(type))
            {
                return;
            }

            var info = options.GetTypeInfo(type);
            switch (info.Kind)
            {
                case System.Text.Json.Serialization.Metadata.JsonTypeInfoKind.Enumerable:
                    Walk(info.ElementType!, path + "[]");
                    break;
                case System.Text.Json.Serialization.Metadata.JsonTypeInfoKind.Dictionary:
                    Walk(info.ElementType!, path + "{}");
                    break;
                case System.Text.Json.Serialization.Metadata.JsonTypeInfoKind.Object:
                    foreach (var property in info.Properties.Where(p => p.AttributeProvider?.GetCustomAttributes(typeof(JsonIgnoreAttribute), true)
                                 .OfType<JsonIgnoreAttribute>().Any(a => a.Condition == JsonIgnoreCondition.Always) != true))
                    {
                        if (bad.IsMatch(property.Name))
                        {
                            found.Add($"{path}.{property.Name} ({type.Name})");
                        }

                        Walk(property.PropertyType, $"{path}.{property.Name}");
                    }

                    break;
            }
        }

        foreach (var tool in Tools)
        {
            Walk(tool.Method.ReturnType, tool.Name);
        }

        foreach (var type in returned)
        {
            Walk(type, type.Name);
        }

        string.Join("\n", found).Should().BeEmpty("results speak of lanes (lane, baseLane), the shared stack and envVars");
    }

    [Fact]
    public void The_agent_view_serves_every_tool_but_the_admin_ones()
    {
        var all = new[] { "lane_build", "admin_profile_save", "stack_status", "admin_slot_forget", "dashboard_open" }
            .Select(n => ModelContextProtocol.Server.McpServerTool.Create(() => n, new ModelContextProtocol.Server.McpServerToolCreateOptions { Name = n })).ToList();

        AgentView.Without(all).Select(t => t.ProtocolTool.Name).Should().BeEquivalentTo("lane_build", "stack_status");
        AgentView.Requested(new Microsoft.AspNetCore.Http.QueryCollection(new Dictionary<string, Microsoft.Extensions.Primitives.StringValues> { ["view"] = "agent" }))
            .Should().BeTrue();
        AgentView.Requested(new Microsoft.AspNetCore.Http.QueryCollection()).Should().BeFalse();
    }

    [Fact]
    public void A_lanes_lease_from_before_the_lane_vocabulary_belongs_to_the_lane()
    {
        EnvironmentDiscovery.CurrentLeaseOwner("env:ab1").Should().Be("lane:ab1");
        EnvironmentDiscovery.CurrentLeaseOwner("reimar/AB#1_x").Should().Be("reimar/AB#1_x");
        EnvironmentDiscovery.EnvironmentOfLeaseOwner("lane:ab1").Should().Be("ab1");
        EnvironmentDiscovery.EnvironmentOfLeaseOwner("env:ab1").Should().Be("ab1");
        EnvironmentDiscovery.LeaseOwnerOf("ab1").Should().Be("lane:ab1");
    }
}
