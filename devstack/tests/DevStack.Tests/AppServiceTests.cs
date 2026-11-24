using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     Apps (frontends of consumer repositories) as services: the slot variant, the generated runtime config, the identity
///     overlay of their clients, and the static app host. No npm, no dev server, no real app repository - the "app" is a
///     folder with an index.html and a config.json in a temp checkout.
/// </summary>
public sealed class AppServiceTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly List<Process> _processes = [];
    private readonly List<StackSupervisor> _supervisors = [];

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    public void Dispose()
    {
        foreach (var run in _supervisors.SelectMany(s => s.Runs))
        {
            foreach (var pid in run.Pids().Where(ProcessTree.IsAlive))
            {
                ProcessTree.TerminateAsync(pid, TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult();
            }
        }

        foreach (var p in _processes.Where(p => !p.HasExited))
        {
            p.Kill(entireProcessTree: true);
        }

        _checkout.Dispose();
    }

    private static readonly SlotInfo Second = new("second", 1, 100, "s1");

    private static DevStackConfig Default => ConfigStore.Parse(ConfigStore.ReadDefaultYaml());

    // ---------- the default configuration ----------

    [Fact]
    public void An_app_runs_its_own_dev_server_in_the_default_slot_and_its_build_output_in_another_slot()
    {
        var config = Default;

        var own = config.Services["voestApp"];
        own.Command.Should().Be("pwsh");
        own.Args.Should().Equal("-NoLogo", "-NoProfile", "-File", "octo-start.ps1");
        own.Ports.Should().Equal(4300);
        own.Enabled.Should().BeFalse("an app starts with its profile, not with every stack");
        SlotDeriver.Apply(config, SlotInfo.Default, "/state/slots/default").Config.Services["voestApp"].Command.Should().Be("pwsh", "the default slot derives nothing");

        var slot = SlotDeriver.Apply(config, Second, "/state/slots/second").Config.Services["voestApp"];
        slot.Command.Should().Be("dotnet");
        slot.Ports.Should().Equal(4400);
        slot.HealthUrl.Should().Be("https://localhost:4400/");
        slot.Args.Should().Equal("${daemon}", "--serve-app", "--root", "${repoPath}/src/voestalpine/dist/voestalpine/browser", "--overlay",
            Path.Combine("/state/slots/second", "services", "voestApp"), "--url", "https://localhost:4400", "--proxy",
            "^/tenant(/.*)?$=https://localhost:5101");

        var energy = SlotDeriver.Apply(config, Second, "/state/slots/second").Config.Services["energyCommunityApp"];
        energy.Args.Should().Contain("https://localhost:44586").And.Contain("${repoPath}/src/energy-community/dist");
        energy.Args[^1].Should().Be("^/[A-Za-z0-9_-]+/public-api/member-registration(-community)?$=https://localhost:5120|/public-api/=>/");
    }

    [Fact]
    public void The_app_profiles_start_the_app_with_the_backend_it_needs()
    {
        var config = Default;

        ProfileResolver.Resolve(config, "voest-app", null).Services.Should().Equal("identityServices", "assetRepoServices", "voestApp");
        var energy = ProfileResolver.Resolve(config, "energy-community", null);
        energy.Services.Should().Equal("identityServices", "assetRepoServices", "reportingServices", "meshAdapter", "energyCommunityApp");
        config.Services["energyCommunityApp"].RequiresRepos.Should().Equal("octo-frontend-libraries");
    }

    [Fact]
    public void An_app_profile_brings_the_adapter_the_app_needs_and_the_slot_config_points_at_it()
    {
        var config = Default;
        var eda = config.Services["edaAdapter"];
        eda.Enabled.Should().BeFalse("an adapter of an app starts only when a profile or the developer asks for it");
        eda.Description.Should().Contain("LIVE").And.Contain("energy-community/docs/runbooks");

        var resolved = ProfileResolver.Resolve(config, "voest-app-eda", null);
        resolved.Services.Should().Equal("identityServices", "assetRepoServices", "edaAdapter", "voestApp");
        var plan = ProfileResolver.DryRunPlans(resolved, ProfileResolver.DryRunContext(resolved.Config, resolved.Checkout, resolved.Configuration))
            .Single(p => p.Name == "edaAdapter");
        plan.Env.Should().Contain("OCTO_ADAPTER__TENANTID", "voestalpine").And.Contain("OCTO_ADAPTER__ADAPTERRTID", "686e0f17196fcd3c42ed8c77");
        plan.Ports.Should().Equal(5022, 5023);

        var shifted = SlotDeriver.Apply(config, Second, "/state/slots/second").Config;
        shifted.Services["edaAdapter"].Args[^1].Should().Be("--urls=https://0.0.0.0:5122;http://0.0.0.0:5123");
        shifted.Services["voestApp"].Files.Single().Set["edaAdapterUrl"].Should().Be("https://localhost:{port.edaAdapter.https}/");
    }

    [Fact]
    public void The_daemon_placeholder_is_the_running_assembly_and_slot_placeholders_leave_service_placeholders_alone()
    {
        ServicePlanner.DaemonAssembly.Should().EndWith("octo-devstack.dll");
        SlotDeriver.Render("${repoPath}/x {slot.name} ${daemon}", Default, Second, "/s").Should().Be("${repoPath}/x second ${daemon}");
    }

    [Fact]
    public void The_built_in_apps_are_imported_into_an_existing_configuration_on_request()
    {
        var store = _checkout.WriteConfig("""
                                            web:
                                              repo: octo-a
                                              args: [x]
                                          """);
        var tools = new Tools.ConfigTools(store, NullLogger<Tools.ConfigTools>.Instance);

        var listed = tools.ImportDefaults("me");
        listed.ImportedServices.Should().BeEmpty();
        listed.MissingServices.Should().Contain(["voestApp", "energyCommunityApp", "identityServices"]);
        listed.MissingProfiles.Should().Contain("voest-app");

        var imported = tools.ImportDefaults("me", ["voestApp", "identityServices", "assetRepoServices", "edaAdapter"], ["voest-app"]);
        imported.ImportedServices.Should().Equal("voestApp", "identityServices", "assetRepoServices", "edaAdapter");
        imported.ImportedProfiles.Should().Equal("voest-app");

        // Written to the file and read back as it is built in (slot variant, files, clients).
        var loaded = store.Load();
        var app = loaded.Services["voestApp"];
        app.Slot!.Args.Should().Equal(Default.Services["voestApp"].Slot!.Args);
        app.Files.Single().Set.Should().Contain("assetServicesUrl", "https://localhost:{port.assetRepoServices.https}");
        app.IdentityClients.Single().ClientId.Should().Be("voestalpine-frontend-debug");
        app.RequiresRepos.Should().Equal("octo-frontend-libraries");
        ProfileResolver.Resolve(loaded, "voest-app", null).Services.Should().Equal("identityServices", "assetRepoServices", "voestApp");
        SlotDeriver.Apply(loaded, Second, "/s").Config.Services["voestApp"].Args.Should().Contain("https://localhost:4400");

        loaded.Services["assetRepoServices"].StartAfter.Should().Equal("identityServices");

        // A backend imported without identityServices keeps no dependency on it (AB#8951) instead of failing validation.
        tools.ImportDefaults("me", ["aiServices"]).ImportedServices.Should().Equal("aiServices");
        store.Load().Services["aiServices"].StartAfter.Should().Equal(["identityServices"], "identityServices is in this file");

        tools.ImportDefaults("me", ["voestApp"]).Note.Should().Contain("Kept as they are").And.Contain("service voestApp");
        var unknown = () => tools.ImportDefaults("me", ["nope"]);
        unknown.Should().Throw<ModelContextProtocol.McpException>().WithMessage("*no service 'nope'*");

        var bareStore = _checkout.WriteConfig("  web:\n    repo: octo-a\n    args: [x]\n");
        var bare = new Tools.ConfigTools(bareStore, NullLogger<Tools.ConfigTools>.Instance);
        bare.ImportDefaults("me", ["aiServices"]).ImportedServices.Should().Equal("aiServices");
        bareStore.Load().Services["aiServices"].StartAfter.Should().BeEmpty("the file has no identityServices");
    }

    // ---------- generated files ----------

    [Fact]
    public void The_generated_config_is_the_apps_own_file_with_the_slots_backend_urls()
    {
        var repo = _checkout.Repo("voest-app");
        Directory.CreateDirectory(Path.Combine(repo, "src/voestalpine/src/assets"));
        File.WriteAllText(Path.Combine(repo, "src/voestalpine/src/assets/config.json"),
            """
            {
              // the tracked defaults
              "tenantId": "voestalpine",
              "authorityUrl": "https://localhost:5003/",
              "assetServicesUrl": "https://localhost:5001",
              "clientId": "voestalpine-frontend-debug",
              "supportedLanguages": [{ "cultureCode": "de-AT" }],
            }
            """);
        var shifted = SlotDeriver.Apply(Default, Second, _checkout.StateDirectory).Config;

        var written = ServiceFiles.Write(shifted, Second, _checkout.StateDirectory, "voestApp", repo);

        written.Should().Equal(Path.Combine(_checkout.StateDirectory, "services", "voestApp", "assets", "config.json"));
        var json = JsonNode.Parse(File.ReadAllText(written[0]))!;
        json["authorityUrl"]!.GetValue<string>().Should().Be("https://localhost:5103/");
        json["assetServicesUrl"]!.GetValue<string>().Should().Be("https://localhost:5101");
        json["edaAdapterUrl"]!.GetValue<string>().Should().Be("https://localhost:5122/");
        json["tenantId"]!.GetValue<string>().Should().Be("voestalpine", "what the app owns stays");
        json["clientId"]!.GetValue<string>().Should().Be("voestalpine-frontend-debug");
        json["supportedLanguages"]!.AsArray().Should().HaveCount(1);
        File.ReadAllText(Path.Combine(repo, "src/voestalpine/src/assets/config.json")).Should().Contain("https://localhost:5003/", "the repository is not touched");
    }

    [Fact]
    public void A_generated_file_stays_in_its_folder_and_needs_its_base_file()
    {
        var repo = _checkout.Repo("octo-a");
        DevStackConfig Config(string file) => ConfigStore.Parse($$"""
                                                                  rootPath: {{_checkout.Root}}
                                                                  services:
                                                                    app:
                                                                      repo: octo-a
                                                                      args: [x]
                                                                      ports: [4300]
                                                                      files:
                                                                        - {{file}}
                                                                  """);

        var escaping = () => ServiceFiles.Write(Config("{ path: ../../outside.json, set: { a: b } }"), Second, _checkout.StateDirectory, "app", repo);
        escaping.Should().Throw<InvalidOperationException>().WithMessage("*leaves its folder*");
        var missing = () => ServiceFiles.Write(Config("{ path: c.json, from: nope.json }"), Second, _checkout.StateDirectory, "app", repo);
        missing.Should().Throw<InvalidOperationException>().WithMessage("*nope.json*does not exist*");

        // A value that names a service the configuration does not have keeps what the base file says (here: nothing).
        var partial = ServiceFiles.Write(Config("""{ path: p.json, set: { own: "{port.app.0}", other: "https://localhost:{port.nope.https}" } }"""), Second,
            _checkout.StateDirectory, "app", repo);
        JsonNode.Parse(File.ReadAllText(partial.Single()))!.AsObject().Select(p => p.Key).Should().Equal("own");

        var plain = ServiceFiles.Write(Config("""{ path: c.json, set: { url: "http://localhost:{port.app.0}" } }"""), Second, _checkout.StateDirectory, "app", repo);
        JsonNode.Parse(File.ReadAllText(plain.Single()))!["url"]!.GetValue<string>().Should().Be("http://localhost:4300", "the config given here is not shifted");
    }

    [Fact]
    public async Task A_slot_start_writes_the_files_of_its_services_and_the_default_slot_none()
    {
        var repo = _checkout.Repo("octo-a");
        File.WriteAllText(Path.Combine(repo, "config.json"), """{ "authorityUrl": "https://localhost:5003", "clientId": "c1" }""");
        var port = FreePort();
        var store = _checkout.WriteConfig($$"""
                                              app:
                                                repo: octo-a
                                                workingDirectory: .
                                                command: pwsh
                                                args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                                ports: [{{port}}]
                                                slot:
                                                  args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 31"]
                                                files:
                                                  - path: assets/config.json
                                                    from: config.json
                                                    set:
                                                      authorityUrl: "https://localhost:{shift:5003}"
                                                      self: "http://localhost:{port.app.0}"
                                            """);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        var generated = Path.Combine(_checkout.StateDirectory, "slots", "second", "services", "app", "assets", "config.json");

        await supervisor.StartStackAsync("a", new StartSpec(), null, false, false, TimeSpan.FromSeconds(1), Ct);
        File.Exists(generated).Should().BeFalse("the default slot runs the app as its repository configures it");

        var started = await supervisor.StartStackAsync("b", new StartSpec { Slot = "second" }, null, false, false, TimeSpan.FromSeconds(1), Ct);

        started.Notes.Should().Contain(n => n.Contains("wrote") && n.Contains(generated));
        var json = JsonNode.Parse(File.ReadAllText(generated))!;
        json["authorityUrl"]!.GetValue<string>().Should().Be("https://localhost:5103");
        json["self"]!.GetValue<string>().Should().Be($"http://localhost:{port + 100}");
        json["clientId"]!.GetValue<string>().Should().Be("c1");
        (await supervisor.StatusAsync()).Slots!.Single(s => s.Name == "second").Services.Single().Ports.Should().Equal(port + 100);
        var slotService = started.Status.Services.Single();
        slotService.Args.Should().Contain("Start-Sleep 31", "the slot variant replaces the whole argument list");
        ProcessTree.IsAlive(slotService.Pid).Should().BeTrue("the slot's process still runs");
        await supervisor.StopServicesAsync("a", null, Ct);
        await supervisor.StopServicesAsync("b", null, Ct, "second");
    }

    // ---------- identity overlay ----------

    [Fact]
    public void The_slots_overlays_carry_the_apps_redirect_uris_per_tenant()
    {
        var shifted = SlotDeriver.Apply(Default, Second, "/state/slots/second").Config;

        var system = SlotArtifacts.RenderOverlay(shifted, Second, "/state/slots/second");
        system.Should().Contain("- clientId: voestalpine-frontend-debug").And.Contain("- https://localhost:4400/")
            .And.NotContain("energy-community-app-debug", "that client lives in the app-host tenant");

        var tenants = SlotArtifacts.RenderTenantOverlays(shifted, Second, "/state/slots/second");
        tenants.Keys.Should().Equal("energycommunitymanagement");
        var overlay = new YamlDotNet.Serialization.Deserializer().Deserialize<Dictionary<string, object>>(tenants["energycommunitymanagement"]);
        overlay["overlayName"].Should().Be("local-dev-second-energycommunitymanagement");
        var client = overlay["clients"].As<List<object>>().Single().As<Dictionary<object, object>>();
        client["clientId"].Should().Be("energy-community-app-debug");
        client["redirectUris"].As<List<object>>().Should().Equal("https://localhost:44586/", "https://localhost:44586/silent-refresh.html");
        client["allowedCorsOrigins"].As<List<object>>().Should().Equal("https://localhost:44586");

        var paths = SlotArtifacts.Write(shifted, Second, Path.Combine(_checkout.StateDirectory, "slots", "second"));
        paths.TenantOverlays!["energycommunitymanagement"].Should().EndWith("identity-overlay.energycommunitymanagement.yaml");
        File.Exists(paths.TenantOverlays["energycommunitymanagement"]).Should().BeTrue();
        SlotArtifacts.ApplyCommand(Second, "/o.yaml", "energycommunitymanagement").Should().Contain("octo-cli --context local-second_energycommunitymanagement @args");
    }

    // ---------- the app host ----------

    private (string Root, string Overlay) BuiltApp()
    {
        var root = Path.Combine(_checkout.Root, "dist");
        var overlay = Path.Combine(_checkout.Root, "overlay");
        Directory.CreateDirectory(Path.Combine(root, "assets"));
        Directory.CreateDirectory(Path.Combine(overlay, "assets"));
        File.WriteAllText(Path.Combine(root, "index.html"), "<html>app</html>");
        File.WriteAllText(Path.Combine(root, "main.js"), "console.log(1)");
        File.WriteAllText(Path.Combine(root, "assets", "config.json"), """{"authorityUrl":"https://localhost:5003"}""");
        File.WriteAllText(Path.Combine(root, "assets", "logo.svg"), "<svg/>");
        File.WriteAllText(Path.Combine(overlay, "assets", "config.json"), """{"authorityUrl":"https://localhost:5103"}""");
        return (root, overlay);
    }

    [Fact]
    public void The_app_host_serves_the_overlay_first_then_the_build_and_index_html_for_routes()
    {
        var (root, overlay) = BuiltApp();
        var options = new AppHostOptions(root, overlay, "https://localhost:4400", []);

        AppHost.Resolve(options, "/assets/config.json").Should().Be(Path.Combine(overlay, "assets", "config.json"));
        AppHost.Resolve(options, "/assets/logo.svg").Should().Be(Path.Combine(root, "assets", "logo.svg"));
        AppHost.Resolve(options, "/main.js").Should().Be(Path.Combine(root, "main.js"));
        AppHost.Resolve(options, "/").Should().Be(Path.Combine(root, "index.html"));
        AppHost.Resolve(options, "/voestalpine/facilities/42").Should().Be(Path.Combine(root, "index.html"), "a route of the app");
        AppHost.Resolve(options, "/assets/missing.png").Should().BeNull("a missing file is a 404, not the app");
        AppHost.Resolve(options, "/../../etc/passwd.txt").Should().BeNull();
        AppHost.Resolve(options, "/%2e%2e/%2e%2e/secret.json").Should().BeNull();
        AppHost.Resolve(options with { Overlay = null }, "/assets/config.json").Should().Be(Path.Combine(root, "assets", "config.json"));
    }

    [Fact]
    public void The_app_host_reads_its_arguments_and_proxy_rules()
    {
        var options = AppHostOptions.Parse([
            AppHost.Switch, "--root", "/app/dist", "--overlay", "/state/o", "--url", "https://localhost:4400", "--proxy", "^/tenant(/.*)?$=https://localhost:5101",
            "--proxy", "^/[a-z]+/public-api/x$=https://localhost:5120|/public-api/=>/"
        ]);

        // The host makes both folders absolute: "/app/dist" is "C:\app\dist" on Windows.
        options.Should().BeEquivalentTo(new { Root = Path.GetFullPath("/app/dist"), Overlay = Path.GetFullPath("/state/o"), Url = "https://localhost:4400" });
        options.Proxies[0].TargetOf("/tenant/graphql", "?a=1").Should().Be("https://localhost:5101/tenant/graphql?a=1");
        options.Proxies[0].TargetOf("/tenants", "").Should().BeNull();
        options.Proxies[1].TargetOf("/demo/public-api/x", "").Should().Be("https://localhost:5120/demo/x");
        var noRoot = () => AppHostOptions.Parse([AppHost.Switch, "--url", "http://localhost:1"]);
        noRoot.Should().Throw<ArgumentException>().WithMessage("*--root*");
        var badProxy = () => AppHostOptions.Parse([AppHost.Switch, "--root", "/x", "--url", "http://localhost:1", "--proxy", "nonsense"]);
        badProxy.Should().Throw<ArgumentException>().WithMessage("*path regex*");
    }

    [Fact]
    public async Task The_daemon_binary_serves_a_built_app_with_its_overlay()
    {
        var (root, overlay) = BuiltApp();
        var port = FreePort();
        var psi = new ProcessStartInfo("dotnet") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var arg in new[] { ServicePlanner.DaemonAssembly, AppHost.Switch, "--root", root, "--overlay", overlay, "--url", $"http://127.0.0.1:{port}" })
        {
            psi.ArgumentList.Add(arg);
        }

        var process = Process.Start(psi)!;
        _processes.Add(process);
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        var url = $"http://127.0.0.1:{port}";
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (true)
        {
            try
            {
                using var probe = await http.GetAsync(url + "/", Ct);
                break;
            }
            catch (HttpRequestException) when (DateTime.UtcNow < deadline && !process.HasExited)
            {
                await Task.Delay(100, Ct);
            }
        }

        (await http.GetStringAsync(url + "/assets/config.json", Ct)).Should().Contain("5103", "the overlay wins over the built config");
        (await http.GetStringAsync(url + "/some/route", Ct)).Should().Be("<html>app</html>");
        using var config = await http.GetAsync(url + "/assets/config.json", Ct);
        config.Content.Headers.ContentType!.MediaType.Should().Be("application/json");
        config.Headers.CacheControl!.NoStore.Should().BeTrue();
        using var missing = await http.GetAsync(url + "/assets/missing.png", Ct);
        missing.StatusCode.Should().Be(HttpStatusCode.NotFound);
        using var post = await http.PostAsync(url + "/assets/config.json", new StringContent("x"), Ct);
        post.StatusCode.Should().Be(HttpStatusCode.MethodNotAllowed, "the host is read-only");
    }

    [Fact]
    public async Task The_app_host_says_that_the_app_is_not_built()
    {
        var psi = new ProcessStartInfo("dotnet") { UseShellExecute = false, RedirectStandardError = true, RedirectStandardOutput = true, CreateNoWindow = true };
        foreach (var arg in new[] { ServicePlanner.DaemonAssembly, AppHost.Switch, "--root", Path.Combine(_checkout.Root, "nothing"), "--url", "http://127.0.0.1:1" })
        {
            psi.ArgumentList.Add(arg);
        }

        var process = Process.Start(psi)!;
        _processes.Add(process);
        var error = await process.StandardError.ReadToEndAsync(Ct);
        await process.WaitForExitAsync(Ct);

        process.ExitCode.Should().Be(3);
        error.Should().Contain("not built").And.Contain("lane_build for a lane");
    }

    private static int FreePort() => TestPorts.Free();

}
