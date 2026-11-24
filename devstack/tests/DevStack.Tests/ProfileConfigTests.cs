using FluentAssertions;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Tests;

public class ProfileConfigTests
{
    [Fact]
    public void A_file_without_profiles_still_loads()
    {
        using var checkout = new TestCheckout();
        var store = checkout.WriteConfig("""
                                           a: { repo: r, args: [x] }
                                         """);
        store.Load().Profiles.Should().BeEmpty();

        ConfigStore.Parse("services: {}\nprofiles:\n").Profiles.Should().BeEmpty("an empty profiles key is no profile");
        ConfigStore.Parse("services:\n  a: { repo: r, args: [x] }\nprofiles:\n  bare:\n").Profiles.Should().ContainKey("bare");
    }

    [Fact]
    public void Default_profiles_resolve_and_plan()
    {
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        config.Profiles.Keys.Should().BeEquivalentTo("core-identity", "core-data", "full-main", "backend-octogrid-studio", "second-adapter",
            "reporting-ai", "lean-backend", "simulation", "fresh-db", "core-data-slot", "energy-community", "voest-app", "voest-app-eda");

        ProfileResolver.Resolve(config, "core-identity", null).Services.Should().Equal("identityServices");
        ProfileResolver.Resolve(config, "backend-octogrid-studio", null).Services.Should().NotContain("frontendLibraries").And.Contain("refineryStudio");
        ProfileResolver.Resolve(config, "lean-backend", null).EnvProviders.Should().Contain("s3Store", false);
        ProfileResolver.Resolve(config, "fresh-db", null).Environment.Should().Contain("OCTO_SYSTEM__SYSTEMDATABASENAME", "OctoSystem_fresh");
        ProfileResolver.Resolve(config, "reporting-ai", null).Services.Should().Contain(["reportingServices", "aiServices", "mcpServices"]);

        var second = ProfileResolver.Resolve(config, "second-adapter", null);
        second.Services.Should().Contain(["meshAdapter", "meshAdapterB"]);
        var plan = ProfileResolver.DryRunPlans(second, ProfileResolver.DryRunContext(second.Config, second.Checkout, second.Configuration))
            .Single(p => p.Name == "meshAdapterB");
        plan.Args.Should().Contain("--Adapter:DedicatedTenantId=meshtest2");
        plan.Args[^1].Should().Be("--urls=https://0.0.0.0:5030;http://0.0.0.0:5031", "the last --urls wins");
        plan.LogFile.Should().EndWith("meshAdapterB.log");
    }

    [Fact]
    public void Profiles_round_trip_through_an_update_including_null_env_values()
    {
        using var checkout = new TestCheckout();
        var store = checkout.WriteConfig("""
                                           a: { repo: r, args: [x], ports: [1] }
                                           b: { repo: r, args: [y], variables: { v: "1" } }
                                         """, """
                                              envProviders:
                                                p: { script: "@{}" }
                                              """);
        store.Update(c => c.Profiles["mine"] = new Profile
        {
            Description = "test",
            Checkout = "branches/main",
            Exclude = ["a"],
            Environment = new() { ["KEEP"] = "k", ["DROP"] = null },
            EnvProviders = new() { ["p"] = false },
            Overrides = new() { ["b"] = new ServiceOverride { ExtraArgs = ["--z"], Env = new() { ["GONE"] = null }, Variables = new() { ["v"] = "2" } } },
            Instances = new() { ["b2"] = new ProfileInstance { Of = "b", Ports = [7], LogName = "B2" } },
            Settings = new ProfileSettings { SystemDatabase = "S", Broker = new BrokerSettings { Port = 5673 } }
        });

        var yaml = File.ReadAllText(checkout.ConfigPath);
        var loaded = store.Load().Profiles["mine"];
        loaded.Description.Should().Be("test");
        loaded.Exclude.Should().Equal("a");
        loaded.Environment.Should().Contain("KEEP", "k");
        loaded.Environment.Should().ContainKey("DROP").WhoseValue.Should().BeNull(yaml);
        loaded.EnvProviders.Should().Contain("p", false);
        loaded.Overrides!["b"].Env.Should().ContainKey("GONE").WhoseValue.Should().BeNull();
        loaded.Overrides["b"].ExtraArgs.Should().Equal("--z");
        loaded.Instances!["b2"].Of.Should().Be("b");
        loaded.Instances["b2"].Ports.Should().Equal(7);
        loaded.Settings!.Broker!.Port.Should().Be(5673);
        ProfileResolver.Hash(store.Load(), "mine").Should().Be(ProfileResolver.Hash(store.Load(), "mine"));
    }

    [Fact]
    public void An_invalid_profile_update_leaves_the_file_untouched()
    {
        using var checkout = new TestCheckout();
        var store = checkout.WriteConfig("""
                                           a: { repo: r, args: [x] }
                                         """);
        var original = File.ReadAllText(checkout.ConfigPath);

        var act = () => store.Update(c => c.Profiles["broken"] = new Profile { Services = ["nope"] });
        act.Should().Throw<InvalidOperationException>().WithMessage("*profile 'broken'*Unknown service 'nope'*");
        File.ReadAllText(checkout.ConfigPath).Should().Be(original);
    }
}
