using System.Diagnostics;
using System.Runtime.Versioning;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Graceful stop on Windows: a CTRL_BREAK_EVENT to the process group of a service. Services are launched with their own
///     hidden console (CreateNoWindow) and as the leader of a new process group (CreateNewProcessGroup), see
///     <c>ProcessLauncher</c>. GenerateConsoleCtrlEvent only reaches processes on the caller's console, and a process has
///     at most one console, so the daemon does not attach itself (it would lose its own console and could signal itself):
///     it starts itself once more as a short-lived helper (<see cref="HelperSwitch"/>) that frees its console, attaches to
///     the service's console, refuses if the daemon shares that console, and sends the event to the service's group.
///     .NET hosts (ConsoleLifetime) treat CTRL_BREAK like SIGQUIT/SIGTERM and shut down gracefully.
/// </summary>
public static class ConsoleSignal
{
    public const string HelperSwitch = "--send-ctrl-break";

    /// <summary>Helper exit codes.</summary>
    internal const int Sent = 0;
    internal const int BadArguments = 1;
    internal const int AttachFailed = 2;
    internal const int SharesGuardConsole = 3;
    internal const int GenerateFailed = 4;
    internal const int ConsoleNotOwn = 5;

    /// <summary>
    ///     Fourth helper argument: signal every process of the target's console instead of the target's process group. For a
    ///     process that has a console of its own but leads no process group - the daemon started by Start-OctoDevStackDaemon
    ///     (Start-OctoDevStackDetachedWindows: CreateProcessW, hidden console of its own, AB#9922) -, so
    ///     Stop-OctoDevStackDaemon can stop it gracefully on Windows (AB#9377).
    /// </summary>
    public const string ConsoleMode = "console";

    // Kept in a field: the native side calls it after SetConsoleCtrlHandler returned.
    private static WindowsNative.ConsoleCtrlHandler? _ignore;

    /// <summary>The program and arguments that run the helper: the daemon's apphost, or dotnet with the daemon's dll.</summary>
    internal static (string File, List<string> Args) HelperCommand(string processPath, string assemblyPath, int targetPid, int guardPid)
    {
        var args = new List<string>();
        var name = processPath[(processPath.LastIndexOfAny(['\\', '/']) + 1)..];
        if (name.Equals("dotnet", StringComparison.OrdinalIgnoreCase) || name.Equals("dotnet.exe", StringComparison.OrdinalIgnoreCase))
        {
            args.Add(assemblyPath);
        }

        args.AddRange([HelperSwitch, targetPid.ToString(System.Globalization.CultureInfo.InvariantCulture),
            guardPid.ToString(System.Globalization.CultureInfo.InvariantCulture)]);
        return (processPath, args);
    }

    /// <summary>Sends CTRL_BREAK to the process group led by <paramref name="pid"/> through the helper; true if it was sent.</summary>
    [SupportedOSPlatform("windows")]
    public static async Task<bool> SendCtrlBreakAsync(int pid)
    {
        var processPath = Environment.ProcessPath;
        if (processPath == null)
        {
            return false;
        }

        var (file, args) = HelperCommand(processPath, typeof(ConsoleSignal).Assembly.Location, pid, Environment.ProcessId);
        var psi = new ProcessStartInfo(file)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var arg in args)
        {
            psi.ArgumentList.Add(arg);
        }

        try
        {
            using var helper = Process.Start(psi);
            if (helper == null)
            {
                return false;
            }

            _ = helper.StandardOutput.ReadToEndAsync();
            _ = helper.StandardError.ReadToEndAsync();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await helper.WaitForExitAsync(timeout.Token);
            return helper.ExitCode == Sent;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or OperationCanceledException or InvalidOperationException)
        {
            return false;
        }
    }

    /// <summary>
    ///     True when the target is alone on its console: every process there apart from the helper is the target. Only then may
    ///     the event go to the whole console - a console shared with a shell (a daemon in the foreground of a terminal) would
    ///     hand it to the shell too.
    /// </summary>
    internal static bool AloneOnConsole(IEnumerable<uint> consoleProcesses, uint target, uint helper) =>
        consoleProcesses.Where(p => p != helper).All(p => p == target);

    /// <summary>The helper mode of the daemon executable: <c>--send-ctrl-break &lt;pid&gt; &lt;guardPid&gt; [console]</c>.</summary>
    [SupportedOSPlatform("windows")]
    public static int RunHelper(IReadOnlyList<string> args)
    {
        if (args.Count < 3 || !uint.TryParse(args[1], out var target) || !uint.TryParse(args[2], out var guard) || target == 0)
        {
            return BadArguments;
        }

        WindowsNative.FreeConsole();
        if (!WindowsNative.AttachConsole(target))
        {
            return AttachFailed;
        }

        try
        {
            var list = new uint[256];
            var count = WindowsNative.GetConsoleProcessList(list, (uint)list.Length);
            var attached = list.Take((int)Math.Min(count, (uint)list.Length)).ToList();
            if (attached.Contains(guard))
            {
                // The daemon is on this console: the event would reach it (and every other process there).
                return SharesGuardConsole;
            }

            var wholeConsole = args.Count > 3 && args[3] == ConsoleMode;
            if (wholeConsole && !AloneOnConsole(attached, target, (uint)Environment.ProcessId))
            {
                return ConsoleNotOwn;
            }

            // The helper is not in the target group, but stays alive whatever reaches it.
            _ignore = _ => true;
            WindowsNative.SetConsoleCtrlHandler(_ignore, true);
            // Group 0: every process attached to the console - here only the target, and the helper itself.
            if (!WindowsNative.GenerateConsoleCtrlEvent(WindowsNative.CtrlBreakEvent, wholeConsole ? 0 : target))
            {
                return GenerateFailed;
            }

            if (wholeConsole)
            {
                // The event reaches the helper too, on a thread of its own and a moment later: wait for it while the handler
                // that ignores it is still installed, else it lands during shutdown and ends the helper as "Ctrl-C exit".
                Thread.Sleep(500);
            }

            return Sent;
        }
        finally
        {
            WindowsNative.FreeConsole();
        }
    }
}
