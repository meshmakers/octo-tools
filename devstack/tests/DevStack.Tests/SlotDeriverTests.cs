using FluentAssertions;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Tests;

public sealed class SlotDeriverTests
{
    private static readonly SlotInfo Second = new("second", 1, 100, "s1");
    private const string SlotDir = "/state/slots/second";

    private static DevStackConfig DefaultConfig() => ConfigStore.Parse(ConfigStore.ReadDefaultYaml());

    private static StackContext Context(DevStackConfig config) => ProfileResolver.DryRunContext(config, "branches/main", "DebugL");

    [Fact]
    public void Ports_health_urls_urls_arguments_and_announced_urls_are_shifted()
    {
        var config = ConfigStore.Parse("""
                                       services:
                                         web:
                                           repo: r
                                           args: [Web.dll, "--urls=https://0.0.0.0:5003;http://0.0.0.0:5002", "--Other=5003"]
                                           ports: [5003, 5002]
                                           healthUrl: https://localhost:5003/health
                                           announceEnv: { OCTO_X__URL: "https://localhost:5003", OCTO_Y__URL: "https://example.com:443" }
                                         split:
                                           repo: r
                                           args: [Split.dll, --urls, "http://0.0.0.0:6000"]
                                           ports: [6000]
                                       """);

        var derived = SlotDeriver.Apply(config, Second, SlotDir).Config;

        var web = derived.Services["web"];
        web.Ports.Should().Equal(5103, 5102);
        web.HealthUrl.Should().Be("https://localhost:5103/health");
        web.Args.Should().Equal("Web.dll", "--urls=https://0.0.0.0:5103;http://0.0.0.0:5102", "--Other=5003");
        web.AnnounceEnv.Should().Contain("OCTO_X__URL", "https://localhost:5103").And.Contain("OCTO_Y__URL", "https://example.com:443");
        derived.Services["split"].Args.Should().Equal("Split.dll", "--urls", "http://0.0.0.0:6100");
        config.Services["web"].Ports.Should().Equal([5003, 5002], "the input configuration is not changed");
    }

    [Fact]
    public void Instances_get_their_own_shifted_ports_and_urls()
    {
        var config = DefaultConfig();
        var resolved = ProfileResolver.Resolve(config, "second-adapter", new StartSpec { Slot = "second" });

        var derived = SlotDeriver.Apply(resolved.Config, Second, SlotDir, resolved.Instances, resolved.Environment);

        var plan = ServicePlanner.Plan(derived.Config, Context(derived.Config), "meshAdapterB", resolved.Overrides.GetValueOrDefault("meshAdapterB"),
            new Dictionary<string, string?>());
        plan.Ports.Should().Equal(5130, 5131);
        plan.Args[^1].Should().Be("--urls=https://0.0.0.0:5130;http://0.0.0.0:5131");
        plan.Env.Should().Contain("OCTO_EDGEDATABUFFER__STORAGEPATH", $"{SlotDir}/edge-buffer/meshAdapterB", "a scoped row reaches the instances of its service");
    }

    [Fact]
    public void Every_shipped_row_renders_for_the_default_services()
    {
        var config = DefaultConfig();
        var derived = SlotDeriver.Apply(config, Second, SlotDir);

        derived.Skipped.Should().BeEmpty();
        derived.Rows.Select(r => r.Id).Should().BeEquivalentTo(config.EffectiveSlotDerivations.Rows.Select(r => r.Id));
        derived.Env.Should().Contain("OCTO_SYSTEM__SYSTEMDATABASENAME", "OctoSystem_s1")
            .And.Contain("OCTO_BOT__INSTANCEPREFIX", "s1")
            .And.Contain("OCTO_ADAPTER__INSTANCEPREFIX", "s1")
            .And.Contain("OCTO_STREAMDATA__SCHEMAINSTANCEPREFIX", "s1")
            .And.Contain("OCTO_SYSTEM__TENANTDATABASEPREFIX", "s1_")
            .And.Contain("OCTO_ARTIFACTSTORAGE__INSTANCEPREFIX", "local-s1")
            .And.Contain("OCTO_BOT__SECRETSWEEP__BACKUPSTORAGEPATH", $"{SlotDir}/bot/secret-backups")
            .And.Contain("OCTO_AIWORKSPACE__BASEPATH", $"{SlotDir}/ai/workspaces")
            .And.Contain("OCTO_IDENTITY__AUTHORITYURL", "https://localhost:5103")
            .And.Contain("OCTO_ASSETREPOSITORY__AUTHORITY", "https://localhost:5103")
            .And.Contain("OCTO_IDENTITY__REFINERYSTUDIOURL", "https://localhost:4300")
            .And.Contain("OCTO_ASSETREPOSITORY__PUBLICURL", "https://localhost:5101")
            .And.Contain("OCTO_COMMUNICATIONCONTROLLER__SERVICEURLS__BOT", "https://localhost:5109")
            .And.Contain("OCTO_ADAPTER__COMMUNICATIONCONTROLLERSERVICESURI", "https://localhost:5115")
            .And.Contain("OCTO_PLATFORMSERVICES__MESHADAPTERURL", "https://localhost:5120")
            .And.Contain("OCTO_ADAPTER__REPORTINGSERVICEURL", "https://localhost:5107")
            .And.Contain("OCTO_AI__APIURL", "https://localhost:5119")
            .And.Contain("OCTO_AIWORKSPACE__MCPSERVERURL", "http://localhost:5116/mcp");
        derived.Config.Services["meshAdapter"].Env.Should().Contain("OCTO_EDGEDATABUFFER__STORAGEPATH", $"{SlotDir}/edge-buffer/meshAdapter");
        derived.Config.Services["identityServices"].Env.Should().NotContainKey("OCTO_EDGEDATABUFFER__STORAGEPATH");
        derived.Config.Services["platformServices"].Ports.Should().Equal(5125, 5124);
        derived.Config.Services["mcpServices"].AnnounceEnv.Should().Contain("OCTO_PLATFORMSERVICES__MCPSERVICEURL", "https://localhost:5117");
        derived.IsolateKeys.Should().ContainKey("OCTO_EDGEDATABUFFER__STORAGEPATH").WhoseValue.Should().Equal("meshAdapter");
    }

    [Fact]
    public void The_communication_controller_skips_its_CK_method_validation_in_every_non_default_slot_only()
    {
        // A new slot's system database has no System.Communication model, and the validation refuses the start (platform bug).
        var config = DefaultConfig();

        var derived = SlotDeriver.Apply(config, Second, SlotDir);
        var third = SlotDeriver.Apply(config, new SlotInfo("third", 2, 200, "s2"), "/state/slots/third");
        var main = SlotDeriver.Apply(config, SlotInfo.Default, SlotDir);

        derived.Config.Services["communicationControllerServices"].Env.Should().Contain("OCTO_METHODS__VALIDATEREGISTRATIONS", "false");
        third.Config.Services["communicationControllerServices"].Env.Should().Contain("OCTO_METHODS__VALIDATEREGISTRATIONS", "false");
        derived.Env.Should().NotContainKey("OCTO_METHODS__VALIDATEREGISTRATIONS", "only the communication controller gets it");
        derived.Config.Services.Where(s => s.Key != "communicationControllerServices")
            .Should().OnlyContain(s => !s.Value.Env.ContainsKey("OCTO_METHODS__VALIDATEREGISTRATIONS"));
        main.Config.Services["communicationControllerServices"].Env.Should().NotContainKey("OCTO_METHODS__VALIDATEREGISTRATIONS",
            "the default slot derives nothing and keeps the validation");
        var plan = ServicePlanner.Plan(derived.Config, Context(derived.Config), "communicationControllerServices", null,
            ServicePlanner.StackEnv(derived.Config, ["communicationControllerServices"], new Dictionary<string, string?>(), derived.Env, new Dictionary<string, string?>()));
        plan.Env.Should().Contain("OCTO_METHODS__VALIDATEREGISTRATIONS", "false");
    }

    [Fact]
    public void Explicit_settings_and_env_beat_derived_values()
    {
        var config = DefaultConfig();
        var resolved = ProfileResolver.Resolve(config, null, new StartSpec
        {
            Slot = "second",
            Services = ["identityServices", "meshAdapter"],
            Settings = new ProfileSettings { SystemDatabase = "OctoSystem_mine" },
            Environment = new Dictionary<string, string?> { ["OCTO_BOT__INSTANCEPREFIX"] = "mine", ["OCTO_EDGEDATABUFFER__STORAGEPATH"] = "/explicit" }
        });
        var derived = SlotDeriver.Apply(resolved.Config, Second, SlotDir, resolved.Instances, resolved.Environment);
        var providers = new Dictionary<string, string?> { ["OCTO_ARTIFACTSTORAGE__INSTANCEPREFIX"] = "local" };
        var stackEnv = ServicePlanner.StackEnv(derived.Config, resolved.Services, providers, derived.Env, resolved.Environment);

        var plan = ServicePlanner.Plan(derived.Config, Context(derived.Config), "meshAdapter", null, stackEnv);

        plan.Env["OCTO_SYSTEM__SYSTEMDATABASENAME"].Should().Be("OctoSystem_mine", "settings beat the slot");
        plan.Env["OCTO_BOT__INSTANCEPREFIX"].Should().Be("mine", "stack_start env beats the slot");
        plan.Env["OCTO_EDGEDATABUFFER__STORAGEPATH"].Should().Be("/explicit", "explicit env beats a scoped row");
        plan.Env["OCTO_ARTIFACTSTORAGE__INSTANCEPREFIX"].Should().Be("local-s1", "the slot beats the provider output");
        plan.Env["OCTO_ADAPTER__INSTANCEPREFIX"].Should().Be("s1");
    }

    [Fact]
    public void The_default_slot_plans_exactly_what_a_start_without_slots_plans()
    {
        var config = DefaultConfig();
        var context = Context(config);
        var derived = SlotDeriver.Apply(config, SlotInfo.Default, SlotDir);
        derived.Env.Should().BeEmpty();
        derived.Rows.Should().BeEmpty();

        foreach (var name in config.Services.Keys)
        {
            var expected = ServicePlanner.Plan(config, context, name, null, ServicePlanner.StackEnv(config, config.Services.Keys, new Dictionary<string, string?>(),
                new Dictionary<string, string>(), new Dictionary<string, string?>()));
            var actual = ServicePlanner.Plan(derived.Config, context, name, null, ServicePlanner.StackEnv(derived.Config, config.Services.Keys,
                new Dictionary<string, string?>(), derived.Env, new Dictionary<string, string?>()));

            actual.Args.Should().Equal(expected.Args, name);
            actual.Ports.Should().Equal(expected.Ports, name);
            actual.HealthUrl.Should().Be(expected.HealthUrl, name);
            actual.LogFile.Should().Be(expected.LogFile, name);
            actual.WorkingDirectory.Should().Be(expected.WorkingDirectory, name);
            actual.Env.Should().BeEquivalentTo(expected.Env, name);
        }
    }

    [Fact]
    public void Conditions_and_user_rows_change_the_table()
    {
        var config = ConfigStore.Parse("""
                                       services:
                                         web: { repo: r, args: [Web.dll], ports: [5003] }
                                       slotDerivations:
                                         rows:
                                           - id: systemDatabase
                                             keys: [OCTO_SYSTEM__SYSTEMDATABASENAME]
                                             value: "Sys_{slot.name}"
                                             isolate: true
                                           - id: artifactStorage
                                             disabled: true
                                           - id: onlyLater
                                             keys: [OCTO_LATER]
                                             value: "{slot.index}"
                                             when: "slot.index > 1"
                                       """);

        var second = SlotDeriver.Apply(config, Second, SlotDir);
        second.Env.Should().Contain("OCTO_SYSTEM__SYSTEMDATABASENAME", "Sys_second").And.NotContainKey("OCTO_ARTIFACTSTORAGE__INSTANCEPREFIX")
            .And.NotContainKey("OCTO_LATER");
        second.Skipped.Should().Contain(s => s.StartsWith("meshAdapterUrl"), "rows naming services this file does not have are skipped");
        SlotDeriver.Apply(config, new SlotInfo("third", 2, 200, "s2"), SlotDir).Env.Should().Contain("OCTO_LATER", "2");

        var act = () => ConfigStore.Parse("""
                                          services: {}
                                          slotDerivations:
                                            rows:
                                              - id: bad
                                                keys: [X]
                                                value: "{nope}"
                                          """);
        act.Should().Throw<InvalidOperationException>().WithMessage("*row 'bad'*Unknown placeholder '{nope}'*");
    }

    [Fact]
    public void Slots_in_the_file_are_validated()
    {
        var bad = new[]
        {
            ("default: { index: 1 }", "*not 'default'*"),
            ("Second: { index: 1 }", "*lowercase*"),
            ("a: { index: 0 }", "*index must be 1 or more*"),
            ("a: { index: 1 }\n  b: { index: 1 }", "*share an index*"),
            ("a: { index: 1, portOffset: 1 }", "*port 5004*"),
            ("a: { index: 1, prefix: '1x' }", "*must start with a letter*")
        };
        foreach (var (slots, message) in bad)
        {
            var act = () => ConfigStore.Parse("services:\n  web: { repo: r, args: [Web.dll], ports: [5003, 5004] }\nslots:\n  " + slots + "\n");
            act.Should().Throw<InvalidOperationException>(slots).WithMessage(message);
        }
    }

    [Fact]
    public void A_start_in_another_slot_leaves_the_frontends_out_or_refuses_them()
    {
        var config = DefaultConfig();
        var resolved = ProfileResolver.Resolve(config, "full-main", new StartSpec { Slot = "second" });
        resolved.Services.Should().NotContain(["refineryStudio", "frontendLibraries"]);
        resolved.Dropped.Should().BeEquivalentTo("refineryStudio", "frontendLibraries");

        var explicitFrontend = () => ProfileResolver.Resolve(config, null, new StartSpec { Slot = "second", Services = ["identityServices", "refineryStudio"] });
        explicitFrontend.Should().Throw<InvalidOperationException>().WithMessage("*refineryStudio*shared stack only*");

        var activator = () => ProfileResolver.Resolve(config, null, new StartSpec
        {
            Slot = "second", Services = ["communicationControllerServices"], Settings = new ProfileSettings { HttpActivator = new HttpActivatorSettings { Enabled = true } }
        });
        activator.Should().Throw<InvalidOperationException>().WithMessage("*httpActivator*");

        var badName = () => ProfileResolver.Resolve(config, null, new StartSpec { Slot = "Second" });
        badName.Should().Throw<InvalidOperationException>().WithMessage("*Invalid slot name*");
    }

    [Fact]
    public void A_file_written_before_slots_keeps_the_frontends_exclusive()
    {
        var config = ConfigStore.Parse("""
                                       services:
                                         refineryStudio: { repo: octo-frontend-refinery-studio, command: pwsh }
                                         other: { repo: r, command: x }
                                       """);
        SlotRules.IsExclusive(config, "refineryStudio").Should().BeTrue("the built-in service of that name is exclusive");
        SlotRules.IsExclusive(config, "other").Should().BeFalse();
    }

    [Fact]
    public void A_new_devstack_yaml_leaves_the_built_in_table_out()
    {
        var yaml = ConfigStore.UserDefaultYaml();
        yaml.Should().NotContain("- id: systemDatabase").And.Contain("slotDerivations: built in");
        var config = ConfigStore.Parse(yaml);
        config.SlotDerivations.Should().BeNull();
        config.EffectiveSlotDerivations.Rows.Should().Contain(r => r.Id == "systemDatabase");
        ConfigStore.Serialize(config).Should().NotContain("OctoSystem_{slot.prefix}", "the effective table is never written into the file");
    }
}
