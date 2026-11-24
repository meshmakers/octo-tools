using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>A running (or expected) process for profile matching. Empty args/ports mean "not known".</summary>
public sealed record ObservedService(string Name, string? RepoPath, IReadOnlyList<string> Args, IReadOnlyList<int> Ports);

public sealed record ObservedStack(string? Checkout, string? Configuration, IReadOnlyList<ObservedService> Services);

/// <summary>One difference between a running stack and a profile. Kinds: checkout, configuration, serviceMissing, serviceExtra, source, args, ports, profileDeleted.</summary>
public sealed record ProfileDrift(string Kind, string? Service, string Detail);

/// <summary>Which profile a stack runs and how far it is from it.</summary>
public sealed record ProfileMatch(string Profile, string? Description, bool Exact, bool Edited, int DriftCount, IReadOnlyList<ProfileDrift> Drift);

/// <summary>
///     Answers "which profile is running": compares an observed stack (the daemon's, or a group of processes it did not
///     start) with the services a profile would start. Environment is not compared (external processes do not show it).
/// </summary>
public static class ProfileMatcher
{
    /// <summary>A stack outside the daemon "looks like" the best profile up to this many differences.</summary>
    public const int Threshold = 3;

    private const int MaxTokens = 5;

    private sealed record Expected(string Name, string Base, string RepoPath, IReadOnlyList<string> Args, IReadOnlyList<int> Ports, bool Optional);

    /// <summary>
    ///     Compares with one profile. <paramref name="recordedHash"/>: hash at start time, sets Edited when it changed since.
    ///     <paramref name="slots"/> names the slot to compare in (the expected ports are shifted by its offset); without it the
    ///     profile's own slot is looked up the same way, else the configured ports are expected.
    /// </summary>
    public static ProfileMatch Compare(DevStackConfig config, string profile, ObservedStack observed, string? recordedHash = null,
        Func<string, SlotInfo?>? slots = null)
    {
        if (!config.Profiles.TryGetValue(profile, out var definition))
        {
            return new ProfileMatch(profile, null, false, true, 1, [new ProfileDrift("profileDeleted", null, "the profile no longer exists")]);
        }

        var resolved = ProfileResolver.Resolve(config, profile, null);
        resolved = InSlot(resolved, slots?.Invoke(resolved.Slot));
        var drift = new List<ProfileDrift>();
        var expectedContext = ProfileResolver.DryRunContext(config, resolved.Checkout, resolved.Configuration);
        // An environment whose base is the profile's lane is that lane plus the environment's repos: no checkout difference
        // (the services are compared through the environment's chain below).
        var observedEnv = observed.Checkout == null ? null : Discovery.EnvironmentDiscovery.OfCheckout(observed.Checkout, expectedContext.RootPath);
        var envOnProfileLane = observedEnv?.BasePath != null && SamePath(observedEnv.BasePath, expectedContext.Checkout);
        if (observed.Checkout != null && !SamePath(observed.Checkout, expectedContext.Checkout) && !envOnProfileLane)
        {
            drift.Add(new ProfileDrift("baseLane", null, $"runs from {Relative(observed.Checkout, expectedContext.RootPath)}, profile: {resolved.Checkout}"));
        }

        if (observed.Configuration != null && !string.Equals(observed.Configuration, resolved.Configuration, StringComparison.OrdinalIgnoreCase))
        {
            drift.Add(new ProfileDrift("configuration", null, $"runs {observed.Configuration}, profile: {resolved.Configuration}"));
        }

        // Plan in the observed checkout, so a different lane is one difference and not one per service.
        // An environment as the observed checkout brings its chain along: its repos from the manifest, the rest from its base.
        var context = observed.Checkout != null
            ? expectedContext with { Checkout = observed.Checkout, Environment = observedEnv?.Name, Base = observedEnv?.BasePath, EnvironmentRepos = observedEnv?.RepoPaths() }
            : expectedContext;
        drift.AddRange(CompareServices(ExpectedServices(resolved, context), observed.Services, context.RootPath));

        var hash = ProfileResolver.Hash(config, profile);
        return new ProfileMatch(profile, definition.Description, drift.Count == 0, recordedHash != null && recordedHash != hash, drift.Count, drift);
    }

    /// <summary>The expected services in a slot: ports, --urls and health URLs shifted (the default slot or none: unchanged).</summary>
    private static ResolvedStart InSlot(ResolvedStart resolved, SlotInfo? slot) =>
        slot == null || slot.IsDefault ? resolved : resolved with { Config = SlotDeriver.ShiftPorts(resolved.Config, slot.PortOffset) };

    /// <summary>The profile closest to <paramref name="observed"/>: an exact match, or the best one with at most <see cref="Threshold"/> differences.</summary>
    public static ProfileMatch? Best(DevStackConfig config, ObservedStack observed, Func<string, SlotInfo?>? slots = null)
    {
        ProfileMatch? best = null;
        foreach (var name in config.Profiles.Keys.Order(StringComparer.Ordinal))
        {
            ProfileMatch match;
            try
            {
                // A profile none of whose services runs is no match, however few the differences (a lone frontend is not core-identity).
                var services = ProfileResolver.Resolve(config, name, null).Services;
                if (!observed.Services.Any(o => services.Contains(o.Name)))
                {
                    continue;
                }

                match = Compare(config, name, observed, null, slots);
            }
            catch (InvalidOperationException)
            {
                continue;
            }

            if (best == null || match.DriftCount < best.DriftCount)
            {
                best = match;
            }
        }

        return best is { DriftCount: <= Threshold } ? best : null;
    }

    /// <summary>What a profile would run, as an observation (to compare two profiles).</summary>
    public static ObservedStack ExpectedStack(DevStackConfig config, string profile)
    {
        var resolved = ProfileResolver.Resolve(config, profile, null);
        var context = ProfileResolver.DryRunContext(config, resolved.Checkout, resolved.Configuration);
        return new ObservedStack(context.Checkout, resolved.Configuration,
            ExpectedServices(resolved, context).Select(e => new ObservedService(e.Name, e.RepoPath, e.Args, e.Ports)).ToList());
    }

    /// <summary>The processes of an external group (Start-Octo, a terminal) as an observation.</summary>
    public static ObservedStack FromExternal(ExternalSnapshot external, ExternalGroup group) =>
        new(group.Checkout, group.Configuration, external.Services.Where(s => s.Group == group.Key)
            .Select(s => new ObservedService(s.Service, s.RepoPath, ArgsOf(s.Command), s.Ports)).ToList());

    /// <summary>The live services of the daemon's stack as an observation.</summary>
    public static ObservedStack FromStatus(StackStatus status) =>
        new(status.Folder, status.Configuration, status.Services.Where(s => s.State != "exited")
            .Select(s => new ObservedService(s.Name, s.RepoPath, s.Args, s.Ports)).ToList());

    /// <summary>The arguments of a command line from the .dll on (frontends without a .dll: none).</summary>
    /// <summary>Normalized raw token and its masked form, position by position.</summary>
    private static IEnumerable<(string Raw, string Shown)> MaskedTokens(IReadOnlyList<string> args) =>
        args.Zip(Common.SecretMask.MaskArgs(args), (raw, shown) => (Normalize(raw), Normalize(shown)));

    public static IReadOnlyList<string> ArgsOf(string commandLine)
    {
        var tokens = commandLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var dll = Array.FindIndex(tokens, t => t.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));
        if (dll < 0)
        {
            return [];
        }

        var args = tokens[dll..].ToList();
        args[0] = Path.GetFileName(args[0]);
        return args;
    }

    private static List<Expected> ExpectedServices(ResolvedStart resolved, StackContext context)
    {
        var plans = ProfileResolver.DryRunPlans(resolved, context);
        return plans.Select(plan =>
        {
            var baseName = resolved.Instances.TryGetValue(plan.Name, out var instance) ? instance.Of! : plan.Name;
            var repoPath = plan.RepoPath;
            if (resolved.Overrides.GetValueOrDefault(plan.Name)?.Source is { Length: > 0 } source)
            {
                try
                {
                    repoPath = LaneSource.Is(source)
                        ? LaneSource.Resolve(resolved.Config, plan.Name, resolved.Config.Services[baseName].Repo, source)
                        : ServicePlanner.ResolveFolder(source, context.RootPath, context.Checkout, "source");
                }
                catch (InvalidOperationException)
                {
                    repoPath = LaneSource.Is(source) ? repoPath : Path.IsPathRooted(source) ? source : Path.GetFullPath(Path.Combine(context.Checkout, source));
                }
            }

            return new Expected(plan.Name, baseName, repoPath, plan.Args, plan.Ports, resolved.Config.Services[baseName].Optional);
        }).ToList();
    }

    private static IEnumerable<ProfileDrift> CompareServices(List<Expected> expected, IReadOnlyList<ObservedService> observed, string root)
    {
        // Pair observed processes with expected services. Processes outside the daemon carry the base name (two mesh
        // adapters are both "meshAdapter"), so instances are told apart by their ports.
        var pairs = new List<(int Score, Expected E, ObservedService O)>();
        foreach (var o in observed)
        {
            foreach (var e in expected.Where(e => e.Name == o.Name || e.Base == o.Name))
            {
                var overlap = e.Ports.Intersect(o.Ports).Count();
                pairs.Add((overlap * 2 + (e.Name == o.Name ? 1 : 0), e, o));
            }
        }

        var usedE = new HashSet<Expected>();
        var usedO = new HashSet<ObservedService>(ReferenceEqualityComparer.Instance);
        var assigned = new List<(Expected E, ObservedService O)>();
        foreach (var (_, e, o) in pairs.OrderByDescending(p => p.Score))
        {
            if (!usedE.Contains(e) && !usedO.Contains(o))
            {
                usedE.Add(e);
                usedO.Add(o);
                assigned.Add((e, o));
            }
        }

        foreach (var e in expected.Where(e => !usedE.Contains(e) && !e.Optional))
        {
            yield return new ProfileDrift("serviceMissing", e.Name, $"{e.Name} is not running");
        }

        foreach (var o in observed.Where(o => !usedO.Contains(o)))
        {
            yield return new ProfileDrift("serviceExtra", o.Name, $"{o.Name} runs but is not part of the profile");
        }

        foreach (var (e, o) in assigned.OrderBy(a => expected.IndexOf(a.E)))
        {
            if (o.RepoPath != null && !SamePath(o.RepoPath, e.RepoPath))
            {
                yield return new ProfileDrift("source", e.Name, $"runs from {Relative(o.RepoPath, root)}, profile: {Relative(e.RepoPath, root)}");
            }

            if (o.Args.Count > 0)
            {
                var want = e.Args.Select(Normalize).ToHashSet(StringComparer.Ordinal);
                var have = o.Args.Select(Normalize).ToHashSet(StringComparer.Ordinal);
                var missing = want.Except(have).ToList();
                var extra = have.Except(want).ToList();
                if (missing.Count + extra.Count > 0)
                {
                    // Compared raw, shown masked: the detail leaves the daemon (stack_status, profile_list, the status page).
                    var shownOf = MaskedTokens(e.Args).Concat(MaskedTokens(o.Args)).GroupBy(p => p.Raw).ToDictionary(g => g.Key, g => g.First().Shown);
                    var parts = missing.Select(t => "-" + shownOf.GetValueOrDefault(t, t)).Concat(extra.Select(t => "+" + shownOf.GetValueOrDefault(t, t))).ToList();
                    var shown = string.Join(" ", parts.Take(MaxTokens)) + (parts.Count > MaxTokens ? $" (+{parts.Count - MaxTokens} more)" : "");
                    yield return new ProfileDrift("args", e.Name, shown);
                }
            }

            if (o.Ports.Count > 0 && !o.Ports.ToHashSet().SetEquals(e.Ports))
            {
                yield return new ProfileDrift("ports", e.Name, $"listens on {string.Join(", ", o.Ports)}, profile: {string.Join(", ", e.Ports)}");
            }
        }
    }

    /// <summary>The legacy adapter tenant key (Start-Octo still uses it) means the same as the new one.</summary>
    private static string Normalize(string token) =>
        token.StartsWith("--Adapter:TenantId=", StringComparison.OrdinalIgnoreCase)
            ? "--Adapter:DedicatedTenantId=" + token["--Adapter:TenantId=".Length..]
            : token;

    private static bool SamePath(string a, string b) =>
        string.Equals(Path.GetFullPath(a).TrimEnd(Path.DirectorySeparatorChar), Path.GetFullPath(b).TrimEnd(Path.DirectorySeparatorChar),
            Common.PathScope.OsComparison);

    private static string Relative(string path, string root) => Common.PathScope.Relative(path, root);
}
