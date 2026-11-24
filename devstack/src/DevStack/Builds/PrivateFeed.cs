using System.Security.Cryptography;
using System.Text.Json;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     The per-session feed of packages=private. NuGet does not prefer one source over another: with the same id and version
///     in the private feed and in &lt;lane&gt;/nuget a restore takes whichever answers first. So the private feed is the ONLY
///     local source of a private build, and it is kept a superset of the lane feed: before every private step the lane's
///     packages are mirrored into it. A mirrored file is refreshed when the lane's copy changes; a package built into the
///     feed (its file differs from what was mirrored) is never overwritten.
/// </summary>
public static partial class PrivateFeed
{
    private const string ManifestName = ".mirrored.json";

    public sealed record SyncResult(int Copied, int Refreshed, int KeptPrivate);

    public static SyncResult Sync(string feed, string laneNuget)
    {
        Directory.CreateDirectory(feed);
        var manifestPath = Path.Combine(feed, ManifestName);
        var manifest = ReadManifest(manifestPath);
        int copied = 0, refreshed = 0, kept = 0;
        if (Directory.Exists(laneNuget))
        {
            foreach (var source in Directory.EnumerateFiles(laneNuget, "*.nupkg"))
            {
                var name = Path.GetFileName(source);
                var target = Path.Combine(feed, name);
                var laneHash = Hash(source);
                if (!File.Exists(target))
                {
                    File.Copy(source, target);
                    manifest[name] = laneHash;
                    copied++;
                    continue;
                }

                var feedHash = Hash(target);
                if (manifest.TryGetValue(name, out var mirrored) && mirrored == feedHash)
                {
                    if (feedHash != laneHash)
                    {
                        File.Copy(source, target, overwrite: true);
                        manifest[name] = laneHash;
                        refreshed++;
                    }
                }
                else
                {
                    manifest.Remove(name); // built privately: it wins over the lane's package
                    kept++;
                }
            }
        }

        File.WriteAllText(manifestPath, JsonSerializer.Serialize(manifest));
        return new SyncResult(copied, refreshed, kept);
    }

    /// <summary>
    ///     Removes extracted packages from the private cache whose .nupkg differs from the feed's copy. NuGet never
    ///     re-extracts a version it already has, and every local build is 999.0.0, so a rebuilt package would otherwise stay
    ///     invisible to its consumers (Invoke-BuildRange -feedPath leaves cache purging to the caller).
    /// </summary>
    public static List<string> PurgeStaleCache(string feed, string cache)
    {
        var purged = new List<string>();
        if (!Directory.Exists(feed) || !Directory.Exists(cache))
        {
            return purged;
        }

        foreach (var file in Directory.EnumerateFiles(feed, "*.nupkg"))
        {
            var match = PackageFile().Match(Path.GetFileName(file));
            if (!match.Success)
            {
                continue;
            }

            var id = match.Groups["id"].Value.ToLowerInvariant();
            var version = match.Groups["version"].Value.ToLowerInvariant();
            var folder = Path.Combine(cache, id, version);
            var cached = Path.Combine(folder, $"{id}.{version}.nupkg");
            if (Directory.Exists(folder) && (!File.Exists(cached) || Hash(cached) != Hash(file)))
            {
                Directory.Delete(folder, recursive: true);
                purged.Add($"{id}/{version}");
            }
        }

        return purged;
    }

    [System.Text.RegularExpressions.GeneratedRegex(@"^(?<id>.+?)\.(?<version>\d+\.\d+\.\d+(?:[-+][^/]*)?)\.nupkg$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)]
    private static partial System.Text.RegularExpressions.Regex PackageFile();

    /// <summary>Packages in the feed that were built into it (not mirrored from the lane).</summary>
    public static List<string> OwnPackages(string feed)
    {
        if (!Directory.Exists(feed))
        {
            return [];
        }

        var manifest = ReadManifest(Path.Combine(feed, ManifestName));
        return Directory.EnumerateFiles(feed, "*.nupkg")
            .Where(f => !manifest.TryGetValue(Path.GetFileName(f), out var mirrored) || mirrored != Hash(f))
            .Select(Path.GetFileName).Select(f => f!).OrderBy(f => f).ToList();
    }

    private static Dictionary<string, string> ReadManifest(string path)
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? new() : new();
        }
        catch (JsonException)
        {
            return new();
        }
    }

    private static string Hash(string file)
    {
        using var stream = File.OpenRead(file);
        return Convert.ToHexString(SHA256.HashData(stream));
    }
}
