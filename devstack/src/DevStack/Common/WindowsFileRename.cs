using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>
///     Windows (AB#9377): puts a file in place of another in one step, also while readers hold the target open with
///     FILE_SHARE_DELETE (they go on reading the old content) - a rename with POSIX semantics (SetFileInformationByHandle,
///     FileRenameInfoEx; NTFS on Windows 10 1709 and later). ReplaceFile renames the old file away first ("~RF....TMP") and
///     the new one in after it, so for a moment the name does not exist: a reader then found no state, job or config file.
///     MoveFileEx refuses a target that anyone has open.
/// </summary>
internal static class WindowsFileRename
{
    internal const uint ReplaceIfExists = 0x1;
    internal const uint PosixSemantics = 0x2;

    private const int FileRenameInfoEx = 22;
    private const uint DeleteAccess = 0x00010000;
    private const uint Synchronize = 0x00100000;
    private const uint ShareReadWriteDelete = 0x7;
    private const uint OpenExisting = 3;
    private const int ErrorInvalidFunction = 1;
    private const int ErrorNotSupported = 50;
    private const int ErrorInvalidParameter = 87;

    /// <summary>
    ///     The FILE_RENAME_INFO buffer: Flags (4 bytes, padded to a pointer), RootDirectory (a pointer, null), FileNameLength
    ///     (4 bytes, in bytes), FileName (UTF-16, terminated). Pure, so its layout is tested on every OS.
    /// </summary>
    internal static byte[] RenameInfo(string target, uint flags, int pointerSize)
    {
        var name = Encoding.Unicode.GetBytes(target);
        var lengthOffset = pointerSize * 2;
        var nameOffset = lengthOffset + 4;
        var buffer = new byte[nameOffset + name.Length + 2];
        BitConverter.TryWriteBytes(buffer.AsSpan(0, 4), flags);
        BitConverter.TryWriteBytes(buffer.AsSpan(lengthOffset, 4), (uint)name.Length);
        name.CopyTo(buffer, nameOffset);
        return buffer;
    }

    /// <summary>
    ///     Moves <paramref name="source"/> onto <paramref name="target"/>. False when the file system cannot do it (FAT, a network
    ///     share, an older Windows): the caller replaces the file another way. A target that someone has open without
    ///     FILE_SHARE_DELETE throws UnauthorizedAccessException or IOException, a missing source FileNotFoundException.
    /// </summary>
    [SupportedOSPlatform("windows")]
    public static bool TryReplace(string source, string target)
    {
        using var handle = CreateFileW(source, DeleteAccess | Synchronize, ShareReadWriteDelete, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (handle.IsInvalid)
        {
            throw ExceptionFor(Marshal.GetLastWin32Error());
        }

        var info = RenameInfo(Path.GetFullPath(target), ReplaceIfExists | PosixSemantics, IntPtr.Size);
        var buffer = Marshal.AllocHGlobal(info.Length);
        try
        {
            Marshal.Copy(info, 0, buffer, info.Length);
            if (SetFileInformationByHandle(handle, FileRenameInfoEx, buffer, (uint)info.Length))
            {
                return true;
            }

            var error = Marshal.GetLastWin32Error();
            if (error is ErrorInvalidFunction or ErrorNotSupported or ErrorInvalidParameter)
            {
                return false;
            }

            throw ExceptionFor(error);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    // FileNotFoundException, UnauthorizedAccessException, IOException (sharing violation, ...) - what File.* would throw.
    private static Exception ExceptionFor(int error) =>
        Marshal.GetExceptionForHR(unchecked((int)0x80070000 | (error & 0xFFFF))) ?? new IOException($"Win32 error {error}");

    // DllImport instead of LibraryImport: the generated stubs would need AllowUnsafeBlocks (see ProcessTree).
#pragma warning disable SYSLIB1054
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern SafeFileHandle CreateFileW(string fileName, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle file, int informationClass, IntPtr information, uint size);
#pragma warning restore SYSLIB1054
}
