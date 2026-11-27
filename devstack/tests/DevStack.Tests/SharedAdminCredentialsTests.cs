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
///     AB#9865: the admin step of a lane stack takes email and password from the shared admin file
///     <c>&lt;base lane&gt;/.octo/admin-credentials.json</c> when it is there and usable. Invariant: the password from that file
///     never appears in a result, a warning, a step summary, the saved setup or an exception message - only the file's path
///     and the email do. One test per abuse case. Dummy values in temp folders only; no real credentials file is read.
/// </summary>
public sealed class SharedAdminCredentialsTests : IDisposable
{
    private const string Lane = "ab1-one";
    private const string DummyPassword = "Dummy-Pass-1x";
    private const string DummyEmail = "dev@example.test";

    private const string IdentityService = """
                                             identityServices:
                                               repo: octo-a
                                               workingDirectory: .
                                               command: pwsh
                                               args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30 #", "--urls=https://0.0.0.0:5003;http://0.0.0.0:5002"]
                                               ports: [5003, 5002]
                                           """;

    private readonly TestCheckout _checkout = new();
    private readonly FakePwsh _fake = new() { Capabilities = FakePwsh.EnvironmentParams };

    public void Dispose() => _checkout.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private sealed class FakeHttp(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public List<string> Bodies { get; } = [];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Bodies.Add(request.Content == null ? "" : await request.Content.ReadAsStringAsync(cancellationToken));
            return answer(request);
        }
    }

    private sealed record Setup(SlotOperations Ops, StackSupervisor Supervisor, FakeHttp Http, string LaneFile, string SharedFile);

    private static HttpResponseMessage Created(HttpRequestMessage _) => new(HttpStatusCode.OK) { Content = new StringContent("""{"success":true}""") };

    /// <param name="protection">The owner-only check; default: every file counts as owner-only (the real check has its own tests).</param>
    private Setup Create(Func<HttpRequestMessage, HttpResponseMessage>? identity = null, Func<string, string?>? protection = null)
    {
        _checkout.Repo("octo-a");
        var store = _checkout.WriteConfig(IdentityService);
        var state = new StateStore(new DevStackPaths(_checkout.StateDirectory));
        state.Load();
        var supervisor = new StackSupervisor(store, new LeaseManager(), state, NullLogger<StackSupervisor>.Instance, external: new ExternalDetector(store));
        var folder = Path.Combine(_checkout.Root, "wt-" + Lane);
        Directory.CreateDirectory(Path.Combine(folder, ".octo"));
        Directory.CreateDirectory(Path.Combine(folder, "octo-a"));
        File.WriteAllText(Path.Combine(folder, "octo-a", "octo-a.sln"), "");
        File.WriteAllText(Path.Combine(folder, "Octo.User.props"), "<Project />");
        var manifest = new
        {
            schemaVersion = 1, name = Lane, workItem = "AB#1234", @base = "branches/main", created = "2026-11-20T09:00:00+01:00", owner = "markus/AB#1234_x",
            repos = new[] { new { name = "octo-a", role = "feature", path = Path.Combine(folder, "octo-a"), branch = "markus/AB#1234_x", baseCommit = "abc123" } },
            slot = (string?)null
        };
        File.WriteAllText(EnvironmentDiscovery.ManifestPath(folder), JsonSerializer.Serialize(manifest, JsonSerializerOptions.Web));
        var http = new FakeHttp(identity ?? Created);
        var ops = new SlotOperations(store, supervisor, _fake, http, Path.Combine(_checkout.Root, "octo-tools-config", "installations.json"),
            sharedFileProtection: protection ?? (_ => null));
        Directory.CreateDirectory(Path.Combine(_checkout.Lane, ".octo"));
        return new Setup(ops, supervisor, http, Path.Combine(folder, ".octo", SlotOperations.CredentialsFileName),
            Path.Combine(_checkout.Lane, ".octo", SlotOperations.CredentialsFileName));
    }

    /// <summary>A copy of a lane file as the admin step writes it (dummy values).</summary>
    private static string LaneFileCopy(string? email = DummyEmail, string password = DummyPassword) =>
        JsonSerializer.Serialize(new
        {
            email, password, tenant = "octosystem", url = "https://localhost:5203/octosystem/api/setup/create-admin", slot = "ab0-old",
            createdAt = DateTimeOffset.Parse("2026-11-20T09:00:00+01:00")
        });

    private Task<SlotSetupResult> AdminStep(Setup setup) => setup.Ops.SetupAsync("agent-1", Lane, null, ["admin"], [], false, Ct);

    /// <summary>Everything the setup hands out or keeps: the answer, the saved setup of the slot.</summary>
    private static string Everything(Setup setup, SlotSetupResult result)
    {
        var info = setup.Supervisor.Registry.Resolve(Lane, create: false);
        var saved = File.ReadAllText(Path.Combine(SlotDeriver.SlotDirectory(setup.Supervisor.StateDirectory, info), SlotOperations.SetupFileName));
        return JsonSerializer.Serialize(result) + "\n" + saved;
    }

    private static JsonNode Sent(Setup setup) => JsonNode.Parse(setup.Http.Bodies.Single())!;

    private static string StoredPassword(Setup setup) => JsonNode.Parse(File.ReadAllText(setup.LaneFile))!["password"]!.GetValue<string>();

    // ---------- the criteria ----------

    [Fact]
    public async Task A_lane_file_copied_to_the_base_lane_creates_the_lane_admin_with_its_email_and_password()
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, LaneFileCopy());

        var result = await AdminStep(setup);

        result.Steps.Single().Status.Should().Be("done");
        result.Warnings.Should().BeEmpty();
        Sent(setup)["email"]!.GetValue<string>().Should().Be(DummyEmail);
        Sent(setup)["password"]!.GetValue<string>().Should().Be(DummyPassword);
        Sent(setup)["confirmPassword"]!.GetValue<string>().Should().Be(DummyPassword);
        var lane = JsonNode.Parse(File.ReadAllText(setup.LaneFile))!;
        lane["email"]!.GetValue<string>().Should().Be(DummyEmail, "the lane file is still written, with the values used");
        lane["password"]!.GetValue<string>().Should().Be(DummyPassword);
        lane["slot"]!.GetValue<string>().Should().Be(Lane, "the lane file is the lane's own, in today's format");
        lane["tenant"]!.GetValue<string>().Should().Be("octosystem");
        lane["url"]!.GetValue<string>().Should().Be("https://localhost:5103/octosystem/api/setup/create-admin");
        result.Steps.Single().Summary.Should().Contain(DummyEmail).And.Contain(setup.SharedFile, "the path and the email may appear");
        Everything(setup, result).Should().NotContain(DummyPassword, "the password stays in the files");
        if (!OperatingSystem.IsWindows())
        {
            File.GetUnixFileMode(setup.LaneFile).Should().Be(UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
    }

    [Fact]
    public async Task Without_an_email_in_the_shared_file_the_admin_is_admin_at_the_slot()
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, $$"""{"password":"{{DummyPassword}}","email":"  "}""");

        var result = await AdminStep(setup);

        result.Steps.Single().Status.Should().Be("done");
        Sent(setup)["email"]!.GetValue<string>().Should().Be("admin@ab1-one.local");
        Sent(setup)["password"]!.GetValue<string>().Should().Be(DummyPassword);
    }

    [Fact]
    public async Task Without_the_shared_file_the_admin_step_behaves_as_before()
    {
        var setup = Create();

        var result = await AdminStep(setup);

        result.Steps.Single().Status.Should().Be("done");
        result.Warnings.Should().BeEmpty("a missing shared file is no problem");
        Sent(setup)["email"]!.GetValue<string>().Should().Be("admin@ab1-one.local");
        StoredPassword(setup).Length.Should().Be(24, "the generated password");
        Sent(setup)["password"]!.GetValue<string>().Should().Be(StoredPassword(setup));
        result.Steps.Single().Summary.Should().NotContain("shared");
    }

    [Fact]
    public async Task An_existing_lane_is_not_changed_by_a_new_shared_file()
    {
        var setup = Create();
        File.WriteAllText(setup.LaneFile, """{"email":"admin@ab1-one.local","password":"Old-Lane-Pass-9"}""");
        File.WriteAllText(setup.SharedFile, LaneFileCopy());

        var result = await AdminStep(setup);

        result.Steps.Single().Status.Should().Be("unchanged");
        setup.Http.Bodies.Should().BeEmpty("nothing is sent for a lane that has its admin");
        StoredPassword(setup).Should().Be("Old-Lane-Pass-9");
    }

    // ---------- abuse cases ----------

    [Fact]
    public async Task Abuse_invalid_json_is_a_warning_naming_the_file_and_falls_back_to_a_generated_password()
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, $$"""{"email":"{{DummyEmail}}","password":"{{DummyPassword}}" """); // cut off

        var result = await AdminStep(setup);

        result.Steps.Single().Status.Should().Be("done");
        result.Warnings.Should().ContainSingle().Which.Should().Contain(setup.SharedFile).And.Contain("is not valid JSON").And.Contain("generated password");
        Everything(setup, result).Should().NotContain(DummyPassword).And.NotContain(DummyEmail, "nothing of an unusable file is passed on");
        StoredPassword(setup).Should().NotBe(DummyPassword).And.HaveLength(24);
        Sent(setup)["email"]!.GetValue<string>().Should().Be("admin@ab1-one.local");
    }

    [Fact]
    public async Task Abuse_a_file_that_is_not_owner_only_is_not_read_and_falls_back_to_a_generated_password()
    {
        var checkedFiles = new List<string>();
        var setup = Create(protection: f =>
        {
            checkedFiles.Add(f);
            return "is not owned by the current user";
        });
        File.WriteAllText(setup.SharedFile, LaneFileCopy());

        var result = await AdminStep(setup);

        checkedFiles.Should().Equal(setup.SharedFile);
        result.Steps.Single().Status.Should().Be("done");
        result.Warnings.Should().ContainSingle().Which.Should().Contain(setup.SharedFile).And.Contain("is not owned by the current user");
        Everything(setup, result).Should().NotContain(DummyPassword);
        StoredPassword(setup).Should().NotBe(DummyPassword).And.HaveLength(24);
    }

    [Theory]
    [InlineData("""{"email":"dev@example.test"}""")]
    [InlineData("""{"email":"dev@example.test","password":""}""")]
    [InlineData("""{"email":"dev@example.test","password":"   "}""")]
    [InlineData("""{"email":"dev@example.test","password":12345678}""")]
    [InlineData("""{"email":"dev@example.test","password":null}""")]
    [InlineData("""["Dummy-Pass-1x"]""")]
    [InlineData("""{"email":42,"password":"Dummy-Pass-1x"}""")]
    public async Task Abuse_a_missing_empty_or_malformed_password_is_a_warning_and_falls_back(string content)
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, content);

        var result = await AdminStep(setup);

        result.Steps.Single().Status.Should().Be("done");
        result.Warnings.Should().ContainSingle().Which.Should().Contain(setup.SharedFile).And.Contain("generated password");
        Everything(setup, result).Should().NotContain(DummyPassword).And.NotContain("12345678");
        StoredPassword(setup).Should().HaveLength(24);
    }

    [Theory]
    [InlineData("Ab1!x", "at least 6 characters")]
    [InlineData("dummy-pass-1x", "uppercase")]
    [InlineData("DUMMY-PASS-1X", "lowercase")]
    [InlineData("Dummy-Pass-xx", "digit")]
    [InlineData("DummyPass1xyz", "symbol")]
    public async Task Abuse_a_password_that_breaks_a_rule_fails_the_step_naming_the_rule_without_fallback(string password, string rule)
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, LaneFileCopy(password: password));

        var result = await AdminStep(setup);

        var step = result.Steps.Single();
        step.Status.Should().Be("failed", "no silent fallback to a generated password");
        step.Summary.Should().Contain(rule).And.Contain(setup.SharedFile);
        result.Warnings.Should().Contain(w => w.Contains("Setup step 'admin'") && w.Contains(rule));
        Everything(setup, result).Should().NotContain(password);
        setup.Http.Bodies.Should().BeEmpty("nothing is sent");
        File.Exists(setup.LaneFile).Should().BeFalse("no admin, no lane file");
    }

    [Fact]
    public async Task Abuse_an_identity_error_that_echoes_the_password_is_passed_on_without_it()
    {
        var setup = Create(_ => new HttpResponseMessage(HttpStatusCode.BadRequest)
        {
            Content = new StringContent($$"""{"success":false,"errors":["Passwords must have ... (got {{DummyPassword}})"]}""")
        });
        File.WriteAllText(setup.SharedFile, LaneFileCopy());

        var result = await AdminStep(setup);

        var step = result.Steps.Single();
        step.Status.Should().Be("failed");
        step.Summary.Should().Contain("create-admin failed (400)").And.Contain("Passwords must have").And.Contain("***").And.Contain(setup.SharedFile);
        Everything(setup, result).Should().NotContain(DummyPassword);
        File.Exists(setup.LaneFile).Should().BeFalse();
    }

    [Fact]
    public async Task Abuse_a_transport_error_that_names_the_password_is_passed_on_without_it()
    {
        var setup = Create(_ => throw new HttpRequestException($"refused while sending {DummyPassword}"));
        File.WriteAllText(setup.SharedFile, LaneFileCopy());

        var result = await AdminStep(setup);

        result.Steps.Single().Status.Should().Be("failed");
        result.Steps.Single().Summary.Should().Contain("does not answer").And.Contain("***");
        Everything(setup, result).Should().NotContain(DummyPassword);
    }

    [Fact]
    public async Task Abuse_the_direct_admin_call_neither_returns_nor_throws_the_password()
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, LaneFileCopy());

        var result = await setup.Ops.BootstrapAdminAsync("agent-1", Lane, null, null, Ct);

        result.Status.Should().Be("created");
        result.SharedCredentialsFile.Should().Be(setup.SharedFile);
        JsonSerializer.Serialize(result).Should().NotContain(DummyPassword);
        result.ToString().Should().NotContain(DummyPassword);

        File.Delete(setup.LaneFile);
        File.WriteAllText(setup.SharedFile, LaneFileCopy(password: "nouppercase-1"));
        var broken = () => setup.Ops.BootstrapAdminAsync("agent-1", Lane, null, null, Ct);
        (await broken.Should().ThrowAsync<InvalidOperationException>()).Which.Message.Should().Contain("uppercase").And.NotContain("nouppercase-1");
    }

    [Fact]
    public void Abuse_formatting_the_shared_credentials_never_shows_the_password()
    {
        var read = SlotOperations.ReadSharedAdmin(WriteTemp(LaneFileCopy()), _ => null);

        read.Warning.Should().BeNull();
        read.Credentials!.Password.Should().Be(DummyPassword);
        read.Credentials.ToString().Should().NotContain(DummyPassword).And.Contain(DummyEmail);
        read.ToString().Should().NotContain(DummyPassword, "the record prints the credentials through their own ToString");
        $"{read.Credentials}".Should().NotContain(DummyPassword);
    }

    [Fact]
    public async Task Abuse_the_shared_stack_never_reads_the_shared_file_its_own_file_there_means_nothing_is_sent()
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, LaneFileCopy());
        var lane = setup.Ops.Resolve(Lane, null);
        // The shared stack's admin lives in the same file: a target whose files folder is the base lane's .octo.
        var sharedStack = lane with { Environment = null, FilesFolder = Path.GetDirectoryName(setup.SharedFile)! };

        var result = await setup.Ops.BootstrapAdminCoreAsync(sharedStack, null, Ct);

        result.Status.Should().Be("credentialsFileExists");
        result.SharedCredentialsFile.Should().BeNull();
        setup.Http.Bodies.Should().BeEmpty("an existing file there means nothing is sent");
        File.ReadAllText(setup.SharedFile).Should().Be(LaneFileCopy(), "the file is never overwritten");

        // Even named as a lane: a target whose own folder is the shared file's folder does not take the shared file.
        File.Delete(setup.SharedFile);
        var protectedChecks = 0;
        var counting = new SlotOperations(_checkout.WriteConfig(IdentityService), setup.Supervisor, _fake, new FakeHttp(Created),
            sharedFileProtection: _ =>
            {
                protectedChecks++;
                return null;
            });
        (await counting.BootstrapAdminCoreAsync(lane with { FilesFolder = Path.GetDirectoryName(setup.SharedFile)! }, null, Ct)).SharedCredentialsFile.Should().BeNull();
        protectedChecks.Should().Be(0, "the shared file is not consulted for its own folder");
    }

    [Fact]
    public async Task Abuse_a_named_slot_without_a_lane_does_not_take_the_shared_file()
    {
        var setup = Create();
        File.WriteAllText(setup.SharedFile, LaneFileCopy());
        var slot = setup.Ops.Resolve(Lane, null) with { Environment = null };

        var result = await setup.Ops.BootstrapAdminCoreAsync(slot, null, Ct);

        result.Status.Should().Be("created");
        result.SharedCredentialsFile.Should().BeNull("lanes only");
        Sent(setup)["password"]!.GetValue<string>().Should().NotBe(DummyPassword).And.HaveLength(24);
    }

    // ---------- the owner-only check and the rules themselves ----------

    [Fact]
    public void The_owner_only_check_refuses_group_or_other_bits_on_unix_and_a_foreign_owner_on_windows()
    {
        var file = WriteTemp(LaneFileCopy());
        if (OperatingSystem.IsWindows())
        {
            // The test process created the file: owned by the current user unless the process runs elevated, where Windows
            // may make the Administrators group the owner - then the check must refuse it.
            var owner = System.IO.FileSystemAclExtensions.GetAccessControl(new FileInfo(file), System.Security.AccessControl.AccessControlSections.Owner)
                .GetOwner(typeof(System.Security.Principal.SecurityIdentifier));
            var mine = owner!.Equals(System.Security.Principal.WindowsIdentity.GetCurrent().User);
            SlotOperations.OwnerOnlyProblem(file).Should().Be(mine ? null : "is not owned by the current user");
            return;
        }

        File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        SlotOperations.OwnerOnlyProblem(file).Should().BeNull();
        File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.GroupRead);
        SlotOperations.OwnerOnlyProblem(file).Should().Contain("not owner-only").And.Contain("640");
        File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.OtherRead);
        var read = SlotOperations.ReadSharedAdmin(file, SlotOperations.OwnerOnlyProblem);
        read.Credentials.Should().BeNull();
        read.Warning.Should().Contain(file).And.Contain("chmod 600").And.NotContain(DummyPassword);
    }

    [Fact]
    public void A_missing_file_is_no_warning_and_a_large_file_is_not_read()
    {
        var missing = Path.Combine(_checkout.Root, "nothing", SlotOperations.CredentialsFileName);
        SlotOperations.ReadSharedAdmin(missing, _ => null).Should().Be(new SharedAdminRead(null, null));

        var large = WriteTemp(LaneFileCopy() + new string(' ', SlotOperations.SharedAdminFileMaxBytes));
        var read = SlotOperations.ReadSharedAdmin(large, _ => null);
        read.Credentials.Should().BeNull();
        read.Warning.Should().Contain("larger than 64 KB");
    }

    [Theory]
    [InlineData("Dummy-Pass-1x", null)]
    [InlineData("Ab1!xy", null)]
    [InlineData("Ab1 xy", null)]
    [InlineData("Ab1!x", "at least 6 characters")]
    [InlineData("Abcdef1Ä", null)] // as ASP.NET Identity counts it: a non-ASCII letter is a symbol
    public void The_rules_are_the_identity_ones_and_need_no_24_characters(string password, string? broken)
    {
        SlotOperations.PasswordRuleBroken(password).Should().Be(broken);
        // What the admin step generates always passes.
        SlotOperations.PasswordRuleBroken(SlotOperations.GeneratePassword()).Should().BeNull();
    }

    private string WriteTemp(string content)
    {
        var folder = Path.Combine(_checkout.Root, "tmp-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        var file = Path.Combine(folder, SlotOperations.CredentialsFileName);
        File.WriteAllText(file, content);
        return file;
    }
}
