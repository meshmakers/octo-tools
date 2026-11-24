using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Signals and inspects processes and their descendants: macOS/Linux via ps, lsof and kill(2); Windows via a Toolhelp
///     snapshot and per-process queries (<see cref="WindowsProcesses"/>), GetExtendedTcpTable and console control events
///     (see <see cref="ConsoleSignal"/>).
/// </summary>
public static class ProcessTree
{
    private const int SigTerm = 15;
    private const int SigKill = 9;
    private const int Eperm = 1;

    /// <summary>How far a process's start time may be off the recorded one and still count as the same process.</summary>
    public static readonly TimeSpan StartTimeTolerance = TimeSpan.FromSeconds(2);

    // DllImport instead of LibraryImport: the generated stub would need AllowUnsafeBlocks for one int-only call.
    [DllImport("libc", EntryPoint = "kill", SetLastError = true)]
#pragma warning disable SYSLIB1054
    private static extern int SysKill(int pid, int signal);
#pragma warning restore SYSLIB1054

    public static bool IsAlive(int pid)
    {
        if (pid <= 0)
        {
            return false;
        }

        if (OperatingSystem.IsWindows())
        {
            try
            {
                using var p = Process.GetProcessById(pid);
                return !p.HasExited;
            }
            catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
            {
                return false;
            }
        }

        if (SysKill(pid, 0) == 0)
        {
            // A zombie still answers kill(0). Linux reads the state from /proc (no process per check), macOS from ps.
            return AliveByState(OperatingSystem.IsLinux() ? LinuxProcState(pid) : RunPs($"-o stat= -p {pid}"));
        }

        return Marshal.GetLastPInvokeError() == Eperm;
    }

    /// <summary>
    ///     Whether a process state (ps stat, or the state field of /proc/&lt;pid&gt;/stat) is a live process. Z: a zombie - also
    ///     a multi-threaded process (pwsh, every .NET program) whose main thread already ended while its last threads are torn
    ///     down. Empty: the process was reaped between kill(0) and the state read - gone, not alive (that race counted as
    ///     alive before, and a stopped service looked alive right after its stop).
    /// </summary>
    internal static bool AliveByState(string state) => state.TrimStart() is { Length: > 0 } s && s[0] != 'Z';

    /// <summary>The state letter of /proc/&lt;pid&gt;/stat (the field after the command in parentheses), empty when it is gone.</summary>
    internal static string LinuxProcState(int pid, string procRoot = "/proc")
    {
        try
        {
            return ParseProcStatState(File.ReadAllText(Path.Combine(procRoot, pid.ToString(System.Globalization.CultureInfo.InvariantCulture), "stat")));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "";
        }
    }

    /// <summary>The state of a /proc/&lt;pid&gt;/stat line: after the last ')' (the command itself may contain spaces and parentheses).</summary>
    internal static string ParseProcStatState(string stat)
    {
        var close = stat.LastIndexOf(')');
        var rest = close < 0 ? "" : stat[(close + 1)..].TrimStart();
        return rest.Length > 0 ? rest[..1] : "";
    }

    /// <summary>
    ///     Alive and still the process that started at <paramref name="startedAt"/> (pid reuse): a start time that cannot be
    ///     read (another user's process) does not count against it.
    /// </summary>
    public static bool IsAlive(int pid, DateTimeOffset? startedAt) =>
        IsAlive(pid) && SameStart(startedAt, StartTime(pid));

    /// <summary>True when either time is unknown or both are within <see cref="StartTimeTolerance"/>.</summary>
    public static bool SameStart(DateTimeOffset? recorded, DateTimeOffset? actual) =>
        recorded == null || actual == null || (recorded.Value - actual.Value).Duration() <= StartTimeTolerance;

    /// <summary>The start time of a process, null if it is gone or not readable.</summary>
    public static DateTimeOffset? StartTime(int pid)
    {
        if (pid <= 0)
        {
            return null;
        }

        try
        {
            using var p = Process.GetProcessById(pid);
            return StartTime(p);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>The start time of a process object, null if it is not readable.</summary>
    public static DateTimeOffset? StartTime(Process process)
    {
        try
        {
            return new DateTimeOffset(process.StartTime);
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>Command line of a process, empty if it is gone or not readable.</summary>
    public static string CommandLine(int pid)
    {
        if (OperatingSystem.IsWindows())
        {
            return WindowsProcesses.CommandLine(pid) ?? "";
        }

        return RunPs($"-o command= -p {pid}").Trim();
    }

    /// <summary>The process and all its descendants, root first.</summary>
    public static List<int> Descendants(int root) => DescendantsOf(root, Links());

    /// <summary>
    ///     Every (pid, parent pid) link of the machine, one snapshot. Windows: only real parent links (see
    ///     <see cref="IsRealParent"/>), without conhost.exe - it belongs to the service's console and ends with it.
    /// </summary>
    public static List<(int Pid, int ParentPid)> Links()
    {
        if (OperatingSystem.IsWindows())
        {
            var rows = WindowsProcesses.Snapshot();
            var byPid = rows.ToDictionary(r => r.Pid);
            return rows
                .Where(r => !r.Name.Equals("conhost.exe", StringComparison.OrdinalIgnoreCase) && IsRealParent(r, byPid.GetValueOrDefault(r.ParentPid)))
                .Select(r => (r.Pid, r.ParentPid)).ToList();
        }

        var links = new List<(int, int)>();
        foreach (var line in RunPs("-A -o pid=,ppid=").Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length == 2 && int.TryParse(parts[0], out var pid) && int.TryParse(parts[1], out var ppid))
            {
                links.Add((pid, ppid));
            }
        }

        return links;
    }

    /// <summary>The root and every process below it in the (pid, parent pid) links, root first.</summary>
    internal static List<int> DescendantsOf(int root, IEnumerable<(int Pid, int ParentPid)> links)
    {
        var result = new List<int> { root };
        var children = new Dictionary<int, List<int>>();
        foreach (var (pid, ppid) in links)
        {
            if (!children.TryGetValue(ppid, out var list))
            {
                children[ppid] = list = new List<int>();
            }

            list.Add(pid);
        }

        for (var i = 0; i < result.Count; i++)
        {
            if (children.TryGetValue(result[i], out var list))
            {
                result.AddRange(list.Where(c => !result.Contains(c)));
            }
        }

        return result;
    }

    /// <summary>
    ///     A real parent link on Windows: ParentProcessId keeps the pid of a dead parent, which may be reused by a younger
    ///     process, so a parent created after its child is no parent.
    /// </summary>
    public static bool IsRealParent(WindowsProcessRow child, WindowsProcessRow? parent) =>
        parent != null && parent.Pid != child.Pid && (parent.CreatedAt == null || child.CreatedAt == null || parent.CreatedAt <= child.CreatedAt);

    /// <summary>
    ///     Stops the tree of <paramref name="root"/> gracefully, waits up to <paramref name="timeout"/>, then kills what is
    ///     left. Returns true if it had to kill. macOS/Linux: SIGTERM to the tree. Windows: CTRL_BREAK to the process group
    ///     when <paramref name="consoleGroup"/> (the root was launched by <c>ProcessLauncher</c> as a group leader with its
    ///     own console), otherwise an immediate kill of the tree (a CTRL_BREAK could reach other processes).
    /// </summary>
    public static async Task<bool> TerminateAsync(int root, TimeSpan timeout, CancellationToken cancellationToken = default, bool consoleGroup = false)
    {
        // Collect the tree before signalling: once the root exits its children are re-parented and lost.
        var tree = Descendants(root);
        if (OperatingSystem.IsWindows())
        {
            var signalled = consoleGroup && await ConsoleSignal.SendCtrlBreakAsync(root);
            return await TerminateCoreAsync(tree, () => signalled, IsAlive, KillWindows, signalled ? timeout : TimeSpan.Zero,
                TimeSpan.FromMilliseconds(250), cancellationToken);
        }

        return await TerminateCoreAsync(tree, () =>
        {
            foreach (var pid in tree)
            {
                SysKill(pid, SigTerm);
            }

            return true;
        }, IsAlive, pid => SysKill(pid, SigKill), timeout, TimeSpan.FromMilliseconds(250), cancellationToken);
    }

    /// <summary>
    ///     Signal, wait until every process of the tree is gone or the timeout passed, then kill the rest (root first).
    ///     Returns true if it had to kill.
    /// </summary>
    internal static async Task<bool> TerminateCoreAsync(IReadOnlyList<int> tree, Func<bool> signal, Func<int, bool> isAlive, Action<int> kill,
        TimeSpan timeout, TimeSpan pollInterval, CancellationToken cancellationToken)
    {
        signal();
        // Monotonic, like every wait of the daemon: a wall clock set forward would kill before the grace period is over.
        var waited = Stopwatch.StartNew();
        while (waited.Elapsed < timeout)
        {
            if (tree.All(pid => !isAlive(pid)))
            {
                return false;
            }

            await Task.Delay(pollInterval, cancellationToken);
        }

        var killed = false;
        foreach (var pid in tree.Where(isAlive))
        {
            kill(pid);
            killed = true;
        }

        return killed;
    }

    private static void KillWindows(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            p.Kill(entireProcessTree: true);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or AggregateException)
        {
            // Gone already, or not ours to kill.
        }
    }

    /// <summary>
    ///     The command a developer types to end a process and its children: kill on macOS/Linux (the children follow their
    ///     parent's SIGTERM), taskkill /T /F on Windows (Stop-Process would leave the tree alive).
    /// </summary>
    public static string KillHint(int pid) => OperatingSystem.IsWindows() ? $"taskkill /T /F /PID {pid}" : $"kill {pid}";

    /// <summary>PIDs listening on a TCP port (lsof; /proc on Linux without lsof; GetExtendedTcpTable on Windows), empty if none or unreadable.</summary>
    public static List<int> ListeningPids(int port)
    {
        if (OperatingSystem.IsWindows())
        {
            return TcpListenerTable.ListeningPortsByPid().Where(e => e.Value.Contains(port)).Select(e => e.Key).Where(pid => pid > 0).ToList();
        }

        if (LinuxProc.UseProc)
        {
            return LinuxProc.ListeningPortsByPid().Where(e => e.Value.Contains(port)).Select(e => e.Key).ToList();
        }

        var output = Run("lsof", $"-nP -iTCP:{port} -sTCP:LISTEN -t");
        return output.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(s => int.TryParse(s.Trim(), out var pid) ? pid : 0)
            .Where(pid => pid > 0).Distinct().ToList();
    }

    private static string RunPs(string arguments) => Run("ps", arguments);

    /// <summary>Runs a tool (lsof, ps) and returns its stdout; empty when it fails.</summary>
    internal static string RunTool(string file, string arguments) => Run(file, arguments);

    private static string Run(string file, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            if (process == null)
            {
                return "";
            }

            var output = process.StandardOutput.ReadToEnd();
            process.WaitForExit(5000);
            return output;
        }
        catch (System.ComponentModel.Win32Exception)
        {
            return "";
        }
    }
}
