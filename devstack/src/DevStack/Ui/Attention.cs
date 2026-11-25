using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Ui;

/// <summary>
///     One thing that needs the reader's eye: level stop | caution | foreign, kind (what it is about), the sentence the
///     status page shows, the page it links to, and for agents the tool call that explains it.
/// </summary>
public sealed record AttentionItem(string Level, string Kind, string Text, string Href)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Slot { get; init; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Service { get; init; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BuildId { get; init; }

    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Hint { get; init; }
}

/// <summary>
///     What needs attention, worst first: the list at the top of the status page's stack view (/api/overview attention) and
///     stack_attention. One function for both, so the page and the agents see the same list.
/// </summary>
public static class Attention
{
    private static readonly string[] Order = ["stop", "caution", "foreign"];

    public static IReadOnlyList<AttentionItem> Of(Overview o)
    {
        var items = new List<AttentionItem>();
        foreach (var problem in o.Stack.ConfigProblems ?? [])
        {
            items.Add(new AttentionItem("stop", "config", problem, "#/config/daemon") { Hint = "admin_config_inspect shows rootPath and defaultCheckout (the base lane)." });
        }

        foreach (var row in Rows(o))
        {
            var prefix = row.IsDefault ? "" : row.Name + "/";
            var href = "#/stack/" + Uri.EscapeDataString(row.Name);
            foreach (var s in row.Services.Where(s => s.State is "exited" or "unhealthy"))
            {
                items.Add(new AttentionItem(s.State == "exited" ? "stop" : "caution", "service",
                    $"{prefix}{s.Name} {(s.State == "exited" ? "exited" : "is not answering")}{(s.Detail is { Length: > 0 } d ? $" ({d})" : "")}.", href)
                {
                    Slot = row.Name, Service = s.Name,
                    Hint = $"service_logs(service=\"{s.Name}\"{(row.IsDefault ? "" : row.Env != null ? $", lane=\"{row.Env.Name}\"" : $", slot=\"{row.Name}\"")}) shows its log."
                });
            }

            foreach (var s in row.Services.Where(s => s.EntryAssemblyProblem != null))
            {
                items.Add(new AttentionItem("stop", "service", $"{prefix}{s.Name} runs another build than its folder holds: {s.EntryAssemblyProblem}.", href)
                    { Slot = row.Name, Service = s.Name, Hint = "stack_status shows entryAssembly; service_restart starts it from its folder again." });
            }

            if (row.Env?.Problem is { } envProblem)
            {
                items.Add(new AttentionItem("stop", "lane", $"Lane {row.Env.Name}: {envProblem}", "#/lanes/" + Uri.EscapeDataString(row.Env.Name))
                    { Slot = row.Name, Hint = $"lane_list(lane=\"{row.Env.Name}\") shows the lane." });
            }
        }

        // The newest run per kind and target; a run whose environment or checkout is gone is history, not a current failure,
        // and so is a failed repo build that a later range or all build of its lane built again.
        var current = o.Builds.Where(b => b.Gone == null).ToList();
        var latest = current.GroupBy(b => $"{b.Kind}:{b.Target}").Select(g => g.First());
        foreach (var b in latest.Where(b => b.State is "failed" or "orphaned" && !RebuiltLater(b, current)))
        {
            var test = b.Kind == "test";
            var what = test ? Place(b.Target, o) : $"Build of {Place(b.Target, o)}";
            var verb = b.State == "failed" ? "failed" : "lost its process";
            var repos = FailedRepos(b);
            items.Add(new AttentionItem("stop", test ? "test" : "build", $"{what} {verb}{(b.Outcome?.Summary is { Length: > 0 } sum ? $": {sum}" : ".")}",
                "#/builds/" + Uri.EscapeDataString(b.Id))
            {
                BuildId = b.Id,
                Hint = test
                    ? $"job_status(id=\"{b.Id}\") lists the failed tests; it clears once a newer run of the same target succeeds."
                    : $"job_status(id=\"{b.Id}\") shows the errors; it clears once a newer build of the same target succeeds" +
                      (repos.Count > 0 ? $" or a later range or all build of the lane builds {string.Join(", ", repos)}." : ".")
            });
        }

        // A running repo or test project far beyond what it usually takes probably hangs (job_stats limitSeconds).
        foreach (var b in o.Builds.Where(b => b.State == "running" && b.Progress != null))
        {
            var test = b.Kind == "test";
            var now = b.Progress!.Running ?? (b.Progress.Current is { } c ? [c] : []);
            foreach (var item in now.Where(n => n.Overdue == true))
            {
                var name = item.Project ?? item.Repo ?? "";
                var what = test
                    ? $"Test project {name} has been running for {Span(item.Seconds)} ({Place(b.Target, o)})"
                    : $"{name} has been building for {Span(item.Seconds)} in the build of {Place(b.Target, o)}";
                items.Add(new AttentionItem("caution", "overdue", $"{what}; it usually takes {Span(item.TypicalSeconds ?? 0)} - it may hang.",
                    "#/builds/" + Uri.EscapeDataString(b.Id))
                {
                    BuildId = b.Id,
                    Hint = $"job_output(id=\"{b.Id}\", repo=\"{name}\") shows its log; job_cancel(owner=\"{b.Owner}\", id=\"{b.Id}\") stops the job " +
                           (b.Env is { } lane ? $"(or a session of lane {lane} with lane=\"{lane}\")." : "(only its owner).")
                });
            }
        }

        foreach (var refusal in o.BuildRefusals.Where(r => r.Conflicts.Count > 0).Take(3))
        {
            items.Add(new AttentionItem("caution", "refusal",
                    $"A {refusal.Kind} build of {Place(refusal.Target, o)} was refused at {refusal.At.ToLocalTime():HH:mm}: services run from it.", "#/builds")
                { Hint = "job_refusals lists the conflicts; build_plan shows them before a build." });
        }

        if (o.Stack.Running && o.Stack.Profile is { Exact: false } drift)
        {
            items.Add(new AttentionItem("caution", "drift", $"The shared stack differs from profile {drift.Profile} in {Count(drift.DriftCount, "place")}.",
                "#/stack/default") { Slot = SlotInfo.DefaultName, Hint = "stack_status shows profile.drift." });
        }

        var groups = o.Stack.External.Groups
            .Select(g => (Group: g, Members: o.Stack.External.Services.Where(s => s.Group == g.Key).ToList())).ToList();
        if (groups.Count > 1)
        {
            var n = o.Stack.External.Services.Count;
            items.Add(new AttentionItem("foreign", "external",
                    $"{Count(n, "process", "processes")} on service ports run outside octo-devstack ({string.Join(", ", groups.Select(x => OriginShort(x.Group.Origin)).Distinct())}).",
                    "#/stack/default")
                { Hint = "stack_status lists them under external, with who started them and how to stop them." });
        }
        else
        {
            foreach (var (g, members) in groups)
            {
                var ports = members.SelectMany(m => m.Ports).ToList();
                var slot = members.FirstOrDefault()?.SlotHint ?? SlotInfo.DefaultName;
                items.Add(new AttentionItem("foreign", "external",
                        $"{string.Join(", ", g.Services)} {(ports.Count > 0 ? $"on {string.Join(", ", ports)} " : "")}{(g.Services.Count == 1 ? "runs" : "run")} outside octo-devstack ({OriginShort(g.Origin)}).",
                        "#/stack/" + Uri.EscapeDataString(slot))
                    { Slot = slot, Hint = "stack_status lists them under external, with who started them and how to stop them." });
            }
        }

        return items.OrderBy(i => Array.IndexOf(Order, i.Level)).ToList();
    }

    /// <summary>
    ///     The lane repositories a failed build failed in: kind=repo the repository it built, when that is a folder of its lane
    ///     (not a worktree elsewhere); range and all the repositories the cmdlet reported failed. Empty for any other build and
    ///     when no repository is known (a failed preflight).
    /// </summary>
    internal static IReadOnlyList<string> FailedRepos(BuildStatus b)
    {
        if (b.Kind == "repo")
        {
            var parent = Path.GetDirectoryName(b.Target.TrimEnd('/', '\\'));
            var lane = b.Lane?.Path ?? parent;
            return parent != null && lane != null && PathScope.SamePath(parent, lane) ? [Path.GetFileName(b.Target.TrimEnd('/', '\\'))] : [];
        }

        if (b.Kind is not ("range" or "all"))
        {
            return [];
        }

        return (b.Outcome?.FailedRepos ?? (b.Outcome?.FailedRepo is { } one ? [one] : []))
            .Concat(b.Progress?.Rows.Where(r => r.State == "failed").Select(r => r.Name) ?? [])
            .Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    /// <summary>
    ///     Whether a failed build of lane repositories (<see cref="FailedRepos"/>) was made good by later range or all builds of
    ///     the same lane: each repository it failed in was built (repository state done) by one of them, whatever became of the
    ///     rest of that build - a failure of it is its own entry. <paramref name="newestFirst"/>: the builds as job_list orders
    ///     them.
    /// </summary>
    internal static bool RebuiltLater(BuildStatus failed, IReadOnlyList<BuildStatus> newestFirst)
    {
        var repos = FailedRepos(failed);
        var lane = failed.Kind == "repo" ? failed.Lane?.Path ?? Path.GetDirectoryName(failed.Target.TrimEnd('/', '\\')) : failed.Lane?.Path;
        if (repos.Count == 0 || lane == null)
        {
            return false;
        }

        var later = newestFirst.TakeWhile(b => !ReferenceEquals(b, failed))
            .Where(b => b.Kind is "range" or "all" && b.Lane?.Path is { } path && PathScope.SamePath(path, lane)).ToList();
        return repos.All(repo => later.Any(b => b.Progress?.Rows.Any(r => r.State == "done" && string.Equals(r.Name, repo, StringComparison.OrdinalIgnoreCase)) == true));
    }

    private sealed record ServiceRow(string Name, string State, string? Detail, string? EntryAssemblyProblem);

    private sealed record SlotRow(string Name, bool IsDefault, EnvironmentRow? Env, IReadOnlyList<ServiceRow> Services);

    // One row per stack (a lane's stack is the slot named after the lane) with the services the daemon runs there,
    // in the order of the configuration.
    private static List<SlotRow> Rows(Overview o)
    {
        var configured = o.Configured.Select(c => c.Name).ToList();
        int Rank(string name) => configured.IndexOf(name) is >= 0 and var i ? i : int.MaxValue;

        var rows = new List<SlotRow>();
        foreach (var slot in o.Slots)
        {
            var services = slot.Name == SlotInfo.DefaultName
                ? DefaultServices(o)
                : slot.Services.Select(s => new ServiceRow(s.Name, s.State, s.State == "unhealthy" ? s.HealthDetail : null, null)).ToList();
            rows.Add(new SlotRow(slot.Name, slot.Name == SlotInfo.DefaultName, o.Environments.FirstOrDefault(e => e.Slot == slot.Name), services));
        }

        if (rows.All(r => !r.IsDefault))
        {
            rows.Insert(0, new SlotRow(SlotInfo.DefaultName, true, null, DefaultServices(o)));
        }

        foreach (var env in o.Environments.Where(e => rows.All(r => r.Name != e.Slot)))
        {
            rows.Add(new SlotRow(env.Slot, false, env, []));
        }

        return rows.Select(r => r with { Services = r.Services.Select((s, i) => (s, i)).OrderBy(x => Rank(x.s.Name)).ThenBy(x => x.i).Select(x => x.s).ToList() })
            .ToList();
    }

    private static List<ServiceRow> DefaultServices(Overview o) =>
        o.Stack.Services.Select(s => new ServiceRow(s.Name, s.State, s.State switch
        {
            "exited" => $"{(s.ExitCode is { } code ? $"exit code {code}, " : "")}{s.ExitedAt?.ToLocalTime():HH:mm}",
            "healthy" => null,
            _ => s.HealthDetail
        }, s.EntryAssemblyProblem)).ToList();

    private static string OriginShort(ExternalOrigin? origin) => origin == null ? "Another process" : origin.Kind switch
    {
        "start-octo" => "Start-Octo",
        "orphan" => "Leftover process",
        "session" => "Claude Code session",
        _ => origin.LauncherCommand ?? "Another process"
    };

    /// <summary>A duration as the reader says it: 45 s, 7 min, 1 h 20 min.</summary>
    internal static string Span(double seconds)
    {
        if (seconds < 90)
        {
            return $"{Math.Round(seconds)} s";
        }

        var minutes = (int)Math.Round(seconds / 60);
        return minutes < 60 ? $"{minutes} min" : $"{minutes / 60} h {minutes % 60} min";
    }

    private static string Count(int n, string one, string? many = null) => $"{n} {(n == 1 ? one : many ?? one + "s")}";

    /// <summary>A path as the reader knows it: relative to the root folder, else to the home folder (~/...). Anything else stays.</summary>
    internal static string Place(string path, Overview o)
    {
        if (string.IsNullOrEmpty(path))
        {
            return "";
        }

        var rel = Relative(path, o.RootPath);
        if (rel != path)
        {
            return rel;
        }

        rel = Relative(path, o.Home);
        return rel != path ? "~/" + rel : path;
    }

    private static string Relative(string path, string? @base)
    {
        if (string.IsNullOrEmpty(@base))
        {
            return path;
        }

        if (IsWindowsPath(path) || IsWindowsPath(@base))
        {
            var p = path.Replace('\\', '/');
            var b = @base.Replace('\\', '/').TrimEnd('/') + "/";
            return p.StartsWith(b, StringComparison.OrdinalIgnoreCase) ? p[b.Length..] : path;
        }

        var prefix = @base.EndsWith('/') ? @base : @base + "/";
        return path.StartsWith(prefix, StringComparison.Ordinal) ? path[prefix.Length..] : path;
    }

    private static bool IsWindowsPath(string p) =>
        (p.Length >= 3 && char.IsAsciiLetter(p[0]) && p[1] == ':' && p[2] is '\\' or '/') || p.StartsWith(@"\\", StringComparison.Ordinal);
}
