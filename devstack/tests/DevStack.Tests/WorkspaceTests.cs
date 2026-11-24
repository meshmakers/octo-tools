using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Tools;
using Microsoft.Extensions.Logging.Abstractions;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The workspace octo-tools describes (AB#9377): where octo-tools is found, what Get-OctoWorkspace answers, the folder view
///     for an older octo-tools, devstack.yaml in the octo-tools config folder and the take-over of the old file.
/// </summary>
public sealed class WorkspaceTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    private static CancellationToken Ct => TestContext.Current.CancellationToken;

    private sealed class CannedPwsh(string output, int exitCode = 0, bool timedOut = false) : IPwshRunner
    {
        public List<string> Bodies { get; } = [];

        public Task<PwshResult> RunAsync(string octoToolsPath, string body, PwshRunOptions options, CancellationToken cancellationToken)
        {
            Bodies.Add(body);
            return Task.FromResult(new PwshResult(exitCode, output, timedOut, false));
        }
    }

    [Fact]
    public async Task A_slow_or_failing_octo_tools_is_named_as_such_not_as_too_old()
    {
        var (_, tools, _) = Machine("m-fail");

        var slow = await WorkspaceResolver.ResolveAsync(new CannedPwsh("Loading Octo Profile\n", timedOut: true), tools, TimeSpan.FromSeconds(90), Ct);
        slow.Problems.Should().ContainSingle(p => p.Contains("within 90 s") && !p.Contains("newer octo-tools"));

        var broken = await WorkspaceResolver.ResolveAsync(new CannedPwsh("Loading Octo Profile\nInvalidOperation: the private profile threw\n", exitCode: 1), tools, TimeSpan.FromSeconds(90), Ct);
        broken.Problems.Should().ContainSingle(p => p.Contains("exit code 1") && p.Contains("the private profile threw") && !p.Contains("newer octo-tools"));
    }

    private static string WorkspaceDocument(object data) =>
        "Loading profile...\n" + JsonSerializer.Serialize(new { schemaVersion = 1, command = "Get-OctoWorkspace", timestamp = "2026-11-19T09:00:00Z", data }) + "\n";

    /// <summary>A machine: &lt;root&gt;/octo-tools with its profile and &lt;root&gt;/octo-devstack with the solution.</summary>
    private (string Root, string Tools, string DevStack) Machine(string name)
    {
        var root = Path.Combine(_checkout.Root, name);
        var tools = Path.Combine(root, "octo-tools");
        var devstack = Path.Combine(root, "octo-devstack");
        Directory.CreateDirectory(Path.Combine(tools, "modules"));
        File.WriteAllText(Path.Combine(tools, "modules", "profile.ps1"), "# fake");
        Directory.CreateDirectory(Path.Combine(devstack, "bin", "Release", "net10.0"));
        File.WriteAllText(Path.Combine(devstack, "Octo.DevStack.sln"), "");
        return (root, tools, devstack);
    }

    // ---------- where the config lives ----------

    [Fact]
    public void Devstack_yaml_lives_in_the_config_folder_octo_tools_names()
    {
        var home = Path.Combine(_checkout.Root, "home");
        var folder = Path.Combine(_checkout.Root, "elsewhere");

        ConfigStore.PathIn(FromOctoTools() with { ConfigDirectory = folder }).Should().Be(Path.Combine(folder, "devstack.yaml"),
            "next to installations.json, wherever octo-tools keeps it - the daemon has no rule of its own for that folder");
        ConfigStore.PathIn(WorkspaceResolver.Unanswered(Path.Combine(_checkout.Root, "octo-tools"), "too old")).Should().BeNull();
        ConfigStore.LegacyPath("devstack.dev.yaml", home).Should().Be(Path.Combine(home, ".config", "octo-devstack", "devstack.dev.yaml"));
    }

    private WorkspaceInfo FromOctoTools() => new("octo-tools", _checkout.Root, Path.Combine(_checkout.Root, "octo-tools"), "lanes", "branches/main",
        _checkout.Lane, "lanes", Path.Combine(_checkout.Root, "cfg"), true, []);

    [Fact]
    public void A_new_config_names_no_folder_of_this_machine()
    {
        var store = new ConfigStore(Path.Combine(_checkout.Root, "new", "devstack.yaml"));
        store.EnsureExists().Should().BeTrue();

        var text = File.ReadAllText(store.ConfigPath);
        text.Should().NotMatchRegex(@"(?m)^(rootPath|octoToolsPath|defaultCheckout):", "they come from octo-tools; a value in the file would pin this machine's folders");
        var raw = ConfigStore.Parse(text);
        (raw.RootPathSetting, raw.OctoToolsPathSetting, raw.DefaultCheckoutSetting).Should().Be((null, null, null));
    }

    // ---------- finding octo-tools ----------

    [Fact]
    public void Octo_tools_is_found_from_the_argument_the_environment_or_next_to_the_daemon_checkout()
    {
        var (_, tools, devstack) = Machine("m1");
        var daemonDirectory = Path.Combine(devstack, "bin", "Release", "net10.0");
        var other = Path.Combine(_checkout.Root, "other-tools");
        var third = Path.Combine(_checkout.Root, "third-tools");

        WorkspaceResolver.LocateOctoTools(null, daemonDirectory, _ => null).Should().Be(tools, "Invoke-CloneMainRepos -devTools puts both next to each other");
        WorkspaceResolver.LocateOctoTools(null, daemonDirectory, n => n == WorkspaceResolver.ToolsPathVariable ? other : null).Should().Be(Path.GetFullPath(other));
        WorkspaceResolver.LocateOctoTools(third, daemonDirectory, n => n == WorkspaceResolver.ToolsPathVariable ? other : null)
            .Should().Be(Path.GetFullPath(third), "--octo-tools wins");
        WorkspaceResolver.LocateOctoTools(null, Path.Combine(_checkout.Root, "loose"), _ => null).Should().BeNull();
    }

    [Fact]
    public void A_Claude_Code_worktree_of_octo_devstack_finds_the_octo_tools_of_its_main_checkout()
    {
        var (_, tools, devstack) = Machine("m2");
        var worktree = Path.Combine(devstack, ".claude", "worktrees", "feature");
        Directory.CreateDirectory(Path.Combine(worktree, "bin", "Debug", "net10.0"));
        File.WriteAllText(Path.Combine(worktree, "Octo.DevStack.sln"), "");

        WorkspaceResolver.NextToCheckout(Path.Combine(worktree, "bin", "Debug", "net10.0")).Should().Be(tools);
        WorkspaceResolver.NextToCheckout(Path.Combine(_checkout.Root, "no-checkout-here")).Should().BeNull();
    }

    // ---------- asking octo-tools ----------

    [Fact]
    public async Task Octo_tools_describes_the_workspace_and_its_values_fill_what_the_file_leaves_out()
    {
        var pwsh = new CannedPwsh(WorkspaceDocument(new
        {
            rootPath = _checkout.Root, toolsPath = Path.Combine(_checkout.Root, "octo-tools"), layout = "flat", defaultLane = ".",
            defaultLanePath = _checkout.Root, defaultLaneSource = "flat", environmentsRoot = _checkout.Root, configDirectory = "/cfg",
            toolsConfigPath = "/cfg/installations.json", toolsConfigExists = true, problems = Array.Empty<string>()
        }));

        var workspace = await WorkspaceResolver.ResolveAsync(pwsh, Path.Combine(_checkout.Root, "octo-tools"), TimeSpan.FromSeconds(5), Ct);

        pwsh.Bodies.Should().Equal("Get-OctoWorkspace -Json");
        workspace.Should().BeEquivalentTo(new { Source = "octo-tools", Layout = "flat", DefaultLane = ".", ConfigDirectory = "/cfg", ToolsConfigExists = (bool?)true });
        workspace.Problems.Should().BeEmpty();

        File.WriteAllText(_checkout.ConfigPath, "configuration: DebugL\n");
        var store = new ConfigStore(_checkout.ConfigPath) { WorkspaceInfo = workspace };
        var config = store.Load();
        (config.RootPath, config.DefaultCheckout, config.OctoToolsPath).Should().Be((_checkout.Root, ".", Path.Combine(_checkout.Root, "octo-tools")));
        ServicePlanner.CreateContext(config, null, null).Checkout.Should().Be(_checkout.Root, "the flat layout's lane is the root itself");

        // A change through the tools keeps the file free of the workspace's values, and the view says what is overridden.
        var view = new ConfigTools(store, NullLogger<ConfigTools>.Instance).SetDefaults("agent", configuration: "Release");
        File.ReadAllText(_checkout.ConfigPath).Should().NotMatchRegex(@"(?m)^(rootPath|octoToolsPath|defaultCheckout):");
        view.Workspace!.Source.Should().Be("octo-tools");
        view.Overrides.Should().BeEmpty();
        view.BaseLane.Should().Be(".");

        store.Update(c => c.DefaultCheckout = "branches/main");
        new ConfigTools(store, NullLogger<ConfigTools>.Instance).Get().Overrides.Should().Equal("defaultCheckout");
    }

    [Fact]
    public async Task An_octo_tools_without_Get_OctoWorkspace_is_reported_and_no_folder_is_guessed()
    {
        var (root, tools, _) = Machine("m3");
        Directory.CreateDirectory(Path.Combine(root, "branches", "main"));
        File.WriteAllText(Path.Combine(root, "branches", "main", "Octo.User.props"), "<Project />");

        var workspace = await WorkspaceResolver.ResolveAsync(new CannedPwsh("The term 'Get-OctoWorkspace' is not recognized\n"), tools, TimeSpan.FromSeconds(5), Ct);

        // The lanes layout is right there, but only octo-tools may say so: nothing is derived from the folders.
        workspace.Should().BeEquivalentTo(new { Source = "unanswered", ToolsPath = tools, RootPath = (string?)null, DefaultLane = (string?)null });
        workspace.Defaults.Should().BeNull();
        workspace.Problems.Should().ContainSingle(p => p.Contains("needs a newer octo-tools"));

        File.WriteAllText(_checkout.ConfigPath, "configuration: DebugL\n");
        var config = new ConfigStore(_checkout.ConfigPath) { WorkspaceInfo = workspace }.Load();
        ServicePlanner.FolderProblems(config).Should().ContainSingle(p => p.StartsWith("The workspace is unknown"));
        var start = () => ServicePlanner.CreateContext(config, null, null);
        start.Should().Throw<InvalidOperationException>().WithMessage("*workspace is unknown*", "never the current directory as the root");
    }

    [Fact]
    public void Octo_tools_not_found_names_the_ways_to_point_at_it()
    {
        var workspace = WorkspaceResolver.NotFound("");

        workspace.Source.Should().Be("none");
        workspace.Problems.Single().Should().Contain("Invoke-CloneMainRepos -devTools").And.Contain("OCTO_TOOLS_PATH").And.Contain("--octo-tools");
    }

    // ---------- taking over the old file ----------

    [Fact]
    public void The_old_config_is_taken_over_without_the_values_the_workspace_says_anyway()
    {
        var legacy = Path.Combine(_checkout.Root, "legacy", "devstack.yaml");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        var oldText = $"rootPath: {_checkout.Root}\noctoToolsPath: ${{rootPath}}/octo-tools\ndefaultCheckout: branches/main\nstopTimeoutSeconds: 7\n";
        File.WriteAllText(legacy, oldText);
        var store = new ConfigStore(Path.Combine(_checkout.Root, "new", "devstack.yaml"))
        {
            Workspace = new WorkspaceDefaults(_checkout.Root, Path.Combine(_checkout.Root, "octo-tools"), "branches/main")
        };

        var note = store.TakeOver(legacy, store.Workspace);

        note.Should().Contain("octoToolsPath, rootPath, defaultCheckout removed").And.Contain("no longer read");
        var taken = File.ReadAllText(store.ConfigPath);
        taken.Should().StartWith("# Taken over from").And.Contain("stopTimeoutSeconds: 7");
        taken.Should().NotMatchRegex(@"(?m)^(rootPath|octoToolsPath|defaultCheckout):");
        File.ReadAllText(legacy).Should().Be(oldText, "a running older daemon still reads it");
        store.TakeOver(legacy, store.Workspace).Should().BeNull("the new file exists now");
    }

    [Fact]
    public void A_value_of_the_old_config_that_differs_from_the_workspace_stays_as_an_override()
    {
        var legacy = Path.Combine(_checkout.Root, "legacy2", "devstack.yaml");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        var otherLane = Path.Combine(_checkout.Root, "branches", "release");
        Directory.CreateDirectory(otherLane);
        File.WriteAllText(legacy, $"rootPath: {_checkout.Root}\noctoToolsPath: /elsewhere/octo-tools\ndefaultCheckout: branches/release\n");
        var store = new ConfigStore(Path.Combine(_checkout.Root, "new2", "devstack.yaml"))
        {
            Workspace = new WorkspaceDefaults(_checkout.Root, Path.Combine(_checkout.Root, "octo-tools"), "branches/main")
        };

        // octoToolsPath goes even when it differs: the daemon uses the octo-tools it asked (OCTO_TOOLS_PATH, --octo-tools).
        store.TakeOver(legacy, store.Workspace).Should().Contain("octoToolsPath, rootPath removed");

        var config = store.Load();
        config.DefaultCheckoutSetting.Should().Be("branches/release");
        config.RootPathSetting.Should().BeNull();
    }

    [Fact]
    public void A_folded_value_is_removed_with_its_continuation_lines()
    {
        var legacy = Path.Combine(_checkout.Root, "legacy3", "devstack.yaml");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        File.WriteAllText(legacy, $"octoToolsPath: >-\n  /workspace/octo-tools\n\n# a comment\nrootPath: {_checkout.Root}\nstopTimeoutSeconds: 9\n");
        var store = new ConfigStore(Path.Combine(_checkout.Root, "new3", "devstack.yaml"))
        {
            Workspace = new WorkspaceDefaults(_checkout.Root, Path.Combine(_checkout.Root, "octo-tools"), "branches/main")
        };

        store.TakeOver(legacy, store.Workspace).Should().Contain("octoToolsPath, rootPath removed");

        var taken = File.ReadAllText(store.ConfigPath);
        taken.Should().NotContain("/workspace/octo-tools").And.Contain("# a comment").And.Contain("stopTimeoutSeconds: 9");
        store.Load().StopTimeoutSeconds.Should().Be(9, "the result is a valid file");
    }

    [Fact]
    public void A_default_lane_stays_when_a_kept_root_would_change_what_it_means()
    {
        // The old file has its own root and names the workspace's lane by its full path: without the line the lane would be
        // inherited below the kept root (custom/branches/main), another folder.
        var legacy = Path.Combine(_checkout.Root, "legacy4", "devstack.yaml");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        var custom = Path.Combine(_checkout.Root, "custom");
        Directory.CreateDirectory(Path.Combine(custom, "branches", "main"));
        File.WriteAllText(legacy, $"rootPath: {custom}\ndefaultCheckout: {_checkout.Lane}\n");
        var store = new ConfigStore(Path.Combine(_checkout.Root, "new4", "devstack.yaml"))
        {
            Workspace = new WorkspaceDefaults(_checkout.Root, Path.Combine(_checkout.Root, "octo-tools"), "branches/main")
        };

        store.TakeOver(legacy, store.Workspace);

        var config = store.Load();
        config.RootPathSetting.Should().Be(custom);
        config.DefaultCheckoutSetting.Should().Be(_checkout.Lane, "it still points at the lane it named");
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void A_file_without_rootPath_compares_its_default_lane_below_the_workspace_root(bool absolute)
    {
        // Without a rootPath line the new file runs on the workspace root; the file's lane is resolved there too, never
        // against the daemon's current folder.
        var legacy = Path.Combine(_checkout.Root, $"legacy5{absolute}", "devstack.yaml");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        File.WriteAllText(legacy, $"defaultCheckout: {(absolute ? _checkout.Lane : "branches/main")}\n");
        var store = new ConfigStore(Path.Combine(_checkout.Root, $"new5{absolute}", "devstack.yaml"))
        {
            Workspace = new WorkspaceDefaults(_checkout.Root, Path.Combine(_checkout.Root, "octo-tools"), "branches/main")
        };

        store.TakeOver(legacy, store.Workspace)!.Should().Contain("defaultCheckout removed");

        File.ReadAllText(store.ConfigPath).Should().NotContain("defaultCheckout:");
        File.Exists(store.ConfigPath + ".tmp").Should().BeFalse("the take-over writes a temporary file and moves it in place");
        store.Load().DefaultCheckout.Should().Be("branches/main", "the workspace's lane, the same folder the file named");
    }

    [Fact]
    public void Removing_keys_keeps_everything_else_of_the_file()
    {
        ConfigStore.WithoutKeys("a: 1\nrootPath:\n  /x\nb: 2\n", ["rootPath"]).Should().Be("a: 1\nb: 2\n");
        ConfigStore.WithoutKeys("rootPath: /x\r\n  # not a continuation of a plain value? still indented, dropped\r\nc: 3\r\n", ["rootPath"]).Should().Be("c: 3\r\n");
        ConfigStore.WithoutKeys("rootPathExtra: 1\n", ["rootPath"]).Should().Be("rootPathExtra: 1\n", "only the exact key");
    }
}
