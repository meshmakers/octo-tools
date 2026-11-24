using System.Diagnostics;
using System.Text.Json;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     Harmless test processes: pwsh (-NoProfile) on every OS (AB#9377). The daemon needs pwsh anyway, so one script serves
///     macOS, Linux and Windows - no /bin/sh or /bin/sleep fixture with a translation for one OS. Only what really differs
///     per OS (the launcher's wrapper, signals, Unix file modes) is tested per OS. Service yaml names pwsh directly:
///     <c>command: pwsh</c>, <c>args: ["-NoProfile", "-NonInteractive", "-Command", "Start-Sleep 30"]</c>.
/// </summary>
internal static class TestProcess
{
    public const string Pwsh = "pwsh";

    public static bool Windows => OperatingSystem.IsWindows();

    public static string[] PwshArgs(string command) => ["-NoProfile", "-NonInteractive", "-Command", command];

    /// <summary>
    ///     The yaml <c>args</c> (a flow list) of a pwsh service. Extra arguments follow the script after a '#': -Command joins
    ///     them into the command, so they stay a comment, but they remain in the process's command line, which is what the
    ///     tests look at (masking, tenant arguments).
    /// </summary>
    public static string ShellArgs(string script, params string[] extra) =>
        Json([.. PwshArgs(extra.Length > 0 ? script + " #" : script), .. extra]);

    /// <summary>The program of a sleeping service as its log header shows it (arguments quoted like the header quotes them).</summary>
    public static string SleepCommand(int seconds) =>
        Pwsh + " " + string.Join(' ', PwshArgs($"Start-Sleep {seconds}").Select(ProcessLauncher.HeaderArg));

    /// <summary>A service log, read while the service may still write it (Windows locks without FileShare.ReadWrite).</summary>
    public static string ReadLog(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public static ProcessStartInfo SleepStartInfo(int seconds) => Script($"Start-Sleep {seconds}");

    public static Process StartSleep(int seconds) => Process.Start(SleepStartInfo(seconds))!;

    /// <summary>A pwsh script as a process to start.</summary>
    public static ProcessStartInfo Script(string script)
    {
        // CreateNoWindow: on Windows a test host without a console would open a visible window for every test process.
        var psi = new ProcessStartInfo(Pwsh) { UseShellExecute = false, CreateNoWindow = true };
        foreach (var arg in PwshArgs(script))
        {
            psi.ArgumentList.Add(arg);
        }

        return psi;
    }

    /// <summary>The program and arguments of a pwsh script (e.g. for a build launcher).</summary>
    public static (string Program, IReadOnlyList<string> Arguments) PwshCommand(string script) => (Pwsh, PwshArgs(script));

    /// <summary>A PowerShell single-quoted literal of <paramref name="value"/> (one line).</summary>
    public static string PwshLiteral(string value) => "'" + value.Replace("'", "''") + "'";

    /// <summary>
    ///     A script that does not end on the graceful stop: SIGTERM (macOS/Linux) and CTRL_BREAK (Windows, SIGQUIT to .NET)
    ///     are cancelled through PosixSignalRegistration, then it runs until it is killed. Compiling the handler takes a second
    ///     or two: the script writes <paramref name="readyFile"/> when it is in place, and a test waits for that file before
    ///     it stops the service.
    /// </summary>
    public static string StubbornScript(string readyFile) =>
        "Add-Type -TypeDefinition 'public static class StubbornTestProcess { static object[] keep; public static void IgnoreStop() { keep = new object[] { " +
        "System.Runtime.InteropServices.PosixSignalRegistration.Create(System.Runtime.InteropServices.PosixSignal.SIGTERM, c => c.Cancel = true), " +
        "System.Runtime.InteropServices.PosixSignalRegistration.Create(System.Runtime.InteropServices.PosixSignal.SIGQUIT, c => c.Cancel = true) }; } }'; " +
        $"[StubbornTestProcess]::IgnoreStop(); Set-Content -LiteralPath {PwshLiteral(readyFile)} -Value ready; " +
        "while ($true) { Start-Sleep -Milliseconds 200 }";

    private static string Json(IEnumerable<string> values) => "[" + string.Join(", ", values.Select(v => JsonSerializer.Serialize(v))) + "]";
}
