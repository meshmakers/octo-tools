using System.ComponentModel;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Builds;

/// <summary>
///     The state of a repository's work tree for a job's evidence, read with git as a process (the daemon has no git library):
///     <c>git --no-optional-locks -C &lt;repo&gt; -c core.quotePath=false status --porcelain=v2 --branch --untracked-files=all</c> - one call gives HEAD, the branch and the
///     changed entries. Untracked files count as changes, ignored ones do not (they are only listed with --ignored).
///     --no-optional-locks: the daemon never takes the index lock a session's own git needs. Only the root of a work tree is
///     read (a folder with its own .git): a folder inside some other repository - a temp folder below a home directory under
///     git - is not that repository.
/// </summary>
internal static class GitWorkTree
{
    /// <summary>How long one git status may take (a big repository with many untracked files on Windows takes seconds).</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    /// <summary>How many repositories are read at the same time (kind=all covers every repository of a lane).</summary>
    private const int Parallel = 4;

    /// <summary>Reads every folder, at most <see cref="Parallel"/> at once, in the given order. Never throws.</summary>
    public static async Task<List<BuildRepoState>> ReadAllAsync(IReadOnlyList<string> folders, TimeSpan? timeout = null)
    {
        using var gate = new SemaphoreSlim(Parallel);
        var reads = folders.Select(async folder =>
        {
            await gate.WaitAsync();
            try
            {
                return await ReadAsync(folder, timeout);
            }
            finally
            {
                gate.Release();
            }
        });
        return (await Task.WhenAll(reads)).ToList();
    }

    /// <summary>The work tree of <paramref name="folder"/>; a state with only an error when git cannot tell. Never throws.</summary>
    public static async Task<BuildRepoState> ReadAsync(string folder, TimeSpan? timeout = null)
    {
        try
        {
            if (!Directory.Exists(folder))
            {
                return Failed("the folder does not exist");
            }

            var git = System.IO.Path.Combine(folder, ".git");
            if (!File.Exists(git) && !Directory.Exists(git))
            {
                return Failed("no .git in the folder: not the root of a git work tree");
            }

            var (exitCode, output, error) = await RunAsync(folder, timeout ?? Timeout);
            if (exitCode != 0)
            {
                return Failed($"git status exited with {exitCode}: {GitProcess.FirstLine(error)}");
            }

            var state = Parse(output);
            return state.Clean == false ? state with { Fingerprint = Fingerprint(folder, output) } : state;
        }
        catch (Exception e) when (e is Win32Exception or IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            return Failed($"git could not be run: {e.Message}");
        }
        catch (TimeoutException e)
        {
            return Failed(e.Message);
        }
    }

    /// <summary>The state from the output of <c>git status --porcelain=v2 --branch</c> (pure).</summary>
    internal static BuildRepoState Parse(string output)
    {
        string? head = null;
        string? branch = null;
        var changes = 0;
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.StartsWith("# branch.oid ", StringComparison.Ordinal))
            {
                var oid = line["# branch.oid ".Length..].Trim();
                head = oid.Length >= 40 && oid.All(Uri.IsHexDigit) ? oid.ToLowerInvariant() : null; // "(initial)": no commit yet
            }
            else if (line.StartsWith("# branch.head ", StringComparison.Ordinal))
            {
                var name = line["# branch.head ".Length..].Trim();
                branch = name is "" or "(detached)" ? null : name;
            }
            else if (line.Length > 0 && line[0] != '#' && line[0] != '!')
            {
                changes++; // 1/2 (changed), u (unmerged), ? (untracked)
            }
        }

        return new BuildRepoState(head, branch, changes == 0, changes > 0 ? changes : null);
    }

    private static BuildRepoState Failed(string error) => new(null, null, null, null, error);

    /// <summary>Changed files bigger than this are not hashed: the fingerprint is incomplete then (null).</summary>
    internal const long MaxHashedFileBytes = 16 * 1024 * 1024;

    /// <summary>More changed entries than this are not hashed: the fingerprint is incomplete then (null).</summary>
    internal const int MaxEntries = 20000;

    /// <summary>
    ///     What makes two dirty states of a work tree the same: every changed entry of <c>git status --porcelain=v2
    ///     --untracked-files=all</c> (its line: path, change, index object; every untracked file on a line of its own, ignored
    ///     ones not) and the SHA-256 of the file it names, "missing" for a deleted one. An edit to a file that was dirty already
    ///     changes it, a build's ignored output does not. 16 hex characters of SHA-256. Null - never equal, so the evidence is
    ///     not "unchanged" - when it would not cover every change: a path git still quotes (a quote, backslash or control
    ///     character in it), a folder entry (an untracked nested repository), a file over 16 MB, more than 20000 entries.
    /// </summary>
    internal static string? Fingerprint(string folder, string output)
    {
        var lines = output.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => l.Length > 0 && l[0] is not ('#' or '!')).Order(StringComparer.Ordinal).ToList();
        if (lines.Count > MaxEntries)
        {
            return null;
        }

        using var hash = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
        void Add(string text) => hash.AppendData(System.Text.Encoding.UTF8.GetBytes(text + "\n"));
        foreach (var line in lines)
        {
            Add(line);
            if (EntryPath(line) is not { } path)
            {
                return null; // a quoted path: its content cannot be read, so the fingerprint would not cover it
            }

            var full = System.IO.Path.Combine(folder, path);
            try
            {
                if (File.Exists(full))
                {
                    if (ContentOf(new FileInfo(full)) is not { } content)
                    {
                        return null;
                    }

                    Add(content);
                }
                else if (Directory.Exists(full))
                {
                    return null; // git lists a folder only for an untracked nested repository: its files are not covered
                }
                else
                {
                    Add("missing");
                }
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                return null;
            }
        }

        return Convert.ToHexStringLower(hash.GetHashAndReset())[..16];
    }

    /// <summary>The SHA-256 of the file, or null for one over <see cref="MaxHashedFileBytes"/>.</summary>
    private static string? ContentOf(FileInfo file)
    {
        if (file.Length > MaxHashedFileBytes)
        {
            return null;
        }

        using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(stream));
    }

    /// <summary>
    ///     The path of a porcelain v2 entry (relative to the work tree root): the last field of '1' (8 fields before it), '2'
    ///     (9, then the original path after a tab), 'u' (10) and '?'. Null for a quoted path.
    /// </summary>
    internal static string? EntryPath(string line)
    {
        var path = line[0] switch
        {
            '1' => Field(line, 8),
            '2' => Field(line, 9)?.Split('\t')[0],
            'u' => Field(line, 10),
            '?' => line.Length > 2 ? line[2..] : null,
            _ => null
        };
        return path is { Length: > 0 } && path[0] != '"' ? path : null;

        static string? Field(string text, int before) => text.Split(' ', before + 1) is var parts && parts.Length == before + 1 ? parts[before] : null;
    }

    // --untracked-files=all: every untracked file on its own line (ignored ones not), so the fingerprint can hash each - and a
    // developer's status.showUntrackedFiles=no must not make a work tree with new files look clean. core.quotePath=false: a
    // non-ASCII name comes as it is (UTF-8), not quoted; only names with a quote, backslash or control character stay quoted.
    private static Task<(int ExitCode, string Output, string Error)> RunAsync(string folder, TimeSpan timeout) =>
        GitProcess.RunAsync(folder, ["-c", "core.quotePath=false", "status", "--porcelain=v2", "--branch", "--untracked-files=all"], timeout);
}
