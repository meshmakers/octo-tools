namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Which file a running .NET service really loaded as its entry assembly: the open (mapped) files of the process - lsof
///     on macOS, /proc/&lt;pid&gt;/maps on Linux. Not available on Windows (null).
/// </summary>
public static class EntryAssemblies
{
    /// <summary>The loaded path of each process's entry dll (by file name), or null when it is not among the process's files.</summary>
    public static Dictionary<int, string?> Loaded(IReadOnlyDictionary<int, string> dllByPid)
    {
        var result = dllByPid.Keys.ToDictionary(p => p, _ => (string?)null);
        if (dllByPid.Count == 0 || OperatingSystem.IsWindows())
        {
            return result;
        }

        if (OperatingSystem.IsLinux())
        {
            foreach (var (pid, dll) in dllByPid)
            {
                try
                {
                    result[pid] = FindIn(File.ReadAllLines($"/proc/{pid}/maps").Select(l => l.Split(' ', StringSplitOptions.RemoveEmptyEntries).LastOrDefault() ?? ""), dll);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    // gone or not readable: stays null
                }
            }

            return result;
        }

        var output = ProcessTree.RunTool("lsof", $"-a -p {string.Join(',', dllByPid.Keys)} -Fpn");
        foreach (var (pid, paths) in ParseLsofPaths(output))
        {
            if (dllByPid.TryGetValue(pid, out var dll))
            {
                result[pid] = FindIn(paths, dll);
            }
        }

        return result;
    }

    internal static string? FindIn(IEnumerable<string> paths, string dll) =>
        paths.FirstOrDefault(p => p.EndsWith(Path.DirectorySeparatorChar + dll, StringComparison.Ordinal) || p.EndsWith("/" + dll, StringComparison.Ordinal));

    /// <summary>lsof -Fpn output: p&lt;pid&gt; lines followed by n&lt;path&gt; lines.</summary>
    internal static Dictionary<int, List<string>> ParseLsofPaths(string output)
    {
        var result = new Dictionary<int, List<string>>();
        var pid = 0;
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            if (line[0] == 'p')
            {
                int.TryParse(line[1..], out pid);
                result.TryAdd(pid, []);
            }
            else if (line[0] == 'n' && pid > 0 && line.Length > 1 && line[1] == '/')
            {
                result[pid].Add(line[1..]);
            }
        }

        return result;
    }

    /// <summary>The entry dll of a service command line: the first argument that ends in .dll (dotnet &lt;dll&gt;).</summary>
    public static string? DllOf(IReadOnlyList<string> args) =>
        args.FirstOrDefault(a => a.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && !a.StartsWith('-')) is { } dll ? Path.GetFileName(dll) : null;
}
