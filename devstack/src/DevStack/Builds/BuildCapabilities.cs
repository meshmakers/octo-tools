using System.Text.Json;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     Which build parameters the octo-tools checkout of the daemon offers. Newer octo-tools add -EventsFile, -repoPaths,
///     -feedPath, -skipKill and the lane-scoped Invoke-KillDotnet; the daemon degrades without them.
/// </summary>
public sealed record BuildCapabilities(
    bool Probed,
    bool BuildEvents,
    bool RangeEvents,
    bool AllEvents,
    bool BuildMsbuildProperties,
    bool RangeMsbuildProperties,
    bool RangeRepoPaths,
    bool RangeFeedPath,
    bool AllSkipKill,
    bool AllDryRun,
    bool KillDotnetLaneScoped,
    string? Error = null)
{
    public static readonly BuildCapabilities None = new(false, false, false, false, false, false, false, false, false, false, false);

    /// <summary>The environment cmdlets (Invoke-BuildEnvironment, New-/Remove-OctoEnvironment); None while octo-tools lacks them.</summary>
    public EnvironmentCapabilities Environments { get; init; } = EnvironmentCapabilities.None;

    /// <summary>-refreshCatalogs of the build cmdlets (octo-tools AB#8831): every CK compile reads the remote catalogs again.</summary>
    public bool RefreshCatalogs { get; init; }

    /// <summary>Parameters asked for; one pwsh call prints them as one marker line.</summary>
    internal static readonly string[] Commands =
        [
            "Invoke-Build", "Invoke-BuildRange", "Invoke-BuildAll", "Invoke-KillDotnet", "Invoke-BuildEnvironment", "New-OctoEnvironment", "Remove-OctoEnvironment",
            "Add-OctoEnvironmentRepo", "Sync-OctoEnvironment", "Get-OctoAffectedRepos", "Get-OctoEnvironment", "Invoke-OctoTestRun", "Get-OctoTestLock",
            "Initialize-OctoEnvironmentPackageCache", "Get-OctoProcessesUnderFolder"
        ];

    /// <summary>The test cmdlets (Invoke-OctoTestRun, Get-OctoTestLock); None while octo-tools lacks them.</summary>
    public TestCapabilities Tests { get; init; } = TestCapabilities.None;

    internal static string ProbeBody() =>
        "$__caps = [ordered]@{}\n" +
        $"foreach ($__name in @({string.Join(",", Commands.Select(PwshRunner.Quote))})) {{\n" +
        "  $__cmd = Get-Command $__name -ErrorAction SilentlyContinue\n" +
        "  $__caps[$__name] = if ($__cmd) { @($__cmd.Parameters.Keys) } else { $null }\n" +
        "}\n" +
        $"Write-Output ('{PwshRunner.Marker}' + ($__caps | ConvertTo-Json -Compress -Depth 4))";

    /// <summary>Reads the marker JSON; a parameter list may arrive as an array, a single string (ConvertTo-Json) or null.</summary>
    internal static BuildCapabilities Parse(string output)
    {
        JsonNode? node;
        try
        {
            node = PwshRunner.ExtractMarker(output);
        }
        catch (JsonException e)
        {
            return None with { Error = $"capability probe returned invalid JSON: {e.Message}" };
        }

        if (node is not JsonObject obj)
        {
            return None with { Error = "capability probe printed no result; is pwsh on PATH and octoToolsPath right? " + PwshRunner.Tail(output, 5) };
        }

        HashSet<string>? Params(string command)
        {
            if (obj[command] is null)
            {
                return null; // the cmdlet does not exist
            }

            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            switch (obj[command])
            {
                case JsonArray array:
                    foreach (var item in array)
                    {
                        if (item?.GetValueKind() == JsonValueKind.String)
                        {
                            set.Add(item.GetValue<string>());
                        }
                    }

                    break;
                case JsonValue value when value.GetValueKind() == JsonValueKind.String:
                    set.Add(value.GetValue<string>());
                    break;
            }

            return set;
        }

        var build = Params("Invoke-Build") ?? [];
        var range = Params("Invoke-BuildRange") ?? [];
        var all = Params("Invoke-BuildAll") ?? [];
        var kill = Params("Invoke-KillDotnet") ?? [];
        var addRepo = Params("Add-OctoEnvironmentRepo");
        var affected = Params("Get-OctoAffectedRepos");
        var environments = EnvironmentCapabilities.From(Params("Invoke-BuildEnvironment"), Params("New-OctoEnvironment"), Params("Remove-OctoEnvironment")) with
        {
            AddRepo = addRepo?.Contains("env") == true,
            AddRepoPath = addRepo?.Contains("path") == true,
            AddRepoInPlace = addRepo?.Contains("inPlace") == true,
            AddRepoRole = addRepo?.Contains("role") == true,
            AddRepoAddAffected = addRepo?.Contains("addAffected") == true,
            Sync = Params("Sync-OctoEnvironment")?.Contains("env") == true,
            Affected = affected?.Contains("env") == true,
            AffectedTarget = affected?.Contains("target") == true,
            Get = Params("Get-OctoEnvironment")?.Contains("env") == true,
            SkipPackageCacheSeed = Params("New-OctoEnvironment")?.Contains("skipPackageCacheSeed") == true,
            SeedPackageCache = Params("Initialize-OctoEnvironmentPackageCache")?.Contains("env") == true,
            ProcessesUnderFolder = Params("Get-OctoProcessesUnderFolder")?.Contains("path") == true
        };
        return new BuildCapabilities(true,
            build.Contains("EventsFile"), range.Contains("EventsFile"), all.Contains("EventsFile"),
            build.Contains("msbuildProperties"), range.Contains("msbuildProperties"),
            range.Contains("repoPaths"), range.Contains("feedPath"),
            all.Contains("skipKill"), all.Contains("DryRun"),
            kill.Contains("branchRootPath"))
        {
            RefreshCatalogs = build.Contains("refreshCatalogs") && range.Contains("refreshCatalogs") && all.Contains("refreshCatalogs") &&
                              Params("Invoke-BuildEnvironment")?.Contains("refreshCatalogs") != false,
            Environments = environments, Tests = TestCapabilities.From(Params("Invoke-OctoTestRun"), Params("Get-OctoTestLock")) };
    }

    /// <summary>What is missing, in words, for build_plan / job_status notes.</summary>
    public IReadOnlyList<string> Missing()
    {
        if (!Probed)
        {
            return [Error ?? "octo-tools capabilities unknown"];
        }

        var missing = new List<string>();
        if (!BuildEvents || !RangeEvents || !AllEvents)
        {
            missing.Add("-EventsFile (progress is read from the repos' Invoke-Build.log instead)");
        }

        if (!RangeFeedPath)
        {
            missing.Add("Invoke-BuildRange -feedPath (packages=private is refused)");
        }

        if (!RangeRepoPaths)
        {
            missing.Add("Invoke-BuildRange -repoPaths (worktrees cannot take part in a range build)");
        }

        if (!KillDotnetLaneScoped || !AllSkipKill)
        {
            missing.Add("Invoke-KillDotnet -branchRootPath / Invoke-BuildAll -skipKill (kind=all is refused on Windows without them)");
        }

        missing.AddRange(Environments.Missing());

        return missing;
    }
}

/// <summary>Caches the capabilities per octo-tools path (10 min; a failed probe 1 min) so a merged octo-tools is picked up.</summary>
public sealed class BuildCapabilityCache(IPwshRunner runner, TimeProvider? time = null)
{
    private static readonly TimeSpan Ttl = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan FailedTtl = TimeSpan.FromMinutes(1);
    private readonly Dictionary<string, (DateTimeOffset At, BuildCapabilities Caps)> _cache = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly TimeProvider _time = time ?? TimeProvider.System;

    public async Task<BuildCapabilities> GetAsync(string octoToolsPath, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var now = _time.GetUtcNow();
            if (_cache.TryGetValue(octoToolsPath, out var hit) && now - hit.At < (hit.Caps.Probed ? Ttl : FailedTtl))
            {
                return hit.Caps;
            }

            BuildCapabilities caps;
            try
            {
                var result = await runner.RunAsync(octoToolsPath, BuildCapabilities.ProbeBody(), new PwshRunOptions { Timeout = TimeSpan.FromMinutes(1) },
                    cancellationToken);
                caps = BuildCapabilities.Parse(result.Output);
            }
            catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException or InvalidOperationException)
            {
                caps = BuildCapabilities.None with { Error = $"pwsh could not be started: {e.Message}" };
            }

            _cache[octoToolsPath] = (now, caps);
            return caps;
        }
        finally
        {
            _gate.Release();
        }
    }
}

/// <summary>
///     What the octo-tools environment cmdlets offer. A missing cmdlet refuses its tool with "octo-tools too old" instead of a
///     pwsh error. Agreed signatures (AB#8700): New-OctoEnvironment -env -repos [-workItem] [-branchName] [-owner]
///     [-addAffected] -Json, Remove-OctoEnvironment -env -Json (no -force: it refuses dirty or unpushed worktrees),
///     Invoke-BuildEnvironment -env [-syncMain] [-verifyTests|-includeTests] [-EventsFile] [-DryRun] -Json. The name and repo
///     parameters are still probed (-env or -name, -repos or -repo).
/// </summary>
public sealed record EnvironmentCapabilities(
    bool Build,
    bool BuildEvents,
    bool BuildDryRun,
    bool BuildSyncMain,
    bool BuildVerifyTests,
    bool BuildIncludeTests,
    bool BuildConfiguration,
    string? CreateNameParameter,
    string? CreateReposParameter,
    bool CreateWorkItem,
    bool CreateOwner,
    bool CreateBranchName,
    bool CreateAddAffected,
    string? RemoveNameParameter)
{
    public static readonly EnvironmentCapabilities None = new(false, false, false, false, false, false, false, null, null, false, false, false, false, null);

    public const string TooOld = "the octo-tools checkout of the daemon is too old for lanes (feature environments): update octo-tools (git pull in its checkout)";

    /// <summary>Why an environment cmdlet is not available: the probe failed (pwsh, octoToolsPath), or octo-tools is too old.</summary>
    public static string Unavailable(BuildCapabilities caps, string cmdlet) =>
        caps.Probed
            ? $"{cmdlet}: {TooOld}"
            : $"{cmdlet}: the octo-tools capability probe failed ({caps.Error ?? "unknown error"})";

    /// <summary>Add-OctoEnvironmentRepo -env -repo [-role] [-addAffected] | -path [-inPlace].</summary>
    public bool AddRepo { get; init; }

    public bool AddRepoPath { get; init; }
    public bool AddRepoInPlace { get; init; }
    public bool AddRepoRole { get; init; }
    public bool AddRepoAddAffected { get; init; }

    /// <summary>Sync-OctoEnvironment -env.</summary>
    public bool Sync { get; init; }

    /// <summary>Get-OctoAffectedRepos -env [-target].</summary>
    public bool Affected { get; init; }

    public bool AffectedTarget { get; init; }

    /// <summary>Get-OctoEnvironment -env -Json (per repo: exists, dirty, unpushed).</summary>
    public bool Get { get; init; }

    /// <summary>New-OctoEnvironment -skipPackageCacheSeed (octo-tools AB#8831: a new environment's package cache is filled from a local cache).</summary>
    public bool SkipPackageCacheSeed { get; init; }

    /// <summary>Initialize-OctoEnvironmentPackageCache -env: fill or top up the package cache of an existing environment.</summary>
    public bool SeedPackageCache { get; init; }

    /// <summary>
    ///     Get-OctoProcessesUnderFolder -path (Invoke-KillDotnet.psm1, list-only): lane_remove asks it which processes hold files
    ///     below the lane before Remove-OctoEnvironment deletes it.
    /// </summary>
    public bool ProcessesUnderFolder { get; init; }

    /// <summary>Invoke-BuildEnvironment -repos / -skip / -buildUnchanged (AB#8814: only what changed is built).</summary>
    public bool BuildRepos { get; init; }

    public bool BuildSkip { get; init; }
    public bool BuildUnchanged { get; init; }

    /// <summary>Invoke-BuildEnvironment -maxParallel (AB#8814: independent repos of an environment build at the same time).</summary>
    public bool BuildMaxParallel { get; init; }

    /// <summary>Why a selection parameter of an environment build is not available.</summary>
    public const string SelectionTooOld =
        "the octo-tools checkout of the daemon has no Invoke-BuildEnvironment -repos / -skip / -buildUnchanged: they come with octo-tools AB#8814 " +
        "(a lane build that builds only what changed)";

    public bool Create => CreateNameParameter != null;
    public bool Remove => RemoveNameParameter != null;

    internal static EnvironmentCapabilities From(HashSet<string>? build, HashSet<string>? create, HashSet<string>? remove)
    {
        static string? First(HashSet<string>? set, params string[] names) => set == null ? null : names.FirstOrDefault(set.Contains);

        return new EnvironmentCapabilities(
            build != null && build.Contains("env"),
            build?.Contains("EventsFile") == true,
            build?.Contains("DryRun") == true,
            build?.Contains("syncMain") == true,
            build?.Contains("verifyTests") == true,
            build?.Contains("includeTests") == true,
            build?.Contains("configuration") == true,
            First(create, "env", "name"),
            First(create, "repos", "repo"),
            create?.Contains("workItem") == true,
            create?.Contains("owner") == true,
            create?.Contains("branchName") == true,
            create?.Contains("addAffected") == true,
            First(remove, "env", "name"))
        {
            BuildRepos = build?.Contains("repos") == true,
            BuildSkip = build?.Contains("skip") == true,
            BuildUnchanged = build?.Contains("buildUnchanged") == true,
            BuildMaxParallel = build?.Contains("maxParallel") == true
        };
    }

    /// <summary>What is missing, in words.</summary>
    public IEnumerable<string> Missing()
    {
        if (!Build)
        {
            yield return "Invoke-BuildEnvironment -env (lane_build is refused)";
        }
        else if (!BuildEvents)
        {
            yield return "Invoke-BuildEnvironment -EventsFile (lane build progress is read from the repos' Invoke-Build.log)";
        }

        if (!Create || !Remove)
        {
            yield return "New-OctoEnvironment / Remove-OctoEnvironment (lane_create / lane_remove are refused)";
        }
    }
}

/// <summary>
///     What the octo-tools test cmdlets offer (AB#8813): Invoke-OctoTestRun (-env | -branch) -repo [-project] [-filter]
///     [-rerunFailed] [-EventsFile] -Json and Get-OctoTestLock -Json. Without them base_test / lane_test are refused with the reason.
/// </summary>
public sealed record TestCapabilities(bool Run, bool Events, bool RerunFailed, bool Lock, bool IncludePassed = false, bool DockerCheck = false)
{
    public static readonly TestCapabilities None = new(false, false, false, false);

    internal static TestCapabilities From(HashSet<string>? run, HashSet<string>? testLock) =>
        new(run != null && run.Contains("repo"), run?.Contains("EventsFile") == true, run?.Contains("rerunFailed") == true, testLock != null,
            run?.Contains("includePassed") == true, run?.Contains("dockerCheck") == true);

    /// <summary>Why test runs are not available: the probe failed, or the octo-tools checkout has no Invoke-OctoTestRun yet.</summary>
    public static string Unavailable(BuildCapabilities caps, string octoTools) =>
        caps.Probed
            ? $"The octo-tools checkout of the daemon ({octoTools}) has no Invoke-OctoTestRun: test runs come with octo-tools AB#8813 (PR #39, modules/OctoTests.psm1). " +
              "Update that checkout; the daemon looks again within 10 minutes."
            : $"Invoke-OctoTestRun: the octo-tools capability probe failed ({caps.Error ?? "unknown error"})";
}
