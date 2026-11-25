using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>One repository of a build step in plan order. mode: dotnet | script | frontend | zenon | none.</summary>
/// <remarks>action / reason / detail: the cmdlet's prediction for an environment build (build | skip, and why; AB#8814).</remarks>
public sealed record PlanRepo(string Name, string Mode, string Path, string? Action = null, string? Reason = null, string? Detail = null)
{
    /// <summary>The environment repos this one waits for in a parallel build (package graph).</summary>
    public IReadOnlyList<string>? DependsOn { get; init; }

    /// <summary>Builds alone in a parallel build (build.ps1, frontend, zenon, a CK model).</summary>
    public bool? Exclusive { get; init; }
}

/// <summary>What a step's events file (or, without one, the repos' logs) says about the repositories.</summary>
internal sealed class RepoRun
{
    public required string Repo { get; init; }
    public string State { get; set; } = "pending";
    public DateTimeOffset? StartedAt { get; set; }
    public DateTimeOffset? FinishedAt { get; set; }
    public string? Phase { get; set; }
    public double? Seconds { get; set; }
    public double? BuildSeconds { get; set; }
    public double? TestSeconds { get; set; }
    public double? PackageSeconds { get; set; }

    /// <summary>Parts of the steps (octo-tools AB#8831): the one read of the remote CK catalogs (on the repo that triggered it), restore and compile of the build step, the restore of the test step.</summary>
    public double? CatalogSeconds { get; set; }

    public double? RestoreSeconds { get; set; }
    public double? CompileSeconds { get; set; }
    public double? TestRestoreSeconds { get; set; }
    public int? Copied { get; set; }
    public int? Purged { get; set; }
    public string? LogFile { get; set; }

    /// <summary>A test project of a test run (the row's "repo" is the project): its counts, why it was built, whether it needs Docker.</summary>
    public int? Total { get; set; }

    public int? Passed { get; set; }
    public int? Failed { get; set; }
    public int? Skipped { get; set; }
    public string? BuildReason { get; set; }
    public bool? Docker { get; set; }

    /// <summary>A test project that runs without compiling first (testProjectStart noBuild); false when it compiles first, null when the event does not say.</summary>
    public bool? NoBuild { get; set; }

    /// <summary>vstest | mtp | ng, when the plan or testProjectStart event says it.</summary>
    public string? Runner { get; set; }

    /// <summary>The state the cmdlet gave a finished test project (passed, failed, error, noTests, noMatch); null from an older octo-tools.</summary>
    public string? TestState { get; set; }

    /// <summary>Why the repo was skipped (unchanged, notSelected, excluded, ...) or built (sourcesChanged, ...), with the cmdlet's detail.</summary>
    public string? Reason { get; set; }

    public string? Detail { get; set; }

    /// <summary>The repositories of the build this one depends on (the plan's dependsOn, transitive); null when the plan does not say.</summary>
    public List<string>? DependsOn { get; set; }

    /// <summary>The start order the cmdlet gave the repo (1-based; a skipped repo consumes one too); null before it started.</summary>
    public int? Index { get; set; }
}

internal sealed record StepDone(bool Success, string? FailedRepo, string? FailedStep, double? ElapsedSeconds);

/// <summary>The parsed state of one events file.</summary>
internal sealed class StepEvents
{
    public List<RepoRun> Repos { get; } = [];
    public StepDone? Done { get; set; }
    public int Lines { get; set; }
    public DateTimeOffset? LastEventAt { get; set; }

    /// <summary>The cmdlet builds independent repos at the same time (plan.parallel) and how many at most.</summary>
    public bool Parallel { get; set; }

    public int? MaxParallel { get; set; }

    /// <summary>The repository of a test run as the cmdlet resolved it (plan.repo): its results folder is named after it.</summary>
    public string? TestRepo { get; set; }

    /// <summary>A test run waits for the machine-wide test lock: who holds it (set by lockWait, cleared by lockAcquired and done).</summary>
    public string? LockWait { get; set; }

    public RepoRun Repo(string name)
    {
        var run = Repos.FirstOrDefault(r => string.Equals(r.Repo, name, StringComparison.OrdinalIgnoreCase));
        if (run == null)
        {
            run = new RepoRun { Repo = name };
            Repos.Add(run);
        }

        return run;
    }
}

/// <summary>Reads the JSON lines of -EventsFile. Tolerant: a partial last line, unknown events and broken lines are skipped.</summary>
internal static class BuildEventReader
{
    public static StepEvents Parse(string text, IReadOnlyList<PlanRepo> plan)
    {
        var result = new StepEvents();
        foreach (var repo in plan)
        {
            result.Repo(repo.Name);
        }

        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] != '{')
            {
                continue;
            }

            JsonObject? e;
            try
            {
                e = JsonNode.Parse(line) as JsonObject;
            }
            catch (JsonException)
            {
                continue; // partial last line while the cmdlet writes it
            }

            if (e == null)
            {
                continue;
            }

            result.Lines++;
            var ts = Time(e["ts"]);
            if (ts != null)
            {
                result.LastEventAt = ts;
            }

            switch (Str(e["event"]))
            {
                case "plan" when e["projects"] is JsonArray projects:
                    result.TestRepo = Str(e["repo"]);
                    foreach (var p in projects.OfType<JsonObject>())
                    {
                        if (Str(p["project"]) is { } name)
                        {
                            var run = result.Repo(name);
                            run.Docker = Bool(p["docker"]);
                            run.Runner = Str(p["runner"]) ?? run.Runner;
                            run.BuildReason = Str(p["buildReason"]);
                            if (Bool(p["skip"]) == true)
                            {
                                run.State = "skipped";
                            }
                        }
                    }

                    break;
                case "lockWait":
                    result.LockWait = LockOwner(e["owner"] as JsonObject);
                    break;
                case "lockAcquired":
                    result.LockWait = null;
                    break;
                case "testProjectStart" when Str(e["project"]) is { } name:
                {
                    var run = result.Repo(name);
                    run.State = "building";
                    run.StartedAt = ts;
                    run.Phase = "tests";
                    run.Docker = Bool(e["docker"]) ?? run.Docker;
                    run.NoBuild = Bool(e["noBuild"]) ?? run.NoBuild;
                    run.Runner = Str(e["runner"]) ?? run.Runner;
                    run.BuildReason = Str(e["buildReason"]) ?? run.BuildReason;
                    break;
                }
                case "testProjectDone" when Str(e["project"]) is { } name:
                {
                    var run = result.Repo(name);
                    run.State = Bool(e["success"]) == false ? "failed" : "done";
                    run.TestState = Str(e["state"]);
                    run.FinishedAt = ts;
                    run.Seconds = Num(e["seconds"]);
                    run.TestSeconds = run.Seconds;
                    run.Total = (int?)Num(e["total"]);
                    run.Passed = (int?)Num(e["passed"]);
                    run.Failed = (int?)Num(e["failed"]);
                    run.Skipped = (int?)Num(e["skipped"]);
                    run.LogFile = Str(e["logFile"]);
                    break;
                }
                case "plan" when e["repos"] is JsonArray repos:
                    result.Parallel = Bool(e["parallel"]) == true;
                    result.MaxParallel = (int?)Num(e["maxParallel"]);
                    foreach (var r in repos.OfType<JsonObject>())
                    {
                        if (Str(r["repo"]) is { } name)
                        {
                            var planned = result.Repo(name);
                            if (r["dependsOn"] is JsonArray dependsOn)
                            {
                                planned.DependsOn = dependsOn.Select(Str).OfType<string>().ToList();
                            }
                        }
                    }

                    break;
                case "repoStart" when Str(e["repo"]) is { } name:
                {
                    var run = result.Repo(name);
                    run.State = "building";
                    run.StartedAt = ts;
                    run.Phase = "build";
                    run.Index = (int?)Num(e["index"]) ?? run.Index;
                    break;
                }
                case "phase" when Str(e["repo"]) is { } name:
                {
                    var run = result.Repo(name);
                    if (run.State == "pending")
                    {
                        run.State = "building";
                        run.StartedAt ??= ts;
                    }

                    run.Phase = Str(e["phase"]) ?? run.Phase;
                    break;
                }
                case "repoSkipped" when Str(e["repo"]) is { } name:
                {
                    // A repository that is not built (unchanged, not selected, excluded): no start, no durations.
                    var run = result.Repo(name);
                    run.State = "skipped";
                    run.Reason = Str(e["reason"]);
                    run.Detail = Str(e["detail"]);
                    run.Index = (int?)Num(e["index"]) ?? run.Index;
                    break;
                }
                case "repoDone" when Str(e["repo"]) is { } name:
                {
                    var run = result.Repo(name);
                    run.State = Bool(e["success"]) == false ? "failed" : Str(e["status"]) == "skipped" ? "skipped" : "done";
                    run.Reason = Str(e["reason"]) ?? run.Reason;
                    run.FinishedAt = ts;
                    run.Seconds = Num(e["seconds"]);
                    run.BuildSeconds = Num(e["buildSeconds"]);
                    run.TestSeconds = Num(e["testSeconds"]);
                    run.PackageSeconds = Num(e["packageSeconds"]);
                    run.CatalogSeconds = Num(e["catalogSeconds"]);
                    run.RestoreSeconds = Num(e["restoreSeconds"]);
                    run.CompileSeconds = Num(e["compileSeconds"]);
                    run.TestRestoreSeconds = Num(e["testRestoreSeconds"]);
                    run.Copied = (int?)Num(e["copied"]);
                    run.Purged = (int?)Num(e["purged"]);
                    run.LogFile = Str(e["logFile"]);
                    break;
                }
                case "done":
                    result.Done = new StepDone(Bool(e["success"]) == true, Str(e["failedProject"]) ?? Str(e["failedRepo"]), Str(e["failedStep"]), Num(e["elapsedSeconds"]));
                    result.LockWait = null;
                    break;
            }
        }

        return result;
    }

    /// <summary>Who holds the test lock, in words: "Invoke-OctoTestRun of ab8797 octo-a (pid 4711, since 10:48)".</summary>
    internal static string LockOwner(JsonObject? owner)
    {
        if (owner == null)
        {
            return "another test run";
        }

        var where = Str(owner["environment"]) ?? Str(owner["lane"]);
        var what = string.Join(' ', new[] { where, Str(owner["repo"]) }.Where(x => !string.IsNullOrEmpty(x)));
        var details = new List<string>();
        if (Num(owner["pid"]) is { } pid)
        {
            details.Add($"pid {pid:0}");
        }

        if (Time(owner["since"]) is { } since)
        {
            details.Add($"since {since:HH:mm}");
        }

        return $"{Str(owner["command"]) ?? "a test run"}{(what.Length > 0 ? " of " + what : "")}{(details.Count > 0 ? $" ({string.Join(", ", details)})" : "")}";
    }

    public static string ReadShared(string file)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            return reader.ReadToEnd();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "";
        }
    }

    private static string? Str(JsonNode? node) => node is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;

    private static bool? Bool(JsonNode? node) => node is JsonValue v ? v.GetValueKind() switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null
    } : null;

    private static double? Num(JsonNode? node) => node is JsonValue v && v.GetValueKind() == JsonValueKind.Number ? v.GetValue<double>() : null;

    private static DateTimeOffset? Time(JsonNode? node) =>
        Str(node) is { } s && DateTimeOffset.TryParse(s, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal,
            out var t)
            ? t.ToLocalTime()
            : null;
}

/// <summary>
///     Progress without an events file (older octo-tools): the repos are built in plan order and each build recreates
///     <c>&lt;repo&gt;/Invoke-Build.log</c>; a log written since the step started marks the repo as started, its last write
///     as the end of its build.
/// </summary>
internal static class BuildLogPoller
{
    public static StepEvents Poll(IReadOnlyList<PlanRepo> plan, DateTimeOffset stepStartedAt, bool stepFinished)
    {
        var result = new StepEvents();
        var runs = plan.Select(p => (Plan: p, Run: result.Repo(p.Name))).ToList();
        var lastStarted = -1;
        // Where the creation (birth) time is not available (often on Linux) the start is the end of the previous
        // repository's log, or the start of the step.
        var previousEnd = stepStartedAt;
        for (var i = 0; i < runs.Count; i++)
        {
            var log = Path.Combine(runs[i].Plan.Path, "Invoke-Build.log");
            if (!File.Exists(log))
            {
                continue;
            }

            var written = new DateTimeOffset(File.GetLastWriteTime(log));
            if (written < stepStartedAt.AddSeconds(-1))
            {
                continue;
            }

            var created = new DateTimeOffset(File.GetCreationTime(log));
            var fallbackStart = previousEnd <= written ? previousEnd : written;
            runs[i].Run.StartedAt = created >= stepStartedAt.AddSeconds(-1) && created < written ? created : fallbackStart;
            previousEnd = written;
            runs[i].Run.FinishedAt = written;
            runs[i].Run.LogFile = log;
            lastStarted = i;
        }

        for (var i = 0; i <= lastStarted; i++)
        {
            var run = runs[i].Run;
            if (run.StartedAt == null)
            {
                run.State = "skipped"; // a later repo started, this one wrote no log (script/none builder)
                continue;
            }

            var current = i == lastStarted && !stepFinished;
            run.State = current ? "building" : "done";
            run.Phase = current ? "build" : null;
            if (!current)
            {
                run.Seconds = (run.FinishedAt!.Value - run.StartedAt.Value).TotalSeconds;
                run.BuildSeconds = run.Seconds;
            }
            else
            {
                run.FinishedAt = null;
            }
        }

        return result;
    }
}
