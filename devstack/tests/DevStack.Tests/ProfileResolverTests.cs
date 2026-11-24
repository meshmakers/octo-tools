using FluentAssertions;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Tests;

public class ProfileResolverTests
{
    private const string Services = """
                                    services:
                                      identity:
                                        repo: octo-identity
                                        args: [Identity.dll, "--urls=https://0.0.0.0:5003"]
                                        ports: [5003]
                                      repo:
                                        repo: octo-repo
                                        args: [Repo.dll]
                                        ports: [5001]
                                        env: { FROM_SERVICE: s }
                                      meshAdapter:
                                        repo: octo-mesh-adapter
                                        variables: { tenantId: meshtest, adapterId: "1" }
                                        args: [MeshAdapter.dll, "--urls=https://0.0.0.0:5020;http://0.0.0.0:5021", "--Adapter:DedicatedTenantId=${tenantId}", "--Adapter:AdapterRtId=${adapterId}"]
                                        ports: [5020, 5021]
                                        logName: MeshAdapter
                                        announceEnv: { ANNOUNCED: x }
                                      studio:
                                        repo: octo-studio
                                        enabled: false
                                        command: pwsh
                                        args: [start.ps1]
                                    envProviders:
                                      s3Store: { script: "@{}" }
                                      other: { script: "@{}" }
                                    """;

    private static DevStackConfig Parse(string profiles, string root = "") =>
        ConfigStore.Parse($"""
                           rootPath: /tmp/devstack-profile-tests
                           defaultCheckout: branches/main
                           configuration: DebugL
                           {root}
                           {Services}
                           profiles:
                           {profiles}
                           """);

    [Fact]
    public void Merge_order_is_root_then_ancestors_then_profile_then_adhoc()
    {
        var config = Parse("""
                             base:
                               checkout: branches/base
                               configuration: Release
                               environment: { A: base, B: base }
                             child:
                               extends: base
                               checkout: branches/child
                               environment: { B: child }
                           """);

        var root = ProfileResolver.Resolve(config, null, null);
        root.Checkout.Should().Be("branches/main");
        root.Configuration.Should().Be("DebugL");
        root.Profile.Should().BeNull();

        var child = ProfileResolver.Resolve(config, "child", null);
        child.Checkout.Should().Be("branches/child");
        child.Configuration.Should().Be("Release", "inherited from base");
        child.Environment.Should().Contain("A", "base").And.Contain("B", "child");
        child.Profile.Should().Be("child");
        child.ProfileHash.Should().HaveLength(12);

        var adhoc = ProfileResolver.Resolve(config, "child", new StartSpec { Configuration = "Debug", Environment = new() { ["B"] = "adhoc" } });
        adhoc.Configuration.Should().Be("Debug");
        adhoc.Checkout.Should().Be("branches/child");
        adhoc.Environment["B"].Should().Be("adhoc");
    }

    [Fact]
    public void Extends_of_an_unknown_profile_and_cycles_are_rejected()
    {
        var unknown = () => Parse("""
                                    a: { extends: nope }
                                  """);
        unknown.Should().Throw<InvalidOperationException>().WithMessage("*profile 'a'*unknown profile 'nope'*");

        var cycle = () => Parse("""
                                  a: { extends: b }
                                  b: { extends: a }
                                """);
        cycle.Should().Throw<InvalidOperationException>().WithMessage("*extends cycle*");
    }

    [Fact]
    public void Exclude_unions_and_services_replace()
    {
        var config = Parse("""
                             all: { exclude: [studio] }
                             small: { extends: all, services: [identity, repo, studio], exclude: [repo] }
                           """);

        ProfileResolver.Resolve(config, "all", null).Services.Should().Equal("identity", "repo", "meshAdapter");
        ProfileResolver.Resolve(config, "small", null).Services.Should().Equal(["identity"], "services replaced, exclude [studio, repo] unioned");
        ProfileResolver.Resolve(config, "small", new StartSpec { Services = ["repo", "meshAdapter"] }).Services
            .Should().Equal(["meshAdapter"], "ad-hoc services replace too, the inherited exclude still applies");
    }

    [Fact]
    public void Overrides_merge_field_wise_extra_args_concatenate_and_null_env_removes()
    {
        var config = Parse("""
                             base:
                               overrides:
                                 repo: { source: wt-1, extraArgs: [--a], env: { KEEP: k, DROP: d }, args: [Repo.dll, --base] }
                             child:
                               extends: base
                               overrides:
                                 repo: { extraArgs: [--b], env: { DROP: null } }
                           """);

        var resolved = ProfileResolver.Resolve(config, "child", new StartSpec
        {
            Overrides = new() { ["repo"] = new ServiceOverride { ExtraArgs = ["--c"], Args = ["Repo.dll", "--adhoc"] } }
        });

        var o = resolved.Overrides["repo"];
        o.Source.Should().Be("wt-1");
        o.Args.Should().Equal("Repo.dll", "--adhoc");
        o.ExtraArgs.Should().Equal("--a", "--b", "--c");
        o.Env.Should().Contain("KEEP", "k");
        o.Env.Should().ContainKey("DROP").WhoseValue.Should().BeNull();

        var context = ProfileResolver.DryRunContext(resolved.Config, resolved.Checkout, resolved.Configuration);
        var plan = ProfileResolver.DryRunPlans(resolved, context).Single(p => p.Name == "repo");
        plan.Args.Should().Equal("Repo.dll", "--adhoc", "--a", "--b", "--c");
        plan.Env.Should().ContainKey("DROP").WhoseValue.Should().BeNull("a null value removes the variable at start");
    }

    [Fact]
    public void Overrides_of_services_the_start_leaves_out_are_dropped_but_adhoc_ones_are_an_error()
    {
        var config = Parse("""
                             base: { overrides: { repo: { extraArgs: [--x] } } }
                             child: { extends: base, services: [identity] }
                           """);

        ProfileResolver.Resolve(config, "child", null).Overrides.Should().BeEmpty();
        var act = () => ProfileResolver.Resolve(config, "child", new StartSpec { Overrides = new() { ["repo"] = new ServiceOverride() } });
        act.Should().Throw<InvalidOperationException>().WithMessage("*Override for 'repo'*not started*");
    }

    [Fact]
    public void Instance_is_materialized_as_a_clone_of_its_base_service()
    {
        var config = Parse("""
                             two:
                               services: [identity, meshAdapter]
                               instances:
                                 meshAdapterB:
                                   of: meshAdapter
                                   ports: [5030, 5031]
                                   extraArgs: ["--urls=https://0.0.0.0:5030;http://0.0.0.0:5031"]
                                   variables: { tenantId: other }
                                   env: { EXTRA: e }
                           """);

        var resolved = ProfileResolver.Resolve(config, "two", null);
        resolved.Services.Should().Equal("identity", "meshAdapter", "meshAdapterB");
        config.Services.Should().NotContainKey("meshAdapterB", "the loaded config stays untouched");

        var clone = resolved.Config.Services["meshAdapterB"];
        clone.Ports.Should().Equal(5030, 5031);
        clone.LogName.Should().Be("meshAdapterB");
        clone.AnnounceEnv.Should().BeEmpty();
        clone.Repo.Should().Be("octo-mesh-adapter");

        var plan = ProfileResolver.DryRunPlans(resolved, ProfileResolver.DryRunContext(resolved.Config, resolved.Checkout, resolved.Configuration))
            .Single(p => p.Name == "meshAdapterB");
        plan.Args.Should().Equal("MeshAdapter.dll", "--urls=https://0.0.0.0:5020;http://0.0.0.0:5021", "--Adapter:DedicatedTenantId=other",
            "--Adapter:AdapterRtId=1", "--urls=https://0.0.0.0:5030;http://0.0.0.0:5031");
        plan.LogFile.Should().EndWith("meshAdapterB.log");
        plan.Env["EXTRA"].Should().Be("e");
        plan.Ports.Should().Equal(5030, 5031);
    }

    [Fact]
    public void Instance_without_own_ports_next_to_its_base_clashes()
    {
        var act = () => Parse("""
                                clash:
                                  instances:
                                    meshAdapterB: { of: meshAdapter }
                              """);
        act.Should().Throw<InvalidOperationException>().WithMessage("*profile 'clash'*Port 5020*'meshAdapter' and 'meshAdapterB'*");

        var alone = Parse("""
                            alone:
                              exclude: [meshAdapter]
                              instances:
                                meshAdapterB: { of: meshAdapter }
                          """);
        ProfileResolver.Resolve(alone, "alone", null).Services.Should().Contain("meshAdapterB").And.NotContain("meshAdapter");
    }

    [Theory]
    [InlineData("bad name", "a: { }", "*invalid name*")]
    [InlineData("instance named like a service", "a: { instances: { repo: { of: identity, ports: [1] } } }", "*name of a configured service*")]
    [InlineData("instance of an unknown service", "a: { instances: { x: { of: nope } } }", "*'of' must name a configured service*")]
    [InlineData("unknown service in services", "a: { services: [nope] }", "*Unknown service 'nope' in services*")]
    [InlineData("unknown service in exclude", "a: { exclude: [nope] }", "*Unknown service 'nope' in exclude*")]
    [InlineData("unknown service in overrides", "a: { overrides: { nope: { } } }", "*Unknown service 'nope' in overrides*")]
    [InlineData("unknown env provider", "a: { envProviders: { nope: true } }", "*Unknown env provider 'nope'*")]
    [InlineData("unknown placeholder", "a: { overrides: { repo: { extraArgs: [\"${nope}\"] } } }", "*${nope}*")]
    [InlineData("undeclared variable", "a: { overrides: { repo: { variables: { tenantId: x } } } }", "*no variable 'tenantId'*")]
    [InlineData("instance variable unknown", "a: { instances: { x: { of: repo, ports: [9], variables: { nope: y } } } }", "*has no variable 'nope'*")]
    [InlineData("bad artifact storage", "a: { settings: { artifactStorage: cloud } }", "*artifactStorage*")]
    public void Validation_rejects_broken_profiles(string because, string profile, string message)
    {
        if (because == "bad name")
        {
            profile = "\"a b\": { }";
        }

        var act = () => Parse("  " + profile);
        act.Should().Throw<InvalidOperationException>(because).WithMessage(message);
    }

    public static TheoryData<string, string, string, string> SettingsFields => new()
    {
        { "systemDatabase: X", "OCTO_SYSTEM__SYSTEMDATABASENAME", "X", "" },
        { "mongo: { host: h:27017 }", "OCTO_SYSTEM__DATABASEHOST", "h:27017", "" },
        { "mongo: { directConnection: false }", "OCTO_SYSTEM__USEDIRECTCONNECTION", "false", "" },
        { "mongo: { replicaSet: rs1 }", "OCTO_SYSTEM__REPLICASETNAME", "rs1", "" },
        { "broker: { host: rabbit }", "OCTO_IDENTITY__BROKERHOST", "rabbit", "OCTO_ADAPTER__BROKERHOST" },
        { "broker: { port: 5673 }", "OCTO_COMMUNICATIONCONTROLLER__BROKERPORT", "5673", "OCTO_AI__BROKERPORT" },
        { "broker: { vhost: dev }", "OCTO_MCP__BROKERVIRTUALHOST", "dev", "OCTO_REPORTING__BROKERVIRTUALHOST" },
        { "broker: { instancePrefix: p1 }", "OCTO_BOT__INSTANCEPREFIX", "p1", "OCTO_PLATFORMSERVICES__INSTANCEPREFIX" },
        { "authorityUrl: https://id/", "OCTO_ASSETREPOSITORY__AUTHORITY", "https://id/", "OCTO_ADAPTER__ISSUERURI" },
        { "streamData: { enabled: false }", "OCTO_STREAMDATA__ENABLED", "false", "" },
        { "streamData: { schemaInstancePrefix: s1 }", "OCTO_STREAMDATA__SCHEMAINSTANCEPREFIX", "s1", "" },
        { "httpActivator: { enabled: true }", "OCTO_COMMUNICATIONCONTROLLER__ACTIVATORENABLED", "true", "OCTO_COMMUNICATIONCONTROLLER__ACTIVATORFORWARDRETRYSECONDS" },
        { "httpActivator: { addressTemplate: \"https://{release}.localhost\" }", "OCTO_COMMUNICATIONCONTROLLER__ACTIVATORWORKLOADADDRESSTEMPLATE", "https://{release}.localhost", "" },
        { "logLevel: Debug", "OCTO_LOGGING__LOGLEVEL__DEFAULT", "Debug", "" }
    };

    [Theory]
    [MemberData(nameof(SettingsFields))]
    public void Every_setting_fans_out_into_the_request_environment(string setting, string key, string value, string alsoKey)
    {
        var config = Parse($"""
                              s:
                                settings:
                                  {setting}
                            """);
        var env = ProfileResolver.Resolve(config, "s", null).Environment;
        env.Should().Contain(key, value);
        if (alsoKey.Length > 0)
        {
            env.Should().ContainKey(alsoKey);
        }
    }

    [Fact]
    public void Broker_port_and_vhost_go_only_to_sections_that_have_them_and_activator_off_sets_no_retry()
    {
        var env = SettingsMap.Expand(new ProfileSettings
        {
            Broker = new BrokerSettings { Port = 1, Vhost = "v" },
            HttpActivator = new HttpActivatorSettings { Enabled = false }
        }).Env;
        env.Should().NotContainKey("OCTO_IDENTITY__BROKERPORT").And.NotContainKey("OCTO_ASSETREPOSITORY__BROKERVIRTUALHOST");
        env.Should().ContainKey("OCTO_ADAPTER__BROKERPORT");
        env.Should().Contain("OCTO_COMMUNICATIONCONTROLLER__ACTIVATORENABLED", "false");
        env.Should().NotContainKey("OCTO_COMMUNICATIONCONTROLLER__ACTIVATORFORWARDRETRYSECONDS");
        SettingsMap.EnvKeys["authorityUrl"].Should().HaveCount(10);
    }

    [Fact]
    public void Artifact_storage_toggles_the_s3_provider_and_explicit_toggles_win()
    {
        var config = Parse("""
                             fs: { settings: { artifactStorage: fileSystem } }
                             s3: { settings: { artifactStorage: localS3 }, envProviders: { other: false } }
                             explicit: { extends: fs, envProviders: { s3Store: true } }
                           """);
        var fs = ProfileResolver.Resolve(config, "fs", null);
        fs.EnvProviders.Should().Contain("s3Store", false);
        fs.Config.EnvProviders["s3Store"].Enabled.Should().BeFalse();
        config.EnvProviders["s3Store"].Enabled.Should().BeTrue("the loaded config stays untouched");

        var s3 = ProfileResolver.Resolve(config, "s3", null);
        s3.EnvProviders.Should().Contain("s3Store", true).And.Contain("other", false);
        ProfileResolver.Resolve(config, "explicit", null).EnvProviders.Should().Contain("s3Store", true);
    }

    [Fact]
    public void Mesh_adapter_settings_become_variables_and_explicit_overrides_win()
    {
        var config = Parse("""
                             grid: { settings: { meshAdapter: { tenantId: octogrid, adapterRtId: "42" } } }
                           """);
        var resolved = ProfileResolver.Resolve(config, "grid", null);
        resolved.Overrides["meshAdapter"].Variables.Should().Contain("tenantId", "octogrid").And.Contain("adapterId", "42");

        var adhoc = ProfileResolver.Resolve(config, "grid", new StartSpec
        {
            Overrides = new() { ["meshAdapter"] = new ServiceOverride { Variables = new() { ["tenantId"] = "mine" } } }
        });
        adhoc.Overrides["meshAdapter"].Variables.Should().Contain("tenantId", "mine").And.Contain("adapterId", "42");

        ProfileResolver.Resolve(config, "grid", new StartSpec { Services = ["identity"] }).Overrides.Should().BeEmpty();
    }

    [Fact]
    public void Explicit_environment_wins_over_settings()
    {
        var config = Parse("""
                             db: { settings: { systemDatabase: FromSetting }, environment: { OCTO_SYSTEM__SYSTEMDATABASENAME: FromEnv } }
                           """);
        ProfileResolver.Resolve(config, "db", null).Environment["OCTO_SYSTEM__SYSTEMDATABASENAME"].Should().Be("FromEnv");
    }

    [Fact]
    public void Hash_changes_when_an_ancestor_is_edited()
    {
        var config = Parse("""
                             base: { configuration: Release }
                             child: { extends: base }
                           """);
        var before = ProfileResolver.Hash(config, "child");
        config.Profiles["base"].Configuration = "Debug";
        ProfileResolver.Hash(config, "child").Should().NotBe(before);
    }

    [Fact]
    public void Unknown_profile_lists_the_known_ones()
    {
        var config = Parse("""
                             one: { }
                             two: { }
                           """);
        var act = () => ProfileResolver.Resolve(config, "three", null);
        act.Should().Throw<InvalidOperationException>().WithMessage("Unknown profile 'three'. Known: one, two.");
    }

    [Fact]
    public void Capture_keeps_only_non_secret_environment_and_reports_skipped_keys()
    {
        var (kept, skipped) = ProfileCapture.FilterEnv(new Dictionary<string, string?>
        {
            ["OCTO_SYSTEM__SYSTEMDATABASENAME"] = "X",
            ["OCTO_SYSTEM__ADMINUSERPASSWORD"] = "p",
            ["OCTO_AI__APIKEY"] = "k",
            ["REMOVED"] = null
        });
        kept.Should().BeEquivalentTo(new Dictionary<string, string?> { ["OCTO_SYSTEM__SYSTEMDATABASENAME"] = "X", ["REMOVED"] = null });
        skipped.Should().BeEquivalentTo("OCTO_SYSTEM__ADMINUSERPASSWORD", "OCTO_AI__APIKEY");
    }

    [Fact]
    public void Capture_of_processes_outside_the_daemon_turns_a_second_process_into_an_instance_by_port()
    {
        var config = Parse("");
        const string lane = "/tmp/devstack-profile-tests/branches/main";
        var profile = ProfileCapture.FromProcesses(config, lane, "DebugL",
        [
            new ProfileCapture.Process("meshAdapter", null, ["MeshAdapter.dll", "--urls=https://0.0.0.0:5030;http://0.0.0.0:5031", "--Adapter:DedicatedTenantId=b"], [5030, 5031]),
            new ProfileCapture.Process("meshAdapter", null, ["MeshAdapter.dll", "--urls=https://0.0.0.0:5020;http://0.0.0.0:5021", "--Adapter:DedicatedTenantId=octogrid", "--Adapter:AdapterRtId=1"], [5020, 5021]),
            new ProfileCapture.Process("identity", lane + "/wt-1-octo-identity", ["Identity.dll", "--urls=https://0.0.0.0:5003"], [5003])
        ]);

        profile.Checkout.Should().Be("branches/main");
        profile.Services.Should().BeEquivalentTo("meshAdapter", "identity");
        profile.Overrides!["identity"].Source.Should().Be("wt-1-octo-identity");
        profile.Overrides["identity"].Args.Should().BeNull("the arguments are the configured ones");
        profile.Overrides["meshAdapter"].Args.Should().Contain("--Adapter:DedicatedTenantId=octogrid");
        var instance = profile.Instances!["meshAdapter2"];
        instance.Of.Should().Be("meshAdapter");
        instance.Ports.Should().Equal(5030, 5031);
        instance.Args.Should().Contain("--Adapter:DedicatedTenantId=b");

        config.Profiles["captured"] = profile;
        var resolved = ProfileResolver.Resolve(config, "captured", null);
        resolved.Services.Should().Contain(["meshAdapter", "meshAdapter2", "identity"]);
    }
}
