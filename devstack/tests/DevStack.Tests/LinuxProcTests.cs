using FluentAssertions;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     /proc instead of lsof on Linux (AB#9377). The parsers and the fd walk run on every OS: the /proc tree is a temp folder
///     of plain files, and the links are a dictionary passed as the link reader.
/// </summary>
public sealed class LinuxProcTests : IDisposable
{
    private readonly TestCheckout _checkout = new();

    public void Dispose() => _checkout.Dispose();

    private const string Tcp = """
                                 sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
                                  0: 0100007F:13BA 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41001 1 0000000000000000 100 0 0 10 0
                                  1: 0100007F:138B 0100007F:A1B2 01 00000000:00000000 00:00000000 00000000  1000        0 41002 1 0000000000000000 20 4 30 10 -1
                                  2: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 0 1 0000000000000000 100 0 0 10 0
                               """;

    private const string Tcp6 = """
                                  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
                                   0: 00000000000000000000000001000000:13BB 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41003 1 0000000000000000 100 0 0 10 0
                                """;

    [Fact]
    public void Listening_sockets_are_the_rows_in_state_0A_with_their_port_and_inode()
    {
        var listening = LinuxProc.ParseListening([Tcp, Tcp6]);

        // 0x13BA = 5050, 0x13BB = 5051; the established row (01) and the row without an inode do not count.
        listening.Should().BeEquivalentTo(new Dictionary<long, int> { [41001] = 5050, [41003] = 5051 });
        LinuxProc.SocketInode("socket:[41001]").Should().Be(41001);
        LinuxProc.SocketInode("pipe:[77]").Should().BeNull();
        LinuxProc.SocketInode(null).Should().BeNull();
    }

    [Fact]
    public void Ports_are_mapped_to_the_pids_whose_fds_hold_the_sockets_and_cwd_and_stdout_come_from_the_links()
    {
        var proc = Path.Combine(_checkout.Root, "proc");
        Directory.CreateDirectory(Path.Combine(proc, "net"));
        File.WriteAllText(Path.Combine(proc, "net", "tcp"), Tcp);
        File.WriteAllText(Path.Combine(proc, "net", "tcp6"), Tcp6);
        var links = new Dictionary<string, string>();
        void Fd(int pid, int fd, string target)
        {
            var folder = Path.Combine(proc, pid.ToString(), "fd");
            Directory.CreateDirectory(folder);
            var path = Path.Combine(folder, fd.ToString());
            File.WriteAllText(path, "");
            links[path] = target;
        }

        Fd(120, 1, "/home/me/logs/identity.log");
        Fd(120, 7, "socket:[41001]");
        Fd(120, 8, "socket:[41003]");
        Fd(300, 1, "pipe:[9]");
        Fd(300, 4, "socket:[41002]"); // established, not listening
        Directory.CreateDirectory(Path.Combine(proc, "self")); // not a pid
        links[Path.Combine(proc, "120", "cwd")] = "/home/me/dev/meshmakers/octo-identity-services";
        links[Path.Combine(proc, "300", "cwd")] = "/tmp";

        var ports = LinuxProc.ListeningPortsByPid(proc, p => links.GetValueOrDefault(p));
        var files = LinuxProc.Files([120, 300, 999], proc, p => links.GetValueOrDefault(p));

        ports.Should().BeEquivalentTo(new Dictionary<int, List<int>> { [120] = [5050, 5051] });
        files[120].Should().Be(("/home/me/dev/meshmakers/octo-identity-services", "/home/me/logs/identity.log"));
        files[300].Should().Be(("/tmp", (string?)null), "a pipe is no stdout target, as with lsof");
        files.Should().NotContainKey(999, "a process that is gone or not readable has no entry");
    }

    [Fact]
    public void A_process_is_alive_only_by_a_state_that_is_neither_zombie_nor_gone()
    {
        // What a stopped pwsh looked like 3 ms after SIGTERM: its main thread a zombie, two threads still being torn down.
        const string exiting = "3154 (pwsh) Z 2793 293 293 34816 293 4228108 8692 0 0 0 12 5 0 0 20 0 2 0 104179 0 0";
        ProcessTree.ParseProcStatState(exiting).Should().Be("Z");
        ProcessTree.ParseProcStatState("42 (a (strange) name) S 1 42 42 0").Should().Be("S", "the command may hold spaces and parentheses");
        ProcessTree.ParseProcStatState("").Should().BeEmpty();

        ProcessTree.AliveByState("S").Should().BeTrue();
        ProcessTree.AliveByState(" Sl+\n").Should().BeTrue("ps pads and ends its stat column");
        ProcessTree.AliveByState("Zl+").Should().BeFalse("a multi-threaded process whose main thread ended is on its way out");
        ProcessTree.AliveByState("").Should().BeFalse("reaped between kill(0) and the state read: gone, not alive");
        ProcessTree.LinuxProcState(int.MaxValue, Path.Combine(_checkout.Root, "no-proc")).Should().BeEmpty();
    }

    [Fact]
    public void The_real_proc_shows_a_port_this_process_listens_on_and_its_working_directory()
    {
        using var listener = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
        listener.Start();
        var port = ((System.Net.IPEndPoint)listener.LocalEndpoint).Port;

        if (OperatingSystem.IsLinux())
        {
            LinuxProc.ListeningPortsByPid().GetValueOrDefault(Environment.ProcessId).Should().Contain(port);
            LinuxProc.Files([Environment.ProcessId])[Environment.ProcessId].Cwd.Should().Be(Path.TrimEndingDirectorySeparator(Environment.CurrentDirectory));
        }
        else
        {
            LinuxProc.UseProc.Should().BeFalse("only Linux reads /proc; macOS keeps lsof, Windows the TCP table");
        }
    }
}
