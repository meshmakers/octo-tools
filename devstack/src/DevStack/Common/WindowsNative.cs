using System.Buffers.Binary;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>The listening TCP sockets of the machine as GetExtendedTcpTable returns them; the parsing is plain byte code.</summary>
public static class TcpListenerTable
{
    /// <summary>MIB_TCPROW_OWNER_PID: state, local addr, local port, remote addr, remote port, owning pid (6 DWORDs).</summary>
    internal const int Ipv4RowSize = 24;

    /// <summary>MIB_TCP6ROW_OWNER_PID: local addr[16], scope, local port, remote addr[16], scope, remote port, state, owning pid.</summary>
    internal const int Ipv6RowSize = 56;

    /// <summary>
    ///     Port and owning pid of every row of a MIB_TCPTABLE_OWNER_PID / MIB_TCP6TABLE_OWNER_PID buffer (dwNumEntries, then
    ///     the rows). Ports are stored in network byte order in the low 16 bits of their DWORD.
    /// </summary>
    public static List<(int Port, int Pid)> Parse(ReadOnlySpan<byte> buffer, bool ipv6)
    {
        var result = new List<(int, int)>();
        if (buffer.Length < 4)
        {
            return result;
        }

        var count = BinaryPrimitives.ReadInt32LittleEndian(buffer);
        var rowSize = ipv6 ? Ipv6RowSize : Ipv4RowSize;
        var portOffset = ipv6 ? 20 : 8;
        var pidOffset = ipv6 ? 52 : 20;
        for (var i = 0; i < count; i++)
        {
            var row = 4 + i * rowSize;
            if (row + rowSize > buffer.Length)
            {
                break;
            }

            var port = (buffer[row + portOffset] << 8) | buffer[row + portOffset + 1];
            var pid = BinaryPrimitives.ReadInt32LittleEndian(buffer[(row + pidOffset)..]);
            result.Add((port, pid));
        }

        return result;
    }

    /// <summary>Listening ports by pid (IPv4 and IPv6), sorted; empty when the table cannot be read.</summary>
    [SupportedOSPlatform("windows")]
    public static Dictionary<int, List<int>> ListeningPortsByPid()
    {
        var result = new Dictionary<int, List<int>>();
        foreach (var (family, ipv6) in new[] { (WindowsNative.AfInet, false), (WindowsNative.AfInet6, true) })
        {
            foreach (var (port, pid) in Parse(WindowsNative.TcpTable(family), ipv6))
            {
                if (!result.TryGetValue(pid, out var ports))
                {
                    result[pid] = ports = [];
                }

                if (!ports.Contains(port))
                {
                    ports.Add(port);
                }
            }
        }

        foreach (var ports in result.Values)
        {
            ports.Sort();
        }

        return result;
    }
}

/// <summary>Win32 calls: the TCP table (iphlpapi), the console control functions, the Toolhelp process snapshot and per-process queries.</summary>
[SupportedOSPlatform("windows")]
internal static class WindowsNative
{
    internal const int AfInet = 2;
    internal const int AfInet6 = 23;
    private const int TcpTableOwnerPidListener = 3;
    private const int ErrorInsufficientBuffer = 122;
    internal const uint CtrlBreakEvent = 1;

    // DllImport instead of LibraryImport: the generated stubs would need AllowUnsafeBlocks (see ProcessTree).
#pragma warning disable SYSLIB1054
    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int addressFamily, int tableClass, uint reserved);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool AttachConsole(uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler? handler, bool add);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern uint GetConsoleProcessList([Out] uint[] processList, uint count);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")]
    private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")]
    private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry32 entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(IntPtr process, int informationClass, IntPtr information, int length, out int returnLength);
#pragma warning restore SYSLIB1054

    private const uint Th32csSnapProcess = 0x2;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const int ProcessCommandLineInformation = 60;
    private const int StatusInfoLengthMismatch = unchecked((int)0xC0000004);
    private static readonly IntPtr InvalidHandle = new(-1);

    internal delegate bool ConsoleCtrlHandler(uint ctrlType);

    /// <summary>Every process (pid, parent pid, exe name) from one Toolhelp snapshot; empty on failure.</summary>
    internal static List<ProcessEntry> ProcessEntries()
    {
        var result = new List<ProcessEntry>();
        var snapshot = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
        if (snapshot == InvalidHandle || snapshot == IntPtr.Zero)
        {
            return result;
        }

        try
        {
            var entry = new ProcessEntry32 { Size = (uint)Marshal.SizeOf<ProcessEntry32>() };
            for (var ok = Process32First(snapshot, ref entry); ok; ok = Process32Next(snapshot, ref entry))
            {
                result.Add(new ProcessEntry((int)entry.ProcessId, (int)entry.ParentProcessId, entry.ExeFile ?? ""));
            }
        }
        finally
        {
            CloseHandle(snapshot);
        }

        return result;
    }

    /// <summary>The creation time of a process (GetProcessTimes), null if it cannot be opened.</summary>
    internal static DateTimeOffset? CreationTime(int pid)
    {
        var handle = OpenProcess(ProcessQueryLimitedInformation, false, (uint)pid);
        if (handle == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            return GetProcessTimes(handle, out var creation, out _, out _, out _) && creation > 0
                ? new DateTimeOffset(DateTime.FromFileTimeUtc(creation)).ToLocalTime()
                : null;
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    /// <summary>
    ///     The command line of a process: NtQueryInformationProcess(ProcessCommandLineInformation) returns a UNICODE_STRING
    ///     (Length, MaximumLength, Buffer pointer into the same buffer) followed by the text. Null if not readable.
    /// </summary>
    internal static string? CommandLine(int pid)
    {
        var handle = OpenProcess(ProcessQueryLimitedInformation, false, (uint)pid);
        if (handle == IntPtr.Zero)
        {
            return null;
        }

        try
        {
            var status = NtQueryInformationProcess(handle, ProcessCommandLineInformation, IntPtr.Zero, 0, out var needed);
            if (status != StatusInfoLengthMismatch || needed <= 0)
            {
                return null;
            }

            var buffer = Marshal.AllocHGlobal(needed);
            try
            {
                if (NtQueryInformationProcess(handle, ProcessCommandLineInformation, buffer, needed, out _) != 0)
                {
                    return null;
                }

                var length = (ushort)Marshal.ReadInt16(buffer);
                var text = Marshal.ReadIntPtr(buffer, IntPtr.Size); // after Length, MaximumLength and the alignment padding
                return length == 0 || text == IntPtr.Zero ? "" : Marshal.PtrToStringUni(text, length / 2);
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        finally
        {
            CloseHandle(handle);
        }
    }

    /// <summary>The listener rows of one address family as raw bytes (empty on failure).</summary>
    internal static byte[] TcpTable(int addressFamily)
    {
        var size = 0;
        for (var attempt = 0; attempt < 5; attempt++)
        {
            var buffer = size == 0 ? IntPtr.Zero : Marshal.AllocHGlobal(size);
            try
            {
                var error = GetExtendedTcpTable(buffer, ref size, false, addressFamily, TcpTableOwnerPidListener, 0);
                if (error == 0 && buffer != IntPtr.Zero)
                {
                    var bytes = new byte[size];
                    Marshal.Copy(buffer, bytes, 0, size);
                    return bytes;
                }

                if (error != ErrorInsufficientBuffer)
                {
                    return [];
                }

                // The table may grow between the calls: ask again with the size just reported (plus some room).
                size += 1024;
            }
            finally
            {
                if (buffer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
        }

        return [];
    }
}
