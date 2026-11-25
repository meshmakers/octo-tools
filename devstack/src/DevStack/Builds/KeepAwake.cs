using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     AB#9808: keeps a Mac awake while a job runs - a test run or build that sleeps with the lid open loses its containers and
///     its watchdog's clock. <c>caffeinate -i -w &lt;pid&gt;</c> prevents idle sleep until the job's process ends, and ends with it
///     (also when the daemon restarts in between: it then belongs to launchd and still ends with the job). Elsewhere a no-op.
/// </summary>
internal static class KeepAwake
{
    internal const string Caffeinate = "/usr/bin/caffeinate";

    /// <summary>The arguments: prevent idle sleep (-i) until the process <paramref name="pid"/> exits (-w).</summary>
    internal static IReadOnlyList<string> Arguments(int pid) => ["-i", "-w", pid.ToString(CultureInfo.InvariantCulture)];

    /// <summary>
    ///     Starts caffeinate for the job process <paramref name="pid"/>; returns it, or null on another OS, without caffeinate,
    ///     or when it cannot start (a job never fails for it).
    /// </summary>
    internal static Process? While(int pid, bool? isMacOs = null, string program = Caffeinate)
    {
        if (!(isMacOs ?? OperatingSystem.IsMacOS()) || !File.Exists(program))
        {
            return null;
        }

        try
        {
            var psi = new ProcessStartInfo(program) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var argument in Arguments(pid))
            {
                psi.ArgumentList.Add(argument);
            }

            return Process.Start(psi);
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or IOException)
        {
            return null;
        }
    }
}
