using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     AB#8832: a test run of a repository its environment's build is already through need not wait for the rest of that
///     build - as long as the test run itself builds nothing.
/// </summary>
public sealed partial class BuildQueue
{
    /// <summary>What Invoke-OctoTestRun -WhatIf said about a waiting test run: it needs no build (Ok), or which project would build.</summary>
    private sealed record EarlyProbe(DateTimeOffset At, bool Pending, bool Ok, string? Reason);

    private Timer? _recheck;

    /// <summary>
    ///     The environment build a waiting test run may start next to, else null. The rule: the run tests a repository of an
    ///     environment; exactly one job of that environment runs and it is its build (kind env); that build is done with the
    ///     repository (built or skipped) and with every repository it depends on (the plan's dependsOn; without it every
    ///     repository before it in the build order). Called under <see cref="_scheduleLock"/>, for a job nothing of its
    ///     environment waits ahead of.
    /// </summary>
    private BuildJob? EarlyStartBuild(BuildJob job)
    {
        if (!IsTest(job) || job.Request.Environment is not { } env || string.IsNullOrWhiteSpace(job.Request.Repo))
        {
            return null;
        }

        var sameEnvironment = _running.Where(r => ClassOf(r) == env).ToList();
        if (sameEnvironment.Count != 1 || sameEnvironment[0] is not { } build || build.Request.Kind != BuildKind.Env)
        {
            return null;
        }

        var repo = job.Request.Repo.Trim();
        foreach (var events in build.Steps.Select(s => build.ReadEvents(s, finished: false)))
        {
            if (ThroughWith(events, repo))
            {
                return build;
            }
        }

        return null;
    }

    /// <summary>The rule on a build's events (pure): the repository and everything it depends on are built or skipped.</summary>
    internal static bool ThroughWith(StepEvents events, string repo)
    {
        static bool Finished(RepoRun r) => r.State is "done" or "skipped";

        var index = events.Repos.FindIndex(r => string.Equals(r.Repo, repo, StringComparison.OrdinalIgnoreCase) || string.Equals(r.Repo, "octo-" + repo, StringComparison.OrdinalIgnoreCase));
        if (index < 0 || events.Done != null || !Finished(events.Repos[index]))
        {
            return false;
        }

        var row = events.Repos[index];
        var upstream = row.DependsOn != null
            ? row.DependsOn.Select(d => events.Repos.FirstOrDefault(r => string.Equals(r.Repo, d, StringComparison.OrdinalIgnoreCase))).ToList()
            : events.Repos.Take(index).ToList<RepoRun?>();
        // A dependency the build does not name is unknown: no early start.
        return upstream.All(r => r != null && Finished(r));
    }

    /// <summary>
    ///     Asks the cmdlet what the waiting test run would do (-WhatIf, read-only) and schedules again with the answer: the
    ///     run may start early only when no selected test project would be built - a build would compile CK models into the
    ///     environment's local catalog and rewrite packages while the environment build writes there.
    /// </summary>
    private async Task ProbeEarlyAsync(BuildJob job)
    {
        EarlyProbe result;
        try
        {
            var config = _store.Load();
            var script = job.Steps[0].Spec.Script;
            var call = (script.EndsWith(" -Json", StringComparison.Ordinal) ? script[..^" -Json".Length] : script) + " -WhatIf -Json";
            var run = await _pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), BuildPlanner.RootPrelude(ServicePlanner.RootPath(config)) + call,
                new PwshRunOptions { Timeout = _options.PlanTimeout }, _abandoned.Token);
            var projects = (PwshRunner.ExtractOctoJson(run.Output, "Invoke-OctoTestRun")?["data"] as JsonObject)?["projects"] as JsonArray;
            result = new EarlyProbe(DateTimeOffset.Now, false, false, null) with { Reason = EarlyRefusal(run.ExitCode == 0 ? projects : null) };
            result = result with { Ok = result.Reason == null };
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            result = new EarlyProbe(DateTimeOffset.Now, false, false, $"the test plan could not be read ({e.Message})");
        }

        job.Early = result;
        Schedule();
    }

    /// <summary>Why a test run with these planned projects (Invoke-OctoTestRun -WhatIf) may not start next to a build; null when it may.</summary>
    internal static string? EarlyRefusal(JsonArray? projects)
    {
        if (projects == null)
        {
            return "the test plan could not be read (Invoke-OctoTestRun -WhatIf gave no projects)";
        }

// Not started at all: skipped (rerunFailed without failed tests), or its runner cannot take the filter (noMatch, octo-tools AB#8832).
        static bool Skipped(JsonObject p) =>
            (p["skip"] is JsonValue skip && (BuildPlanner.Bool(skip) == true || BuildPlanner.Str(skip) is { Length: > 0 })) ||
            (p["noMatch"] is JsonValue noMatch && (BuildPlanner.Bool(noMatch) == true || BuildPlanner.Str(noMatch) is { Length: > 0 }));

        var builds = projects.OfType<JsonObject>().Where(p => !Skipped(p) && BuildPlanner.Bool(p["noBuild"]) != true).ToList();
        if (builds.Count == 0)
        {
            return null;
        }

        var first = builds[0];
        return $"needs a build of {BuildPlanner.Str(first["project"])}: {BuildPlanner.Str(first["buildReason"]) ?? "its build is not current"}" +
               (builds.Count > 1 ? $" (and {builds.Count - 1} more)" : "") +
               "; pass verifyTests=true to lane_build to have test projects compiled";
    }

    /// <summary>While a test run waits behind its environment's build the conditions are looked at again every few seconds. Under the lock.</summary>
    private void KeepRechecking(bool needed)
    {
        if (needed && _recheck == null)
        {
            _recheck = new Timer(_ => Schedule(), null, _options.EarlyRecheck, _options.EarlyRecheck);
        }
        else if (!needed && _recheck != null)
        {
            _recheck.Dispose();
            _recheck = null;
        }
    }
}
