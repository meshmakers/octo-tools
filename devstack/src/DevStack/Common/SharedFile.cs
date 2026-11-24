using System.Collections.Concurrent;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Files that are replaced while others read them: the state file, job files, build history, daemon journal, lane
///     claims, the config, exit markers. A writer writes a temporary file and moves it over the old one, so a reader never
///     sees half a file. On Windows that move fails while any handle without FILE_SHARE_DELETE is open on the target -
///     another reader, a virus scanner, the search indexer - so <see cref="Replace"/> retries it briefly, and the daemon's
///     own reads (<see cref="ReadAllText"/>, <see cref="ReadAllLines"/>) share delete and never block a writer. macOS and
///     Linux replace an open file anyway; the code is the same on every OS.
/// </summary>
public static class SharedFile
{
    // About 0.8 s in all: long enough for a scanner's look at a fresh file, short enough to hold a lock for.
    private static readonly TimeSpan[] RetryDelays =
    [
        TimeSpan.FromMilliseconds(10), TimeSpan.FromMilliseconds(25), TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100),
        TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(400)
    ];

    // Windows: the volumes (drive or share root) whose file system refused a rename with POSIX semantics (FAT, a network
    // share). Per volume: a lane claim on a share must not take the gapless replace away from the state file on NTFS.
    private static readonly ConcurrentDictionary<string, bool> NoPosixRename = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The volume a file is on: its drive or share root.</summary>
    internal static string VolumeOf(string path) => Path.GetPathRoot(Path.GetFullPath(path)) ?? "";

    /// <summary>
    ///     Puts <paramref name="temp"/> in place of <paramref name="path"/>, retrying while the target is briefly in use, so
    ///     that the name never goes away: a reader finds the old file or the new one. macOS/Linux: rename(2) (what
    ///     File.Replace and File.Move do there). Windows: a
    ///     rename with POSIX semantics (<see cref="WindowsFileRename"/>), which also replaces a target that a reader holds
    ///     open with FILE_SHARE_DELETE - the reader goes on reading the old content. Where the file system cannot do it,
    ///     an existing target is replaced with <see cref="File.Replace(string, string, string?, bool)"/> (ReplaceFile, the
    ///     name is gone for a moment) and a new file is moved; <see cref="File.Move(string, string, bool)"/> (MoveFileEx)
    ///     refuses any open target.
    /// </summary>
    public static void Replace(string temp, string path)
    {
        for (var attempt = 0;; attempt++)
        {
            try
            {
                if (OperatingSystem.IsWindows())
                {
                    var volume = VolumeOf(path);
                    if (!NoPosixRename.ContainsKey(volume))
                    {
                        if (WindowsFileRename.TryReplace(temp, path))
                        {
                            return;
                        }

                        NoPosixRename[volume] = true;
                    }

                    ReplaceKeepingTheOld(temp, path);
                    return;
                }

                if (File.Exists(path))
                {
                    File.Replace(temp, path, destinationBackupFileName: null, ignoreMetadataErrors: true);
                }
                else
                {
                    File.Move(temp, path, overwrite: true);
                }

                return;
            }
            catch (FileNotFoundException) when (attempt < RetryDelays.Length && File.Exists(temp))
            {
                // The target went away between the check and the replace: the next attempt moves.
            }
            catch (Exception e) when (attempt < RetryDelays.Length && IsTransient(e))
            {
                Thread.Sleep(RetryDelays[attempt]);
            }
        }
    }

    /// <summary>
    ///     Windows without POSIX rename: ReplaceFile with a backup name. ReplaceFile moves the old file away before it moves
    ///     the new one in; when the second move fails (ERROR_UNABLE_TO_MOVE_REPLACEMENT_2) the old file sits under the
    ///     backup name and goes back to its name, so a failed update never loses the last good file (a job record, the
    ///     state). A new file is moved. <paramref name="replace"/> stands for File.Replace in the tests (a ReplaceFile that
    ///     fails half-way cannot be provoked on purpose); the code runs on every OS, Replace uses it only on Windows.
    /// </summary>
    internal static void ReplaceKeepingTheOld(string temp, string path, Action<string, string, string>? replace = null)
    {
        if (!File.Exists(path))
        {
            File.Move(temp, path, overwrite: true);
            return;
        }

        var backup = path + ".replaced";
        try
        {
            (replace ?? ((t, p, b) => File.Replace(t, p, b, ignoreMetadataErrors: true)))(temp, path, backup);
        }
        catch (IOException) when (!File.Exists(path) && File.Exists(backup))
        {
            File.Move(backup, path);
            throw;
        }

        try
        {
            File.Delete(backup);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // a reader still has the old content open; the next replace overwrites the backup
        }
    }

    /// <summary>Like <see cref="File.ReadAllText(string)"/>, without blocking a writer that replaces the file.</summary>
    public static string ReadAllText(string path)
    {
        using var reader = Open(path);
        return reader.ReadToEnd();
    }

    /// <summary>Like <see cref="File.ReadAllLines(string)"/>, without blocking a writer that replaces the file.</summary>
    public static string[] ReadAllLines(string path)
    {
        using var reader = Open(path);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line)
        {
            lines.Add(line);
        }

        return [.. lines];
    }

    /// <summary>A sharing conflict that goes away by itself; a missing file or folder does not.</summary>
    internal static bool IsTransient(Exception e) =>
        e is UnauthorizedAccessException || e is IOException and not FileNotFoundException and not DirectoryNotFoundException;

    private static StreamReader Open(string path) =>
        new(new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete));
}
