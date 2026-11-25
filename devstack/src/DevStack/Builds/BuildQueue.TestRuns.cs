using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     AB#9808: test runs that tell the truth - rerunFailed reruns the failed tests of one named job or is refused, a run in
///     which no test ran is no success, and a frontend lane test that cannot work is refused before it builds anything.
/// </summary>
public sealed partial class BuildQueue
{
    /// <summary>The lane folder every frontend repository of a lane builds against (its build.ps1 builds ../octo-frontend-libraries).</summary>
    internal const string FrontendLibraries = "octo-frontend-libraries";

    /// <summary>
    ///     rerunFailed: Invoke-OctoTestRun reads the last result of each project (its last-result.json), which a later run of the
    ///     same project - a filtered one too - replaces (b383 after b376: 0 tests, "succeeded"). So the rerun is tied to one job:
    ///     the newest finished test run of the same repository in the same lane. Only that job's projects with failed tests run
    ///     (their last result is that job's), the note names the job; a run without failed tests, a running or waiting test run of
    ///     the repository, or none at all is refused before a job exists.
    /// </summary>
    private (BuildRequest Request, string Note) RerunOf(BuildRequest request, PlannedBuild planned)
    {
        var where = planned.Request.Environment is { } env ? $"lane {env}" : planned.Lane ?? "the base lane";
        var repo = planned.TestFolder is { Length: > 0 } folder ? Path.GetFileName(folder.TrimEnd('/', '\\')) : request.Repo?.Trim();
        var same = _jobs.Values.Where(j => IsTest(j) && SameTestTarget(j, planned)).ToList();
        if (same.Where(j => j.State is "queued" or "running").OrderBy(j => j.Sequence).FirstOrDefault() is { } active)
        {
            throw new InvalidOperationException(
                $"rerunFailed refused, nothing was queued: test run {active.Id} of {repo} is {active.State} in {where}; its result decides which tests " +
                $"failed. Wait for it (job_status(\"{active.Id}\", waitSeconds)) and ask again.");
        }

        var finished = same.Where(j => j.FinishedAt != null).OrderByDescending(j => j.FinishedAt).ThenByDescending(j => j.Sequence).ToList();
        if (finished.Count == 0)
        {
            throw new InvalidOperationException(
                $"rerunFailed refused, nothing was queued: octo-devstack knows no finished test run of {repo} in {where}, so there is no job whose " +
                "failed tests it could run. Run the tests without rerunFailed first.");
        }

        var last = finished[0];
        var failed = FailedProjects(last);
        if (failed.Count == 0)
        {
            var earlier = finished.Skip(1).FirstOrDefault(j => FailedProjects(j).Count > 0);
            var snapshot = last.Snapshot();
            throw new InvalidOperationException(
                $"rerunFailed refused, nothing was queued: the last test run of {repo} in {where}, {last.Id} ({snapshot.State}" +
                (snapshot.Outcome?.Summary is { Length: > 0 } summary ? $": {summary}" : "") + "), has no failed test - its results are what rerunFailed reads." +
                (earlier != null
                    ? $" {earlier.Id} had failed tests ({string.Join(", ", FailedProjects(earlier))}), but {last.Id} ran later: run them again by name with " +
                      $"filter (job_status(\"{earlier.Id}\", project=X) lists them) or run the whole project."
                    : ""));
        }

        var asked = request.Projects.Where(p => !string.IsNullOrWhiteSpace(p)).Select(p => p.Trim()).ToList();
        var chosen = asked.Count == 0 ? failed : failed.Where(f => asked.Any(p => NamesProject(p, f))).ToList();
        if (chosen.Count == 0)
        {
            throw new InvalidOperationException(
                $"rerunFailed refused, nothing was queued: {string.Join(", ", asked)} had no failed test in {last.Id}, the last test run of {repo} in " +
                $"{where} (failed there: {string.Join(", ", failed)}).");
        }

        var count = FailedCount(last, chosen);
        return (request with { Projects = chosen }, $"rerunFailed: runs the {count} failed test(s) of {last.Id} again, in {string.Join(", ", chosen)}.");
    }

    /// <summary>Whether a job tests the same repository folder in the same lane as <paramref name="planned"/>.</summary>
    private static bool SameTestTarget(BuildJob job, PlannedBuild planned)
    {
        if (job.Planned.Lane == null || planned.Lane == null || !PathScope.SamePath(job.Planned.Lane, planned.Lane))
        {
            return false;
        }

        return job.Planned.TestFolder is { Length: > 0 } a && planned.TestFolder is { Length: > 0 } b
            ? PathScope.SamePath(a, b)
            : string.Equals(job.Request.Repo?.Trim(), planned.Request.Repo?.Trim(), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>The test projects of a finished test run that had failed tests.</summary>
    private static List<string> FailedProjects(BuildJob job) =>
        (job.Snapshot().Tests ?? []).Where(t => (t.Failed ?? 0) > 0).Select(t => t.Project).ToList();

    private static int FailedCount(BuildJob job, IReadOnlyCollection<string> projects) =>
        (job.Snapshot().Tests ?? []).Where(t => projects.Contains(t.Project)).Sum(t => t.Failed ?? 0);

    /// <summary>How lane_test's 'project' names a test project: its csproj name, a path to it, or a unique part of the name.</summary>
    private static bool NamesProject(string asked, string project) =>
        string.Equals(asked, project, StringComparison.OrdinalIgnoreCase) ||
        string.Equals(Path.GetFileNameWithoutExtension(asked.TrimEnd('/', '\\')), project, StringComparison.OrdinalIgnoreCase) ||
        project.Contains(asked, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    ///     A test run whose projects ran no test at all: none reported, or every one with a total of 0 (noMatch, noTests,
    ///     skipped, notRun). Counts the cmdlet did not report (an older octo-tools) leave the decision to it.
    /// </summary>
    internal static bool NoTestRan(IReadOnlyList<BuildTestProject> tests) =>
        tests.Count == 0 || (tests.All(t => t.Total != null) && tests.Sum(t => t.Total ?? 0) == 0);

    /// <summary>
    ///     lane_test of a frontend repository (octo-frontend-*): refused before it builds anything when the lane does not hold
    ///     octo-frontend-libraries (the frontends build against the lane's copy) or a variable the frontend builds need
    ///     (TELERIK_LICENSE, devstack.yaml buildVariables) is not set for the daemon's builds - looked at by name only, never
    ///     by value. A probe that does not answer refuses nothing.
    /// </summary>
    private async Task FrontendPreflightAsync(PlannedBuild planned, CancellationToken cancellationToken)
    {
        var lane = planned.Request.Environment;
        var repo = planned.TestFolder is { Length: > 0 } folder ? Path.GetFileName(folder.TrimEnd('/', '\\')) : planned.Request.Repo?.Trim();
        if (lane == null || planned.Lane == null || repo == null || !repo.StartsWith("octo-frontend-", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        if (!Directory.Exists(Path.Combine(planned.Lane, FrontendLibraries)))
        {
            throw new InvalidOperationException(
                $"Test run of {repo} refused before it built anything: lane {lane} does not hold {FrontendLibraries}, and the frontend tests build " +
                $"against the lane's copy of it. Add it with lane_add_repo(owner, lane=\"{lane}\", repo=\"{FrontendLibraries}\") and run lane_test again.");
        }

        var config = _store.Load();
        var names = SetupCheck.EffectiveBuildVariables(config)
            .Where(v => v.Repos.Count == 0 || v.Repos.Any(r => string.Equals(r, repo, StringComparison.OrdinalIgnoreCase) ||
                                                              string.Equals(r, FrontendLibraries, StringComparison.OrdinalIgnoreCase)))
            .Select(v => v.Name).Distinct().ToList();
        if (names.Count == 0)
        {
            return;
        }

        var result = await _pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), SetupCheck.BuildVariablesBody(names), new PwshRunOptions { Timeout = TimeSpan.FromMinutes(1) },
            cancellationToken);
        if (PwshRunner.ExtractMarker(result.Output) is not { } seen)
        {
            return;
        }

        var set = (seen["set"] as System.Text.Json.Nodes.JsonArray ?? []).Select(n => n?.ToString()).ToHashSet(StringComparer.Ordinal);
        var missing = names.Where(n => !set.Contains(n)).ToList();
        if (missing.Count > 0)
        {
            var profile = seen["profile"]?.ToString() is { Length: > 0 } p ? p : "your private PowerShell profile (setup_check names it)";
            throw new InvalidOperationException(
                $"Test run of {repo} refused before it built anything: {string.Join(", ", missing)} {(missing.Count == 1 ? "is" : "are")} not set for the daemon's " +
                $"builds (the frontend builds need {(missing.Count == 1 ? "it" : "them")}; TELERIK_LICENSE is the Kendo UI license). Add " +
                $"{string.Join("; ", missing.Select(SetupCheck.ProfileAssignment))} to {profile} - octo-tools' profile.ps1 loads it for every build of the " +
                "daemon, no restart needed - and run lane_test again.");
        }
    }
}
