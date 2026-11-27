using System.Buffers.Binary;
using System.Diagnostics;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>The Windows code paths' logic (command lines, TCP table, adoption, stop, process scan), tested on every OS.</summary>
public class WindowsSupportTests
{
    // ---------- command lines ----------

    [Theory]
    [InlineData("plain")]
    [InlineData("a b")]
    [InlineData("")]
    [InlineData("it's")]
    [InlineData("q\"uote")]
    [InlineData(@"C:\Program Files\dotnet\")]
    [InlineData(@"back\\slash\""quote")]
    [InlineData("--urls=https://0.0.0.0:5003;http://0.0.0.0:5002")]
    [InlineData("x&y^z|w %PATH% (p)<r>!")]
    public void Quoted_arguments_split_back_unchanged(string argument)
    {
        WindowsCommandLine.Split(WindowsCommandLine.Join("prog", [argument, "next"])).Should().Equal("prog", argument, "next");
    }

    [Fact]
    public void Split_follows_the_CommandLineToArgvW_rules()
    {
        WindowsCommandLine.Split(@"""C:\Program Files\dotnet\dotnet.exe"" Octo.dll  --x=""a b"" \""q a\\\""b"" c\\d")
            .Should().Equal(@"C:\Program Files\dotnet\dotnet.exe", "Octo.dll", "--x=a b", "\"q", @"a\""b c\\d");
    }

    [Fact]
    public void Cmd_wrapper_escapes_every_metacharacter_and_keeps_the_log_path_quoted()
    {
        var args = WindowsCommandLine.CmdWrapperArguments("dotnet", ["Octo.dll", "--x=a&b", "%PATH%"], @"C:\lane\log Files\Identity.log");

        args.Should().Be(@"/d /v:off /s /c ""dotnet Octo.dll --x=a^&b ^%PATH^% <NUL >>""C:\lane\log Files\Identity.log"" 2>&1""");
        WindowsCommandLine.CmdEscape("\"a b\"").Should().Be("^\"a b^\"", "escaped quotes keep cmd out of its quote mode");
        var bad = () => WindowsCommandLine.CmdWrapperArguments("x", [], @"C:\100%\log.txt");
        bad.Should().Throw<InvalidOperationException>();
    }

    [Theory]
    [InlineData(@"""C:\Users\me\.local\bin\claude.exe"" --resume abc", "claude")]
    [InlineData("/Users/me/.local/bin/claude --agent x", "claude")]
    [InlineData(@"C:\Windows\system32\cmd.exe /c x", "cmd")]
    [InlineData("-zsh", "-zsh")]
    public void Program_name_drops_path_quotes_and_exe(string commandLine, string expected)
    {
        WindowsCommandLine.ProgramName(commandLine).Should().Be(expected);
    }

    [Fact]
    public void The_log_header_quotes_arguments_with_spaces_or_quotes()
    {
        var plan = new ServicePlan("x", "/r", "/r/bin", "dotnet", ["X.dll", "a b", "c\"d", "--plain"], new Dictionary<string, string?>(), "/r/x.log",
            [], null, [], null);
        ProcessLauncher.HeaderLine(plan, DateTimeOffset.Now).Should().Contain(": dotnet X.dll \"a b\" \"c\\\"d\" --plain (in /r/bin)");
    }

    // ---------- TCP table ----------

    [Fact]
    public void Tcp_listener_tables_give_port_and_pid_for_IPv4_and_IPv6()
    {
        var v4 = new byte[4 + 2 * TcpListenerTable.Ipv4RowSize];
        BinaryPrimitives.WriteInt32LittleEndian(v4, 2);
        Row(v4, 4, portOffset: 8, pidOffset: 20, port: 5003, pid: 1234);
        Row(v4, 4 + TcpListenerTable.Ipv4RowSize, portOffset: 8, pidOffset: 20, port: 80, pid: 4);
        TcpListenerTable.Parse(v4, ipv6: false).Should().Equal((5003, 1234), (80, 4));

        var v6 = new byte[4 + TcpListenerTable.Ipv6RowSize];
        BinaryPrimitives.WriteInt32LittleEndian(v6, 1);
        Row(v6, 4, portOffset: 20, pidOffset: 52, port: 5031, pid: 9876);
        TcpListenerTable.Parse(v6, ipv6: true).Should().Equal((5031, 9876));

        TcpListenerTable.Parse(v4.AsSpan(0, 30), ipv6: false).Should().Equal([(5003, 1234)], "a truncated row is not read");
        TcpListenerTable.Parse([], ipv6: false).Should().BeEmpty();
    }

    private static void Row(byte[] buffer, int row, int portOffset, int pidOffset, int port, int pid)
    {
        // Network byte order in the low 16 bits; the high bytes are garbage the parser must ignore.
        buffer[row + portOffset] = (byte)(port >> 8);
        buffer[row + portOffset + 1] = (byte)(port & 0xFF);
        buffer[row + portOffset + 2] = 0xAB;
        BinaryPrimitives.WriteInt32LittleEndian(buffer.AsSpan(row + pidOffset), pid);
    }

    // ---------- process tree ----------

    [Fact]
    public void Descendants_follow_the_parent_links_root_first()
    {
        ProcessTree.DescendantsOf(10, [(11, 10), (12, 11), (13, 99), (14, 10)]).Should().Equal(10, 11, 14, 12);
    }

    [Fact]
    public void A_parent_created_after_its_child_is_a_reused_pid()
    {
        var t = DateTimeOffset.Now;
        var child = new WindowsProcessRow(20, 8, "dotnet.exe", t);
        ProcessTree.IsRealParent(child, new WindowsProcessRow(8, 4, "pwsh.exe", t.AddMinutes(-1))).Should().BeTrue();
        ProcessTree.IsRealParent(child, new WindowsProcessRow(8, 4, "notepad.exe", t.AddMinutes(1))).Should().BeFalse();
        ProcessTree.IsRealParent(child, null).Should().BeFalse();
    }

    [Fact]
    public void Start_times_match_within_the_tolerance_and_unknown_times_do_not_count_against()
    {
        var t = DateTimeOffset.Now;
        ProcessTree.SameStart(t, t.AddSeconds(1.5)).Should().BeTrue();
        ProcessTree.SameStart(t, t.AddSeconds(5)).Should().BeFalse();
        ProcessTree.SameStart(null, t).Should().BeTrue();
        ProcessTree.SameStart(t, null).Should().BeTrue();

        using var self = Process.GetCurrentProcess();
        ProcessTree.StartTime(Environment.ProcessId).Should().BeCloseTo(new DateTimeOffset(self.StartTime), TimeSpan.FromSeconds(1));
        ProcessTree.IsAlive(Environment.ProcessId, ProcessTree.StartTime(Environment.ProcessId)).Should().BeTrue();
        ProcessTree.IsAlive(Environment.ProcessId, DateTimeOffset.Now.AddHours(-30)).Should().BeFalse("the pid now belongs to another process");
    }

    [Fact]
    public async Task Terminate_waits_for_a_graceful_exit_and_kills_only_what_is_left()
    {
        var alive = new HashSet<int> { 1, 2 };
        var killed = new List<int>();

        var hadToKill = await ProcessTree.TerminateCoreAsync([1, 2], () =>
        {
            alive.Clear();
            return true;
        }, alive.Contains, killed.Add, TimeSpan.FromSeconds(2), TimeSpan.FromMilliseconds(10), CancellationToken.None);
        hadToKill.Should().BeFalse();
        killed.Should().BeEmpty();

        alive = [1, 2];
        hadToKill = await ProcessTree.TerminateCoreAsync([1, 2], () =>
        {
            alive.Remove(2); // the child stops, the root ignores the signal
            return true;
        }, alive.Contains, killed.Add, TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(10), CancellationToken.None);
        hadToKill.Should().BeTrue();
        killed.Should().Equal(1);

        // No graceful way (Windows without a console group): zero timeout, the tree is killed at once.
        killed.Clear();
        alive = [1, 2];
        var watch = Stopwatch.StartNew();
        (await ProcessTree.TerminateCoreAsync([1, 2], () => false, alive.Contains, killed.Add, TimeSpan.Zero, TimeSpan.FromSeconds(5),
            CancellationToken.None)).Should().BeTrue();
        killed.Should().Equal(1, 2);
        watch.Elapsed.Should().BeLessThan(TimeSpan.FromSeconds(1));
    }

    [Fact]
    public void The_ctrl_break_helper_is_the_apphost_or_dotnet_with_the_daemon_dll()
    {
        ConsoleSignal.HelperCommand(@"C:\tools\octo-devstack.exe", @"C:\tools\octo-devstack.dll", 1200, 300)
            .Should().BeEquivalentTo((@"C:\tools\octo-devstack.exe", new List<string> { ConsoleSignal.HelperSwitch, "1200", "300" }));
        var (file, args) = ConsoleSignal.HelperCommand(@"C:\Program Files\dotnet\dotnet.exe", @"C:\tools\octo-devstack.dll", 1200, 300);
        file.Should().Be(@"C:\Program Files\dotnet\dotnet.exe");
        args.Should().Equal(@"C:\tools\octo-devstack.dll", ConsoleSignal.HelperSwitch, "1200", "300");
    }

    [Fact]
    public void The_whole_console_is_signalled_only_when_the_target_is_alone_on_it()
    {
        // The daemon started hidden by Start-OctoDevStackDaemon: its console holds it and, for a moment, the helper.
        ConsoleSignal.AloneOnConsole([1200, 77], target: 1200, helper: 77).Should().BeTrue();
        ConsoleSignal.AloneOnConsole([1200], target: 1200, helper: 77).Should().BeTrue();
        // A daemon in the foreground of a terminal shares the console with the shell: never signal that.
        ConsoleSignal.AloneOnConsole([1200, 77, 4000], target: 1200, helper: 77).Should().BeFalse();
        ConsoleSignal.ConsoleMode.Should().Be("console", "Stop-OctoDevStackDaemon passes it as the fourth argument");
    }

    // ---------- adoption ----------

    [Fact]
    public void Adoption_needs_the_pid_alive_running_the_service_and_started_when_recorded()
    {
        var started = DateTimeOffset.Now.AddMinutes(-10);
        var s = new PersistedService { Name = "identity", Pid = 4242, Command = "dotnet", Args = ["Identity.dll"], ProcessStartTime = started };
        const string cmd = @"C:\Windows\system32\cmd.exe /d /v:off /s /c ""dotnet Identity.dll <NUL >>""C:\l\Identity.log"" 2>&1""";

        SlotRun.NotAdoptable(s, true, cmd, started.AddSeconds(1)).Should().BeNull("the cmd.exe wrapper's command line names the service");
        SlotRun.NotAdoptable(s, false, "", null).Should().Contain("exited");
        SlotRun.NotAdoptable(s, true, "notepad.exe", started).Should().Contain("another program");
        SlotRun.NotAdoptable(s, true, "", started).Should().Contain("cannot be read");
        SlotRun.NotAdoptable(s, true, cmd, started.AddMinutes(5)).Should().Contain("reused");
        SlotRun.NotAdoptable(new PersistedService { Pid = 1, Command = "dotnet", Args = ["Identity.dll"] }, true, cmd, DateTimeOffset.Now)
            .Should().BeNull("state files of older daemons have no start time");
    }

    // ---------- external processes ----------

    [Fact]
    public void Windows_command_lines_are_recognised_as_sessions_shells_and_services()
    {
        ExternalDetector.IsClaude(@"""C:\Users\me\.local\bin\claude.exe"" --resume abc").Should().BeTrue();
        ExternalDetector.IsClaude(@"""C:\Program Files\nodejs\node.exe"" C:\Users\me\AppData\Roaming\npm\node_modules\@anthropic-ai\claude-code\cli.js")
            .Should().BeTrue();
        ExternalDetector.IsClaude(@"""C:\Program Files\nodejs\node.exe"" ng serve").Should().BeFalse();
        ExternalDetector.IsShell(@"""C:\Program Files\Git\usr\bin\bash.exe"" -c ""npm run start""").Should().BeTrue();
        ExternalDetector.IsShell(@"C:\Windows\system32\cmd.exe /c x").Should().BeTrue();
        ExternalDetector.IsShell("/bin/zsh -c x").Should().BeTrue();
        ExternalDetector.IsShell("pwsh -NoLogo").Should().BeFalse("pwsh stays a launcher (Start-Octo runs in it)");

        ExternalDetector.ContainsToken(@"""C:\Program Files\dotnet\dotnet.exe"" Octo.Identity.dll --urls=x", "Octo.Identity.dll").Should().BeTrue();
        ExternalDetector.ContainsToken(@"dotnet ""C:\lane\octo-identity\bin\DebugL\net10.0\Octo.Identity.dll""", "Octo.Identity.dll").Should().BeTrue();
        ExternalDetector.ContainsToken(@"dotnet C:\lane\x\NotOcto.Identity.dll", "Octo.Identity.dll").Should().BeFalse();
        ExternalDetector.Arg(@"pwsh -Command ""Start-Octo -branch \""branches/main\"" -configuration DebugL""", "-branch").Should().Be("branches/main");
    }

    [Fact]
    public void Location_of_a_process_comes_from_its_dll_its_modules_or_an_absolute_argument()
    {
        // Rooted paths of the OS the test runs on (Path.IsPathFullyQualified is OS-specific).
        var lane = Path.Combine(Path.GetTempPath(), "lane");
        var bin = Path.Combine(lane, "octo-identity", "bin", "DebugL", "net10.0");
        var dll = Path.Combine(bin, "Octo.Identity.dll");
        string? NoModule(string _) => null;

        ExternalDetector.LocationFromCommandLine(WindowsCommandLine.Join("dotnet", [dll, "--urls=x"]), NoModule).Should().Be(bin);
        ExternalDetector.LocationFromCommandLine("dotnet Octo.Identity.dll --urls=x", f => f == "Octo.Identity.dll" ? dll : null).Should().Be(bin);
        var script = Path.Combine(lane, "octo-studio", "node_modules", "@angular", "cli", "bin", "ng");
        ExternalDetector.LocationFromCommandLine(WindowsCommandLine.Join("node", [script, "serve"]), NoModule).Should().Be(Path.GetDirectoryName(script),
            "a location is a folder, like a working directory");
        ExternalDetector.LocationFromCommandLine(WindowsCommandLine.Join("node", ["--root=" + script]), NoModule).Should().Be(Path.GetDirectoryName(script));
        ExternalDetector.LocationFromCommandLine(WindowsCommandLine.Join("node", [Path.GetTempPath()]), NoModule).Should().Be(Path.GetTempPath());
        ExternalDetector.LocationFromCommandLine("dotnet Octo.Identity.dll", NoModule).Should().BeNull();
    }

    [Fact]
    public void The_scan_finds_services_from_Windows_rows_and_a_reused_parent_makes_an_orphan()
    {
        using var checkout = new TestCheckout();
        var repo = checkout.Repo("octo-identity-services");
        Directory.CreateDirectory(Path.Combine(repo, ".git"));
        var bin = Path.Combine(repo, "bin", "DebugL", "net10.0");
        Directory.CreateDirectory(bin);
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        config.RootPath = checkout.Root;
        var dll = config.Services["identityServices"].Args.First(a => a.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));

        var observation = new ExternalDetector.Observation(
        [
            new ExternalDetector.PsRow(500, 0, TimeSpan.FromMinutes(3), $@"""C:\Program Files\dotnet\dotnet.exe"" {dll} --urls=https://0.0.0.0:5003"),
            new ExternalDetector.PsRow(600, 0, TimeSpan.FromMinutes(1), @"""C:\Program Files\JetBrains\rider64.exe""")
        ], new Dictionary<int, List<int>> { [500] = [5003], [600] = [63342] }, pids => pids.ToDictionary(p => p, p => p == 500 ? (bin, (string?)null) : (null, null)));

        var snapshot = ExternalDetector.Analyse(config, observation, new HashSet<int>(), [SlotInfo.Default]);

        var service = snapshot.Services.Should().ContainSingle("the IDE listens on a port but runs no stack service").Subject;
        service.Service.Should().Be("identityServices");
        service.RepoPath.Should().Be(repo);
        service.Configuration.Should().Be("DebugL");
        service.SlotHint.Should().Be(SlotInfo.DefaultName);
        snapshot.Groups.Single().Origin.Kind.Should().Be("orphan", "its parent is gone (ppid 0 on Windows)");
    }

    [Fact]
    public void A_listener_without_a_service_dll_is_the_service_whose_port_it_holds()
    {
        using var checkout = new TestCheckout();
        var repo = checkout.Repo("tools");
        Directory.CreateDirectory(Path.Combine(repo, ".git"));
        var config = checkout.WriteConfig("""
                                            sleeper:
                                              repo: tools
                                              command: node
                                              ports: [6110]
                                            web:
                                              repo: tools
                                              command: node
                                              ports: [6111]
                                          """).Load();
        var observation = new ExternalDetector.Observation(
            [new ExternalDetector.PsRow(700, 0, TimeSpan.FromMinutes(1), "node server.js")],
            new Dictionary<int, List<int>> { [700] = [6111] }, pids => pids.ToDictionary(p => p, _ => ((string?)repo, (string?)null)));

        var service = ExternalDetector.Analyse(config, observation, new HashSet<int>(), [SlotInfo.Default]).Services.Should().ContainSingle().Subject;

        service.Service.Should().Be("web", "both services run from the repo; the port decides");
        service.RepoPath.Should().Be(repo);
    }

    [Fact]
    public void A_candidate_that_is_also_a_sessions_ancestor_is_observed_once()
    {
        using var checkout = new TestCheckout();
        var config = checkout.WriteConfig("""
                                            web:
                                              repo: tools
                                              command: node
                                              ports: [6111]
                                          """).Load();
        // AB#9556: a Claude session that listens itself (a candidate) and the listener below it (whose session it is).
        IReadOnlyCollection<int>? asked = null;
        var observation = new ExternalDetector.Observation(
            [
                new ExternalDetector.PsRow(800, 1, TimeSpan.FromMinutes(5), "claude"),
                new ExternalDetector.PsRow(801, 800, TimeSpan.FromMinutes(1), "node server.js")
            ],
            new Dictionary<int, List<int>> { [800] = [6200], [801] = [6111] },
            pids =>
            {
                asked = pids;
                return pids.ToDictionary(p => p, _ => ((string?)null, (string?)null)); // throws on a pid asked for twice, as the Windows observation did
            });

        var act = () => ExternalDetector.Analyse(config, observation, new HashSet<int>(), [SlotInfo.Default]);

        act.Should().NotThrow();
        asked.Should().OnlyHaveUniqueItems().And.Contain([800, 801]);
    }

    [Fact]
    public async Task A_scan_that_fails_leaves_the_external_processes_unknown_with_a_warning_and_the_call_answers()
    {
        using var checkout = new TestCheckout();
        var store = checkout.WriteConfig("""
                                           web:
                                             repo: tools
                                             command: node
                                         """);
        var detector = new ExternalDetector(store)
        {
            ScanOverride = (_, _, _) => throw new ArgumentException("An item with the same key has already been added. Key: 10444")
        };

        var snapshot = await detector.ScanAsync(new HashSet<int>());

        snapshot.Services.Should().BeEmpty();
        snapshot.Warning.Should().StartWith("Processes outside octo-devstack are unknown").And.Contain("Key: 10444");

        // stack_status and the start/stop answers go through Masked(): the warning stays in them.
        var supervisor = new StackSupervisor(store, new Leasing.LeaseManager(), new StateStore(new DevStackPaths(checkout.StateDirectory)),
            Microsoft.Extensions.Logging.Abstractions.NullLogger<StackSupervisor>.Instance, external: detector);
        (await supervisor.StatusAsync()).Masked().External.Warning.Should().StartWith("Processes outside octo-devstack are unknown");
    }

    /// <summary>A lane with the identity service running from its bin folder outside the daemon (pid 500, port 5003).</summary>
    private static (DevStackConfig Config, string Repo, string Bin, ExternalDetector.PsRow Row) IdentityOutsideTheDaemon(TestCheckout checkout)
    {
        var repo = checkout.Repo("octo-identity-services");
        Directory.CreateDirectory(Path.Combine(repo, ".git"));
        var bin = Path.Combine(repo, "bin", "DebugL", "net10.0");
        Directory.CreateDirectory(bin);
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        config.RootPath = checkout.Root;
        var dll = config.Services["identityServices"].Args.First(a => a.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));
        return (config, repo, bin,
            new ExternalDetector.PsRow(500, 0, TimeSpan.FromMinutes(3), WindowsCommandLine.Join("dotnet", [Path.Combine(bin, dll), "--urls=https://0.0.0.0:5003"])));
    }

    [Fact]
    public void A_listener_whose_location_carries_a_NUL_is_no_stack_service_and_the_others_are_reported()
    {
        using var checkout = new TestCheckout();
        var (config, repo, _, identity) = IdentityOutsideTheDaemon(checkout);
        // AB#9924: zenon's zenDBSrv.exe listens on a port and its command line carries NUL characters (Windows counts them in its length).
        var zenon = new ExternalDetector.PsRow(900, 0, TimeSpan.FromMinutes(9),
            WindowsCommandLine.Join(Path.Combine(checkout.Root, "zen\0on", "zenDBSrv.exe"), ["-service"]) + "\0");
        var commands = new Dictionary<int, string> { [500] = identity.Command, [900] = zenon.Command };
        ExternalDetector.LocationFromCommandLine(zenon.Command, _ => null).Should().Contain("\0", "the location keeps the NUL");
        var observation = new ExternalDetector.Observation([identity, zenon], new Dictionary<int, List<int>> { [500] = [5003], [900] = [1103] },
            pids => pids.ToDictionary(p => p, p => (ExternalDetector.LocationFromCommandLine(commands[p], _ => null), (string?)null)));

        var snapshot = ExternalDetector.Analyse(config, observation, new HashSet<int>(), [SlotInfo.Default]);

        var service = snapshot.Services.Should().ContainSingle("a location that is no valid path lies in no repository").Subject;
        service.Service.Should().Be("identityServices");
        service.RepoPath.Should().Be(repo);
        snapshot.Warning.Should().BeNull();
        snapshot.Skipped.Should().BeNull("nothing failed");
    }

    [Fact]
    public void A_candidate_whose_analysis_throws_is_left_out_with_pid_executable_and_exception_type_and_the_others_are_reported()
    {
        using var checkout = new TestCheckout();
        var (config, _, bin, identity) = IdentityOutsideTheDaemon(checkout);
        // A folder whose .git file names a gitdir the path API rejects: reading it throws while the listener's repo is searched.
        var odd = checkout.Repo("odd");
        File.WriteAllText(Path.Combine(odd, ".git"), "gitdir: wt\0x\n");
        const string marker = "marker-ab9924";
        var probe = new ExternalDetector.PsRow(901, 0, TimeSpan.FromMinutes(2),
            WindowsCommandLine.Join(Path.Combine(checkout.Root, "tools", "probe.exe"), ["--" + marker, "--token=" + marker]));
        var observation = new ExternalDetector.Observation([identity, probe], new Dictionary<int, List<int>> { [500] = [5003], [901] = [6400] },
            pids => pids.ToDictionary(p => p, p => ((string?)(p == 500 ? bin : odd), (string?)null)));

        var snapshot = ExternalDetector.Analyse(config, observation, new HashSet<int>(), [SlotInfo.Default]);

        snapshot.Services.Should().ContainSingle().Which.Service.Should().Be("identityServices");
        snapshot.Warning.Should().BeNull("the other processes are known");
        snapshot.Skipped.Should().ContainSingle().Which.Should().Be(new ExternalSkipped(901, "probe.exe", "ArgumentException"));
        var json = System.Text.Json.JsonSerializer.Serialize(snapshot, new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web));
        json.Should().NotContain(marker, "the note carries no argument of the command line").And.NotContain("gitdir").And.NotContain("Null character");
    }

    [Fact]
    public void The_executable_of_a_skipped_process_is_its_program_file_name_without_arguments()
    {
        ExternalDetector.ExecutableOf("\"C:\\zen\0on\\zenDBSrv.exe\" -service\0").Should().Be("zenDBSrv.exe");
        ExternalDetector.ExecutableOf("C:\\tools\\probe.exe\0--secret").Should().Be("probe.exe", "a NUL joins the program and an argument into one token");
        ExternalDetector.ExecutableOf("/usr/bin/node /x/server.js --token=abc").Should().Be("node");
        ExternalDetector.ExecutableOf("").Should().BeEmpty();
    }

    /// <summary>Command lines whose program, read as one token, would carry a part of an argument (AB#9924).</summary>
    internal static readonly string[] MarkerCommandLines =
    [
        "\"C:\\x\\prog.exe --token=MARKER-AB9924", // unclosed quote
        "\"C:\\x\\prog.exe\"--token=MARKER-AB9924", // closing quote without a blank
        "\"C:\\x\\prog.exe --url=https://host/MARKER-AB9924", // unclosed quote, a separator inside the argument
        "\"C:\\x\\prog.exe --path=C:\\s\\MARKER-AB9924"
    ];

    public static TheoryData<string> CommandLinesWithAMarkerArgument => new(MarkerCommandLines);

    [Theory]
    [MemberData(nameof(CommandLinesWithAMarkerArgument))]
    public void A_process_left_out_is_named_without_any_part_of_its_arguments(string command)
    {
        using var checkout = new TestCheckout();
        var (config, _, bin, identity) = IdentityOutsideTheDaemon(checkout);
        var observation = new ExternalDetector.Observation([identity, new ExternalDetector.PsRow(903, 0, TimeSpan.FromMinutes(2), command)],
            new Dictionary<int, List<int>> { [500] = [5003], [903] = [6400] },
            pids => pids.Contains(903) ? throw new InvalidOperationException("unreadable") : pids.ToDictionary(p => p, _ => ((string?)bin, (string?)null)));

        var snapshot = ExternalDetector.Analyse(config, observation, new HashSet<int>(), [SlotInfo.Default]);

        snapshot.Skipped.Should().ContainSingle().Which.Executable.Should().Be("prog.exe");
        System.Text.Json.JsonSerializer.Serialize(snapshot.Skipped).Should().NotContain("MARKER");
    }

    [Fact]
    public void A_process_left_out_is_named_by_the_image_name_the_OS_reports_and_else_by_its_program_without_arguments()
    {
        // Windows reports the image name with the process snapshot; a program path with a blank is read from the command
        // line only up to the blank.
        const string command = "\"C:\\Program Files\\COPA-DATA\\zenDBSrv.exe\" -service MARKER-AB9924";

        ExternalDetector.Skip(new ExternalDetector.PsRow(1103, 0, TimeSpan.Zero, command, "zenDBSrv.exe"), new ArgumentException("x"))
            .Should().Be(new ExternalSkipped(1103, "zenDBSrv.exe", "ArgumentException"));
        ExternalDetector.Skip(new ExternalDetector.PsRow(1103, 0, TimeSpan.Zero, command), new ArgumentException("x")).Executable
            .Should().Be("Program", "without an image name the first word stands for the program, never an argument");
    }

    [Fact]
    public void A_candidate_whose_location_cannot_be_read_is_left_out_and_the_others_are_reported()
    {
        using var checkout = new TestCheckout();
        var (config, _, bin, identity) = IdentityOutsideTheDaemon(checkout);
        const string marker = "marker-ab9924";
        var probe = new ExternalDetector.PsRow(902, 0, TimeSpan.FromMinutes(2),
            WindowsCommandLine.Join(Path.Combine(checkout.Root, "tools", "probe.exe"), ["--" + marker]));
        var observation = new ExternalDetector.Observation([identity, probe], new Dictionary<int, List<int>> { [500] = [5003], [902] = [6400] },
            pids => pids.Contains(902)
                ? throw new InvalidOperationException($"no location for --{marker}")
                : pids.ToDictionary(p => p, _ => ((string?)bin, (string?)null)));

        var snapshot = ExternalDetector.Analyse(config, observation, new HashSet<int>(), [SlotInfo.Default]);

        snapshot.Services.Should().ContainSingle().Which.Service.Should().Be("identityServices");
        snapshot.Warning.Should().BeNull();
        snapshot.Skipped.Should().ContainSingle().Which.Should().Be(new ExternalSkipped(902, "probe.exe", "InvalidOperationException"));
        System.Text.Json.JsonSerializer.Serialize(snapshot).Should().NotContain(marker);
    }

    // ---------- MCP argument errors ----------

    [Fact]
    public void Argument_errors_name_the_unknown_arguments_and_the_parameters()
    {
        ArgumentErrors.Describe("service_restart", "missing 'services'.", ["owner", "service"], ["owner", "services", "slot"])
            .Should().Be("Invalid arguments for service_restart: missing 'services'. Unknown argument(s): service. Parameters of service_restart: owner, services, slot.");
        ArgumentErrors.Describe("x", "bad.", ["a"], null).Should().Be("Invalid arguments for x: bad.");
    }

    // ---------- configuration ----------

    [Fact]
    public void Missing_rootPath_or_defaultCheckout_is_named()
    {
        using var checkout = new TestCheckout();
        var config = ConfigStore.Parse(ConfigStore.ReadDefaultYaml());
        config.RootPath = checkout.Root;
        ServicePlanner.FolderProblems(config).Should().ContainSingle().Which.Should().StartWith("The default lane is unknown",
            "no workspace and no defaultCheckout: an empty value would resolve to the root itself");

        config.DefaultCheckout = "branches/main";
        ServicePlanner.FolderProblems(config).Should().BeEmpty();

        config.DefaultCheckout = "branches/nope";
        ServicePlanner.FolderProblems(config).Should().ContainSingle().Which.Should().Contain("defaultCheckout 'branches/nope'");

        config.RootPath = Path.Combine(checkout.Root, "missing");
        ServicePlanner.FolderProblems(config, "/x/devstack.yaml").Should().ContainSingle().Which.Should().Contain("rootPath").And.Contain("/x/devstack.yaml");
    }

    [Fact]
    public void Profile_paths_are_relative_with_forward_slashes()
    {
        var root = Path.Combine(Path.GetTempPath(), "root");
        PathScope.Relative(Path.Combine(root, "branches", "main"), root).Should().Be("branches/main");
        PathScope.Relative(Path.Combine(root, "branches", "main"), root + Path.DirectorySeparatorChar).Should().Be("branches/main");
        PathScope.Relative(root, root).Should().Be(root);
        PathScope.Relative(Path.Combine(Path.GetTempPath(), "other"), root).Should().Be(Path.Combine(Path.GetTempPath(), "other"));
        if (OperatingSystem.IsWindows())
        {
            PathScope.Relative(@"c:\dev\meshmakers/branches/main", @"C:\dev\meshmakers").Should().Be("branches/main");
        }
    }
}
