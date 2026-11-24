using System.Net.Sockets;

namespace Meshmakers.Octo.DevStack.Common;

/// <summary>Port and HTTP checks against localhost.</summary>
public static class Probes
{
    // Local dev only: the services use the ASP.NET dev certificate, which the daemon need not trust.
    private static readonly HttpClient Http = new(new HttpClientHandler
    {
        ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
    }) { Timeout = TimeSpan.FromSeconds(3) };

    public static async Task<bool> IsPortOpenAsync(int port, TimeSpan timeout)
    {
        using var client = new TcpClient();
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await client.ConnectAsync("127.0.0.1", port, cts.Token);
            return true;
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException)
        {
            return false;
        }
    }

    /// <summary>
    ///     Whether a TLS handshake on the port completes (certificate not validated: the ASP.NET dev certificate). A bare TCP
    ///     connect to an HTTPS endpoint makes Kestrel log "Failed to authenticate HTTPS connection" on every probe; a finished
    ///     handshake without a request logs nothing.
    /// </summary>
    public static async Task<bool> IsTlsOpenAsync(int port, TimeSpan timeout)
    {
        using var client = new TcpClient();
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await client.ConnectAsync("127.0.0.1", port, cts.Token);
            await using var ssl = new System.Net.Security.SslStream(client.GetStream(), false, (_, _, _, _) => true);
            await ssl.AuthenticateAsClientAsync(new System.Net.Security.SslClientAuthenticationOptions { TargetHost = "localhost" }, cts.Token);
            return true;
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException or IOException or System.Security.Authentication.AuthenticationException)
        {
            return false;
        }
    }

    /// <summary>The ports a service's --urls declares as https (they get a TLS handshake instead of a bare connect).</summary>
    public static HashSet<int> HttpsPorts(IReadOnlyList<string> args)
    {
        var result = new HashSet<int>();
        foreach (var arg in args.Where(a => a.StartsWith("--urls=", StringComparison.Ordinal)))
        {
            foreach (var url in arg["--urls=".Length..].Split(';', StringSplitOptions.RemoveEmptyEntries))
            {
                if (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && url.LastIndexOf(':') is var colon and > 7 &&
                    int.TryParse(url[(colon + 1)..].TrimEnd('/'), out var port))
                {
                    result.Add(port);
                }
            }
        }

        return result;
    }

    /// <summary>
    ///     Healthy = the URL answers below 500, or (without URL) the first port accepts connections - with a TLS handshake when
    ///     the service's --urls serves it as https (<paramref name="args"/>).
    /// </summary>
    public static async Task<(bool Healthy, string Detail)> CheckAsync(string? healthUrl, IReadOnlyList<int> ports, IReadOnlyList<string>? args = null)
    {
        if (!string.IsNullOrEmpty(healthUrl))
        {
            try
            {
                using var response = await Http.GetAsync(healthUrl);
                var code = (int)response.StatusCode;
                return (code < 500, $"GET {healthUrl} -> {code}");
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
            {
                return (false, $"GET {healthUrl} -> {e.GetType().Name}: {e.Message}");
            }
        }

        if (ports.Count == 0)
        {
            return (true, "no port or healthUrl configured; process alive");
        }

        if (args != null && HttpsPorts(args).Contains(ports[0]))
        {
            var tls = await IsTlsOpenAsync(ports[0], TimeSpan.FromSeconds(2));
            return (tls, tls ? $"port {ports[0]} answers TLS" : $"port {ports[0]} not answering TLS yet");
        }

        var open = await IsPortOpenAsync(ports[0], TimeSpan.FromSeconds(1));
        return (open, open ? $"port {ports[0]} open" : $"port {ports[0]} not open yet");
    }
}
