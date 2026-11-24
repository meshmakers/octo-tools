using System.Diagnostics;
using System.Globalization;
using System.Runtime.Versioning;
using System.Text;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>What a build step needs to run without the daemon: its script, where its output goes and where its exit code is left.</summary>
public sealed record BuildLaunch(string OctoToolsPath, string Body, string LogFile, string ExitFile, IReadOnlyDictionary<string, string?> Environment);

/// <summary>A started build step. <see cref="Process"/> is the daemon's own handle (null for a step adopted after a restart).</summary>
public sealed record LaunchedBuild(int Pid, DateTimeOffset? ProcessStart, Process? Process);

/// <summary>The seam build steps are started through; null in the queue means "run attached through <see cref="IPwshRunner"/>" (tests).</summary>
public interface IBuildLauncher
{
    LaunchedBuild Start(BuildLaunch launch);
}

/// <summary>
///     Starts a build step detached from the daemon, so it survives a daemon restart and its result is recoverable without
///     the parent: a wrapper runs the program with its output appended to the job log (no pipe to the daemon) and leaves
///     the exit code in the step's exit marker when it ends: <c>/bin/sh</c> on macOS/Linux, <c>cmd.exe</c> on Windows. On
///     both the marker is written under a temporary name and moved into place, so a reader never sees half a file.
/// </summary>
public sealed class DetachedBuildLauncher(Func<BuildLaunch, (string Program, IReadOnlyList<string> Arguments)>? command = null) : IBuildLauncher
{
    /// <summary>$0 of the wrapper shell: names the process in ps.</summary>
    public const string WrapperName = "octo-devstack-build";

    // $1 = log, $2 = exit marker, the rest = program and arguments (positional, no quoting involved). The marker is
    // written to a temporary name first, so a reader never sees a half-written file.
    internal const string UnixWrapper =
        "log=\"$1\"; marker=\"$2\"; shift 2; \"$@\" </dev/null >>\"$log\" 2>&1; code=$?; " +
        "printf '%s\\n' \"$code\" >\"$marker.tmp\" && mv -f \"$marker.tmp\" \"$marker\"; exit \"$code\"";

    private readonly Func<BuildLaunch, (string Program, IReadOnlyList<string> Arguments)> _command = command ?? Pwsh;

    public LaunchedBuild Start(BuildLaunch launch)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(launch.LogFile)!);
        File.Delete(launch.ExitFile);
        var (program, arguments) = _command(launch);
        var psi = OperatingSystem.IsWindows() ? WindowsStartInfo(program, arguments, launch) : UnixStartInfo(program, arguments, launch);
        psi.UseShellExecute = false;
        psi.WorkingDirectory = Directory.Exists(launch.OctoToolsPath) ? launch.OctoToolsPath : Path.GetDirectoryName(launch.LogFile)!;
        foreach (var (key, value) in launch.Environment)
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

        var process = Process.Start(psi) ?? throw new InvalidOperationException("Could not start the build process.");
        return new LaunchedBuild(process.Id, ProcessTree.StartTime(process), process);
    }

    /// <summary>pwsh with the octo-tools profile, as <see cref="PwshRunner"/> runs it.</summary>
    private static (string Program, IReadOnlyList<string> Arguments) Pwsh(BuildLaunch launch) =>
        OperatingSystem.IsWindows()
            ? WindowsPwsh(launch)
            : ("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", PwshRunner.BuildScript(launch.OctoToolsPath, launch.Body)]);

    /// <summary>
    ///     Windows: the script goes into a file next to the step's exit marker (<c>&lt;id&gt;.&lt;step&gt;.ps1</c>) and pwsh runs it
    ///     with -File. The cmd.exe wrapper's command line ends at a line break, and the script has several lines (profile,
    ///     settings, the cmdlet); a file also has no 8191-character limit and stays to be looked at (AB#9377: found by the
    ///     first real environment build on Windows). -File exits with the same codes as -Command.
    /// </summary>
    internal static (string Program, IReadOnlyList<string> Arguments) WindowsPwsh(BuildLaunch launch)
    {
        var script = ScriptFile(launch.ExitFile);
        File.WriteAllText(script, Utf8Console + PwshRunner.BuildScript(launch.OctoToolsPath, launch.Body));
        return ("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script]);
    }

    /// <summary>
    ///     First lines of a Windows step script: the step's own hidden console has the OEM code page, so pwsh and every program
    ///     it starts in that console (dotnet, node, npm) wrote non-ASCII output - umlauts, the box frame of a failing npm
    ///     script - in it, and the job log is read as UTF-8 (AB#9464). Setting the console's output encoding switches its
    ///     code page for all of them. macOS/Linux write UTF-8 anyway.
    /// </summary>
    internal const string Utf8Console = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\n$OutputEncoding = [Console]::OutputEncoding\n";

    /// <summary>The script file of a step on Windows: its exit marker with .ps1 instead of .exit.</summary>
    internal static string ScriptFile(string exitFile) => Path.ChangeExtension(exitFile, ".ps1");

    private static ProcessStartInfo UnixStartInfo(string program, IReadOnlyList<string> arguments, BuildLaunch launch)
    {
        var psi = new ProcessStartInfo("/bin/sh");
        foreach (var arg in (string[])["-c", UnixWrapper, WrapperName, launch.LogFile, launch.ExitFile, program, ..arguments])
        {
            psi.ArgumentList.Add(arg);
        }

        return psi;
    }

    [SupportedOSPlatform("windows")]
    private static ProcessStartInfo WindowsStartInfo(string program, IReadOnlyList<string> arguments, BuildLaunch launch)
    {
        var cmd = Path.Combine(Environment.SystemDirectory is { Length: > 0 } system ? system : @"C:\Windows\System32", "cmd.exe");
        return new ProcessStartInfo(cmd, WindowsWrapperArguments(program, arguments, launch.LogFile, launch.ExitFile))
        {
            CreateNoWindow = true,
            CreateNewProcessGroup = true
        };
    }

    /// <summary>
    ///     The cmd.exe arguments of a detached build step: the service wrapper (<see cref="WindowsCommandLine.CmdWrapperArguments"/>)
    ///     followed by <c>&amp; call echo %^ERRORLEVEL%&gt;"marker.tmp" &amp; move /y "marker.tmp" "marker"</c>. The script's
    ///     text is not expanded (/v:off, its percent signs are escaped); only the wrapper's own <c>%^ERRORLEVEL%</c> is:
    ///     the parse of the whole line leaves it alone (no variable is named <c>^ERRORLEVEL</c>) and drops the caret, and
    ///     <c>call</c> expands the result when the echo runs - after the program ended, so it is the program's exit code.
    /// </summary>
    internal static string WindowsWrapperArguments(string program, IReadOnlyList<string> arguments, string logFile, string exitFile)
    {
        if (exitFile.Contains('"') || exitFile.Contains('%'))
        {
            throw new InvalidOperationException($"The exit marker path '{exitFile}' must not contain quotes or percent signs (cmd.exe redirection).");
        }

        var service = WindowsCommandLine.CmdWrapperArguments(program, arguments, logFile);
        // CmdWrapperArguments ends with the quote that closes /c "..."; the marker commands go inside it.
        return $"{service[..^1]} & call echo %^ERRORLEVEL%>\"{exitFile}.tmp\" & move /y \"{exitFile}.tmp\" \"{exitFile}\" >NUL\"";
    }
}

/// <summary>Files a detached build step leaves: the exit marker and the part of the job log it wrote.</summary>
internal static class BuildStepFiles
{
    private const int MaxOutputBytes = 4 * 1024 * 1024;

    /// <summary>The exit code in a step's marker; null while there is none (the step runs, or it was killed).</summary>
    public static int? ReadExit(string exitFile)
    {
        try
        {
            if (!File.Exists(exitFile))
            {
                return null;
            }

            return int.TryParse(Common.SharedFile.ReadAllText(exitFile).Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var code) ? code : null;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public static long Length(string file)
    {
        try
        {
            return File.Exists(file) ? new FileInfo(file).Length : 0;
        }
        catch (IOException)
        {
            return 0;
        }
    }

    /// <summary>The log from <paramref name="offset"/> on (what this step wrote), at most its last 4 MB.</summary>
    public static string ReadFrom(string file, long offset)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var start = Math.Clamp(offset, 0, stream.Length);
            if (stream.Length - start > MaxOutputBytes)
            {
                start = stream.Length - MaxOutputBytes;
            }

            stream.Position = start;
            using var reader = new StreamReader(stream, Encoding.UTF8);
            return reader.ReadToEnd();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "";
        }
    }

    /// <summary>The last write of a file; null when it does not exist.</summary>
    public static DateTimeOffset? LastWrite(string file)
    {
        try
        {
            return File.Exists(file) ? new DateTimeOffset(File.GetLastWriteTime(file)) : null;
        }
        catch (IOException)
        {
            return null;
        }
    }
}
