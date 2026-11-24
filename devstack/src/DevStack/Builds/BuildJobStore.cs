using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     A build job as it is kept in <c>builds/&lt;id&gt;.job.json</c>: what was asked, the plan it runs, where it is and how it
///     ended. Written on every change, so the next daemon run restores queued jobs in order, re-attaches to running ones
///     and still answers job_status for finished ones. No environment values of services; the steps' scripts and build
///     environment are the same text the job log and the process list show.
/// </summary>
internal sealed class JobRecord
{
    public int SchemaVersion { get; set; } = 1;
    public string Id { get; set; } = "";
    public long Sequence { get; set; }
    public BuildRequest Request { get; set; } = new() { Owner = "" };
    public PlannedBuild? Plan { get; set; }
    public string State { get; set; } = "queued";
    public bool Success { get; set; }
    public DateTimeOffset QueuedAt { get; set; }
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }
    public string? Phase { get; set; }
    public BuildOutcome? Outcome { get; set; }
    public bool LeaseRequired { get; set; }
    public List<string> LeaseSlots { get; set; } = [];
    public List<string> PlannedStops { get; set; } = [];

    /// <summary>The services the build stopped, with their overrides, to start them again after it (also after a daemon restart).</summary>
    public List<string> StoppedNames { get; set; } = [];

    public Dictionary<string, ServiceOverride> StoppedOverrides { get; set; } = [];
    public List<string> Notes { get; set; } = [];
    public Dictionary<string, List<BuildError>> Errors { get; set; } = [];
    public Dictionary<string, RepoCounts> Counts { get; set; } = [];
    public int ErrorCount { get; set; }
    public int WarningCount { get; set; }
    public Dictionary<string, string> PerRepoLogs { get; set; } = [];
    public List<JsonObject> Results { get; set; } = [];
    public string? OutputTail { get; set; }
    public List<string> Files { get; set; } = [];
    public List<StepRecord> Steps { get; set; } = [];

    /// <summary>A finished test run's projects with their failed tests.</summary>
    public List<BuildTestProject>? Tests { get; set; }

    /// <summary>The work trees the job covers, read with git when it started and when it ended (null before it started).</summary>
    public List<BuildRepoEvidence>? Evidence { get; set; }

    /// <summary>How often a daemon start took the job over while it ran (each one adds a note).</summary>
    public int Reattached { get; set; }

    /// <summary>A build of a daemon version without job files, taken over from the state file: no plan, no exit marker.</summary>
    public bool Legacy { get; set; }
}

/// <summary>Errors and warnings of one repo's log.</summary>
internal sealed record RepoCounts(int Errors, int Warnings);

internal sealed class StepRecord
{
    public string EventsFile { get; set; } = "";
    public string ExitFile { get; set; } = "";
    public DateTimeOffset? StartedAt { get; set; }
    public int? Pid { get; set; }

    /// <summary>The OS start time of <see cref="Pid"/>: re-attaching requires it to match (pid reuse).</summary>
    public DateTimeOffset? ProcessStart { get; set; }

    /// <summary>Length of the job log when the step started: its output starts there.</summary>
    public long LogOffset { get; set; }

    public bool Completed { get; set; }
    public bool Success { get; set; }
    public BuildOutcome? Outcome { get; set; }
    public List<RepoRun>? Repos { get; set; }
    public StepDone? Done { get; set; }
}

/// <summary>Reads and writes the job files of the state folder's builds directory.</summary>
internal sealed class BuildJobStore(string directory)
{
    public const string Suffix = ".job.json";

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter() }
    };

    public string PathOf(string id) => Path.Combine(directory, id + Suffix);

    public void Save(JobRecord record)
    {
        var file = PathOf(record.Id);
        var temp = file + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(record, Options));
        Common.SharedFile.Replace(temp, file);
    }

    /// <summary>Every readable job file, oldest job first; an unreadable one is set aside as <c>.corrupt</c> and reported.</summary>
    public List<JobRecord> LoadAll(Action<string, Exception>? unreadable = null)
    {
        var result = new List<JobRecord>();
        if (!Directory.Exists(directory))
        {
            return result;
        }

        foreach (var file in Directory.EnumerateFiles(directory, "*" + Suffix))
        {
            try
            {
                if (JsonSerializer.Deserialize<JobRecord>(Common.SharedFile.ReadAllText(file), Options) is { Id.Length: > 0, Plan: not null } record)
                {
                    result.Add(record);
                }
            }
            catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or NotSupportedException)
            {
                unreadable?.Invoke(file, e);
                try
                {
                    File.Move(file, file + ".corrupt", overwrite: true);
                }
                catch (Exception move) when (move is IOException or UnauthorizedAccessException)
                {
                    // Left in place; it is reported again at the next start.
                }
            }
        }

        return result.OrderBy(r => r.Sequence).ThenBy(r => r.QueuedAt).ToList();
    }

    /// <summary>The record as JSON text (tests compare round trips).</summary>
    internal static string Serialize(JobRecord record) => JsonSerializer.Serialize(record, Options);

    internal static JobRecord? Deserialize(string json) => JsonSerializer.Deserialize<JobRecord>(json, Options);
}
