namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     One daemon per state folder (AB#9377): an exclusive lock on &lt;state&gt;/daemon.lock, held for the daemon's lifetime and
///     released by the operating system when the process ends, however it ends. A second daemon on the same state folder (for
///     example launchd's KeepAlive restart racing a start by hand) stops before it asks octo-tools for the workspace, adopts
///     services or writes a start record; without the lock it would do all of it and fail only later, at the port bind,
///     leaving a wrong "lost" record behind.
/// </summary>
public sealed class DaemonLock : IDisposable
{
    public const string FileName = "daemon.lock";

    /// <summary>
    ///     Exit code of a daemon that finds its state folder locked (75, EX_TEMPFAIL). The systemd unit of octo-tools counts it
    ///     as a success (SuccessExitStatus), so systemd does not start the daemon again and again while another one runs.
    /// </summary>
    public const int HeldExitCode = 75;

    /// <summary>Set by octo-tools' service definitions to the service manager that runs the daemon: launchd, systemd.</summary>
    public const string ServiceVariable = "OCTO_DEVSTACK_SERVICE";

    private readonly FileStream _stream;

    private DaemonLock(FileStream stream)
    {
        _stream = stream;
    }

    public static string PathIn(string stateDirectory) => Path.Combine(stateDirectory, FileName);

    /// <summary>
    ///     The lock, or null when another process holds it. Anything else - a lock file this user cannot write, a missing
    ///     folder - throws: it is no other daemon, and waiting for it (launchd) would never end.
    /// </summary>
    public static DaemonLock? TryAcquire(string stateDirectory)
    {
        Directory.CreateDirectory(stateDirectory);
        try
        {
            // FileShare.None: a share-deny open on Windows, flock(LOCK_EX) on macOS/Linux - both refuse a second holder.
            return new DaemonLock(new FileStream(PathIn(stateDirectory), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None));
        }
        catch (IOException e) when (IsHeldByAnother(e))
        {
            return null;
        }
    }

    /// <summary>
    ///     Whether the open failed because another process holds the file: a sharing or lock violation on Windows (Win32 32, 33);
    ///     on macOS/Linux only the failed flock (the file was opened, the lock refused), which .NET reports as an IOException
    ///     whose HResult is the raw errno EWOULDBLOCK. Any other error creating or opening the file (a read-only file system,
    ///     a full disk, an I/O error) is no other daemon: systemd would count exit code 75 as success and launchd would wait
    ///     for ever.
    /// </summary>
    internal static bool IsHeldByAnother(IOException e) =>
        e is not (FileNotFoundException or DirectoryNotFoundException or PathTooLongException) &&
        (OperatingSystem.IsWindows() ? (e.HResult & 0xFFFF) is 32 or 33 : e.HResult == WouldBlockErrno);

    /// <summary>EWOULDBLOCK (= EAGAIN): 35 on macOS and the BSDs, 11 on Linux.</summary>
    internal static int WouldBlockErrno => OperatingSystem.IsMacOS() || OperatingSystem.IsFreeBSD() ? 35 : 11;

    /// <summary>
    ///     The lock as soon as it is free. For a daemon launchd runs: KeepAlive starts it again whenever it exits, so instead of
    ///     exiting it waits for the other daemon to end and takes over then.
    /// </summary>
    public static async Task<DaemonLock> WaitAsync(string stateDirectory, TimeSpan interval, CancellationToken cancellationToken = default)
    {
        while (true)
        {
            if (TryAcquire(stateDirectory) is { } acquired)
            {
                return acquired;
            }

            await Task.Delay(interval, cancellationToken);
        }
    }

    /// <summary>Whether the daemon waits for a held lock instead of exiting: only under launchd (see <see cref="WaitAsync" />).</summary>
    public static bool WaitsForTheLock(string? serviceManager) => string.Equals(serviceManager, "launchd", StringComparison.Ordinal);

    public void Dispose() => _stream.Dispose();
}
