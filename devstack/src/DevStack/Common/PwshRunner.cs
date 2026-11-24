using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Meshmakers.Octo.DevStack.Common;

public sealed record PwshResult(int ExitCode, string Output, bool TimedOut, bool Canceled, bool IdleTimedOut = false);

/// <summary>How a pwsh (or any) process is run.</summary>
public sealed record PwshRunOptions
{
    /// <summary>stdout and stderr (interleaved) are appended to this file as well as captured.</summary>
    public string? LogFile { get; init; }

    public TimeSpan Timeout { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>Terminate when neither output nor <see cref="LastActivity"/> moved for this long.</summary>
    public TimeSpan? IdleTimeout { get; init; }

    /// <summary>
    ///     Activity outside stdout, e.g. the last write of a build events file. The argument is true when the value would
    ///     terminate the process: then read it without a cache (AB#9417).
    /// </summary>
    public Func<bool, DateTimeOffset?>? LastActivity { get; init; }

    /// <summary>Environment of the process on top of the daemon's; a null value removes a variable.</summary>
    public IReadOnlyDictionary<string, string?>? Environment { get; init; }

    public Action<int>? OnStarted { get; init; }
}

/// <summary>The seam builds and probes run pwsh through; tests replace it with canned output.</summary>
public interface IPwshRunner
{
    Task<PwshResult> RunAsync(string octoToolsPath, string body, PwshRunOptions options, CancellationToken cancellationToken);
}

/// <summary>Production runner: pwsh with the octo-tools profile.</summary>
public sealed class PwshProcessRunner : IPwshRunner
{
    public Task<PwshResult> RunAsync(string octoToolsPath, string body, PwshRunOptions options, CancellationToken cancellationToken) =>
        PwshRunner.RunAsync(octoToolsPath, body, options, cancellationToken);
}

/// <summary>Runs PowerShell with the octo-tools profile loaded.</summary>
public static class PwshRunner
{
    public const string Marker = "@@DEVSTACK@@";
    private const int MaxCapturedChars = 4 * 1024 * 1024;

    public static string BuildScript(string octoToolsPath, string body)
    {
        var profile = Path.Combine(octoToolsPath, "modules", "profile.ps1").Replace("'", "''");
        return $"""
                $ProgressPreference = 'SilentlyContinue'
                . '{profile}' *> $null
                $ErrorActionPreference = 'Stop'
                {body}
                """;
    }

    public static string Quote(string value) => "'" + value.Replace("'", "''") + "'";

    /// <summary>A PowerShell hashtable literal of string values.</summary>
    public static string Hashtable(IEnumerable<KeyValuePair<string, string>> values) =>
        "@{ " + string.Join("; ", values.Select(v => $"{Quote(v.Key)} = {Quote(v.Value)}")) + " }";

    /// <summary>Runs the script; stdout and stderr go (interleaved) to <paramref name="logFile"/> and are captured.</summary>
    public static Task<PwshResult> RunAsync(string octoToolsPath, string body, string? logFile, TimeSpan timeout,
        CancellationToken cancellationToken, Action<int>? onStarted = null) =>
        RunAsync(octoToolsPath, body, new PwshRunOptions { LogFile = logFile, Timeout = timeout, OnStarted = onStarted }, cancellationToken);

    public static Task<PwshResult> RunAsync(string octoToolsPath, string body, PwshRunOptions options, CancellationToken cancellationToken)
    {
        var psi = new ProcessStartInfo("pwsh") { WorkingDirectory = octoToolsPath };
        psi.ArgumentList.Add("-NoLogo");
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-Command");
        psi.ArgumentList.Add(BuildScript(octoToolsPath, body));
        return RunProcessAsync(psi, options, cancellationToken);
    }

    /// <summary>
    ///     Runs a process with captured output, an overall and an optional idle timeout; on cancellation or a timeout the
    ///     whole process tree is terminated.
    /// </summary>
    public static async Task<PwshResult> RunProcessAsync(ProcessStartInfo psi, PwshRunOptions options, CancellationToken cancellationToken)
    {
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.RedirectStandardInput = true;
        psi.UseShellExecute = false;
        foreach (var (key, value) in options.Environment ?? new Dictionary<string, string?>())
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

        using var process = new Process { StartInfo = psi };
        var captured = new StringBuilder();
        StreamWriter? log = null;
        if (options.LogFile != null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(options.LogFile)!);
            log = new StreamWriter(options.LogFile, append: true) { AutoFlush = true };
        }

        var sync = new Lock();
        var lastOutput = DateTimeOffset.Now;

        void OnLine(string? line)
        {
            if (line == null)
            {
                return;
            }

            lock (sync)
            {
                lastOutput = DateTimeOffset.Now;
                if (captured.Length < MaxCapturedChars)
                {
                    captured.AppendLine(line);
                }

                log?.WriteLine(line);
            }
        }

        process.OutputDataReceived += (_, e) => OnLine(e.Data);
        process.ErrorDataReceived += (_, e) => OnLine(e.Data);

        try
        {
            process.Start();
            process.StandardInput.Close();
            options.OnStarted?.Invoke(process.Id);
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();

            using var timeoutCts = new CancellationTokenSource(options.Timeout);
            using var idleCts = new CancellationTokenSource();
            using var watchCts = new CancellationTokenSource();
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutCts.Token, idleCts.Token);
            Task? idleWatch = null;
            if (options.IdleTimeout is { } idle)
            {
                var check = TimeSpan.FromMilliseconds(Math.Clamp(idle.TotalMilliseconds / 4, 50, 30_000));
                idleWatch = WatchIdleAsync(idle, check, () =>
                {
                    lock (sync)
                    {
                        return lastOutput;
                    }
                }, options.LastActivity, idleCts, watchCts.Token);
            }

            try
            {
                await process.WaitForExitAsync(linked.Token);
            }
            catch (OperationCanceledException)
            {
                await ProcessTree.TerminateAsync(process.Id, TimeSpan.FromSeconds(10), CancellationToken.None);
                await process.WaitForExitAsync(CancellationToken.None);
                var canceled = cancellationToken.IsCancellationRequested;
                lock (sync)
                {
                    return new PwshResult(-1, captured.ToString(), timeoutCts.IsCancellationRequested && !canceled, canceled,
                        idleCts.IsCancellationRequested && !canceled && !timeoutCts.IsCancellationRequested);
                }
            }
            finally
            {
                await watchCts.CancelAsync();
                if (idleWatch != null)
                {
                    await idleWatch;
                }
            }

            // Drain the asynchronous readers.
            process.WaitForExit();
            lock (sync)
            {
                return new PwshResult(process.ExitCode, captured.ToString(), false, false);
            }
        }
        finally
        {
            log?.Dispose();
        }
    }

    /// <summary>Cancels <paramref name="idle"/>'s source when neither output nor the extra activity moved for the idle time.</summary>
    private static async Task WatchIdleAsync(TimeSpan idleTimeout, TimeSpan check, Func<DateTimeOffset> lastOutput, Func<bool, DateTimeOffset?>? lastActivity,
        CancellationTokenSource idle, CancellationToken stop)
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                await Task.Delay(check, stop);
                var last = lastOutput();
                var other = lastActivity?.Invoke(false);
                if (other > last)
                {
                    last = other.Value;
                }

                if (DateTimeOffset.Now - last > idleTimeout && lastActivity != null)
                {
                    var fresh = lastActivity(true);
                    // Output that arrived while the fresh read ran counts as well.
                    var output = lastOutput();
                    last = new[] { last, fresh ?? last, output }.Max();
                }

                if (DateTimeOffset.Now - last > idleTimeout)
                {
                    await idle.CancelAsync();
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // The process ended.
        }
    }

    /// <summary>The JSON after the last marker line (written by the provider wrapper).</summary>
    public static JsonNode? ExtractMarker(string output)
    {
        var line = output.Split('\n').LastOrDefault(l => l.StartsWith(Marker, StringComparison.Ordinal));
        return line == null ? null : JsonNode.Parse(line[Marker.Length..].Trim());
    }

    /// <summary>
    ///     The last octo-tools -Json document ({ "schemaVersion": ..., "command": ..., "data": ... }) in mixed output: the
    ///     cmdlets print ConvertTo-Json multi-line, dotnet build output may come before it. With <paramref name="command"/> only a
    ///     document of that cmdlet counts (a nested cmdlet's -Json output must not pass for the result).
    /// </summary>
    public static JsonObject? ExtractOctoJson(string output, string? command = null)
    {
        var lines = output.Replace("\r", "").Split('\n');
        for (var start = lines.Length - 1; start >= 0; start--)
        {
            if (lines[start].TrimEnd() != "{" && !lines[start].StartsWith("{\"schemaVersion\"", StringComparison.Ordinal))
            {
                continue;
            }

            var bytes = Encoding.UTF8.GetBytes(string.Join('\n', lines[start..]));
            try
            {
                // Read exactly one JSON value, so output printed after the document does not break parsing.
                var reader = new Utf8JsonReader(bytes);
                if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
                {
                    continue;
                }

                reader.Skip();
                var length = (int)reader.BytesConsumed;
                if (JsonNode.Parse(bytes.AsSpan(0, length)) is JsonObject obj && obj.ContainsKey("schemaVersion") &&
                    (command == null || (obj["command"] is JsonValue c && c.GetValueKind() == JsonValueKind.String &&
                                         string.Equals(c.GetValue<string>(), command, StringComparison.OrdinalIgnoreCase))))
                {
                    return obj;
                }
            }
            catch (JsonException)
            {
                // Not a complete document from here; try an earlier start.
            }
        }

        return null;
    }

    /// <summary>Last lines of a text, for error reports.</summary>
    public static string Tail(string text, int lines)
    {
        var all = text.Replace("\r", "").TrimEnd('\n').Split('\n');
        return string.Join('\n', all.Skip(Math.Max(0, all.Length - lines)));
    }
}
