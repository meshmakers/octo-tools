using System.Net;
using System.Net.Sockets;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     Ports for tests that rely on a port staying closed, or open it later themselves. A port taken by binding port 0 and
///     released again comes from the ephemeral range, which the OS hands out again to the next socket bound to port 0 -
///     another test's listener, Kestrel, an outgoing connection - and a port "nobody opens" was then open (a rare flake under
///     load). These ports come from 20000-31999, outside the ephemeral range of every OS (Windows and macOS 49152-65535,
///     Linux 32768-60999), so no port-0 socket gets one. Each call returns another port; a port that cannot be bound (used,
///     or excluded on Windows, e.g. by Hyper-V) is skipped.
/// </summary>
internal static class TestPorts
{
    private const int First = 20000;
    private const int Last = 31999;
    private static int _next = First + Random.Shared.Next(0, (Last - First) / 2);

    public static int Free()
    {
        for (var attempt = 0; attempt <= Last - First; attempt++)
        {
            var port = First + (Interlocked.Increment(ref _next) - First) % (Last - First + 1);
            try
            {
                using var probe = new TcpListener(IPAddress.Loopback, port);
                probe.Start();
                return port;
            }
            catch (SocketException)
            {
                // in use, or in a range Windows excludes: the next one
            }
        }

        throw new InvalidOperationException($"No free port between {First} and {Last}.");
    }
}
