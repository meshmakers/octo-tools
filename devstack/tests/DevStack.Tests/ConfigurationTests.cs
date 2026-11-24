using FluentAssertions;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Tests;

public class ConfigurationTests
{
    [Fact]
    public void Default_config_parses_and_every_service_plans_without_unknown_placeholders()
    {
        using var checkout = new TestCheckout();
        // As the daemon runs it: the folders come from the workspace octo-tools describes (here the lanes layout).
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml(), workspace: new WorkspaceDefaults(checkout.Root, Path.Combine(checkout.Root, "octo-tools"), "branches/main"));
        var context = ServicePlanner.CreateContext(config, null, null);

        config.Services.Should().ContainKeys("identityServices", "assetRepoServices", "meshAdapter", "platformServices", "refineryStudio");
        foreach (var name in config.Services.Keys)
        {
            var plan = ServicePlanner.Plan(config, context, name, null, new Dictionary<string, string?>());
            plan.Args.Should().NotContain(a => a.Contains("${"), $"service {name} must expand all placeholders");
        }

        var identity = ServicePlanner.Plan(config, context, "identityServices", null, new Dictionary<string, string?>());
        identity.WorkingDirectory.Should().Be(Path.Combine(checkout.Lane, "octo-identity-services", "bin", "DebugL", "net10.0"));
        identity.LogFile.Should().Be(Path.Combine(checkout.Lane, "logFiles", "IdentityServices.log"));
        // Path values from the yaml keep its '/' after the lane; Windows accepts both separators, so compare full paths.
        Path.GetFullPath(identity.Env["OCTO_LocalFileSystemCatalog__RootPath"]!).Should().Be(Path.Combine(checkout.Lane, ".octo", "local-catalog"));
    }

    [Fact]
    public void Default_config_matches_the_Start_Octo_ports()
    {
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        config.Services["identityServices"].Ports.Should().Contain(5003);
        config.Services["assetRepoServices"].Ports.Should().Contain([5000, 5001]);
        config.Services["platformServices"].Ports.Should().Contain(5025);
        config.EnvProviders.Keys.Should().Equal("profileEnv", "devInstanceKey", "s3Store");
        config.EnvProviders["s3Store"].WhenServices.Should().Equal("botServices");
    }

    [Fact]
    public void Unknown_placeholder_is_an_error()
    {
        var act = () => TemplateExpander.Expand("--x=${nope}", new Dictionary<string, string> { ["a"] = "1" });
        act.Should().Throw<InvalidOperationException>().WithMessage("*${nope}*Known: a*");
    }

    [Fact]
    public void Env_placeholder_reads_the_daemon_environment()
    {
        TemplateExpander.Expand("${env:X}/y", new Dictionary<string, string>(), n => n == "X" ? "val" : null).Should().Be("val/y");
        TemplateExpander.Expand("${env:MISSING}", new Dictionary<string, string>(), _ => null).Should().BeEmpty();
    }

    [Fact]
    public void Override_changes_source_args_env_and_variables()
    {
        using var checkout = new TestCheckout();
        checkout.Repo("octo-mesh-adapter");
        var worktree = checkout.Repo("wt-1-octo-mesh-adapter");
        var store = checkout.WriteConfig("""
                                           adapter:
                                             repo: octo-mesh-adapter
                                             variables: { tenantId: meshtest }
                                             args: [A.dll, "--Tenant=${tenantId}"]
                                             env: { FROM_SERVICE: s, REMOVE_ME: x }
                                         """, """
                                              environment:
                                                GLOBAL: g
                                                FROM_SERVICE: global-loses
                                              """);
        var config = store.Load();
        var context = ServicePlanner.CreateContext(config, null, null);

        var plan = ServicePlanner.Plan(config, context, "adapter", new ServiceOverride
        {
            Source = "wt-1-octo-mesh-adapter",
            ExtraArgs = ["--Logging:LogLevel:Default=Debug"],
            Env = new Dictionary<string, string?> { ["REMOVE_ME"] = null, ["EXTRA"] = "${repoPath}" },
            Variables = new Dictionary<string, string> { ["tenantId"] = "other" }
        }, new Dictionary<string, string?> { ["STACK"] = "st" });

        plan.RepoPath.Should().Be(worktree);
        plan.Source.Should().Be(worktree);
        plan.WorkingDirectory.Should().Be(Path.Combine(worktree, "bin", "DebugL", "net10.0"));
        plan.Args.Should().Equal("A.dll", "--Tenant=other", "--Logging:LogLevel:Default=Debug");
        plan.Env["GLOBAL"].Should().Be("g");
        plan.Env["STACK"].Should().Be("st");
        plan.Env["FROM_SERVICE"].Should().Be("s");
        plan.Env["EXTRA"].Should().Be(worktree);
        plan.Env.Should().ContainKey("REMOVE_ME").WhoseValue.Should().BeNull();
    }

    [Fact]
    public void Override_of_an_undeclared_variable_is_an_error()
    {
        using var checkout = new TestCheckout();
        var store = checkout.WriteConfig("""
                                           a:
                                             repo: r
                                             args: [x]
                                         """);
        var config = store.Load();
        var context = ServicePlanner.CreateContext(config, null, null);
        var act = () => ServicePlanner.Plan(config, context, "a", new ServiceOverride { Variables = new() { ["tenantId"] = "x" } },
            new Dictionary<string, string?>());
        act.Should().Throw<InvalidOperationException>().WithMessage("*no variable 'tenantId'*");
    }

    [Fact]
    public void Missing_source_folder_is_reported_with_the_paths_tried()
    {
        using var checkout = new TestCheckout();
        var store = checkout.WriteConfig("""
                                           a:
                                             repo: r
                                             args: [x]
                                         """);
        var config = store.Load();
        var context = ServicePlanner.CreateContext(config, null, null);
        var act = () => ServicePlanner.Plan(config, context, "a", new ServiceOverride { Source = "wt-missing" }, new Dictionary<string, string?>());
        act.Should().Throw<InvalidOperationException>().WithMessage("*wt-missing*does not exist*");
    }

    [Fact]
    public void StartAfter_orders_dependencies_first_and_detects_cycles()
    {
        var config = ConfigStore.Parse("""
                                       services:
                                         a: { repo: r, args: [x], startAfter: [b] }
                                         b: { repo: r, args: [x], startAfter: [c] }
                                         c: { repo: r, args: [x] }
                                       """);
        ServicePlanner.Order(config, ["a", "b", "c"]).Should().Equal("c", "b", "a");
        ServicePlanner.Order(config, ["a", "b"]).Should().Equal("b", "a");
        ServicePlanner.Order(config, ["a", "c"]).Should().Equal(["a", "c"], "no relation inside the set keeps the given order");

        config.Services["c"].StartAfter.Add("a");
        var act = () => ServicePlanner.Order(config, ["a", "b", "c"]);
        act.Should().Throw<InvalidOperationException>().WithMessage("*cycle*");
    }

    [Fact]
    public void Backend_services_of_the_default_start_after_identity()
    {
        // AB#8951: in a fresh slot identity creates the system database the asset repository needs.
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        config.Services["identityServices"].StartAfter.Should().BeEmpty();
        foreach (var name in new[] { "assetRepoServices", "meshAdapter", "botServices", "platformServices", "mcpServices", "aiServices" })
        {
            config.Services[name].StartAfter.Should().Equal(["identityServices"], name);
        }

        // AB#9377: the controller validates its CK method handlers against the system tenant the asset repository sets up.
        config.Services["communicationControllerServices"].StartAfter.Should().Equal("identityServices", "assetRepoServices");

        ServicePlanner.Order(config, ["assetRepoServices", "botServices", "identityServices"]).First().Should().Be("identityServices");
        ServicePlanner.Order(config, ["communicationControllerServices", "assetRepoServices", "identityServices"])
            .Should().Equal("identityServices", "assetRepoServices", "communicationControllerServices");
    }

    [Fact]
    public void The_built_in_startAfter_is_always_kept_restricted_to_configured_services_and_an_own_list_adds_to_it()
    {
        // A devstack.yaml written before the default had startAfter, or before a dependency was added to it.
        var config = ConfigStore.Parse("""
                                       services:
                                         identityServices: { repo: r, args: [x] }
                                         assetRepoServices: { repo: r, args: [x] }
                                         botServices: { repo: r, args: [x], startAfter: [assetRepoServices] }
                                         communicationControllerServices: { repo: r, args: [x], startAfter: [identityServices] }
                                         custom: { repo: r, args: [x] }
                                       """);
        config.Services["assetRepoServices"].StartAfter.Should().Equal("identityServices");
        config.Services["botServices"].StartAfter.Should().Equal(["assetRepoServices", "identityServices"], "an own list adds to the built-in one");
        config.Services["communicationControllerServices"].StartAfter.Should().Equal(["identityServices", "assetRepoServices"],
            "a file of an older daemon gets the dependency added later (AB#9377)");
        config.Services["custom"].StartAfter.Should().BeEmpty();

        var withoutIdentity = ConfigStore.Parse("services:\n  assetRepoServices: { repo: r, args: [x] }\n");
        withoutIdentity.Services["assetRepoServices"].StartAfter.Should().BeEmpty("a dependency the file does not configure is left out");
    }

    [Fact]
    public void Validation_rejects_a_startAfter_cycle_when_the_file_is_read()
    {
        var act = () => ConfigStore.Parse("""
                                          services:
                                            a: { repo: r, args: [x], startAfter: [b] }
                                            b: { repo: r, args: [x], startAfter: [a] }
                                          """);
        act.Should().Throw<InvalidOperationException>().WithMessage("devstack.yaml: startAfter cycle: *a*b*");
    }

    [Fact]
    public void Validation_rejects_unknown_startAfter_and_shadowed_builtins()
    {
        var unknown = () => ConfigStore.Parse("services:\n  a: { repo: r, args: [x], startAfter: [zz] }\n");
        unknown.Should().Throw<InvalidOperationException>().WithMessage("*unknown service 'zz'*");

        var shadow = () => ConfigStore.Parse("services:\n  a: { repo: r, args: [x], variables: { checkout: y } }\n");
        shadow.Should().Throw<InvalidOperationException>().WithMessage("*shadows a built-in*");

        var typo = () => ConfigStore.Parse("services:\n  a: { repo: r, argz: [x] }\n");
        typo.Should().Throw<InvalidOperationException>();
    }

    [Fact]
    public void Update_round_trips_and_keeps_a_backup()
    {
        using var checkout = new TestCheckout();
        var store = new ConfigStore(checkout.ConfigPath);
        store.EnsureExists().Should().BeTrue();
        store.EnsureExists().Should().BeFalse();
        var before = store.Load();

        store.Update(c =>
        {
            c.Services["extra"] = new ServiceConfig { Repo = "octo-extra", Args = ["Extra.dll"], Ports = [5041] };
            c.Services.Remove("aiWorker");
            c.Environment["NEW"] = "1";
        });

        var after = store.Load();
        File.Exists(checkout.ConfigPath + ".bak").Should().BeTrue();
        after.Services.Should().ContainKey("extra").And.NotContainKey("aiWorker");
        after.Services["extra"].Ports.Should().Equal(5041);
        after.Environment["NEW"].Should().Be("1");
        after.Services["meshAdapter"].Variables.Should().BeEquivalentTo(before.Services["meshAdapter"].Variables);
        after.Services["reportingServices"].Enabled.Should().BeFalse();
        after.Services["reportingServices"].AnnounceEnv.Should().BeEquivalentTo(before.Services["reportingServices"].AnnounceEnv);
        after.EnvProviders["s3Store"].Script.Should().Be(before.EnvProviders["s3Store"].Script);
    }

    [Fact]
    public void Failed_update_leaves_the_file_unchanged()
    {
        using var checkout = new TestCheckout();
        var store = new ConfigStore(checkout.ConfigPath);
        store.EnsureExists();
        var original = File.ReadAllText(checkout.ConfigPath);

        var act = () => store.Update(c => c.Services["broken"] = new ServiceConfig { Repo = "", Args = ["x"] });
        act.Should().Throw<InvalidOperationException>();
        File.ReadAllText(checkout.ConfigPath).Should().Be(original);
    }
}
