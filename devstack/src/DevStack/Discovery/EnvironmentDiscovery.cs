using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Discovery;

/// <summary>
///     One repo of an environment manifest. role: feature (a branch of its own) | consumer (detached at the base commit).
///     baseRef: the ref the worktree started from (origin/main, HEAD, or the branch it adopted).
/// </summary>
public sealed record EnvironmentRepo(
    string Name,
    string Role,
    string Path,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Branch,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? BaseCommit,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? BaseRef = null);

/// <summary>
///     <c>&lt;rootPath&gt;/wt-&lt;env&gt;/.octo/environment.json</c>, schemaVersion 1. Written only by octo-tools
///     (New-OctoEnvironment, Add-OctoEnvironmentRepo); the daemon reads it.
/// </summary>
public sealed record EnvironmentManifest(
    int SchemaVersion,
    string Name,
    string? WorkItem,
    string Base,
    DateTimeOffset? Created,
    string? Owner,
    IReadOnlyList<EnvironmentRepo> Repos,
    string? Slot);

/// <summary>An environment as the daemon sees it. Problem is set (and Manifest may be null) when the manifest cannot be used.</summary>
public sealed record EnvironmentInfo(
    string Name,
    string Path,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    EnvironmentManifest? Manifest,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? BasePath,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Problem)
{
    /// <summary>The stack slot the environment runs in: the manifest's slot, else its name.</summary>
    public string Slot => Manifest?.Slot is { Length: > 0 } slot ? slot : Name;

    /// <summary>The environment's repos by name with their folders (manifest paths).</summary>
    public IReadOnlyDictionary<string, string> RepoPaths() =>
        (Manifest?.Repos ?? []).GroupBy(r => r.Name, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First().Path, StringComparer.OrdinalIgnoreCase);

    /// <summary>The lease holder of the environment's slot: the environment itself, so every session of the feature shares it.</summary>
    public string LeaseOwner => EnvironmentDiscovery.LeaseOwnerOf(Name);
}

/// <summary>
///     Finds the feature environments: &lt;rootPath&gt;/wt-&lt;env&gt; folders (octo-claude-pm lanes) that hold a manifest. A wt-*
///     folder without one is a plain lane folder or flat worktree, not an environment.
/// </summary>
public static class EnvironmentDiscovery
{
    /// <summary>The folder of an environment is &lt;rootPath&gt;/&lt;FolderPrefix&gt;&lt;env&gt;.</summary>
    public const string FolderPrefix = "wt-";

    public static string FolderOf(string rootPath, string env) => System.IO.Path.Combine(rootPath, FolderPrefix + env);
    public const int SchemaVersion = 1;
    private const string LeasePrefix = "lane:";

    /// <summary>The lease holder prefix of a lane before the lane vocabulary (a lease restored from an older state file).</summary>
    public const string LegacyLeasePrefix = "env:";

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { ReadCommentHandling = JsonCommentHandling.Skip };

    /// <summary>The lease holder of a lane's stack: "lane:&lt;name&gt;", shared by every session of the lane.</summary>
    public static string LeaseOwnerOf(string env) => LeasePrefix + env;

    /// <summary>A lease owner as it is named now: a lane's older "env:&lt;name&gt;" becomes "lane:&lt;name&gt;", every other owner stays.</summary>
    public static string CurrentLeaseOwner(string owner) =>
        owner.StartsWith(LegacyLeasePrefix, StringComparison.Ordinal) ? LeaseOwnerOf(owner[LegacyLeasePrefix.Length..]) : owner;

    /// <summary>The lane a lease owner stands for ("lane:&lt;name&gt;", also the older "env:&lt;name&gt;"), or null.</summary>
    public static string? EnvironmentOfLeaseOwner(string? owner) =>
        owner == null ? null
        : owner.StartsWith(LeasePrefix, StringComparison.Ordinal) ? owner[LeasePrefix.Length..]
        : owner.StartsWith(LegacyLeasePrefix, StringComparison.Ordinal) ? owner[LegacyLeasePrefix.Length..]
        : null;

    public static string ManifestPath(string environmentFolder) => System.IO.Path.Combine(environmentFolder, ".octo", "environment.json");

    /// <summary>Every &lt;rootPath&gt;/wt-* folder that holds a manifest, by name.</summary>
    public static List<EnvironmentInfo> Discover(DevStackConfig config)
    {
        var root = ServicePlanner.RootPath(config);
        if (!Directory.Exists(root))
        {
            return [];
        }

        string[] dirs;
        try
        {
            dirs = Directory.GetDirectories(root, FolderPrefix + "*");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }

        return dirs.Where(d => File.Exists(ManifestPath(d)))
            .Select(d => Read(d, root))
            .OrderBy(e => e.Name, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>An environment by name; throws with the known names when there is none or its manifest is unusable.</summary>
    public static EnvironmentInfo Find(DevStackConfig config, string name)
    {
        var all = Discover(config);
        var env = all.FirstOrDefault(e => string.Equals(e.Name, name, StringComparison.Ordinal));
        if (env == null)
        {
            throw new InvalidOperationException(
                $"Unknown lane '{name}' (looked for {ManifestPath(FolderOf(ServicePlanner.RootPath(config), name))}). " +
                $"Known: {(all.Count == 0 ? "none" : string.Join(", ", all.Select(e => e.Name)))}; lane_create creates one (octo-tools: New-OctoEnvironment).");
        }

        if (env.Problem != null)
        {
            throw new InvalidOperationException($"Lane '{name}' cannot be used: {env.Problem}");
        }

        return env;
    }

    /// <summary>The environment whose folder is <paramref name="checkout"/> (a lane with a manifest), or null for a plain lane.</summary>
    public static EnvironmentInfo? OfCheckout(string checkout, string rootPath)
    {
        return File.Exists(ManifestPath(checkout)) ? Read(checkout, rootPath) : null;
    }

    /// <summary>Reads and checks one manifest; never throws (a broken manifest is reported in Problem).</summary>
    public static EnvironmentInfo Read(string folder, string rootPath)
    {
        var dirName = System.IO.Path.GetFileName(folder.TrimEnd(System.IO.Path.DirectorySeparatorChar, '/'));
        // wt-<env>; a folder outside the convention (an environment given as checkout) keeps its own name.
        var folderName = dirName.StartsWith(FolderPrefix, StringComparison.Ordinal) ? dirName[FolderPrefix.Length..] : dirName;
        EnvironmentManifest? manifest;
        try
        {
            manifest = JsonSerializer.Deserialize<EnvironmentManifest>(File.ReadAllText(ManifestPath(folder)), Json);
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return new EnvironmentInfo(folderName, folder, null, null, $"{ManifestPath(folder)} is not readable: {e.Message}");
        }

        if (manifest == null)
        {
            return new EnvironmentInfo(folderName, folder, null, null, $"{ManifestPath(folder)} is empty.");
        }

        if (manifest.SchemaVersion != SchemaVersion)
        {
            return new EnvironmentInfo(folderName, folder, manifest, null,
                $"schemaVersion {manifest.SchemaVersion} is not supported (octo-devstack reads {SchemaVersion}); update octo-devstack or octo-tools.");
        }

        // A repo's path may lie outside the environment folder (adopted in place: <repo>/.claude/worktrees/<x>, a flat
        // wt-<lane>-<repo>); a relative path is relative to the environment folder.
        manifest = manifest with
        {
            Repos = (manifest.Repos ?? []).Select(r => r with
            {
                Path = string.IsNullOrWhiteSpace(r.Path)
                    ? System.IO.Path.Combine(folder, r.Name)
                    : System.IO.Path.GetFullPath(System.IO.Path.IsPathRooted(r.Path) ? r.Path : System.IO.Path.Combine(folder, r.Path)).TrimEnd(System.IO.Path.DirectorySeparatorChar)
            }).ToList()
        };
        if (!string.Equals(manifest.Name, folderName, StringComparison.Ordinal))
        {
            return new EnvironmentInfo(folderName, folder, manifest, null, $"the manifest names '{manifest.Name}', but the folder is '{dirName}'.");
        }

        var slot = manifest.Slot is { Length: > 0 } s ? s : manifest.Name;
        if (slot == SlotInfo.DefaultName)
        {
            return new EnvironmentInfo(folderName, folder, manifest, null, "a lane cannot run in the shared stack's slot (default); rename it.");
        }

        if (!SlotRules.IsValidName(slot))
        {
            return new EnvironmentInfo(folderName, folder, manifest, null, $"its slot name is not usable: {SlotRules.NameRule(slot)}");
        }

        if (string.IsNullOrWhiteSpace(manifest.Base))
        {
            return new EnvironmentInfo(folderName, folder, manifest, null, "the manifest names no base lane.");
        }

        var basePath = System.IO.Path.IsPathRooted(manifest.Base) ? manifest.Base : System.IO.Path.GetFullPath(System.IO.Path.Combine(rootPath, manifest.Base));
        basePath = basePath.TrimEnd(System.IO.Path.DirectorySeparatorChar);
        return Directory.Exists(basePath)
            ? new EnvironmentInfo(folderName, folder, manifest, basePath, null)
            : new EnvironmentInfo(folderName, folder, manifest, null, $"its base lane {basePath} does not exist.");
    }
}
