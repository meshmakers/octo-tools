using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The setup of a lane stack (stack_setup and the automatic run after a start) and the login script of its login step.
///     Fakes only: <see cref="FakePwsh"/> for the octo-tools calls, a fake HTTP handler for the identity setup API, a contexts
///     file of the test, and for the login script a fake octo-cli run through pwsh - no OctoMesh service, no octo-tools.
/// </summary>
public sealed class SlotSetupTests : IDisposable
{
    private readonly TestCheckout _checkout = new();
    private readonly FakePwsh _fake = new() { Capabilities = FakePwsh.EnvironmentParams };
    private readonly List<StackSupervisor> _supervisors = [];

    public void Dispose()
    {
        foreach (var run in _supervisors.SelectMany(s => s.Runs))
        {
            foreach (var pid in run.Pids().Where(ProcessTree.IsAlive))
            {
                ProcessTree.TerminateAsync(pid, TimeSpan.FromSeconds(2), CancellationToken.None).GetAwaiter().GetResult();
            }
        }

        _checkout.Dispose();
    }

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private const string Lane = "ab1-one";

    private const string IdentityService = """
                                             identityServices:
                                               repo: octo-a
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--urls=https://0.0.0.0:5003;http://0.0.0.0:5002"]
                                               ports: [5003, 5002]
                                           """;

    private sealed class FakeHttp(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public List<string> Requests { get; } = [];

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add(request.RequestUri!.ToString());
            return Task.FromResult(answer(request));
        }
    }

    /// <summary>A lane as New-OctoEnvironment leaves it: &lt;rootPath&gt;/wt-&lt;lane&gt; with Octo.User.props, the manifest and octo-a.</summary>
    private string LaneFolder()
    {
        var folder = Path.Combine(_checkout.Root, "wt-" + Lane);
        Directory.CreateDirectory(Path.Combine(folder, ".octo"));
        Directory.CreateDirectory(Path.Combine(folder, "octo-a"));
        File.WriteAllText(Path.Combine(folder, "octo-a", "octo-a.sln"), "");
        File.WriteAllText(Path.Combine(folder, "Octo.User.props"), "<Project />");
        var manifest = new
        {
            schemaVersion = 1, name = Lane, workItem = "AB#1234", @base = "branches/main", created = "2026-11-20T09:00:00+01:00", owner = "reimar/AB#1234_x",
            repos = new[] { new { name = "octo-a", role = "feature", path = Path.Combine(folder, "octo-a"), branch = "reimar/AB#1234_x", baseCommit = "abc123" } },
            slot = (string?)null
        };
        File.WriteAllText(EnvironmentDiscovery.ManifestPath(folder), JsonSerializer.Serialize(manifest, JsonSerializerOptions.Web));
        return folder;
    }

    private sealed record Setup(SlotOperations Ops, StackSupervisor Supervisor, ConfigStore Store, string Octo, string Contexts, FakeHttp Http);

    /// <summary>The daemon's pieces around a lane: the identity setup API answers <paramref name="identity"/>, the contexts file has the system context.</summary>
    private Setup Create(string identityYaml = IdentityService, Func<HttpRequestMessage, HttpResponseMessage>? identity = null, string extra = "")
    {
        _checkout.Repo("octo-a");
        var store = _checkout.WriteConfig(identityYaml, extra);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        _supervisors.Add(supervisor);
        var folder = LaneFolder();
        var contexts = Path.Combine(_checkout.Root, "contexts.json");
        File.WriteAllText(contexts, """{"Contexts":{"local-ab1-one_octosystem":{}}}""");
        var http = new FakeHttp(identity ?? (_ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"success":true}""") }));
        var ops = new SlotOperations(store, supervisor, _fake, http, Path.Combine(_checkout.Root, "octo-tools-config", "installations.json"),
            new PreStartChecks([], contexts));
        supervisor.Setup = ops;
        return new Setup(ops, supervisor, store, Path.Combine(folder, ".octo"), contexts, http);
    }

    /// <summary>Register-OctoCliContext, the login script (marker by <paramref name="login"/>) and Invoke-IdentityOverlay answer like octo-tools.</summary>
    private void Answer(Func<string, string>? login = null, bool overlayFails = false) =>
        _fake.Build = (body, _, _) => Task.FromResult(
            body.Contains("LogInClientCredentials", StringComparison.Ordinal)
                ? new PwshResult(0, "octo-cli noise\n" + PwshRunner.Marker + " " + (login ?? LoggedIn)(body) + "\n", false, false)
                : body.Contains("Invoke-IdentityOverlay", StringComparison.Ordinal)
                    ? FakePwsh.Ok("Invoke-IdentityOverlay", overlayFails ? """{"summary":{"failed":2}}""" : """{"summary":{"failed":0}}""", overlayFails ? 1 : 0)
                    : FakePwsh.Ok("Register-OctoCliContext", """{"success":true}"""));

    private static string LoggedIn(string body) => body.Contains("if ($true) {", StringComparison.Ordinal)
        ? """{"created":true,"step":"done","error":null,"adminLoginKept":null,"contexts":[{"name":"local-ab1-one_octosystem","loggedIn":true}]}"""
        : """{"created":false,"step":"done","error":null,"adminLoginKept":null,"contexts":[{"name":"local-ab1-one_octosystem","loggedIn":true}]}""";

    private List<string> Scripts() => _fake.Calls.Select(c => FakePwsh.Strip(c.Body)).ToList();

    [Fact]
    public async Task Stack_setup_runs_every_step_on_a_fresh_lane_stack_and_later_only_logs_in_again()
    {
        var setup = Create();
        Answer();

        var first = await setup.Ops.SetupAsync("agent-1", Lane, null, null, [], false, Ct);

        first.Success.Should().BeTrue();
        first.Lane.Should().Be(Lane);
        first.Steps.Select(s => (s.Step, s.Status)).Should().Equal(("admin", "done"), ("octoCli", "done"), ("login", "done"), ("overlay", "done"));
        first.Warnings.Should().BeEmpty();
        first.Steps[2].Summary.Should().Contain("Client devstack-ab1-one created");
        first.Shell.Should().Contain("export OCTO_CLI_CLIENT_ID=devstack-ab1-one");
        var password = JsonNode.Parse(File.ReadAllText(Path.Combine(setup.Octo, SlotOperations.CredentialsFileName)))!["password"]!.GetValue<string>();
        var secret = File.ReadAllText(Path.Combine(setup.Octo, SlotOperations.ClientSecretFileName)).Trim();
        JsonSerializer.Serialize(first).Should().NotContain(password).And.NotContain(secret, "secrets stay in their owner-only files");
        setup.Http.Requests.Should().Equal("https://localhost:5103/octosystem/api/setup/create-admin");
        var scripts = Scripts();
        scripts.Should().HaveCount(3, "the login step does not register the contexts the octoCli step just registered");
        scripts[0].Should().Be("Register-OctoCliContext -Installation 'local-ab1-one' -TenantId @('octosystem') -NoSwitch -NoLogin -Json");
        scripts[1].Should().Contain("if ($true) {").And.Contain("LogInClientCredentials");
        scripts[2].Should().Contain("Invoke-IdentityOverlay").And.Contain("--context local-ab1-one_octosystem");

        // What stack_list and stack_status show afterwards.
        var info = setup.Supervisor.Registry.Resolve(Lane, create: false);
        SlotOperations.LastSetup(setup.Supervisor.StateDirectory, info)!.Steps.Should().HaveCount(4);
        (await setup.Supervisor.SummariesAsync()).Single(s => s.Name == Lane).Setup!.Trigger.Should().Be("stack_setup");
        (await setup.Supervisor.SummariesAsync()).Single(s => s.Name == "default").Setup.Should().BeNull();
        (await setup.Supervisor.StatusAsync(slot: Lane)).Setup!.Success.Should().BeTrue();

        // Again (token expired, stack restarted): the admin exists, the client too - only the login runs.
        _fake.Calls.Clear();
        var again = await setup.Ops.SetupAsync("agent-1", Lane, null, null, [], false, Ct);

        again.Steps.Select(s => (s.Step, s.Status)).Should().Equal(("admin", "unchanged"), ("octoCli", "done"), ("login", "done"), ("overlay", "done"));
        setup.Http.Requests.Should().HaveCount(1, "an existing credentials file is never overwritten, nothing is sent");
        Scripts()[1].Should().Contain("if ($false) {", "the client exists: no admin login, no client creation");
        File.ReadAllText(Path.Combine(setup.Octo, SlotOperations.ClientSecretFileName)).Trim().Should().Be(secret);

        // One step: the login registers its contexts itself (they exist, a login left in them is gone).
        _fake.Calls.Clear();
        var login = await setup.Ops.SetupAsync("agent-1", Lane, null, ["Login"], ["MeshTest"], false, Ct);

        login.Steps.Select(s => s.Step).Should().Equal("login");
        Scripts()[0].Should().Be("Register-OctoCliContext -Installation 'local-ab1-one' -TenantId @('octosystem','meshtest') -NoSwitch -NoLogin -Json");
        Scripts()[1].Should().Contain("foreach ($context in @('local-ab1-one_octosystem', 'local-ab1-one_meshtest'))");
    }

    [Fact]
    public async Task Stack_setup_records_the_session_next_to_the_lane_that_holds_the_lease()
    {
        var setup = Create();
        Answer();

        var result = await new Tools.SlotOpsTools(setup.Ops).Setup("reimar/AB#1234_x", lane: Lane, steps: ["octoCli"], session: "meshmakers-07", cancellationToken: Ct);

        result.Success.Should().BeTrue();
        var lease = setup.Supervisor.Leases.Get(Lane).Current()!;
        lease.Owner.Should().Be("lane:" + Lane, "the lane holds its stack's lease");
        lease.Session.Should().Be("meshmakers-07");
        lease.Purpose.Should().Contain("reimar/AB#1234_x");
    }

    [Fact]
    public async Task A_failed_step_is_a_warning_with_the_call_that_repeats_it_and_the_steps_that_need_it_are_skipped()
    {
        // The identity service does not answer: no admin; the contexts are registered; the login cannot create the client.
        var setup = Create(identity: _ => throw new HttpRequestException("connection refused"));
        Answer();

        var result = await setup.Ops.SetupAsync("agent-1", Lane, null, null, [], false, Ct);

        result.Success.Should().BeFalse();
        result.Steps.Select(s => (s.Step, s.Status)).Should().Equal(("admin", "failed"), ("octoCli", "done"), ("login", "failed"), ("overlay", "skipped"));
        result.Steps[0].Summary.Should().Contain("does not answer");
        result.Steps[2].Summary.Should().Contain("needs the slot's admin");
        result.Warnings.Should().Contain(w => w.StartsWith("Setup step 'admin' of lane stack 'ab1-one' failed") &&
                                              w.Contains("Repair: stack_setup(owner, lane=\"ab1-one\", steps=[\"admin\"])"));
        result.Warnings.Should().Contain(w => w.Contains("Repair: stack_setup(owner, lane=\"ab1-one\", steps=[\"login\"])"));
        File.Exists(Path.Combine(setup.Octo, SlotOperations.CredentialsFileName)).Should().BeFalse("no admin was created");
        File.Exists(Path.Combine(setup.Octo, SlotOperations.ClientSecretFileName)).Should().BeFalse();

        // The login script reports a context it could not log in: the login step fails, the overlay is skipped.
        File.WriteAllText(Path.Combine(setup.Octo, SlotOperations.ClientSecretFileName), "old\n");
        Answer(login: _ => """{"created":false,"step":"done","error":null,"contexts":[{"name":"local-ab1-one_octosystem","loggedIn":false,"note":"invalid_client"}]}""");
        var stale = await setup.Ops.SetupAsync("agent-1", Lane, null, ["login", "overlay"], [], false, Ct);

        stale.Steps.Select(s => (s.Step, s.Status)).Should().Equal(("login", "failed"), ("overlay", "skipped"));
        stale.Steps[0].Summary.Should().Contain("invalid_client").And.Contain("renew=true");

        // A failing overlay is a warning of its own.
        Answer(overlayFails: true);
        var overlay = await setup.Ops.SetupAsync("agent-1", Lane, null, ["overlay"], [], false, Ct);
        overlay.Steps.Single().Status.Should().Be("failed");
        overlay.Warnings.Single().Should().Contain("Identity overlay failed").And.Contain("FAILED (exit 1)").And.Contain("steps=[\"overlay\"]");
    }

    [Fact]
    public async Task The_first_setup_of_a_fresh_lane_applies_no_overlay_of_a_tenant_it_did_not_log_in_and_a_failure_names_its_cause()
    {
        // AB#9676: an app keeps its client in tenant energycommunitymanagement; a context of that tenant is left in the contexts
        // file from an earlier stack of the same name, but the fresh lane has only the system tenant.
        var setup = Create(IdentityService + """

                                               app:
                                                 repo: octo-a
                                                 workingDirectory: .
                                                 command: pwsh
                                                 identityClients:
                                                   - clientId: app-debug
                                                     tenant: energycommunitymanagement
                                                     redirectUris: ["https://localhost:4400/"]
                                             """);
        File.WriteAllText(setup.Contexts, """{"Contexts":{"local-ab1-one_octosystem":{},"local-ab1-one_energycommunitymanagement":{}}}""");
        Answer();

        var first = await setup.Ops.SetupAsync("agent-1", Lane, null, null, [], false, Ct);

        first.Success.Should().BeTrue();
        first.Steps.Select(s => (s.Step, s.Status)).Should().Equal(("admin", "done"), ("octoCli", "done"), ("login", "done"), ("overlay", "done"));
        first.Steps[3].Summary.Should().Contain("of tenant 'energycommunitymanagement' was not applied: this setup did not log in tenant 'energycommunitymanagement'");
        Scripts().Should().NotContain(s => s.Contains("--context local-ab1-one_energycommunitymanagement"));

        // The overlay answers exit 0 but reports failed clients: the step names that and the failed clients, not "exit 0".
        _fake.Build = (body, _, _) => Task.FromResult(body.Contains("Invoke-IdentityOverlay", StringComparison.Ordinal)
            ? FakePwsh.Ok("Invoke-IdentityOverlay",
                """{"clients":[{"client":"octo-cli","status":"applied"},{"client":"voest-debug","status":"failed (exit 253)"},""" +
                """{"client":"app-debug","status":"failed (exit 253)"}],"summary":{"failed":2}}""")
            : FakePwsh.Ok("Register-OctoCliContext", """{"success":true}"""));
        var failed = await setup.Ops.SetupAsync("agent-1", Lane, null, ["overlay"], [], false, Ct);

        failed.Steps.Single().Status.Should().Be("failed");
        failed.Steps.Single().Summary.Should().Contain("FAILED (2 client(s) failed)").And.NotContain("exit 0")
            .And.Contain("client voest-debug failed (exit 253); client app-debug failed (exit 253)").And.NotContain("octo-cli applied")
            .And.NotEndWith("}");
    }

    [Fact]
    public async Task A_failed_octo_cli_step_shows_the_error_records_message_not_the_last_wrapped_line()
    {
        // e2e 2026-11-20: the daemon's PATH was stale, octo-cli did not resolve; the summary showed "spelling of the name, ...".
        var setup = Create();
        _fake.Build = (_, _, _) => Task.FromResult(new PwshResult(1,
            "Registering local-ab1-one ...\n" +
            "Register-OctoCliContext: C:\\dev\\meshmakers\\octo-tools\\modules\\OctoCli.psm1:42\n" +
            "Line |\n" +
            "  42 |      & octo-cli -c AddContext @arguments\n" +
            "     |        ~~~~~~~~\n" +
            "     | The term 'octo-cli' is not recognized as a name of a cmdlet, function, script file, or executable program. Check the\n" +
            "     | spelling of the name, or if a path was included, verify that the path is correct and try again.\n", false, false));

        var result = await setup.Ops.SetupAsync("agent-1", Lane, null, ["octoCli"], [], false, Ct);

        var step = result.Steps.Single();
        step.Status.Should().Be("failed");
        step.Summary.Should().Be("Register-OctoCliContext failed: Register-OctoCliContext: The term 'octo-cli' is not recognized as a name of a cmdlet, " +
                                 "function, script file, or executable program. Check the spelling of the name, or if a path was included, verify that the path " +
                                 "is correct and try again.");
        result.Warnings.Single().Should().Contain("The term 'octo-cli' is not recognized").And.Contain("steps=[\"octoCli\"]");
    }

    [Fact]
    public async Task Stack_setup_refuses_unknown_steps_the_shared_stack_and_a_caller_without_the_lease()
    {
        var setup = Create();

        var unknown = () => setup.Ops.SetupAsync("agent-1", Lane, null, ["admin", "bogus"], [], false, Ct);
        await unknown.Should().ThrowAsync<ArgumentException>().WithMessage("*'bogus'*admin, octoCli, login, overlay*");
        var shared = () => setup.Ops.SetupAsync("agent-1", null, "default", null, [], false, Ct);
        await shared.Should().ThrowAsync<ArgumentException>().WithMessage("*shared stack*");
        var neither = () => setup.Ops.SetupAsync("agent-1", null, null, null, [], false, Ct);
        await neither.Should().ThrowAsync<ArgumentException>().WithMessage("*lane=<lane> or slot=<slot>*");

        // A named slot is held by whoever started it; another owner is refused before anything runs.
        setup.Supervisor.Registry.Resolve("second", create: true);
        setup.Supervisor.Leases.Get("second").Require("agent-1");
        var foreign = () => setup.Ops.SetupAsync("agent-2", null, "second", null, [], false, Ct);
        await foreign.Should().ThrowAsync<LeaseHeldException>().WithMessage("*held by 'agent-1'*", "the refusal is the slot's lease, nothing else");
        _fake.Calls.Should().BeEmpty("nothing ran");
        setup.Http.Requests.Should().BeEmpty();
    }

    [Fact]
    public async Task A_frontend_that_runs_only_as_a_profile_instance_keeps_its_client_in_the_overlay()
    {
        // The instance web2 is a copy of web: its identityClients are web's, so the overlay keeps web-debug; the client of
        // other, a configured service that does not run, is left out (system tenant and tenant file alike).
        var setup = Create(IdentityService + """

                                               web:
                                                 repo: octo-a
                                                 workingDirectory: .
                                                 command: pwsh
                                                 args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                                 identityClients:
                                                   - clientId: web-debug
                                                     redirectUris: ["https://localhost:4200/"]
                                                   - clientId: web-tenant-debug
                                                     tenant: energycommunitymanagement
                                                     redirectUris: ["https://localhost:4200/"]
                                               other:
                                                 repo: octo-a
                                                 workingDirectory: .
                                                 command: pwsh
                                                 identityClients:
                                                   - clientId: other-debug
                                                     redirectUris: ["https://localhost:4300/"]
                                                   - clientId: other-tenant-debug
                                                     tenant: energycommunitymanagement
                                                     redirectUris: ["https://localhost:4300/"]
                                             """);
        Answer();
        var started = await setup.Supervisor.StartStackAsync("lane:ab1-one", new StartSpec
        {
            Slot = Lane, Checkout = "wt-" + Lane, Services = ["web2"],
            Instances = new() { ["web2"] = new ProfileInstance { Of = "web", Ports = [TestPorts.Free()] } }
        }, null, false, false, TimeSpan.FromSeconds(1), Ct);
        setup.Supervisor.Slot(Lane).LiveServices().Should().ContainSingle(s => s.Service == "web2");
        var directory = SlotDeriver.SlotDirectory(setup.Supervisor.StateDirectory, setup.Supervisor.Registry.Resolve(Lane, false));
        var system = SlotArtifacts.PathsOf(directory).IdentityOverlay;
        var tenant = Path.Combine(directory, "identity-overlay.energycommunitymanagement.yaml");

        // Written by the start itself, then again by the overlay step: both hold the same clients.
        foreach (var pass in new[] { "start", "overlay step" })
        {
            if (pass == "overlay step")
            {
                (await setup.Ops.SetupAsync("agent-1", Lane, null, ["overlay"], [], false, Ct)).Steps.Single().Status.Should().Be("done");
            }

            File.ReadAllText(system).Should().Contain("clientId: web-debug", pass).And.NotContain("other-debug", pass);
            File.ReadAllText(tenant).Should().Contain("clientId: web-tenant-debug", pass).And.NotContain("other-tenant-debug", pass);
        }

        await setup.Supervisor.StopServicesAsync("lane:ab1-one", null, Ct, slot: Lane);
    }

    [Fact]
    public async Task The_start_of_a_lane_stack_sets_it_up_once_its_identity_service_is_healthy()
    {
        // identityServices: a sleeping pwsh whose health URL is a listener of the test.
        var port = TestPorts.Free();
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        using var stop = new CancellationTokenSource();
        var serve = Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    var context = await listener.GetContextAsync();
                    context.Response.StatusCode = 200;
                    context.Response.Close();
                }
                catch (Exception e) when (e is HttpListenerException or ObjectDisposedException or InvalidOperationException)
                {
                    return;
                }
            }
        }, Ct);
        try
        {
            var ports = TestPorts.Free();
            var identity = IdentityService.Replace("5003", ports.ToString()).Replace("5002", (ports + 1).ToString()) +
                           $"\n    healthUrl: http://127.0.0.1:{port}/health\n" +
                           // A configured app this start does not run: its client is not in the lane's identity server.
                           "  voestApp:\n    repo: octo-a\n    workingDirectory: .\n    command: pwsh\n" +
                           "    identityClients:\n      - clientId: voest-debug\n        redirectUris: [\"https://localhost:4300/\"]\n";
            var setup = Create(identity);
            Answer();

            var started = await setup.Supervisor.StartStackAsync("lane:ab1-one", new StartSpec { Slot = Lane, Checkout = "wt-" + Lane, Services = ["identityServices"] },
                null, false, true, TimeSpan.FromSeconds(30), Ct);

            started.Setup.Should().NotBeNull();
            started.Setup!.Trigger.Should().Be("after the start");
            started.Setup.Steps.Select(s => (s.Step, s.Status)).Should().Equal(("admin", "done"), ("octoCli", "done"), ("login", "done"), ("overlay", "done"));
            started.Notes.Should().Contain("Setup of lane stack 'ab1-one' (after the start): admin done; octoCli done; login done; overlay done.");
            started.Warnings.Should().NotContain(w => w.Contains("Setup step"));
            var slotInfo = setup.Supervisor.Registry.Resolve(Lane, false);
            File.ReadAllText(SlotArtifacts.PathsOf(SlotDeriver.SlotDirectory(setup.Supervisor.StateDirectory, slotInfo)).IdentityOverlay)
                .Should().NotContain("voest-debug", "the overlay holds only the clients of the services the slot runs");
            setup.Http.Requests.Should().ContainSingle().Which.Should().Be($"https://localhost:{ports + 100}/octosystem/api/setup/create-admin",
                "the identity port of the lane's slot");
            (await setup.Supervisor.StatusAsync(slot: Lane)).Setup!.Trigger.Should().Be("after the start");

            // A start that does not wait for health cannot know the identity service is up: the note names stack_setup.
            await setup.Supervisor.StopServicesAsync("lane:ab1-one", null, Ct, slot: Lane);
            _fake.Calls.Clear();
            var unwaited = await setup.Supervisor.StartStackAsync("lane:ab1-one", new StartSpec { Slot = Lane, Checkout = "wt-" + Lane, Services = ["identityServices"] },
                null, false, false, TimeSpan.FromSeconds(30), Ct);
            unwaited.Setup.Should().BeNull();
            unwaited.Notes.Should().Contain(n => n.Contains("was not set up (the start did not wait for health)") && n.Contains("stack_setup(owner, lane=\"ab1-one\")"));
            _fake.Calls.Should().BeEmpty();
        }
        finally
        {
            // Also after a failed assertion: the listener is the test's own, and GetContextAsync ends only when it closes.
            await stop.CancelAsync();
            listener.Close();
            await serve;
        }
    }

    [Fact]
    public async Task Without_auto_setup_a_start_only_names_stack_setup_and_the_shared_stack_never_gets_one()
    {
        var setup = Create(IdentityService.Replace("ports: [5003, 5002]", "ports: []"), extra: "slotOptions: { autoSetup: false, smokeCheck: false }");
        Answer();

        var lane = await setup.Supervisor.StartStackAsync("lane:ab1-one", new StartSpec { Slot = Lane, Checkout = "wt-" + Lane, Services = ["identityServices"] },
            null, false, true, TimeSpan.FromSeconds(30), Ct);

        lane.Setup.Should().BeNull();
        lane.Notes.Should().Contain(n => n.Contains("was not set up (slotOptions.autoSetup is off)"));
        await setup.Supervisor.StopServicesAsync("lane:ab1-one", null, Ct, slot: Lane);

        var shared = await setup.Supervisor.StartStackAsync("agent-1", new StartSpec { Services = ["identityServices"] }, null, false, true,
            TimeSpan.FromSeconds(30), Ct);
        shared.Setup.Should().BeNull();
        shared.Notes.Should().NotContain(n => n.Contains("set up"));
        _fake.Calls.Should().BeEmpty();
        setup.Http.Requests.Should().BeEmpty();
        await setup.Supervisor.StopServicesAsync("agent-1", null, Ct);
    }

    [Fact]
    public void An_older_devstack_yaml_with_applyIdentityOverlay_still_loads_and_auto_setup_is_on_by_default()
    {
        var store = _checkout.WriteConfig(IdentityService, "slotOptions: { applyIdentityOverlay: false, smokeCheck: true }");

        var config = store.Load();

        config.SlotOptions.AutoSetup.Should().BeTrue("the key it replaces is read and ignored");
        ConfigStore.Serialize(config).Should().NotContain("applyIdentityOverlay");
        ConfigStore.Parse(ConfigStore.ReadDefaultYaml()).SlotOptions.AutoSetup.Should().BeTrue();
    }

    // ---------- the login script with a fake octo-cli ----------

    /// <summary>
    ///     A fake octo-cli in pwsh with the context guard of octo-cli AB#9063: LogIn (device code) leaves a refresh token in
    ///     the context, LogInClientCredentials refuses a context that holds one. State: a JSON file (FAKE_OCTO_STATE).
    /// </summary>
    private const string FakeOctoCli = """
                                       $state = $env:FAKE_OCTO_STATE
                                       function Read-State { Get-Content -Raw -LiteralPath $state | ConvertFrom-Json -AsHashtable }
                                       function Write-State($s) { $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $state }
                                       $cmd = $null; $context = $null
                                       for ($i = 0; $i -lt $args.Count; $i++) {
                                           if ($args[$i] -eq '-c') { $cmd = $args[$i + 1] }
                                           if ($args[$i] -eq '--context') { $context = $args[$i + 1] }
                                       }
                                       $s = Read-State
                                       $s.calls += "$cmd $context"
                                       Write-State $s
                                       switch ($cmd) {
                                           'LogIn' {
                                               [Console]::Out.WriteLine('Enter the code: FAKE-1234'); [Console]::Out.Flush()
                                               $deadline = (Get-Date).AddSeconds(30)
                                               while (-not (Test-Path -LiteralPath "$state.approved") -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
                                               if (-not (Test-Path -LiteralPath "$state.approved")) { exit 3 }
                                               $s = Read-State
                                               $s.contexts[$context] = @{ refresh = $true; client = $false }
                                               Write-State $s
                                               [Console]::Out.WriteLine('Device log-in successful'); [Console]::Out.Flush()
                                           }
                                           'AddClientCredentialsClient' {
                                               if (-not $env:OCTO_CLI_NEW_CLIENT_SECRET -or $env:FAKE_FAIL_CREATE) { [Console]::Out.WriteLine('creating the client failed'); exit 4 }
                                           }
                                           'LogInClientCredentials' {
                                               if ($s.contexts[$context].refresh) {
                                                   [Console]::Out.WriteLine("Context '$context' holds an interactive login; a client-credentials login would replace it. Nothing was changed.")
                                                   exit 5
                                               }
                                               if (-not $env:OCTO_CLI_CLIENT_ID -or -not $env:OCTO_CLI_CLIENT_SECRET) { exit 6 }
                                               $s.contexts[$context] = @{ refresh = $false; client = $true }
                                               Write-State $s
                                           }
                                       }
                                       exit 0
                                       """;

    /// <summary>octo-tools and the identity service for the script: Register-OctoCliContext (AddContext writes the context anew) and Invoke-RestMethod.</summary>
    private static string Fakes(bool registerFails) => $$"""
                                                    $ErrorActionPreference = 'Stop'
                                                    function Invoke-RestMethod {
                                                        param($Method, $Uri, $WebSession, [switch]$SkipCertificateCheck, $ContentType, $Body)
                                                        if ($Uri -like '*/api/auth/login') { return [pscustomobject]@{ success = $true } }
                                                        if ($Uri -like '*/connect/deviceverification') {
                                                            Set-Content -LiteralPath "$($env:FAKE_OCTO_STATE).approved" -Value ok
                                                            return [pscustomobject]@{ success = $true }
                                                        }
                                                        throw "unexpected $Uri"
                                                    }
                                                    function Register-OctoCliContext {
                                                        param($Installation, [string[]]$TenantId, [switch]$NoSwitch, [switch]$NoLogin, [switch]$Json)
                                                        $s = Get-Content -Raw -LiteralPath $env:FAKE_OCTO_STATE | ConvertFrom-Json -AsHashtable
                                                        $s.calls += "Register $Installation $($TenantId -join ',')"
                                                        if (-not {{(registerFails ? "$true" : "$false")}}) {
                                                            foreach ($t in $TenantId) { $s.contexts["${Installation}_$t"] = @{ refresh = $false; client = $false } }
                                                        }
                                                        $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:FAKE_OCTO_STATE
                                                        $ok = if ({{(registerFails ? "$true" : "$false")}}) { 'false' } else { 'true' }
                                                        '{"schemaVersion":1,"command":"Register-OctoCliContext","data":{"success":' + $ok + ',"exitCode":0' + '}' + '}'
                                                    }

                                                    """;

    private async Task<(JsonObject Marker, JsonObject State)> RunLoginScriptAsync(bool createClient, bool registerFails = false, bool failCreate = false)
    {
        var folder = Path.Combine(_checkout.Root, "login");
        Directory.CreateDirectory(folder);
        var fake = Path.Combine(folder, "fake-octo-cli.ps1");
        File.WriteAllText(fake, FakeOctoCli);
        var stateFile = Path.Combine(folder, "state.json");
        File.Delete(stateFile + ".approved");
        // As RegisterOctoCliAsync leaves them before the script: both contexts registered, without a login.
        File.WriteAllText(stateFile, """{"contexts":{"local-ab1-one_octosystem":{"refresh":false,"client":false},"local-ab1-one_meshtest":{"refresh":false,"client":false}},"calls":[]}""");
        var secretFile = Path.Combine(folder, SlotOperations.ClientSecretFileName);
        File.WriteAllText(secretFile, "c2VjcmV0LW9mLXRoZS10ZXN0\n");
        var adminFile = Path.Combine(folder, SlotOperations.CredentialsFileName);
        File.WriteAllText(adminFile, """{"email":"admin@ab1-one.local","password":"Pw-Very-Secret-123!"}""");
        var script = SlotOperations.LoginScript("devstack-ab1-one", Lane, secretFile, adminFile, "https://localhost:1", "octosystem", "local-ab1-one",
            ["local-ab1-one_octosystem", "local-ab1-one_meshtest"], createClient, renew: false, octoCli: ["pwsh", "-NoProfile", "-NonInteractive", "-File", fake]);

        var psi = new System.Diagnostics.ProcessStartInfo("pwsh") { WorkingDirectory = folder };
        foreach (var arg in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", Fakes(registerFails) + script })
        {
            psi.ArgumentList.Add(arg);
        }

        var environment = new Dictionary<string, string?> { ["FAKE_OCTO_STATE"] = stateFile, ["FAKE_FAIL_CREATE"] = failCreate ? "1" : null };
        var result = await PwshRunner.RunProcessAsync(psi, new PwshRunOptions { Timeout = TimeSpan.FromMinutes(2), Environment = environment }, Ct);
        var marker = PwshRunner.ExtractMarker(result.Output) as JsonObject ?? throw new InvalidOperationException("no marker: " + result.Output);
        result.Output.Should().NotContain("Pw-Very-Secret-123!").And.NotContain("c2VjcmV0LW9mLXRoZS10ZXN0", "the script prints no secret");
        return (marker, (JsonNode.Parse(File.ReadAllText(stateFile)) as JsonObject)!);
    }

    private static bool Holds(JsonObject state, string context, string what) => state["contexts"]![context]![what]!.GetValue<bool>();

    [Fact]
    public async Task The_first_login_of_a_fresh_slot_logs_the_system_context_in_although_the_admin_logged_in_there_first()
    {
        // octo-cli refuses to replace an interactive login (AB#9063). The admin's device login lands in the system context; the
        // script registers that context anew before the client-credentials logins, so the first call logs every context in.
        var (marker, state) = await RunLoginScriptAsync(createClient: true);

        marker["error"].Should().BeNull();
        marker["created"]!.GetValue<bool>().Should().BeTrue();
        marker["adminLoginKept"].Should().BeNull();
        marker["contexts"]!.AsArray().Select(c => (c!["name"]!.GetValue<string>(), c["loggedIn"]!.GetValue<bool>()))
            .Should().Equal(("local-ab1-one_octosystem", true), ("local-ab1-one_meshtest", true));
        Holds(state, "local-ab1-one_octosystem", "refresh").Should().BeFalse("the admin's refresh token does not stay in the contexts");
        Holds(state, "local-ab1-one_octosystem", "client").Should().BeTrue();
        state["calls"]!.AsArray().Select(c => c!.GetValue<string>()).Should().Equal(
            "LogIn local-ab1-one_octosystem", "AddClientCredentialsClient local-ab1-one_octosystem", "AddClientToRole local-ab1-one_octosystem",
            "ProvisionClientInExistingTenants local-ab1-one_octosystem", "Register local-ab1-one octosystem",
            "LogInClientCredentials local-ab1-one_octosystem", "LogInClientCredentials local-ab1-one_meshtest");

        // The next call (the client exists): no admin login, no registration, only the logins.
        var (next, nextState) = await RunLoginScriptAsync(createClient: false);
        next["contexts"]!.AsArray().Should().OnlyContain(c => c!["loggedIn"]!.GetValue<bool>());
        nextState["calls"]!.AsArray().Select(c => c!.GetValue<string>()).Should().Equal(
            "LogInClientCredentials local-ab1-one_octosystem", "LogInClientCredentials local-ab1-one_meshtest");
    }

    [Fact]
    public async Task The_admins_device_login_is_dropped_also_when_the_client_cannot_be_created_and_a_kept_one_is_reported()
    {
        var (failed, state) = await RunLoginScriptAsync(createClient: true, failCreate: true);

        failed["step"]!.GetValue<string>().Should().Be("createClient");
        failed["error"]!.GetValue<string>().Should().Contain("AddClientCredentialsClient failed");
        Holds(state, "local-ab1-one_octosystem", "refresh").Should().BeFalse("the admin's login is dropped although the client creation failed");

        // The guard is real in the fake: when the context cannot be registered anew, the system context's login is refused.
        var (kept, keptState) = await RunLoginScriptAsync(createClient: true, registerFails: true);

        kept["adminLoginKept"]!.GetValue<string>().Should().Contain("Register-OctoCliContext failed");
        var system = kept["contexts"]!.AsArray().First()!;
        system["loggedIn"]!.GetValue<bool>().Should().BeFalse();
        system["note"]!.GetValue<string>().Should().Contain("holds an interactive login");
        Holds(keptState, "local-ab1-one_octosystem", "refresh").Should().BeTrue();
    }
}
