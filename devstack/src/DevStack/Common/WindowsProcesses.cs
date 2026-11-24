using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>A process of a Toolhelp snapshot: pid, parent pid, executable name and creation time (null when not readable).</summary>
public sealed record WindowsProcessRow(int Pid, int ParentPid, string Name, DateTimeOffset? CreatedAt);

/// <summary>
///     Process information on Windows without WMI (a Win32_Process query took seconds): CreateToolhelp32Snapshot for the
///     process list (milliseconds), GetProcessTimes for creation times and NtQueryInformationProcess for the command line
///     of single processes, asked only where a caller needs it. Command lines of other users' or elevated processes are
///     not readable (null).
/// </summary>
[SupportedOSPlatform("windows")]
public static class WindowsProcesses
{
    /// <summary>How long a snapshot is reused: the calls of one request (stop of several services, a status) share it.</summary>
    private static readonly TimeSpan SnapshotAge = TimeSpan.FromMilliseconds(500);

    private static readonly Lock Gate = new();
    private static (DateTime At, List<WindowsProcessRow> Rows)? _cache;

    /// <summary>Every process of the machine (reused for <see cref="SnapshotAge"/>); empty when the snapshot fails.</summary>
    public static List<WindowsProcessRow> Snapshot()
    {
        lock (Gate)
        {
            if (_cache is { } c && DateTime.UtcNow - c.At < SnapshotAge)
            {
                return c.Rows;
            }
        }

        var rows = WindowsNative.ProcessEntries()
            .Select(e => new WindowsProcessRow(e.Pid, e.ParentPid, e.Name, CreationTime(e.Pid)))
            .ToList();
        lock (Gate)
        {
            _cache = (DateTime.UtcNow, rows);
        }

        return rows;
    }

    /// <summary>The creation time of a process, null if it is gone or not readable.</summary>
    public static DateTimeOffset? CreationTime(int pid) => WindowsNative.CreationTime(pid);

    /// <summary>The command line of one process, null if it is gone or not readable.</summary>
    public static string? CommandLine(int pid) => pid <= 0 ? null : WindowsNative.CommandLine(pid);
}

/// <summary>The Toolhelp entry fields the daemon uses.</summary>
internal readonly record struct ProcessEntry(int Pid, int ParentPid, string Name);

/// <summary>PROCESSENTRY32W.</summary>
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
internal struct ProcessEntry32
{
    public uint Size;
    public uint Usage;
    public uint ProcessId;
    public IntPtr DefaultHeapId;
    public uint ModuleId;
    public uint Threads;
    public uint ParentProcessId;
    public int PriorityClassBase;
    public uint Flags;

    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
    public string ExeFile;
}
