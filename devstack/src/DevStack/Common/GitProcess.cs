using System.Diagnostics;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     git as a process (the daemon has no git library): <c>git --no-optional-locks -C &lt;folder&gt; &lt;arguments&gt;</c> without
///     a terminal prompt and without the variables a git hook (or tests run from one) would pass on to point it at another
///     repository. --no-optional-locks: the daemon never takes the index lock a session's own git needs.
/// </summary>
internal static class GitProcess
{
    // A git started by a git hook (or by tests run from one) inherits these and would read another repository.
    private static readonly string[] LocationVariables = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR", "GIT_NAMESPACE"];

    /// <summary>Runs git in <paramref name="folder"/>; throws <see cref="TimeoutException"/> after <paramref name="timeout"/> (the process is killed).</summary>
    public static async Task<(int ExitCode, string Output, string Error)> RunAsync(string folder, IReadOnlyList<string> arguments, TimeSpan timeout)
    {
        var start = new ProcessStartInfo("git")
        {
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, UseShellExecute = false, CreateNoWindow = true,
            // git writes paths as UTF-8 (core.quotePath=false), whatever the console code page of Windows says.
            StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8
        };
        foreach (var argument in new[] { "--no-optional-locks", "-C", folder }.Concat(arguments))
        {
            start.ArgumentList.Add(argument);
        }

        foreach (var variable in LocationVariables)
        {
            start.Environment.Remove(variable);
        }

        start.Environment["GIT_TERMINAL_PROMPT"] = "0";
        using var process = Process.Start(start) ?? throw new InvalidOperationException("git did not start.");
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        using var limit = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(limit.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // Ended meanwhile.
            }

            throw new TimeoutException($"git {arguments.FirstOrDefault()} took longer than {timeout.TotalSeconds:0} s");
        }

        return (process.ExitCode, await output, await error);
    }

    /// <summary>The first non-empty line of git's output, for a message.</summary>
    public static string FirstLine(string text) =>
        text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0) ?? "no message";
}
