using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     What Docker has to work with (docker info): memory and CPUs of its VM (Docker Desktop, colima; the host itself on
///     Linux), whether the kind cluster runs in it, and a warning when test projects that start containers would share a
///     small VM with kind.
/// </summary>
public sealed record DockerVmInfo(
    bool Available,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? MemoryGb,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    int? Cpus,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? OperatingSystem,
    bool Kind,
    double MinMemoryGb,
    int MinCpus,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Warning,
    DateTimeOffset CheckedAt);

/// <summary>Reads the Docker VM size with the docker CLI (read-only: docker info, docker ps); the answer is kept for a minute.</summary>
public sealed class DockerVm(ConfigStore store, Func<string, (int ExitCode, string Output)>? docker = null, Func<DateTimeOffset>? clock = null)
{
    private static readonly TimeSpan MaxAge = TimeSpan.FromSeconds(60);
    private readonly Lock _lock = new();
    private DockerVmInfo? _last;

    public DockerVmInfo Current()
    {
        lock (_lock)
        {
            var now = (clock ?? (() => DateTimeOffset.Now))();
            if (_last == null || now - _last.CheckedAt > MaxAge)
            {
                var limits = store.Load().DockerVm;
                _last = Probe(docker ?? Run, limits.MinMemoryGb, limits.MinCpus, now);
            }

            return _last;
        }
    }

    /// <summary>The warning for a test run that starts containers; null when the VM is large enough, kind does not run or Docker does not answer.</summary>
    public string? Warning() => Current().Warning;

    internal static DockerVmInfo Probe(Func<string, (int ExitCode, string Output)> docker, double minMemoryGb, int minCpus, DateTimeOffset now)
    {
        long? memory = null;
        int? cpus = null;
        string? os = null;
        try
        {
            var (exit, output) = docker("info --format \"{{json .}}\"");
            var line = output.Split('\n').FirstOrDefault(l => l.TrimStart().StartsWith('{'));
            if (exit != 0 || line == null)
            {
                return new DockerVmInfo(false, null, null, null, false, minMemoryGb, minCpus, null, now);
            }

            using var json = JsonDocument.Parse(line);
            var root = json.RootElement;
            memory = root.TryGetProperty("MemTotal", out var m) && m.TryGetInt64(out var bytes) && bytes > 0 ? bytes : null;
            cpus = root.TryGetProperty("NCPU", out var c) && c.TryGetInt32(out var n) && n > 0 ? n : null;
            os = root.TryGetProperty("OperatingSystem", out var o) ? o.GetString() : null;
            if (memory == null && cpus == null)
            {
                // The client answered, the server did not (ServerErrors): Docker is not running.
                return new DockerVmInfo(false, null, null, os, false, minMemoryGb, minCpus, null, now);
            }
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            return new DockerVmInfo(false, null, null, null, false, minMemoryGb, minCpus, null, now);
        }

        var kind = false;
        try
        {
            var (exit, output) = docker("ps --format \"{{.Image}}\"");
            kind = exit == 0 && output.Split('\n').Any(l => l.Trim().StartsWith("kindest/node", StringComparison.OrdinalIgnoreCase));
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            // Unknown: no warning.
        }

        var gb = memory == null ? (double?)null : Math.Round(memory.Value / 1024d / 1024d / 1024d, 1);
        return new DockerVmInfo(true, gb, cpus, os, kind, minMemoryGb, minCpus, WarningOf(gb, cpus, kind, minMemoryGb, minCpus), now);
    }

    /// <summary>The rule (pure): kind runs in the VM and it has less memory or fewer CPUs than the limits.</summary>
    internal static string? WarningOf(double? memoryGb, int? cpus, bool kind, double minMemoryGb, int minCpus)
    {
        var small = new List<string>();
        if (memoryGb < minMemoryGb)
        {
            small.Add(string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{memoryGb:0.#} GiB memory (below {minMemoryGb:0.#})"));
        }

        if (cpus < minCpus)
        {
            small.Add($"{cpus} CPUs (below {minCpus})");
        }

        return !kind || small.Count == 0
            ? null
            : $"The Docker VM has {string.Join(" and ", small)} and the kind cluster runs in it: test projects that start containers (docker) may fail there for lack " +
              "of resources (Docker Desktop: Settings > Resources); the test run checks the free memory itself before it starts them.";
    }

    private static (int ExitCode, string Output) Run(string arguments)
    {
        using var process = Process.Start(new ProcessStartInfo("docker", arguments)
        {
            RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true
        }) ?? throw new InvalidOperationException("docker did not start.");
        var output = process.StandardOutput.ReadToEndAsync();
        _ = process.StandardError.ReadToEndAsync();
        if (!process.WaitForExit(5000))
        {
            process.Kill(entireProcessTree: true);
            return (-1, "");
        }

        return (process.ExitCode, output.GetAwaiter().GetResult());
    }
}
