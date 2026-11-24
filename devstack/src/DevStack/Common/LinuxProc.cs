using System.Globalization;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Linux without lsof (minimal distributions, WSL; AB#9377): what the daemon asks lsof for, read from /proc. Without it
///     the lsof calls printed nothing, so ports in use and foreign processes went unseen. Listening TCP sockets come from
///     /proc/net/tcp and tcp6 (state 0A), mapped to pids through the socket inodes of /proc/&lt;pid&gt;/fd; the working
///     directory and stdout from the /proc/&lt;pid&gt;/cwd and fd/1 links. Like lsof without root, only the user's own
///     processes are readable. Where lsof is installed it stays what the daemon uses.
/// </summary>
public static class LinuxProc
{
    private static readonly Lazy<bool> LsofOnPath = new(() => OnPath("lsof"));

    /// <summary>True on Linux when lsof is not installed: read /proc instead.</summary>
    public static bool UseProc => OperatingSystem.IsLinux() && !LsofOnPath.Value;

    /// <summary>The ports in LISTEN state of /proc/net/tcp-style tables, by socket inode.</summary>
    internal static Dictionary<long, int> ParseListening(IEnumerable<string> tables)
    {
        var result = new Dictionary<long, int>();
        foreach (var table in tables)
        {
            foreach (var line in table.Split('\n', StringSplitOptions.RemoveEmptyEntries).Skip(1))
            {
                // sl local_address rem_address st tx:rx tr:when retrnsmt uid timeout inode ...
                var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (fields.Length < 10 || fields[3] != "0A")
                {
                    continue;
                }

                var colon = fields[1].LastIndexOf(':');
                if (colon < 0 || !int.TryParse(fields[1][(colon + 1)..], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var port) ||
                    !long.TryParse(fields[9], NumberStyles.Integer, CultureInfo.InvariantCulture, out var inode) || inode == 0)
                {
                    continue;
                }

                result[inode] = port;
            }
        }

        return result;
    }

    /// <summary>The socket inode an fd link names (<c>socket:[123]</c>), else null.</summary>
    internal static long? SocketInode(string? linkTarget) =>
        linkTarget is { Length: > 9 } t && t.StartsWith("socket:[", StringComparison.Ordinal) && t.EndsWith(']') &&
        long.TryParse(t[8..^1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var inode)
            ? inode
            : null;

    /// <summary>Listening ports per pid, as ExternalDetector.ParseLsofListen returns them.</summary>
    public static Dictionary<int, List<int>> ListeningPortsByPid(string procRoot = "/proc", Func<string, string?>? readLink = null)
    {
        readLink ??= ReadLink;
        var tables = new[] { "net/tcp", "net/tcp6" }.Select(t => Path.Combine(procRoot, t)).Where(File.Exists).Select(SafeRead);
        var ports = ParseListening(tables);
        var result = new Dictionary<int, List<int>>();
        if (ports.Count == 0)
        {
            return result;
        }

        foreach (var pid in Pids(procRoot))
        {
            foreach (var fd in SafeFiles(Path.Combine(procRoot, pid.ToString(CultureInfo.InvariantCulture), "fd")))
            {
                if (SocketInode(readLink(fd)) is { } inode && ports.TryGetValue(inode, out var port))
                {
                    var list = result.TryGetValue(pid, out var existing) ? existing : result[pid] = [];
                    if (!list.Contains(port))
                    {
                        list.Add(port);
                    }
                }
            }
        }

        return result;
    }

    /// <summary>Working directory and stdout target per pid, as ExternalDetector.ParseLsofFiles returns them.</summary>
    public static Dictionary<int, (string? Cwd, string? Stdout)> Files(IReadOnlyCollection<int> pids, string procRoot = "/proc", Func<string, string?>? readLink = null)
    {
        readLink ??= ReadLink;
        var result = new Dictionary<int, (string? Cwd, string? Stdout)>();
        foreach (var pid in pids)
        {
            var folder = Path.Combine(procRoot, pid.ToString(CultureInfo.InvariantCulture));
            var cwd = readLink(Path.Combine(folder, "cwd"));
            var stdout = readLink(Path.Combine(folder, "fd", "1"));
            if (cwd != null || stdout != null)
            {
                // Like lsof -Fn: only a path counts as a stdout target, not a pipe or socket.
                result[pid] = (cwd, stdout is { Length: > 0 } s && s[0] == '/' ? s : null);
            }
        }

        return result;
    }

    private static IEnumerable<int> Pids(string procRoot)
    {
        try
        {
            return Directory.EnumerateDirectories(procRoot)
                .Select(Path.GetFileName)
                .Select(n => int.TryParse(n, NumberStyles.None, CultureInfo.InvariantCulture, out var pid) ? pid : 0)
                .Where(pid => pid > 0)
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    private static IEnumerable<string> SafeFiles(string folder)
    {
        try
        {
            return Directory.EnumerateFileSystemEntries(folder).ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return []; // another user's process, or it ended
        }
    }

    private static string SafeRead(string file)
    {
        try
        {
            return File.ReadAllText(file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return "";
        }
    }

    private static string? ReadLink(string path)
    {
        try
        {
            return new FileInfo(path).LinkTarget;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static bool OnPath(string program) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
        .Any(dir => File.Exists(Path.Combine(dir, program)));
}
