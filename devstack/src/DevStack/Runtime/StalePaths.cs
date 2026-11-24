using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>A path the daemon or a lane still has on record that no longer exists: where it is recorded, and the path.</summary>
public sealed record StalePath(string Where, string Path);

/// <summary>
///     The checkout paths still on record that no longer exist (AB#9555): after a checkout moved (e.g. to
///     D:\source\Octo\branches\main) the daemon's state keeps the base lane and repository folders of the stacks it adopted,
///     and a lane's manifest keeps the folders of its repos. setup_check lists them with the way out, so a moved checkout
///     shows as what it is instead of an unexplained failure.
/// </summary>
public static class StalePaths
{
    public static List<StalePath> Find(DevStackConfig config, PersistedState state)
    {
        var result = new List<StalePath>();
        var root = ServicePlanner.RootPath(config);
        foreach (var (slot, stack) in state.StacksBySlot().OrderBy(s => s.Key, StringComparer.Ordinal))
        {
            var label = slot == SlotInfo.DefaultName ? "the shared stack" : $"stack '{slot}'";
            if (stack.Checkout.Length > 0 && !Directory.Exists(Full(stack.Checkout, root)))
            {
                result.Add(new StalePath($"base lane of {label} in the daemon's state", Full(stack.Checkout, root)));
            }

            foreach (var service in stack.Services.Concat(stack.StoppedForBuild))
            {
                if (service.RepoPath.Length > 0 && !Directory.Exists(service.RepoPath))
                {
                    result.Add(new StalePath($"repository of {service.Name} ({label}) in the daemon's state", service.RepoPath));
                }
            }
        }

        foreach (var lane in EnvironmentDiscovery.Discover(config))
        {
            foreach (var repo in lane.Manifest?.Repos ?? [])
            {
                if (!string.IsNullOrWhiteSpace(repo.Path) && !Directory.Exists(repo.Path))
                {
                    result.Add(new StalePath($"repository {repo.Name} in the manifest of lane '{lane.Name}'", repo.Path));
                }
            }
        }

        return result.DistinctBy(p => (p.Where, p.Path)).ToList();
    }

    private static string Full(string path, string root) =>
        System.IO.Path.IsPathFullyQualified(path) || root.Length == 0 ? path : System.IO.Path.GetFullPath(System.IO.Path.Combine(root, path));

    /// <summary>The setup_check line: ok, or warn with every stale path and what to do about it.</summary>
    public static SetupItem Item(IReadOnlyList<StalePath> stale) => stale.Count == 0
        ? new SetupItem("stale paths", "ok", "every checkout and repository folder on record exists", null)
        : new SetupItem("stale paths", "warn",
            $"{stale.Count} path(s) on record no longer exist (a checkout that moved?): " + string.Join("; ", stale.Take(10).Select(s => $"{s.Where}: {s.Path}")) +
            (stale.Count > 10 ? $"; and {stale.Count - 10} more" : ""),
            "a stack recorded with an old path: stack_stop it (or restart the daemon) and start it again from the new base lane; a lane whose repos moved: " +
            "lane_remove it, or fix its manifest with octo-tools (Add-OctoEnvironmentRepo -path)");
}
