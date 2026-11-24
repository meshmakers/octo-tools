using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Windows (AB#9377): Start-OctoDevStackDaemon starts the daemon with its stdout and stderr redirected into
///     daemon.log / daemon.err.log, and Start-Process makes those handles inheritable. CreateProcess hands every
///     inheritable handle to a child (.NET always passes bInheritHandles = true), so every service, build and probe the
///     daemon started held the daemon's log open for its whole life: the next start could not keep it as daemon.prev.log.
///     The daemon clears the inherit flag of its own output handles once at its start. No child needs them: every child
///     either redirects its output or gets a console of its own (services and builds: CreateNoWindow).
/// </summary>
public static class StdHandles
{
    private const int StdOutputHandle = -11;
    private const int StdErrorHandle = -12;
    private const uint HandleFlagInherit = 0x1;
    private const uint FileTypeDisk = 0x1;
    private const uint FileTypePipe = 0x3;
    private static readonly IntPtr InvalidHandle = new(-1);

    /// <summary>Whether a handle of this file type (GetFileType) is kept from the children: a file or a pipe, not a console.</summary>
    internal static bool KeptFromChildren(uint fileType) => fileType is FileTypeDisk or FileTypePipe;

    /// <summary>Clears the inherit flag of stdout and stderr when they are a file or a pipe; returns how many were cleared.</summary>
    [SupportedOSPlatform("windows")]
    public static int KeepOutputFromChildren()
    {
        var cleared = 0;
        foreach (var which in new[] { StdOutputHandle, StdErrorHandle })
        {
            var handle = GetStdHandle(which);
            if (handle == IntPtr.Zero || handle == InvalidHandle || !KeptFromChildren(GetFileType(handle)))
            {
                continue;
            }

            if (SetHandleInformation(handle, HandleFlagInherit, 0))
            {
                cleared++;
            }
        }

        return cleared;
    }

    // DllImport instead of LibraryImport: the generated stubs would need AllowUnsafeBlocks (see ProcessTree).
#pragma warning disable SYSLIB1054
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int which);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetFileType(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
#pragma warning restore SYSLIB1054
}
