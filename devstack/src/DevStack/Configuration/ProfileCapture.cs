using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>Turns a running stack into a profile (admin_profile_save with capture).</summary>
public static class ProfileCapture
{
    /// <summary>Keeps the environment a profile may store; secret-looking keys are skipped and reported.</summary>
    public static (Dictionary<string, string?> Kept, List<string> Skipped) FilterEnv(IReadOnlyDictionary<string, string?> env)
    {
        var kept = new Dictionary<string, string?>(StringComparer.Ordinal);
        var skipped = new List<string>();
        foreach (var (key, value) in env)
        {
            if (SecretMask.IsSecretName(key))
            {
                skipped.Add(key);
            }
            else
            {
                kept[key] = value;
            }
        }

        return (kept, skipped);
    }

    /// <summary>A process of a running stack as admin_profile_save sees it.</summary>
    public sealed record Process(string Service, string? Source, IReadOnlyList<string> Args, IReadOnlyList<int> Ports);

    /// <summary>A path as a profile stores it: relative to <paramref name="baseFolder"/> when inside it.</summary>
    public static string Relative(string path, string baseFolder) => Common.PathScope.Relative(path, baseFolder);

    /// <summary>
    ///     A profile from processes the daemon did not start (Start-Octo, a terminal): checkout, configuration, services,
    ///     worktree sources and arguments that differ from the configured ones. A second process of the same service becomes
    ///     an instance (by port: the one on the configured ports is the service itself). Their environment is not readable.
    /// </summary>
    /// <param name="skipped">Receives the secret-looking arguments that were left out (command lines can hold credentials).</param>
    public static Profile FromProcesses(DevStackConfig config, string? checkout, string? configuration, IReadOnlyList<Process> processes,
        List<string>? skipped = null)
    {
        skipped ??= [];
        var root = ServicePlanner.RootPath(config);
        var profile = new Profile
        {
            Checkout = checkout == null ? null : Relative(checkout, root),
            Configuration = configuration,
            Services = []
        };
        var context = ProfileResolver.DryRunContext(config, checkout ?? config.DefaultCheckout, configuration ?? config.Configuration);
        foreach (var group in processes.Where(p => config.Services.ContainsKey(p.Service)).GroupBy(p => p.Service))
        {
            var service = config.Services[group.Key];
            var ordered = group.OrderByDescending(p => p.Ports.Intersect(service.Ports).Count()).ToList();
            profile.Services.Add(group.Key);
            var configured = ServicePlanner.Plan(config, context, group.Key, null, new Dictionary<string, string?>()).Args;
            var first = ordered[0];
            var o = new ServiceOverride
            {
                Source = first.Source == null ? null : Relative(first.Source, context.Checkout),
                Args = first.Args.Count > 0 && !first.Args.SequenceEqual(configured) ? SecretMask.FilterArgs(first.Args, skipped) : null
            };
            if (o.Source != null || o.Args != null)
            {
                (profile.Overrides ??= new Dictionary<string, ServiceOverride>())[group.Key] = o;
            }

            for (var i = 1; i < ordered.Count; i++)
            {
                var p = ordered[i];
                var name = $"{group.Key}{i + 1}";
                (profile.Instances ??= new Dictionary<string, ProfileInstance>())[name] = new ProfileInstance
                {
                    Of = group.Key,
                    Ports = [..p.Ports],
                    Source = p.Source == null ? null : Relative(p.Source, context.Checkout),
                    Args = p.Args.Count > 0 ? SecretMask.FilterArgs(p.Args, skipped) : null
                };
            }
        }

        return profile;
    }
}
