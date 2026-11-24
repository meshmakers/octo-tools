using System.Text.Json;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     Durations of successful repository builds per lane, repo and configuration (the last five), persisted in the state
///     folder; the ETA of a running job is computed from them.
/// </summary>
public sealed class BuildHistory
{
    private const int Keep = 5;
    private readonly string _file;
    private readonly Lock _lock = new();
    private Dictionary<string, List<double>> _entries;

    public BuildHistory(DevStackPaths paths)
    {
        _file = Path.Combine(paths.StateDirectory, "build-history.json");
        _entries = Load(_file);
    }

    private static string Key(string lane, string repo, string configuration) =>
        $"{PathScope.Normalize(lane).TrimEnd(Path.DirectorySeparatorChar)}|{repo.ToLowerInvariant()}|{configuration}";

    public void Record(string lane, string repo, string configuration, double seconds)
    {
        if (seconds <= 0 || double.IsNaN(seconds))
        {
            return;
        }

        lock (_lock)
        {
            var key = Key(lane, repo, configuration);
            if (!_entries.TryGetValue(key, out var list))
            {
                _entries[key] = list = [];
            }

            list.Add(Math.Round(seconds, 1));
            if (list.Count > Keep)
            {
                list.RemoveRange(0, list.Count - Keep);
            }

            try
            {
                var temp = _file + ".tmp";
                File.WriteAllText(temp, JsonSerializer.Serialize(_entries));
                Common.SharedFile.Replace(temp, _file);
            }
            catch (IOException)
            {
                // History is a nice-to-have; an unwritable state folder must not fail a build.
            }
        }
    }

    /// <summary>Average of the recorded durations, null when the repo was never built here.</summary>
    public double? Estimate(string lane, string repo, string configuration)
    {
        lock (_lock)
        {
            return _entries.TryGetValue(Key(lane, repo, configuration), out var list) && list.Count > 0 ? list.Average() : null;
        }
    }

    /// <summary>
    ///     Seconds left: the estimate of every pending repo plus what the current one still needs. Repos without history count
    ///     with the median of the known ones; null when nothing is known.
    /// </summary>
    public double? Eta(string configuration, IReadOnlyList<(string Lane, string Repo)> pending, (string Lane, string Repo)? current, double currentSeconds)
    {
        var estimates = pending.Select(r => Estimate(r.Lane, r.Repo, configuration)).ToList();
        var currentEstimate = current is { } c ? Estimate(c.Lane, c.Repo, configuration) : null;
        var known = estimates.Where(e => e != null).Select(e => e!.Value).Concat(currentEstimate is { } ce ? [ce] : []).OrderBy(v => v).ToList();
        if (known.Count == 0)
        {
            return null;
        }

        var median = known[known.Count / 2];
        var rest = estimates.Sum(e => e ?? median);
        if (current != null)
        {
            rest += Math.Max(0, (currentEstimate ?? median) - currentSeconds);
        }

        return Math.Round(rest);
    }

    private static Dictionary<string, List<double>> Load(string file)
    {
        try
        {
            return File.Exists(file)
                ? JsonSerializer.Deserialize<Dictionary<string, List<double>>>(Common.SharedFile.ReadAllText(file)) ?? new()
                : new();
        }
        catch (Exception e) when (e is JsonException or IOException)
        {
            return new();
        }
    }
}
