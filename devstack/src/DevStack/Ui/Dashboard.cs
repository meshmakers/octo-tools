using System.ComponentModel;
using System.Diagnostics;
using Meshmakers.Octo.DevStack.Discovery;

namespace Meshmakers.Octo.DevStack.Ui;

/// <summary>What a browser launch did: opened, or why not (problem).</summary>
public sealed record BrowserLaunch(bool Opened, string? Problem);

/// <summary>Opens a URL in the developer's default browser. The seam of dashboard_open: tests pass a fake and never open a browser.</summary>
public interface IBrowserLauncher
{
    BrowserLaunch Open(string url);
}

/// <summary>
///     The default browser of this machine: Windows ShellExecute of the URL (in a desktop session), macOS <c>open &lt;url&gt;</c>,
///     Linux <c>xdg-open &lt;url&gt;</c> when the daemon has a display (DISPLAY or WAYLAND_DISPLAY) and xdg-open is on its PATH.
///     <paramref name="disabled"/> (the daemon's <c>--no-browser</c>) opens nothing.
/// </summary>
public sealed class SystemBrowser(bool disabled = false) : IBrowserLauncher
{
    private static readonly TimeSpan LauncherWait = TimeSpan.FromSeconds(5);

    /// <summary>How long the answer waits for the output of a launcher that ended (a browser it started may hold the pipes).</summary>
    private static readonly TimeSpan OutputDrainWait = TimeSpan.FromSeconds(1);

    public BrowserLaunch Open(string url)
    {
        if (disabled)
        {
            return new BrowserLaunch(false, "this daemon was started with --no-browser");
        }

        try
        {
            if (OperatingSystem.IsWindows())
            {
                if (!Environment.UserInteractive)
                {
                    return new BrowserLaunch(false, "the daemon runs without a desktop session");
                }

                using var process = Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
                return new BrowserLaunch(true, null);
            }

            if (OperatingSystem.IsMacOS())
            {
                return Run("open", url);
            }

            if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("DISPLAY")) && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("WAYLAND_DISPLAY")))
            {
                return new BrowserLaunch(false, "the daemon has no display (neither DISPLAY nor WAYLAND_DISPLAY is set in its environment)");
            }

            return OnPath("xdg-open") ? Run("xdg-open", url) : new BrowserLaunch(false, "xdg-open is not on the daemon's PATH");
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or IOException or PlatformNotSupportedException)
        {
            return new BrowserLaunch(false, e.Message);
        }
    }

    /// <summary>
    ///     Runs the launcher with the URL as its one argument (no shell). It normally hands the URL to the browser and exits; one
    ///     that still runs after a few seconds is the browser itself, so the page is open.
    /// </summary>
    private static BrowserLaunch Run(string command, string url)
    {
        var start = new ProcessStartInfo(command)
        {
            UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, CreateNoWindow = true
        };
        start.ArgumentList.Add(url);
        using var process = Process.Start(start) ?? throw new InvalidOperationException($"{command} did not start");
        var errors = new List<string>();
        process.ErrorDataReceived += (_, e) =>
        {
            if (!string.IsNullOrWhiteSpace(e.Data))
            {
                lock (errors)
                {
                    errors.Add(e.Data.Trim());
                }
            }
        };
        process.OutputDataReceived += (_, _) => { };
        process.BeginErrorReadLine();
        process.BeginOutputReadLine();
        process.StandardInput.Close();
        if (!process.WaitForExit(LauncherWait))
        {
            return new BrowserLaunch(true, null);
        }

        // The launcher ended; its output may still drain. Bounded: a browser it started can inherit the pipes and keep them
        // open until it closes, and the call must not wait for that.
        try
        {
            using var drain = new CancellationTokenSource(OutputDrainWait);
            process.WaitForExitAsync(drain.Token).GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            // What the launcher wrote so far is enough for the answer.
        }

        if (process.ExitCode == 0)
        {
            return new BrowserLaunch(true, null);
        }

        string detail;
        lock (errors)
        {
            detail = errors.Count > 0 ? $": {errors[0]}" : "";
        }

        return new BrowserLaunch(false, $"{command} exited with code {process.ExitCode}{detail}");
    }

    private static bool OnPath(string command) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
        .Any(folder => File.Exists(Path.Combine(folder, command)));
}

/// <summary>dashboard_open: the URL it opened (the daemon's own status page), whether a browser opened it, and what to do otherwise.</summary>
public sealed record DashboardOpenResult(string Url, bool Opened, string Note);

/// <summary>
///     The status page in the developer's browser. Only the daemon's own URL with one of the page's hash routes is ever opened,
///     never a URL from the caller: <see cref="UrlFor"/> builds it from the view and a lane that exists.
/// </summary>
/// <param name="baseUrl">The daemon's listen URL (loopback), e.g. http://127.0.0.1:5090.</param>
public sealed class Dashboard(string baseUrl, IBrowserLauncher browser)
{
    /// <summary>The views of the status page (hash routes, app.js route()); the first is the default.</summary>
    public static readonly IReadOnlyList<string> Views = ["stack", "lanes", "builds", "profiles", "config"];

    public string BaseUrl { get; } = baseUrl.TrimEnd('/');

    /// <summary>
    ///     The page's URL for <paramref name="view"/> (default stack) and <paramref name="lane"/>: a lane opens its place in the
    ///     lanes view (#/lanes/&lt;lane&gt;), with view=stack the sheet of its lane stack (#/stack/&lt;slot&gt;). An unknown view, an
    ///     unknown lane and a lane with another view are refused (ArgumentException) with what is allowed.
    /// </summary>
    public string UrlFor(string? view, string? lane, IReadOnlyList<EnvironmentInfo> lanes)
    {
        var name = string.IsNullOrWhiteSpace(view) ? null : view.Trim().ToLowerInvariant();
        if (name != null && !Views.Contains(name))
        {
            throw new ArgumentException($"There is no view '{view!.Trim()}'; the views are {string.Join(", ", Views)}.");
        }

        if (string.IsNullOrWhiteSpace(lane))
        {
            return $"{BaseUrl}/#/{name ?? Views[0]}";
        }

        var found = lanes.FirstOrDefault(l => l.Name == lane.Trim())
                    ?? throw new ArgumentException($"There is no lane '{lane.Trim()}' (lane_list): " +
                                                   (lanes.Count == 0 ? "there is no lane." : $"the lanes are {string.Join(", ", lanes.Select(l => l.Name))}."));
        return name switch
        {
            null or "lanes" => $"{BaseUrl}/#/lanes/{Uri.EscapeDataString(found.Name)}",
            "stack" => $"{BaseUrl}/#/stack/{Uri.EscapeDataString(found.Slot)}",
            _ => throw new ArgumentException($"lane applies to the views lanes (its place there, the default) and stack (its lane stack), not to {name}.")
        };
    }

    /// <summary>Opens <see cref="UrlFor"/> in the default browser; when that does not work the note says to open the URL by hand.</summary>
    public DashboardOpenResult Open(string? view, string? lane, IReadOnlyList<EnvironmentInfo> lanes)
    {
        var url = UrlFor(view, lane, lanes);
        BrowserLaunch launch;
        try
        {
            launch = browser.Open(url);
        }
        catch (Exception e) when (e is Win32Exception or InvalidOperationException or IOException)
        {
            launch = new BrowserLaunch(false, e.Message);
        }

        return launch.Opened
            ? new DashboardOpenResult(url, true, $"Opened {url} in the default browser of this machine. The page is read-only and refreshes every 5 s.")
            : new DashboardOpenResult(url, false, $"No browser opened ({launch.Problem ?? "unknown reason"}): open {url} by hand.");
    }
}
