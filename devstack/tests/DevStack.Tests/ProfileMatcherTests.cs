using FluentAssertions;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

public class ProfileMatcherTests
{
    private const string Root = "/tmp/devstack-matcher";
    private const string Lane = Root + "/branches/main";

    private static DevStackConfig Config() => ConfigStore.Parse($$"""
                                                                 rootPath: {{Root}}
                                                                 defaultCheckout: branches/main
                                                                 configuration: DebugL
                                                                 services:
                                                                   identity:
                                                                     repo: octo-identity
                                                                     args: [Identity.dll, "--urls=https://0.0.0.0:5003"]
                                                                     ports: [5003]
                                                                   meshAdapter:
                                                                     repo: octo-mesh-adapter
                                                                     variables: { tenantId: meshtest }
                                                                     args: [MeshAdapter.dll, "--urls=https://0.0.0.0:5020;http://0.0.0.0:5021", "--Adapter:DedicatedTenantId=${tenantId}"]
                                                                     ports: [5020, 5021]
                                                                   reporting:
                                                                     repo: octo-report
                                                                     optional: true
                                                                     args: [Reporting.dll]
                                                                     ports: [5007]
                                                                 profiles:
                                                                   base:
                                                                     services: [identity, meshAdapter, reporting]
                                                                   two:
                                                                     extends: base
                                                                     instances:
                                                                       meshAdapterB:
                                                                         of: meshAdapter
                                                                         ports: [5030, 5031]
                                                                         extraArgs: ["--urls=https://0.0.0.0:5030;http://0.0.0.0:5031"]
                                                                         variables: { tenantId: other }
                                                                   identityOnly:
                                                                     services: [identity]
                                                                 """);

    private static ObservedService Identity(string? repo = null, string[]? args = null, int[]? ports = null) =>
        new("identity", repo ?? $"{Lane}/octo-identity", args ?? ["Identity.dll", "--urls=https://0.0.0.0:5003"], ports ?? [5003]);

    private static ObservedService Adapter(string tenant = "meshtest", int[]? ports = null, string? name = null, bool legacyKey = false)
    {
        var p = ports ?? [5020, 5021];
        var args = new List<string> { "MeshAdapter.dll", "--urls=https://0.0.0.0:5020;http://0.0.0.0:5021", $"--Adapter:{(legacyKey ? "TenantId" : "DedicatedTenantId")}={tenant}" };
        if (p[0] == 5030)
        {
            args.Add("--urls=https://0.0.0.0:5030;http://0.0.0.0:5031");
        }

        return new ObservedService(name ?? "meshAdapter", $"{Lane}/octo-mesh-adapter", args, p);
    }

    private static ObservedStack Stack(params ObservedService[] services) => new(Lane, "DebugL", services);

    [Fact]
    public void The_expected_stack_of_a_profile_matches_it_exactly()
    {
        var config = Config();
        var match = ProfileMatcher.Compare(config, "two", ProfileMatcher.ExpectedStack(config, "two"));
        match.Exact.Should().BeTrue();
        match.Drift.Should().BeEmpty();
        match.Edited.Should().BeFalse();
    }

    [Fact]
    public void A_missing_optional_service_is_ignored()
    {
        var match = ProfileMatcher.Compare(Config(), "base", Stack(Identity(), Adapter()));
        match.Exact.Should().BeTrue("reporting is optional (skipped when not built)");
    }

    [Fact]
    public void Every_drift_kind_is_reported()
    {
        var config = Config();
        var dev = Root + "/branches/dev";
        var inDev = new ObservedStack(dev, "DebugL", [Identity(repo: dev + "/octo-identity"), Adapter() with { RepoPath = dev + "/octo-mesh-adapter" }]);
        Kinds(ProfileMatcher.Compare(config, "base", inDev)).Should().Equal(["baseLane"], "another lane is one difference, not one per service");
        Kinds(ProfileMatcher.Compare(config, "base", Stack(Identity(), Adapter()) with { Configuration = "Release" }))
            .Should().Equal("configuration");
        Kinds(ProfileMatcher.Compare(config, "base", Stack(Adapter()))).Should().Equal("serviceMissing");
        Kinds(ProfileMatcher.Compare(config, "identityOnly", Stack(Identity(), Adapter()))).Should().Equal("serviceExtra");
        Kinds(ProfileMatcher.Compare(config, "base", Stack(Identity(repo: $"{Lane}/wt-1-octo-identity"), Adapter()))).Should().Equal("source");
        Kinds(ProfileMatcher.Compare(config, "base", Stack(Identity(), Adapter(tenant: "octogrid")))).Should().Equal("args");
        Kinds(ProfileMatcher.Compare(config, "base", Stack(Identity(ports: [5003, 5002]), Adapter()))).Should().Equal("ports");

        var args = ProfileMatcher.Compare(config, "base", Stack(Identity(), Adapter(tenant: "octogrid"))).Drift.Single();
        args.Service.Should().Be("meshAdapter");
        args.Detail.Should().Contain("---Adapter:DedicatedTenantId=meshtest").And.Contain("+--Adapter:DedicatedTenantId=octogrid");
    }

    [Fact]
    public void Arg_drift_lists_at_most_five_tokens()
    {
        var many = Identity(args: ["Identity.dll", "--a", "--b", "--c", "--d", "--e", "--f"]);
        var drift = ProfileMatcher.Compare(Config(), "identityOnly", Stack(many)).Drift.Single();
        drift.Detail.Should().Contain("(+2 more)");
    }

    [Fact]
    public void Unknown_ports_and_args_are_not_compared_and_the_legacy_tenant_key_is_equivalent()
    {
        var unknown = new ObservedService("identity", null, [], []);
        ProfileMatcher.Compare(Config(), "identityOnly", Stack(unknown)).Exact.Should().BeTrue();
        ProfileMatcher.Compare(Config(), "base", Stack(Identity(), Adapter(legacyKey: true))).Exact.Should().BeTrue();
    }

    [Fact]
    public void Two_processes_of_one_service_are_assigned_to_the_instances_by_port()
    {
        // Outside the daemon both processes are called meshAdapter; the second one listens on the instance's ports.
        var match = ProfileMatcher.Compare(Config(), "two", Stack(Adapter("other", [5030, 5031]), Identity(), Adapter()));
        match.Exact.Should().BeTrue(string.Join("; ", match.Drift.Select(d => d.Detail)));

        var wrongTenant = ProfileMatcher.Compare(Config(), "two", Stack(Adapter("third", [5030, 5031]), Identity(), Adapter()));
        wrongTenant.Drift.Should().ContainSingle().Which.Service.Should().Be("meshAdapterB");
    }

    [Fact]
    public void Best_picks_the_closest_profile_within_the_threshold()
    {
        var config = Config();
        ProfileMatcher.Best(config, Stack(Identity()))!.Profile.Should().Be("identityOnly");
        var near = ProfileMatcher.Best(config, Stack(Identity(), Adapter("octogrid")))!;
        near.Profile.Should().Be("base");
        near.DriftCount.Should().Be(1);

        var far = Stack(Identity(ports: [1]), Adapter("x", [2]), new ObservedService("reporting", null, ["Other.dll"], [3]),
            new ObservedService("meshAdapter", null, [], [9]));
        ProfileMatcher.Best(config, far with { Configuration = "Release", Checkout = "/elsewhere" }).Should().BeNull();
    }

    [Fact]
    public void Edited_is_set_when_the_profile_changed_since_the_start()
    {
        var config = Config();
        var observed = ProfileMatcher.ExpectedStack(config, "base");
        var hash = ProfileResolver.Hash(config, "base");
        ProfileMatcher.Compare(config, "base", observed, hash).Edited.Should().BeFalse();

        config.Profiles["base"].Configuration = "Release";
        var edited = ProfileMatcher.Compare(config, "base", observed, hash);
        edited.Edited.Should().BeTrue();
        Kinds(edited).Should().Equal("configuration");

        config.Profiles.Remove("base");
        config.Profiles.Remove("two");
        ProfileMatcher.Compare(config, "base", observed, hash).Drift.Single().Kind.Should().Be("profileDeleted");
    }

    [Fact]
    public void Args_of_a_command_line_start_at_the_dll()
    {
        ProfileMatcher.ArgsOf("/usr/local/share/dotnet/dotnet /x/bin/Identity.dll --urls=a;b --x").Should().Equal("Identity.dll", "--urls=a;b", "--x");
        ProfileMatcher.ArgsOf("node ng serve").Should().BeEmpty();
    }

    private static List<string> Kinds(ProfileMatch match) => match.Drift.Select(d => d.Kind).ToList();

    [Fact]
    public void Args_drift_is_computed_on_raw_values_and_shown_masked()
    {
        var match = ProfileMatcher.Compare(Config(), "base",
            Stack(Identity(args: ["Identity.dll", "--urls=https://0.0.0.0:5003", "--Identity:ClientSecret=hush", "--Db=mongodb://u:pw@h"]), Adapter()));

        var detail = match.Drift.Single(d => d.Kind == "args").Detail;
        detail.Should().Contain("+--Identity:ClientSecret=***").And.Contain("+--Db=mongodb://***@h");
        detail.Should().NotContain("hush").And.NotContain("pw@");
    }
}
