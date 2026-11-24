using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;
using Microsoft.Extensions.Logging.Abstractions;
using ModelContextProtocol;

namespace Meshmakers.Octo.DevStack.Tests;

public sealed class ProfileToolsTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    private (ProfileTools Tools, ConfigStore Store, StackSupervisor Supervisor) Create()
    {
        _checkout.Repo("tools");
        var store = _checkout.WriteConfig("""
                                            web:
                                              repo: tools
                                              workingDirectory: .
                                              command: pwsh
                                              variables: { apiKey: none, tenantId: t0, dbPassword: none }
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                            other:
                                              repo: tools
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 31"]
                                          profiles:
                                            base:
                                              description: the base
                                              services: [web]
                                            child:
                                              extends: base
                                              configuration: Release
                                          """);
        var supervisor = new StackSupervisor(store, new LeaseManager(), new StateStore(new DevStackPaths(_checkout.StateDirectory)),
            NullLogger<StackSupervisor>.Instance);
        return (new ProfileTools(store, supervisor, NullLogger<ProfileTools>.Instance), store, supervisor);
    }

    [Fact]
    public async Task Save_get_and_delete_a_profile()
    {
        var (tools, store, _) = Create();

        var saved = await tools.Save("me", "mine", new Profile { Services = ["web", "other"], Environment = new() { ["LEVEL"] = "Debug" } },
            description: "my profile");
        saved.Replaced.Should().BeFalse();
        store.Load().Profiles["mine"].Description.Should().Be("my profile");

        var detail = await tools.Get("mine");
        detail.Profile!.Services.Should().Equal("web", "other");
        detail.Chain.Should().Equal("mine");

        var list = await tools.List();
        list.Select(p => p.Name).Should().BeEquivalentTo("base", "child", "mine");
        list.Single(p => p.Name == "child").Configuration.Should().Be("Release");
        list.Single(p => p.Name == "child").Services.Should().Equal("web");

        tools.Delete("me", "mine").Should().Contain("deleted");
        store.Load().Profiles.Should().NotContainKey("mine");
    }

    [Fact]
    public async Task Overwrite_is_needed_to_replace_and_an_invalid_profile_is_refused()
    {
        var (tools, store, _) = Create();
        var again = () => tools.Save("me", "base", new Profile { Services = ["other"] });
        (await again.Should().ThrowAsync<McpException>()).WithMessage("*exists*overwrite=true*");

        (await tools.Save("me", "base", new Profile { Services = ["other"] }, overwrite: true)).Replaced.Should().BeTrue();
        store.Load().Profiles["base"].Services.Should().Equal("other");

        var invalid = () => tools.Save("me", "bad", new Profile { Services = ["nope"] });
        (await invalid.Should().ThrowAsync<McpException>()).WithMessage("*Unknown service 'nope'*");
        var badName = () => tools.Save("me", "a b", new Profile());
        await badName.Should().ThrowAsync<McpException>();
    }

    [Fact]
    public void Delete_is_refused_while_another_profile_extends_it()
    {
        var (tools, store, _) = Create();
        var act = () => tools.Delete("me", "base");
        act.Should().Throw<McpException>().WithMessage("*extended by child*");
        store.Load().Profiles.Should().ContainKey("base");

        var unknown = () => tools.Delete("me", "nope");
        unknown.Should().Throw<McpException>().WithMessage("Unknown profile 'nope'. Known: base, child.");
    }

    [Fact]
    public async Task Secret_environment_is_never_saved_and_is_masked_in_views()
    {
        var (tools, store, _) = Create();
        var saved = await tools.Save("me", "s", new Profile
        {
            Services = ["web"],
            Environment = new() { ["OCTO_SYSTEM__ADMINUSERPASSWORD"] = "secret-value", ["PLAIN"] = "p" }
        });
        saved.SkippedEnv.Should().Equal("OCTO_SYSTEM__ADMINUSERPASSWORD");
        File.ReadAllText(store.ConfigPath).Should().NotContain("secret-value");

        // A hand-written secret in devstack.yaml is masked in every view.
        store.Update(c => c.Profiles["s"].Environment!["OCTO_X__APIKEY"] = "hand-written");
        var raw = await tools.Get("s");
        raw.Profile!.Environment!["OCTO_X__APIKEY"].Should().Be(SecretMask.Masked);
        var resolved = await tools.Get("s", resolved: true);
        resolved.Resolved!.EnvVars["OCTO_X__APIKEY"].Should().Be(SecretMask.Masked);
        resolved.Resolved.EnvVars["PLAIN"].Should().Be("p");
    }

    [Fact]
    public async Task Get_against_another_profile_lists_the_differences()
    {
        var (tools, _, _) = Create();
        var detail = await tools.Get("base", against: "child");
        detail.Against.Should().Be("profile child");
        detail.Drift!.Drift.Should().ContainSingle(d => d.Kind == "configuration");

        var unknown = () => tools.Get("base", against: "nothing");
        (await unknown.Should().ThrowAsync<McpException>()).WithMessage("*no profile and no running stack*");
    }

    [Fact]
    public async Task Capture_of_the_daemon_stack_saves_what_runs_without_secrets_and_marks_the_profile_active()
    {
        var (tools, store, supervisor) = Create();
        await supervisor.StartStackAsync("me", new StartSpec
        {
            Services = ["web", "other"],
            Environment = new() { ["OCTO_SYSTEM__ADMINUSERPASSWORD"] = "pw", ["LEVEL"] = "Debug" },
            Overrides = new() { ["other"] = new ServiceOverride { Env = new() { ["SOME_TOKEN"] = "t", ["X"] = "y" } } }
        }, "base", false, false, TimeSpan.FromSeconds(1), CancellationToken.None);

        var saved = await tools.Save("me", "captured", capture: "daemon");
        saved.SkippedEnv.Should().BeEquivalentTo("OCTO_SYSTEM__ADMINUSERPASSWORD", "SOME_TOKEN");
        var profile = store.Load().Profiles["captured"];
        profile.Services.Should().BeEquivalentTo("web", "other");
        profile.Checkout.Should().Be("branches/main");
        profile.Environment.Should().ContainKey("LEVEL").And.NotContainKey("OCTO_SYSTEM__ADMINUSERPASSWORD");
        profile.Overrides!["other"].Env.Should().ContainKey("X").And.NotContainKey("SOME_TOKEN");
        File.ReadAllText(store.ConfigPath).Should().NotContain("ADMINUSERPASSWORD").And.NotContain("SOME_TOKEN");

        var list = await tools.List();
        list.Single(p => p.Name == "base").ActiveIn.Should().Be("daemon");
        list.Single(p => p.Name == "base").Match!.Drift.Should().ContainSingle(d => d.Kind == "serviceExtra" && d.Service == "other");

        var noStack = () => tools.Save("me", "x", capture: "start-octo:1");
        (await noStack.Should().ThrowAsync<McpException>()).WithMessage("*No stack 'start-octo:1'*");

        await supervisor.StopServicesAsync("me", null, CancellationToken.None);
    }

    [Theory]
    [InlineData("OCTO_LICENSE__KEY")]
    [InlineData("Db__ConnectionString")]
    [InlineData("MONGO_CONNSTR")]
    [InlineData("RABBIT_PWD")]
    [InlineData("SSH_PASSPHRASE")]
    [InlineData("OPENAI_APIKEY")]
    [InlineData("TLS_PRIVATE")]
    [InlineData("CLIENT_CERT")]
    public void Secret_names_cover_licenses_connection_strings_and_certificates(string name) =>
        SecretMask.IsSecretName(name).Should().BeTrue();

    [Fact]
    public void Uri_credentials_are_masked_and_secret_arguments_dropped()
    {
        SecretMask.MaskValue("mongodb://octo:s3cret@localhost:27017/db").Should().Be("mongodb://***@localhost:27017/db");
        SecretMask.Mask(new Dictionary<string, string> { ["MONGO_URL"] = "amqp://u:p@h", ["LEVEL"] = "Debug" })
            .Should().Equal(new Dictionary<string, string> { ["MONGO_URL"] = "amqp://***@h", ["LEVEL"] = "Debug" });

        var skipped = new List<string>();
        var kept = SecretMask.FilterArgs(["App.dll", "--Adapter:TenantId=t1", "--Octo:ApiKey=abc", "--ClientSecret", "xyz", "--urls",
            "http://0.0.0.0:5020", "--Broker=amqp://u:p@host"], skipped);

        kept.Should().Equal("App.dll", "--Adapter:TenantId=t1", "--urls", "http://0.0.0.0:5020");
        skipped.Should().Equal("argument --Octo:ApiKey", "argument --ClientSecret", "argument --Broker (URI credentials)");
        string.Join(" ", skipped).Should().NotContain("abc").And.NotContain("xyz");
    }

    [Fact]
    public void Capture_of_an_external_stack_leaves_secret_arguments_out_and_reports_them()
    {
        var (_, store, _) = Create();
        var skipped = new List<string>();

        var profile = ProfileCapture.FromProcesses(store.Load(), _checkout.Lane, "DebugL",
        [
            new ProfileCapture.Process("web", null, ["30", "--Identity:ClientSecret", "hush", "--LogLevel=Debug"], []),
            new ProfileCapture.Process("web", null, ["30", "--Token=t0k3n"], [])
        ], skipped);

        profile.Overrides!["web"].Args.Should().Equal("30", "--LogLevel=Debug");
        profile.Instances!["web2"].Args.Should().Equal("30");
        skipped.Should().Equal("argument --Identity:ClientSecret", "argument --Token");
    }

    [Fact]
    public async Task Profile_views_mask_secret_variables_and_env_of_overrides_and_instances()
    {
        var (tools, _, _) = Create();
        await tools.Save("me", "vars", new Profile
        {
            Services = ["web"],
            Overrides = new() { ["web"] = new ServiceOverride { Variables = new() { ["apiKey"] = "v1", ["tenantId"] = "t1" } } },
            Instances = new()
            {
                ["web2"] = new ProfileInstance
                {
                    Of = "web", Variables = new() { ["dbPassword"] = "v2" }, Env = new() { ["DB_URL"] = "postgres://a:b@h/db" }
                }
            }
        });

        var detail = await tools.Get("vars");

        detail.Profile!.Overrides!["web"].Variables.Should().Equal(new Dictionary<string, string> { ["apiKey"] = SecretMask.Masked, ["tenantId"] = "t1" });
        detail.Profile.Instances!["web2"].Variables!["dbPassword"].Should().Be(SecretMask.Masked);
        detail.Profile.Instances["web2"].Env!["DB_URL"].Should().Be("postgres://***@h/db");
    }
}
