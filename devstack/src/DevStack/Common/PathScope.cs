namespace Meshmakers.Octo.DevStack.Common;

/// <summary>Which folder a process or build target belongs to.</summary>
public static class PathScope
{
    private static readonly char Sep = Path.DirectorySeparatorChar;

    public static string Normalize(string path) => Path.GetFullPath(path).TrimEnd(Sep) + Sep;

    public static bool SamePath(string a, string b) => string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>Whether <paramref name="path"/> is <paramref name="folder"/> or lies below it (plain prefix; nested repos count).</summary>
    public static bool IsUnder(string path, string folder) => Normalize(path).StartsWith(Normalize(folder), StringComparison.OrdinalIgnoreCase);

    /// <summary>How paths compare on this OS for display and profiles: case-insensitive on Windows, exact elsewhere.</summary>
    public static StringComparison OsComparison => OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    /// <summary>
    ///     <paramref name="path"/> relative to <paramref name="baseFolder"/> when it lies inside it, else <paramref name="path"/>
    ///     unchanged. Both are made full first (on Windows: '/' becomes '\', drive letters compare case-insensitively); a
    ///     relative result uses '/' on every OS, so profiles and texts read the same.
    /// </summary>
    public static string Relative(string path, string baseFolder)
    {
        var full = Path.GetFullPath(path);
        var b = Path.GetFullPath(baseFolder).TrimEnd(Sep, Path.AltDirectorySeparatorChar) + Sep;
        if (!full.StartsWith(b, OsComparison) || full.Length == b.Length)
        {
            return path;
        }

        var relative = full[b.Length..].TrimEnd(Sep);
        return Sep == '/' ? relative : relative.Replace(Sep, '/');
    }

    /// <summary>
    ///     Whether <paramref name="path"/> is the repository <paramref name="repo"/> or lies inside it. A git worktree or
    ///     clone nested in the repository (<c>.claude/worktrees/x</c>, any folder with its own <c>.git</c>) is not part of
    ///     it: a build of the repository does not touch its binaries.
    /// </summary>
    public static bool IsInRepo(string path, string repo)
    {
        var p = Normalize(path);
        var r = Normalize(repo);
        if (!p.StartsWith(r, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var relative = p[r.Length..].TrimEnd(Sep);
        if (relative.Length == 0)
        {
            return true;
        }

        var parts = relative.Split(Sep);
        if (parts[0] == ".claude")
        {
            return false;
        }

        var current = r.TrimEnd(Sep);
        foreach (var part in parts)
        {
            current = Path.Combine(current, part);
            if (File.Exists(Path.Combine(current, ".git")) || Directory.Exists(Path.Combine(current, ".git")))
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>A git worktree: its .git is a file (a normal clone has a .git folder).</summary>
    public static bool IsWorktree(string folder) => File.Exists(Path.Combine(folder, ".git"));

    /// <summary>The nearest folder at or above <paramref name="path"/> that holds Octo.User.props (a lane), or null.</summary>
    public static string? LaneOf(string path)
    {
        var current = Path.GetFullPath(path).TrimEnd(Sep);
        while (!string.IsNullOrEmpty(current))
        {
            if (File.Exists(Path.Combine(current, "Octo.User.props")))
            {
                return current;
            }

            current = Path.GetDirectoryName(current);
        }

        return null;
    }

    /// <summary>A file-system-safe name for an owner or key.</summary>
    public static string Slug(string value)
    {
        var chars = value.Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' or '.' ? c : '_').ToArray();
        var slug = new string(chars).Trim('.');
        return slug.Length == 0 ? "_" : slug.Length > 80 ? slug[..80] : slug;
    }
}
