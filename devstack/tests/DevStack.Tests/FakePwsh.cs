using System.Text.Json;
using System.Text.RegularExpressions;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     Stands in for pwsh: answers the capability probe, dry runs and Get-OctoBuildOrder with canned output and hands the
///     build calls to <see cref="Build"/>. Never starts a process.
/// </summary>
internal sealed partial class FakePwsh : IPwshRunner
{
    public const string WorktreeParams =
        """{"Invoke-Build":["repositoryPath","configuration","DryRun","msbuildProperties","EventsFile","Json"],"Invoke-BuildRange":["from","branch","msbuildProperties","repoPaths","feedPath","EventsFile","Json"],"Invoke-BuildAll":["branch","DryRun","skipKill","EventsFile","Json"],"Invoke-KillDotnet":["branchRootPath","Json"]}""";

    // octo-tools with the environment cmdlets as agreed for AB#8700 (branch reimar/feature-environments).
    public const string EnvironmentParams =
        """{"Invoke-Build":["repositoryPath","configuration","DryRun","msbuildProperties","EventsFile","Json"],"Invoke-BuildRange":["from","branch","msbuildProperties","repoPaths","feedPath","EventsFile","Json"],"Invoke-BuildAll":["branch","DryRun","skipKill","EventsFile","Json"],"Invoke-KillDotnet":["branchRootPath","Json"],"Invoke-BuildEnvironment":["env","syncMain","verifyTests","includeTests","DryRun","EventsFile","Json"],"New-OctoEnvironment":["env","repos","workItem","branchName","owner","addAffected","Json"],"Remove-OctoEnvironment":["env","WhatIf","Json"],"Add-OctoEnvironmentRepo":["env","repo","role","addAffected","path","inPlace","Json"],"Sync-OctoEnvironment":["env","Json"],"Get-OctoAffectedRepos":["env","target","Json"],"Get-OctoEnvironment":["env","Json"]}""";

    // octo-tools whose Invoke-BuildEnvironment builds only what changed (AB#8814): -repos, -skip, -buildUnchanged.
    public static readonly string NarrowParams = EnvironmentParams.Replace(
        "\"Invoke-BuildEnvironment\":[\"env\",", "\"Invoke-BuildEnvironment\":[\"env\",\"repos\",\"skip\",\"buildUnchanged\",");

    // octo-tools whose Invoke-BuildEnvironment builds independent repos in parallel (AB#8814): -maxParallel on top of the above.
    public static readonly string ParallelParams = NarrowParams.Replace("\"buildUnchanged\",", "\"buildUnchanged\",\"maxParallel\",");

    // octo-tools with the test cmdlets of AB#8813 (modules/OctoTests.psm1) on top of the environment cmdlets.
    public static readonly string TestParams = EnvironmentParams[..^1] +
        ""","Invoke-OctoTestRun":["env","branch","repo","project","filter","rerunFailed","build","dockerLock","lockTimeoutSeconds","configuration","maxFailures","EventsFile","WhatIf","Json"],"Get-OctoTestLock":["Json"]}""";

    // octo-tools with the list-only process scan of Invoke-KillDotnet.psm1 on top of the environment cmdlets.
    public static readonly string ProcessParams = EnvironmentParams[..^1] + ""","Get-OctoProcessesUnderFolder":["path"]}""";

    /// <summary>
    ///     The answer of the Get-OctoProcessesUnderFolder run (lane_remove's process check): the JSON array of
    ///     { folder, pid, name, reason } for the script's body. Default: no process.
    /// </summary>
    public Func<string, string> FolderProcesses { get; set; } = _ => "[]";

    /// <summary>Get-OctoTestLock -Json data.</summary>
    public string TestLock { get; set; } = """{"locked":false,"stale":false,"ownerAlive":false,"path":"/state/octo-tools/locks/docker-tests.lock","owner":null}""";

    // What the main octo-tools checkout answers today: no -EventsFile, -feedPath, -repoPaths, -skipKill, lane-scoped kill.
    public const string MainParams =
        """{"Invoke-Build":["repositoryPath","configuration","DryRun","msbuildProperties","Json"],"Invoke-BuildRange":["from","branch","stopServices","msbuildProperties","Json"],"Invoke-BuildAll":["branch","msbuildProperties","DryRun","Json"],"Invoke-KillDotnet":"Json"}""";

    /// <summary>Invoke-OctoTestRun -WhatIf -Json data.</summary>
    public string TestPlan { get; set; } = """{"whatIf":true,"projects":[{"project":"A.Tests","docker":false,"noBuild":true,"buildReason":"upToDate","skip":null}]}""";

    private readonly Lock _lock = new();

    public string Capabilities { get; set; } = WorktreeParams;

    /// <summary>Invoke-BuildRange -WhatIf -Json data.</summary>
    public string RangePlan { get; set; } = """{"whatIf":true,"lane":{"isolated":false},"packageCaches":["/cache"],"repositories":[]}""";

    public string AllPlan { get; set; } = """{"dryRun":true,"lane":{"isolated":false},"packageCachesToPurge":["/cache/meshmakers.x/999.0.0"],"repositories":[]}""";

    /// <summary>Invoke-BuildEnvironment -DryRun -Json data.</summary>
    public string EnvPlan { get; set; } = """{"dryRun":true,"repositories":[]}""";

    public List<string> BuildOrder { get; set; } = [];

    /// <summary>The build call (no probe/plan); default: success.</summary>
    public Func<string, PwshRunOptions, CancellationToken, Task<PwshResult>> Build { get; set; } =
        (body, _, _) => Task.FromResult(Ok(Command(body), """{"success":true,"exitCode":0}"""));

    public List<(string Body, PwshRunOptions Options)> Calls { get; } = [];

    public List<string> BuildCalls
    {
        get
        {
            lock (_lock)
            {
                return Calls.Select(c => Strip(c.Body)).Where(IsBuild).ToList();
            }
        }
    }

    /// <summary>The cmdlet call without the daemon's rootPath prelude.</summary>
    public static string Strip(string body) =>
        body.StartsWith("$global:rootPath", StringComparison.Ordinal) ? body[(body.IndexOf('\n') + 1)..] : body;

    public async Task<PwshResult> RunAsync(string octoToolsPath, string body, PwshRunOptions options, CancellationToken cancellationToken)
    {
        lock (_lock)
        {
            Calls.Add((body, options));
        }

        body = Strip(body);

        if (body.Contains("Get-Command", StringComparison.Ordinal))
        {
            return new PwshResult(0, PwshRunner.Marker + Capabilities + "\n", false, false);
        }

        if (body.Contains("Get-OctoBuildOrder", StringComparison.Ordinal))
        {
            return new PwshResult(0, PwshRunner.Marker + JsonSerializer.Serialize(BuildOrder.Select(n => new { name = n, path = "/x/" + n })) + "\n", false,
                false);
        }

        if (body.StartsWith("Get-OctoTestLock", StringComparison.Ordinal))
        {
            return Ok("Get-OctoTestLock", TestLock);
        }

        if (body.Contains("Get-OctoProcessesUnderFolder -path", StringComparison.Ordinal))
        {
            return new PwshResult(0, PwshRunner.Marker + FolderProcesses(body) + "\n", false, false);
        }

        if (body.Contains("-WhatIf", StringComparison.Ordinal) && body.StartsWith("Invoke-OctoTestRun", StringComparison.Ordinal))
        {
            return Ok("Invoke-OctoTestRun", TestPlan);
        }

        if (body.Contains("-WhatIf", StringComparison.Ordinal))
        {
            return Ok("Invoke-BuildRange", RangePlan);
        }

        if (body.Contains("-DryRun", StringComparison.Ordinal))
        {
            if (body.StartsWith("Invoke-BuildEnvironment", StringComparison.Ordinal))
            {
                return Ok("Invoke-BuildEnvironment", EnvPlan);
            }

            return body.StartsWith("Invoke-BuildAll", StringComparison.Ordinal)
                ? Ok("Invoke-BuildAll", AllPlan)
                : Ok("Invoke-Build", """{"dryRun":true,"isolated":false,"environment":{}}""");
        }

        options.OnStarted?.Invoke(Environment.ProcessId);
        return await Build(body, options, cancellationToken);
    }

    private static bool IsBuild(string body) =>
        !body.Contains("Get-Command", StringComparison.Ordinal) && !body.Contains("Get-OctoBuildOrder", StringComparison.Ordinal) &&
        !body.StartsWith("Get-OctoTestLock", StringComparison.Ordinal) && !body.Contains("Get-OctoProcessesUnderFolder -path", StringComparison.Ordinal) &&
        !body.Contains("-WhatIf", StringComparison.Ordinal) && !body.Contains("-DryRun", StringComparison.Ordinal);

    public static string Command(string body) => body.Split(' ', 2)[0];

    public static PwshResult Ok(string command, string data, int exitCode = 0, string before = "") =>
        new(exitCode, before + $$"""{"schemaVersion":1,"command":"{{command}}","timestamp":"2026-11-09T10:00:00Z","data":{{data}}}""" + "\n", false, false);

    public static string? EventsFile(string body)
    {
        var m = EventsRegex().Match(body);
        return m.Success ? m.Groups[1].Value : null;
    }

    public static void Event(string file, string command, string name, string fields)
    {
        var ts = DateTimeOffset.UtcNow.ToString("O");
        File.AppendAllText(file, $$"""{"schemaVersion":1,"ts":"{{ts}}","command":"{{command}}","event":"{{name}}"{{(fields.Length > 0 ? "," + fields : "")}}}""" + "\n");
    }

    [GeneratedRegex("-EventsFile '([^']+)'")]
    private static partial Regex EventsRegex();
}
