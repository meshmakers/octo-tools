using System.Net;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.StaticFiles;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>One path proxy of the app host: requests whose path matches go to the target, optionally with a part of the path replaced.</summary>
public sealed record AppHostProxy(Regex Path, string Target, string? RewriteFrom, string? RewriteTo)
{
    /// <summary>"&lt;path regex&gt;=&lt;target url&gt;" or "&lt;path regex&gt;=&lt;target url&gt;|&lt;from&gt;=&gt;&lt;to&gt;".</summary>
    public static AppHostProxy Parse(string value)
    {
        var rule = value;
        string? from = null;
        string? to = null;
        var bar = value.LastIndexOf('|');
        if (bar > 0 && value[(bar + 1)..].Split("=>", 2) is { Length: 2 } rewrite)
        {
            rule = value[..bar];
            (from, to) = (rewrite[0], rewrite[1]);
        }

        var split = rule.LastIndexOf("=http", StringComparison.OrdinalIgnoreCase);
        if (split <= 0)
        {
            throw new ArgumentException($"--proxy '{value}': use '<path regex>=<http(s) target>[|<from>=><to>]'.");
        }

        return new AppHostProxy(new Regex(rule[..split], RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1)), rule[(split + 1)..].TrimEnd('/'), from, to);
    }

    /// <summary>The target URL of a request path, or null when the rule does not apply.</summary>
    public string? TargetOf(string path, string query) =>
        Path.IsMatch(path) ? Target + (RewriteFrom is { Length: > 0 } ? path.Replace(RewriteFrom, RewriteTo ?? "", StringComparison.Ordinal) : path) + query : null;
}

/// <summary>What <c>--serve-app</c> was started with.</summary>
public sealed record AppHostOptions(string Root, string? Overlay, string Url, IReadOnlyList<AppHostProxy> Proxies)
{
    public static AppHostOptions Parse(IReadOnlyList<string> args)
    {
        string? root = null, overlay = null, url = null;
        var proxies = new List<AppHostProxy>();
        for (var i = 0; i < args.Count; i++)
        {
            string Next(string name) => i + 1 < args.Count ? args[++i] : throw new ArgumentException($"{name} needs a value.");
            switch (args[i])
            {
                case AppHost.Switch:
                    break;
                case "--root":
                    root = Next("--root");
                    break;
                case "--overlay":
                    overlay = Next("--overlay");
                    break;
                case "--url":
                    url = Next("--url");
                    break;
                case "--proxy":
                    proxies.Add(AppHostProxy.Parse(Next("--proxy")));
                    break;
                default:
                    throw new ArgumentException($"Unknown argument '{args[i]}'. Usage: {AppHost.Switch} --root <dir> --url <loopback url> [--overlay <dir>] [--proxy <rule>]...");
            }
        }

        if (root == null || url == null)
        {
            throw new ArgumentException($"{AppHost.Switch} needs --root <dir> and --url <loopback url>.");
        }

        return new AppHostOptions(Path.GetFullPath(root), overlay == null ? null : Path.GetFullPath(overlay), url, proxies);
    }
}

/// <summary>
///     A helper mode of the daemon binary (<c>octo-devstack.dll --serve-app</c>), started as a normal service: serves the
///     build output of a single-page app on a loopback URL (HTTPS with the ASP.NET development certificate), with the files
///     of an overlay folder laid over it - a generated runtime config with the backend URLs of a stack slot - and an
///     index.html fallback for the app's routes. Path proxies stand in for what the app's dev server or nginx forwards.
///     Read-only towards the app: nothing is written into the repository.
/// </summary>
public static class AppHost
{
    public const string Switch = "--serve-app";

    private static readonly FileExtensionContentTypeProvider ContentTypes = new();

    public static async Task<int> RunAsync(string[] args)
    {
        AppHostOptions options;
        try
        {
            options = AppHostOptions.Parse(args);
        }
        catch (ArgumentException e)
        {
            Console.Error.WriteLine(e.Message);
            return 2;
        }

        if (!Uri.TryCreate(options.Url, UriKind.Absolute, out var uri) || !IsLoopback(uri.Host))
        {
            Console.Error.WriteLine($"--url must be a loopback URL, not '{options.Url}'.");
            return 2;
        }

        if (!File.Exists(Path.Combine(options.Root, "index.html")))
        {
            Console.Error.WriteLine($"There is no index.html in {options.Root}: the app is not built. Build it first (lane_build for a " +
                                    "lane, or the app's build.ps1), then start the service again.");
            return 3;
        }

        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls(options.Url);
        builder.Logging.AddSimpleConsole(o =>
        {
            o.SingleLine = true;
            o.TimestampFormat = "HH:mm:ss ";
        });
        // Not every request (the daemon's health probe asks every few seconds): the log holds starts, proxies' failures and errors.
        builder.Logging.AddFilter("Microsoft.AspNetCore", LogLevel.Warning);
        var app = builder.Build();
        using var http = new HttpClient(new HttpClientHandler
        {
            // Local dev only: the backend services use the ASP.NET development certificate.
            ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator,
            AllowAutoRedirect = false
        });
        app.Run(context => HandleAsync(context, options, http));
        app.Logger.LogInformation("Serving {Root} on {Url}{Overlay}{Proxies}", options.Root, options.Url,
            options.Overlay == null ? "" : $", overlay {options.Overlay}",
            options.Proxies.Count == 0 ? "" : $", proxies: {string.Join("; ", options.Proxies.Select(p => $"{p.Path} -> {p.Target}"))}");
        await app.RunAsync();
        return 0;
    }

    /// <summary>The file a request path is answered with: the overlay's, else the root's, else index.html for a route of the app; null = 404.</summary>
    public static string? Resolve(AppHostOptions options, string requestPath)
    {
        var relative = Uri.UnescapeDataString(requestPath).TrimStart('/');
        foreach (var folder in new[] { options.Overlay, options.Root })
        {
            if (folder == null || relative.Length == 0)
            {
                continue;
            }

            var candidate = Path.GetFullPath(Path.Combine(folder, relative));
            if (candidate.StartsWith(folder + Path.DirectorySeparatorChar, StringComparison.Ordinal) && File.Exists(candidate))
            {
                return candidate;
            }
        }

        // A path with a file extension that does not exist is a missing file; anything else is a route of the app.
        return Path.HasExtension(relative) ? null : Path.Combine(options.Root, "index.html");
    }

    private static async Task HandleAsync(HttpContext context, AppHostOptions options, HttpClient http)
    {
        var path = context.Request.Path.Value ?? "/";
        foreach (var proxy in options.Proxies)
        {
            if (proxy.TargetOf(path, context.Request.QueryString.Value ?? "") is { } target)
            {
                await ForwardAsync(context, http, target);
                return;
            }
        }

        if (!HttpMethods.IsGet(context.Request.Method) && !HttpMethods.IsHead(context.Request.Method))
        {
            context.Response.StatusCode = StatusCodes.Status405MethodNotAllowed;
            return;
        }

        var file = Resolve(options, path);
        if (file == null)
        {
            context.Response.StatusCode = StatusCodes.Status404NotFound;
            return;
        }

        context.Response.ContentType = ContentTypes.TryGetContentType(file, out var type) ? type : "application/octet-stream";
        // The runtime config and index.html change with every start and build; hashed bundles may be cached.
        var name = Path.GetFileName(file);
        context.Response.Headers.CacheControl = name is "index.html" || name.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ? "no-store" : "no-cache";
        if (HttpMethods.IsGet(context.Request.Method))
        {
            await context.Response.SendFileAsync(file);
        }
    }

    private static async Task ForwardAsync(HttpContext context, HttpClient http, string target)
    {
        using var request = new HttpRequestMessage(new HttpMethod(context.Request.Method), target);
        if (context.Request.ContentLength > 0 || context.Request.Headers.ContainsKey("Transfer-Encoding"))
        {
            request.Content = new StreamContent(context.Request.Body);
        }

        foreach (var header in context.Request.Headers)
        {
            if (header.Key.Equals("Host", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!request.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray()))
            {
                request.Content?.Headers.TryAddWithoutValidation(header.Key, header.Value.ToArray());
            }
        }

        try
        {
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, context.RequestAborted);
            context.Response.StatusCode = (int)response.StatusCode;
            foreach (var header in response.Headers.Concat(response.Content.Headers))
            {
                if (!header.Key.Equals("Transfer-Encoding", StringComparison.OrdinalIgnoreCase))
                {
                    context.Response.Headers[header.Key] = header.Value.ToArray();
                }
            }

            await response.Content.CopyToAsync(context.Response.Body, context.RequestAborted);
        }
        catch (HttpRequestException e)
        {
            context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("AppHost")
                .LogWarning("Proxy target {Target} did not answer: {Message}", target, e.Message);
            context.Response.StatusCode = StatusCodes.Status502BadGateway;
            await context.Response.WriteAsync($"The proxy target {target} did not answer: {e.Message}");
        }
    }

    private static bool IsLoopback(string host) =>
        host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || (IPAddress.TryParse(host.Trim('[', ']'), out var address) && IPAddress.IsLoopback(address));
}
