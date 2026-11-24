using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Discovery;

public sealed record WorktreeInfo(string Path, string RelativeToBaseLane, string Repo, string? Branch, IReadOnlyList<string> Services, IReadOnlyList<string> BuiltConfigurations);

public sealed record CheckoutInfo(string Path, string RelativeToRoot,
    [property: System.Text.Json.Serialization.JsonPropertyName("isBaseLane")] bool IsDefault, IReadOnlyList<WorktreeInfo> Worktrees)
{
    /// <summary>The lane this folder is (&lt;rootPath&gt;/wt-&lt;lane&gt;, octo-tools: feature environment), else null (a base lane folder).</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    [System.Text.Json.Serialization.JsonPropertyName("lane")]
    public string? Environment { get; init; }

    /// <summary>For an environment: its base lane, where services of repos the environment does not hold run from.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Base { get; init; }
}

/// <summary>Finds lanes (folders holding Octo.User.props) and the git worktrees in and next to them.</summary>
public static class CheckoutDiscovery
{
    private static readonly string[] Configurations = ["Release", "DebugL", "Debug"];

    public static List<CheckoutInfo> Discover(DevStackConfig config)
    {
        var root = ServicePlanner.RootPath(config);
        string? defaultCheckout = null;
        try
        {
            defaultCheckout = ServicePlanner.CreateContext(config, null, null).Checkout;
        }
        catch (InvalidOperationException)
        {
            // Reported as missing below.
        }

        var lanes = new List<string>();
        // Three folder levels below rootPath (rootPath/branches/main is level two).
        foreach (var candidate in Enumerate(root, depth: 2))
        {
            if (File.Exists(Path.Combine(candidate, "Octo.User.props")))
            {
                lanes.Add(candidate);
            }
        }

        if (defaultCheckout != null && !lanes.Contains(defaultCheckout))
        {
            lanes.Insert(0, defaultCheckout);
        }

        // Environments are lanes too (their Octo.User.props isolates them); list every one that has a manifest.
        var environments = EnvironmentDiscovery.Discover(config);
        foreach (var env in environments.Where(e => !lanes.Any(l => Common.PathScope.SamePath(l, e.Path))))
        {
            lanes.Add(env.Path);
        }

        return lanes.Select(lane =>
        {
            var env = environments.FirstOrDefault(e => Common.PathScope.SamePath(e.Path, lane));
            return new CheckoutInfo(lane, Path.GetRelativePath(root, lane), lane == defaultCheckout, Worktrees(config, lane))
            {
                Environment = env?.Name,
                Base = env?.BasePath
            };
        }).ToList();
    }

    private static List<WorktreeInfo> Worktrees(DevStackConfig config, string lane)
    {
        var result = new List<WorktreeInfo>();
        var candidates = new List<string>();
        foreach (var dir in SafeDirectories(lane))
        {
            candidates.Add(dir);
            var claudeWorktrees = Path.Combine(dir, ".claude", "worktrees");
            if (Directory.Exists(claudeWorktrees))
            {
                candidates.AddRange(SafeDirectories(claudeWorktrees));
            }
        }

        foreach (var dir in candidates)
        {
            var gitFile = Path.Combine(dir, ".git");
            if (!File.Exists(gitFile))
            {
                continue; // a normal clone has a .git folder; a worktree has a .git file
            }

            var (repo, branch) = ReadWorktree(gitFile);
            if (repo == null)
            {
                continue;
            }

            var services = config.Services.Where(s => string.Equals(s.Value.Repo, repo, StringComparison.OrdinalIgnoreCase)).Select(s => s.Key).ToList();
            var built = Configurations.Where(c => Directory.Exists(Path.Combine(dir, "bin", c))).ToList();
            result.Add(new WorktreeInfo(dir, Path.GetRelativePath(lane, dir), repo, branch, services, built));
        }

        return result;
    }

    /// <summary>Reads "gitdir: /x/octo-foo/.git/worktrees/wt-1" and its HEAD.</summary>
    internal static (string? Repo, string? Branch) ReadWorktree(string gitFile)
    {
        string content;
        try
        {
            content = File.ReadAllText(gitFile).Trim();
        }
        catch (IOException)
        {
            return (null, null);
        }

        if (!content.StartsWith("gitdir:", StringComparison.Ordinal))
        {
            return (null, null);
        }

        var gitDir = content["gitdir:".Length..].Trim();
        if (!Path.IsPathRooted(gitDir))
        {
            gitDir = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(gitFile)!, gitDir));
        }

        // <repo>/.git/worktrees/<name>
        var dotGit = Path.GetDirectoryName(Path.GetDirectoryName(gitDir));
        var repoDir = dotGit == null ? null : Path.GetDirectoryName(dotGit);
        if (repoDir == null || Path.GetFileName(dotGit) != ".git")
        {
            return (null, null);
        }

        string? branch = null;
        var head = Path.Combine(gitDir, "HEAD");
        if (File.Exists(head))
        {
            var text = File.ReadAllText(head).Trim();
            branch = text.StartsWith("ref: refs/heads/", StringComparison.Ordinal) ? text["ref: refs/heads/".Length..] : $"(detached {text[..Math.Min(8, text.Length)]})";
        }

        return (Path.GetFileName(repoDir), branch);
    }

    private static IEnumerable<string> Enumerate(string root, int depth)
    {
        if (depth < 0 || !Directory.Exists(root))
        {
            yield break;
        }

        foreach (var dir in SafeDirectories(root))
        {
            var name = Path.GetFileName(dir);
            if (name.StartsWith('.') || name is "node_modules" or "bin" or "obj" || name.StartsWith("octo-", StringComparison.Ordinal) ||
                name.StartsWith("mm-", StringComparison.Ordinal))
            {
                continue;
            }

            yield return dir;
            foreach (var child in Enumerate(dir, depth - 1))
            {
                yield return child;
            }
        }
    }

    private static IEnumerable<string> SafeDirectories(string path)
    {
        try
        {
            return Directory.GetDirectories(path);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException)
        {
            return [];
        }
    }
}
