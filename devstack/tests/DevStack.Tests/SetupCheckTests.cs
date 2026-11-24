using FluentAssertions;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>setup_check (AB#9377): every requirement of a new machine with its fix; canned probes, nothing is run.</summary>
public sealed class SetupCheckTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    private SetupProbes Probes(string platform = "linux", bool lsof = true, bool pwsh = true, string sdks = "10.0.100 [/usr/share/dotnet/sdk]\n",
        bool certTrusted = true, bool docker = true, List<string>? unreachable = null, bool contexts = true, bool installations = true,
        Func<string, IReadOnlyList<string>, Task<BuildVariablesSeen?>>? buildVariables = null, string? octoCli = "/opt/octo-cli/octo-cli") => new(
        (file, args) => args.StartsWith("--list-sdks", StringComparison.Ordinal) ? (0, sdks) : (certTrusted ? 0 : 6, ""),
        program => program == "lsof" ? lsof : program == "pwsh" && pwsh,
        path => (contexts && path.EndsWith("contexts.json", StringComparison.Ordinal)) || (installations && path.EndsWith("installations.json", StringComparison.Ordinal)),
        () => Task.FromResult(unreachable ?? []),
        () => docker ? new DockerVmInfo(true, 15.6, 16, "Docker Desktop", true, 12, 6, null, DateTimeOffset.Now) : new DockerVmInfo(false, null, null, null, false, 12, 6, null, DateTimeOffset.Now),
        platform,
        Path.Combine(_checkout.Root, "home"),
        buildVariables ?? ((_, _) => Task.FromResult<BuildVariablesSeen?>(null)),
        program => program == "octo-cli" ? octoCli : null);

    private ConfigStore Store(WorkspaceInfo? workspace)
    {
        var store = _checkout.WriteConfig("""
                                            sleeper:
                                              repo: octo-x
                                              workingDirectory: .
                                              command: pwsh
                                              args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]
                                          """);
        store.WorkspaceInfo = workspace;
        return store;
    }

    private WorkspaceInfo FromOctoTools(bool toolsConfig = true) => new("octo-tools", _checkout.Root, Path.Combine(_checkout.Root, "octo-tools"), "lanes",
        "branches/main", _checkout.Lane, "lanes", Path.Combine(_checkout.Root, "cfg"), toolsConfig, []);

    private static SetupItem Item(SetupReport report, string name) => report.Items.Single(i => i.Name == name);

    [Fact]
    public async Task A_machine_with_everything_passes()
    {
        var report = await new SetupCheck(Store(FromOctoTools()), Probes()).RunAsync();

        report.Ok.Should().BeTrue();
        report.Items.Where(i => i.State is "warn" or "fail").Should().BeEmpty();
        Item(report, "octo-tools").Detail.Should().Contain("describes the workspace");
        Item(report, "base lane").Detail.Should().Contain(_checkout.Lane).And.Contain("lanes layout");
        Item(report, "Claude Code").State.Should().Be("info", "~/.claude.json of the test home has no octo-devstack entry");
        Item(report, "Claude Code").Fix.Should().Contain("claude mcp add --transport http --scope user octo-devstack http://127.0.0.1:5090/mcp");
    }

    [Fact]
    public async Task A_checkout_that_moved_is_reported_as_stale_paths_with_the_way_out()
    {
        var old = Path.Combine(_checkout.Root, "old-place", "branches", "main");
        var present = _checkout.Repo("octo-a");
        var state = new PersistedState
        {
            Stack = new PersistedStack
            {
                Checkout = old,
                Services = [new PersistedService { Name = "alpha", RepoPath = Path.Combine(old, "octo-a") }, new PersistedService { Name = "beta", RepoPath = present }]
            }
        };

        var report = await new SetupCheck(Store(FromOctoTools()), Probes(), () => state).RunAsync();

        var item = Item(report, "stale paths");
        item.State.Should().Be("warn");
        item.Detail.Should().Contain($"base lane of the shared stack in the daemon's state: {old}")
            .And.Contain($"repository of alpha (the shared stack) in the daemon's state: {Path.Combine(old, "octo-a")}")
            .And.NotContain(present, "a folder that exists is not stale");
        item.Fix.Should().Contain("stack_stop");

        var fine = await new SetupCheck(Store(FromOctoTools()), Probes(), () => new PersistedState()).RunAsync();
        Item(fine, "stale paths").State.Should().Be("ok");
    }

    [Fact]
    public async Task A_new_machine_is_told_what_to_install_and_how()
    {
        var report = await new SetupCheck(Store(new WorkspaceInfo("none", null, null, null, null, null, null, null, null, ["octo-tools not found"])),
            Probes(platform: "macos", lsof: false, pwsh: false, sdks: "9.0.203 [/usr/local/share/dotnet/sdk]\n", certTrusted: false, docker: false,
                unreachable: ["MongoDB (127.0.0.1:27017)"], contexts: false)).RunAsync();

        report.Ok.Should().BeFalse();
        Item(report, "octo-tools").Should().BeEquivalentTo(new { State = "fail", Detail = "octo-tools not found" });
        Item(report, "octo-tools").Fix.Should().Contain("Invoke-CloneMainRepos -devTools");
        Item(report, "pwsh").State.Should().Be("fail");
        Item(report, ".NET SDK").Should().BeEquivalentTo(new { State = "fail", Fix = "install the .NET 10 SDK" });
        Item(report, "process tools").Should().BeEquivalentTo(new { State = "fail", Fix = "install lsof" }, "macOS has no /proc to fall back on");
        Item(report, "dev certificate").Should().BeEquivalentTo(new { State = "warn", Fix = "dotnet dev-certs https --trust" });
        Item(report, "Docker").State.Should().Be("warn");
        Item(report, "kind infrastructure").Detail.Should().Contain("MongoDB");
        Item(report, "kind infrastructure").Fix.Should().Contain("Install-OctoKubernetes");
        Item(report, "octo-cli").Fix.Should().Be("Register-OctoCliContext -Installation local");
        Item(report, "installations.json").State.Should().Be("info");
    }

    [Fact]
    public async Task An_older_octo_tools_fails_and_a_missing_installations_json_is_a_warning_with_its_fix()
    {
        // An octo-tools without Get-OctoWorkspace: the daemon guesses nothing, so it cannot work until octo-tools is updated.
        var old = WorkspaceResolver.Unanswered(Path.Combine(_checkout.Root, "octo-tools"), "octo-tools ... needs a newer octo-tools");
        var report = await new SetupCheck(Store(old), Probes()).RunAsync();

        report.Ok.Should().BeFalse();
        Item(report, "octo-tools").Should().BeEquivalentTo(new { State = "fail" });
        Item(report, "octo-tools").Fix.Should().StartWith("git pull in");

        var withoutConfig = await new SetupCheck(Store(FromOctoTools(toolsConfig: false)), Probes(installations: false)).RunAsync();
        withoutConfig.Ok.Should().BeTrue("octo-cli contexts are missing then, the stack still runs");
        Item(withoutConfig, "installations.json").State.Should().Be("warn");
        Item(withoutConfig, "installations.json").Fix.Should().Contain("installations.example.json");
    }

    [Fact]
    public async Task The_command_that_shows_why_octo_tools_did_not_answer_quotes_its_path()
    {
        var tools = Path.Combine(_checkout.Root, "O'Brien", "octo-tools");
        var failing = WorkspaceResolver.Unanswered(tools, "Get-OctoWorkspace returned no document (exit code 1)");

        var report = await new SetupCheck(Store(failing), Probes()).RunAsync();

        Item(report, "octo-tools").Fix.Should().Contain($"'{Path.Combine(_checkout.Root, "O''Brien", "octo-tools", "modules", "profile.ps1")}'",
            "an apostrophe in the path is doubled inside the single-quoted PowerShell string");
    }

    // ---------- build variables (AB#9464) ----------

    [Fact]
    public async Task A_missing_build_variable_of_a_lane_repo_is_named_with_the_private_profile_to_set_it_in()
    {
        // macOS under the LaunchAgent: TELERIK_LICENSE only in ~/.zshrc, so the daemon's builds lack it.
        Directory.CreateDirectory(Path.Combine(_checkout.Lane, "octo-frontend-libraries"));
        (string Tools, IReadOnlyList<string> Names)? asked = null;
        var profile = Path.Combine(_checkout.Root, "home", ".config", "powershell", "Microsoft.PowerShell_profile_private.ps1");

        var report = await new SetupCheck(Store(FromOctoTools()), Probes(platform: "macos", buildVariables: (tools, names) =>
        {
            asked = (tools, names);
            return Task.FromResult<BuildVariablesSeen?>(new BuildVariablesSeen([], profile));
        })).RunAsync();

        asked!.Value.Names.Should().Equal("TELERIK_LICENSE");
        asked.Value.Tools.Should().Be(Path.Combine(_checkout.Root, "octo-tools"), "the builds' pwsh loads this octo-tools' profile");
        var item = Item(report, "build variables");
        item.State.Should().Be("warn");
        item.Detail.Should().Contain("TELERIK_LICENSE is not set for the daemon's builds").And.Contain("Kendo UI license")
            .And.Contain("(octo-frontend-libraries fail without it)").And.NotContain("octo-frontend-refinery-studio", "only repos the lane has");
        item.Fix.Should().StartWith($"add $env:TELERIK_LICENSE = '<value>' to {profile}").And.Contain("does not read ~/.zshrc");
        report.Ok.Should().BeTrue("the stack runs; only the frontend builds fail");
    }

    [Fact]
    public async Task A_build_variable_the_builds_see_is_ok_and_none_is_asked_without_a_repo_that_needs_one()
    {
        Directory.CreateDirectory(Path.Combine(_checkout.Lane, "octo-frontend-refinery-studio"));
        var set = await new SetupCheck(Store(FromOctoTools()), Probes(buildVariables: (_, _) =>
            Task.FromResult<BuildVariablesSeen?>(new BuildVariablesSeen(["TELERIK_LICENSE"], "/p")))).RunAsync();
        Item(set, "build variables").Should().BeEquivalentTo(new { State = "ok", Detail = "TELERIK_LICENSE set for the daemon's builds" });

        var unanswered = await new SetupCheck(Store(FromOctoTools()), Probes()).RunAsync();
        Item(unanswered, "build variables").State.Should().Be("info", "pwsh did not answer: not checked, no guess");

        Directory.Delete(Path.Combine(_checkout.Lane, "octo-frontend-refinery-studio"));
        var asked = false;
        var none = await new SetupCheck(Store(FromOctoTools()), Probes(buildVariables: (_, _) =>
        {
            asked = true;
            return Task.FromResult<BuildVariablesSeen?>(null);
        })).RunAsync();
        none.Items.Should().NotContain(i => i.Name == "build variables");
        asked.Should().BeFalse("no pwsh is started for a lane without such a repo");
    }

    [Fact]
    public void Build_variables_are_the_built_in_ones_with_the_files_and_are_asked_for_by_name_only()
    {
        var config = new DevStackConfig
        {
            BuildVariables =
            [
                new BuildVariable { Name = "TELERIK_LICENSE", Repos = ["my-frontend"], Why = "mine" },
                new BuildVariable { Name = "NPM_TOKEN", Why = "private npm feed" }
            ]
        };

        SetupCheck.EffectiveBuildVariables(config).Select(v => (v.Name, v.Why)).Should().Equal(("TELERIK_LICENSE", "mine"), ("NPM_TOKEN", "private npm feed"));
        SetupCheck.EffectiveBuildVariables(new DevStackConfig()).Should().ContainSingle(v => v.Name == "TELERIK_LICENSE" && v.Repos.Contains("octo-frontend-libraries"));

        SetupCheck.ProfileAssignment("TELERIK_LICENSE").Should().Be("$env:TELERIK_LICENSE = '<value>'");
        SetupCheck.ProfileAssignment("O'DD").Should().Be("[Environment]::SetEnvironmentVariable('O''DD', '<value>')",
            "$env: cannot spell a name with an apostrophe");

        var body = SetupCheck.BuildVariablesBody(["TELERIK_LICENSE", "O'DD"]);
        body.Should().Contain("@('TELERIK_LICENSE', 'O''DD')").And.Contain(Common.PwshRunner.Marker).And.Contain("profile = $privateProfilePath")
            .And.Contain("GetEnvironmentVariable($_)").And.NotContain("$env:TELERIK_LICENSE", "only whether it is set goes out, never the value");
    }

    [Fact]
    public async Task Linux_without_lsof_reads_proc_and_says_so()
    {
        var report = await new SetupCheck(Store(FromOctoTools()), Probes(platform: "linux", lsof: false)).RunAsync();

        Item(report, "process tools").Should().BeEquivalentTo(new { State = "info" });
        Item(report, "process tools").Detail.Should().Contain("/proc");
    }

    [Fact]
    public void The_Claude_Code_registration_is_read_by_name_only()
    {
        var file = Path.Combine(_checkout.Root, "claude.json");
        File.WriteAllText(file, """{ "mcpServers": { "octo-devstack": { "type": "http", "url": "http://127.0.0.1:5090/mcp" }, "other": { "env": { "TOKEN": "x" } } } }""");
        SetupCheck.ClaudeRegistered(file, "http://127.0.0.1:5090").Should().BeTrue();
        File.WriteAllText(file, """{ "mcpServers": { "other": {} } }""");
        SetupCheck.ClaudeRegistered(file, "http://127.0.0.1:5090").Should().BeFalse();
        SetupCheck.ClaudeRegistered(Path.Combine(_checkout.Root, "missing.json"), "x").Should().BeNull();
        foreach (var root in new[] { "null", "[]", "42" })
        {
            File.WriteAllText(file, root);
            SetupCheck.ClaudeRegistered(file, "x").Should().BeNull($"a root of {root} is no settings file (and never throws)");
        }
    }
    [Fact]
    public async Task Installations_json_is_looked_at_when_the_check_runs_not_at_the_daemon_start()
    {
        // The workspace of the daemon's start said there was none; the developer copied it since.
        var report = await new SetupCheck(Store(FromOctoTools(toolsConfig: false)), Probes(installations: true)).RunAsync();
        Item(report, "installations.json").State.Should().Be("ok");

        var removed = await new SetupCheck(Store(FromOctoTools(toolsConfig: true)), Probes(installations: false)).RunAsync();
        Item(removed, "installations.json").State.Should().Be("warn");
    }

    [Fact]
    public async Task A_lane_that_cannot_be_used_is_a_lane_failure_and_the_other_checks_still_run()
    {
        // The default lane is an environment folder whose manifest is broken: the folder exists, the context throws.
        var env = Path.Combine(_checkout.Root, "wt-broken");
        Directory.CreateDirectory(Path.Combine(env, ".octo"));
        File.WriteAllText(Path.Combine(env, ".octo", "environment.json"), "{ not json");
        var broken = Store(FromOctoTools());
        File.WriteAllText(broken.ConfigPath, File.ReadAllText(broken.ConfigPath).Replace("defaultCheckout: branches/main", "defaultCheckout: wt-broken"));

        var report = await new SetupCheck(broken, Probes()).RunAsync();

        Item(report, "base lane").State.Should().Be("fail");
        Item(report, "base lane").Detail.Should().Contain("wt-broken");
        report.Items.Select(i => i.Name).Should().Contain(["installations.json", "pwsh", "Docker"], "the report goes on after the lane");
    }

    [Fact]
    public void An_empty_default_lane_is_a_folder_problem_not_the_root()
    {
        var config = ConfigStore.Parse($"rootPath: {_checkout.Root}\nservices:\n  a: {{ repo: r, args: [x] }}\n");

        ServicePlanner.FolderProblems(config).Should().ContainSingle(p => p.StartsWith("The default lane is unknown"));
    }
    [Fact]
    public async Task A_daemon_whose_own_PATH_lacks_octo_cli_is_told_to_restart_from_a_shell_with_the_current_PATH()
    {
        var ok = await new SetupCheck(Store(FromOctoTools()), Probes()).RunAsync();
        Item(ok, SetupCheck.OctoCliItem).Should().BeEquivalentTo(new { State = "ok", Fix = (string?)null });
        Item(ok, SetupCheck.OctoCliItem).Detail.Should().StartWith("/opt/octo-cli/octo-cli");

        var stale = await new SetupCheck(Store(FromOctoTools()), Probes(octoCli: null)).RunAsync();

        var item = Item(stale, SetupCheck.OctoCliItem);
        item.State.Should().Be("warn");
        item.Detail.Should().Contain("PATH the daemon runs with").And.Contain("not your shell's").And.Contain("is not recognized");
        item.Fix.Should().Contain("open a new shell").And.Contain("Start-OctoDevStackDaemon -Restart").And.Contain("restart.safe");
    }

    [Fact]
    public void Octo_cli_resolves_on_a_PATH_like_a_shell_finds_it()
    {
        var bin = Path.Combine(_checkout.Root, "bin");
        var tools = Path.Combine(_checkout.Root, "tools");
        var files = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Path.Combine(tools, "octo-cli.exe"), Path.Combine(bin, "octo-cli") };

        SetupCheck.ResolveOnPath("octo-cli", $"{bin};\"{tools}\"", ".COM;.EXE", windows: true, files.Contains).Should().Be(Path.Combine(bin, "octo-cli"),
            "the plain name first, as a shell takes it");
        files.Remove(Path.Combine(bin, "octo-cli"));
        SetupCheck.ResolveOnPath("octo-cli", $"{bin};\"{tools}\"", ".COM;.EXE", windows: true, files.Contains).Should().Be(Path.Combine(tools, "octo-cli.exe"));
        files.Add(Path.Combine(bin, "octo-cli.ps1"));
        SetupCheck.ResolveOnPath("octo-cli", $"{bin};{tools}", null, windows: true, files.Contains).Should().Be(Path.Combine(bin, "octo-cli.ps1"), "pwsh runs a script on PATH too");
        SetupCheck.ResolveOnPath("octo-cli", $"{bin}:{tools}", null, windows: false, files.Contains).Should().BeNull("no extensions outside Windows");
        SetupCheck.ResolveOnPath("octo-cli", null, null, windows: false, files.Contains).Should().BeNull();
    }
}