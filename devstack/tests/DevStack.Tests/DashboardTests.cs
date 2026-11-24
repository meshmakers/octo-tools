using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Tools;
using Meshmakers.Octo.DevStack.Ui;
using ModelContextProtocol;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     dashboard_open: only the daemon's own status page with a known hash route is opened, through the browser seam - a fake
///     here, so no test ever opens a browser.
/// </summary>
public sealed class DashboardTests : IDisposable
{
    private const string Base = "http://127.0.0.1:5198";
    private readonly TestCheckout _checkout = new();
    private readonly FakeBrowser _browser = new();

    public void Dispose() => _checkout.Dispose();

    private sealed class FakeBrowser : IBrowserLauncher
    {
        public List<string> Opened { get; } = [];
        public BrowserLaunch Answer { get; set; } = new(true, null);

        public BrowserLaunch Open(string url)
        {
            Opened.Add(url);
            return Answer;
        }
    }

    private static EnvironmentInfo Lane(string name, string? slot = null) =>
        new(name, "/root/wt-" + name, new EnvironmentManifest(1, name, "AB#1", "branches/main", null, "o", [], slot), "/root/branches/main", null);

    [Fact]
    public void The_url_is_the_daemons_page_with_a_view_and_a_lane_that_exist()
    {
        var dashboard = new Dashboard(Base + "/", _browser);
        IReadOnlyList<EnvironmentInfo> lanes = [Lane("ab1-one"), Lane("ab2-two", slot: "ab2-slot")];

        dashboard.UrlFor(null, null, lanes).Should().Be($"{Base}/#/stack", "the default view; a trailing slash of the listen URL is dropped");
        foreach (var view in Dashboard.Views)
        {
            dashboard.UrlFor(view, null, lanes).Should().Be($"{Base}/#/{view}");
        }

        dashboard.UrlFor(" Lanes ", null, lanes).Should().Be($"{Base}/#/lanes");
        dashboard.UrlFor(null, "ab1-one", lanes).Should().Be($"{Base}/#/lanes/ab1-one", "a lane alone opens its place in the lanes view");
        dashboard.UrlFor("lanes", "ab1-one", lanes).Should().Be($"{Base}/#/lanes/ab1-one");
        dashboard.UrlFor("stack", "ab2-two", lanes).Should().Be($"{Base}/#/stack/ab2-slot", "view=stack shows the lane's stack, the slot of its manifest");

        var unknownView = () => dashboard.UrlFor("https://example.com", null, lanes);
        unknownView.Should().Throw<ArgumentException>().WithMessage("There is no view 'https://example.com'; the views are stack, lanes, builds, profiles, config.");
        var unknownLane = () => dashboard.UrlFor(null, "../x", lanes);
        unknownLane.Should().Throw<ArgumentException>().WithMessage("There is no lane '../x' (lane_list): the lanes are ab1-one, ab2-two.");
        var noLanes = () => dashboard.UrlFor(null, "ab1-one", []);
        noLanes.Should().Throw<ArgumentException>().WithMessage("*there is no lane.");
        var otherView = () => dashboard.UrlFor("builds", "ab1-one", lanes);
        otherView.Should().Throw<ArgumentException>().WithMessage("lane applies to the views lanes*and stack*not to builds.");
        _browser.Opened.Should().BeEmpty("building a URL opens nothing");
    }

    [Fact]
    public void Open_hands_the_url_to_the_browser_and_says_to_open_it_by_hand_when_that_fails()
    {
        var dashboard = new Dashboard(Base, _browser);

        var opened = dashboard.Open("builds", null, []);
        opened.Should().BeEquivalentTo(new { Url = $"{Base}/#/builds", Opened = true });
        opened.Note.Should().StartWith($"Opened {Base}/#/builds in the default browser");
        _browser.Opened.Should().Equal($"{Base}/#/builds");

        _browser.Answer = new BrowserLaunch(false, "the daemon has no display (neither DISPLAY nor WAYLAND_DISPLAY is set in its environment)");
        var headless = dashboard.Open(null, null, []);
        headless.Opened.Should().BeFalse();
        headless.Note.Should().Be($"No browser opened (the daemon has no display (neither DISPLAY nor WAYLAND_DISPLAY is set in its environment)): open {Base}/#/stack by hand.");

        var refused = () => dashboard.Open("nope", null, []);
        refused.Should().Throw<ArgumentException>();
        _browser.Opened.Should().HaveCount(2, "a refused view opens nothing");

        var json = JsonSerializer.SerializeToNode(headless, McpJsonUtilities.DefaultOptions)!.AsObject();
        json.Select(p => p.Key).Should().Equal("url", "opened", "note");
    }

    [Fact]
    public void The_tool_reads_the_lanes_and_refuses_with_their_names()
    {
        var store = _checkout.WriteConfig("""
                                            alpha:
                                              repo: octo-a
                                          """);
        var folder = Path.Combine(_checkout.Root, "wt-ab1-one");
        Directory.CreateDirectory(Path.Combine(folder, ".octo"));
        File.WriteAllText(EnvironmentDiscovery.ManifestPath(folder),
            """{"schemaVersion":1,"name":"ab1-one","workItem":"AB#1","base":"branches/main","owner":"o","repos":[]}""");
        var tools = new DashboardTools(new Dashboard(Base, _browser), store);

        tools.Open(lane: "ab1-one").Url.Should().Be($"{Base}/#/lanes/ab1-one");
        var unknown = () => tools.Open(lane: "ab9-gone");
        unknown.Should().Throw<McpException>().WithMessage("There is no lane 'ab9-gone' (lane_list): the lanes are ab1-one.");
        _browser.Opened.Should().Equal($"{Base}/#/lanes/ab1-one");
    }

    [Fact]
    public void A_daemon_started_with_no_browser_opens_nothing()
    {
        var launch = new SystemBrowser(disabled: true).Open($"{Base}/#/stack");

        launch.Should().Be(new BrowserLaunch(false, "this daemon was started with --no-browser"));
        new Dashboard(Base, new SystemBrowser(disabled: true)).Open(null, null, []).Note.Should().Contain("--no-browser").And.Contain("by hand");
    }
}
