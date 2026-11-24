using Meshmakers.Octo.DevStack.Discovery;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>
///     overrides.&lt;service&gt;.source = "lane:&lt;name&gt;": the service runs from the lane's worktree of its repo - the path
///     of that repo in the lane's manifest (repos[].path, which may lie outside the lane folder). UC-A: a lane's build of one
///     service runs in the shared stack in place of the base lane's.
/// </summary>
public static class LaneSource
{
    public const string Prefix = "lane:";

    /// <summary><see cref="RunsFrom"/> of a service in the base lane its stack runs from.</summary>
    public const string BaseLane = "base lane";

    public static bool Is(string? source) => source != null && source.StartsWith(Prefix, StringComparison.Ordinal);

    /// <summary>
    ///     Where a service runs from, in the words of the tools: "lane:&lt;name&gt;" when <paramref name="repoPath"/> is a lane's
    ///     worktree of a repo (its manifest's repos[].path: a lane stack's own repos, or a lane's build in the shared stack,
    ///     UC-A), "base lane" when it lies in <paramref name="baseLane"/> (the base lane the stack runs from), else the folder
    ///     itself (a source override with a path, a plain worktree). Lanes with an unusable manifest are not looked at.
    /// </summary>
    public static string RunsFrom(string repoPath, string? baseLane, IEnumerable<EnvironmentInfo> lanes)
    {
        if (string.IsNullOrWhiteSpace(repoPath))
        {
            return repoPath;
        }

        foreach (var lane in lanes.Where(l => l.Problem == null))
        {
            if (lane.RepoPaths().Values.Any(path => Common.PathScope.SamePath(path, repoPath)))
            {
                return Prefix + lane.Name;
            }
        }

        return baseLane != null && Common.PathScope.IsUnder(repoPath, baseLane) ? BaseLane : repoPath;
    }

    /// <summary>
    ///     The folder of <paramref name="repo"/> (the repo of <paramref name="service"/>) in the lane <paramref name="source"/>
    ///     names. Refused for an unknown lane, and for a lane that does not hold the repo - naming the lanes that do.
    /// </summary>
    public static string Resolve(DevStackConfig config, string service, string repo, string source)
    {
        var name = source[Prefix.Length..].Trim();
        if (name.Length == 0)
        {
            throw new InvalidOperationException($"The source of service '{service}' is '{source}': name the lane, e.g. 'lane:ab8625-enum-null' (lane_list).");
        }

        var lane = EnvironmentDiscovery.Find(config, name);
        if (lane.RepoPaths().TryGetValue(repo, out var path))
        {
            if (!Directory.Exists(path))
            {
                throw new InvalidOperationException($"Lane '{lane.Name}' names {path} as its worktree of {repo} (service '{service}'), but the folder does not exist.");
            }

            return path;
        }

        var holders = EnvironmentDiscovery.Discover(config).Where(e => e.Problem == null && e.RepoPaths().ContainsKey(repo)).Select(e => e.Name).ToList();
        throw new InvalidOperationException(
            $"Lane '{lane.Name}' does not hold {repo}, the repo of service '{service}' (it holds {(lane.RepoPaths().Count == 0 ? "no repo" : string.Join(", ", lane.RepoPaths().Keys.Order(StringComparer.Ordinal)))}). " +
            (holders.Count == 0
                ? $"No lane holds {repo}; add it with lane_add_repo(lane=\"{lane.Name}\", repo=\"{repo}\") and build it with lane_build."
                : $"Lanes that hold {repo}: {string.Join(", ", holders)}."));
    }
}
