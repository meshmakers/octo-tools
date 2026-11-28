using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

public class ExternalDetectorTests
{
    // Shape of a real process chain: a Claude Code session ran Start-Octo, which runs each service in a pwsh job; the same
    // session ran npm run start; a mesh adapter was left behind (ppid 1).
    private const string Ps = """
                                1     0 28-09:06:55 /sbin/launchd
                              18448 31289 02:15:49 /Users/dev/.local/bin/claude --dangerously-skip-permissions --agent octo-claude-pm:cpo-platform --resume b3936174-1b29-4e23-beb8-2ce5edf8be9e
                              82084 18448 01:53:12 /bin/zsh -c source /Users/dev/.claude/shell-snapshots/snapshot.sh && eval 'pwsh ...'
                              82085 82084 01:53:12 pwsh -NoLogo -Command . /Users/dev/octo-tools/modules/profile.ps1 | Out-Null; Start-Octo -branch "branches/main" -configuration DebugL -nonInteractive $true -meshAdapterTenantId octogrid
                              82268 82085 01:53:06 /usr/local/microsoft/powershell/7/pwsh -s -NoLogo -NoProfile -wd /Users/dev/branches/main
                              82276 82268 01:53:06 /usr/local/share/dotnet/dotnet Meshmakers.Octo.Backend.IdentityServices.dll --urls=https://0.0.0.0:5003;http://0.0.0.0:5002
                              81626 18448    40:00 /bin/zsh -c source /Users/dev/.claude/shell-snapshots/snapshot.sh && eval 'npm run start'
                              81627 81626    40:00 npm run start
                              81832 81627    39:58 ng serve (octo-mesh-refinery-studio)
                              84985     1 1-02:03:04 dotnet Meshmakers.Octo.MeshAdapter.dll --urls=https://0.0.0.0:5030;http://0.0.0.0:5031 --Adapter:TenantId=tmp-archfinal
                              """;

    private static Dictionary<int, ExternalDetector.PsRow> Table() => ExternalDetector.ParsePs(Ps).ToDictionary(r => r.Pid);

    private static readonly Dictionary<int, (string? Cwd, string? Stdout)> Files = new()
    {
        [18448] = ("/Users/dev/branches/main", null)
    };

    [Fact]
    public void Ps_output_is_parsed_with_elapsed_time_and_full_command()
    {
        var rows = Table();
        rows[82276].Ppid.Should().Be(82268);
        rows[82276].Elapsed.Should().Be(new TimeSpan(1, 53, 6));
        rows[84985].Elapsed.Should().Be(new TimeSpan(1, 2, 3, 4));
        rows[81832].Elapsed.Should().Be(new TimeSpan(0, 39, 58));
        rows[81832].Command.Should().Be("ng serve (octo-mesh-refinery-studio)");
    }

    [Fact]
    public void Start_Octo_origin_names_branch_configuration_session_and_stop_command()
    {
        var origin = ExternalDetector.DescribeOrigin(82276, Table(), Files);
        origin.Kind.Should().Be("start-octo");
        origin.LauncherPid.Should().Be(82085);
        origin.Branch.Should().Be("branches/main");
        origin.Configuration.Should().Be("DebugL");
        origin.NonInteractive.Should().BeTrue();
        origin.StopHint.Should().Be("Stop-Octo -branch branches/main");
        origin.LauncherCommand.Should().StartWith("Start-Octo -branch");
        origin.Session!.Agent.Should().Be("octo-claude-pm:cpo-platform");
        origin.Session.SessionId.Should().Be("b3936174-1b29-4e23-beb8-2ce5edf8be9e");
        origin.Session.WorkingDirectory.Should().Be("/Users/dev/branches/main");
        origin.Description.Should().Be("Start-Octo, started by a Claude Code session (agent octo-claude-pm:cpo-platform, session b3936174)");
    }

    [Fact]
    public void Session_origin_names_the_command_below_the_session_shell()
    {
        var origin = ExternalDetector.DescribeOrigin(81832, Table(), Files);
        origin.Kind.Should().Be("session");
        origin.LauncherCommand.Should().Be("npm run start");
        origin.LauncherPid.Should().Be(81627);
        origin.StopHint.Should().Be(ProcessTree.KillHint(81627));
    }

    [Fact]
    public void Process_without_parent_is_an_orphan()
    {
        var origin = ExternalDetector.DescribeOrigin(84985, Table(), Files);
        origin.Kind.Should().Be("orphan");
        origin.StopHint.Should().Be(ProcessTree.KillHint(84985));
    }

    [Fact]
    public void Lsof_listen_output_maps_pids_to_ports()
    {
        const string output = "p82276\nf12\nn*:5003\nf13\nn*:5002\nf14\nn[::1]:5003\np81832\nf20\nn127.0.0.1:4200\n";
        var ports = ExternalDetector.ParseLsofListen(output);
        ports[82276].Should().Equal(5002, 5003);
        ports[81832].Should().Equal(4200);
    }

    [Fact]
    public void Lsof_file_output_gives_cwd_and_stdout_file_but_not_pipes()
    {
        const string output = "p84985\nfcwd\nn/lane/octo-mesh-adapter/bin/DebugL/net10.0\nf1\nn/lane/logFiles/MeshAdapter-x.log\n" +
                              "p82276\nfcwd\nn/lane/octo-identity-services/bin/DebugL/net10.0\nf1\nn->0x1234\n";
        var files = ExternalDetector.ParseLsofFiles(output);
        files[84985].Should().Be(("/lane/octo-mesh-adapter/bin/DebugL/net10.0", "/lane/logFiles/MeshAdapter-x.log"));
        files[82276].Cwd.Should().Be("/lane/octo-identity-services/bin/DebugL/net10.0");
        files[82276].Stdout.Should().BeNull();
    }

    [Fact]
    public void Arguments_are_read_with_and_without_quotes()
    {
        ExternalDetector.Arg("Start-Octo -branch \"branches/main\" -configuration DebugL", "-branch").Should().Be("branches/main");
        ExternalDetector.Arg("Start-Octo -branch \"branches/main\" -configuration DebugL", "-configuration").Should().Be("DebugL");
        ExternalDetector.Arg("claude --resume=abc", "--resume").Should().Be("abc");
        ExternalDetector.Arg("claude --agent x", "--resume").Should().BeNull();
    }

    [Fact]
    public void Repo_folder_is_found_for_the_lane_repo_and_for_a_worktree()
    {
        using var checkout = new TestCheckout();
        var repo = checkout.Repo("octo-mesh-adapter");
        Directory.CreateDirectory(Path.Combine(repo, ".git", "worktrees", "wt-1"));
        var bin = Path.Combine(repo, "bin", "DebugL", "net10.0");
        Directory.CreateDirectory(bin);
        ExternalDetector.FindRepoFolder(bin, "octo-mesh-adapter", checkout.Root).Should().Be(repo);
        ExternalDetector.FindRepoFolder(bin, "octo-identity-services", checkout.Root).Should().BeNull();

        var worktree = checkout.Repo("wt-1-octo-mesh-adapter");
        File.WriteAllText(Path.Combine(worktree, ".git"), $"gitdir: {Path.Combine(repo, ".git", "worktrees", "wt-1")}\n");
        var wtBin = Path.Combine(worktree, "bin", "DebugL", "net10.0");
        Directory.CreateDirectory(wtBin);
        ExternalDetector.FindRepoFolder(wtBin, "octo-mesh-adapter", checkout.Root).Should().Be(worktree);
    }

    [Fact]
    public void A_location_the_path_API_rejects_lies_in_no_repo()
    {
        using var checkout = new TestCheckout();

        // AB#9924: a command line with a NUL character (zenon's zenDBSrv.exe) gives a location with a NUL in it.
        WindowsSupportTests.Visible(ExternalDetector.FindRepoFolder(Path.Combine(checkout.Root, "a\0x"), "tools", checkout.Root)).Should().BeNull();
        ExternalDetector.FindRepoFolder("", "tools", checkout.Root).Should().BeNull();
    }

    [Fact]
    public void An_unnamed_stdout_in_lsof_output_is_skipped()
    {
        var files = ExternalDetector.ParseLsofFiles("p42\nfcwd\nn/x/repo\nf1\nn\np43\nf1\nn/x/log.txt\n");

        files[42].Should().Be(("/x/repo", (string?)null));
        files[43].Stdout.Should().Be("/x/log.txt");
    }
}
