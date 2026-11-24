using System.Diagnostics;
using System.Runtime.Versioning;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>Starts a service process whose output goes straight into its log file.</summary>
public static class ProcessLauncher
{
    // macOS/Linux: /bin/sh replaces itself with the service (exec), so the PID we get is the service's PID, and the output
    // is redirected by the shell instead of through a pipe to the daemon: the service keeps logging when the daemon
    // restarts. Command and arguments are passed positionally ($0 "$@"), no quoting involved. Windows: see WindowsStartInfo.
    internal const string ShellScript = "log=\"$DEVSTACK_LOG\"; unset DEVSTACK_LOG; exec \"$0\" \"$@\" </dev/null >>\"$log\" 2>&1";

    public static Process Start(ServicePlan plan)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(plan.LogFile)!);
        RotateLog(plan.LogFile);
        File.AppendAllText(plan.LogFile, HeaderLine(plan, DateTimeOffset.Now));

        var psi = OperatingSystem.IsWindows() ? WindowsStartInfo(plan) : UnixStartInfo(plan);
        ApplyEnvironment(psi, plan);
        return Process.Start(psi) ?? throw new InvalidOperationException($"Could not start {plan.Name}.");
    }

    /// <summary>The first line the daemon writes into a service's log before it starts it.</summary>
    /// <remarks>Arguments with spaces, tabs or quotes are quoted (CommandLineToArgvW style), so the line is unambiguous.</remarks>
    internal static string HeaderLine(ServicePlan plan, DateTimeOffset now) =>
        $"# octo-devstack {now:yyyy-MM-dd HH:mm:ss zzz}: {HeaderArg(plan.Command)} {string.Join(' ', plan.Args.Select(HeaderArg))} (in {plan.WorkingDirectory})\n";

    /// <summary>One program or argument as the header line shows it (internal: the tests build expected headers with it).</summary>
    internal static string HeaderArg(string arg) => arg.Length > 0 && arg.IndexOfAny([' ', '\t', '"']) < 0 ? arg : WindowsCommandLine.Quote(arg);

    private static ProcessStartInfo UnixStartInfo(ServicePlan plan)
    {
        var psi = new ProcessStartInfo("/bin/sh")
        {
            UseShellExecute = false,
            WorkingDirectory = plan.WorkingDirectory
        };
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add(ShellScript);
        psi.ArgumentList.Add(plan.Command);
        foreach (var arg in plan.Args)
        {
            psi.ArgumentList.Add(arg);
        }

        psi.Environment["DEVSTACK_LOG"] = plan.LogFile;
        return psi;
    }

    /// <summary>
    ///     Windows: cmd.exe runs the service with its output appended to the log file (<see cref="WindowsCommandLine.CmdWrapperArguments"/>),
    ///     so the log does not depend on the daemon, and exits with the service's exit code. The PID the daemon tracks is
    ///     cmd.exe's; the service is its child. Its own hidden console (CreateNoWindow) and process group
    ///     (CreateNewProcessGroup) let <see cref="ConsoleSignal"/> stop exactly this tree with CTRL_BREAK.
    /// </summary>
    [SupportedOSPlatform("windows")]
    internal static ProcessStartInfo WindowsStartInfo(ServicePlan plan)
    {
        var cmd = Path.Combine(Environment.SystemDirectory is { Length: > 0 } system ? system : @"C:\Windows\System32", "cmd.exe");
        return new ProcessStartInfo(cmd, WindowsCommandLine.CmdWrapperArguments(plan.Command, plan.Args, plan.LogFile))
        {
            UseShellExecute = false,
            WorkingDirectory = plan.WorkingDirectory,
            CreateNoWindow = true,
            CreateNewProcessGroup = true
        };
    }

    private static void ApplyEnvironment(ProcessStartInfo psi, ServicePlan plan)
    {
        foreach (var (key, value) in plan.Env)
        {
            if (value == null)
            {
                psi.Environment.Remove(key);
            }
            else
            {
                psi.Environment[key] = value;
            }
        }
    }

    /// <summary>Keeps the previous run's log as &lt;name&gt;.prev.log (Start-Octo deletes it).</summary>
    private static void RotateLog(string logFile)
    {
        if (File.Exists(logFile))
        {
            var previous = Path.ChangeExtension(logFile, ".prev.log");
            File.Move(logFile, previous, overwrite: true);
        }
    }
}
