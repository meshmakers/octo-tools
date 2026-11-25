using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     How long things usually take: the durations of successful repository builds (kind build) and of test projects of
///     unfiltered test runs (kind test, the project of a repository), the last <see cref="Keep" /> per repository, project and
///     configuration across every lane, persisted in the state folder (<c>duration-history.json</c>). The ETA of a running
///     job comes from them (a lane's own durations first), and so do the statistics of <c>job_stats</c> and the limit beyond
///     which a running repository or test project is overdue - it probably hangs.
/// </summary>
public sealed class BuildHistory
{
    /// <summary>Durations kept per repository (or test project) and configuration, across lanes.</summary>
    internal const int Keep = 30;

    /// <summary>A lane's own estimate (the ETA) averages its last five durations.</summary>
    private const int LaneWindow = 5;

    /// <summary>Durations needed before a limit is set: fewer say too little about what is usual.</summary>
    internal const int MinSamplesForLimit = 3;

    /// <summary>The least a running item may exceed its usual time by before it counts as overdue.</summary>
    internal const double MinGraceSeconds = 120;

    private const string FileName = "duration-history.json";
    private const string LegacyFileName = "build-history.json";

    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    private readonly string _file;
    private readonly Lock _lock = new();
    private readonly Dictionary<string, Series> _series;

    public BuildHistory(DevStackPaths paths)
    {
        _file = Path.Combine(paths.StateDirectory, FileName);
        _series = Load(_file, Path.Combine(paths.StateDirectory, LegacyFileName));
    }

    // A test project that compiles first takes far longer than one that runs on its last build: two series, never mixed.
    private static string Key(string kind, string repo, string? project, string configuration, bool? compilesFirst = null) =>
        $"{kind}|{repo.ToLowerInvariant()}|{project?.ToLowerInvariant() ?? ""}|{configuration}" +
        (compilesFirst switch { true => "|compiles", false => "|prebuilt", null => "" });

    private static string LaneKey(string lane) => PathScope.Normalize(lane).TrimEnd(Path.DirectorySeparatorChar);

    /// <summary>A repository built successfully in <paramref name="lane" />.</summary>
    public void Record(string lane, string repo, string configuration, double seconds, DateTimeOffset? at = null) =>
        Add(DurationKind.Build, lane, repo, null, configuration, null, seconds, at);

    /// <summary>
    ///     A test project of <paramref name="repo" /> ran to its end (passed or failed) in an unfiltered test run;
    ///     <paramref name="compilesFirst" />: whether it compiled before it ran (null when the cmdlet did not say).
    /// </summary>
    public void RecordTest(string lane, string repo, string project, bool? compilesFirst, string configuration, double seconds, DateTimeOffset? at = null) =>
        Add(DurationKind.Test, lane, repo, project, configuration, compilesFirst, seconds, at);

    private void Add(string kind, string lane, string repo, string? project, string configuration, bool? compilesFirst, double seconds, DateTimeOffset? at)
    {
        if (seconds <= 0 || double.IsNaN(seconds) || string.IsNullOrWhiteSpace(repo))
        {
            return;
        }

        lock (_lock)
        {
            var key = Key(kind, repo, project, configuration, compilesFirst);
            if (!_series.TryGetValue(key, out var series))
            {
                _series[key] = series = new Series { Kind = kind, Repo = repo, Project = project, Configuration = configuration, CompilesFirst = compilesFirst };
            }

            series.Samples.Add(new Sample { At = at ?? DateTimeOffset.Now, Seconds = Math.Round(seconds, 1), Lane = LaneKey(lane) });
            if (series.Samples.Count > Keep)
            {
                series.Samples.RemoveRange(0, series.Samples.Count - Keep);
            }

            try
            {
                var temp = _file + ".tmp";
                File.WriteAllText(temp, JsonSerializer.Serialize(new HistoryFile { Series = _series.Values.ToList() }, Json));
                SharedFile.Replace(temp, _file);
            }
            catch (IOException)
            {
                // History is a nice-to-have; an unwritable state folder must not fail a build.
            }
        }
    }

    /// <summary>
    ///     What a build of the repo in this lane takes: the average of the lane's last five durations, else the median of every
    ///     lane's; null when the repo was never built.
    /// </summary>
    public double? Estimate(string lane, string repo, string configuration)
    {
        lock (_lock)
        {
            if (!_series.TryGetValue(Key(DurationKind.Build, repo, null, configuration), out var series) || series.Samples.Count == 0)
            {
                return null;
            }

            var laneKey = LaneKey(lane);
            var own = series.Samples.Where(s => s.Lane == laneKey).TakeLast(LaneWindow).ToList();
            return own.Count > 0 ? own.Average(s => s.Seconds) : Percentile(series.Samples.Select(s => s.Seconds).ToList(), 50);
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

    /// <summary>
    ///     What is usual for a repository build (project null) or a test project that compiles first or not
    ///     (<paramref name="compilesFirst" />); null when nothing was recorded.
    /// </summary>
    public DurationStat? Typical(string kind, string repo, string? project, string configuration, bool? compilesFirst = null)
    {
        lock (_lock)
        {
            return _series.TryGetValue(Key(kind, repo, project, configuration, compilesFirst), out var series) && series.Samples.Count > 0 ? Stat(series) : null;
        }
    }

    /// <summary>Every recorded repository build and test project, slowest (by median) first.</summary>
    public IReadOnlyList<DurationStat> Stats()
    {
        lock (_lock)
        {
            return _series.Values.Where(s => s.Samples.Count > 0).Select(Stat)
                .OrderByDescending(s => s.MedianSeconds).ThenBy(s => s.Repo, StringComparer.OrdinalIgnoreCase).ThenBy(s => s.Project, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
    }

    /// <summary>
    ///     The limit beyond which a running item is overdue: twice the slowest usual time (p90), and at least two minutes more
    ///     than the median - a short build that takes a minute longer is no hang. Null with fewer than three durations.
    /// </summary>
    internal static double? Limit(int samples, double median, double p90) =>
        samples < MinSamplesForLimit ? null : Math.Round(Math.Max(2 * p90, median + MinGraceSeconds));

    private static DurationStat Stat(Series series)
    {
        var values = series.Samples.Select(s => s.Seconds).ToList();
        var median = Percentile(values, 50);
        var p90 = Percentile(values, 90);
        var last = series.Samples[^1];
        return new DurationStat(series.Kind, series.Repo, series.Project, series.Configuration, values.Count, Math.Round(median, 1), Math.Round(p90, 1),
            values.Min(), values.Max(), last.Seconds, last.At, Limit(values.Count, median, p90)) { CompilesFirst = series.CompilesFirst };
    }

    /// <summary>Nearest-rank percentile of a non-empty list.</summary>
    internal static double Percentile(IReadOnlyList<double> values, int percent)
    {
        var sorted = values.OrderBy(v => v).ToList();
        var rank = (int)Math.Ceiling(percent / 100.0 * sorted.Count);
        return sorted[Math.Clamp(rank - 1, 0, sorted.Count - 1)];
    }

    private static Dictionary<string, Series> Load(string file, string legacyFile)
    {
        try
        {
            if (File.Exists(file))
            {
                var stored = JsonSerializer.Deserialize<HistoryFile>(SharedFile.ReadAllText(file), Json)?.Series ?? [];
                // A damaged or hand-edited file may hold nulls: such entries are dropped, never a reason to fail.
                var series = stored.OfType<Series>()
                    .Where(s => s.Kind is DurationKind.Build or DurationKind.Test && !string.IsNullOrEmpty(s.Repo) && s.Configuration != null)
                    .Select(s => { s.Samples = (s.Samples ?? []).OfType<Sample>().Where(x => x.Seconds > 0).ToList(); return s; })
                    .ToList();
                return series.GroupBy(s => Key(s.Kind, s.Repo, s.Project, s.Configuration, s.CompilesFirst)).ToDictionary(g => g.Key, g => g.First());
            }

            return File.Exists(legacyFile) ? FromLegacy(legacyFile) : new Dictionary<string, Series>();
        }
        catch (Exception)
        {
            // History is a nice-to-have: whatever is wrong with the file, the daemon starts with an empty one.
            return new Dictionary<string, Series>();
        }
    }

    /// <summary>build-history.json of earlier daemons: "lane|repo|configuration" -> the last five seconds, without times.</summary>
    private static Dictionary<string, Series> FromLegacy(string legacyFile)
    {
        var result = new Dictionary<string, Series>();
        var legacy = JsonSerializer.Deserialize<Dictionary<string, List<double>>>(SharedFile.ReadAllText(legacyFile)) ?? new Dictionary<string, List<double>>();
        foreach (var (key, values) in legacy)
        {
            var parts = key.Split('|');
            if (parts.Length != 3 || parts[1].Length == 0)
            {
                continue;
            }

            var k = Key(DurationKind.Build, parts[1], null, parts[2]);
            if (!result.TryGetValue(k, out var series))
            {
                result[k] = series = new Series { Kind = DurationKind.Build, Repo = parts[1], Configuration = parts[2] };
            }

            series.Samples.AddRange((values ?? []).Where(v => v > 0).Select(v => new Sample { Seconds = v, Lane = LaneKey(parts[0]) }));
        }

        foreach (var series in result.Values.Where(s => s.Samples.Count > Keep))
        {
            series.Samples.RemoveRange(0, series.Samples.Count - Keep);
        }

        return result;
    }

    private sealed class HistoryFile
    {
        public int SchemaVersion { get; set; } = 1;
        public List<Series> Series { get; set; } = [];
    }

    private sealed class Series
    {
        public string Kind { get; set; } = DurationKind.Build;
        public string Repo { get; set; } = "";
        public string? Project { get; set; }
        public string Configuration { get; set; } = "";

        /// <summary>A test project: whether its runs compiled it first (null for a build and when the cmdlet did not say).</summary>
        public bool? CompilesFirst { get; set; }

        public List<Sample> Samples { get; set; } = [];
    }

    private sealed class Sample
    {
        /// <summary>When the item ended; null for durations taken over from build-history.json.</summary>
        public DateTimeOffset? At { get; set; }

        public double Seconds { get; set; }
        public string Lane { get; set; } = "";
    }
}

/// <summary>The kinds of durations the history keeps.</summary>
public static class DurationKind
{
    /// <summary>A repository build (the repo's whole time in a build step).</summary>
    public const string Build = "build";

    /// <summary>A test project of an unfiltered test run.</summary>
    public const string Test = "test";
}

/// <summary>
///     What a repository build (kind build) or a test project (kind test, project = the test project of repo) usually takes in
///     a configuration, from the last durations of every lane: samples, median, p90, min, max, the last one and when it ended
///     (lastAt; absent for durations an earlier daemon recorded without a time), and limitSeconds - a running item beyond it is
///     overdue and probably hangs (twice p90, at least median + 120 s; absent below three samples). compilesFirst (test projects):
///     true for the runs that compiled the project before running it, false for those that ran on its last build - each its
///     own row, a running project is compared with the row of its own kind (absent when the cmdlet did not say).
/// </summary>
public sealed record DurationStat(
    string Kind,
    string Repo,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Project,
    string Configuration,
    int Samples,
    double MedianSeconds,
    double P90Seconds,
    double MinSeconds,
    double MaxSeconds,
    double LastSeconds,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DateTimeOffset? LastAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    double? LimitSeconds)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? CompilesFirst { get; init; }
}
